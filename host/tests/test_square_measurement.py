"""方波测量去过冲：采样相位、压缩包络、收包顺序及校准回归。"""

import os
import struct
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

import numpy as np

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.config import ADC_SAMPLE_RATE_HZ, MAX_ENVELOPE_POINTS
from host.core.waveform import (
    clean_square_waveform, idealize_square_display, measure_waveform,
    vpp_from_code_span, zero_crossing_frequency,
)
from host.tests.test_square_display import noisy_square
from host.tests.window_helpers import create_window


def make_frame(sample_format, payload, count, rate, mask=3, frame_id=11):
    return CompletedFrame(PacketHeader(1, 2, frame_id, count, rate, 0, mask,
                                      sample_format, 0, 0, len(payload), 0), payload)


def to_codes(values):
    return np.rint((values + 5) / 10 * 4095).astype(np.uint16)


def envelope_frame(a, b, mask=3):
    bucket = int(np.ceil(len(a) / MAX_ENVELOPE_POINTS))
    indices = np.arange(0, len(a), bucket)
    amin, amax = np.minimum.reduceat(a, indices), np.maximum.reduceat(a, indices)
    bmin, bmax = np.minimum.reduceat(b, indices), np.maximum.reduceat(b, indices)
    columns = (amin, amax, bmin, bmax) if mask == 3 else ((amin, amax) if mask == 1 else (bmin, bmax))
    payload = np.column_stack(columns).astype('<u2').tobytes()
    return make_frame(SampleFormat.ENVELOPE64 if mask == 3 else SampleFormat.ENVELOPE32,
                      payload, len(indices), ADC_SAMPLE_RATE_HZ // bucket, mask)


def hardware_frame(a, b, mask=3):
    payload = struct.pack(
        "<HHHHIIHHIIIIIIBB",
        int(a.min()), int(a.max()), int(b.min()), int(b.max()),
        int(a.mean()), int(b.mean()), int(a.max()) - int(a.min()), int(b.max()) - int(b.min()),
        7, 9, 65, 81, 1_000_000, 800_000, mask, 1,
    )
    # 硬件测量包编号与波形编号故意不同。
    return make_frame(SampleFormat.MEASUREMENT_V1, payload, len(a), ADC_SAMPLE_RATE_HZ, mask, 700)


class SquareMeasurementTest(unittest.TestCase):
    def test_amplitude_uses_clean_samples_and_keeps_small_jitter(self):
        for frequency in (500_000, 600_000, 800_000, 1_000_000):
            for phase in (0.1, 0.35, 0.7):
                with self.subTest(frequency=frequency, phase=phase):
                    values = noisy_square(frequency, 1300, phase)
                    original = values.copy()
                    result = measure_waveform(values, ADC_SAMPLE_RATE_HZ)
                    self.assertAlmostEqual(result.minimum_v, -1, delta=0.04)
                    self.assertAlmostEqual(result.maximum_v, 1, delta=0.04)
                    self.assertGreater(result.vpp_v, 2.005)  # 保留平台微小噪声。
                    self.assertLess(result.vpp_v, 2.08)
                    x = np.arange(len(values)) / ADC_SAMPLE_RATE_HZ
                    display_y = idealize_square_display(x, values)[1]
                    self.assertEqual(result.minimum_v, float(display_y.min()))
                    self.assertEqual(result.maximum_v, float(display_y.max()))
                    self.assertEqual(result.frequency_hz, zero_crossing_frequency(values, ADC_SAMPLE_RATE_HZ))
                    np.testing.assert_array_equal(values, original)

    def test_non_square_amplitude_is_unchanged(self):
        phase = np.arange(650) / 65
        for values in (np.sin(2 * np.pi * phase), 4 * np.abs(phase % 1 - 0.5) - 1,
                       np.linspace(-1, 2, 650), np.full(650, 0.3)):
            result = measure_waveform(values, ADC_SAMPLE_RATE_HZ)
            self.assertEqual(result.minimum_v, values.min())
            self.assertEqual(result.maximum_v, values.max())
            self.assertEqual(result.mean_v, values.mean())

    def test_mean_uses_samples_without_extra_drawing_endpoints(self):
        values = np.where(np.arange(1300) % 100 < 20, 1.0, -1.0)
        values[110] = 1.8
        result = measure_waveform(values, ADC_SAMPLE_RATE_HZ)
        self.assertAlmostEqual(result.mean_v, -0.6)
        self.assertEqual(result.vpp_v, 2.0)


class SquareMeasurementWindowTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.window = create_window(Path(self.directory.name) / "measure.db")
        self.window.status_timer.stop()
        self.window.timebase_combo.setCurrentText("5 µs/div")
        self.a = to_codes(noisy_square(1_000_000, 3250))
        self.b = to_codes(np.sin(2 * np.pi * np.arange(3250) * 800_000 / ADC_SAMPLE_RATE_HZ))

    def tearDown(self):
        self.window.close()
        self.app.processEvents()
        self.directory.cleanup()

    def test_continuous_corrects_both_arrival_orders_and_saves_corrected_values(self):
        wave = envelope_frame(self.a, self.b)
        hardware = hardware_frame(self.a, self.b)
        for first in (wave, hardware):
            with self.subTest(first=first.header.sample_format):
                self.window._clear_continuous_measurement()
                self.window._on_frame(first)
                self.window._on_frame(hardware if first is wave else wave)
                measured = self.window._last_measurement
                self.assertAlmostEqual(vpp_from_code_span(measured.vpp_a), 2, delta=0.08)
                self.assertEqual(measured.min_b, int(self.b.min()))
                self.assertEqual(measured.max_b, int(self.b.max()))
                self.assertEqual(measured.frequency_hz_a, 1_000_000)
                self.assertEqual(measured.period_samples_b, 81)
                self.assertTrue(measured.period_valid_b)
                self.assertEqual((measured.otr_count_a, measured.otr_count_b), (7, 9))
                self.assertTrue(measured.calculation_overrun)
                self.assertIs(self.window.current_frame, wave)
                # 后续原始测量包不能恢复过冲，数据库保存同一修正快照。
                self.window._on_frame(hardware)
                self.assertEqual(self.window._last_measurement, measured)
                stored = self.window.store._connection.execute(
                    "SELECT min_a, max_a, vpp_a FROM measurements ORDER BY id DESC LIMIT 1"
                ).fetchone()
                self.assertEqual(tuple(stored), (measured.min_a, measured.max_a, measured.vpp_a))

    def test_compressed_envelope_frequency_timebase_and_channel_sweep(self):
        for frequency in (500_000, 600_000, 800_000, 1_000_000):
            for timebase in (500e-9, 1e-6, 5e-6, 10e-6, 20e-6, 50e-6):
                self.window.timebase_combo.setCurrentIndex(self.window.timebase_combo.findData(timebase))
                count = int(np.ceil(ADC_SAMPLE_RATE_HZ * timebase * 10))
                a = to_codes(noisy_square(frequency, count))
                b = to_codes(noisy_square(frequency, count, 0.7) * 0.6 + 0.2)
                for mask in (1, 2, 3):
                    with self.subTest(frequency=frequency, timebase=timebase, mask=mask):
                        self.window._on_frame(envelope_frame(a, b, mask))
                        self.window._on_frame(hardware_frame(a, b, mask), persist_measurement=False)
                        measured = self.window._last_measurement
                        for bit, suffix, span in ((1, "a", 2), (2, "b", 1.2)):
                            if mask & bit:
                                self.assertAlmostEqual(vpp_from_code_span(getattr(measured, f"vpp_{suffix}")), span, delta=0.08)
                            else:
                                start = 0 if bit == 1 else 4
                                self.assertEqual([label.text() for label in self.window.measurement_labels[start:start + 4]], ["未启用"] * 4)

    def test_manual_raw_and_calibration_use_clean_code_span(self):
        self.window.acquisition_mode_combo.setCurrentText("手动")
        for mask in (1, 2, 3):
            with self.subTest(mask=mask):
                payload = ((self.a.astype('<u4') | (self.a.astype('<u4') << 12) | (1 << 24)).tobytes()
                           if mask == 3 else (self.a | (1 << 12)).astype('<u2').tobytes())
                frame = make_frame(SampleFormat.RAW32 if mask == 3 else SampleFormat.RAW16,
                                   payload, len(self.a), ADC_SAMPLE_RATE_HZ, mask)
                self.window._on_frame(frame)
                measured = self.window._last_measurement
                suffix, channel = ("b", 2) if mask == 2 else ("a", 1)
                span = getattr(measured, f"vpp_{suffix}")
                self.assertAlmostEqual(vpp_from_code_span(span), 2, delta=0.08)
                self.assertEqual(getattr(measured, f"otr_count_{suffix}"), len(self.a))
                self.window.cal_vpp_spins[channel].setValue(2)
                self.window._calibrate_amplitude(channel)
                self.assertAlmostEqual(self.window._adc_gain[channel], 2 / vpp_from_code_span(span))
                self.assertEqual(self.window.measurement_labels[(channel - 1) * 4 + 2].text(), "2.000 V")
                self.window._on_frame(hardware_frame(self.a, self.b, mask))
                self.assertEqual(self.window._last_measurement, measured)
                self.window._save_current()
                saved = self.window.store.list_captures()[0]
                self.assertEqual(self.window.store.load_frame(saved.id).payload, payload)

    def test_new_non_square_frame_and_configuration_drop_previous_correction(self):
        wave = envelope_frame(self.a, self.b)
        hardware = hardware_frame(self.a, self.b)
        for change in ("sine", "unresolved", "timebase", "channel", "mode"):
            with self.subTest(change=change):
                self.window.acquisition_mode_combo.setCurrentText("连续")
                self.window.channel_mode_combo.setCurrentText("CH1 + CH2")
                self.window.timebase_combo.setCurrentText("5 µs/div")
                self.window._on_frame(wave)
                self.window._on_frame(hardware)
                self.assertLess(self.window._last_measurement.max_a, int(self.a.max()))
                if change == "sine":
                    self.window._on_frame(envelope_frame(self.b, self.b))
                elif change == "unresolved":
                    payload = np.tile([1400, 2700, 1400, 2700], (1625, 1)).astype('<u2').tobytes()
                    self.window._on_frame(make_frame(SampleFormat.ENVELOPE64, payload, 1625, ADC_SAMPLE_RATE_HZ // 2))
                elif change == "timebase":
                    self.window.timebase_combo.setCurrentText("10 µs/div")
                    self.window._on_frame(wave)  # 旧时基帧应被拒绝。
                elif change == "channel":
                    self.window.channel_mode_combo.setCurrentText("CH1")
                else:
                    self.window.acquisition_mode_combo.setCurrentText("手动")
                    self.window.acquisition_mode_combo.setCurrentText("连续")
                self.window._on_frame(hardware)
                self.assertEqual(self.window._last_measurement.max_a, int(self.a.max()))

    def test_expired_waveform_does_not_correct_new_measurement(self):
        self.window._on_frame(envelope_frame(self.a, self.b))
        with mock.patch("host.ui.main_window.monotonic", return_value=self.window._square_amplitude_time + 10):
            self.window._on_frame(hardware_frame(self.a, self.b))
        self.assertEqual(self.window._last_measurement.max_a, int(self.a.max()))

    def test_display_scale_and_continuous_calibration_do_not_change_code_measurement(self):
        self.window._on_frame(envelope_frame(self.a, self.b))
        hardware = hardware_frame(self.a, self.b)
        self.window._on_frame(hardware)
        measured = self.window._last_measurement
        self.window.cal_vpp_spins[1].setValue(2)
        self.window._calibrate_amplitude(1)
        self.window.plot_widget.set_volts_per_div(1, 0.2)
        self.window.plot_widget.set_vertical_position_div(1, 2.5)
        self.window._on_frame(hardware)
        self.assertEqual(self.window._last_measurement, measured)
        self.assertAlmostEqual(self.window._adc_gain[1], 2 / vpp_from_code_span(measured.vpp_a))
        self.assertEqual(self.window.measurement_labels[2].text(), "2.000 V")
        self.assertEqual(self.window._adc_gain[2], 1)
