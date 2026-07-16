"""三种时域波形和 FFT 显示控件。"""

from __future__ import annotations

import numpy as np
from PyQt5 import QtWidgets
import pyqtgraph as pg

from host.comm.data_protocol import (
    CompletedFrame, SampleFormat, decode_envelope64, decode_raw32,
)
from host.core.waveform import codes_to_voltage, fft_spectrum, time_axis


class PlotWidget(QtWidgets.QWidget):
    def __init__(self, parent: QtWidgets.QWidget | None = None) -> None:
        super().__init__(parent)
        self.plot = pg.PlotWidget(background="#10151d")
        self.plot.showGrid(x=True, y=True, alpha=0.25)
        self.plot.addLegend()
        self.plot.setLabel("left", "电压", units="V")
        self.plot.setLabel("bottom", "时间", units="s")
        self.curve_a = self.plot.plot(pen=pg.mkPen("#3da5ff", width=1.5), name="CH A")
        self.curve_b = self.plot.plot(pen=pg.mkPen("#ffb020", width=1.5), name="CH B")
        self.min_a = self.plot.plot(pen=pg.mkPen("#3da5ff", width=1))
        self.max_a = self.plot.plot(pen=pg.mkPen("#3da5ff", width=1))
        self.min_b = self.plot.plot(pen=pg.mkPen("#ffb020", width=1))
        self.max_b = self.plot.plot(pen=pg.mkPen("#ffb020", width=1))
        self.fill_a = pg.FillBetweenItem(self.min_a, self.max_a, pg.mkBrush(61, 165, 255, 45))
        self.fill_b = pg.FillBetweenItem(self.min_b, self.max_b, pg.mkBrush(255, 176, 32, 35))
        self.plot.addItem(self.fill_a)
        self.plot.addItem(self.fill_b)
        layout = QtWidgets.QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(self.plot)
        self._fft = False
        self._seconds_per_div = 0.001

    def set_fft_enabled(self, enabled: bool) -> None:
        self._fft = enabled

    def set_timebase(self, seconds_per_div: float) -> None:
        self._seconds_per_div = seconds_per_div
        if not self._fft:
            self.plot.setXRange(0, seconds_per_div * 10, padding=0)

    def display_frame(self, frame: CompletedFrame, max_points: int = 100_000) -> None:
        sample_format = frame.header.sample_format
        if sample_format == SampleFormat.ENVELOPE64:
            self._display_envelope(frame)
            return
        if sample_format not in (SampleFormat.RAW32, SampleFormat.DECIMATED32):
            return
        decoded = decode_raw32(frame.payload)
        a = codes_to_voltage(decoded["a"])
        b = codes_to_voltage(decoded["b"])
        if self._fft:
            self._display_fft(a, b, frame.header.sample_rate_hz)
            return
        step = max(1, len(a) // max_points)
        x = time_axis(len(a), frame.header.sample_rate_hz)[::step]
        self._clear_envelope()
        self.curve_a.setData(x, a[::step])
        self.curve_b.setData(x, b[::step])
        self.plot.setLabel("bottom", "时间", units="s")
        self.plot.setLabel("left", "电压", units="V")
        self.plot.setXRange(0, min(self._seconds_per_div * 10, x[-1] if x.size else 0), padding=0)

    def _display_envelope(self, frame: CompletedFrame) -> None:
        values = decode_envelope64(frame.payload)
        count = len(values["min_a"])
        x = time_axis(count, frame.header.sample_rate_hz)
        self.curve_a.clear()
        self.curve_b.clear()
        self.min_a.setData(x, codes_to_voltage(values["min_a"]))
        self.max_a.setData(x, codes_to_voltage(values["max_a"]))
        self.min_b.setData(x, codes_to_voltage(values["min_b"]))
        self.max_b.setData(x, codes_to_voltage(values["max_b"]))
        self.plot.setLabel("bottom", "时间", units="s")
        self.plot.setLabel("left", "电压", units="V")
        if x.size:
            self.plot.setXRange(0, min(self._seconds_per_div * 10, x[-1]), padding=0)

    def _display_fft(self, a: np.ndarray, b: np.ndarray, sample_rate_hz: int) -> None:
        fa, ma = fft_spectrum(a, sample_rate_hz)
        fb, mb = fft_spectrum(b, sample_rate_hz)
        self._clear_envelope()
        self.curve_a.setData(fa, ma)
        self.curve_b.setData(fb, mb)
        self.plot.setLabel("bottom", "频率", units="Hz")
        self.plot.setLabel("left", "幅度", units="V")
        if fa.size:
            self.plot.setXRange(0, sample_rate_hz / 2, padding=0)

    def _clear_envelope(self) -> None:
        self.min_a.clear()
        self.max_a.clear()
        self.min_b.clear()
        self.max_b.clear()
