from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from host.comm.data_protocol import CompletedFrame, Measurement, PacketHeader, SampleFormat
from host.db.sqlite_store import SqliteStore


class SqliteStoreTest(unittest.TestCase):
    def test_frame_blob_and_measurement_round_trip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "signal.db"
            header = PacketHeader(1, 1, 123, 2, 65_000_000, 1, 3, SampleFormat.RAW32, 0, 0, 8, 3)
            frame = CompletedFrame(header, b"\x01\x02\x03\x04\x05\x06\x07\x08")
            measurement = Measurement(1, 2, 3, 4, 5, 6, 1, 1, 0, 0, 65, 65, 1_000_000, 1_000_000, True, True, False)
            with SqliteStore(path) as store:
                record_id = store.save_frame(frame, config={"mode": "RAW"}, note="测试")
                store.save_measurement(123, measurement, capture_id=record_id)
                records = store.list_captures()
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0].payload_bytes, 8)
                loaded = store.load_frame(record_id)
                self.assertEqual(loaded.payload, frame.payload)
                store.delete_capture(record_id)
                self.assertEqual(store.list_captures(), [])
            self.assertTrue(path.exists())


if __name__ == "__main__":
    unittest.main()
