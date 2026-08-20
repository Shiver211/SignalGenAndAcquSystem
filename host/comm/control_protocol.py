"""M3/M7 UART 控制协议的编码、解析和参数构造。"""

from __future__ import annotations

import struct
from dataclasses import dataclass
from enum import IntEnum


class Command(IntEnum):
    SET_GENERATOR = 0x01
    SET_ACQUISITION = 0x02
    SET_PROCESSING = 0x03
    ARM = 0x04
    STOP = 0x05
    ENVELOPE_ENABLE = 0x06
    QUERY_STATUS = 0x07
    REQUEST_RAW = 0x08
    REQUEST_RETRANSMIT = 0x09
    SET_CALIBRATION = 0x0A
    CLEAR_ERRORS = 0x0B


class StatusCode(IntEnum):
    OK = 0x00
    CRC_ERROR = 0x01
    UNKNOWN_CMD = 0x02
    INVALID_PARAM = 0x03
    BUSY = 0x04
    NO_FRAME = 0x05
    INTERNAL_ERROR = 0x06


class Waveform(IntEnum):
    SINE = 0
    TRIANGLE = 1
    SQUARE = 2


class DataMode(IntEnum):
    RAW = 0
    ENVELOPE = 1
    DECIMATED = 2


class ProtocolError(ValueError):
    pass


def crc8_atm(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def encode_request(command: int | Command, payload: bytes = b"") -> bytes:
    if len(payload) > 255:
        raise ValueError("UART payload 不能超过 255 字节")
    body = bytes((int(command), len(payload))) + payload
    return b"\xAA\x55" + body + bytes((crc8_atm(body),))


@dataclass(frozen=True)
class Response:
    command: int
    status: int
    payload: bytes

    @property
    def ok(self) -> bool:
        return self.status == StatusCode.OK

    @property
    def status_name(self) -> str:
        try:
            return StatusCode(self.status).name
        except ValueError:
            return f"UNKNOWN_STATUS_0x{self.status:02X}"


class ResponseParser:
    """可增量喂入串口字节流，并自动跳过帧头前的噪声。"""

    def __init__(self) -> None:
        self._buffer = bytearray()

    def feed(self, data: bytes) -> list[Response]:
        self._buffer.extend(data)
        responses: list[Response] = []
        while True:
            start = self._buffer.find(b"\x55\xAA")
            if start < 0:
                if self._buffer[-1:] == b"\x55":
                    self._buffer[:] = b"\x55"
                else:
                    self._buffer.clear()
                break
            if start:
                del self._buffer[:start]
            if len(self._buffer) < 6:
                break
            length = self._buffer[4]
            frame_length = 6 + length
            if len(self._buffer) < frame_length:
                break
            frame = bytes(self._buffer[:frame_length])
            del self._buffer[:frame_length]
            body = frame[2:-1]
            if crc8_atm(body) != frame[-1]:
                raise ProtocolError("UART 应答 CRC8 错误")
            responses.append(Response(frame[2], frame[3], frame[5:-1]))
        return responses


def generator_payload(
    channel: int,
    waveform: int | Waveform,
    frequency_hz: float,
    amplitude_vpk: float,
    *,
    dc_code: int = 0x8000,
    update_rate_hz: float = 1_388_888.888888889,
    commit: bool = True,
) -> bytes:
    if channel not in (1, 2):
        raise ValueError("通道必须为 1 或 2")
    if not 0 <= frequency_hz <= 50_000:
        raise ValueError("输出频率必须在 0..50000Hz")
    if not 0 <= amplitude_vpk <= 5:
        raise ValueError("输出幅度必须在 0..5Vpk")
    ftw = round(frequency_hz * (1 << 32) / update_rate_hz)
    amplitude_q15 = round(amplitude_vpk / 5.0 * 0x8000)
    return struct.pack(
        "<BBIHHB", channel - 1, int(waveform), ftw,
        amplitude_q15, dc_code, int(commit),
    )


def acquisition_payload(
    source: int,
    threshold_code: int,
    hysteresis_code: int,
    edge: int,
    capture_depth: int,
    pretrigger_percent: float,
    *,
    channel_mask: int = 0x03,
    commit: bool = True,
) -> bytes:
    if source not in (0, 1) or edge not in (0, 1):
        raise ValueError("触发源和边沿只能为 0 或 1")
    if not 0 <= threshold_code <= 4095 or not 0 <= hysteresis_code <= 4095:
        raise ValueError("触发码值必须在 0..4095")
    if not 1 <= capture_depth <= 58_720_256:
        raise ValueError("采集深度超出 RAW 分区容量")
    if not 0 <= pretrigger_percent <= 100:
        raise ValueError("预触发比例必须在 0..100%")
    if channel_mask not in (1, 2, 3):
        raise ValueError("通道掩码必须为 1(CH1)、2(CH2) 或 3(双通道)")
    return struct.pack(
        "<BHHBIHBB", source, threshold_code, hysteresis_code, edge,
        capture_depth, round(pretrigger_percent * 10), int(commit), channel_mask,
    )


def processing_payload(
    mode: int | DataMode,
    decimation: int,
    display_points: int,
    refresh_hz: float,
    *,
    commit: bool = True,
) -> bytes:
    if decimation < 1 or decimation > 1024 or decimation & (decimation - 1):
        raise ValueError("抽取倍率必须是 1..1024 的 2 次幂")
    if display_points < 1 or refresh_hz <= 0:
        raise ValueError("显示点数和刷新率必须大于 0")
    return struct.pack(
        "<BIIIB", int(mode), decimation, display_points,
        round(refresh_hz * 1000), int(commit),
    )


def calibration_payload(
    channel: int,
    gain: float,
    offset_code: int,
    *,
    commit: bool = True,
) -> bytes:
    gain_q15 = round(gain * 0x8000)
    if channel not in (1, 2) or not 0x4000 <= gain_q15 <= 0xC000:
        raise ValueError("通道必须为 1/2，增益必须在 0.5..1.5")
    if not -32768 <= offset_code <= 32767:
        raise ValueError("偏移必须为 int16 DAC LSB")
    return struct.pack("<BHhB", channel - 1, gain_q15, offset_code, int(commit))


def raw_request_payload(frame_id: int) -> bytes:
    return struct.pack("<I", frame_id)


def retransmit_payload(frame_id: int, offset: int, length: int) -> bytes:
    if not 0 <= offset <= 0xFFFFFFFF or not 1 <= length <= 0xFFFF:
        raise ValueError("重传范围非法")
    return struct.pack("<IIH", frame_id, offset, length)


def parse_device_status(payload: bytes) -> dict[str, object]:
    if len(payload) != 32:
        raise ProtocolError(f"状态长度应为 32，实际为 {len(payload)}")
    flags = payload[5]
    return {
        "protocol_version": f"{payload[0]}.{payload[1]}",
        "firmware_version": f"{payload[2]}.{payload[3]}.{payload[4]}",
        "control_busy": bool(flags & 0x01),
        "adc_armed": bool(flags & 0x02),
        "envelope_enabled": bool(flags & 0x04),
        "ddr_calibrated": bool(flags & 0x08),
        "network_link_up": bool(flags & 0x10),
        "adc_clock_alive": bool(flags & 0x20),
        "mmcm_locked": bool(flags & 0x40),
        "last_error": payload[6],
        "crc_error_count": struct.unpack_from("<I", payload, 8)[0],
        "uart_frame_error_count": struct.unpack_from("<I", payload, 12)[0],
        "command_error_count": struct.unpack_from("<I", payload, 16)[0],
        "dac_update_rate_ch1_hz": struct.unpack_from("<I", payload, 20)[0],
        "dac_update_rate_ch2_hz": struct.unpack_from("<I", payload, 24)[0],
        "config_sequence": struct.unpack_from("<H", payload, 28)[0],
        "adc_clear_count": struct.unpack_from("<H", payload, 30)[0],
    }
