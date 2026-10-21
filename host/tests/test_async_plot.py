"""异步像素等价、长时基响应、最新帧合并及绘制进程生命周期回归。"""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from dataclasses import replace
from multiprocessing.shared_memory import SharedMemory
from pathlib import Path
import tempfile
from time import monotonic
import unittest
from unittest import mock

import numpy as np
from PyQt5 import QtCore, QtGui, QtTest, QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.tests.test_render_performance import waveform
from host.tests.window_helpers import create_window
from host.ui.plot_widget import PlotWidget


def dense_envelope():
    count, rate = 1024, 10240
    centers = np.rint(2048 + 650*np.sin(2*np.pi*5000*np.arange(count)/rate)).astype("<u2")
    payload = np.column_stack((centers-200, centers+200, centers-200, centers+200)).astype("<u2").tobytes()
    return CompletedFrame(PacketHeader(1, 2, 1, count, rate, 0, 3,
                                       SampleFormat.ENVELOPE64, 0, 0, len(payload), 0), payload)


def pixels(image):
    pointer = image.constBits()
    pointer.setsize(image.byteCount())
    return np.frombuffer(pointer, np.uint8).copy()


class AsyncPlotTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
        # offscreen 不自动枚举 Windows 字体，加载原应用使用的字体。
        for name in ("segoeui.ttf", "msyh.ttc", "msyhbd.ttc", "consola.ttf"):
            path = Path("C:/Windows/Fonts") / name
            if path.exists():
                QtGui.QFontDatabase.addApplicationFont(str(path))

    def wait_until(self, predicate, timeout=15):
        deadline = monotonic() + timeout
        while not predicate():
            if monotonic() > deadline:
                self.fail("后台绘制未在时限内完成")
            QtTest.QTest.qWait(10)

    def settle(self, view):
        self.app.processEvents()
        self.wait_until(lambda: view._image is not None and not view._renderer.busy
                        and not view._record_timer.isActive() and not view._dirty)

    def direct_image(self, view, dpr):
        image = QtGui.QImage(int(view.viewport().width()*dpr+.5),
                             int(view.viewport().height()*dpr+.5),
                             QtGui.QImage.Format_ARGB32_Premultiplied)
        image.setDevicePixelRatio(dpr)
        image.setDotsPerMeterX(round(view.logicalDpiX()/.0254))
        image.setDotsPerMeterY(round(view.logicalDpiY()/.0254))
        image.fill(0)
        painter = QtGui.QPainter(image)
        rect = view.viewport().rect()
        view.render(painter, QtCore.QRectF(rect), rect)
        painter.end()
        return image

    def test_pixels_match_original_scene_at_two_dpi_scales(self):
        widget = PlotWidget()
        widget.resize(800, 420)
        try:
            widget.show()
            for fft, envelope in ((False, False), (False, True), (True, False), (True, True)):
                widget.set_fft_enabled(fft)
                widget.set_timebase(1e-6)
                widget.display_frame(waveform(envelope=envelope))
                self.settle(widget.plot)
                view = widget.plot
                expected = self.direct_image(view, view.devicePixelRatioF())
                np.testing.assert_array_equal(pixels(expected), pixels(view._image))
                # 同一批原绘图指令，在高 DPI 图像中回放。
                images = []
                renderer = view._renderer
                renderer.image_ready.connect(lambda _, image: images.append(image))
                for dpr in (1.0, 1.5):
                    geometry = view._viewport_geometry()
                    width, height, _, dpi_x, dpi_y = geometry
                    renderer.submit(-1, view._last_commands,
                                    (int(width*dpr+.5), int(height*dpr+.5)), dpr, (dpi_x, dpi_y))
                    self.wait_until(lambda: not renderer.busy)
                    np.testing.assert_array_equal(pixels(self.direct_image(view, dpr)), pixels(images[-1]))
        finally:
            widget.close()
            self.app.processEvents()

    def test_slow_waveform_keeps_interface_events_responsive_and_stops_cleanly(self):
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory)/"responsive.db")
            timer = QtCore.QTimer()
            timer.setTimerType(QtCore.Qt.PreciseTimer)
            beats, clicks, completed = [], [], []
            try:
                window.status_timer.stop()
                window.show()
                view = window.plot_widget.plot
                self.settle(view)  # 先启动常驻绘制进程。
                window.timebase_combo.setCurrentText("10 ms/div")
                self.settle(view)
                window._continuous_running = True
                window.udp_receiver._publish_frame(dense_envelope())
                window._refresh_display()
                self.wait_until(lambda: view._renderer.busy)
                process = view._renderer._process
                memory_name = view._renderer._memory.name
                view._renderer.image_ready.connect(lambda *_: completed.append(monotonic()))
                timer.timeout.connect(lambda: beats.append(monotonic()))
                window.refresh_records_button.clicked.connect(lambda: clicks.append(monotonic()))
                timer.start(10)
                start = monotonic()
                QtCore.QTimer.singleShot(50, window.refresh_records_button.click)
                self.wait_until(lambda: bool(clicks))
                self.assertTrue(view._renderer.busy, "控件应在波形仍在绘制时响应")
                self.assertLess(clicks[0]-start, .3)
                self.wait_until(lambda: bool(completed))
                self.assertGreater(completed[0]-start, .4, "回归样例必须覆盖耗时像素绘制")
                self.assertGreater(len(beats), 20)
                self.assertLess(max(np.diff([start]+beats+[monotonic()])), .3)
                window._continuous_running = False
                window.udp_receiver._publish_frame(waveform(frame_id=99))
                window._refresh_display()
                self.assertEqual(window.current_frame.header.frame_id, 1)
                window.close()
                # Process.close 仅在进程已经终止后才能成功。
                self.assertTrue(process._closed)
                with self.assertRaises(FileNotFoundError):
                    SharedMemory(name=memory_name)
            finally:
                timer.stop()
                window.close()
                self.app.processEvents()

    def test_busy_renderer_records_only_latest_scene_then_reuses_process(self):
        widget = PlotWidget()
        widget.resize(800, 420)
        try:
            widget.show()
            self.settle(widget.plot)
            widget.set_timebase(.01)
            self.settle(widget.plot)
            view = widget.plot
            source = dense_envelope()
            widget.display_frame(source)
            self.wait_until(lambda: view._renderer.busy)
            process = view._renderer._process
            latest = waveform(frame_id=101)
            with mock.patch.object(view, "render", wraps=view.render) as record:
                for frame_id in range(2, 102):
                    widget.display_frame(replace(latest, header=replace(latest.header, frame_id=frame_id)))
                QtTest.QTest.qWait(100)
                self.assertTrue(view._renderer.busy)
                record.assert_not_called()
                self.settle(view)
                self.assertLessEqual(record.call_count, 2)
            self.assertIs(view._renderer._process, process)
            self.assertEqual(widget._last_frame.header.frame_id, 101)
            np.testing.assert_array_equal(pixels(self.direct_image(view, view.devicePixelRatioF())),
                                          pixels(view._image))
        finally:
            widget.close()
            self.app.processEvents()

    def test_configuration_change_cancels_old_pixels_resize_and_close_release_worker(self):
        widget = PlotWidget()
        widget.resize(800, 420)
        try:
            widget.show()
            self.settle(widget.plot)
            widget.set_timebase(.01)
            self.settle(widget.plot)
            view = widget.plot
            widget.display_frame(dense_envelope())
            self.wait_until(lambda: view._renderer.busy)
            old_process = view._renderer._process
            generation = view._generation
            stale = view._image.copy()
            start = monotonic()
            widget.set_timebase(1e-6)
            widget.display_frame(waveform())
            self.assertLess(monotonic()-start, .3)
            self.assertTrue(old_process._closed)
            self.settle(view)
            current = view._image
            view._accept_image(generation, stale)
            self.assertIs(view._image, current)
            widget.resize(930, 480)
            self.settle(view)
            self.assertEqual(view._image.width(), round(930*view.devicePixelRatioF()))
            np.testing.assert_array_equal(pixels(self.direct_image(view, view.devicePixelRatioF())),
                                          pixels(view._image))
            widget.clear_frame()
            self.settle(view)
            np.testing.assert_array_equal(pixels(self.direct_image(view, view.devicePixelRatioF())),
                                          pixels(view._image))
            widget.set_timebase(.01)
            widget.display_frame(dense_envelope())
            self.wait_until(lambda: view._renderer.busy)
            process = view._renderer._process
            memory_name = view._renderer._memory.name
            start = monotonic()
            widget.close()
            self.assertLess(monotonic()-start, .3)
            self.assertTrue(process._closed)
            with self.assertRaises(FileNotFoundError):
                SharedMemory(name=memory_name)
        finally:
            widget.close()
            self.app.processEvents()
