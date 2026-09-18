from __future__ import annotations
import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock
from PyQt5 import QtCore, QtWidgets
from host.comm.control_protocol import Command, Response, acquisition_payload, parse_device_status
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
                    self.assertEqual(w.timebase_combo.model().item(w.timebase_combo.count()-1).isEnabled(),not bool(mode))
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
