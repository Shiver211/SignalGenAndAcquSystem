"""M7 UDP 接收、校验、重组、缺块检测和可选 UART 重传测试工具。"""

from __future__ import annotations

import argparse
import binascii
import socket
import struct
import time
from dataclasses import dataclass, field


HEADER = struct.Struct("<HBBIIIIBBHIHH")


def crc8_atm(data: bytes) -> int:
    value = 0
    for byte in data:
        value ^= byte
        for _ in range(8):
            value = ((value << 1) ^ 0x07) & 0xFF if value & 0x80 else (value << 1) & 0xFF
    return value


def retransmit_command(frame_id: int, offset: int, length: int) -> bytes:
    payload = struct.pack("<IIH", frame_id, offset, length)
    body = bytes((0x09, len(payload))) + payload
    return b"\xAA\x55" + body + bytes((crc8_atm(body),))


def parse_packet(datagram: bytes) -> tuple[dict[str, int], bytes]:
    if len(datagram) < 36:
        raise ValueError("数据包短于 36 字节")
    fields = HEADER.unpack_from(datagram)
    payload_length = fields[11]
    expected_length = 32 + payload_length + 4
    if fields[0] != 0xA55A or fields[1] != 1:
        raise ValueError("MAGIC/VERSION 错误")
    if len(datagram) != expected_length:
        raise ValueError(f"长度错误 expected={expected_length} actual={len(datagram)}")
    received_crc = struct.unpack_from("<I", datagram, 32 + payload_length)[0]
    calculated_crc = binascii.crc32(datagram[2 : 32 + payload_length]) & 0xFFFFFFFF
    if received_crc != calculated_crc:
        raise ValueError("应用 CRC32 错误")
    names = (
        "magic", "version", "type", "frame_id", "total_samples",
        "sample_rate_hz", "trigger_index", "channel_mask", "sample_format",
        "chunk_index", "chunk_offset", "payload_len", "flags",
    )
    return dict(zip(names, fields)), datagram[32 : 32 + payload_length]


def expected_bytes(header: dict[str, int]) -> int | None:
    return {
        0x01: header["total_samples"] * 4,
        0x02: header["total_samples"] * 8,
        0x03: header["payload_len"],
    }.get(header["type"])


@dataclass
class Frame:
    frame_id: int
    data_type: int
    total_bytes: int
    created: float = field(default_factory=time.monotonic)
    chunks: dict[int, bytes] = field(default_factory=dict)

    def add(self, offset: int, payload: bytes) -> None:
        self.chunks[offset] = payload

    def missing(self, chunk_size: int = 1400) -> list[tuple[int, int]]:
        result = []
        for offset in range(0, self.total_bytes, chunk_size):
            length = min(chunk_size, self.total_bytes - offset)
            if offset not in self.chunks:
                result.append((offset, length))
        return result

    def complete(self) -> bool:
        return not self.missing()

    def assemble(self) -> bytes:
        output = bytearray(self.total_bytes)
        for offset, payload in self.chunks.items():
            output[offset : offset + len(payload)] = payload
        return bytes(output)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=5000)
    parser.add_argument("--timeout", type=float, default=5.0)
    parser.add_argument("--drop-every", type=int, default=0, help="人为丢弃每 N 个包")
    parser.add_argument("--serial", help="可选串口，例如 COM5")
    parser.add_argument("--baud", type=int, default=921600)
    args = parser.parse_args()

    serial_port = None
    if args.serial:
        import serial  # type: ignore[import-not-found]

        serial_port = serial.Serial(args.serial, args.baud, timeout=0.2)

    frames: dict[tuple[int, int], Frame] = {}
    packet_count = 0
    byte_count = 0
    start_time = time.monotonic()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    sock.settimeout(0.2)
    print(f"监听 UDP {args.bind}:{args.port}")

    try:
        while time.monotonic() - start_time < args.timeout:
            try:
                datagram, address = sock.recvfrom(2048)
            except TimeoutError:
                continue
            packet_count += 1
            if args.drop_every and packet_count % args.drop_every == 0:
                continue
            try:
                header, payload = parse_packet(datagram)
            except ValueError as error:
                print(f"丢弃 {address}：{error}")
                continue
            byte_count += len(payload)
            total = expected_bytes(header)
            if total is None:
                continue
            key = (header["type"], header["frame_id"])
            frame = frames.setdefault(key, Frame(header["frame_id"], header["type"], total))
            frame.add(header["chunk_offset"], payload)
            if frame.complete():
                elapsed = max(time.monotonic() - start_time, 1e-9)
                print(
                    f"完成 TYPE={frame.data_type} FRAME_ID={frame.frame_id} "
                    f"bytes={frame.total_bytes} rate={byte_count / elapsed / 1e6:.2f}MB/s"
                )
                del frames[key]
    finally:
        sock.close()

    for frame in frames.values():
        missing = frame.missing()
        print(f"缺块 TYPE={frame.data_type} FRAME_ID={frame.frame_id}: {missing[:16]}")
        if serial_port and frame.data_type == 0x01:
            for offset, length in missing:
                serial_port.write(retransmit_command(frame.frame_id, offset, length))
    if serial_port:
        serial_port.close()
    elapsed = max(time.monotonic() - start_time, 1e-9)
    print(f"M7_UDP_TEST_DONE packets={packet_count} payload={byte_count} rate={byte_count / elapsed / 1e6:.2f}MB/s")


if __name__ == "__main__":
    main()

