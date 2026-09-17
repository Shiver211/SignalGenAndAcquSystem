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


def _repeated_edge_matches(excess: np.ndarray, tolerance: float) -> np.ndarray:
    """允许多种采样相位的重复形态，独立异常峰没有匹配对象便保留。"""
    # 峰的位置会随亚采样相位和抽桶边界改变，比较幅度分布而非固定列。
    profiles = np.sort(excess, axis=1)
    peaks = profiles[:, -1]
    matches = np.zeros(len(profiles), dtype=bool)
    # 每个边沿只与邻近八次同向边沿比较，避免长帧进行全量两两比较。
    for distance in range(1, min(len(profiles), 9)):
        smaller_peak = np.minimum(peaks[:-distance], peaks[distance:])
        allowed = np.maximum(tolerance * 2.0, smaller_peak * 0.5)
        repeated = ((smaller_peak > tolerance)
                    & (np.max(np.abs(profiles[:-distance] - profiles[distance:]), axis=1)
                       <= allowed))
        matches[:-distance] |= repeated
        matches[distance:] |= repeated
    # 整体仍需至少三次且多数边沿得到重复验证，不能用两个偶发峰启动修整。
    if np.count_nonzero(matches) < max(3, int(np.ceil(len(profiles) * 0.6))):
        matches[:] = False
    return matches


def suppress_repeated_edge_overshoot(samples: np.ndarray) -> np.ndarray:
    """仅修整重复方波边沿后的同形过冲，供等间隔原始采样的显示使用。

    用双平台和持续电平跳变识别方波，再比较同方向边沿后的六个样本。
    至少三次且多数边沿有相近过冲才处理；独立尖峰、短脉冲和异常边沿
    保留。与重复过冲同相同形的毛刺无法区分，可关闭显示修整查看原始值。
    """
    values = np.asarray(samples, dtype=np.float64)
    result = values.copy()
    if values.size < 32:
        return result

    lower, upper = np.quantile(values, [0.1, 0.9])
    if upper <= lower:
        return result
    high_state = values > (lower + upper) / 2.0
    low = float(np.median(values[~high_state]))
    high = float(np.median(values[high_state]))
    span = high - low
    # 正弦/三角波没有占据大多数样本的两个稳定平台，不参与修整。
    residual = np.abs(values - np.where(high_state, high, low))
    if np.mean(residual <= span * 0.08) < 0.8:
        return result
    tolerance = max(span * 0.005, float(np.median(residual)) * 4.0)

    edges = np.flatnonzero(high_state[1:] != high_state[:-1]) + 1
    runs = np.diff(np.r_[0, edges, values.size])
    # 跳变两侧至少各持续十二点，避免把窄脉冲的边沿当作方波主边沿。
    edges = edges[(runs[:-1] >= 12) & (runs[1:] >= 12)]
    offsets = np.arange(6)
    for rising, level, previous in ((True, high, low), (False, low, high)):
        starts = edges[high_state[edges] == rising]
        if starts.size < 3:
            continue
        before = values[starts[:, None] + np.arange(-6, -3)]
        settled = values[starts[:, None] + np.arange(6, 10)]
        stable = ((np.max(np.abs(before - previous), axis=1) <= span * 0.08)
                  & (np.max(np.abs(settled - level), axis=1) <= span * 0.08))
        starts = starts[stable]
        if starts.size < 3:
            continue

        indices = starts[:, None] + offsets
        direction = 1.0 if rising else -1.0
        excess = np.maximum(direction * (values[indices] - level), 0.0)
        matches = _repeated_edge_matches(excess, tolerance)
        correction = matches[:, None] & (excess > tolerance)
        result[indices[correction]] = level
    return result


def suppress_envelope_edge_overshoot(
    minimum: np.ndarray, maximum: np.ndarray, samples_per_bucket: int,
) -> tuple[np.ndarray, np.ndarray]:
    """修整压缩包络的重复过冲，同时保留桶内独立毛刺的极值。

    桶内采样顺序已经丢失，因此从窄包络的平台估计高低电平，比较多次
    同向边沿附近的极值。比较排序后的过冲幅度，允许过冲落在相邻桶；
    平台不可分辨或边沿附近存在异常峰时保留原样。
    """
    lo = np.asarray(minimum, dtype=np.float64)
    hi = np.asarray(maximum, dtype=np.float64)
    if samples_per_bucket == 1:
        if np.array_equal(lo, hi):
            corrected = suppress_repeated_edge_overshoot(lo)
            return corrected, corrected.copy()
        return lo.copy(), hi.copy()
    result_lo, result_hi = lo.copy(), hi.copy()
    if lo.size < 16:
        return result_lo, result_hi

    center = (lo + hi) / 2.0
    lower, upper = np.quantile(center, [0.1, 0.9])
    if upper <= lower:
        return result_lo, result_hi
    high_state = center > (lower + upper) / 2.0
    # 跨越跳变的宽包络不能用来估计平台，否则过冲会抬高目标电平。
    narrow = hi - lo <= (upper - lower) * 0.08
    low_plateau, high_plateau = narrow & ~high_state, narrow & high_state
    if (np.count_nonzero(narrow) < lo.size * 0.25
            or min(np.count_nonzero(low_plateau), np.count_nonzero(high_plateau)) < 3):
        return result_lo, result_hi
    low = float(np.median(center[low_plateau]))
    high = float(np.median(center[high_plateau]))
    span = high - low
    residual = np.abs(center - np.where(high_state, high, low))
    if np.mean(residual[narrow] <= span * 0.08) < 0.8:
        return result_lo, result_hi
    tolerance = max(span * 0.005, float(np.median(residual[narrow])) * 4.0)

    edges = np.flatnonzero(high_state[1:] != high_state[:-1]) + 1
    runs = np.diff(np.r_[0, edges, lo.size])
    minimum_run = max(2, int(np.ceil(12 / samples_per_bucket)))
    edges = edges[(runs[:-1] >= minimum_run) & (runs[1:] >= minimum_run)]
    # 中心线跨阈值的桶可能比真实跳变晚一桶，前一桶也需参与比较。
    window = int(np.ceil(6 / samples_per_bucket)) + 1
    edges = edges[(edges >= 1) & (edges + window <= lo.size)]
    for rising, level in ((True, high), (False, low)):
        starts = edges[high_state[edges] == rising]
        if starts.size < 3:
            continue
        indices = starts[:, None] + np.arange(-1, window)
        excess = np.maximum(hi[indices] - level if rising else level - lo[indices], 0.0)
        matches = _repeated_edge_matches(excess, tolerance)
        corrected = indices[matches[:, None] & (excess > tolerance)]
        # 同时修整上下边界，中心线稍后由修整后的包络重新计算。
        if rising:
            result_lo[corrected] = np.minimum(result_lo[corrected], level)
            result_hi[corrected] = np.minimum(result_hi[corrected], level)
        else:
            result_lo[corrected] = np.maximum(result_lo[corrected], level)
            result_hi[corrected] = np.maximum(result_hi[corrected], level)
    return result_lo, result_hi


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
