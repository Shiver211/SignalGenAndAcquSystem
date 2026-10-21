"""显示限帧、完整数据交付及同帧缓存失效回归。"""

import os
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from unittest import mock

import numpy as np

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtCore, QtTest, QtWidgets

from host.comm.data_protocol import (
    CompletedFrame, DataType, PacketHeader, SampleFormat, build_packet,
)
from host.comm.udp_receiver import UdpReceiver
from host.config import DISPLAY_MAX_FPS
from host.tests.window_helpers import create_window
from host.tests.test_square_measurement import hardware_frame
from host.ui.plot_widget import PlotWidget
from host.ui.theme import set_led


def waveform(*, envelope=True, frame_id=1):
    count = 650
    codes = np.rint(2048 + 600 * np.sin(2 * np.pi * np.arange(count) / 65)).astype("<u2")
    payload = (np.column_stack((codes, codes, codes, codes)).astype("<u2").tobytes()
               if envelope else (codes.astype("<u4") | (codes.astype("<u4") << 12)).tobytes())
    return CompletedFrame(
        PacketHeader(1, DataType.ENVELOPE_FRAME if envelope else DataType.RAW_FRAME,
                     frame_id, count, 65_000_000, 0, 3,
                     SampleFormat.ENVELOPE64 if envelope else SampleFormat.RAW32,
                     0, 0, len(payload), 0), payload,
    )


class RenderPerformanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_envelopes_coalesce_but_raw_and_measurements_are_complete(self):
        receiver = UdpReceiver()
        delivered = []
        receiver.frame_received.connect(delivered.append)
        first, latest = waveform(), waveform(frame_id=200)
        receiver._publish_frame(first)
        for frame_id in range(2, 200):
            receiver._publish_frame(replace(first, header=replace(first.header, frame_id=frame_id)))
        receiver._publish_frame(latest)
        raw = waveform(envelope=False)
        measurement = CompletedFrame(
            replace(raw.header, data_type=DataType.MEASUREMENT,
                    sample_format=SampleFormat.MEASUREMENT_V1), bytes(46),
        )
        receiver._publish_frame(raw)
        receiver._publish_frame(measurement)
        self.assertEqual(delivered, [raw, measurement])
        self.assertIs(receiver.take_display_frame(), latest)
        self.assertIsNone(receiver.take_display_frame())
        receiver._publish_frame(first)
        receiver.discard_pending()
        self.assertIsNone(receiver.take_display_frame())

    def test_timer_shows_latest_frame_once_and_stop_discards_pending(self):
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "display.db")
            try:
                self.assertFalse(window.display_timer.isActive())
                self.assertGreaterEqual(window.display_timer.interval(), 1000 / DISPLAY_MAX_FPS)
                window._continuous_running = True
                self.assertTrue(window.display_timer.isActive())
                first, latest = waveform(), waveform(frame_id=2)
                window.udp_receiver._publish_frame(first)
                window.udp_receiver._publish_frame(latest)
                with mock.patch.object(window.plot_widget, "display_frame") as display:
                    window._refresh_display()
                    window._refresh_display()
                    display.assert_called_once_with(latest)
                self.assertIs(window.current_frame, latest)
                window.udp_receiver._publish_frame(first)
                window._continuous_running = False
                self.assertFalse(window.display_timer.isActive())
                window._refresh_display()
                self.assertIs(window.current_frame, latest)
                window._continuous_running = True
                window.udp_receiver._publish_frame(first)
                window.timebase_combo.setCurrentText("2 µs/div")
                self.assertIsNone(window.udp_receiver.take_display_frame())
                window.udp_receiver._publish_frame(first)
                window.channel_mode_combo.setCurrentText("CH1")
                self.assertIsNone(window.udp_receiver.take_display_frame())
            finally:
                window.close()
                self.app.processEvents()

    def test_live_timer_limits_fast_producer(self):
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "live.db")
            producer = QtCore.QTimer()
            current = waveform()
            produced = []
            displayed = []

            def publish():
                frame = replace(current, header=replace(current.header, frame_id=len(produced) + 1))
                produced.append(frame)
                window.udp_receiver._publish_frame(frame)

            try:
                window._continuous_running = True
                producer.timeout.connect(publish)
                producer.start(1)
                with mock.patch.object(window.plot_widget, "display_frame", side_effect=displayed.append):
                    QtTest.QTest.qWait(220)
                self.assertGreater(len(produced), len(displayed))
                self.assertGreater(len(displayed), 1)
                self.assertLessEqual(len(displayed), 15)
                self.assertEqual(sorted(f.header.frame_id for f in displayed),
                                 [f.header.frame_id for f in displayed])
            finally:
                producer.stop()
                window.close()
                self.app.processEvents()

    def test_measurements_still_persist_while_envelopes_wait_for_display(self):
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "measurements.db")
            try:
                window._continuous_running = True
                wave = waveform()
                codes = np.full(650, 2048, dtype=np.uint16)
                hardware = hardware_frame(codes, codes)
                hardware = replace(hardware, header=replace(hardware.header, data_type=DataType.MEASUREMENT))
                with mock.patch.object(window.store, "save_measurement") as save:
                    for frame_id in range(20):
                        window.udp_receiver._publish_frame(
                            replace(wave, header=replace(wave.header, frame_id=frame_id)),
                        )
                        window.udp_receiver._publish_frame(
                            replace(hardware, header=replace(hardware.header, frame_id=100 + frame_id)),
                        )
                    self.assertEqual(save.call_count, 20)
                    window._refresh_display()
                    self.assertEqual(save.call_count, 20)
                self.assertEqual(window.current_frame.header.frame_id, 19)
                self.assertEqual(window._last_measurement.frequency_hz_a, 1_000_000)
            finally:
                window.close()
                self.app.processEvents()

    def test_cached_redraws_equal_fresh_computation_after_parameter_changes(self):
        widget = PlotWidget()
        reference = PlotWidget()
        try:
            for envelope in (False, True):
                frame = waveform(envelope=envelope)
                widget.set_timebase(1e-6)
                widget.display_frame(frame)
                for settings in ((1e-6, 0.5, 0.4, 1.02, -0.03, 300_000),
                                 (500e-9, 2.0, -0.2, 0.98, 0.02, 800_000),
                                 (1e-6, 0.5, 0.4, 1.02, -0.03, 300_000)):
                    reference.clear_frame()
                    for target in (widget, reference):
                        timebase, scale, position, gain, offset, smoothing = settings
                        target.set_timebase(timebase)
                        target.set_volts_per_div(1, scale)
                        target.set_vertical_position_div(1, position)
                        target.set_adc_calibration(1, gain, offset)
                        target.set_smoothing_start_frequency(1, smoothing)
                        target.display_frame(frame, max_points=100)
                    for name in ("curve_a", "curve_b", "min_a", "max_a", "min_b", "max_b"):
                        actual, expected = getattr(widget, name), getattr(reference, name)
                        self.assertEqual(actual.isVisible(), expected.isVisible())
                        for left, right in zip(actual.getData(), expected.getData()):
                            np.testing.assert_array_equal(left, right)
                    self.assertEqual(widget.fill_a.path(), reference.fill_a.path())
        finally:
            widget.close()
            reference.close()

    def test_cached_fft_keeps_full_spectrum_and_invalidates_calibration(self):
        widget = PlotWidget()
        reference = PlotWidget()
        try:
            raw = waveform(envelope=False)
            for target in (widget, reference):
                target.set_fft_enabled(True)
                target.display_frame(raw)
            self.assertEqual(len(widget.curve_a.getData()[0]), 326)
            with mock.patch("host.ui.plot_widget.fft_spectrum") as fft:
                widget.display_frame(raw)
                widget.set_vertical_position_div(1, 0.5)
                fft.assert_not_called()
            widget.set_adc_calibration(1, 1.03, 0.02)
            reference.clear_frame()
            reference.set_adc_calibration(1, 1.03, 0.02)
            reference.display_frame(raw)
            for actual, expected in zip(widget.curve_a.getData(), reference.curve_a.getData()):
                np.testing.assert_array_equal(actual, expected)
        finally:
            widget.close()
            reference.close()

    def test_fft_switch_and_calibration_redraw_only_once(self):
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "redraw.db")
            try:
                window._on_frame(waveform(envelope=False))
                with mock.patch.object(window.plot_widget, "display_frame") as display:
                    window.analysis_combo.setCurrentIndex(1)
                    display.assert_called_once()
                with mock.patch.object(window.plot_widget, "display_frame") as display:
                    window._reset_adc_calibration(1)
                    display.assert_called_once()
            finally:
                window.close()
                self.app.processEvents()

    def test_raw_progress_emits_only_changed_display_percent(self):
        receiver = UdpReceiver()
        progress = []
        receiver.raw_progress.connect(lambda received, total: progress.append((received, total)))
        raw = waveform(envelope=False)
        header = replace(raw.header, total_samples=10_000)
        for offset in (0, 100, 200, 400):
            payload = bytes(100)
            receiver.reassembler.ingest(build_packet(
                replace(header, chunk_offset=offset, payload_len=100), payload,
            ))
            receiver._emit_raw_progress()
        self.assertEqual(progress, [(100, 40_000), (400, 40_000)])

    def test_unchanged_led_skips_repolish(self):
        label = QtWidgets.QLabel()
        style = mock.Mock()
        with mock.patch.object(label, "style", return_value=style):
            set_led(label, "ok")
            set_led(label, "ok")
            self.assertEqual(style.polish.call_count, 1)
            set_led(label, "bad")
            self.assertEqual(style.polish.call_count, 2)
        self.assertEqual(label.property("state"), "bad")
