from __future__ import annotations

import os
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.ui.main_window import MainWindow


def frame(sample_format: int, payload: bytes, channel_mask: int = 3) -> CompletedFrame:
    unit = 8 if sample_format == SampleFormat.ENVELOPE64 else 1
    return CompletedFrame(
        PacketHeader(1, 2, 1, len(payload) // unit, 100, 0, channel_mask,
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
            window.timebase_combo.setCurrentText("1 ms/div")
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

    def test_measurement_hides_inactive_channel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "single-measurement.db")
            measurement = frame(
                SampleFormat.MEASUREMENT_V1,
                struct.pack("<HHHHIIHHIIIIIIBB", *([0] * 16)),
                channel_mask=1,
            )
            window._on_frame(measurement)
            self.assertEqual([label.text() for label in window.measurement_labels[4:]],
                             ["未启用"] * 4)
            self.assertEqual(window.measurement_labels[3].text(), "无效")
            self.assertEqual(window.status_labels["otr"].text(), "0/未启用")
            window.close()
            self.app.processEvents()

    def test_stale_envelope_from_previous_timebase_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "stale-envelope.db")
            window.timebase_combo.setCurrentText("2 ms/div")
            payload = struct.pack("<" + "H" * (1024 * 4), *([0x800] * (1024 * 4)))
            stale = CompletedFrame(
                PacketHeader(1, 2, 10, 1024, 102400, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 0),
                payload,
            )
            current = CompletedFrame(
                PacketHeader(1, 2, 11, 1024, 51200, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 0),
                payload,
            )
            with mock.patch.object(window.plot_widget, "display_frame") as display:
                window._on_frame(stale)
                display.assert_not_called()
                self.assertIsNone(window.current_frame)
                window._on_frame(current)
                display.assert_called_once_with(current)
                self.assertIs(window.current_frame, current)
            window.close()
            self.app.processEvents()

    def test_timebase_change_redraws_old_envelope_immediately(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "timebase-clear.db")
            window.timebase_combo.setCurrentText("1 ms/div")
            payload = struct.pack(
                "<" + "H" * 400,
                *([0x700, 0x900, 0x600, 0xA00] * 100),
            )
            envelope = CompletedFrame(
                PacketHeader(1, 2, 20, 100, 10000, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 0),
                payload,
            )
            window._on_frame(envelope)
            self.assertIs(window.current_frame, envelope)
            window.timebase_combo.setCurrentText("2 ms/div")
            self.assertIs(window.current_frame, envelope)
            self.assertEqual(len(window.plot_widget.curve_a.getData()[0]), 100)
            self.assertEqual(len(window.plot_widget.curve_b.getData()[0]), 100)
            window.close()
            self.app.processEvents()


if __name__ == "__main__":
    unittest.main()
