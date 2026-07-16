from __future__ import annotations

import binascii
import random
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent
VECTOR_DIR = ROOT / "vectors"

LOCAL_MAC = bytes.fromhex("020000000001")
REMOTE_MAC = bytes.fromhex("020000000002")
LOCAL_IP = bytes((192, 168, 1, 10))
REMOTE_IP = bytes((192, 168, 1, 100))
UDP_PORT = 5000


def crc32(data: bytes) -> int:
    return binascii.crc32(data) & 0xFFFFFFFF


def ipv4_checksum(header: bytes) -> int:
    total = sum(struct.unpack("!10H", header))
    total = (total & 0xFFFF) + (total >> 16)
    total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


def application_packet(
    payload: bytes,
    *,
    data_type: int = 1,
    frame_id: int = 0x11223344,
    total_samples: int = 100_000,
    sample_rate_hz: int = 65_000_000,
    trigger_index: int = 12_345,
    sample_format: int = 1,
    chunk_index: int = 2,
    chunk_offset: int = 2_800,
    flags: int = 3,
) -> bytes:
    header = struct.pack(
        "<HBBIIIIBBH IHH".replace(" ", ""),
        0xA55A,
        1,
        data_type,
        frame_id,
        total_samples,
        sample_rate_hz,
        trigger_index,
        0x03,
        sample_format,
        chunk_index & 0xFFFF,
        chunk_offset,
        len(payload),
        flags,
    )
    assert len(header) == 32
    return header + payload + struct.pack("<I", crc32(header[2:] + payload))


def udp_ethernet_frame(udp_payload: bytes, identification: int = 0) -> bytes:
    udp_header = struct.pack("!HHHH", UDP_PORT, UDP_PORT, 8 + len(udp_payload), 0)
    ip_without_checksum = struct.pack(
        "!BBHHHBBH4s4s",
        0x45,
        0,
        20 + len(udp_header) + len(udp_payload),
        identification,
        0x4000,
        64,
        17,
        0,
        LOCAL_IP,
        REMOTE_IP,
    )
    checksum = ipv4_checksum(ip_without_checksum)
    ip_header = ip_without_checksum[:10] + struct.pack("!H", checksum) + ip_without_checksum[12:]
    ethernet = REMOTE_MAC + LOCAL_MAC + b"\x08\x00" + ip_header + udp_header + udp_payload
    if len(ethernet) < 60:
        ethernet += bytes(60 - len(ethernet))
    return b"\x55" * 7 + b"\xD5" + ethernet + struct.pack("<I", crc32(ethernet))


def parse_application_packet(packet: bytes) -> tuple[dict[str, int], bytes]:
    if len(packet) < 36:
        raise ValueError("packet too short")
    fields = struct.unpack("<HBBIIIIBBHIHH", packet[:32])
    payload_len = fields[11]
    payload = packet[32 : 32 + payload_len]
    expected_crc = struct.unpack("<I", packet[32 + payload_len : 36 + payload_len])[0]
    if crc32(packet[2 : 32 + payload_len]) != expected_crc:
        raise ValueError("application CRC mismatch")
    return {
        "magic": fields[0],
        "version": fields[1],
        "type": fields[2],
        "frame_id": fields[3],
        "total_samples": fields[4],
        "sample_rate_hz": fields[5],
        "trigger_index": fields[6],
        "channel_mask": fields[7],
        "sample_format": fields[8],
        "chunk_index": fields[9],
        "chunk_offset": fields[10],
        "payload_len": payload_len,
        "flags": fields[12],
    }, payload


def verify_large_reassembly() -> None:
    source = bytes((index * 13 + 7) & 0xFF for index in range(70_000))
    packets = []
    for chunk_index, offset in enumerate(range(0, len(source), 1_400)):
        payload = source[offset : offset + 1_400]
        packets.append(
            application_packet(
                payload,
                total_samples=len(source) // 4,
                chunk_index=chunk_index,
                chunk_offset=offset,
                flags=(1 if offset == 0 else 0) | (2 if offset + len(payload) == len(source) else 0),
            )
        )
    random.Random(7).shuffle(packets)
    output = bytearray(len(source))
    seen: set[int] = set()
    for packet in packets:
        header, payload = parse_application_packet(packet)
        offset = header["chunk_offset"]
        output[offset : offset + len(payload)] = payload
        seen.add(offset)
    assert bytes(output) == source
    assert len(seen) == 50


def main() -> None:
    VECTOR_DIR.mkdir(parents=True, exist_ok=True)
    payload = bytes(range(32))
    expected = udp_ethernet_frame(application_packet(payload))
    (VECTOR_DIR / "m7_udp_expected.mem").write_text(
        "".join(f"{byte:02x}\n" for byte in expected), encoding="ascii"
    )
    verify_large_reassembly()
    print(f"M7_PYTHON_REFERENCE_PASS frame_bytes={len(expected)} chunks=50")


if __name__ == "__main__":
    main()

