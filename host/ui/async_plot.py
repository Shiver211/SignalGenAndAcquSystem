"""保留 pyqtgraph 原场景，界面只贴图，耗时的像素绘制在独立进程执行。"""

from __future__ import annotations

from math import ceil

from PyQt5 import QtCore, QtGui
import pyqtgraph as pg

from host.config import DISPLAY_MAX_FPS
from host.ui.plot_renderer import PlotRenderer


class AsyncPlotWidget(pg.PlotWidget):
    def __init__(self, *args, **kwargs) -> None:
        super().__init__(*args, **kwargs)
        self._image: QtGui.QImage | None = None
        self._geometry = None
        self._generation = 0
        self._dirty = True
        self._last_commands: bytes | None = None
        self._render_closed = False
        self._renderer = PlotRenderer(self)
        self._renderer.image_ready.connect(self._accept_image)
        self._renderer.failed.connect(self._render_failed)
        self._record_timer = QtCore.QTimer(self)
        self._record_timer.setSingleShot(True)
        self._record_timer.setInterval(ceil(1000 / DISPLAY_MAX_FPS))
        self._record_timer.timeout.connect(self._record_scene)
        self.scene().changed.connect(self._scene_changed)

    def _scene_changed(self, _regions=None) -> None:
        if self._render_closed:
            return
        self._dirty = True
        self._schedule_record()

    def _schedule_record(self) -> None:
        if (not self._render_closed and self._dirty and self.isVisible()
                and not self._renderer.busy and not self._record_timer.isActive()):
            self._record_timer.start()

    def invalidate_render(self, *, clear_image: bool = False) -> None:
        """只有显示配置切换才改变代次，连续帧不会饿死正在绘制的任务。"""
        self._generation += 1
        self._last_commands = None
        self._dirty = True
        if clear_image:
            self._image = None
            self.viewport().update()
        if self._renderer.busy:
            self._renderer.cancel()
        self._schedule_record()

    def _viewport_geometry(self):
        viewport = self.viewport()
        return (viewport.width(), viewport.height(), viewport.devicePixelRatioF(),
                viewport.logicalDpiX(), viewport.logicalDpiY())

    def _record_scene(self) -> None:
        if not self.isVisible() or self._render_closed or self._renderer.busy:
            return
        geometry = self._viewport_geometry()
        width, height, dpr, dpi_x, dpi_y = geometry
        if width <= 0 or height <= 0:
            return
        self._geometry = geometry
        self._dirty = False
        self.scene().prepareForPaint()
        picture = QtGui.QPicture()
        painter = QtGui.QPainter(picture)
        rect = self.viewport().rect()
        # 必须指定逻辑尺寸，避免高 DPI 图像的物理尺寸改变视图变换。
        self.render(painter, QtCore.QRectF(rect), rect)
        painter.end()
        buffer = QtCore.QBuffer()
        buffer.open(QtCore.QIODevice.WriteOnly)
        picture.save(buffer)
        commands = bytes(buffer.data())
        if commands == self._last_commands:
            return
        self._last_commands = commands
        self._renderer.submit(
            self._generation, commands,
            (int(width * dpr + 0.5), int(height * dpr + 0.5)), dpr, (dpi_x, dpi_y),
        )

    def _accept_image(self, generation: int, image: QtGui.QImage) -> None:
        if generation == self._generation and self._geometry == self._viewport_geometry():
            self._image = image
            self.viewport().update()
        self._schedule_record()

    def _render_failed(self, message: str) -> None:
        self._last_commands = None
        window = self.window()
        if hasattr(window, "statusBar"):
            window.statusBar().showMessage(message)

    def paintEvent(self, event) -> None:
        # 不调用 QGraphicsView.paintEvent；原场景的画笔、路径在后台回放。
        painter = QtGui.QPainter(self.viewport())
        painter.fillRect(event.rect(), self.backgroundBrush())
        if self._image is not None and self._geometry == self._viewport_geometry():
            painter.drawImage(0, 0, self._image)
        painter.end()
        if self._geometry != self._viewport_geometry():
            self.invalidate_render(clear_image=True)
        self._schedule_record()

    def resizeEvent(self, event) -> None:
        super().resizeEvent(event)
        if hasattr(self, "_renderer"):
            self.invalidate_render(clear_image=True)

    def showEvent(self, event) -> None:
        super().showEvent(event)
        self._schedule_record()

    def hideEvent(self, event) -> None:
        self._record_timer.stop()
        if self._renderer.busy:
            self._renderer.cancel()
            self._last_commands = None
            self._dirty = True
        super().hideEvent(event)

    def shutdown_renderer(self) -> None:
        self._render_closed = True
        self._record_timer.stop()
        self._renderer.close()

    def close(self) -> None:
        self.shutdown_renderer()
        super().close()
