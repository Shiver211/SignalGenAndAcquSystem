"""波形码值换算、FFT、过零频率和上位机测量复算。"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


ADC_FULL_SCALE_VOLTS = 10.0
ADC_MAX_CODE = 4095.0
ADC_CAL_GAIN_MIN = 0.5
ADC_CAL_GAIN_MAX = 1.5


@dataclass(frozen=True)
class WaveformMeasurements:
    minimum_v: float
    maximum_v: float
    mean_v: float
    vpp_v: float
    frequency_hz: float


def code_to_voltage(
    code: float,
    *,
    gain: float = 1.0,
    offset_v: float = 0.0,
) -> float:
    """把单个 ADC 码换成输入电压。gain/offset 用于前端校准。"""
    nominal = float(code) / ADC_MAX_CODE * ADC_FULL_SCALE_VOLTS - 5.0
    return nominal * gain + offset_v


def vpp_from_code_span(span: float, *, gain: float = 1.0) -> float:
    """峰峰值码差（max-min）换成伏特；直流偏置会抵消。"""
    return float(span) / ADC_MAX_CODE * ADC_FULL_SCALE_VOLTS * gain


def gain_from_known_vpp(vpp_code: int, known_vpp: float) -> float:
    """用已知输入峰峰值反推前端增益。"""
    if vpp_code <= 0 or known_vpp <= 0:
        raise ValueError("峰峰值必须大于 0")
    gain = known_vpp / vpp_from_code_span(vpp_code)
    if not ADC_CAL_GAIN_MIN <= gain <= ADC_CAL_GAIN_MAX:
        raise ValueError(
            f"校准增益 {gain:.3f} 超出 {ADC_CAL_GAIN_MIN}..{ADC_CAL_GAIN_MAX}"
        )
    return gain


def format_voltage(voltage: float, *, peak_to_peak: bool = False) -> str:
    if peak_to_peak:
        return f"{voltage:.3f} V"
    return f"{voltage:+.3f} V"


def format_frequency_hz(frequency_hz: float) -> str:
    value = float(frequency_hz)
    if value >= 1000.0:
        return f"{value / 1000.0:.3f} kHz"
    return f"{value:.1f} Hz"


def codes_to_voltage(
    codes: np.ndarray,
    *,
    gain: float = 1.0,
    offset_v: float = 0.0,
) -> np.ndarray:
    values = np.asarray(codes, dtype=np.float64)
    nominal = values / ADC_MAX_CODE * ADC_FULL_SCALE_VOLTS - 5.0
    return nominal * gain + offset_v


def voltage_to_code(voltage: float) -> int:
    return int(np.clip(round((voltage + 5.0) / ADC_FULL_SCALE_VOLTS * ADC_MAX_CODE), 0, 4095))


def time_axis(sample_count: int, sample_rate_hz: float) -> np.ndarray:
    if sample_rate_hz <= 0:
        raise ValueError("采样率必须大于 0")
    return np.arange(sample_count, dtype=np.float64) / sample_rate_hz


def median_filter_3(samples: np.ndarray) -> np.ndarray:
    """用于波形显示的形状保持三点中值滤波。

    只替换相对两侧趋势大得多的孤立尖峰；真实三角波拐角和正弦峰值
    的局部斜率变化会保留，避免普通中值滤波把尖角压平。
    """
    values = np.asarray(samples, dtype=np.float64)
    if values.size < 5:
        return values.copy()
    result = values.copy()
    for index in range(2, values.size - 2):
        left = values[index - 1]
        center = values[index]
        right = values[index + 1]
        median = float(np.median((left, center, right)))
        deviation = abs(center - median)
        if deviation == 0:
            continue
        # 若两侧几乎相等且外侧趋势很小，才认定为孤立毛刺；
        # 三角波尖角两侧仍有连续斜率，不会满足这个条件。
        neighbor_span = abs(left - right)
        outer_slope = max(
            abs(values[index - 1] - values[index - 2]),
            abs(values[index + 2] - values[index + 1]),
        )
        if neighbor_span <= deviation * 0.25 and deviation > outer_slope * 3.0:
            result[index] = median
    return result


def smooth_binomial_5(samples: np.ndarray) -> np.ndarray:
    """五点零相位二项平滑，抑制包络中心线的连续小幅抖动。"""
    values = np.asarray(samples, dtype=np.float64)
    if values.size < 5:
        return values.copy()
    padded = np.pad(values, (2, 2), mode="edge")
    windows = np.stack(
        (padded[:-4], padded[1:-3], padded[2:-2], padded[3:-1], padded[4:]),
    )
    return np.sum(
        windows * np.array([1.0, 4.0, 6.0, 4.0, 1.0])[:, None],
        axis=0,
    ) / 16.0


def fft_spectrum(samples: np.ndarray, sample_rate_hz: float) -> tuple[np.ndarray, np.ndarray]:
    values = np.asarray(samples, dtype=np.float64)
    if values.size < 2 or sample_rate_hz <= 0:
        return np.empty(0), np.empty(0)
    centered = values - np.mean(values)
    window = np.hanning(values.size)
    coherent_gain = max(window.sum() / values.size, np.finfo(float).eps)
    spectrum = np.fft.rfft(centered * window)
    magnitude = np.abs(spectrum) * 2.0 / values.size / coherent_gain
    magnitude[0] *= 0.5
    if values.size % 2 == 0:
        magnitude[-1] *= 0.5
    frequencies = np.fft.rfftfreq(values.size, 1.0 / sample_rate_hz)
    return frequencies, magnitude


def zero_crossing_frequency(samples: np.ndarray, sample_rate_hz: float) -> float:
    values = np.asarray(samples, dtype=np.float64)
    if values.size < 3 or sample_rate_hz <= 0:
        return 0.0
    centered = values - np.mean(values)
    indices = np.flatnonzero((centered[:-1] < 0) & (centered[1:] >= 0))
    if indices.size < 2:
        return 0.0
    before = centered[indices]
    after = centered[indices + 1]
    fraction = -before / np.where(after == before, 1.0, after - before)
    crossings = indices.astype(np.float64) + fraction
    periods = np.diff(crossings) / sample_rate_hz
    periods = periods[periods > 0]
    return float(1.0 / np.mean(periods)) if periods.size else 0.0


def measure_waveform(samples_v: np.ndarray, sample_rate_hz: float) -> WaveformMeasurements:
    values = np.asarray(samples_v, dtype=np.float64)
    if values.size == 0:
        return WaveformMeasurements(0.0, 0.0, 0.0, 0.0, 0.0)
    minimum = float(np.min(values))
    maximum = float(np.max(values))
    return WaveformMeasurements(
        minimum_v=minimum,
        maximum_v=maximum,
        mean_v=float(np.mean(values)),
        vpp_v=maximum - minimum,
        frequency_hz=zero_crossing_frequency(values, sample_rate_hz),
    )
