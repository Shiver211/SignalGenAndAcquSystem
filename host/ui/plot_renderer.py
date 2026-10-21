"""独立进程回放 Qt 绘图指令；共享内存只交付完整的一帧像素。"""

from __future__ import annotations

import multiprocessing as mp
from multiprocessing.shared_memory import SharedMemory
from queue import Empty

from PyQt5 import QtCore, QtGui


def _render_loop(requests, results) -> None:
    # 不创建 QWidget，也不接触主进程的 QGraphicsScene。
    app = QtGui.QGuiApplication([])
    while True:
        task = requests.get()
        if task is None:
            return
        token, commands, size, dpr, dpi, memory_name = task
        buffer = QtCore.QBuffer()
        buffer.setData(QtCore.QByteArray(commands))
        buffer.open(QtCore.QIODevice.ReadOnly)
        picture = QtGui.QPicture()
        if not picture.load(buffer):
            results.put((token, "无法读取波形绘图指令"))
            continue
        image = QtGui.QImage(*size, QtGui.QImage.Format_ARGB32_Premultiplied)
        image.setDevicePixelRatio(dpr)
        image.setDotsPerMeterX(round(dpi[0] / 0.0254))
        image.setDotsPerMeterY(round(dpi[1] / 0.0254))
        image.fill(0)
        painter = QtGui.QPainter(image)
        # QPicture 回放会按逻辑 DPI 自动缩放；这里保持原视口的坐标。
        painter.scale(picture.logicalDpiX() / dpi[0], picture.logicalDpiY() / dpi[1])
        painter.drawPicture(0, 0, picture)
        painter.end()
        pointer = image.constBits()
        pointer.setsize(image.byteCount())
        memory = SharedMemory(name=memory_name)
        memory.buf[:image.byteCount()] = pointer.asstring(image.byteCount())
        memory.close()
        results.put((token, None))


class PlotRenderer(QtCore.QObject):
    """只允许一个在绘任务；下一帧由界面在完成后读取最新场景。"""

    image_ready = QtCore.pyqtSignal(int, QtGui.QImage)
    failed = QtCore.pyqtSignal(str)

    def __init__(self, parent: QtCore.QObject | None = None) -> None:
        super().__init__(parent)
        self._process = None
        self._requests = None
        self._results = None
        self._memory: SharedMemory | None = None
        self._task = None
        self._closed = False
        self._poll_timer = QtCore.QTimer(self)
        self._poll_timer.setTimerType(QtCore.Qt.PreciseTimer)
        self._poll_timer.setInterval(10)
        self._poll_timer.timeout.connect(self._poll)
        QtCore.QCoreApplication.instance().aboutToQuit.connect(self.close)

    @property
    def busy(self) -> bool:
        return self._task is not None

    def submit(
        self, token: int, commands: bytes, size: tuple[int, int],
        dpr: float, dpi: tuple[int, int],
    ) -> None:
        if self._closed:
            return
        if self.busy:
            raise RuntimeError("上一帧尚未完成")
        byte_count = size[0] * size[1] * 4
        if self._memory is None or self._memory.size != byte_count:
            self._release_memory()
            self._memory = SharedMemory(create=True, size=byte_count)
        if self._process is None:
            context = mp.get_context("spawn")
            self._requests = context.Queue(1)
            self._results = context.Queue(1)
            self._process = context.Process(
                target=_render_loop, args=(self._requests, self._results),
                name="WaveformRenderer", daemon=True,
            )
            self._process.start()
        self._task = (token, size, dpr, dpi)
        self._requests.put((token, commands, size, dpr, dpi, self._memory.name))
        self._poll_timer.start()

    def _poll(self) -> None:
        try:
            token, error = self._results.get_nowait()
        except Empty:
            if self._process.exitcode is not None:
                self.cancel()
                self.failed.emit("波形绘制进程意外退出")
            return
        self._poll_timer.stop()
        _, size, dpr, dpi = self._task
        self._task = None
        if error is not None:
            self.failed.emit(error)
            return
        # 在提交下一帧之前复制；后台随后可安全复用同一块共享内存。
        image = QtGui.QImage(
            self._memory.buf, *size, size[0] * 4,
            QtGui.QImage.Format_ARGB32_Premultiplied,
        ).copy()
        image.setDevicePixelRatio(dpr)
        image.setDotsPerMeterX(round(dpi[0] / 0.0254))
        image.setDotsPerMeterY(round(dpi[1] / 0.0254))
        self.image_ready.emit(token, image)

    def cancel(self) -> None:
        """配置切换立即终止旧回放，避免新时基等候一张耗时的旧图。"""
        self._poll_timer.stop()
        if self._process is not None:
            if self._process.is_alive():
                self._process.terminate()
            self._process.join()
            self._process.close()
            self._process = None
            for channel in (self._requests, self._results):
                channel.cancel_join_thread()
                channel.close()
            self._requests = self._results = None
        self._task = None
        self._release_memory()

    def _release_memory(self) -> None:
        if self._memory is not None:
            self._memory.close()
            self._memory.unlink()
            self._memory = None

    def close(self) -> None:
        self._closed = True
        self.cancel()
