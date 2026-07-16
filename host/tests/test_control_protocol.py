from __future__ import annotations

import struct
import unittest

from host.comm.control_protocol import (
    Command, DataMode, ProtocolError, ResponseParser, Waveform,
    acquisition_payload, crc8_atm, encode_request, generator_payload,
    parse_device_status, processing_payload,
)


def response_frame(command: int, status: int, payload: bytes) -> bytes:
    body = bytes((command, status, len(payload))) + payload
    return b"\x55\xAA" + body + bytes((crc8_atm(body),))


class ControlProtocolTest(unittest.TestCase):
    def test_crc8_standard_vector(self) -> None:
        self.assertEqual(crc8_atm(b"123456789"), 0xF4)

    def test_encode_and_incremental_response(self) -> None:
        request = encode_request(Command.ARM)
        self.assertEqual(request[:4], b"\xAA\x55\x04\x00")
        self.assertEqual(request[-1], crc8_atm(request[2:-1]))
        frame = response_frame(Command.QUERY_STATUS, 0, bytes(range(32)))
        parser = ResponseParser()
        self.assertEqual(parser.feed(b"noise\x55"), [])
        responses = parser.feed(frame[1:10]) + parser.feed(frame[10:])
        self.assertEqual(len(responses), 1)
        self.assertEqual(responses[0].payload, bytes(range(32)))

    def test_bad_response_crc(self) -> None:
        frame = bytearray(response_frame(Command.ARM, 0, b""))
        frame[-1] ^= 1
        with self.assertRaises(ProtocolError):
            ResponseParser().feed(frame)

    def test_payload_layouts(self) -> None:
        generator = generator_payload(1, Waveform.SINE, 1000, 1.0, commit=False)
        channel, wave, ftw, amplitude, dc, flags = struct.unpack("<BBIHHB", generator)
        self.assertEqual((channel, wave, amplitude, dc, flags), (0, 0, 0x199A, 0x8000, 0))
        self.assertGreater(ftw, 0)
        acquisition = acquisition_payload(0, 2048, 16, 0, 20_000, 50)
        self.assertEqual(len(acquisition), 13)
        processing = processing_payload(DataMode.ENVELOPE, 16, 1024, 20)
        self.assertEqual(struct.unpack("<BIIIB", processing), (1, 16, 1024, 20_000, 1))

    def test_status_parse(self) -> None:
        payload = bytearray(32)
        payload[0:5] = bytes((1, 0, 0, 7, 0))
        payload[5] = 0b01111010
        struct.pack_into("<IIIIIHH", payload, 8, 1, 2, 3, 1_388_888, 1_388_888, 9, 4)
        status = parse_device_status(payload)
        self.assertTrue(status["adc_armed"])
        self.assertTrue(status["ddr_calibrated"])
        self.assertTrue(status["network_link_up"])
        self.assertEqual(status["config_sequence"], 9)


if __name__ == "__main__":
    unittest.main()
