from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.config import PC_IP, UART_BAUD, UDP_PORT
from host.ui.main_window import MainWindow


class UiSmokeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_window_constructs_and_closes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "ui.db")
            self.assertIn("FPGA", window.windowTitle())
            self.assertEqual(window.udp_bind_edit.text(), PC_IP)
            self.assertEqual(window.udp_port_spin.value(), UDP_PORT)
            window.close()
            self.app.processEvents()

    def test_auto_connect_starts_udp_and_only_serial_port(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "auto.db")
            with (
                mock.patch("host.ui.main_window.list_ports.comports", return_value=[SimpleNamespace(device="COM14")]),
                mock.patch.object(window.udp_receiver, "start") as udp_start,
                mock.patch.object(window.serial_link, "connect_port") as uart_connect,
            ):
                window._auto_connect()
            udp_start.assert_called_once_with(PC_IP, UDP_PORT)
            uart_connect.assert_called_once_with("COM14", UART_BAUD)
            window.close()
            self.app.processEvents()

    def test_auto_connect_does_not_guess_between_multiple_serial_ports(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "multiple.db")
            ports = [SimpleNamespace(device="COM3"), SimpleNamespace(device="COM14")]
            with (
                mock.patch("host.ui.main_window.list_ports.comports", return_value=ports),
                mock.patch.object(window.settings, "value", return_value=""),
                mock.patch.object(window.udp_receiver, "start"),
                mock.patch.object(window.serial_link, "connect_port") as uart_connect,
            ):
                window._auto_connect()
            uart_connect.assert_not_called()
            window.close()
            self.app.processEvents()

    def test_auto_connect_prefers_last_successful_serial_port(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "preferred.db")
            ports = [SimpleNamespace(device="COM3"), SimpleNamespace(device="COM14")]
            with (
                mock.patch("host.ui.main_window.list_ports.comports", return_value=ports),
                mock.patch.object(window.settings, "value", return_value="COM14"),
                mock.patch.object(window.udp_receiver, "start"),
                mock.patch.object(window.serial_link, "connect_port") as uart_connect,
            ):
                window._auto_connect()
            uart_connect.assert_called_once_with("COM14", UART_BAUD)
            window.close()
            self.app.processEvents()

    def test_save_table_and_replay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "replay.db")
            payload = b"\x01\x00\x02\x00\x03\x00\x04\x00"
            live_frame = CompletedFrame(
                PacketHeader(1, 2, 9, 1, 1000, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 3),
                payload,
            )
            window._on_frame(live_frame)
            window._save_current()
            self.assertEqual(window.records_table.rowCount(), 1)
            window.records_table.selectRow(0)
            window.current_frame = None
            window._replay_selected()
            self.assertEqual(window.current_frame.payload, payload)
            window.close()
            self.app.processEvents()


if __name__ == "__main__":
    unittest.main()
