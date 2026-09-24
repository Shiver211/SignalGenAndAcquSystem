from __future__ import annotations
import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from PyQt5 import QtCore, QtWidgets
from host.comm.control_protocol import (
    Command, Response, acquisition_payload, parse_device_status,
)
from host.comm.data_protocol import decode_raw32
from host.ui.main_window import MainWindow

class InterleaveTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])

    def test_protocol_and_switch(self):
        old = acquisition_payload(0,2048,16,0,650,50)
        self.assertEqual(len(old),14)
        new = acquisition_payload(0,2048,16,0,1300,50,channel_mask=1,sampling_mode=1)
        self.assertEqual(new[-1],1)
        self.assertEqual(len(new),15)
        with self.assertRaises(ValueError):
            acquisition_payload(1,2048,16,0,1300,50,channel_mask=2,sampling_mode=1)
        status=bytearray(32);status[0:2]=bytes((1,1));status[7]=7
        self.assertTrue(parse_device_status(status)["sample_overflow"])
        with tempfile.TemporaryDirectory() as directory:
            settings=QtCore.QSettings(str(Path(directory)/"test.ini"),QtCore.QSettings.IniFormat)
            w=MainWindow(Path(directory)/"test.db",auto_connect=False,settings=settings)
            try:
                w._uart_connected=True
                w.serial_link.send_command=Mock(side_effect=range(1,100))
                w._on_response(0,Response(Command.QUERY_STATUS,0,bytes(status[:7]+bytes((2,))+status[8:])))
                self.assertTrue(w.sampling_mode_combo.isEnabled())
                self.assertEqual(w.sample_rate_hz,65_000_000)
                for mode in (1,0):
                    w.sampling_mode_combo.setCurrentIndex(mode)
                    for command in (Command.STOP,Command.ENVELOPE_ENABLE,Command.SET_ACQUISITION):
                        self.assertEqual(w.serial_link.send_command.call_args.args[0],command)
                        if mode==1 and command==Command.SET_ACQUISITION:
                            w._on_response(w._mode_token,Response(command,4,b""))
                            self.assertTrue(w._mode_switching)
                            self.assertTrue(w._mode_retry.isActive())
                            w._mode_retry.stop()
                            w._send_mode_step()
                        w._on_response(w._mode_token,Response(command,0,b""))
                    self.assertFalse(w._continuous_running)
                    self.assertFalse(w._mode_switching)
                    self.assertEqual(w.sample_rate_hz,130_000_000 if mode else 65_000_000)
                    self.assertEqual(w._channel_mask(),1 if mode else 3)
                    self.assertEqual(w.channel_mode_combo.isEnabled(),not bool(mode))
                    self.assertEqual(w.duration_spin.maximum(),451 if mode else 900)
                    # 50 ms/div 仅双通道连续采集可用；100 ms/div 留给手动记录。
                    self.assertEqual(w.timebase_combo.model().item(w.timebase_combo.findText("50 ms/div")).isEnabled(),not bool(mode))
                    self.assertFalse(w.timebase_combo.model().item(w.timebase_combo.findText("100 ms/div")).isEnabled())
                    w._apply_acquisition()
                    payload=next(c.args[1] for c in reversed(w.serial_link.send_command.call_args_list)
                                 if c.args[0]==Command.SET_ACQUISITION)
                    self.assertEqual(struct.unpack_from("<I",payload,6)[0],1300 if mode else 650)
                w.sampling_mode_combo.setCurrentIndex(1)
                w._on_response(w._mode_token,Response(Command.STOP,4,b""))
                self.assertFalse(w._mode_switching)
                self.assertEqual(w._sampling_mode,0)
                # 旧协议周期状态不能反复覆盖用户的通道选择。
                status[1]=0
                w._status_received=False
                w._on_response(0,Response(Command.QUERY_STATUS,0,bytes(status)))
                w.channel_mode_combo.setCurrentIndex(2)
                w._on_response(0,Response(Command.QUERY_STATUS,0,bytes(status)))
                self.assertEqual(w._channel_mask(),2)
            finally:
                w.close()

    def test_fixed_calibration_status_does_not_send_configuration(self):
        status = bytearray(32); status[0:2] = bytes((1, 3)); status[7] = 11
        self.assertTrue(parse_device_status(status)['adc_calibration_active'])
        decoded = decode_raw32(struct.pack('<HHH', 0x1800, 0x0123, 0x0FFF), 1)
        self.assertEqual(decoded['a'].tolist(), [2048, 291, 4095])
        self.assertEqual(decoded['otr_a'].tolist(), [True, False, False])
        with tempfile.TemporaryDirectory() as directory:
            settings = QtCore.QSettings(str(Path(directory)/'fixed.ini'), QtCore.QSettings.IniFormat)
            settings.setValue('adc_cal/ch1_gain', 0.5)
            settings.setValue('adc_cal/ch1_offset', 1.0)
            settings.setValue('interleave_cal/A_gain', 1.2)
            w = MainWindow(Path(directory)/'test.db', auto_connect=False, settings=settings)
            try:
                w._uart_connected = True
                w.serial_link.send_command = Mock()
                w._on_response(0, Response(Command.QUERY_STATUS, 0, bytes(status)))
                w.serial_link.send_command.assert_not_called()
                self.assertEqual(w._sampling_mode, 1)
                self.assertFalse(hasattr(w, 'apply_interleave_calibration_button'))
                self.assertEqual(w.calibrate_buttons[1].text(), '校准 CH1')
                self.assertTrue(w.calibrate_buttons[1].isEnabled())
                self.assertFalse(w.calibrate_buttons[2].isEnabled())
                # 保留用户的显示幅度校准，但不向 FPGA 写入交织系数。
                self.assertEqual(w._adc_gain[1], 0.5)
                self.assertEqual(w._adc_offset[1], 1.0)
                from host.comm.data_protocol import decode_measurement_v1
                from host.core.waveform import (
                    code_to_voltage, fixed_dc_offset_v, format_voltage, vpp_from_code_span,
                )
                from host.tests.test_main_window_frame_selection import dual_measurement_payload
                measurement = decode_measurement_v1(dual_measurement_payload())
                w._render_measurement(measurement, 3)
                self.assertEqual(w.measurement_labels[0].text(), format_voltage(
                    code_to_voltage(
                        measurement.min_a, gain=0.5,
                        offset_v=1.0 + fixed_dc_offset_v(1, 0.5),
                    )))
                self.assertEqual(w.measurement_labels[2].text(), format_voltage(
                    vpp_from_code_span(measurement.vpp_a, gain=0.5), peak_to_peak=True))
                w.serial_link.send_command.assert_not_called()
            finally:
                w.close()
