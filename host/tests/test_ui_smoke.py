from __future__ import annotations

import os
import tempfile
import unittest
import struct
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import numpy as np

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from math import ceil

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.comm.control_protocol import Command, DataMode
from host.config import ADC_SAMPLE_RATE_HZ, PC_IP, UART_BAUD, UDP_PORT
from host.core.waveform import fixed_dc_offset_v
from host.tests.window_helpers import create_window
from host.tests.waveform_helpers import square_with_overshoot
from host.ui.main_window import RAW_MAX_SAMPLES, TIME_PER_DIV


class UiSmokeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_window_constructs_and_closes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "ui.db")
            self.assertIn("FPGA", window.windowTitle())
            self.assertEqual(window.udp_bind_edit.text(), PC_IP)
            self.assertEqual(window.udp_port_spin.value(), UDP_PORT)
            self.assertIn("DAC 波形控制", [group.title() for group in window.findChildren(QtWidgets.QGroupBox)])
            self.assertFalse(window.analysis_combo.isHidden())
            self.assertFalse(window.note_edit.isHidden())
            self.assertFalse(window.save_button.isHidden())
            self.assertEqual(
                [window.control_tabs.tabText(i) for i in range(window.control_tabs.count())],
                ["示波器", "信号源", "连接", "记录"],
            )
            records = next(
                group for group in window.findChildren(QtWidgets.QGroupBox)
                if group.title() == "SQLite 记录与回放"
            )
            self.assertFalse(records.isHidden())
            self.assertFalse(window.records_table.isHidden())
            window.close()
            self.app.processEvents()

    def test_ideal_display_cleans_measurement_and_preserves_saved_frame(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "edge.db")
            try:
                codes = np.rint((square_with_overshoot() + 5) / 10 * 4095).astype('<u4')
                payload = (codes | (2048 << 12)).tobytes()
                frame = CompletedFrame(
                    PacketHeader(1, 1, 10, len(codes), ADC_SAMPLE_RATE_HZ, 0, 3,
                                 SampleFormat.RAW32, 0, 0, len(payload), 0), payload,
                )
                window._on_frame(frame)
                window._measure_raw_frame(frame)
                measured = [label.text() for label in window.measurement_labels]
                self.assertLess(window._last_measurement.max_a, int(codes.max()))
                self.assertGreater(window._last_measurement.min_a, int(codes.min()))
                self.assertAlmostEqual(window._last_measurement.vpp_a / 4095 * 10, 2.0, delta=0.02)
                corrected = window.plot_widget.curve_a.getData()[1].copy()
                # CH1 的固定直流补偿也会体现在绘制的纵向格数里。
                self.assertLess(float(corrected.max()), 2.05 + fixed_dc_offset_v(1) / 0.5)
                self.assertFalse(hasattr(window, "edge_overshoot_checkbox"))
                self.assertFalse(hasattr(window, "waveform_display_combo"))
                self.assertEqual([label.text() for label in window.measurement_labels], measured)
                window._save_current()
                record = window.store.list_captures()[0]
                self.assertEqual(window.store.load_frame(record.id).payload, payload)
            finally:
                window.close()
                self.app.processEvents()

    def test_dac_controls_submit_two_channels_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "dac.db")
            window.wave_boxes[0].setCurrentText("三角")
            window.frequency_spins[0].setValue(1250)
            window.amplitude_spins[0].setValue(0.8)
            window._dac_full_scale_vpp[(1, 0)] = 2.0
            window._dac_full_scale_vpp[(2, 0)] = 2.0
            with mock.patch.object(window.serial_link, "send_command") as send:
                window._apply_generator()
            self.assertEqual(len(send.call_args_list), 2)
            self.assertTrue(all(call.args[0] == Command.SET_GENERATOR for call in send.call_args_list))
            self.assertEqual(send.call_args_list[0].args[1][-1], 0)
            self.assertEqual(send.call_args_list[1].args[1][-1], 1)
            window.close()
            self.app.processEvents()

    def test_dac_modes_calibrate_independently_and_persist(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "dac_modes.db"
            window = create_window(database)
            window.dac_mode_boxes[1].setCurrentIndex(1)
            with mock.patch.object(window.serial_link, "send_command") as send:
                window._apply_generator()
                send.assert_not_called()
                window._send_dac_calibration_test()
            self.assertEqual(len(send.call_args_list), 2)
            for call in send.call_args_list:
                self.assertEqual(struct.unpack_from("<H", call.args[1], 6)[0], 0x2000)
            window.dac_measured_spins[0].setValue(0.125)
            window.dac_measured_spins[1].setValue(1.5)
            window._calibrate_dac_amplitude(1)
            window._calibrate_dac_amplitude(2)
            self.assertAlmostEqual(window._dac_full_scale_vpp[(1, 0)], 0.5)
            self.assertAlmostEqual(window._dac_full_scale_vpp[(2, 1)], 6.0)
            window.dac_mode_boxes[0].setCurrentIndex(1)
            with mock.patch.object(window.serial_link, "send_command"):
                window._send_dac_calibration_test()
            window.dac_measured_spins[0].setValue(1.25)
            window._calibrate_dac_amplitude(1)
            window.dac_mode_boxes[0].setCurrentIndex(0)
            self.assertAlmostEqual(window._dac_full_scale_vpp[(1, 1)], 5.0)
            self.assertIn("0.500 Vpp", window.dac_calibration_labels[0].text())
            window.amplitude_spins[0].setValue(0.1)
            window.amplitude_spins[1].setValue(5.0)
            with mock.patch.object(window.serial_link, "send_command") as send:
                window._apply_generator()
            self.assertEqual(len(send.call_args_list), 2)
            self.assertEqual(
                [struct.unpack_from("<H", call.args[1], 6)[0] for call in send.call_args_list],
                [round(0.1 / 0.5 * 0x8000), round(5.0 / 6.0 * 0x8000)],
            )
            window.settings.sync()
            window.close()
            self.app.processEvents()
            reopened = create_window(database)
            self.assertAlmostEqual(reopened._dac_full_scale_vpp[(1, 0)], 0.5)
            self.assertAlmostEqual(reopened._dac_full_scale_vpp[(1, 1)], 5.0)
            self.assertAlmostEqual(reopened._dac_full_scale_vpp[(2, 1)], 6.0)
            reopened.close()
            self.app.processEvents()

    def test_dac_mode_change_invalidates_test_and_low_range_rejects_overflow(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "dac_range.db")
            with mock.patch.object(window.serial_link, "send_command"):
                window._send_dac_calibration_test()
            window.dac_mode_boxes[0].setCurrentIndex(1)
            window.dac_measured_spins[0].setValue(1.0)
            window._calibrate_dac_amplitude(1)
            self.assertNotIn((1, 1), window._dac_full_scale_vpp)
            window.dac_mode_boxes[0].setCurrentIndex(0)
            window._dac_full_scale_vpp[(1, 0)] = 0.5
            window._dac_full_scale_vpp[(2, 0)] = 0.5
            window.amplitude_spins[0].setValue(1.0)
            with mock.patch.object(window.serial_link, "send_command") as send:
                window._apply_generator()
            send.assert_not_called()
            self.assertIn("切换档位", window.statusBar().currentMessage())
            window.close()
            self.app.processEvents()

    def test_auto_connect_starts_udp_and_only_serial_port(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "auto.db")
            with (
                mock.patch("host.ui.main_window.list_ports.comports", return_value=[SimpleNamespace(device="COM14")]),
                mock.patch.object(window.udp_receiver, "start") as udp_start,
                mock.patch.object(window.serial_link, "connect_port") as uart_connect,
            ):
                window._auto_connect()
            udp_start.assert_called_once_with(PC_IP, UDP_PORT)
            uart_connect.assert_called_once_with("COM14", UART_BAUD)
            window.close()
            self.app.processEvents()

    def test_auto_connect_does_not_guess_between_multiple_serial_ports(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "multiple.db")
            ports = [SimpleNamespace(device="COM3"), SimpleNamespace(device="COM14")]
            with (
                mock.patch("host.ui.main_window.list_ports.comports", return_value=ports),
                mock.patch.object(window.settings, "value", return_value=""),
                mock.patch.object(window.udp_receiver, "start"),
                mock.patch.object(window.serial_link, "connect_port") as uart_connect,
            ):
                window._auto_connect()
            uart_connect.assert_not_called()
            window.close()
            self.app.processEvents()

    def test_auto_connect_prefers_last_successful_serial_port(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "preferred.db")
            ports = [SimpleNamespace(device="COM3"), SimpleNamespace(device="COM14")]
            with (
                mock.patch("host.ui.main_window.list_ports.comports", return_value=ports),
                mock.patch.object(window.settings, "value", return_value="COM14"),
                mock.patch.object(window.udp_receiver, "start"),
                mock.patch.object(window.serial_link, "connect_port") as uart_connect,
            ):
                window._auto_connect()
            uart_connect.assert_called_once_with("COM14", UART_BAUD)
            window.close()
            self.app.processEvents()

    def test_save_table_and_replay(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "replay.db")
            window.timebase_combo.setCurrentText("1 ms/div")
            payload = b"\x01\x00\x02\x00\x03\x00\x04\x00"
            live_frame = CompletedFrame(
                PacketHeader(1, 2, 9, 1, 100, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 3),
                payload,
            )
            window._on_frame(live_frame)
            window._save_current()
            self.assertEqual(window.records_table.rowCount(), 1)
            window.records_table.selectRow(0)
            window.current_frame = None
            window._replay_selected()
            self.assertEqual(window.current_frame.payload, payload)
            window.close()
            self.app.processEvents()

    def test_replay_preserves_frame_when_timebase_changes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "replay_tb.db")
            window.timebase_combo.setCurrentText("1 ms/div")
            payload = b"\x01\x00\x02\x00\x03\x00\x04\x00"
            live_frame = CompletedFrame(
                PacketHeader(1, 2, 9, 1, 100, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 3),
                payload,
            )
            window._on_frame(live_frame)
            window._save_current()
            window.timebase_combo.setCurrentText("10 ns/div")
            window.current_frame = None
            window.records_table.selectRow(0)
            window._replay_selected()
            self.assertIsNotNone(window.current_frame)
            self.assertEqual(window.current_frame.payload, payload)
            window.close()
            self.app.processEvents()

    def test_fft_analysis_on_envelope_and_raw_frames(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "fft.db")
            window.timebase_combo.setCurrentText("1 ms/div")
            window.analysis_combo.setCurrentText("FFT")
            self.assertTrue(window.plot_widget._fft)

            payload = struct.pack("<HHHH", 1000, 3000, 1500, 2500) * 100
            env_frame = CompletedFrame(
                PacketHeader(1, 2, 1, 100, 10000, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 3),
                payload,
            )
            window._on_frame(env_frame)
            self.assertGreater(window.plot_widget.fft_freq_per_div, 0)
            self.assertIn("/div", window.timebase_badge.text())
            self.assertIn("SPAN", window.trigger_badge.text())

            codes = (np.sin(np.linspace(0, 20, 500)) * 1000 + 2048).astype("<u4")
            raw_payload = (codes | (codes << 12)).tobytes()
            raw_frame = CompletedFrame(
                PacketHeader(1, 1, 2, len(codes), ADC_SAMPLE_RATE_HZ, 0, 3,
                             SampleFormat.RAW32, 0, 0, len(raw_payload), 0),
                raw_payload,
            )
            window._on_frame(raw_frame)
            self.assertGreater(window.plot_widget.fft_freq_per_div, 0)
            self.assertIn("/div", window.timebase_badge.text())

            window.analysis_combo.setCurrentText("时域")
            self.assertFalse(window.plot_widget._fft)
            self.assertEqual(window.timebase_badge.text(), window.timebase_combo.currentText().replace(" ", ""))

            window.close()
            self.app.processEvents()

    def test_replay_stops_continuous_acquisition(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "replay_stop.db")
            window._continuous_running = True
            payload = b"\x01\x00\x02\x00\x03\x00\x04\x00"
            live_frame = CompletedFrame(
                PacketHeader(1, 2, 9, 1, 100, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 3),
                payload,
            )
            window.current_frame = live_frame
            window._save_current()
            window.records_table.selectRow(0)
            with mock.patch.object(window, "_stop_acquisition") as stop_acq:
                window._replay_selected()
                stop_acq.assert_called_once()
            window.close()
            self.app.processEvents()

    def test_channel_and_time_div_are_sent_to_fpga(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "scope.db")
            window.channel_mode_combo.setCurrentText("CH2")
            window.timebase_combo.setCurrentText("2 ms/div")
            with mock.patch.object(window.serial_link, "send_command") as send:
                window._apply_acquisition()
            acquisition = send.call_args_list[0].args
            self.assertEqual(acquisition[0], Command.SET_ACQUISITION)
            fields = struct.unpack("<BHHBIHBB", acquisition[1])
            self.assertEqual(fields[-1], 0x02)
            self.assertEqual(fields[4], 1_300_000)  # 65Msps × 10格 × 2ms/div
            self.assertAlmostEqual(window.refresh_spin.value(), 20.0)
            # 长时基按桶对齐截到 ≤2048 点 Min/Max，使帧时长贴住十格窗口。
            self.assertEqual(window.display_points_spin.value(), 2048)
            self.assertFalse(window.ch1_vdiv_combo.isEnabled())
            self.assertTrue(window.ch2_vdiv_combo.isEnabled())
            self.assertEqual(window.trigger_source.currentIndex(), 1)
            window.close()
            self.app.processEvents()

    def test_timebase_commit_restores_envelope_points_after_short_timebase(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "points.db")
            window.display_points_spin.setValue(100)
            window.timebase_combo.setCurrentText("1 ms/div")
            with mock.patch.object(window.serial_link, "send_command"):
                window._apply_acquisition()
            self.assertGreater(window.display_points_spin.value(), 2000)
            self.assertLessEqual(window.display_points_spin.value(), 2048)
            window.close()
            self.app.processEvents()

    def test_short_timebase_keeps_one_to_one_adc_samples(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "hf.db")
            with mock.patch.object(window.serial_link, "send_command"):
                window.timebase_combo.setCurrentText("1 µs/div")
                window._apply_acquisition()
            self.assertEqual(window.depth_spin.value(), 650)
            self.assertEqual(window.display_points_spin.value(), 650)
            with mock.patch.object(window.serial_link, "send_command"):
                window.timebase_combo.setCurrentText("200 ns/div")
                window._apply_acquisition()
            self.assertEqual(window.depth_spin.value(), 130)
            self.assertEqual(window.display_points_spin.value(), 130)
            window.close()
            self.app.processEvents()

    def test_mid_timebase_envelope_duration_stays_within_match_window(self) -> None:
        """5/10/20 µs 曾因桶取整超 5% 被丢帧卡死；所有时基都必须过关。"""
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "mid-tb.db")
            try:
                frozen = []
                for seconds, label in TIME_PER_DIV:
                    capture = max(1, min(
                        RAW_MAX_SAMPLES,
                        int(ceil(ADC_SAMPLE_RATE_HZ * seconds * 10.0)),
                    ))
                    points = window._envelope_display_points(capture, 0x03, 20.0)
                    bucket = max(1, (capture + points - 1) // points)
                    env_rate = max(1, ADC_SAMPLE_RATE_HZ // bucket)
                    actual = points / env_rate
                    expected = capture / float(ADC_SAMPLE_RATE_HZ)
                    error = abs(actual - expected) / expected
                    if error > 0.05:
                        frozen.append(
                            f"{label}: {error:.1%} "
                            f"(depth={capture} points={points} bucket={bucket})"
                        )
                self.assertEqual(frozen, [])
                with mock.patch.object(window.serial_link, "send_command"):
                    window.timebase_combo.setCurrentText("5 µs/div")
                    window._apply_acquisition()
                self.assertEqual(window.depth_spin.value(), 3250)
                self.assertEqual(window.display_points_spin.value(), 1625)
                with mock.patch.object(window.serial_link, "send_command"):
                    window.timebase_combo.setCurrentText("10 µs/div")
                    window._apply_acquisition()
                self.assertEqual(window.depth_spin.value(), 6500)
                self.assertEqual(window.display_points_spin.value(), 1625)
                with mock.patch.object(window.serial_link, "send_command"):
                    window.timebase_combo.setCurrentText("20 µs/div")
                    window._apply_acquisition()
                self.assertEqual(window.depth_spin.value(), 13000)
                self.assertEqual(window.display_points_spin.value(), 1858)
            finally:
                window.close()
                self.app.processEvents()

    def test_five_us_envelope_frame_is_not_dropped(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "accept-5us.db")
            window.timebase_combo.setCurrentText("5 µs/div")
            payload = struct.pack("<" + "H" * (1625 * 4), *([0x800] * 1625 * 4))
            frame = CompletedFrame(
                PacketHeader(
                    1, 2, 11, 1625, ADC_SAMPLE_RATE_HZ // 2, 0, 3,
                    SampleFormat.ENVELOPE64, 0, 0, len(payload), 3,
                ),
                payload,
            )
            self.assertTrue(window._envelope_matches_timebase(frame))
            window._on_frame(frame)
            self.assertIs(window.current_frame, frame)
            stale = CompletedFrame(
                PacketHeader(
                    1, 2, 12, 2048, ADC_SAMPLE_RATE_HZ // 2, 0, 3,
                    SampleFormat.ENVELOPE64, 0, 0, 16, 3,
                ),
                b"\x00" * 16,
            )
            self.assertFalse(window._envelope_matches_timebase(stale))
            window.close()
            self.app.processEvents()

    def test_uart_connection_syncs_scope_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "connect-sync.db")
            with mock.patch.object(window.serial_link, "send_command") as send:
                window._on_uart_connection(True, "COM14")
                window._sync_scope_configuration()
            self.assertEqual(window.display_points_spin.value(), 650)
            self.assertTrue(window._continuous_running)
            self.assertTrue(any(call.args[0] == Command.ENVELOPE_ENABLE
                                 for call in send.call_args_list))
            window.close()
            self.app.processEvents()

    def test_timebase_change_discards_udp_backlog_and_redraws_current_frame(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "flush.db")
            window.timebase_combo.setCurrentText("1 ms/div")
            payload = struct.pack(
                "<" + "H" * 400,
                *([0x800, 0x900, 0x700, 0xA00] * 100),
            )
            envelope = CompletedFrame(
                PacketHeader(1, 2, 9, 100, 10000, 0, 3,
                             SampleFormat.ENVELOPE64, 0, 0, len(payload), 3),
                payload,
            )
            window._on_frame(envelope)
            with mock.patch.object(window.udp_receiver, "discard_pending") as flush:
                window.timebase_combo.setCurrentText("2 ms/div")
            flush.assert_called_once_with()
            self.assertIs(window.current_frame, envelope)
            window.close()
            self.app.processEvents()

    def test_manual_mode_hides_run_stop_and_sends_immediate_arm(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "manual.db")
            window.acquisition_mode_combo.setCurrentText("手动")
            self.assertTrue(window.run_button.isHidden())
            self.assertTrue(window.stop_button.isHidden())
            self.assertFalse(window.capture_button.isHidden())
            window.duration_spin.setValue(10)
            with mock.patch.object(window.serial_link, "send_command") as send:
                window._start_manual_capture()
            commands = [call.args[0] for call in send.call_args_list]
            self.assertEqual(commands[-1], Command.ARM)
            self.assertIn(Command.SET_PROCESSING, commands)
            processing = next(
                call.args[1] for call in send.call_args_list
                if call.args[0] == Command.SET_PROCESSING
            )
            self.assertEqual(processing[0], DataMode.RAW)
            acquisition = next(
                call.args[1] for call in send.call_args_list
                if call.args[0] == Command.SET_ACQUISITION
            )
            fields = struct.unpack("<BHHBIHBB", acquisition)
            self.assertEqual(fields[4], 650_000)
            self.assertEqual(fields[5], 0)
            self.assertTrue(window._manual_busy)
            window.close()
            self.app.processEvents()

    def test_manual_timebase_does_not_send_acquisition(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "manual-tb.db")
            window.acquisition_mode_combo.setCurrentText("手动")
            window._uart_connected = True
            with mock.patch.object(window.serial_link, "send_command") as send:
                window.timebase_combo.setCurrentText("2 ms/div")
            send.assert_not_called()
            window.close()
            self.app.processEvents()

    def test_manual_record_longer_than_half_second_fits_the_display(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "manual-long.db")
            try:
                self.assertFalse(window.timebase_combo.model().item(window.timebase_combo.count() - 1).isEnabled())
                window.acquisition_mode_combo.setCurrentText("手动")
                codes = np.full(900, 2048, dtype="<u2")
                frame = CompletedFrame(
                    PacketHeader(1, 1, 4, 900, 1000, 0, 1,
                                 SampleFormat.RAW16, 0, 0, codes.nbytes, 0),
                    codes.tobytes(),
                )
                window._fit_timebase_to_record(frame)
                window.plot_widget.display_frame(frame)
                self.assertEqual(window.timebase_combo.currentText(), "100 ms/div")
                self.assertEqual(window.plot_widget.plot.viewRange()[0], [0.0, 1.0])
                self.assertAlmostEqual(float(window.plot_widget.curve_a.getData()[0][-1]), 0.899)
                window.acquisition_mode_combo.setCurrentText("连续")
                self.assertEqual(window.timebase_combo.currentText(), "50 ms/div")
                self.assertFalse(window.timebase_combo.model().item(window.timebase_combo.count() - 1).isEnabled())
            finally:
                window.close()
                self.app.processEvents()

    def test_manual_raw_frame_updates_measurements(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = create_window(Path(directory) / "manual-raw.db")
            window.acquisition_mode_combo.setCurrentText("手动")
            window._manual_busy = True
            words = struct.pack("<II", 0x0000_0800, 0x0000_0A00)
            frame = CompletedFrame(
                PacketHeader(
                    1, 1, 3, 2, ADC_SAMPLE_RATE_HZ, 0, 3,
                    SampleFormat.RAW32, 0, 0, len(words), 0,
                ),
                words,
            )
            window._on_frame(frame)
            self.assertFalse(window._manual_busy)
            self.assertIs(window.current_frame, frame)
            self.assertNotEqual(window.measurement_labels[0].text(), "—")
            window.close()
            self.app.processEvents()


if __name__ == "__main__":
    unittest.main()
