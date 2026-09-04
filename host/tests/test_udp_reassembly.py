from __future__ import annotations

import random
import unittest

from host.comm.data_protocol import DataType, PacketHeader, SampleFormat, build_packet
from host.comm.udp_receiver import FrameReassembler


def packet(payload: bytes, offset: int, total_bytes: int, frame_id: int = 10, data_type: int = DataType.RAW_FRAME) -> bytes:
    sample_format = SampleFormat.RAW32 if data_type == DataType.RAW_FRAME else SampleFormat.ENVELOPE64
    unit = 4 if sample_format == SampleFormat.RAW32 else 8
    header = PacketHeader(
        1, data_type, frame_id, total_bytes // unit, 65_000_000,
        0, 3, sample_format, offset // 1400, offset, len(payload), 0,
    )
    return build_packet(header, payload)


class UdpReassemblyTest(unittest.TestCase):
    def test_random_order_and_duplicates(self) -> None:
        source = bytes((index * 17 + 5) & 0xFF for index in range(70_000))
        packets = [packet(source[i:i + 1400], i, len(source)) for i in range(0, len(source), 1400)]
        packets.append(packets[5])
        random.Random(8).shuffle(packets)
        reassembler = FrameReassembler()
        completed = None
        for datagram in packets:
            completed = reassembler.ingest(datagram) or completed
        self.assertIsNotNone(completed)
        self.assertEqual(completed.payload, source)
        self.assertGreaterEqual(reassembler.duplicate_count, 1)

    def test_missing_range_requests_retransmit(self) -> None:
        source = bytes(4000)
        reassembler = FrameReassembler(timeout=0.1)
        reassembler.ingest(packet(source[:1400], 0, len(source)), now=0)
        reassembler.ingest(packet(source[2800:], 2800, len(source)), now=0)
        requests = reassembler.expire(now=1)
        self.assertEqual(requests, [(10, 1400, 1400)])
        result = reassembler.ingest(packet(source[1400:2800], 1400, len(source)), now=1.1)
        self.assertEqual(result.payload, source)

    def test_envelope_latest_frame_wins(self) -> None:
        reassembler = FrameReassembler()
        reassembler.ingest(packet(bytes(8), 0, 16, frame_id=1, data_type=DataType.ENVELOPE_FRAME))
        reassembler.ingest(packet(bytes(8), 0, 16, frame_id=2, data_type=DataType.ENVELOPE_FRAME))
        self.assertEqual(reassembler.dropped_frame_count, 1)
        self.assertNotIn((DataType.ENVELOPE_FRAME, 1), reassembler.frames)

    def test_batched_envelope_chunks_reassemble(self) -> None:
        source = bytes((index * 3) & 0xFF for index in range(1600))
        packets = [
            packet(source[:1400], 0, len(source), data_type=DataType.ENVELOPE_FRAME),
            packet(source[1400:], 1400, len(source), data_type=DataType.ENVELOPE_FRAME),
        ]
        reassembler = FrameReassembler()
        completed = None
        for datagram in packets:
            completed = reassembler.ingest(datagram) or completed
        self.assertIsNotNone(completed)
        self.assertEqual(completed.payload, source)
        self.assertEqual(completed.header.total_samples, 200)


if __name__ == "__main__":
    unittest.main()
