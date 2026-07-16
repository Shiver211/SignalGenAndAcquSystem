from __future__ import annotations

import os
import time
import unittest
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.control_protocol import Command, crc8_atm
from host.comm.serial_link import SerialLink


class FakeSerial:
    def __init__(self) -> None:
        self.buffer = bytearray()
        self.closed = False

    @property
    def in_waiting(self) -> int:
        return len(self.buffer)

    def reset_input_buffer(self) -> None:
        self.buffer.clear()

    def write(self, request: bytes) -> int:
        command = request[2]
        payload = bytes(range(32)) if command == Command.QUERY_STATUS else b""
        body = bytes((command, 0, len(payload))) + payload
        self.buffer.extend(b"\x55\xAA" + body + bytes((crc8_atm(body),)))
        return len(request)

    def flush(self) -> None:
        pass

    def read(self, size: int) -> bytes:
        data = bytes(self.buffer[:size])
        del self.buffer[:size]
        return data

    def close(self) -> None:
        self.closed = True


class SerialLinkTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_background_transaction(self) -> None:
        responses = []
        connections = []
        fake = FakeSerial()
        link = SerialLink()
        link.response_received.connect(lambda token, response: responses.append((token, response)))
        link.connection_changed.connect(lambda connected, _: connections.append(connected))
        with mock.patch("host.comm.serial_link.serial.serial_for_url", return_value=fake):
            link.connect_port("fake://", timeout=0.1, retries=0)
            deadline = time.monotonic() + 1
            while not connections and time.monotonic() < deadline:
                self.app.processEvents()
                time.sleep(0.005)
            token = link.send_command(Command.QUERY_STATUS)
            while not responses and time.monotonic() < deadline:
                self.app.processEvents()
                time.sleep(0.005)
            link.disconnect_port()
            self.app.processEvents()
        self.assertTrue(connections[0])
        self.assertEqual(responses[0][0], token)
        self.assertEqual(len(responses[0][1].payload), 32)
        self.assertTrue(fake.closed)


if __name__ == "__main__":
    unittest.main()
