"""UDP 后台接收、乱序重组、缺块检测和 RAW 重传通知。"""

from __future__ import annotations

import socket
import threading
import time
from dataclasses import dataclass, field

from PyQt5 import QtCore

from host.config import UDP_PORT

from .data_protocol import (
    CompletedFrame, DataType, DatagramError, PacketHeader,
    expected_payload_bytes, parse_packet,
)


@dataclass
class _FrameState:
    header: PacketHeader
    total_bytes: int
    created: float
    updated: float
    segments: dict[int, bytes] = field(default_factory=dict)
    last_request: float = 0.0

    def add(self, offset: int, payload: bytes) -> bool:
        if offset < 0 or offset + len(payload) > self.total_bytes:
            raise DatagramError("分块范围超出完整帧")
        duplicate = self.segments.get(offset) == payload
        if not duplicate:
            self.segments[offset] = payload
        return duplicate

    def missing_ranges(self, maximum: int = 1400) -> list[tuple[int, int]]:
        intervals = sorted((start, start + len(data)) for start, data in self.segments.items())
        merged: list[tuple[int, int]] = []
        for start, end in intervals:
            if merged and start <= merged[-1][1]:
                merged[-1] = (merged[-1][0], max(merged[-1][1], end))
            else:
                merged.append((start, end))
        gaps: list[tuple[int, int]] = []
        cursor = 0
        for start, end in merged:
            if start > cursor:
                gaps.extend(_split_range(cursor, start - cursor, maximum))
            cursor = max(cursor, end)
        if cursor < self.total_bytes:
            gaps.extend(_split_range(cursor, self.total_bytes - cursor, maximum))
        return gaps

    def assemble(self) -> bytes:
        result = bytearray(self.total_bytes)
        for offset, payload in self.segments.items():
            result[offset : offset + len(payload)] = payload
        return bytes(result)


def _split_range(offset: int, length: int, maximum: int) -> list[tuple[int, int]]:
    result = []
    while length:
        size = min(length, maximum)
        result.append((offset, size))
        offset += size
        length -= size
    return result


class FrameReassembler:
    def __init__(self, timeout: float = 0.15) -> None:
        self.timeout = timeout
        self.frames: dict[tuple[int, int], _FrameState] = {}
        self.completed: set[tuple[int, int]] = set()
        self.latest_envelope_id: int | None = None
        self.packet_count = 0
        self.crc_error_count = 0
        self.duplicate_count = 0
        self.dropped_frame_count = 0

    def ingest(self, datagram: bytes, now: float | None = None) -> CompletedFrame | None:
        now = time.monotonic() if now is None else now
        try:
            header, payload = parse_packet(datagram)
        except DatagramError:
            self.crc_error_count += 1
            raise
        self.packet_count += 1
        key = (header.data_type, header.frame_id)
        if key in self.completed:
            self.duplicate_count += 1
            return None

        if header.data_type == DataType.ENVELOPE_FRAME:
            if self.latest_envelope_id is not None and header.frame_id < self.latest_envelope_id:
                self.dropped_frame_count += 1
                return None
            if self.latest_envelope_id is None or header.frame_id > self.latest_envelope_id:
                self._drop_old_envelopes(header.frame_id)
                self.latest_envelope_id = header.frame_id

        total = expected_payload_bytes(header)
        state = self.frames.get(key)
        if state is None:
            state = _FrameState(header, total, now, now)
            self.frames[key] = state
        elif (
            state.total_bytes != total
            or state.header.sample_format != header.sample_format
            or state.header.total_samples != header.total_samples
        ):
            raise DatagramError("同一帧的描述符不一致")
        state.updated = now
        if state.add(header.chunk_offset, payload):
            self.duplicate_count += 1
        if state.missing_ranges():
            return None
        del self.frames[key]
        self.completed.add(key)
        if len(self.completed) > 256:
            self.completed.clear()
            self.completed.add(key)
        return CompletedFrame(state.header, state.assemble())

    def expire(self, now: float | None = None) -> list[tuple[int, int, int]]:
        now = time.monotonic() if now is None else now
        retransmit: list[tuple[int, int, int]] = []
        for key, state in list(self.frames.items()):
            if now - state.updated < self.timeout:
                continue
            if state.header.data_type == DataType.RAW_FRAME:
                if now - state.last_request >= self.timeout:
                    retransmit.extend(
                        (state.header.frame_id, offset, length)
                        for offset, length in state.missing_ranges()
                    )
                    state.last_request = now
            else:
                del self.frames[key]
                self.dropped_frame_count += 1
        return retransmit

    def _drop_old_envelopes(self, new_frame_id: int) -> None:
        for key in list(self.frames):
            if key[0] == DataType.ENVELOPE_FRAME and key[1] < new_frame_id:
                del self.frames[key]
                self.dropped_frame_count += 1


class UdpReceiver(QtCore.QObject):
    frame_received = QtCore.pyqtSignal(object)
    packet_error = QtCore.pyqtSignal(str)
    retransmit_required = QtCore.pyqtSignal(int, int, int)
    stats_updated = QtCore.pyqtSignal(dict)
    running_changed = QtCore.pyqtSignal(bool, str)

    def __init__(self, parent: QtCore.QObject | None = None) -> None:
        super().__init__(parent)
        self._stop = threading.Event()
        self._flush = threading.Event()
        self._thread: threading.Thread | None = None
        self._bind = "0.0.0.0"
        self._port = UDP_PORT
        self.reassembler = FrameReassembler()

    @property
    def running(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    def start(self, bind: str = "0.0.0.0", port: int = UDP_PORT) -> None:
        self.stop()
        self._bind, self._port = bind, port
        self._stop.clear()
        self._flush.clear()
        self.reassembler = FrameReassembler()
        self._thread = threading.Thread(target=self._worker, name="udp-receiver", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.5)
        self._thread = None

    def discard_pending(self) -> None:
        """丢弃时基切换前已经排队的 UDP 数据。"""
        self._flush.set()
        if not self.running:
            self.reassembler = FrameReassembler()

    def _worker(self) -> None:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        # 实时示波器宁可丢弃过期帧，也不能缓存数秒的历史波形。
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 256 * 1024)
        sock.settimeout(0.05)
        try:
            sock.bind((self._bind, self._port))
        except OSError as exc:
            sock.close()
            self.running_changed.emit(False, str(exc))
            return
        self.running_changed.emit(True, f"{self._bind}:{self._port}")
        last_stats = time.monotonic()
        try:
            while not self._stop.is_set():
                if self._flush.is_set():
                    self._discard_socket_backlog(sock)
                    self.reassembler = FrameReassembler()
                    self._flush.clear()
                try:
                    datagram, _ = sock.recvfrom(2048)
                    frame = self.reassembler.ingest(datagram)
                    if frame is not None:
                        self.frame_received.emit(frame)
                except socket.timeout:
                    pass
                except (OSError, DatagramError) as exc:
                    if not self._stop.is_set():
                        self.packet_error.emit(str(exc))
                now = time.monotonic()
                for frame_id, offset, length in self.reassembler.expire(now):
                    self.retransmit_required.emit(frame_id, offset, length)
                if now - last_stats >= 0.5:
                    self.stats_updated.emit({
                        "packets": self.reassembler.packet_count,
                        "errors": self.reassembler.crc_error_count,
                        "duplicates": self.reassembler.duplicate_count,
                        "dropped_frames": self.reassembler.dropped_frame_count,
                    })
                    last_stats = now
        finally:
            sock.close()
            self.running_changed.emit(False, f"{self._bind}:{self._port}")

    @staticmethod
    def _discard_socket_backlog(sock: socket.socket) -> None:
        """在接收线程中非阻塞清空当前 socket 的待处理报文。"""
        previous_timeout = sock.gettimeout()
        sock.setblocking(False)
        try:
            for _ in range(16_384):
                try:
                    sock.recvfrom(2048)
                except BlockingIOError:
                    break
        finally:
            sock.settimeout(previous_timeout)
