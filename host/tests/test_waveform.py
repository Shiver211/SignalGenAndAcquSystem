from __future__ import annotations

import unittest

import numpy as np

from host.core.waveform import (
    codes_to_voltage, fft_spectrum, measure_waveform, median_filter_3,
    smooth_binomial_5, voltage_to_code,
    zero_crossing_frequency,
)


class WaveformTest(unittest.TestCase):
    def test_voltage_endpoints(self) -> None:
        volts = codes_to_voltage(np.array([0, 4095]))
        np.testing.assert_allclose(volts, [-5.0, 5.0])
        self.assertEqual(voltage_to_code(-5), 0)
        self.assertEqual(voltage_to_code(5), 4095)

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


if __name__ == "__main__":
    unittest.main()
