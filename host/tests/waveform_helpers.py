"""带有限上升时间和重复过冲的模拟采样，不依赖真实设备。"""

import numpy as np


def square_with_overshoot(sample_count: int = 640, period: int = 64) -> np.ndarray:
    indices = np.arange(sample_count)
    values = np.where((indices + period // 4) % period < period / 2, -1.0, 1.0)
    edges = np.flatnonzero(values[1:] != values[:-1]) + 1
    for edge in edges[edges + 4 <= len(values)]:
        direction = values[edge]
        values[edge:edge + 4] = direction * np.array([0.35, 1.20, 1.08, 1.02])
    return values


def sampled_square_with_overshoot(
    frequency_hz: float, sample_count: int = 650, phase_samples: float = 0.1,
) -> np.ndarray:
    """在连续边沿响应上取样，保留非整数周期引起的亚采样相位变化。

    响应以 ADC 采样间隔为时间单位；同一个模拟尖峰在不同相位下会落在
    不同样点上，离散峰值也不同，不能在每个整数边沿后复制固定数组。
    """
    time = np.arange(sample_count, dtype=np.float64) + phase_samples
    half_period = 65_000_000 / frequency_hz / 2
    age = time % half_period
    direction = np.where(np.floor(time / half_period).astype(np.int64) % 2 == 0, 1.0, -1.0)
    response = np.interp(
        age, [0, 1, 1.3, 1.65, 2.4, 3.8, 6],
        [-1, 0.35, 1.22, 1.12, 1.06, 1.008, 1],
    )
    return direction * response
