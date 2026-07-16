"""波形码值换算、FFT、过零频率和上位机测量复算。"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np


ADC_FULL_SCALE_VOLTS = 10.0
ADC_MAX_CODE = 4095.0


@dataclass(frozen=True)
class WaveformMeasurements:
    minimum_v: float
    maximum_v: float
    mean_v: float
    vpp_v: float
    frequency_hz: float


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
