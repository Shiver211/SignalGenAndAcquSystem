#!/usr/bin/env python3
"""M3 UART 控制协议调试工具。"""

from __future__ import annotations

import argparse
import json
import struct
import sys
from dataclasses import dataclass

import serial


CMD_SET_GENERATOR = 0x01
CMD_SET_ACQUISITION = 0x02
CMD_SET_PROCESSING = 0x03
CMD_ARM = 0x04
CMD_STOP = 0x05
CMD_ENVELOPE_ENABLE = 0x06
CMD_QUERY_STATUS = 0x07
CMD_REQUEST_RAW = 0x08
CMD_REQUEST_RETRANSMIT = 0x09
CMD_SET_CALIBRATION = 0x0A
CMD_CLEAR_ERRORS = 0x0B

STATUS_NAMES = {
    0x00: "OK",
    0x01: "CRC_ERROR",
    0x02: "UNKNOWN_CMD",
    0x03: "INVALID_PARAM",
    0x04: "BUSY",
    0x05: "NO_FRAME",
    0x06: "INTERNAL_ERROR",
}

WAVE_CODES = {"sine": 0, "triangle": 1, "square": 2}
MODE_CODES = {"raw": 0, "envelope": 1, "decimated": 2}


def crc8_atm(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = ((crc << 1) ^ 0x07) & 0xFF if crc & 0x80 else (crc << 1) & 0xFF
    return crc


def encode_request(command: int, payload: bytes = b"") -> bytes:
    if len(payload) > 255:
        raise ValueError("payload 不能超过 255 字节")
    body = bytes((command, len(payload))) + payload
    return b"\xAA\x55" + body + bytes((crc8_atm(body),))


def read_exact(port: serial.Serial, size: int) -> bytes:
    data = port.read(size)
    if len(data) != size:
        raise TimeoutError(f"串口超时：期望 {size} 字节，实际 {len(data)} 字节")
    return data


@dataclass
class Response:
    command: int
    status: int
    payload: bytes

    @property
    def status_name(self) -> str:
        return STATUS_NAMES.get(self.status, f"UNKNOWN_STATUS_0x{self.status:02X}")


def read_response(port: serial.Serial) -> Response:
    # 在噪声或上次残留字节中重新寻找应答帧头。
    previous = None
    while True:
        current = read_exact(port, 1)[0]
        if previous == 0x55 and current == 0xAA:
            break
        previous = current

    command, status, length = read_exact(port, 3)
    payload = read_exact(port, length)
    received_crc = read_exact(port, 1)[0]
    body = bytes((command, status, length)) + payload
    expected_crc = crc8_atm(body)
    if received_crc != expected_crc:
        raise ValueError(
            f"应答 CRC 错误：期望 0x{expected_crc:02X}，收到 0x{received_crc:02X}"
        )
    return Response(command, status, payload)


def transact(port: serial.Serial, command: int, payload: bytes = b"") -> Response:
    port.reset_input_buffer()
    port.write(encode_request(command, payload))
    port.flush()
    response = read_response(port)
    if response.command != command:
        raise ValueError(
            f"应答命令不匹配：发送 0x{command:02X}，收到 0x{response.command:02X}"
        )
    return response


def parse_int(value: str) -> int:
    return int(value, 0)


def commit_flag(stage_only: bool) -> int:
    return 0 if stage_only else 1


def build_generator_payload(args: argparse.Namespace) -> bytes:
    if args.ftw is not None:
        ftw = args.ftw
    else:
        if not 0.0 <= args.frequency <= 50_000.0:
            raise ValueError("frequency 必须在 0..50000Hz")
        ftw = round(args.frequency * (1 << 32) / args.update_rate)

    amplitude_q15 = round(args.amplitude_vpk / 5.0 * 0x8000)
    if not 0 <= amplitude_q15 <= 0x8000:
        raise ValueError("amplitude-vpk 必须在 0..5V")
    if not 0 <= ftw <= 0x09374BC7:
        raise ValueError("FTW 超出 M3 允许范围 0x00000000..0x09374BC7")

    return struct.pack(
        "<BBIHHB",
        args.channel - 1,
        WAVE_CODES[args.wave],
        ftw,
        amplitude_q15,
        args.dc_code,
        commit_flag(args.stage),
    )


def build_acquisition_payload(args: argparse.Namespace) -> bytes:
    pretrigger_permille = round(args.pretrigger_percent * 10.0)
    return struct.pack(
        "<BHHBIHBB",
        0 if args.source == "a" else 1,
        args.threshold,
        args.hysteresis,
        0 if args.edge == "rising" else 1,
        args.depth,
        pretrigger_permille,
        commit_flag(args.stage),
        args.channel_mask,
    )


def build_processing_payload(args: argparse.Namespace) -> bytes:
    refresh_millihz = round(args.refresh_hz * 1000.0)
    return struct.pack(
        "<BIIIB",
        MODE_CODES[args.mode],
        args.decimation,
        args.display_points,
        refresh_millihz,
        commit_flag(args.stage),
    )


def build_calibration_payload(args: argparse.Namespace) -> bytes:
    gain_q15 = round(args.gain * 0x8000)
    if not 0x4000 <= gain_q15 <= 0xC000:
        raise ValueError("gain 必须在 0.5..1.5")
    if not -32768 <= args.offset <= 32767:
        raise ValueError("offset 必须是 int16 DAC LSB")
    return struct.pack(
        "<BHhB",
        args.channel - 1,
        gain_q15,
        args.offset,
        commit_flag(args.stage),
    )


def build_raw_request_payload(args: argparse.Namespace) -> bytes:
    return struct.pack("<I", args.frame_id)


def build_retransmit_payload(args: argparse.Namespace) -> bytes:
    if not 0 <= args.offset <= 0xFFFFFFFF:
        raise ValueError("offset 必须是 uint32")
    if not 1 <= args.length <= 0xFFFF:
        raise ValueError("length 必须在 1..65535")
    return struct.pack("<IIH", args.frame_id, args.offset, args.length)


def parse_status(payload: bytes) -> dict[str, object]:
    if len(payload) != 32:
        raise ValueError(f"状态长度应为 32，实际为 {len(payload)}")

    flags = payload[5]
    return {
        "protocol_version": f"{payload[0]}.{payload[1]}",
        "firmware_version": f"{payload[2]}.{payload[3]}.{payload[4]}",
        "busy": bool(flags & 0x01),
        "armed": bool(flags & 0x02),
        "envelope_enabled": bool(flags & 0x04),
        "ddr_calibrated": bool(flags & 0x08),
        "network_link_up": bool(flags & 0x10),
        "adc_clock_alive": bool(flags & 0x20),
        "mmcm_locked": bool(flags & 0x40),
        "last_error": STATUS_NAMES.get(payload[6], f"0x{payload[6]:02X}"),
        "crc_error_count": struct.unpack_from("<I", payload, 8)[0],
        "uart_frame_error_count": struct.unpack_from("<I", payload, 12)[0],
        "command_error_count": struct.unpack_from("<I", payload, 16)[0],
        "dac_update_rate_ch1_hz": struct.unpack_from("<I", payload, 20)[0],
        "dac_update_rate_ch2_hz": struct.unpack_from("<I", payload, 24)[0],
        "config_sequence": struct.unpack_from("<H", payload, 28)[0],
        "adc_clear_count": struct.unpack_from("<H", payload, 30)[0],
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="FPGA 信号系统 M3 UART 调试工具")
    parser.add_argument("--port", required=True, help="例如 COM5")
    parser.add_argument("--baud", type=int, default=921_600)
    parser.add_argument("--timeout", type=float, default=1.0)
    subparsers = parser.add_subparsers(dest="action", required=True)

    subparsers.add_parser("status")
    subparsers.add_parser("arm")
    subparsers.add_parser("stop")
    subparsers.add_parser("clear")

    raw_request = subparsers.add_parser("request-raw")
    raw_request.add_argument("--frame-id", type=parse_int, required=True)

    retransmit = subparsers.add_parser("retransmit")
    retransmit.add_argument("--frame-id", type=parse_int, required=True)
    retransmit.add_argument("--offset", type=parse_int, required=True)
    retransmit.add_argument("--length", type=parse_int, required=True)

    envelope = subparsers.add_parser("envelope")
    envelope.add_argument("enabled", choices=("on", "off"))

    generator = subparsers.add_parser("set-gen")
    generator.add_argument("--channel", type=int, choices=(1, 2), required=True)
    generator.add_argument("--wave", choices=tuple(WAVE_CODES), required=True)
    frequency_group = generator.add_mutually_exclusive_group(required=True)
    frequency_group.add_argument("--frequency", type=float)
    frequency_group.add_argument("--ftw", type=parse_int)
    generator.add_argument("--update-rate", type=float, default=1_388_888.888888889)
    generator.add_argument("--amplitude-vpk", type=float, required=True)
    generator.add_argument("--dc-code", type=parse_int, default=0x8000)
    generator.add_argument("--stage", action="store_true", help="只写影子寄存器，不提交")

    acquisition = subparsers.add_parser("set-acq")
    acquisition.add_argument("--source", choices=("a", "b"), required=True)
    acquisition.add_argument("--threshold", type=parse_int, required=True)
    acquisition.add_argument("--hysteresis", type=parse_int, required=True)
    acquisition.add_argument("--edge", choices=("rising", "falling"), required=True)
    acquisition.add_argument("--depth", type=int, required=True)
    acquisition.add_argument("--pretrigger-percent", type=float, required=True)
    acquisition.add_argument(
        "--channel-mask", type=parse_int, choices=(1, 2, 3), default=3,
        help="1=CH1，2=CH2，3=双通道；单通道会让 FPGA 丢弃另一通道",
    )
    acquisition.add_argument("--stage", action="store_true")

    processing = subparsers.add_parser("set-processing")
    processing.add_argument("--mode", choices=tuple(MODE_CODES), required=True)
    processing.add_argument("--decimation", type=int, required=True)
    processing.add_argument("--display-points", type=int, required=True)
    processing.add_argument("--refresh-hz", type=float, required=True)
    processing.add_argument("--stage", action="store_true")

    calibration = subparsers.add_parser("calibrate")
    calibration.add_argument("--channel", type=int, choices=(1, 2), required=True)
    calibration.add_argument("--gain", type=float, required=True)
    calibration.add_argument("--offset", type=int, required=True)
    calibration.add_argument("--stage", action="store_true")

    return parser


def command_and_payload(args: argparse.Namespace) -> tuple[int, bytes]:
    if args.action == "status":
        return CMD_QUERY_STATUS, b""
    if args.action == "arm":
        return CMD_ARM, b""
    if args.action == "stop":
        return CMD_STOP, b""
    if args.action == "clear":
        return CMD_CLEAR_ERRORS, b""
    if args.action == "request-raw":
        return CMD_REQUEST_RAW, build_raw_request_payload(args)
    if args.action == "retransmit":
        return CMD_REQUEST_RETRANSMIT, build_retransmit_payload(args)
    if args.action == "envelope":
        return CMD_ENVELOPE_ENABLE, bytes((1 if args.enabled == "on" else 0,))
    if args.action == "set-gen":
        return CMD_SET_GENERATOR, build_generator_payload(args)
    if args.action == "set-acq":
        return CMD_SET_ACQUISITION, build_acquisition_payload(args)
    if args.action == "set-processing":
        return CMD_SET_PROCESSING, build_processing_payload(args)
    if args.action == "calibrate":
        return CMD_SET_CALIBRATION, build_calibration_payload(args)
    raise ValueError(f"未知操作 {args.action}")


def main() -> int:
    args = build_parser().parse_args()
    try:
        command, payload = command_and_payload(args)
        with serial.Serial(args.port, args.baud, timeout=args.timeout) as port:
            response = transact(port, command, payload)

        if response.status != 0:
            print(f"NACK: {response.status_name} (0x{response.status:02X})", file=sys.stderr)
            return 2

        if args.action == "status":
            print(json.dumps(parse_status(response.payload), ensure_ascii=False, indent=2))
        else:
            print(f"ACK: CMD=0x{response.command:02X}")
        return 0
    except (OSError, ValueError, TimeoutError, struct.error, serial.SerialException) as error:
        print(f"错误：{error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
