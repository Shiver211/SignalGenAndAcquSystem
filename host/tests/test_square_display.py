"""方波显示：竖直完整跳变、小抖动保留、大异常剔除。"""

import os
import unittest

import numpy as np

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.config import ADC_SAMPLE_RATE_HZ, MAX_ENVELOPE_POINTS
from host.core.waveform import codes_to_voltage, fft_spectrum, idealize_square_display
from host.tests.waveform_helpers import sampled_square_with_overshoot
from host.ui.plot_widget import PlotWidget


def noisy_square(frequency: int, count: int, phase: float = 0.35) -> np.ndarray:
    values = sampled_square_with_overshoot(frequency, count, phase)
    values += np.random.default_rng(5).uniform(-0.006, 0.006, count)
    # 顶部尖峰、底部下冲以及跨阈值的窄毛刺；均远离主边沿。
    edges = np.flatnonzero((values[:-1] > 0) != (values[1:] > 0)) + 1
    for edge in edges[1:4]:
        index = edge + 10
        values[index] += np.sign(values[index]) * 0.7
    if len(edges) > 4:
        index = edges[4] + 10
        values[index:index + 2] = -np.sign(values[index])
    return values


class IdealSquareTest(unittest.TestCase):
    def test_single_vertical_transition_and_small_jitter(self) -> None:
        for frequency in (500_000, 600_000, 800_000, 1_000_000):
            for phase in (0.1, 0.35, 0.7):
                with self.subTest(frequency=frequency, phase=phase):
                    count = 1300
                    original = sampled_square_with_overshoot(frequency, count, phase)
                    source = noisy_square(frequency, count, phase)
                    time = np.arange(count) / ADC_SAMPLE_RATE_HZ
                    before = source.copy()
                    result = idealize_square_display(time, source)
                    self.assertIsNotNone(result)
                    x, y = result
                    np.testing.assert_array_equal(source, before)
                    self.assertLessEqual(float(np.abs(y).max()), 1.045)
                    jumps = np.flatnonzero(np.abs(np.diff(y)) > 0.5)
                    self.assertGreater(len(jumps), 5)
                    np.testing.assert_array_equal(x[jumps], x[jumps + 1])
                    expected_edges = np.flatnonzero((original[:-1] > 0) != (original[1:] > 0)) + 1
                    np.testing.assert_equal(len(jumps), len(expected_edges))
                    # 除被补入的竖线端点外，每个采样时刻只保留一个平台值。
                    clean_at_samples = y[np.searchsorted(x, time)]
                    plateau = ((np.abs(original) == 1) & (np.abs(np.abs(source) - 1) < 0.015)
                               & (np.sign(source) == np.sign(original)))
                    np.testing.assert_allclose(clean_at_samples[plateau], source[plateau])
                    self.assertGreater(float(np.std(clean_at_samples[plateau] - np.sign(source[plateau]))), 0.002)
                    np.testing.assert_allclose(x[jumps], time[expected_edges], atol=1 / ADC_SAMPLE_RATE_HZ)

    def test_non_square_waveforms_and_unresolved_envelopes_are_untouched(self) -> None:
        time = np.arange(650) / ADC_SAMPLE_RATE_HZ
        phase = np.arange(650) / 65
        signals = (np.sin(2 * np.pi * phase), 4 * np.abs(phase % 1 - 0.5) - 1,
                   np.linspace(0, 1, 650), np.zeros(650))
        for values in signals:
            self.assertIsNone(idealize_square_display(time, values))
        self.assertIsNone(idealize_square_display(time, np.full(650, -1.2), np.full(650, 1.2)))

    def test_period_and_duty_cycle_are_not_replaced_by_fifty_percent(self) -> None:
        time = np.arange(1300) / ADC_SAMPLE_RATE_HZ
        for duty in (0.2, 0.35, 0.7, 0.8):
            source = np.where((np.arange(1300) % 100) < duty * 100, 1.0, -1.0)
            result = idealize_square_display(time, source)
            self.assertIsNotNone(result)
            x, y = result
            rising = x[:-1][np.diff(y) > 1]
            falling = x[:-1][np.diff(y) < -1]
            np.testing.assert_allclose(np.diff(rising), 100 / ADC_SAMPLE_RATE_HZ)
            widths = falling[1:] - rising
            np.testing.assert_allclose(widths, duty * 100 / ADC_SAMPLE_RATE_HZ)


class IdealSquareWidgetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_raw_envelope_and_both_channels_use_ideal_display(self) -> None:
        for frequency in (500_000, 600_000, 800_000, 1_000_000):
            for timebase in (500e-9, 1e-6, 5e-6, 10e-6, 20e-6, 50e-6):
                for channel_mask in (1, 2, 3):
                    with self.subTest(frequency=frequency, timebase=timebase, mask=channel_mask):
                        count = int(np.ceil(ADC_SAMPLE_RATE_HZ * timebase * 10))
                        # 超短窗口的周期较少，毛刺验证由更长窗口覆盖。
                        source = (noisy_square(frequency, count) if count >= 650 else
                                  sampled_square_with_overshoot(frequency, count))
                        codes = np.rint((source + 5) / 10 * 4095).astype(np.uint16)
                        bucket = int(np.ceil(count / MAX_ENVELOPE_POINTS))
                        offsets = np.arange(0, count, bucket)
                        lo, hi = np.minimum.reduceat(codes, offsets), np.maximum.reduceat(codes, offsets)
                        payload = np.column_stack((lo, hi, lo, hi) if channel_mask == 3 else (lo, hi)).astype('<u2').tobytes()
                        frame = CompletedFrame(
                            PacketHeader(1, 2, 1, len(lo), ADC_SAMPLE_RATE_HZ // bucket, 0,
                                         channel_mask, SampleFormat.ENVELOPE64 if channel_mask == 3 else SampleFormat.ENVELOPE32,
                                         0, 0, len(payload), 0), payload,
                        )
                        self._check_frame(frame, timebase)
                        if timebase == 1e-6:
                            raw_payload = ((codes.astype('<u4') | (codes.astype('<u4') << 12)).tobytes()
                                           if channel_mask == 3 else codes.astype('<u2').tobytes())
                            raw = CompletedFrame(
                                PacketHeader(1, 1, 2, count, ADC_SAMPLE_RATE_HZ, 0, channel_mask,
                                             SampleFormat.RAW32 if channel_mask == 3 else SampleFormat.RAW16,
                                             0, 0, len(raw_payload), 0), raw_payload,
                            )
                            self._check_frame(raw, timebase)

    def _check_frame(self, frame: CompletedFrame, timebase: float) -> None:
        widget = PlotWidget()
        try:
            widget.set_timebase(timebase)
            widget.display_frame(frame)
            for channel, curve, minimum, maximum, fill in (
                (1, widget.curve_a, widget.min_a, widget.max_a, widget.fill_a),
                (2, widget.curve_b, widget.min_b, widget.max_b, widget.fill_b),
            ):
                if not frame.header.channel_mask & (1 << (channel - 1)):
                    self.assertFalse(curve.isVisible())
                    continue
                x, y = curve.getData()
                self.assertIsNone(curve.opts['stepMode'])
                self.assertTrue(np.all(np.diff(x) >= 0))
                self.assertLessEqual(float(np.abs(y).max()), 1.045)
                jumps = np.abs(np.diff(y)) > 0.5
                self.assertGreater(np.count_nonzero(jumps), 2)
                np.testing.assert_array_equal(np.diff(x)[jumps], 0)
                self.assertFalse(minimum.isVisible())
                self.assertFalse(maximum.isVisible())
                self.assertFalse(fill.isVisible())
            self.assertIs(widget._last_frame, frame)
        finally:
            widget.close()

    def test_sine_and_fft_preserve_original_samples_after_square(self) -> None:
        widget = PlotWidget()
        try:
            source = noisy_square(1_000_000, 650)
            codes = np.rint((source + 5) / 10 * 4095).astype('<u4')
            payload = (codes | (codes << 12)).tobytes()
            frame = CompletedFrame(PacketHeader(1, 1, 1, 650, ADC_SAMPLE_RATE_HZ, 0, 3,
                                                SampleFormat.RAW32, 0, 0, len(payload), 0), payload)
            widget.set_timebase(1e-6)
            widget.display_frame(frame)
            widget.set_fft_enabled(True)
            expected_x, expected_y = fft_spectrum(codes_to_voltage(codes), ADC_SAMPLE_RATE_HZ)
            np.testing.assert_array_equal(widget.curve_a.getData()[0], expected_x)
            np.testing.assert_array_equal(widget.curve_a.getData()[1], expected_y)
            widget.set_fft_enabled(False)
            self.assertGreater(len(widget.curve_a.getData()[0]), 650)
            sine = np.rint((np.sin(2 * np.pi * np.arange(650) / 65) + 5) / 10 * 4095).astype('<u4')
            payload = (sine | (sine << 12)).tobytes()
            frame = CompletedFrame(frame.header, payload)
            widget.display_frame(frame)
            np.testing.assert_array_equal(widget.curve_a.getData()[1], codes_to_voltage(sine))
        finally:
            widget.close()

    def test_envelope_mixed_channels_scale_and_return_to_sine(self) -> None:
        count, bucket = 3250, 2
        square = noisy_square(1_000_000, count)
        sine = np.sin(2 * np.pi * np.arange(count) * 800_000 / ADC_SAMPLE_RATE_HZ)
        a = np.rint((square + 5) / 10 * 4095).astype(np.uint16)
        b = np.rint((sine + 5) / 10 * 4095).astype(np.uint16)
        offsets = np.arange(0, count, bucket)
        amin, amax = np.minimum.reduceat(a, offsets), np.maximum.reduceat(a, offsets)
        bmin, bmax = np.minimum.reduceat(b, offsets), np.maximum.reduceat(b, offsets)
        payload = np.column_stack((amin, amax, bmin, bmax)).astype('<u2').tobytes()
        frame = CompletedFrame(PacketHeader(1, 2, 1, len(offsets), ADC_SAMPLE_RATE_HZ // bucket, 0, 3,
                                            SampleFormat.ENVELOPE64, 0, 0, len(payload), 0), payload)
        widget = PlotWidget()
        try:
            widget.set_timebase(5e-6)
            widget.display_frame(frame)
            self.assertFalse(widget.fill_a.isVisible())
            self.assertTrue(widget.fill_b.isVisible())
            x, before = (v.copy() for v in widget.curve_a.getData())
            widget.set_volts_per_div(1, 0.5)
            widget.set_vertical_position_div(1, 0.25)
            np.testing.assert_allclose(widget.curve_a.getData()[1], before * 2 + 0.25)
            np.testing.assert_array_equal(widget.curve_a.getData()[0], x)
            np.testing.assert_allclose(widget.curve_b.getData()[1],
                                       codes_to_voltage((bmin.astype(float) + bmax) / 2))
            payload = np.column_stack((bmin, bmax, bmin, bmax)).astype('<u2').tobytes()
            widget.display_frame(CompletedFrame(frame.header, payload))
            self.assertTrue(widget.fill_a.isVisible())
            expected_min = codes_to_voltage(bmin) * 2 + 0.25
            expected_center = codes_to_voltage((bmin.astype(float) + bmax) / 2) * 2 + 0.25
            span_div = (codes_to_voltage(bmax) - codes_to_voltage(bmin)) / 0.5
            visible = span_div >= widget._ENVELOPE_BAND_DIVISIONS
            min_a = widget.min_a.getData()[1]
            np.testing.assert_allclose(min_a[visible], expected_min[visible])
            np.testing.assert_allclose(min_a[~visible], expected_center[~visible])
        finally:
            widget.close()
