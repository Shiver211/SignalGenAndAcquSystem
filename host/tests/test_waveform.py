from __future__ import annotations

import unittest

import numpy as np

from host.core.waveform import (
    code_to_voltage, codes_to_voltage, format_frequency_hz, format_voltage,
    fft_spectrum, gain_from_known_vpp, measure_waveform, median_filter_3,
    smooth_binomial_5, suppress_envelope_edge_overshoot,
    suppress_repeated_edge_overshoot, voltage_to_code, vpp_from_code_span,
    zero_crossing_frequency,
)
from host.tests.waveform_helpers import sampled_square_with_overshoot, square_with_overshoot


class WaveformTest(unittest.TestCase):
    def test_voltage_endpoints(self) -> None:
        volts = codes_to_voltage(np.array([0, 4095]))
        np.testing.assert_allclose(volts, [-5.0, 5.0])
        self.assertEqual(voltage_to_code(-5), 0)
        self.assertEqual(voltage_to_code(5), 4095)
        self.assertAlmostEqual(code_to_voltage(0), -5.0)
        self.assertAlmostEqual(code_to_voltage(4095), 5.0)

    def test_vpp_calibration_and_format(self) -> None:
        self.assertAlmostEqual(vpp_from_code_span(844), 844 / 4095 * 10)
        gain = gain_from_known_vpp(844, 2.0)
        self.assertAlmostEqual(vpp_from_code_span(844, gain=gain), 2.0, places=6)
        self.assertEqual(format_voltage(-1.089), "-1.089 V")
        self.assertEqual(format_voltage(2.0, peak_to_peak=True), "2.000 V")
        self.assertEqual(format_frequency_hz(10_000), "10.000 kHz")
        self.assertEqual(format_frequency_hz(50.0), "50.0 Hz")
        with self.assertRaises(ValueError):
            gain_from_known_vpp(10, 8.0)

    def test_frequency_and_fft(self) -> None:
        sample_rate = 100_000
        frequency = 1234.0
        time = np.arange(sample_rate) / sample_rate
        signal = 1.5 * np.sin(2 * np.pi * frequency * time) + 0.2
        measured = zero_crossing_frequency(signal, sample_rate)
        self.assertAlmostEqual(measured, frequency, delta=0.05)
        frequencies, magnitude = fft_spectrum(signal, sample_rate)
        peak = frequencies[np.argmax(magnitude[1:]) + 1]
        self.assertAlmostEqual(peak, frequency, delta=1.0)
        result = measure_waveform(signal, sample_rate)
        self.assertAlmostEqual(result.vpp_v, 3.0, delta=0.01)

    def test_three_point_median_removes_isolated_spike(self) -> None:
        np.testing.assert_allclose(
            median_filter_3(np.array([0, 0, 100, 0, 0])),
            [0, 0, 0, 0, 0],
        )
        np.testing.assert_allclose(
            median_filter_3(np.array([0, 1, 2, 3, 2, 1, 0])),
            [0, 1, 2, 3, 2, 1, 0],
        )
        np.testing.assert_allclose(
            median_filter_3(np.arange(5)),
            np.arange(5),
        )
        for values in ([], [1], [1, 2]):
            np.testing.assert_allclose(median_filter_3(np.array(values)), values)

    def test_binomial_smoothing_reduces_alternating_jitter(self) -> None:
        source = np.array([0.0, 1.0, -1.0, 1.0, -1.0, 1.0, 0.0])
        result = smooth_binomial_5(source)
        self.assertLess(float(np.max(np.abs(result[2:-2]))), 0.5)
        self.assertEqual(result.shape, source.shape)

    def test_repeated_overshoot_is_removed_without_moving_edges(self) -> None:
        source = square_with_overshoot()
        original = source.copy()
        result = suppress_repeated_edge_overshoot(source)
        self.assertAlmostEqual(float(result.max()), 1.0)
        self.assertAlmostEqual(float(result.min()), -1.0)
        np.testing.assert_array_equal(source, original)
        np.testing.assert_array_equal(result[np.abs(source) <= 1.0],
                                      source[np.abs(source) <= 1.0])
        self.assertEqual(zero_crossing_frequency(result, 65_000_000),
                         zero_crossing_frequency(source, 65_000_000))

    def test_plateau_glitches_and_narrow_pulses_are_preserved(self) -> None:
        source = square_with_overshoot()
        source[30] = 1.6  # 高平台正毛刺。
        source[134] = -1.5  # 低平台负毛刺。
        source[220:222] = -1.0  # 高平台中跨过阈值的窄脉冲。
        source[388:390] = 1.0  # 低平台中跨过阈值的窄脉冲。
        result = suppress_repeated_edge_overshoot(source)
        np.testing.assert_array_equal(result[[30, 134, 220, 221, 388, 389]],
                                      source[[30, 134, 220, 221, 388, 389]])
        self.assertEqual(result[81], 1.0)
        self.assertEqual(result[113], -1.0)

    def test_exceptional_glitch_next_to_edge_is_preserved(self) -> None:
        source = square_with_overshoot()
        source[83] = 1.8  # 单个上升沿后的异常尖峰，不能跟着模板限幅。
        source[115] = -1.7
        result = suppress_repeated_edge_overshoot(source)
        np.testing.assert_array_equal(result[80:86], source[80:86])
        np.testing.assert_array_equal(result[112:118], source[112:118])
        self.assertEqual(result[17], 1.0)
        self.assertEqual(result[49], -1.0)

    def test_unconfirmed_waveforms_keep_original_samples(self) -> None:
        phase = np.arange(640, dtype=np.float64) / 64
        signals = (
            np.sin(2 * np.pi * phase),
            4 * np.abs(phase % 1 - 0.5) - 1,
            square_with_overshoot()[:100],  # 同方向边沿不足三次。
            np.array([0, 0, 1, 0, 0], dtype=float),
            np.full(100, 2.0),
        )
        for source in signals:
            with self.subTest(length=len(source), start=source[0]):
                np.testing.assert_array_equal(
                    suppress_repeated_edge_overshoot(source), source,
                )

    def test_plateau_noise_is_preserved(self) -> None:
        source = square_with_overshoot()
        source += np.random.default_rng(3).normal(0, 0.002, source.size)
        result = suppress_repeated_edge_overshoot(source)
        plateau = (np.arange(source.size) - 16) % 32 >= 6
        np.testing.assert_array_equal(result[plateau], source[plateau])
        self.assertLess(result.max(), 1.02)
        self.assertGreater(result.min(), -1.02)

    def test_overshoot_suppression_with_fractional_sample_periods(self) -> None:
        for frequency in (500_000, 600_000, 800_000, 1_000_000):
            for phase in (0.1, 0.35, 0.7):
                with self.subTest(frequency=frequency, phase=phase):
                    source = sampled_square_with_overshoot(frequency, phase_samples=phase)
                    result = suppress_repeated_edge_overshoot(source)
                    # 排除首尾没有完整平台的边沿；比较过冲总量而非某一个峰。
                    before = np.maximum(np.abs(source[12:-12]) - 1, 0).sum()
                    after = np.maximum(np.abs(result[12:-12]) - 1, 0).sum()
                    self.assertLess(after, before * 0.25)
                    np.testing.assert_array_equal(result[np.abs(source) <= 1],
                                                  source[np.abs(source) <= 1])

    def test_fractional_phase_keeps_independent_and_edge_glitches(self) -> None:
        for frequency in (600_000, 800_000):
            with self.subTest(frequency=frequency):
                source = sampled_square_with_overshoot(frequency, 2600, 0.35)
                edges = np.flatnonzero((source[1:] > 0) != (source[:-1] > 0)) + 1
                glitches = (edges[2] + 10, edges[3] + 10, edges[6] + 2)
                for index in glitches:
                    source[index] += np.sign(source[index]) * 0.8
                result = suppress_repeated_edge_overshoot(source)
                np.testing.assert_array_equal(result[list(glitches)], source[list(glitches)])
                np.testing.assert_array_equal(result[edges[6]:edges[6] + 6],
                                              source[edges[6]:edges[6] + 6])
                self.assertGreater(np.count_nonzero(result != source), 30)

    def test_compressed_sine_and_unresolved_square_keep_extrema(self) -> None:
        for frequency in (10_000, 100_000, 1_000_000, 4_000_000):
            source = np.sin(2 * np.pi * np.arange(13000) * frequency / 65_000_000)
            for bucket in (2, 4, 7, 16):
                with self.subTest(frequency=frequency, bucket=bucket):
                    offsets = np.arange(0, len(source), bucket)
                    lo, hi = np.minimum.reduceat(source, offsets), np.maximum.reduceat(source, offsets)
                    actual_lo, actual_hi = suppress_envelope_edge_overshoot(lo, hi, bucket)
                    np.testing.assert_array_equal(actual_lo, lo)
                    np.testing.assert_array_equal(actual_hi, hi)
        # 每桶已经包含完整周期，没有平台和边沿信息，不能凭空削平极值。
        source = square_with_overshoot()
        offsets = np.arange(0, len(source), 64)
        lo, hi = np.minimum.reduceat(source, offsets), np.maximum.reduceat(source, offsets)
        actual_lo, actual_hi = suppress_envelope_edge_overshoot(lo, hi, 64)
        np.testing.assert_array_equal(actual_lo, lo)
        np.testing.assert_array_equal(actual_hi, hi)


if __name__ == "__main__":
    unittest.main()
