from __future__ import annotations

import os
import struct
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.ui.main_window import MainWindow


def frame(sample_format: int, payload: bytes) -> CompletedFrame:
    unit = 8 if sample_format == SampleFormat.ENVELOPE64 else 1
    return CompletedFrame(
        PacketHeader(1, 2, 1, len(payload) // unit, 1000, 0, 3,
                     sample_format, 0, 0, len(payload), 3),
        payload,
    )


class MainWindowFrameSelectionTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_measurement_does_not_replace_current_waveform(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "selection.db")
            envelope = frame(SampleFormat.ENVELOPE64, struct.pack("<HHHH", 1, 2, 3, 4))
            measurement = frame(
                SampleFormat.MEASUREMENT_V1,
                struct.pack("<HHHHIIHHIIIIIIBB", *([0] * 16)),
            )
            window._on_frame(envelope)
            window._on_frame(measurement)
            self.assertIs(window.current_frame, envelope)
            window.close()
            self.app.processEvents()


if __name__ == "__main__":
    unittest.main()
