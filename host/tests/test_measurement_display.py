"""测量读数显示稳定：末位抖动按住，超出噪声带的变化当帧跟上。"""

from __future__ import annotations

import os
import struct
import tempfile
import unittest
from pathlib import Path

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.core.waveform import (
    MeasurementDisplayFilter, code_to_voltage, fixed_dc_offset_v,
    format_frequency_hz, format_voltage,
)
from host.tests.window_helpers import create_window


class MeasurementDisplayFilterTest(unittest.TestCase):
    def setUp(self) -> None:
        self.filt = MeasurementDisplayFilter()

    def test_first_reading_is_shown_unchanged(self) -> None:
        self.assertEqual(
            self.filt.update_channel(1, 1600, 2444, 10_000, frequency_valid=True, active=True),
            (1600, 2444, 844, 10_000.0, True),
        )

    def test_small_chatter_does_not_move_the_reading(self) -> None:
        self.filt.update_channel(1, 1600, 2444, 10_000, frequency_valid=True, active=True)
        for index, offset in enumerate((1, -1, 2, -2, 1, 0, -1, 2)):
            minimum, maximum, vpp, frequency, valid = self.filt.update_channel(
                1, 1600 + offset, 2444 - offset, 10_000 + (1 if index % 2 == 0 else -1),
                frequency_valid=True, active=True,
            )
            self.assertEqual((minimum, maximum, vpp, frequency, valid),
                             (1600, 2444, 844, 10_000.0, True))

    def test_one_hertz_change_appears_when_repeated(self) -> None:
        for start in (50.0, 10_000.0, 1_000_000.0):
            with self.subTest(start=start):
                self.filt.reset()
                self.filt.update_channel(1, 1600, 2444, start, frequency_valid=True, active=True)
                once = self.filt.update_channel(
                    1, 1600, 2444, start + 1, frequency_valid=True, active=True,
                )
                self.assertEqual(once[3], start)
                twice = self.filt.update_channel(
                    1, 1600, 2444, start + 1, frequency_valid=True, active=True,
                )
                self.assertEqual(twice[3], start + 1.0)
                self.assertTrue(twice[4])

    def test_step_updates_on_the_same_reading(self) -> None:
        self.filt.update_channel(1, 1600, 2444, 10_000, frequency_valid=True, active=True)
        stepped = self.filt.update_channel(
            1, 1592, 2452, 10_050, frequency_valid=True, active=True,
        )
        self.assertEqual(stepped, (1592, 2452, 860, 10_050.0, True))
        large = self.filt.update_channel(
            1, 1400, 2700, 1_000_000, frequency_valid=True, active=True,
        )
        self.assertEqual(large[:4], (1400, 2700, 1300, 1_000_000.0))

    def test_channels_and_reset_are_independent(self) -> None:
        self.filt.update_channel(1, 1600, 2444, 10_000, frequency_valid=True, active=True)
        self.filt.update_channel(2, 1700, 2500, 20_000, frequency_valid=True, active=True)
        self.filt.update_channel(2, 1700, 2800, 25_000, frequency_valid=True, active=True)
        held = self.filt.update_channel(1, 1601, 2443, 10_001, frequency_valid=True, active=True)
        self.assertEqual(held[:4], (1600, 2444, 844, 10_000.0))
        inactive = self.filt.update_channel(2, 1700, 2500, 20_000, frequency_valid=True, active=False)
        self.assertEqual(inactive, (0, 0, 0, 0.0, False))
        restarted = self.filt.update_channel(2, 1800, 2200, 3_000, frequency_valid=True, active=True)
        self.assertEqual(restarted[:4], (1800, 2200, 400, 3_000.0))
        self.filt.reset()
        fresh = self.filt.update_channel(1, 1000, 2000, 4_000, frequency_valid=True, active=True)
        self.assertEqual(fresh[:4], (1000, 2000, 1000, 4_000.0))

    def test_invalid_frequency_does_not_erase_amplitude_or_later_frequency(self) -> None:
        self.filt.update_channel(1, 1600, 2444, 10_000, frequency_valid=True, active=True)
        invalid = self.filt.update_channel(1, 1601, 2443, 0, frequency_valid=False, active=True)
        self.assertEqual(invalid, (1600, 2444, 844, 0.0, False))
        restored = self.filt.update_channel(1, 1600, 2444, 10_001, frequency_valid=True, active=True)
        self.assertEqual(restored, (1600, 2444, 844, 10_000.0, True))

    def test_rejects_unknown_channel(self) -> None:
        with self.assertRaises(ValueError):
            self.filt.update_channel(3, 0, 1, 0, frequency_valid=False, active=True)


class MeasurementDisplayWindowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_labels_hold_chatter_and_follow_a_step_immediately(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "measure.db")
            window._on_frame(_measurement_frame(1600, 2444, 1626, 2468, 10_000, 12_000))
            self.assertEqual(window.measurement_labels[2].text(),
                             format_voltage((2444 - 1600) / 4095 * 10, peak_to_peak=True))
            self.assertEqual(window.measurement_labels[3].text(), format_frequency_hz(10_000))
            for index, offset in enumerate((1, -1, 2, -1)):
                window._on_frame(_measurement_frame(
                    1600 + offset, 2444 - offset, 1626, 2468,
                    10_000 + (1 if index % 2 == 0 else -1), 12_000,
                ))
            self.assertEqual(window.measurement_labels[0].text(),
                             format_voltage(code_to_voltage(1600, offset_v=fixed_dc_offset_v(1))))
            self.assertEqual(window.measurement_labels[2].text(),
                             format_voltage((2444 - 1600) / 4095 * 10, peak_to_peak=True))
            self.assertEqual(window.measurement_labels[3].text(), "10.000 kHz")
            # 校准和记录仍使用最新原始码值，而不是按住的显示值。
            stepped = _measurement_frame(1500, 2600, 1626, 2468, 15_000, 12_000)
            window._on_frame(stepped)
            self.assertEqual(window._last_measurement.min_a, 1500)
            self.assertEqual(window._last_measurement.frequency_hz_a, 15_000)
            self.assertEqual(window.measurement_labels[3].text(), "15.000 kHz")
            self.assertEqual(window.measurement_labels[2].text(),
                             format_voltage((2600 - 1500) / 4095 * 10, peak_to_peak=True))
            window.close()
            self.app.processEvents()


def _measurement_frame(
    min_a: int, max_a: int, min_b: int, max_b: int, freq_a: int, freq_b: int,
) -> CompletedFrame:
    payload = struct.pack(
        "<HHHHIIHHIIIIIIBB",
        min_a, max_a, min_b, max_b, 2000, 2100, max_a - min_a, max_b - min_b,
        0, 0, 6500, 6500, freq_a, freq_b, 3, 0,
    )
    return CompletedFrame(
        PacketHeader(1, 2, 1, 1, 65_000_000, 0, 3, SampleFormat.MEASUREMENT_V1,
                     0, 0, len(payload), 0),
        payload,
    )


if __name__ == "__main__":
    unittest.main()
