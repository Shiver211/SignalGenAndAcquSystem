"""M8 实机闭环测试；默认执行 UART + UDP + SQLite，--uart-only 仅测控制面。"""

from __future__ import annotations

import argparse
import json
import socket
import time
from pathlib import Path

import serial

from host.comm.control_protocol import (
    Command, DataMode, Response, ResponseParser, Waveform,
    acquisition_payload, encode_request, generator_payload,
    parse_device_status, processing_payload, raw_request_payload,
    retransmit_payload,
)
from host.comm.data_protocol import (
    CompletedFrame, DataType, SampleFormat, decode_envelope64,
    decode_measurement_v1,
)
from host.comm.udp_receiver import FrameReassembler
from host.config import PC_IP, UDP_PORT
from host.db.sqlite_store import SqliteStore


class ControlClient:
    def __init__(self, port: str, baud: int = 921_600) -> None:
        self.serial = serial.Serial(port, baud, timeout=0.05, write_timeout=0.5)

    def transact(self, command: int, payload: bytes = b"", timeout: float = 1.0) -> Response:
        parser = ResponseParser()
        self.serial.reset_input_buffer()
        self.serial.write(encode_request(command, payload))
        self.serial.flush()
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            data = self.serial.read(max(self.serial.in_waiting, 1))
            for response in parser.feed(data):
                if response.command == command:
                    return response
        raise TimeoutError(f"UART 命令 0x{command:02X} 应答超时")

    def ok(self, command: int, payload: bytes = b"") -> Response:
        response = self.transact(command, payload)
        if not response.ok:
            raise RuntimeError(f"命令 0x{command:02X} 返回 {response.status_name}")
        return response

    def status(self) -> dict[str, object]:
        return parse_device_status(self.ok(Command.QUERY_STATUS).payload)

    def close(self) -> None:
        self.serial.close()


def receive_frames(
    sock: socket.socket,
    control: ControlClient,
    required_formats: set[int],
    timeout: float,
) -> dict[int, CompletedFrame]:
    reassembler = FrameReassembler(timeout=0.15)
    completed: dict[int, CompletedFrame] = {}
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline and not required_formats.issubset(completed):
        try:
            datagram, _ = sock.recvfrom(2048)
            frame = reassembler.ingest(datagram)
            if frame is not None:
                completed[frame.header.sample_format] = frame
        except socket.timeout:
            pass
        for frame_id, offset, length in reassembler.expire():
            control.ok(Command.REQUEST_RETRANSMIT, retransmit_payload(frame_id, offset, length))
    missing = required_formats - set(completed)
    if missing:
        raise TimeoutError(f"UDP 等待格式 {sorted(missing)} 超时")
    return completed


def restore_device(control: ControlClient) -> dict[str, object]:
    control.ok(Command.ENVELOPE_ENABLE, b"\x00")
    control.ok(Command.STOP)
    control.ok(Command.SET_GENERATOR, generator_payload(
        1, Waveform.SINE, 0, 5.0, dc_code=0x8000, commit=False,
    ))
    control.ok(Command.SET_GENERATOR, generator_payload(
        2, Waveform.SINE, 0, 5.0, dc_code=0x8000, commit=True,
    ))
    control.ok(Command.SET_ACQUISITION, acquisition_payload(
        0, 2048, 16, 0, 20_000, 50, commit=False,
    ))
    control.ok(Command.SET_PROCESSING, processing_payload(
        DataMode.RAW, 1, 256, 10, commit=True,
    ))
    control.ok(Command.CLEAR_ERRORS)
    return control.status()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default="COM14")
    parser.add_argument("--bind", default=PC_IP)
    parser.add_argument("--udp-port", type=int, default=UDP_PORT)
    parser.add_argument("--database", type=Path, default=Path("host/data/m8_live_test.db"))
    parser.add_argument("--uart-only", action="store_true")
    args = parser.parse_args()

    control = ControlClient(args.port)
    sock: socket.socket | None = None
    result: dict[str, object] = {}
    try:
        baseline = control.status()
        control.ok(Command.SET_GENERATOR, generator_payload(
            1, Waveform.SINE, 2_000, 1.0, commit=False,
        ))
        control.ok(Command.SET_GENERATOR, generator_payload(
            2, Waveform.TRIANGLE, 1_000, 0.5, commit=True,
        ))
        control.ok(Command.SET_ACQUISITION, acquisition_payload(
            0, 2048, 16, 0, 20_000, 50, commit=False,
        ))
        control.ok(Command.SET_PROCESSING, processing_payload(
            DataMode.ENVELOPE, 1, 256, 10, commit=True,
        ))
        configured = control.status()
        if configured["config_sequence"] == baseline["config_sequence"]:
            raise RuntimeError("ADC 配置序号未更新")
        result["uart"] = {
            "baseline_sequence": baseline["config_sequence"],
            "configured_sequence": configured["config_sequence"],
            "link": configured["network_link_up"],
            "mig": configured["ddr_calibrated"],
        }

        if not args.uart_only:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 16 * 1024 * 1024)
            sock.settimeout(0.05)
            sock.bind((args.bind, args.udp_port))

            control.ok(Command.ENVELOPE_ENABLE, b"\x01")
            live = receive_frames(
                sock, control,
                {SampleFormat.ENVELOPE64, SampleFormat.MEASUREMENT_V1},
                timeout=5.0,
            )
            control.ok(Command.ENVELOPE_ENABLE, b"\x00")

            envelope = decode_envelope64(live[SampleFormat.ENVELOPE64].payload)
            min_a, max_a = int(envelope["min_a"].min()), int(envelope["max_a"].max())
            min_b, max_b = int(envelope["min_b"].min()), int(envelope["max_b"].max())
            span_a, span_b = max_a - min_a, max_b - min_b
            trigger_source = 0 if span_a >= span_b else 1
            trigger_min, trigger_max = (min_a, max_a) if trigger_source == 0 else (min_b, max_b)
            trigger_threshold = (trigger_min + trigger_max) // 2
            trigger_hysteresis = 0 if trigger_max - trigger_min < 32 else 8
            result["analog"] = {
                "a_min": min_a, "a_max": max_a,
                "b_min": min_b, "b_max": max_b,
                "trigger_source": "A" if trigger_source == 0 else "B",
                "trigger_threshold": trigger_threshold,
                "trigger_hysteresis": trigger_hysteresis,
                "loopback_present": max(span_a, span_b) >= 32,
            }

            control.ok(Command.SET_ACQUISITION, acquisition_payload(
                trigger_source, trigger_threshold, trigger_hysteresis,
                0, 20_000, 50, commit=False,
            ))
            control.ok(Command.SET_PROCESSING, processing_payload(
                DataMode.RAW, 1, 256, 10, commit=True,
            ))
            control.ok(Command.ARM)
            time.sleep(0.5)
            control.ok(Command.REQUEST_RAW, raw_request_payload(1))
            raw = receive_frames(sock, control, {SampleFormat.RAW32}, timeout=5.0)[SampleFormat.RAW32]

            measurement_frame = live[SampleFormat.MEASUREMENT_V1]
            measurement = decode_measurement_v1(measurement_frame.payload)
            with SqliteStore(args.database) as store:
                env_id = store.save_frame(live[SampleFormat.ENVELOPE64], note="M8实机包络")
                raw_id = store.save_frame(raw, note="M8实机RAW")
                store.save_measurement(measurement_frame.header.frame_id, measurement, capture_id=env_id)
                replay = store.load_frame(raw_id)
                if replay.payload != raw.payload:
                    raise RuntimeError("SQLite RAW BLOB 回放不一致")
                result["sqlite"] = {
                    "envelope_record_id": env_id,
                    "raw_record_id": raw_id,
                    "record_count": len(store.list_captures()),
                }
            result["udp"] = {
                "envelope_frame_id": live[SampleFormat.ENVELOPE64].header.frame_id,
                "envelope_bytes": len(live[SampleFormat.ENVELOPE64].payload),
                "measurement_frame_id": measurement_frame.header.frame_id,
                "raw_frame_id": raw.header.frame_id,
                "raw_bytes": len(raw.payload),
                "otr_a": measurement.otr_count_a,
                "otr_b": measurement.otr_count_b,
            }
    finally:
        if sock is not None:
            sock.close()
        try:
            result["restored"] = restore_device(control)
        finally:
            control.close()

    print(json.dumps(result, ensure_ascii=False, indent=2))
    print("M8_LIVE_INTEGRATION_PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
