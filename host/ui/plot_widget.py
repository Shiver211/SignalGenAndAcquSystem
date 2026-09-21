"""标准示波器波形显示控件。

显示坐标固定为横向 10 格、纵向 8 格。波形曲线内部使用“格(div)”作为
Y 轴坐标，因此两个通道可以分别设置 V/div 和垂直位置，同时共用一套
标准示波器网格。协议层仍使用现有 RAW32/ENVELOPE64 数据格式。
"""

from __future__ import annotations

from enum import IntEnum

import numpy as np
from PyQt5 import QtWidgets
import pyqtgraph as pg

from host.comm.data_protocol import (
    INTERLEAVE_FLAG, CompletedFrame, SampleFormat, decode_envelope64, decode_raw32,
)
from host.config import ADC_SAMPLE_RATE_HZ, INTERLEAVE_SAMPLE_RATE_HZ
from host.core.waveform import (
    clean_square_waveform, codes_to_voltage, fft_spectrum,
    idealize_square_display, refine_trigger_position, smooth_continuous_display,
)


class ChannelDisplayMode(IntEnum):
    """波形显示通道选择。"""

    BOTH = 0
    CH1 = 1
    CH2 = 2


class PlotWidget(QtWidgets.QWidget):
    """带 10×8 网格和基本分度控制的示波器显示控件。"""

    HORIZONTAL_DIVISIONS = 10
    VERTICAL_DIVISIONS = 8
    _HALF_HORIZONTAL_DIVISIONS = HORIZONTAL_DIVISIONS / 2
    _HALF_VERTICAL_DIVISIONS = VERTICAL_DIVISIONS / 2
    _ENVELOPE_BAND_DIVISIONS = 0.1

    def __init__(self, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)

        self.plot = pg.PlotWidget(background="#10151d")
        self.plot.setMenuEnabled(False)
        self.plot.setMouseEnabled(x=False, y=False)
        self.plot.showGrid(x=False, y=False)
        self.plot.hideAxis("left")
        self.plot.hideAxis("bottom")
        self.plot.setYRange(-self._HALF_VERTICAL_DIVISIONS,
                            self._HALF_VERTICAL_DIVISIONS, padding=0)

        # GridItem 的一个刻度对应一格，保证视图始终是 10×8 网格。
        # 不画刻度数字，只保留格线。
        self.grid_item = pg.GridItem()
        self.grid_item.setTextPen(None)
        self.plot.addItem(self.grid_item)

        self.trigger_line = pg.InfiniteLine(
            angle=90, movable=False,
            pen=pg.mkPen("#d6d6d6", width=1, style=pg.QtCore.Qt.DashLine),
        )
        self.plot.addItem(self.trigger_line)

        self.plot.addLegend()
        self.curve_a = self.plot.plot(
            pen=pg.mkPen("#3da5ff", width=1.5), name="CH1", antialias=True,
        )
        self.curve_b = self.plot.plot(
            pen=pg.mkPen("#ffb020", width=1.5), name="CH2", antialias=True,
        )

        # 包络帧同时保留每桶的 Min/Max，避免把桶内瞬态压成一个中心点。
        self.min_a = self.plot.plot(pen=pg.mkPen("#3da5ff", width=1), antialias=True)
        self.max_a = self.plot.plot(pen=pg.mkPen("#3da5ff", width=1), antialias=True)
        self.min_b = self.plot.plot(pen=pg.mkPen("#ffb020", width=1), antialias=True)
        self.max_b = self.plot.plot(pen=pg.mkPen("#ffb020", width=1), antialias=True)
        self.fill_a = pg.FillBetweenItem(
            self.min_a, self.max_a, pg.mkBrush(61, 165, 255, 45),
        )
        self.fill_b = pg.FillBetweenItem(
            self.min_b, self.max_b, pg.mkBrush(255, 176, 32, 35),
        )
        self.plot.addItem(self.fill_a)
        self.plot.addItem(self.fill_b)
        self._clear_envelope()

        self._fft = False
        self._seconds_per_div = 0.001
        self._channel_mode = ChannelDisplayMode.BOTH
        self._visible_channels = {1, 2}
        self._channel_settings = {
            1: {"volts_per_div": 1.0, "position_div": 0.0},
            2: {"volts_per_div": 1.0, "position_div": 0.0},
        }
        self._adc_gain = {1: 1.0, 2: 1.0}
        self._adc_offset = {1: 0.0, 2: 0.0}
        self._last_frame: CompletedFrame | None = None
        self._trigger_alignment: tuple[int, float, bool] | None = None
        self._frame_trigger_alignment: tuple[int, float, bool] | None = None
        self._has_trigger_alignment = False
        self._envelope_active = False
        self._configure_grid()
        self._set_time_range()
        self._apply_visibility()

        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.plot)

    # ---- 显示状态与控件可调用接口 -------------------------------------

    @property
    def seconds_per_div(self) -> float:
        return self._seconds_per_div

    @property
    def channel_mode(self) -> ChannelDisplayMode:
        return self._channel_mode

    def set_fft_enabled(self, enabled: bool) -> None:
        self._fft = bool(enabled)
        if self._last_frame is not None:
            self.display_frame(self._last_frame)

    def set_channel_mode(self, mode: ChannelDisplayMode | int | str) -> None:
        """选择 ``BOTH``、``CH1`` 或 ``CH2`` 显示。"""
        if isinstance(mode, str):
            normalized = mode.strip().upper().replace(" ", "")
            aliases = {
                "A": ChannelDisplayMode.CH1,
                "CHA": ChannelDisplayMode.CH1,
                "CH1": ChannelDisplayMode.CH1,
                "CH2": ChannelDisplayMode.CH2,
                "B": ChannelDisplayMode.CH2,
                "CHB": ChannelDisplayMode.CH2,
                "BOTH": ChannelDisplayMode.BOTH,
                "双通道": ChannelDisplayMode.BOTH,
            }
            try:
                mode = aliases[normalized]
            except KeyError as exc:
                raise ValueError("通道模式必须为 BOTH、CH1 或 CH2") from exc
        try:
            self._channel_mode = ChannelDisplayMode(mode)
        except ValueError as exc:
            raise ValueError("通道模式必须为 BOTH、CH1 或 CH2") from exc
        self._visible_channels = {
            1, 2,
        } if self._channel_mode == ChannelDisplayMode.BOTH else {
            int(self._channel_mode),
        }
        self._apply_visibility()

    def set_channel_visible(self, channel: int, visible: bool) -> None:
        """按通道设置显示状态；适合复选框等细粒度控制。"""
        channel = self._validate_channel(channel)
        if visible:
            self._visible_channels.add(channel)
        else:
            self._visible_channels.discard(channel)
        if self._visible_channels == {1}:
            self._channel_mode = ChannelDisplayMode.CH1
        elif self._visible_channels == {2}:
            self._channel_mode = ChannelDisplayMode.CH2
        else:
            # 空集合也保留 BOTH 作为模式值，具体可见性由集合表达。
            self._channel_mode = ChannelDisplayMode.BOTH
        self._apply_visibility()

    set_channel_visibility = set_channel_visible

    def set_adc_calibration(
        self,
        channel: int,
        gain: float = 1.0,
        offset_v: float = 0.0,
    ) -> None:
        channel = self._validate_channel(channel)
        gain_value = float(gain)
        offset_value = float(offset_v)
        if not np.isfinite(gain_value) or gain_value <= 0:
            raise ValueError("ADC 校准增益必须为正数")
        if not np.isfinite(offset_value):
            raise ValueError("ADC 校准偏移必须为有限数")
        self._adc_gain[channel] = gain_value
        self._adc_offset[channel] = offset_value
        self._redraw_last_frame()

    def _codes_to_volts(self, codes: np.ndarray, channel: int) -> np.ndarray:
        return codes_to_voltage(
            codes,
            gain=self._adc_gain[channel],
            offset_v=self._adc_offset[channel],
        )

    def set_volts_per_div(self, channel: int, volts_per_div: float) -> None:
        channel = self._validate_channel(channel)
        value = float(volts_per_div)
        if not np.isfinite(value) or value <= 0:
            raise ValueError("电压/div 必须为正数")
        self._channel_settings[channel]["volts_per_div"] = value
        self._redraw_last_frame()

    set_voltage_per_div = set_volts_per_div
    set_vertical_scale = set_volts_per_div

    def volts_per_div(self, channel: int) -> float:
        channel = self._validate_channel(channel)
        return float(self._channel_settings[channel]["volts_per_div"])

    def set_vertical_position(self, channel: int, position_v: float) -> None:
        channel = self._validate_channel(channel)
        value = float(position_v)
        if not np.isfinite(value):
            raise ValueError("通道垂直位置必须为有限数")
        self._channel_settings[channel]["position_div"] = (
            value / self._channel_settings[channel]["volts_per_div"]
        )
        self._redraw_last_frame()

    set_channel_offset = set_vertical_position

    def set_vertical_position_div(self, channel: int, position_div: float) -> None:
        """按格设置通道垂直位置，正值向上移动。"""
        channel = self._validate_channel(channel)
        value = float(position_div)
        if not np.isfinite(value):
            raise ValueError("通道垂直位置必须为有限数")
        self._channel_settings[channel]["position_div"] = value
        self._redraw_last_frame()

    def vertical_position(self, channel: int) -> float:
        channel = self._validate_channel(channel)
        settings = self._channel_settings[channel]
        return float(settings["position_div"] * settings["volts_per_div"])

    def vertical_position_div(self, channel: int) -> float:
        channel = self._validate_channel(channel)
        settings = self._channel_settings[channel]
        return float(settings["position_div"])

    def set_timebase(self, seconds_per_div: float) -> None:
        value = float(seconds_per_div)
        if not np.isfinite(value) or value <= 0:
            raise ValueError("时间/div 必须为正数")
        self._seconds_per_div = value
        self._configure_grid()
        self._set_time_range()

    set_time_per_div = set_timebase

    def set_trigger_alignment(
        self, channel: int | None, threshold: int = 2048,
        hysteresis: int = 16, falling: bool = False,
    ) -> None:
        """设置后续连续帧使用的已提交触发参数；None 暂停校正。"""
        if channel is None:
            self._trigger_alignment = None
            return
        channel = self._validate_channel(channel)
        level = np.clip(threshold + (-hysteresis if falling else hysteresis), 0, 4095)
        self._trigger_alignment = (channel, float(level), bool(falling))

    def clear_frame(self) -> None:
        """清除当前波形，供采集配置切换时丢弃旧帧。"""
        self._clear_waveforms()

    # ---- 数据显示 ------------------------------------------------------

    def display_frame(
        self, frame: CompletedFrame, max_points: int = 100_000,
        *, align_trigger: bool = True,
    ) -> None:
        """显示 RAW32/DECIMATED32/ENVELOPE64 帧。

        RAW/DECIMATED 使用 UDP 头中的 ``trigger_index`` 作为时间零点；
        ENVELOPE 若 ``trigger_index`` 大于 0 同样居中，否则从帧起点计时。
        已配置触发参数的 1:1 连续帧会细化首点时间；回放可关闭此校正。
        可识别的方波自动整形；连续波形适度平滑，包络保留 Min/Max 范围。
        长记录先在等间隔样点上处理显示副本，再按桶内极值抽点。
        """
        if not align_trigger:
            self._frame_trigger_alignment = None
        elif frame is not self._last_frame:
            # 同一帧重绘沿用原触发配置，避免幅度校准或时基切换改变对齐。
            self._frame_trigger_alignment = self._trigger_alignment
        self._last_frame = frame
        sample_format = frame.header.sample_format
        if sample_format in (SampleFormat.ENVELOPE64, SampleFormat.ENVELOPE32):
            # Min/Max 包络没有桶内相位信息，不能伪装成原始波形做 FFT。
            # 仍显示包络范围，用户切换回时域即可查看。
            self._display_envelope(frame)
            return
        if sample_format not in (SampleFormat.RAW32, SampleFormat.RAW16,
                                 SampleFormat.DECIMATED32):
            self._clear_waveforms()
            return

        # RAW16 是网络紧凑单通道格式；DECIMATED32 即使只有一个有效
        # 通道也仍保持 32bit 双槽布局（另一槽由 FPGA 置零）。
        decode_mask = (frame.header.channel_mask
                       if sample_format in (SampleFormat.RAW32, SampleFormat.RAW16)
                       else 0x03)
        decoded = decode_raw32(frame.payload, decode_mask)
        a = self._codes_to_volts(decoded["a"], 1)
        b = self._codes_to_volts(decoded["b"], 2)
        if len(a) == 0 or frame.header.sample_rate_hz <= 0:
            self._clear_waveforms()
            return
        if self._fft:
            self._display_fft(a, b, frame.header.sample_rate_hz)
            return

        sample_rate = float(frame.header.sample_rate_hz)
        trigger_index = self._clamped_trigger_index(frame, len(a))
        # 立即采集的帧 trigger_index=0，从 t=0 起显示当前十格窗口。
        align_trigger = trigger_index > 0
        if not align_trigger:
            visible = max(1, int(np.ceil(
                self.HORIZONTAL_DIVISIONS * self._seconds_per_div * sample_rate
            )))
            if visible < len(a):
                a = a[:visible]
                b = b[:visible]
        cleaned_a = clean_square_waveform(a)
        a = cleaned_a if cleaned_a is not None else smooth_continuous_display(a, sample_rate)
        cleaned_b = clean_square_waveform(b)
        b = cleaned_b if cleaned_b is not None else smooth_continuous_display(b, sample_rate)
        indices, display_a, display_b = self._reduce_raw_for_display(
            a, b, max_points,
        )
        x = (indices - (trigger_index if align_trigger else 0)) / sample_rate
        self._has_trigger_alignment = align_trigger
        self._set_time_range()
        self._clear_envelope()
        self._envelope_active = False
        for channel, curve, values in ((1, self.curve_a, display_a), (2, self.curve_b, display_b)):
            ideal = idealize_square_display(x, values)
            display_x, display_y = ideal if ideal is not None else (x, values)
            curve.setData(display_x, self._to_divisions(display_y, channel))
        self.trigger_line.setValue(0.0)
        self._apply_visibility()

    def _display_envelope(self, frame: CompletedFrame) -> None:
        values = decode_envelope64(frame.payload, frame.header.channel_mask)
        count = len(values["min_a"])
        if count == 0 or frame.header.sample_rate_hz <= 0:
            self._clear_waveforms()
            return
        min_a = values["min_a"].astype(np.float64)
        max_a = values["max_a"].astype(np.float64)
        min_b = values["min_b"].astype(np.float64)
        max_b = values["max_b"].astype(np.float64)
        trigger_offset = self._envelope_trigger_offset(frame, values)
        # 包络帧的每个点代表一个时间桶，Min/Max 必须分别绘制。
        window_seconds = self.HORIZONTAL_DIVISIONS * self._seconds_per_div
        visible_count = max(1, int(np.ceil(
            window_seconds * float(frame.header.sample_rate_hz)
        )))
        if visible_count < count:
            min_a, max_a = min_a[:visible_count], max_a[:visible_count]
            min_b, max_b = min_b[:visible_count], max_b[:visible_count]
        sample_rate = float(frame.header.sample_rate_hz)
        trigger_index = self._clamped_trigger_index(frame, len(min_a))
        x = (np.arange(len(min_a), dtype=np.float64) - trigger_index - trigger_offset) / sample_rate
        self._has_trigger_alignment = trigger_index > 0
        self._set_time_range()
        self._envelope_active = True
        self._envelope_channels = set()
        for channel, curve, minimum, maximum, lo, hi in (
            (1, self.curve_a, self.min_a, self.max_a, min_a, max_a),
            (2, self.curve_b, self.min_b, self.max_b, min_b, max_b),
        ):
            ideal = idealize_square_display(x, lo, hi)
            if ideal is not None:
                display_x, codes = ideal
                curve.setData(display_x, self._to_divisions(self._codes_to_volts(codes, channel), channel))
                minimum.clear()
                maximum.clear()
            else:
                # 仅平滑中心线；可见的 Min/Max 仍来自 FPGA 的原始包络。
                center = smooth_continuous_display((lo + hi) / 2.0, sample_rate)
                curve.setData(
                    x, self._to_divisions(self._codes_to_volts(center, channel), channel),
                )
                span_div = (
                    np.abs(
                        self._codes_to_volts(hi, channel)
                        - self._codes_to_volts(lo, channel)
                    )
                    / self._channel_settings[channel]["volts_per_div"]
                )
                visible_band = span_div >= self._ENVELOPE_BAND_DIVISIONS
                if np.any(visible_band):
                    display_lo = np.where(visible_band, lo, center)
                    display_hi = np.where(visible_band, hi, center)
                    minimum.setData(
                        x, self._to_divisions(
                            self._codes_to_volts(display_lo, channel), channel,
                        ),
                    )
                    maximum.setData(
                        x, self._to_divisions(
                            self._codes_to_volts(display_hi, channel), channel,
                        ),
                    )
                    self._envelope_channels.add(channel)
                else:
                    minimum.clear()
                    maximum.clear()
        self.trigger_line.setValue(0.0)
        self._apply_visibility()

    def _envelope_trigger_offset(
        self, frame: CompletedFrame, values: dict[str, np.ndarray],
    ) -> float:
        settings = self._frame_trigger_alignment
        native_rate = (INTERLEAVE_SAMPLE_RATE_HZ if frame.header.flags & INTERLEAVE_FLAG
                       else ADC_SAMPLE_RATE_HZ)
        # Min/Max 压缩桶没有桶内时间信息，不能据中心值伪造亚采样触发位置。
        if (settings is None or frame.header.trigger_index != 0 or
                frame.header.sample_rate_hz != native_rate):
            return 0.0
        channel, level, falling = settings
        if not frame.header.channel_mask & (1 << (channel - 1)):
            return 0.0
        suffix = "a" if channel == 1 else "b"
        lo, hi = values[f"min_{suffix}"], values[f"max_{suffix}"]
        if not np.array_equal(lo[:256], hi[:256]):
            return 0.0
        position = refine_trigger_position(lo, level, falling=falling)
        return position if position is not None else 0.0

    def _display_fft(self, a: np.ndarray, b: np.ndarray, sample_rate_hz: int) -> None:
        fa, ma = fft_spectrum(a, sample_rate_hz)
        fb, mb = fft_spectrum(b, sample_rate_hz)
        self._has_trigger_alignment = False
        self._clear_envelope()
        self.curve_a.setData(fa, ma)
        self.curve_b.setData(fb, mb)
        self.trigger_line.setVisible(False)
        if fa.size:
            self.plot.setXRange(0, sample_rate_hz / 2, padding=0)
        self._apply_visibility()

    # ---- 内部绘图辅助 --------------------------------------------------

    def _configure_grid(self) -> None:
        self.grid_item.setTickSpacing(
            x=[self._seconds_per_div], y=[1.0],
        )

    def _set_time_range(self) -> None:
        if self._fft:
            return
        if self._has_trigger_alignment:
            left = -self._HALF_HORIZONTAL_DIVISIONS * self._seconds_per_div
            right = self._HALF_HORIZONTAL_DIVISIONS * self._seconds_per_div
        else:
            left = 0.0
            right = self.HORIZONTAL_DIVISIONS * self._seconds_per_div
        self.plot.setXRange(left, right, padding=0)
        self.plot.setYRange(-self._HALF_VERTICAL_DIVISIONS,
                            self._HALF_VERTICAL_DIVISIONS, padding=0)

    def _to_divisions(self, volts: np.ndarray, channel: int) -> np.ndarray:
        settings = self._channel_settings[channel]
        return (np.asarray(volts, dtype=np.float64) /
                settings["volts_per_div"] + settings["position_div"])

    @staticmethod
    def _reduce_raw_for_display(
        values_a: np.ndarray, values_b: np.ndarray, max_points: int,
    ) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        """降采样时保留每个时间桶的两个通道极值，绝不删除窄脉冲。"""
        a = np.asarray(values_a, dtype=np.float64)
        b = np.asarray(values_b, dtype=np.float64)
        # 双通道 min/max 至少需要四个候选点；正常 UI 上限远大于此值。
        limit = max(4, int(max_points))
        if len(a) <= limit:
            return np.arange(len(a), dtype=np.float64), a, b
        # 每个桶最多保留 CH1/CH2 的 min/max 四个点，候选点数因此
        # 不会超过 limit；不再事后均匀裁剪极值点。
        bucket_count = max(1, limit // 4)
        edges = np.linspace(0, len(a), bucket_count + 1, dtype=np.int64)
        selected: set[int] = set()
        for start, end in zip(edges[:-1], edges[1:]):
            if end <= start:
                continue
            selected.add(int(start + np.argmin(a[start:end])))
            selected.add(int(start + np.argmax(a[start:end])))
            selected.add(int(start + np.argmin(b[start:end])))
            selected.add(int(start + np.argmax(b[start:end])))
        indices = np.asarray(sorted(selected), dtype=np.int64)
        return indices.astype(np.float64), a[indices], b[indices]

    def _clamped_trigger_index(self, frame: CompletedFrame, count: int) -> int:
        if count <= 0:
            return 0
        return int(np.clip(frame.header.trigger_index, 0, count - 1))

    def _redraw_last_frame(self) -> None:
        if self._last_frame is not None:
            self.display_frame(self._last_frame)

    def _clear_waveforms(self) -> None:
        for curve in (self.curve_a, self.curve_b, self.min_a, self.max_a,
                      self.min_b, self.max_b):
            curve.clear()
        self.fill_a.setVisible(False)
        self.fill_b.setVisible(False)
        self._last_frame = None
        self._frame_trigger_alignment = None
        self._envelope_active = False
        self._envelope_channels = set()
        self._has_trigger_alignment = False
        self._set_time_range()

    def _clear_envelope(self) -> None:
        self._envelope_channels = set()
        self._envelope_active = False
        for curve in (self.min_a, self.max_a, self.min_b, self.max_b):
            curve.clear()
        self.fill_a.setVisible(False)
        self.fill_b.setVisible(False)

    def _channel_items(self, channel: int) -> tuple[pg.PlotDataItem, ...]:
        if channel == 1:
            return self.curve_a, self.min_a, self.max_a, self.fill_a
        return self.curve_b, self.min_b, self.max_b, self.fill_b

    def _apply_visibility(self) -> None:
        frame_mask = self._last_frame.header.channel_mask if self._last_frame else 0x03
        ch1_visible = (1 in self._visible_channels) and bool(frame_mask & 0x01)
        ch2_visible = (2 in self._visible_channels) and bool(frame_mask & 0x02)
        if self._fft and not self._envelope_active:
            self.curve_a.setVisible(ch1_visible)
            self.curve_b.setVisible(ch2_visible)
            for curve in (self.min_a, self.max_a, self.min_b, self.max_b,
                          self.fill_a, self.fill_b):
                curve.setVisible(False)
            self.trigger_line.setVisible(False)
            return
        self.curve_a.setVisible(ch1_visible)
        self.curve_b.setVisible(ch2_visible)
        for curve in (self.min_a, self.max_a, self.fill_a):
            curve.setVisible(ch1_visible and 1 in self._envelope_channels)
        for curve in (self.min_b, self.max_b, self.fill_b):
            curve.setVisible(ch2_visible and 2 in self._envelope_channels)
        self.trigger_line.setVisible(True)

    @staticmethod
    def _validate_channel(channel: int) -> int:
        if channel not in (1, 2):
            raise ValueError("通道必须为 1 或 2")
        return int(channel)


__all__ = ["ChannelDisplayMode", "PlotWidget"]
