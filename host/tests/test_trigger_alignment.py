"""1 MHz、200 ns/div 方波的帧间触发校正与双通道相位回归。"""

import os
import unittest
from dataclasses import replace

import numpy as np

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.config import ADC_SAMPLE_RATE_HZ
from host.core.waveform import refine_trigger_position
from host.tests.test_square_display import dual_frame
from host.tests.waveform_helpers import sampled_square_with_overshoot
from host.ui.plot_widget import PlotWidget


def triggered_square(phase: float, *, falling: bool = False):
    direction = -1 if falling else 1
    level = 2048 + 16 * direction
    a = direction * sampled_square_with_overshoot(1_000_000, 400, phase)
    b = sampled_square_with_overshoot(1_000_000, 400, phase - 5.25) * 0.6 + 0.1
    a, b = (np.rint((values + 5) / 10 * 4095).astype(np.uint16) for values in (a, b))
    relative = (a.astype(float) - level) * direction
    start = (np.flatnonzero((relative[:-1] < 0) & (relative[1:] >= 0)) + 1)[0]
    # 测试保留了触发前一点，可以直接算出交点；实际上传的帧从越阈值点开始。
    expected = -1 - relative[start - 1] / (relative[start] - relative[start - 1])
    return a[start:start + 130], b[start:start + 130], level, expected


class SquareTriggerTest(unittest.TestCase):
    def test_two_cycles_recover_rising_and_falling_subsample_trigger(self):
        for falling in (False, True):
            for phase in np.linspace(0, 1, 41, endpoint=False):
                with self.subTest(falling=falling, phase=phase):
                    samples, _, level, expected = triggered_square(phase, falling=falling)
                    before = samples.copy()
                    position = refine_trigger_position(samples, level, falling=falling)
                    self.assertIsNotNone(position)
                    self.assertAlmostEqual(position, expected, delta=0.01)
                    np.testing.assert_array_equal(samples, before)

    def test_trigger_estimate_does_not_assume_fifty_percent_duty(self):
        for duty in (0.2, 0.35, 0.7, 0.8):
            with self.subTest(duty=duty):
                source = np.where((np.arange(400) + 0.3) % 65 < duty * 65, 2800., 1200.)
                start = (np.flatnonzero((source[:-1] < 2064) & (source[1:] >= 2064)) + 1)[0]
                expected = -1 + (2064 - source[start - 1]) / (source[start] - source[start - 1])
                position = refine_trigger_position(source[start:start + 130], 2064)
                self.assertIsNotNone(position)
                self.assertAlmostEqual(position, expected, delta=1e-9)

    def test_unreliable_square_or_non_triggered_start_is_not_aligned(self):
        samples, _, level, _ = triggered_square(0.35)
        glitch = samples.copy()
        glitch[10:12] = 1200
        for values in (samples[:25], samples[8:], glitch, np.full(130, 2400), np.zeros(130)):
            with self.subTest(count=len(values), first=values[0]):
                self.assertIsNone(refine_trigger_position(values, level))

    def test_sine_alignment_remains_accurate(self):
        for phase in (0.05, 0.35, 0.75):
            source = np.rint(2048 + 600 * np.sin(2 * np.pi * (np.arange(400) + phase) / 65))
            start = (np.flatnonzero((source[:-1] < 2064) & (source[1:] >= 2064)) + 1)[0]
            expected = -1 + (2064 - source[start - 1]) / (source[start] - source[start - 1])
            position = refine_trigger_position(source[start:start + 130], 2064)
            self.assertIsNotNone(position)
            self.assertAlmostEqual(position, expected, delta=0.02)


class SquareTriggerWidgetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_reported_timebase_reduces_jitter_and_moves_both_channels_together(self):
        for channel in (1, 2):
            for falling in (False, True):
                with self.subTest(channel=channel, falling=falling):
                    widget = PlotWidget()
                    try:
                        widget.set_timebase(200e-9)
                        widget.set_trigger_alignment(channel, falling=falling)
                        before_edges, after_edges = [], []
                        for phase in np.linspace(0, 1, 21, endpoint=False):
                            a, b, _, offset = triggered_square(phase, falling=falling)
                            a, b = (a, b) if channel == 1 else (b, a)
                            frame = dual_frame(a, b, envelope=True)
                            widget.display_frame(frame, align_trigger=False)
                            curves = (widget.curve_a, widget.curve_b)
                            original = [tuple(values.copy() for values in curve.getData()) for curve in curves]
                            widget.display_frame(dual_frame(a, b, envelope=True))
                            shift = curves[channel - 1].getData()[0][0] - original[channel - 1][0][0]
                            # 重复边沿的 ADC 舍入可能相差一码；两路仍须使用完全相同的平移量。
                            self.assertAlmostEqual(shift, -offset / ADC_SAMPLE_RATE_HZ,
                                                   delta=0.01 / ADC_SAMPLE_RATE_HZ)
                            for curve, (x, y) in zip(curves, original):
                                aligned_x, aligned_y = curve.getData()
                                np.testing.assert_allclose(aligned_x, x + shift,
                                                           rtol=0, atol=1e-15)
                                np.testing.assert_array_equal(aligned_y, y)
                            x, y = original[channel - 1]
                            edges = np.flatnonzero(np.diff(y) * (-1 if falling else 1) > 0.5)
                            before_edges.append(x[edges[0]])
                            after_edges.append(curves[channel - 1].getData()[0][edges[0]])
                        # 200 ns/div：原量化抖动超过 0.04 格；校正后应小于 0.005 格。
                        self.assertGreater(float(np.ptp(before_edges)), 200e-9 * 0.04)
                        self.assertLess(float(np.ptp(after_edges)), 200e-9 * 0.005)
                    finally:
                        widget.close()

    def test_replay_and_compressed_envelope_keep_original_time_origin(self):
        a, b, _, _ = triggered_square(0.35)
        widget = PlotWidget()
        try:
            widget.set_timebase(200e-9)
            widget.set_trigger_alignment(1)
            widget.display_frame(dual_frame(a, b, envelope=True), align_trigger=False)
            self.assertEqual(widget.curve_a.getData()[0][0], 0)
            frame = dual_frame(a, b, envelope=True)
            compressed = replace(frame, header=replace(frame.header, sample_rate_hz=ADC_SAMPLE_RATE_HZ // 2))
            widget.display_frame(compressed)
            self.assertEqual(widget.curve_a.getData()[0][0], 0)
        finally:
            widget.close()


if __name__ == "__main__":
    unittest.main()
