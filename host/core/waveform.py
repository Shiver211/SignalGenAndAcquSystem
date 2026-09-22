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


def _sine_trigger_position(values: np.ndarray) -> float | None:
    """由正弦相位估计首点附近的上升交点；只用于时间对齐，不生成显示幅值。"""
    if len(values) < 12 or np.ptp(values) < 16:
        return None
    # 正弦相邻点满足 y[n-1]+y[n+1]=2*cos(w)*y[n]+常数。
    # 先用轻度平滑数据估计角频率，半个周期的短帧也能使用。
    pilot = smooth_binomial_5(values)[2:-2]
    recurrence = np.column_stack((pilot[1:-1], np.ones(len(pilot) - 2)))
    cosine_step = np.linalg.lstsq(recurrence, pilot[:-2] + pilot[2:], rcond=None)[0][0] / 2
    if not -1 < cosine_step < 1:
        return None
    omega = np.arccos(cosine_step)
    x = np.arange(len(values), dtype=np.float64)
    # 在原始码值上联合细化频率、相位及直流量，消除短窗均值偏移的影响。
    for _ in range(3):
        sine, cosine = np.sin(omega * x), np.cos(omega * x)
        basis = np.column_stack((sine, cosine, np.ones(len(values))))
        coefficients = np.linalg.lstsq(basis, values, rcond=None)[0]
        derivative = x * (coefficients[0] * cosine - coefficients[1] * sine)
        correction = np.linalg.lstsq(
            np.column_stack((basis, derivative)), values - basis @ coefficients, rcond=None,
        )[0][-1]
        omega += correction
        if not 0 < omega < np.pi:
            return None
    basis = np.column_stack((np.sin(omega * x), np.cos(omega * x), np.ones(len(values))))
    a, b, dc = np.linalg.lstsq(basis, values, rcond=None)[0]
    amplitude = np.hypot(a, b)
    residual = np.sqrt(np.mean((values - basis @ np.array([a, b, dc])) ** 2))
    # 至少四分之一周期、足够的幅度和拟合质量，才接受正弦模型。
    if (amplitude < 16 or omega * (len(values) - 1) < np.pi / 2 or
            residual > amplitude * 0.05 or abs(dc) >= amplitude):
        return None
    period = 2 * np.pi / omega
    position = (np.arcsin(-dc / amplitude) - np.arctan2(b, a)) / omega
    position = (position + period / 2) % period - period / 2
    # 硬件已捕获首个越阈值样本，只修正附近的采样量化/噪声误差。
    return float(position) if -1.5 <= position <= 0.5 else None


def _square_trigger_position(values: np.ndarray) -> float | None:
    """用重复边沿反推帧首附近的触发交点，输入已按触发电平和方向归一化。"""
    levels = _square_levels(values)
    if levels is None or not levels.low < 0 < levels.high:
        return None
    edges = np.flatnonzero((values[1:] >= 0) != (values[:-1] >= 0)) + 1
    # 首点已越过触发电平：至少还需下降、上升、下降三个边沿来区分周期与脉宽。
    if len(edges) < 3:
        return None
    crossings = edges - 1 - values[edges - 1] / (values[edges] - values[edges - 1])
    rising = values[edges] >= 0
    cycles = (np.arange(len(edges)) + 1) // 2
    # 上升沿 t=起点+k*周期；下降沿 t=起点+k*周期+高电平宽度。
    # 脉宽独立拟合，不假定 50% 占空比；最终仅把公共起点交给显示层。
    basis = np.column_stack((np.ones(len(edges)), cycles, ~rising))
    coefficients = np.linalg.lstsq(basis, crossings, rcond=None)[0]
    position, period, width = coefficients
    # 非周期毛刺、离触发点过远的自动帧，不能据后续边沿重新锁定相位。
    if (not -1.5 <= position <= 0.5 or not 0 < width < period or
            np.max(np.abs(crossings - basis @ coefficients)) > 0.25):
        return None
    return float(position)


def refine_trigger_position(
    samples: np.ndarray, level: float, *, falling: bool = False,
) -> float | None:
    """细化连续帧起点的触发位置，返回相对首点的浮点样本下标。

    输入须为触发通道未压缩的 ADC 码，level 是计入迟滞后的实际触发电平。
    正弦按相位求交点，周期性方波用重复边沿反推起点，其他波形尝试局部
    斜率拟合。估计不可靠时返回 None，保留硬件给出的起点。
    """
    values = (np.asarray(samples[:256], dtype=np.float64) - level) * (
        -1.0 if falling else 1.0
    )
    if len(values) < 12 or values[0] < 0:
        return None
    position = _sine_trigger_position(values)
    if position is not None:
        return position
    position = _square_trigger_position(values)
    if position is not None:
        return position
    if len(values) < 16:
        return None

    # 64 码约为 ADC 满量程的 1.6%。缓慢边沿需要更多点来区分斜率与噪声。
    for size in (16, 32, 64, 128, 256):
        if size > len(values):
            break
        y = values[:size]
        x = np.arange(size, dtype=np.float64)
        centered_x = x - x.mean()
        slope = float(np.dot(centered_x, y) / np.dot(centered_x, centered_x))
        intercept = float(y.mean() - slope * x.mean())
        span = slope * (size - 1)
        if span >= 64.0:
            break

    residual = float(np.sqrt(np.mean((y - (slope * x + intercept)) ** 2)))
    if span < max(8.0, 6.0 * residual):
        return None
    # 两半斜率应接近，避免把正弦峰顶、方波跳变或多个周期拟合成直线。
    half = len(y) // 2
    half_x = np.arange(half, dtype=np.float64) - (half - 1) / 2
    half_slopes = y.reshape(2, half) @ half_x / np.dot(half_x, half_x)
    if np.max(np.abs(half_slopes - slope)) > slope * 0.5:
        return None
    position = -intercept / slope
    # 当前协议不区分自动超时帧；只接受首点附近的交点，不另找后续边沿。
    if abs(position) > len(y) / 4:
        return None
    return float(position)


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
    return np.convolve(padded, np.array([1.0, 4.0, 6.0, 4.0, 1.0]) / 16.0, mode="valid")


def smooth_continuous_display(
    samples: np.ndarray, sample_rate_hz: float, *, start_frequency_hz: float = 500_000,
) -> np.ndarray:
    """达到本通道起始频率时做保峰的局部二次拟合，仅返回显示副本。

    两路独立估频并使用相同规则：窗口约为周期的 30%，限制为 5..21 点。
    对称拟合保留峰谷曲率及相位；按当前帧采样率检查正弦增益，幅度衰减
    超过 0.5% 时旁路。低频、周期不明、明显跳变和窄脉冲保留原样。
    """
    values = np.asarray(samples, dtype=np.float64)
    if values.size < 16:
        return values.copy()
    span = float(np.ptp(values))
    if span == 0:
        return values.copy()
    # 五点平均仅辅助估频，避免零点抖动重复计数，不作为最终显示滤波。
    frequency = zero_crossing_frequency(smooth_binomial_5(values), sample_rate_hz)
    # 入口留 1% 估频余量，避免同一信号在临界值两侧反复切换。
    if frequency <= 0 or frequency < start_frequency_hz * 0.99:
        return values.copy()
    period = sample_rate_hz / frequency
    # 正弦本身的相邻差随频率增加，不能固定以满幅 10% 拒绝高频正弦。
    step_limit = span * max(0.1, 2 * np.sin(np.pi / period))
    if np.max(np.abs(np.diff(values))) > step_limit:
        return values.copy()
    window = min(21, max(5, int(period * 0.3) | 1))
    if values.size < window:
        return values.copy()
    half = window // 2
    offsets = np.arange(-half, half + 1, dtype=np.float64)
    # Savitzky–Golay 二次拟合：中心值是常数项，无需新增 SciPy 依赖。
    basis = np.column_stack((np.ones(window), offsets, offsets ** 2))
    weights = np.linalg.pinv(basis)[0]
    gain = float(weights @ np.cos(2 * np.pi * offsets / period))
    if abs(gain - 1.0) > 0.005:
        return values.copy()
    result = values.copy()
    # 首尾没有完整邻域，保留原值；内部窗口对称，不改动时间坐标。
    result[half:-half] = np.convolve(values, weights, mode="valid")
    return result


@dataclass(frozen=True)
class _SquareLevels:
    center: np.ndarray
    state: np.ndarray
    narrow: np.ndarray
    residual: np.ndarray
    low: float
    high: float
    span: float


def _square_levels(
    minimum: np.ndarray, maximum: np.ndarray | None = None,
) -> _SquareLevels | None:
    """估计高低平台。不要求能画出竖边沿，供幅度测量单独使用。"""
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
    if min(np.count_nonzero(low_samples), np.count_nonzero(high_samples)) < 3:
        return None
    low = float(np.median(center[low_samples]))
    high = float(np.median(center[high_samples]))
    span = high - low
    if span <= 0:
        return None
    residual = np.abs(center - np.where(state, high, low))
    # 只忽略横跨高低电平的边沿桶；斜坡上的部分幅度桶必须计入，
    # 否则密集正弦的峰谷窄桶会被误判为方波平台。
    edge = (hi - lo) >= span * 0.5
    plateau = residual[~edge]
    if plateau.size == 0 or np.mean(plateau <= span * 0.08) < 0.8:
        return None
    return _SquareLevels(center, state, narrow, residual, low, high, span)


def _prepare_square_waveform(
    minimum: np.ndarray, maximum: np.ndarray | None = None,
) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    """显示用的方波清理，不修改原始采样。

    高低平台须能独立辨认。按平台偏差中位数保留小抖动，异常值回到平台；
    短于典型平台 15% 的内部反向脉冲视作毛刺。完整跳变只在
    50% 电平交点插入一对同 X 坐标的端点，不把过渡样本画成多级台阶。
    压缩包络只能估计交点；平台不可分辨时返回 None，继续显示原包络。
    """
    levels = _square_levels(minimum, maximum)
    if levels is None or np.count_nonzero(levels.narrow) < len(levels.center) * 0.25:
        return None
    center, state, narrow, residual = (
        levels.center, levels.state, levels.narrow, levels.residual,
    )
    low, high, span = levels.low, levels.high, levels.span

    boundaries = np.r_[0, np.flatnonzero(state[1:] != state[:-1]) + 1, len(center)]
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


def square_plateau_stats(
    minimum: np.ndarray, maximum: np.ndarray | None = None,
) -> tuple[float, float, float] | None:
    """方波高低平台和占空比加权均值；不含过冲与平台抖动。

    包络密到无法画竖边沿时，只要还能辨认平台仍返回电平。非方波返回 None。
    """
    levels = _square_levels(minimum, maximum)
    if levels is None:
        return None
    mean = float(np.mean(np.where(levels.state, levels.high, levels.low)))
    return levels.low, levels.high, mean


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
    """方波幅度按平台电平计算，频率仍由原始采样估计。"""
    values = np.asarray(samples_v, dtype=np.float64)
    if values.size == 0:
        return WaveformMeasurements(0.0, 0.0, 0.0, 0.0, 0.0)
    stats = square_plateau_stats(values)
    if stats is None:
        minimum = float(np.min(values))
        maximum = float(np.max(values))
        mean = float(np.mean(values))
    else:
        minimum, maximum, mean = stats
    return WaveformMeasurements(
        minimum_v=minimum,
        maximum_v=maximum,
        mean_v=mean,
        vpp_v=maximum - minimum,
        frequency_hz=zero_crossing_frequency(values, sample_rate_hz),
    )
