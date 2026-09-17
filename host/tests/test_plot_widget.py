from __future__ import annotations

import os
import struct
import unittest

import numpy as np

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.core.waveform import codes_to_voltage, zero_crossing_frequency
from host.config import ADC_SAMPLE_RATE_HZ, MAX_ENVELOPE_POINTS
from host.tests.waveform_helpers import sampled_square_with_overshoot, square_with_overshoot
from host.ui.plot_widget import ChannelDisplayMode, PlotWidget


def raw_frame(words: np.ndarray, *, sample_rate: int = 1_000, trigger_index: int = 0) -> CompletedFrame:
    payload = np.asarray(words, dtype="<u4").tobytes()
    return CompletedFrame(
        PacketHeader(
            1, 1, 7, len(words), sample_rate, trigger_index, 3,
            SampleFormat.RAW32, 0, 0, len(payload), 0,
        ),
        payload,
    )


class PlotWidgetTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def make_widget(self) -> PlotWidget:
        return PlotWidget()

    def test_fixed_scope_grid_and_time_div(self) -> None:
        widget = self.make_widget()
        try:
            widget.set_timebase(2e-3)
            x_range, y_range = widget.plot.viewRange()
            self.assertEqual(x_range, [0.0, 2e-2])
            self.assertEqual(y_range, [-4.0, 4.0])
            self.assertEqual(widget.grid_item.opts["tickSpacing"], ([2e-3], [1.0]))
            self.assertIsNone(widget.grid_item.opts["textPen"])
            self.assertFalse(widget.plot.getAxis("left").isVisible())
            self.assertFalse(widget.plot.getAxis("bottom").isVisible())
        finally:
            widget.close()

    def test_channel_mode_and_independent_scale(self) -> None:
        widget = self.make_widget()
        try:
            widget.set_channel_mode(ChannelDisplayMode.CH1)
            self.assertTrue(widget.curve_a.isVisible())
            self.assertFalse(widget.curve_b.isVisible())
            widget.set_channel_mode("BOTH")
            self.assertTrue(widget.curve_b.isVisible())

            words = np.array([0x0000_0800, 0x0000_1800], dtype="<u4")
            widget.display_frame(raw_frame(words))
            before = widget.curve_a.getData()[1].copy()
            widget.set_volts_per_div(1, 2.0)
            after = widget.curve_a.getData()[1]
            np.testing.assert_allclose(after, before / 2.0)
            widget.set_vertical_position(1, -1.0)
            np.testing.assert_allclose(widget.curve_a.getData()[1], before / 2.0 - 0.5)
        finally:
            widget.close()

    def test_adc_calibration_scales_displayed_volts(self) -> None:
        widget = self.make_widget()
        try:
            words = np.array([2444 | (2048 << 12)], dtype="<u4")
            widget.display_frame(raw_frame(words))
            before = widget.curve_a.getData()[1].copy()
            widget.set_adc_calibration(1, gain=0.5)
            np.testing.assert_allclose(widget.curve_a.getData()[1], before * 0.5)
        finally:
            widget.close()

    def test_trigger_index_is_time_zero(self) -> None:
        widget = self.make_widget()
        try:
            widget.display_frame(raw_frame(np.array([0x800, 0x900, 0xA00], dtype="<u4"),
                                           sample_rate=1_000, trigger_index=1))
            x = widget.curve_a.getData()[0]
            np.testing.assert_allclose(x, [-1e-3, 0.0, 1e-3])
            self.assertAlmostEqual(widget.trigger_line.value(), 0.0)
            self.assertTrue(widget.trigger_line.isVisible())
            self.assertEqual(widget.plot.viewRange()[0], [-5e-3, 5e-3])
        finally:
            widget.close()

    def test_envelope_draws_one_centerline_per_channel(self) -> None:
        widget = self.make_widget()
        try:
            # min/max A/B = 0x700/0x900, 0x600/0xA00
            payload = struct.pack("<HHHH", 0x700, 0x900, 0x600, 0xA00)
            frame = CompletedFrame(
                PacketHeader(1, 2, 1, 1, 1000, 0, 3, SampleFormat.ENVELOPE64,
                             0, 0, len(payload), 0), payload,
            )
            widget.set_volts_per_div(2, 2.0)
            widget.display_frame(frame)
            expected_a = ((0x700 + 0x900) / 2 / 4095 * 10 - 5)
            expected_b = ((0x600 + 0xA00) / 2 / 4095 * 10 - 5) / 2
            self.assertAlmostEqual(float(widget.curve_a.getData()[1][0]),
                                   expected_a)
            self.assertAlmostEqual(float(widget.curve_b.getData()[1][0]),
                                   expected_b)
            self.assertTrue(widget.curve_a.isVisible())
            self.assertTrue(widget.curve_b.isVisible())
            self.assertTrue(widget.trigger_line.isVisible())
            self.assertTrue(widget.min_a.isVisible())
            self.assertTrue(widget.max_a.isVisible())
            self.assertTrue(widget.fill_a.isVisible())
            self.assertTrue(widget.fill_b.isVisible())
            widget.set_channel_mode("CH2")
            self.assertFalse(widget.min_a.isVisible())
            self.assertFalse(widget.max_a.isVisible())
            self.assertTrue(widget.curve_b.isVisible())
            self.assertFalse(widget.curve_a.isVisible())
        finally:
            widget.close()

    def test_short_envelope_fills_current_timebase_without_frequency_change(self) -> None:
        widget = self.make_widget()
        try:
            widget.set_timebase(2e-3)
            payload = struct.pack(
                "<" + "H" * (2 * 4),
                0x700, 0x900, 0x600, 0xA00,
                0x600, 0xA00, 0x700, 0x900,
            )
            # 旧帧短于新窗口时保持真实采样间隔，不能拉伸或重复伪造频率。
            frame = CompletedFrame(
                PacketHeader(1, 2, 1, 2, 200, 0, 3, SampleFormat.ENVELOPE64,
                             0, 0, len(payload), 0), payload,
            )
            widget.display_frame(frame)
            x = widget.curve_a.getData()[0]
            np.testing.assert_allclose(x, [0.0, 0.005])
            self.assertEqual(widget.plot.viewRange()[0], [0.0, 2e-2])
        finally:
            widget.close()

    def test_envelope_display_preserves_isolated_center_spike(self) -> None:
        widget = self.make_widget()
        try:
            centers = [0x800, 0x800, 0xF00, 0x800, 0x800]
            payload = b"".join(
                struct.pack("<HHHH", value, value, 0x800, 0x800)
                for value in centers
            )
            frame = CompletedFrame(
                PacketHeader(1, 2, 4, len(centers), 500, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 0),
                payload,
            )
            widget.set_timebase(1e-3)
            widget.display_frame(frame)
            y = widget.curve_a.getData()[1]
            self.assertGreater(float(y[2]), float(y[1]))
            self.assertGreater(float(widget.max_a.getData()[1][2]),
                               float(widget.max_a.getData()[1][1]))
            self.assertEqual(len(widget.curve_a.getData()[0]), len(y))
        finally:
            widget.close()

    def test_four_mhz_sine_keeps_period_at_full_sample_rate(self) -> None:
        widget = self.make_widget()
        try:
            sample_rate = 65_000_000
            count = 650
            time = np.arange(count, dtype=np.float64) / sample_rate
            codes = np.clip(
                np.round((np.sin(2 * np.pi * 4_000_000 * time) + 1.0) * 2047.5),
                0, 4095,
            ).astype(np.uint16)
            payload = b"".join(
                struct.pack("<HHHH", int(code), int(code), 2048, 2048)
                for code in codes
            )
            frame = CompletedFrame(
                PacketHeader(1, 2, 6, count, sample_rate, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 0),
                payload,
            )
            widget.set_timebase(1e-6)
            widget.display_frame(frame)
            y = widget.curve_a.getData()[1]
            volts = y * widget.volts_per_div(1)
            frequency = zero_crossing_frequency(volts, sample_rate)
            self.assertGreater(frequency, 3.9e6)
            self.assertLess(frequency, 4.1e6)
            np.testing.assert_allclose(
                volts, codes_to_voltage(codes), atol=0.02,
            )
            self.assertFalse(widget.min_a.isVisible())
            self.assertFalse(widget.max_a.isVisible())
            self.assertFalse(widget.fill_a.isVisible())
        finally:
            widget.close()

    def test_ten_khz_envelope_draws_a_min_max_region(self) -> None:
        widget = self.make_widget()
        try:
            # 1 ms/div × 10 格 = 10 ms；包络点按 204.8 kHz 相当于
            # 65Msps 下每桶约 317 个样本。Min/Max 故意错开，模拟抽桶。
            env_rate = 204_800
            count = 2048
            time = np.arange(count, dtype=np.float64) / env_rate
            center = np.clip(
                np.round((np.sin(2 * np.pi * 10_000 * time) + 1.0) * 2047.5),
                0, 4095,
            )
            min_codes = np.clip(center - 40, 0, 4095).astype(np.uint16)
            max_codes = np.clip(center + 40, 0, 4095).astype(np.uint16)
            payload = b"".join(
                struct.pack("<HHHH", int(lo), int(hi), 2048, 2048)
                for lo, hi in zip(min_codes, max_codes)
            )
            frame = CompletedFrame(
                PacketHeader(1, 2, 7, count, env_rate, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 0),
                payload,
            )
            widget.set_timebase(1e-3)
            widget.set_volts_per_div(1, 0.5)
            widget.display_frame(frame)
            y = widget.curve_a.getData()[1]
            volts = y * widget.volts_per_div(1)
            frequency = zero_crossing_frequency(volts, env_rate)
            self.assertGreater(frequency, 9.5e3)
            self.assertLess(frequency, 10.5e3)
            self.assertTrue(widget.min_a.isVisible())
            self.assertTrue(widget.max_a.isVisible())
            self.assertTrue(widget.fill_a.isVisible())
            self.assertFalse(widget.fill_b.isVisible())
            self.assertTrue(widget.curve_a.isVisible())
        finally:
            widget.close()

    def test_single_channel_payload_is_drawn_only_on_selected_channel(self) -> None:
        widget = self.make_widget()
        try:
            payload = np.array([0x0800, 0x0900], dtype="<u2").tobytes()
            frame = CompletedFrame(
                PacketHeader(1, 1, 2, 2, 1000, 1, 2, SampleFormat.RAW16,
                             0, 0, len(payload), 0), payload,
            )
            widget.set_channel_mode("CH2")
            widget.display_frame(frame)
            self.assertEqual(widget.curve_b.getData()[0].tolist(), [-0.001, 0.0])
            self.assertFalse(widget.curve_a.isVisible())
            self.assertTrue(widget.curve_b.isVisible())
        finally:
            widget.close()

    def test_decimated32_keeps_32bit_sample_layout_for_single_mask(self) -> None:
        widget = self.make_widget()
        try:
            # DECIMATED32 的 CH1 帧仍是一点 4 字节，CH2 槽由 FPGA 清零；
            # 不能按 RAW16 拆成两个点。
            payload = struct.pack("<II", 0x00000800, 0x00000900)
            frame = CompletedFrame(
                PacketHeader(1, 1, 3, 2, 1000, 0, 1, SampleFormat.DECIMATED32,
                             0, 0, len(payload), 0),
                payload,
            )
            widget.display_frame(frame)
            self.assertEqual(len(widget.curve_a.getData()[0]), 2)
            self.assertEqual(len(widget.curve_b.getData()[0]), 2)
            self.assertFalse(widget.curve_b.isVisible())
        finally:
            widget.close()

    def test_large_raw_frame_reduction_keeps_narrow_pulse(self) -> None:
        widget = self.make_widget()
        try:
            codes = np.full(200_000, 2048, dtype=np.uint32)
            codes[99_999:100_002] = 4095
            frame = raw_frame(codes, sample_rate=65_000_000)
            widget.display_frame(frame, max_points=1000)
            plotted = widget.curve_a.getData()[1]
            self.assertLessEqual(len(plotted), 1000)
            self.assertAlmostEqual(float(np.max(plotted)),
                                   float(codes_to_voltage(np.array([4095]))[0]),
                                   places=6)
        finally:
            widget.close()

    def test_overshoot_toggle_restores_raw_and_full_rate_envelope(self) -> None:
        source = square_with_overshoot()
        source[30] = 1.6
        codes = np.rint((source + 5.0) / 10.0 * 4095).astype(np.uint16)
        channel_b = np.full_like(codes, 2048)
        raw = raw_frame(codes.astype(np.uint32) | (channel_b.astype(np.uint32) << 12),
                        sample_rate=65_000_000)
        payload = np.column_stack((codes, codes, channel_b, channel_b)).astype('<u2').tobytes()
        envelope = CompletedFrame(
            PacketHeader(1, 2, 8, len(codes), 65_000_000, 0, 3,
                         SampleFormat.ENVELOPE64, 0, 0, len(payload), 0), payload,
        )
        for frame in (raw, envelope):
            with self.subTest(format=frame.header.sample_format):
                widget = self.make_widget()
                try:
                    widget.set_timebase(1e-6)
                    widget.display_frame(frame)
                    x, corrected = widget.curve_a.getData()
                    np.testing.assert_allclose(x, np.arange(len(codes)) / 65_000_000)
                    self.assertLess(corrected[17], codes_to_voltage(codes)[17])
                    self.assertEqual(corrected[30], codes_to_voltage(codes)[30])
                    self.assertFalse(widget.min_a.isVisible())
                    self.assertFalse(widget.max_a.isVisible())
                    self.assertFalse(widget.fill_a.isVisible())
                    widget.set_edge_overshoot_suppression(False)
                    np.testing.assert_array_equal(widget.curve_a.getData()[1],
                                                  codes_to_voltage(codes))
                    widget.set_edge_overshoot_suppression(True)
                    np.testing.assert_array_equal(widget.curve_a.getData()[1], corrected)
                    self.assertIs(widget._last_frame, frame)
                finally:
                    widget.close()

    def test_full_rate_envelope_with_range_keeps_extrema(self) -> None:
        codes = np.rint((square_with_overshoot() + 5) / 10 * 4095).astype(np.uint16)
        spread = 20
        payload = np.column_stack((codes - spread, codes + spread,
                                   codes, codes)).astype('<u2').tobytes()
        frame = CompletedFrame(
            PacketHeader(1, 2, 9, len(codes), ADC_SAMPLE_RATE_HZ, 0, 3,
                         SampleFormat.ENVELOPE64, 0, 0, len(payload), 0), payload,
        )
        widget = self.make_widget()
        try:
            widget.display_frame(frame)
            np.testing.assert_array_equal(widget.curve_a.getData()[1], codes_to_voltage(codes))
            np.testing.assert_array_equal(widget.max_a.getData()[1], codes_to_voltage(codes + spread))
            self.assertTrue(widget.fill_a.isVisible())
        finally:
            widget.close()

    def test_fractional_frequencies_in_raw_and_envelope_display(self) -> None:
        cases = ((1e-6, SampleFormat.RAW32), (1e-6, SampleFormat.ENVELOPE64),
                 (5e-6, SampleFormat.ENVELOPE64), (20e-6, SampleFormat.ENVELOPE32))
        for frequency in (500_000, 600_000, 800_000, 1_000_000):
            for timebase, sample_format in cases:
                with self.subTest(frequency=frequency, timebase=timebase, format=sample_format):
                    count = int(np.ceil(ADC_SAMPLE_RATE_HZ * timebase * 10))
                    bucket = int(np.ceil(count / MAX_ENVELOPE_POINTS))
                    source = sampled_square_with_overshoot(frequency, count, 0.35)
                    codes = np.rint((source + 5) / 10 * 4095).astype(np.uint16)
                    offsets = np.arange(0, count, bucket)
                    lo, hi = np.minimum.reduceat(codes, offsets), np.maximum.reduceat(codes, offsets)
                    mask = 1 if sample_format == SampleFormat.ENVELOPE32 else 3
                    if sample_format == SampleFormat.RAW32:
                        payload = (codes.astype('<u4') | (2048 << 12)).tobytes()
                    else:
                        other = np.full_like(lo, 2048)
                        slots = (lo, hi, other, other) if mask == 3 else (lo, hi)
                        payload = np.column_stack(slots).astype('<u2').tobytes()
                    frame = CompletedFrame(
                        PacketHeader(1, 1 if sample_format == SampleFormat.RAW32 else 2,
                                     11, len(lo), ADC_SAMPLE_RATE_HZ // bucket, 0,
                                     mask, sample_format, 0, 0, len(payload), 0), payload,
                    )
                    widget = self.make_widget()
                    try:
                        widget.set_timebase(timebase)
                        widget.display_frame(frame)
                        if sample_format == SampleFormat.RAW32:
                            actual_lo = actual_hi = widget.curve_a.getData()[1]
                        else:
                            actual_lo, actual_hi = widget.min_a.getData()[1], widget.max_a.getData()[1]
                        guard = max(1, int(np.ceil(12 / bucket)))
                        before = (np.maximum(codes_to_voltage(hi)[guard:-guard] - 1, 0)
                                  + np.maximum(-1 - codes_to_voltage(lo)[guard:-guard], 0)).sum()
                        after = (np.maximum(actual_hi[guard:-guard] - 1, 0)
                                 + np.maximum(-1 - actual_lo[guard:-guard], 0)).sum()
                        self.assertLess(after, before * 0.25)
                        self.assertIsNone(widget.curve_a.opts['stepMode'])
                        widget.set_edge_overshoot_suppression(False)
                        np.testing.assert_allclose(widget.curve_a.getData()[1],
                                                   codes_to_voltage((lo.astype(float) + hi) / 2))
                        self.assertEqual(frame.payload, payload)
                    finally:
                        widget.close()

    def test_compressed_timebases_suppress_overshoot_and_keep_glitches(self) -> None:
        cases = ((5e-6, 65, 3), (10e-6, 65, 3), (20e-6, 65, 3),
                 (50e-6, 65, 3), (100e-6, 650, 3), (1e-3, 6500, 3),
                 (5e-6, 65, 1), (10e-6, 65, 2))
        for timebase, period, channel_mask in cases:
            with self.subTest(timebase=timebase, period=period, channel_mask=channel_mask):
                count = int(np.ceil(ADC_SAMPLE_RATE_HZ * timebase * 10))
                bucket = int(np.ceil(count / MAX_ENVELOPE_POINTS))
                source = square_with_overshoot(count, period)
                edges = np.flatnonzero((source[:-1] < 0) != (source[1:] < 0)) + 1
                glitches = (edges[0] + period // 4, edges[1] + period // 4,
                            edges[6] + 2, edges[10] + period // 4)
                source[glitches[0]] = 1.6  # 高平台毛刺。
                source[glitches[1]] = -1.5  # 低平台毛刺。
                source[glitches[2]] = 1.8  # 紧贴边沿的异常尖峰。
                source[glitches[3]:glitches[3] + 2] = -1.0  # 跨阈值窄脉冲。
                codes = np.rint((source + 5) / 10 * 4095).astype(np.uint16)
                offsets = np.arange(0, count, bucket)
                lo, hi = np.minimum.reduceat(codes, offsets), np.maximum.reduceat(codes, offsets)
                other = np.full_like(lo, 2048)
                slots = (lo, hi, other, other) if channel_mask == 3 else (lo, hi)
                payload = np.column_stack(slots).astype('<u2').tobytes()
                sample_format = SampleFormat.ENVELOPE64 if channel_mask == 3 else SampleFormat.ENVELOPE32
                frame = CompletedFrame(
                    PacketHeader(1, 2, 10, len(lo), ADC_SAMPLE_RATE_HZ // bucket, 0,
                                 channel_mask, sample_format, 0, 0, len(payload), 0), payload,
                )
                widget = self.make_widget()
                try:
                    widget.set_timebase(timebase)
                    widget.display_frame(frame)
                    main, minimum, maximum = ((widget.curve_b, widget.min_b, widget.max_b)
                                              if channel_mask == 2 else
                                              (widget.curve_a, widget.min_a, widget.max_a))
                    actual_lo, actual_hi = minimum.getData()[1], maximum.getData()[1]
                    start = int(np.ceil(8 * period / bucket))
                    self.assertLessEqual(float(actual_hi[start:-3].max()), 1.005)
                    self.assertGreaterEqual(float(actual_lo[start:-3].min()), -1.005)
                    self.assertGreater(float(codes_to_voltage(hi)[start:-3].max()), 1.1)
                    self.assertTrue(np.all(actual_lo <= actual_hi))
                    np.testing.assert_allclose(main.getData()[1], (actual_lo + actual_hi) / 2)
                    for position in glitches:
                        index = position // bucket
                        self.assertEqual(actual_lo[index], codes_to_voltage(lo)[index])
                        self.assertEqual(actual_hi[index], codes_to_voltage(hi)[index])
                    original_x = main.getData()[0].copy()
                    widget.set_edge_overshoot_suppression(False)
                    np.testing.assert_array_equal(minimum.getData()[1], codes_to_voltage(lo))
                    np.testing.assert_array_equal(maximum.getData()[1], codes_to_voltage(hi))
                    np.testing.assert_array_equal(main.getData()[0], original_x)
                    self.assertEqual(frame.payload, payload)
                finally:
                    widget.close()


if __name__ == "__main__":
    unittest.main()
