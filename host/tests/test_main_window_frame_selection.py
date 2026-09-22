from __future__ import annotations

import os
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtCore, QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.core.waveform import code_to_voltage, fixed_dc_offset_v, format_voltage, vpp_from_code_span
from host.tests.window_helpers import create_window


def dual_measurement_payload() -> bytes:
    return struct.pack(
        "<HHHHIIHHIIIIIIBB",
        1600, 2444, 1626, 2468, 2022, 2047, 844, 842,
        0, 0, 6500, 6500, 10_000, 10_000, 3, 0,
    )


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
            window = create_window(Path(directory) / "selection.db")
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
            window = create_window(Path(directory) / "single-measurement.db")
            measurement = frame(
                SampleFormat.MEASUREMENT_V1,
                struct.pack("<HHHHIIHHIIIIIIBB", *([0] * 16)),
                channel_mask=1,
            )
            window._on_frame(measurement)
            self.assertEqual(
                [label.text() for label in window.measurement_labels[:4]],
                [
                    format_voltage(code_to_voltage(0, offset_v=fixed_dc_offset_v(1))),
                    format_voltage(code_to_voltage(0, offset_v=fixed_dc_offset_v(1))),
                    "0.000 V",
                    "无效",
                ],
            )
            self.assertEqual([label.text() for label in window.measurement_labels[4:]],
                             ["未启用"] * 4)
            self.assertEqual(window.status_labels["otr"].text(), "0/未启用")
            window.close()
            self.app.processEvents()

    def test_amplitude_calibration_converts_codes_to_known_vpp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            settings = QtCore.QSettings(
                str(Path(directory) / "cal.ini"), QtCore.QSettings.IniFormat,
            )
            window = create_window(Path(directory) / "cal.db", settings=settings)
            window._on_frame(frame(SampleFormat.MEASUREMENT_V1, dual_measurement_payload()))
            window.cal_vpp_spins[1].setValue(2.0)
            window._calibrate_amplitude(1)
            self.assertEqual(window.measurement_labels[2].text(), "2.000 V")
            self.assertEqual(
                window.measurement_labels[6].text(),
                format_voltage(vpp_from_code_span(842), peak_to_peak=True),
            )
            self.assertEqual(window.measurement_labels[3].text(), "10.000 kHz")
            self.assertAlmostEqual(window._adc_gain[1] * 844 / 4095 * 10, 2.0, places=6)
            self.assertEqual(window._adc_gain[2], 1.0)
            window.close()
            self.app.processEvents()

    def test_amplitude_calibration_is_independent_per_channel(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "cal-independent.db")
            window._on_frame(frame(SampleFormat.MEASUREMENT_V1, dual_measurement_payload()))
            window.cal_vpp_spins[1].setValue(2.0)
            window.cal_vpp_spins[2].setValue(1.5)
            window._calibrate_amplitude(1)
            window._calibrate_amplitude(2)
            self.assertEqual(window.measurement_labels[2].text(), "2.000 V")
            self.assertEqual(window.measurement_labels[6].text(), "1.500 V")
            self.assertAlmostEqual(window._adc_gain[1] * 844 / 4095 * 10, 2.0, places=6)
            self.assertAlmostEqual(window._adc_gain[2] * 842 / 4095 * 10, 1.5, places=6)
            window._reset_adc_calibration(1)
            self.assertEqual(window._adc_gain[1], 1.0)
            self.assertEqual(window._adc_offset[1], 0.0)
            self.assertAlmostEqual(window._adc_gain[2] * 842 / 4095 * 10, 1.5, places=6)
            self.assertEqual(
                window.measurement_labels[2].text(),
                format_voltage(vpp_from_code_span(844), peak_to_peak=True),
            )
            self.assertEqual(window.measurement_labels[6].text(), "1.500 V")
            window.close()
            self.app.processEvents()

    def test_calibrating_disabled_channel_does_not_change_gains(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "cal-disabled.db")
            window._on_frame(frame(
                SampleFormat.MEASUREMENT_V1, dual_measurement_payload(), channel_mask=1,
            ))
            window.cal_vpp_spins[2].setValue(2.0)
            window._calibrate_amplitude(2)
            self.assertEqual(window._adc_gain, {1: 1.0, 2: 1.0})
            window.close()
            self.app.processEvents()

    def test_single_channel_mode_disables_other_calibration_controls(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "cal-mode.db")
            window.channel_mode_combo.setCurrentText("CH1")
            self.assertTrue(window.calibrate_buttons[1].isEnabled())
            self.assertTrue(window.cal_vpp_spins[1].isEnabled())
            self.assertTrue(window.reset_cal_buttons[1].isEnabled())
            self.assertFalse(window.calibrate_buttons[2].isEnabled())
            self.assertFalse(window.cal_vpp_spins[2].isEnabled())
            self.assertFalse(window.reset_cal_buttons[2].isEnabled())
            window.close()
            self.app.processEvents()

    def test_ch1_fixed_dc_offset_shifts_readings_not_vpp(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "fixed-dc.db")
            window._on_frame(frame(SampleFormat.MEASUREMENT_V1, dual_measurement_payload()))
            offset = fixed_dc_offset_v(1)
            self.assertEqual(
                window.measurement_labels[0].text(),
                format_voltage(code_to_voltage(1600, offset_v=offset)),
            )
            self.assertEqual(
                window.measurement_labels[1].text(),
                format_voltage(code_to_voltage(2444, offset_v=offset)),
            )
            self.assertEqual(
                window.measurement_labels[2].text(),
                format_voltage(vpp_from_code_span(844), peak_to_peak=True),
            )
            self.assertEqual(
                window.measurement_labels[4].text(),
                format_voltage(code_to_voltage(1626)),
            )
            self.assertFalse(hasattr(window, "ch1_dc_offset_spin"))
            window.close()
            self.app.processEvents()

    def test_stale_envelope_from_previous_timebase_is_ignored(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "stale-envelope.db")
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
            window = create_window(Path(directory) / "timebase-clear.db")
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
