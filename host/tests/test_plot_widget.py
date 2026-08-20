from __future__ import annotations

import os
import struct
import unittest

import numpy as np

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
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
            self.assertFalse(widget.trigger_line.isVisible())
            self.assertFalse(widget.min_a.isVisible())
            self.assertFalse(widget.max_a.isVisible())
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
            # 10 ms 旧帧切到 20 ms 新窗口，应重复一次旧数据立即填满，
            # 采样间隔仍保持 5 ms，不能通过拉伸横轴伪造。
            frame = CompletedFrame(
                PacketHeader(1, 2, 1, 2, 200, 0, 3, SampleFormat.ENVELOPE64,
                             0, 0, len(payload), 0), payload,
            )
            widget.display_frame(frame)
            x = widget.curve_a.getData()[0]
            np.testing.assert_allclose(x, [0.0, 0.005, 0.010, 0.015])
            self.assertEqual(widget.plot.viewRange()[0], [0.0, 2e-2])
            y = widget.curve_a.getData()[1]
            np.testing.assert_allclose(y[:2], y[2:])
        finally:
            widget.close()

    def test_envelope_display_removes_isolated_center_spike(self) -> None:
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
            self.assertAlmostEqual(float(y[2]), float(y[1]))
            self.assertEqual(len(widget.curve_a.getData()[0]), len(y))
        finally:
            widget.close()

    def test_envelope_display_smooths_continuous_jitter(self) -> None:
        widget = self.make_widget()
        try:
            centers = [0x800, 0x880, 0x780, 0x880, 0x780, 0x880, 0x800]
            payload = b"".join(
                struct.pack("<HHHH", value, value, 0x800, 0x800)
                for value in centers
            )
            frame = CompletedFrame(
                PacketHeader(1, 2, 5, len(centers), 1000, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 0),
                payload,
            )
            widget.set_timebase(1e-3)
            widget.display_frame(frame)
            y = widget.curve_a.getData()[1]
            self.assertLess(float(np.max(np.abs(y[2:-2] - y[3:-1]))), 0.2)
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


if __name__ == "__main__":
    unittest.main()
