from __future__ import annotations

import unittest

import numpy as np

from host.core.waveform import (
    codes_to_voltage, fft_spectrum, measure_waveform, voltage_to_code,
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


if __name__ == "__main__":
    unittest.main()
