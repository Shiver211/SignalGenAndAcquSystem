from __future__ import annotations

import os
import tempfile
import unittest
import struct
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PyQt5 import QtWidgets

from host.comm.data_protocol import CompletedFrame, PacketHeader, SampleFormat
from host.comm.control_protocol import Command
from host.config import PC_IP, UART_BAUD, UDP_PORT
from host.ui.main_window import MainWindow


class UiSmokeTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_window_constructs_and_closes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "ui.db")
            self.assertIn("FPGA", window.windowTitle())
            self.assertEqual(window.udp_bind_edit.text(), PC_IP)
            self.assertEqual(window.udp_port_spin.value(), UDP_PORT)
            self.assertIn("DAC 波形控制", [group.title() for group in window.findChildren(QtWidgets.QGroupBox)])
            window.close()
            self.app.processEvents()

    def test_dac_controls_submit_two_channels_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "dac.db")
            window.wave_boxes[0].setCurrentText("三角")
            window.frequency_spins[0].setValue(1250)
            window.amplitude_spins[0].setValue(0.8)
            with mock.patch.object(window.serial_link, "send_command") as send:
                window._apply_generator()
            self.assertEqual(len(send.call_args_list), 2)
            self.assertTrue(all(call.args[0] == Command.SET_GENERATOR for call in send.call_args_list))
            self.assertEqual(send.call_args_list[0].args[1][-1], 0)
            self.assertEqual(send.call_args_list[1].args[1][-1], 1)
            window.close()
            self.app.processEvents()

    def test_auto_connect_starts_udp_and_only_serial_port(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "auto.db")
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
            window = MainWindow(Path(directory) / "multiple.db")
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
            window = MainWindow(Path(directory) / "preferred.db")
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
            window = MainWindow(Path(directory) / "replay.db")
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

    def test_channel_and_time_div_are_sent_to_fpga(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "scope.db")
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
            # 长时基超过 FIFO/1:1 预算时截断为 2048 点 Min/Max。
            self.assertEqual(window.display_points_spin.value(), 2048)
            self.assertFalse(window.ch1_vdiv_combo.isEnabled())
            self.assertTrue(window.ch2_vdiv_combo.isEnabled())
            self.assertEqual(window.trigger_source.currentIndex(), 1)
            window.close()
            self.app.processEvents()

    def test_timebase_commit_restores_envelope_points_after_short_timebase(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "points.db")
            window.display_points_spin.setValue(100)
            window.timebase_combo.setCurrentText("1 ms/div")
            with mock.patch.object(window.serial_link, "send_command"):
                window._apply_acquisition()
            self.assertEqual(window.display_points_spin.value(), 2048)
            window.close()
            self.app.processEvents()

    def test_short_timebase_keeps_one_to_one_adc_samples(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "hf.db")
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

    def test_uart_connection_syncs_scope_configuration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            window = MainWindow(Path(directory) / "connect-sync.db")
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
            window = MainWindow(Path(directory) / "flush.db")
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


if __name__ == "__main__":
    unittest.main()
