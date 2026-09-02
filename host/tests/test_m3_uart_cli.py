from __future__ import annotations

import argparse
import struct
import unittest

from scripts.uart_cli import build_acquisition_payload


class M3CliProtocolTest(unittest.TestCase):
    def test_acquisition_payload_contains_channel_mask(self) -> None:
        args = argparse.Namespace(
            source="b", threshold=2048, hysteresis=16, edge="falling",
            depth=20_000, pretrigger_percent=50.0, channel_mask=2,
            stage=False,
        )
        payload = build_acquisition_payload(args)
        self.assertEqual(len(payload), 14)
        self.assertEqual(
            struct.unpack("<BHHBIHBB", payload),
            (1, 2048, 16, 1, 20_000, 500, 1, 2),
        )


if __name__ == "__main__":
    unittest.main()
