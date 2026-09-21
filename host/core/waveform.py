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


def _prepare_square_waveform(
    minimum: np.ndarray, maximum: np.ndarray | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    """显示与幅度测量共用的方波清理，不修改原始采样。

    高低平台须能独立辨认。按平台偏差中位数保留小抖动，异常值回到平台；
    短于典型平台 15% 的内部反向脉冲视作毛刺。完整跳变只在
    50% 电平交点插入一对同 X 坐标的端点，不把过渡样本画成多级台阶。
    压缩包络只能估计交点；平台不可分辨时返回 None，继续显示原包络。
    """
    lo = np.asarray(minimum, dtype=np.float64)
    hi = lo if maximum is None else np.asarray(maximum, dtype=np.float64)
    if len(lo) < 16:
        return None
    center = (lo + hi) / 2.0
    lower, upper = np.quantile(center, [0.1, 0.9])
    if upper <= lower:
        return None
    state = center > (lower + upper) / 2.0
    narrow = hi - lo <= (upper - lower) * 0.1
    low_samples, high_samples = narrow & ~state, narrow & state
    if (np.count_nonzero(narrow) < len(lo) * 0.25
            or min(np.count_nonzero(low_samples), np.count_nonzero(high_samples)) < 3):
        return None
    low = float(np.median(center[low_samples]))
    high = float(np.median(center[high_samples]))
    span = high - low
    residual = np.abs(center - np.where(state, high, low))
    # 平台须占主要部分。只忽略横跨高低电平的边沿桶；斜坡上的部分
    # 幅度桶必须计入，否则密集正弦的峰谷窄桶会被误判为方波平台。
    edge = (hi - lo) >= span * 0.5
    plateau = residual[~edge]
    if plateau.size == 0 or np.mean(plateau <= span * 0.08) < 0.8:
        return None

    boundaries = np.r_[0, np.flatnonzero(state[1:] != state[:-1]) + 1, len(lo)]
    lengths = np.diff(boundaries)
    if len(lengths) < 3:
        return None
    minimum_run = max(2, int(np.quantile(lengths, 0.75) * 0.15))
    keep = lengths >= minimum_run
    if np.count_nonzero(keep) < 3:
        return None
    # 保留首尾的部分周期；内部短反向脉冲沿用之前的稳定平台。
    keep[0] = keep[-1] = True
    preceding = np.maximum.accumulate(np.where(keep, np.arange(len(lengths)), 0))
    state = np.repeat(state[boundaries[:-1]][preceding], lengths)
    edges = np.flatnonzero(state[1:] != state[:-1]) + 1
    if len(edges) < 2:
        return None

    level = np.where(state, high, low)
    # 不对平台做平滑。阈值随平台噪声自适应，在电平差 0.3%~2% 内，
    # 避免平台很安静时还保留明显高于噪声的残余尖峰。
    tolerance = np.clip(4.5 * np.median(residual[narrow]), span * 0.003, span * 0.02)
    clean = np.where(np.abs(center - level) <= tolerance, center, level)
    threshold = (low + high) / 2.0
    delta = center[edges] - center[edges - 1]
    fraction = np.clip(np.divide(threshold - center[edges - 1], delta,
                                out=np.full(len(edges), 0.5), where=delta != 0), 0, 1)
    return clean, edges, fraction


def clean_square_waveform(
    minimum: np.ndarray, maximum: np.ndarray | None = None,
) -> np.ndarray | None:
    """返回去过冲、大毛刺且保留小抖动的等间隔样本；非方波返回 None。"""
    prepared = _prepare_square_waveform(minimum, maximum)
    return prepared[0] if prepared is not None else None


def idealize_square_display(
    time: np.ndarray, minimum: np.ndarray, maximum: np.ndarray | None = None,
) -> tuple[np.ndarray, np.ndarray] | None:
    """在清理后的方波样本间插入竖直边沿；新增绘图端点不参与测量。"""
    prepared = _prepare_square_waveform(minimum, maximum)
    if prepared is None:
        return None
    clean, edges, fraction = prepared
    x = np.asarray(time, dtype=np.float64)
    crossing = x[edges - 1] + fraction * (x[edges] - x[edges - 1])

    # 插入两点形成单根竖线，其余点仍用普通连线，平台噪声不会变成阶梯。
    positions = np.arange(len(x)) + 2 * np.searchsorted(edges, np.arange(len(x)), side="right")
    vertical = edges + 2 * np.arange(len(edges))
    display_x = np.empty(len(x) + 2 * len(edges))
    display_y = np.empty_like(display_x)
    display_x[positions], display_y[positions] = x, clean
    display_x[vertical] = display_x[vertical + 1] = crossing
    display_y[vertical], display_y[vertical + 1] = clean[edges - 1], clean[edges]
    return display_x, display_y


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
    """方波幅度按清理后的样本计算，频率仍由原始采样估计。"""
    values = np.asarray(samples_v, dtype=np.float64)
    if values.size == 0:
        return WaveformMeasurements(0.0, 0.0, 0.0, 0.0, 0.0)
    cleaned = clean_square_waveform(values)
    amplitude = values if cleaned is None else cleaned
    minimum = float(np.min(amplitude))
    maximum = float(np.max(amplitude))
    return WaveformMeasurements(
        minimum_v=minimum,
        maximum_v=maximum,
        mean_v=float(np.mean(amplitude)),
        vpp_v=maximum - minimum,
        frequency_hz=zero_crossing_frequency(values, sample_rate_hz),
    )
