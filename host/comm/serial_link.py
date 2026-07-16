"""使用后台线程执行 UART 请求/应答，避免阻塞 Qt 事件循环。"""

from __future__ import annotations

import queue
import threading
import time
from dataclasses import dataclass

import serial
from PyQt5 import QtCore

from .control_protocol import ProtocolError, Response, ResponseParser, encode_request


@dataclass(frozen=True)
class _Request:
    token: int
    command: int
    payload: bytes


class SerialLink(QtCore.QObject):
    connection_changed = QtCore.pyqtSignal(bool, str)
    response_received = QtCore.pyqtSignal(int, object)
    request_failed = QtCore.pyqtSignal(int, str)

    def __init__(self, parent: QtCore.QObject | None = None) -> None:
        super().__init__(parent)
        self._requests: queue.Queue[_Request] = queue.Queue()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._port_name = ""
        self._baud = 921_600
        self._timeout = 0.5
        self._retries = 2
        self._next_token = 1

    @property
    def running(self) -> bool:
        return bool(self._thread and self._thread.is_alive())

    def connect_port(
        self, port_name: str, baud: int = 921_600,
        timeout: float = 0.5, retries: int = 2,
    ) -> None:
        self.disconnect_port()
        self._port_name = port_name
        self._baud = baud
        self._timeout = timeout
        self._retries = retries
        self._stop.clear()
        self._thread = threading.Thread(target=self._worker, name="uart-link", daemon=True)
        self._thread.start()

    def disconnect_port(self) -> None:
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=1.5)
        self._thread = None

    def send_command(self, command: int, payload: bytes = b"") -> int:
        token = self._next_token
        self._next_token += 1
        self._requests.put(_Request(token, int(command), payload))
        return token

    def _worker(self) -> None:
        try:
            port = serial.serial_for_url(
                self._port_name, self._baud, timeout=0.05, write_timeout=self._timeout,
            )
        except (serial.SerialException, ValueError) as exc:
            self.connection_changed.emit(False, str(exc))
            return

        self.connection_changed.emit(True, self._port_name)
        try:
            while not self._stop.is_set():
                try:
                    request = self._requests.get(timeout=0.05)
                except queue.Empty:
                    continue
                self._transact(port, request)
        finally:
            port.close()
            self.connection_changed.emit(False, self._port_name)

    def _transact(self, port: serial.SerialBase, request: _Request) -> None:
        last_error = "UART 请求失败"
        for _ in range(self._retries + 1):
            if self._stop.is_set():
                return
            parser = ResponseParser()
            try:
                port.reset_input_buffer()
                port.write(encode_request(request.command, request.payload))
                port.flush()
                deadline = time.monotonic() + self._timeout
                while time.monotonic() < deadline and not self._stop.is_set():
                    data = port.read(max(port.in_waiting, 1))
                    if not data:
                        continue
                    for response in parser.feed(data):
                        if response.command != request.command:
                            continue
                        self.response_received.emit(request.token, response)
                        return
                last_error = "UART 应答超时"
            except (serial.SerialException, ProtocolError, OSError) as exc:
                last_error = str(exc)
        self.request_failed.emit(request.token, last_error)
