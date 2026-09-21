"""双通道显示平滑：噪声、幅相、数据格式及原始数据隔离。"""

import os
import unittest

import numpy as np

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.config import ADC_SAMPLE_RATE_HZ
from host.core.waveform import codes_to_voltage, fft_spectrum, smooth_continuous_display
from host.ui.plot_widget import PlotWidget


def make_frame(a, b, *, envelope=False, mask=3, half_span=0):
    if envelope:
        columns = ((a - half_span, a + half_span, b - half_span, b + half_span)
                   if mask == 3 else ((a - half_span, a + half_span) if mask == 1
                                     else (b - half_span, b + half_span)))
        payload = np.column_stack(columns).astype("<u2").tobytes()
        sample_format = SampleFormat.ENVELOPE64 if mask == 3 else SampleFormat.ENVELOPE32
    else:
        payload = ((a.astype("<u4") | (b.astype("<u4") << 12)).tobytes() if mask == 3
                   else (a if mask == 1 else b).astype("<u2").tobytes())
        sample_format = SampleFormat.RAW32 if mask == 3 else SampleFormat.RAW16
    return CompletedFrame(
        PacketHeader(1, 2 if envelope else 1, 1, len(a), ADC_SAMPLE_RATE_HZ,
                     0, mask, sample_format, 0, 0, len(payload), 0), payload,
    )


class ContinuousSmoothingTest(unittest.TestCase):
    def test_500khz_noise_reduction_at_500ns_per_div(self):
        time = np.arange(325) / ADC_SAMPLE_RATE_HZ
        for phase in (0.0, 0.8, 2.5, 4.8):
            with self.subTest(phase=phase):
                clean = np.sin(2 * np.pi * 500_000 * time + phase)
                source = clean + np.random.default_rng(21).normal(0, 0.008, len(time))
                original = source.copy()
                result = smooth_continuous_display(source, ADC_SAMPLE_RATE_HZ)
                before_rms = np.std(source[2:-2] - clean[2:-2])
                after_rms = np.std(result[2:-2] - clean[2:-2])
                self.assertLess(after_rms, before_rms * 0.65)
                np.testing.assert_array_equal(source, original)
                np.testing.assert_array_equal(result[[0, 1, -2, -1]], source[[0, 1, -2, -1]])

    def test_sine_amplitude_and_phase(self):
        time = np.arange(1300) / ADC_SAMPLE_RATE_HZ
        for frequency in (500_000, 800_000, 1_000_000, 2_000_000, 4_000_000):
            with self.subTest(frequency=frequency):
                phase = 2 * np.pi * frequency * time
                source = 0.2 + np.sin(phase)
                result = smooth_continuous_display(source, ADC_SAMPLE_RATE_HZ)
                basis = np.column_stack((np.sin(phase), np.cos(phase), np.ones(len(time))))
                sine, cosine, offset = np.linalg.lstsq(basis[10:-10], result[10:-10], rcond=None)[0]
                self.assertGreater(sine, 0.995)
                self.assertLess(sine, 1.0)
                self.assertAlmostEqual(cosine, 0.0, places=12)
                self.assertAlmostEqual(offset, 0.2, places=12)

    def test_low_frequencies_edges_and_incomplete_periods_are_bypassed(self):
        time = np.arange(650) / ADC_SAMPLE_RATE_HZ
        sine = np.sin(2 * np.pi * 500_000 * time)
        pulse = sine.copy()
        pulse[300] += 0.8
        signals = [
            np.array([]), np.zeros(100), sine[:50], np.linspace(-1, 1, 325),
            np.sin(2 * np.pi * 100_000 * time),
            np.sin(2 * np.pi * 400_000 * time),
            np.sin(2 * np.pi * 490_000 * time),
            np.sin(2 * np.pi * 16_000_000 * time),
            np.where(sine >= 0, 1.0, -1.0), pulse,
        ]
        for index, source in enumerate(signals):
            with self.subTest(signal=index):
                np.testing.assert_array_equal(
                    smooth_continuous_display(source, ADC_SAMPLE_RATE_HZ), source,
                )

    def test_peak_and_valley_jitter_above_one_mhz(self):
        for frequency, limit in ((1_000_000, 0.6), (2_000_000, 0.7), (4_000_000, 0.85)):
            with self.subTest(frequency=frequency):
                clean = np.sin(2 * np.pi * np.arange(1300) * frequency / ADC_SAMPLE_RATE_HZ)
                source = clean + np.random.default_rng(21).normal(0, 0.012, len(clean))
                result = smooth_continuous_display(source, ADC_SAMPLE_RATE_HZ)
                interior = (np.arange(len(clean)) >= 10) & (np.arange(len(clean)) < len(clean) - 10)
                for peak in (clean > 0.9, clean < -0.9):
                    region = peak & interior
                    before = np.sqrt(np.mean((source[region] - clean[region]) ** 2))
                    after = np.sqrt(np.mean((result[region] - clean[region]) ** 2))
                    self.assertLess(after, before * limit)

    def test_frequency_gate_uses_actual_frame_rate(self):
        source = np.sin(2 * np.pi * np.arange(650) / 65)
        source += np.random.default_rng(21).normal(0, 0.008, len(source))
        # 相同离散周期在抽桶后只代表 100 kHz，在双通道/交织帧中是 1/2 MHz。
        np.testing.assert_array_equal(smooth_continuous_display(source, 6_500_000), source)
        for rate in (65_000_000, 130_000_000):
            with self.subTest(rate=rate):
                self.assertFalse(np.array_equal(smooth_continuous_display(source, rate), source))


class DisplaySmoothingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def setUp(self):
        self.widget = PlotWidget()
        self.widget.set_timebase(500e-9)
        self.clean = np.sin(2 * np.pi * np.arange(325) / 130)
        rng = np.random.default_rng(12)
        self.codes = [np.rint((self.clean + rng.normal(0, noise, 325) + 5) * 409.5).astype(np.uint16)
                      for noise in (0.004, 0.012)]

    def tearDown(self):
        self.widget.close()

    def test_raw_and_envelope_smooth_both_channels_and_single_channel_formats(self):
        for envelope in (False, True):
            for mask in (1, 2, 3):
                with self.subTest(envelope=envelope, mask=mask):
                    frame = make_frame(*self.codes, envelope=envelope, mask=mask)
                    original = frame.payload
                    self.widget.display_frame(frame)
                    for channel, curve in ((1, self.widget.curve_a), (2, self.widget.curve_b)):
                        if not mask & (1 << (channel - 1)):
                            self.assertFalse(curve.isVisible())
                            continue
                        time, volts = curve.getData()
                        raw = codes_to_voltage(self.codes[channel - 1])
                        np.testing.assert_allclose(time, np.arange(325) / ADC_SAMPLE_RATE_HZ)
                        self.assertLess(np.std(volts[2:-2] - self.clean[2:-2]),
                                        np.std(raw[2:-2] - self.clean[2:-2]) * 0.7)
                    self.assertEqual(frame.payload, original)

    def test_identical_inputs_remain_identical_with_independent_display_scales(self):
        for envelope in (False, True):
            with self.subTest(envelope=envelope):
                self.widget.set_adc_calibration(1, 0.98, 0.02)
                self.widget.set_adc_calibration(2, 1.02, -0.01)
                self.widget.set_volts_per_div(1, 0.5)
                self.widget.set_volts_per_div(2, 1.0)
                self.widget.set_vertical_position_div(1, 0.4)
                self.widget.set_vertical_position_div(2, -0.4)
                self.widget.display_frame(make_frame(self.codes[1], self.codes[1], envelope=envelope))
                x_a, a = self.widget.curve_a.getData()
                x_b, b = self.widget.curve_b.getData()
                np.testing.assert_array_equal(x_a, x_b)
                np.testing.assert_allclose(((a - 0.4) * 0.5 - 0.02) / 0.98,
                                           ((b + 0.4) + 0.01) / 1.02, atol=1e-12)

    def test_low_channel_is_unchanged_while_one_mhz_channel_is_smoothed(self):
        time = np.arange(3250) / ADC_SAMPLE_RATE_HZ
        rng = np.random.default_rng(21)
        clean_b = np.sin(2 * np.pi * 1_000_000 * time)
        a = np.rint((5 + np.sin(2 * np.pi * 100_000 * time)
                     + rng.normal(0, 0.012, len(time))) * 409.5).astype(np.uint16)
        b = np.rint((5 + clean_b + rng.normal(0, 0.012, len(time))) * 409.5).astype(np.uint16)
        self.widget.set_timebase(5e-6)
        for envelope in (False, True):
            with self.subTest(envelope=envelope):
                self.widget.display_frame(make_frame(a, b, envelope=envelope))
                np.testing.assert_array_equal(self.widget.curve_a.getData()[1], codes_to_voltage(a))
                shown_b = self.widget.curve_b.getData()[1]
                self.assertLess(np.std(shown_b[10:-10] - clean_b[10:-10]),
                                np.std(codes_to_voltage(b)[10:-10] - clean_b[10:-10]) * 0.6)

    def test_envelope_extrema_and_raw_fft_are_unchanged(self):
        frame = make_frame(*self.codes, envelope=True, half_span=30)
        self.widget.display_frame(frame)
        for codes, minimum, maximum in (
            (self.codes[0], self.widget.min_a, self.widget.max_a),
            (self.codes[1], self.widget.min_b, self.widget.max_b),
        ):
            self.assertTrue(minimum.isVisible())
            np.testing.assert_array_equal(minimum.getData()[1], codes_to_voltage(codes - 30))
            np.testing.assert_array_equal(maximum.getData()[1], codes_to_voltage(codes + 30))

        raw = make_frame(*self.codes)
        self.widget.display_frame(raw)
        before = [curve.getData()[1].copy() for curve in (self.widget.curve_a, self.widget.curve_b)]
        self.widget.set_fft_enabled(True)
        for codes, curve in zip(self.codes, (self.widget.curve_a, self.widget.curve_b)):
            expected_x, expected_y = fft_spectrum(codes_to_voltage(codes), ADC_SAMPLE_RATE_HZ)
            np.testing.assert_array_equal(curve.getData()[0], expected_x)
            np.testing.assert_array_equal(curve.getData()[1], expected_y)
        self.widget.set_fft_enabled(False)
        for expected, curve in zip(before, (self.widget.curve_a, self.widget.curve_b)):
            np.testing.assert_array_equal(curve.getData()[1], expected)


if __name__ == "__main__":
    unittest.main()
