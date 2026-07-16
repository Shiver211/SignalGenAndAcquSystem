from __future__ import annotations

import struct
import unittest
from pathlib import Path

import numpy as np

from host.comm.data_protocol import (
    DatagramError, DataType, PacketHeader, SampleFormat, build_packet,
    decode_envelope64, decode_measurement_v1, decode_raw32, parse_packet,
)
from host.config import UDP_PORT


ROOT = Path(__file__).resolve().parents[2]


def header(sample_format: int, total: int = 1, data_type: int = DataType.RAW_FRAME) -> PacketHeader:
    return PacketHeader(1, data_type, 7, total, 65_000_000, 0, 3, sample_format, 0, 0, 0, 3)


class DataProtocolTest(unittest.TestCase):
    def test_packet_round_trip_and_crc(self) -> None:
        payload = bytes(range(32))
        packet = build_packet(header(SampleFormat.RAW32, 8), payload)
        parsed, result = parse_packet(packet)
        self.assertEqual(parsed.total_samples, 8)
        self.assertEqual(result, payload)
        damaged = bytearray(packet); damaged[40] ^= 1
        with self.assertRaises(DatagramError):
            parse_packet(damaged)

    def test_m7_rtl_reference_vector(self) -> None:
        vector = ROOT / "sim" / "vectors" / "m7_udp_expected.mem"
        ethernet_frame = bytes(int(line, 16) for line in vector.read_text().splitlines())
        # 前导码8 + Ethernet14 + IPv4头20 + UDP头8，尾部4字节为 Ethernet FCS。
        self.assertEqual(struct.unpack("!HH", ethernet_frame[42:46]), (UDP_PORT, UDP_PORT))
        app_packet = ethernet_frame[50:-4]
        parsed, payload = parse_packet(app_packet)
        self.assertEqual(parsed.frame_id, 0x11223344)
        self.assertEqual(parsed.chunk_offset, 2800)
        self.assertEqual(payload, bytes(range(32)))

    def test_raw_and_envelope_decode(self) -> None:
        words = np.array([0x03ABC123, 0x00456789], dtype="<u4")
        raw = decode_raw32(words.tobytes())
        self.assertEqual(raw["a"].tolist(), [0x123, 0x789])
        self.assertEqual(raw["b"].tolist(), [0xABC, 0x456])
        self.assertTrue(raw["otr_a"][0])
        envelope = struct.pack("<HHHH", 1, 4095, 2, 4000)
        decoded = decode_envelope64(envelope)
        self.assertEqual(decoded["max_a"].tolist(), [4095])
        self.assertEqual(decoded["min_b"].tolist(), [2])

    def test_measurement_decode(self) -> None:
        payload = struct.pack(
            "<HHHHIIHHIIIIIIBB",
            1, 4000, 2, 3900, 2000, 2100, 3999, 3898,
            3, 4, 65_000, 32_500, 1000, 2000, 3, 1,
        )
        measurement = decode_measurement_v1(payload)
        self.assertEqual(measurement.frequency_hz_b, 2000)
        self.assertTrue(measurement.period_valid_a)
        self.assertTrue(measurement.period_valid_b)
        self.assertTrue(measurement.calculation_overrun)


if __name__ == "__main__":
    unittest.main()
