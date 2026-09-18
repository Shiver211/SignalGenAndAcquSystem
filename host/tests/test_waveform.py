from __future__ import annotations

import unittest

import numpy as np

from host.core.waveform import (
    code_to_voltage, codes_to_voltage, format_frequency_hz, format_voltage,
    fft_spectrum, gain_from_known_vpp, measure_waveform, median_filter_3,
    smooth_binomial_5, voltage_to_code, vpp_from_code_span,
    zero_crossing_frequency,
)


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


if __name__ == "__main__":
    unittest.main()
