"""M7 UDP 应用协议与四种数据格式解析。"""

from __future__ import annotations

import binascii
import struct
from dataclasses import dataclass
from enum import IntEnum

import numpy as np


HEADER = struct.Struct("<HBBIIIIBBHIHH")
MEASUREMENT_V1 = struct.Struct("<HHHHIIHHIIIIIIBB")


class DataType(IntEnum):
    RAW_FRAME = 0x01
    ENVELOPE_FRAME = 0x02
    MEASUREMENT = 0x03
    STATUS = 0x04


class SampleFormat(IntEnum):
    RAW32 = 0x01
    ENVELOPE64 = 0x02
    MEASUREMENT_V1 = 0x03
    DECIMATED32 = 0x04


class DatagramError(ValueError):
    pass


@dataclass(frozen=True)
class PacketHeader:
    version: int
    data_type: int
    frame_id: int
    total_samples: int
    sample_rate_hz: int
    trigger_index: int
    channel_mask: int
    sample_format: int
    chunk_index: int
    chunk_offset: int
    payload_len: int
    flags: int


@dataclass(frozen=True)
class CompletedFrame:
    header: PacketHeader
    payload: bytes


@dataclass(frozen=True)
class Measurement:
    min_a: int
    max_a: int
    min_b: int
    max_b: int
    mean_a: int
    mean_b: int
    vpp_a: int
    vpp_b: int
    otr_count_a: int
    otr_count_b: int
    period_samples_a: int
    period_samples_b: int
    frequency_hz_a: int
    frequency_hz_b: int
    period_valid_a: bool
    period_valid_b: bool
    calculation_overrun: bool


def parse_packet(datagram: bytes) -> tuple[PacketHeader, bytes]:
    if len(datagram) < 36:
        raise DatagramError("UDP 应用包短于 36 字节")
    fields = HEADER.unpack_from(datagram)
    if fields[0] != 0xA55A or fields[1] != 1:
        raise DatagramError("MAGIC 或 VERSION 错误")
    payload_len = fields[11]
    if payload_len > 1400:
        raise DatagramError("应用负载超过 1400 字节")
    expected_len = 32 + payload_len + 4
    if len(datagram) != expected_len:
        raise DatagramError(f"包长错误：期望 {expected_len}，实际 {len(datagram)}")
    received_crc = struct.unpack_from("<I", datagram, 32 + payload_len)[0]
    calculated_crc = binascii.crc32(datagram[2 : 32 + payload_len]) & 0xFFFFFFFF
    if received_crc != calculated_crc:
        raise DatagramError("应用 CRC32 错误")
    header = PacketHeader(
        version=fields[1], data_type=fields[2], frame_id=fields[3],
        total_samples=fields[4], sample_rate_hz=fields[5],
        trigger_index=fields[6], channel_mask=fields[7],
        sample_format=fields[8], chunk_index=fields[9],
        chunk_offset=fields[10], payload_len=payload_len, flags=fields[12],
    )
    return header, datagram[32 : 32 + payload_len]


def build_packet(header: PacketHeader, payload: bytes) -> bytes:
    raw_header = HEADER.pack(
        0xA55A, header.version, header.data_type, header.frame_id,
        header.total_samples, header.sample_rate_hz, header.trigger_index,
        header.channel_mask, header.sample_format, header.chunk_index,
        header.chunk_offset, len(payload), header.flags,
    )
    crc = binascii.crc32(raw_header[2:] + payload) & 0xFFFFFFFF
    return raw_header + payload + struct.pack("<I", crc)


def expected_payload_bytes(header: PacketHeader) -> int:
    if header.sample_format in (SampleFormat.RAW32, SampleFormat.DECIMATED32):
        return header.total_samples * 4
    if header.sample_format == SampleFormat.ENVELOPE64:
        return header.total_samples * 8
    if header.sample_format == SampleFormat.MEASUREMENT_V1:
        return 46
    return header.payload_len


def decode_raw32(payload: bytes) -> dict[str, np.ndarray]:
    if len(payload) % 4:
        raise ValueError("RAW32 数据长度必须为 4 的倍数")
    words = np.frombuffer(payload, dtype="<u4")
    return {
        "a": (words & 0xFFF).astype(np.uint16),
        "b": ((words >> 12) & 0xFFF).astype(np.uint16),
        "otr_a": ((words >> 24) & 1).astype(bool),
        "otr_b": ((words >> 25) & 1).astype(bool),
    }


def decode_envelope64(payload: bytes) -> dict[str, np.ndarray]:
    if len(payload) % 8:
        raise ValueError("ENVELOPE64 数据长度必须为 8 的倍数")
    values = np.frombuffer(payload, dtype="<u2").reshape(-1, 4)
    return {
        "min_a": values[:, 0] & 0xFFF,
        "max_a": values[:, 1] & 0xFFF,
        "min_b": values[:, 2] & 0xFFF,
        "max_b": values[:, 3] & 0xFFF,
    }


def decode_measurement_v1(payload: bytes) -> Measurement:
    if len(payload) != MEASUREMENT_V1.size:
        raise ValueError(f"MEASUREMENT_V1 长度应为 46，实际为 {len(payload)}")
    v = MEASUREMENT_V1.unpack(payload)
    return Measurement(
        min_a=v[0] & 0xFFF, max_a=v[1] & 0xFFF,
        min_b=v[2] & 0xFFF, max_b=v[3] & 0xFFF,
        mean_a=v[4], mean_b=v[5], vpp_a=v[6] & 0xFFF, vpp_b=v[7] & 0xFFF,
        otr_count_a=v[8], otr_count_b=v[9], period_samples_a=v[10],
        period_samples_b=v[11], frequency_hz_a=v[12], frequency_hz_b=v[13],
        period_valid_a=bool(v[14] & 1), period_valid_b=bool(v[14] & 2),
        calculation_overrun=bool(v[15] & 1),
    )
