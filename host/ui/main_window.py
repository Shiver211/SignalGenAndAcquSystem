"""M8 上位机主窗口。"""

from __future__ import annotations

from pathlib import Path

from PyQt5 import QtCore, QtGui, QtWidgets
from serial.tools import list_ports

from host.comm.control_protocol import (
    Command, DataMode, Response, Waveform, acquisition_payload,
    generator_payload, parse_device_status, processing_payload,
    raw_request_payload, retransmit_payload,
)
from host.comm.data_protocol import (
    CompletedFrame, DataType, SampleFormat, decode_measurement_v1,
)
from host.comm.serial_link import SerialLink
from host.comm.udp_receiver import UdpReceiver
from host.config import PC_IP, UART_BAUD, UDP_PORT
from host.db.sqlite_store import SqliteStore
from host.ui.plot_widget import PlotWidget


class MainWindow(QtWidgets.QMainWindow):
    def __init__(
        self, database_path: str | Path, parent: QtWidgets.QWidget | None = None,
        *, auto_connect: bool = False,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("FPGA 信号发生与采集系统")
        self.resize(1480, 900)
        self.serial_link = SerialLink(self)
        self.udp_receiver = UdpReceiver(self)
        self.store = SqliteStore(database_path)
        self.current_frame: CompletedFrame | None = None
        self.latest_raw_frame_id = 0
        self._uart_connected = False
        self.settings = QtCore.QSettings("FPGA Signal System", "Host")
        self._build_ui()
        self._connect_signals()
        self._refresh_ports()
        self._refresh_records()
        self.status_timer = QtCore.QTimer(self)
        self.status_timer.timeout.connect(self._query_status)
        self.status_timer.start(1000)
        if auto_connect:
            QtCore.QTimer.singleShot(0, self._auto_connect)

    def _build_ui(self) -> None:
        splitter = QtWidgets.QSplitter()
        splitter.addWidget(self._build_control_panel())
        splitter.addWidget(self._build_display_panel())
        splitter.setStretchFactor(1, 1)
        splitter.setSizes([390, 1090])
        self.setCentralWidget(splitter)
        self.statusBar().showMessage("就绪")

    def _build_control_panel(self) -> QtWidgets.QWidget:
        panel = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(panel)
        layout.addWidget(self._connection_group())
        layout.addWidget(self._generator_group())
        layout.addWidget(self._acquisition_group())
        layout.addWidget(self._device_status_group())
        layout.addStretch(1)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setWidget(panel)
        return scroll

    def _connection_group(self) -> QtWidgets.QGroupBox:
        group = QtWidgets.QGroupBox("连接")
        form = QtWidgets.QGridLayout(group)
        self.port_combo = QtWidgets.QComboBox()
        self.baud_combo = QtWidgets.QComboBox()
        self.baud_combo.addItems([str(UART_BAUD), "460800", "115200"])
        self.uart_button = QtWidgets.QPushButton("连接 UART")
        self.refresh_port_button = QtWidgets.QPushButton("刷新")
        self.udp_bind_edit = QtWidgets.QLineEdit(PC_IP)
        self.udp_port_spin = QtWidgets.QSpinBox()
        self.udp_port_spin.setRange(1, 65535)
        self.udp_port_spin.setValue(UDP_PORT)
        self.udp_button = QtWidgets.QPushButton("启动 UDP")
        form.addWidget(QtWidgets.QLabel("串口"), 0, 0)
        form.addWidget(self.port_combo, 0, 1)
        form.addWidget(self.refresh_port_button, 0, 2)
        form.addWidget(QtWidgets.QLabel("波特率"), 1, 0)
        form.addWidget(self.baud_combo, 1, 1)
        form.addWidget(self.uart_button, 1, 2)
        form.addWidget(QtWidgets.QLabel("UDP 绑定"), 2, 0)
        form.addWidget(self.udp_bind_edit, 2, 1)
        form.addWidget(self.udp_port_spin, 2, 2)
        form.addWidget(self.udp_button, 3, 1, 1, 2)
        return group

    def _generator_group(self) -> QtWidgets.QGroupBox:
        group = QtWidgets.QGroupBox("双通道信号发生")
        grid = QtWidgets.QGridLayout(group)
        grid.addWidget(QtWidgets.QLabel(""), 0, 0)
        grid.addWidget(QtWidgets.QLabel("CH1"), 0, 1)
        grid.addWidget(QtWidgets.QLabel("CH2"), 0, 2)
        self.wave_boxes, self.frequency_spins, self.amplitude_spins = [], [], []
        for channel in range(2):
            wave = QtWidgets.QComboBox()
            wave.addItems(["正弦", "三角", "方波"])
            frequency = QtWidgets.QDoubleSpinBox()
            frequency.setRange(0, 50_000)
            frequency.setDecimals(3)
            frequency.setValue(1000 * (channel + 1))
            frequency.setSuffix(" Hz")
            amplitude = QtWidgets.QDoubleSpinBox()
            amplitude.setRange(0, 5)
            amplitude.setDecimals(3)
            amplitude.setValue(1.0)
            amplitude.setSuffix(" Vpk")
            self.wave_boxes.append(wave)
            self.frequency_spins.append(frequency)
            self.amplitude_spins.append(amplitude)
            grid.addWidget(wave, 1, channel + 1)
            grid.addWidget(frequency, 2, channel + 1)
            grid.addWidget(amplitude, 3, channel + 1)
        grid.addWidget(QtWidgets.QLabel("波形"), 1, 0)
        grid.addWidget(QtWidgets.QLabel("频率"), 2, 0)
        grid.addWidget(QtWidgets.QLabel("幅度"), 3, 0)
        self.apply_generator_button = QtWidgets.QPushButton("原子提交两通道参数")
        grid.addWidget(self.apply_generator_button, 4, 0, 1, 3)
        return group

    def _acquisition_group(self) -> QtWidgets.QGroupBox:
        group = QtWidgets.QGroupBox("采集与显示")
        form = QtWidgets.QFormLayout(group)
        self.trigger_source = QtWidgets.QComboBox(); self.trigger_source.addItems(["CH A", "CH B"])
        self.trigger_edge = QtWidgets.QComboBox(); self.trigger_edge.addItems(["上升沿", "下降沿"])
        self.threshold_spin = QtWidgets.QSpinBox(); self.threshold_spin.setRange(0, 4095); self.threshold_spin.setValue(2048)
        self.hysteresis_spin = QtWidgets.QSpinBox(); self.hysteresis_spin.setRange(0, 4095); self.hysteresis_spin.setValue(16)
        self.depth_spin = QtWidgets.QSpinBox(); self.depth_spin.setRange(1, 58_720_256); self.depth_spin.setValue(20_000)
        self.pretrigger_spin = QtWidgets.QDoubleSpinBox(); self.pretrigger_spin.setRange(0, 100); self.pretrigger_spin.setValue(50); self.pretrigger_spin.setSuffix(" %")
        self.mode_combo = QtWidgets.QComboBox(); self.mode_combo.addItems(["RAW", "ENVELOPE", "DECIMATED"])
        self.decimation_combo = QtWidgets.QComboBox(); self.decimation_combo.addItems([str(1 << i) for i in range(11)])
        self.display_points_spin = QtWidgets.QSpinBox(); self.display_points_spin.setRange(1, 1_000_000); self.display_points_spin.setValue(1024)
        self.refresh_spin = QtWidgets.QDoubleSpinBox(); self.refresh_spin.setRange(0.001, 1000); self.refresh_spin.setValue(20); self.refresh_spin.setSuffix(" Hz")
        self.timebase_combo = QtWidgets.QComboBox(); self.timebase_combo.addItems(["0.1 ms/div", "0.2 ms/div", "0.5 ms/div", "1 ms/div", "2 ms/div", "5 ms/div", "10 ms/div", "100 ms/div", "1 s/div"]); self.timebase_combo.setCurrentText("1 ms/div")
        for label, widget in (
            ("触发源", self.trigger_source), ("触发边沿", self.trigger_edge),
            ("阈值码", self.threshold_spin), ("迟滞码", self.hysteresis_spin),
            ("采集深度", self.depth_spin), ("预触发", self.pretrigger_spin),
            ("数据模式", self.mode_combo), ("抽取倍率", self.decimation_combo),
            ("显示点数", self.display_points_spin), ("刷新率", self.refresh_spin),
            ("时间基准", self.timebase_combo),
        ):
            form.addRow(label, widget)
        self.apply_acquisition_button = QtWidgets.QPushButton("提交采集/处理参数")
        form.addRow(self.apply_acquisition_button)
        buttons = QtWidgets.QHBoxLayout()
        self.arm_button = QtWidgets.QPushButton("ARM")
        self.stop_button = QtWidgets.QPushButton("STOP")
        self.envelope_button = QtWidgets.QPushButton("连续包络：关")
        self.envelope_button.setCheckable(True)
        buttons.addWidget(self.arm_button); buttons.addWidget(self.stop_button); buttons.addWidget(self.envelope_button)
        form.addRow(buttons)
        raw_buttons = QtWidgets.QHBoxLayout()
        self.raw_frame_spin = QtWidgets.QSpinBox(); self.raw_frame_spin.setRange(0, 0x7FFFFFFF)
        self.raw_request_button = QtWidgets.QPushButton("请求 RAW")
        raw_buttons.addWidget(self.raw_frame_spin); raw_buttons.addWidget(self.raw_request_button)
        form.addRow("帧号", raw_buttons)
        return group

    def _device_status_group(self) -> QtWidgets.QGroupBox:
        group = QtWidgets.QGroupBox("设备状态")
        grid = QtWidgets.QGridLayout(group)
        self.status_labels: dict[str, QtWidgets.QLabel] = {}
        names = [
            ("uart", "UART"), ("phy", "PHY"), ("mig", "MIG"),
            ("capture", "采集"), ("adc", "ADC 时钟"), ("mmcm", "MMCM"),
            ("loss", "UDP错/丢帧"), ("otr", "OTR A/B"),
        ]
        for index, (key, text) in enumerate(names):
            label = QtWidgets.QLabel("未知")
            self.status_labels[key] = label
            grid.addWidget(QtWidgets.QLabel(text), index // 2, (index % 2) * 2)
            grid.addWidget(label, index // 2, (index % 2) * 2 + 1)
        return group

    def _build_display_panel(self) -> QtWidgets.QWidget:
        panel = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(panel)
        toolbar = QtWidgets.QHBoxLayout()
        self.analysis_combo = QtWidgets.QComboBox(); self.analysis_combo.addItems(["时域", "FFT"])
        self.save_button = QtWidgets.QPushButton("保存当前帧")
        self.note_edit = QtWidgets.QLineEdit(); self.note_edit.setPlaceholderText("记录备注")
        toolbar.addWidget(QtWidgets.QLabel("显示")); toolbar.addWidget(self.analysis_combo)
        toolbar.addWidget(self.note_edit, 1); toolbar.addWidget(self.save_button)
        layout.addLayout(toolbar)
        self.plot_widget = PlotWidget()
        layout.addWidget(self.plot_widget, 1)
        self.measurement_labels = [QtWidgets.QLabel("—") for _ in range(8)]
        measure = QtWidgets.QGroupBox("测量")
        grid = QtWidgets.QGridLayout(measure)
        titles = ["A Min", "A Max", "A Vpp", "A 频率", "B Min", "B Max", "B Vpp", "B 频率"]
        for i, title in enumerate(titles):
            grid.addWidget(QtWidgets.QLabel(title), i // 4 * 2, i % 4)
            grid.addWidget(self.measurement_labels[i], i // 4 * 2 + 1, i % 4)
        layout.addWidget(measure)
        records = QtWidgets.QGroupBox("SQLite 记录与回放")
        record_layout = QtWidgets.QVBoxLayout(records)
        self.records_table = QtWidgets.QTableWidget(0, 7)
        self.records_table.setHorizontalHeaderLabels(["ID", "时间", "帧号", "类型", "点数", "字节", "备注"])
        self.records_table.horizontalHeader().setSectionResizeMode(1, QtWidgets.QHeaderView.Stretch)
        record_layout.addWidget(self.records_table)
        record_buttons = QtWidgets.QHBoxLayout()
        self.refresh_records_button = QtWidgets.QPushButton("刷新")
        self.replay_button = QtWidgets.QPushButton("回放")
        self.delete_record_button = QtWidgets.QPushButton("删除")
        record_buttons.addStretch(1); record_buttons.addWidget(self.refresh_records_button); record_buttons.addWidget(self.replay_button); record_buttons.addWidget(self.delete_record_button)
        record_layout.addLayout(record_buttons)
        layout.addWidget(records)
        return panel

    def _connect_signals(self) -> None:
        self.refresh_port_button.clicked.connect(self._refresh_ports)
        self.uart_button.clicked.connect(self._toggle_uart)
        self.udp_button.clicked.connect(self._toggle_udp)
        self.apply_generator_button.clicked.connect(self._apply_generator)
        self.apply_acquisition_button.clicked.connect(self._apply_acquisition)
        self.arm_button.clicked.connect(lambda: self.serial_link.send_command(Command.ARM))
        self.stop_button.clicked.connect(lambda: self.serial_link.send_command(Command.STOP))
        self.envelope_button.toggled.connect(self._toggle_envelope)
        self.raw_request_button.clicked.connect(self._request_raw)
        self.timebase_combo.currentTextChanged.connect(self._set_timebase)
        self.analysis_combo.currentIndexChanged.connect(self._set_analysis)
        self.save_button.clicked.connect(self._save_current)
        self.refresh_records_button.clicked.connect(self._refresh_records)
        self.replay_button.clicked.connect(self._replay_selected)
        self.delete_record_button.clicked.connect(self._delete_selected)
        self.serial_link.connection_changed.connect(self._on_uart_connection)
        self.serial_link.response_received.connect(self._on_response)
        self.serial_link.request_failed.connect(lambda _, error: self.statusBar().showMessage(error, 5000))
        self.udp_receiver.running_changed.connect(self._on_udp_running)
        self.udp_receiver.frame_received.connect(self._on_frame)
        self.udp_receiver.packet_error.connect(lambda error: self.statusBar().showMessage(error, 3000))
        self.udp_receiver.retransmit_required.connect(self._request_retransmit)
        self.udp_receiver.stats_updated.connect(self._on_udp_stats)

    def _refresh_ports(self) -> None:
        current = self.port_combo.currentText()
        preferred = self.settings.value("connection/serial_port", "", type=str)
        ports = [port.device for port in list_ports.comports()]
        self.port_combo.clear(); self.port_combo.addItems(ports)
        if current in ports:
            self.port_combo.setCurrentText(current)
        elif preferred in ports:
            self.port_combo.setCurrentText(preferred)

    def _auto_connect(self) -> None:
        self._refresh_ports()
        if not self.udp_receiver.running:
            self.udp_receiver.start(self.udp_bind_edit.text().strip(), self.udp_port_spin.value())
        preferred = self.settings.value("connection/serial_port", "", type=str)
        may_connect_uart = self.port_combo.count() == 1 or (
            bool(preferred) and self.port_combo.findText(preferred) >= 0
        )
        if may_connect_uart and not self.serial_link.running:
            self.serial_link.connect_port(
                self.port_combo.currentText(), int(self.baud_combo.currentText())
            )

    def _toggle_uart(self) -> None:
        if self.serial_link.running:
            self.serial_link.disconnect_port()
        elif self.port_combo.currentText():
            self.serial_link.connect_port(self.port_combo.currentText(), int(self.baud_combo.currentText()))

    def _toggle_udp(self) -> None:
        if self.udp_receiver.running:
            self.udp_receiver.stop()
        else:
            self.udp_receiver.start(self.udp_bind_edit.text().strip(), self.udp_port_spin.value())

    def _apply_generator(self) -> None:
        for channel in (1, 2):
            payload = generator_payload(
                channel, Waveform(self.wave_boxes[channel - 1].currentIndex()),
                self.frequency_spins[channel - 1].value(),
                self.amplitude_spins[channel - 1].value(), commit=(channel == 2),
            )
            self.serial_link.send_command(Command.SET_GENERATOR, payload)

    def _apply_acquisition(self) -> None:
        self.serial_link.send_command(Command.SET_ACQUISITION, acquisition_payload(
            self.trigger_source.currentIndex(), self.threshold_spin.value(),
            self.hysteresis_spin.value(), self.trigger_edge.currentIndex(),
            self.depth_spin.value(), self.pretrigger_spin.value(), commit=False,
        ))
        self.serial_link.send_command(Command.SET_PROCESSING, processing_payload(
            DataMode(self.mode_combo.currentIndex()), int(self.decimation_combo.currentText()),
            self.display_points_spin.value(), self.refresh_spin.value(), commit=True,
        ))

    def _toggle_envelope(self, enabled: bool) -> None:
        self.envelope_button.setText(f"连续包络：{'开' if enabled else '关'}")
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, bytes((int(enabled),)))

    def _request_raw(self) -> None:
        self.serial_link.send_command(Command.REQUEST_RAW, raw_request_payload(self.raw_frame_spin.value()))

    def _request_retransmit(self, frame_id: int, offset: int, length: int) -> None:
        if self._uart_connected:
            self.serial_link.send_command(Command.REQUEST_RETRANSMIT, retransmit_payload(frame_id, offset, length))

    def _query_status(self) -> None:
        if self._uart_connected:
            self.serial_link.send_command(Command.QUERY_STATUS)

    def _on_uart_connection(self, connected: bool, detail: str) -> None:
        self._uart_connected = connected
        if connected:
            self.settings.setValue("connection/serial_port", detail)
        self.uart_button.setText("断开 UART" if connected else "连接 UART")
        self.status_labels["uart"].setText("已连接" if connected else "断开")
        self.statusBar().showMessage(detail, 3000)

    def _on_udp_running(self, running: bool, detail: str) -> None:
        self.udp_button.setText("停止 UDP" if running else "启动 UDP")
        self.statusBar().showMessage(detail, 3000)

    def _on_response(self, _: int, response: Response) -> None:
        if not response.ok:
            self.statusBar().showMessage(f"命令 0x{response.command:02X}: {response.status_name}", 5000)
            return
        if response.command == Command.QUERY_STATUS:
            status = parse_device_status(response.payload)
            self.status_labels["phy"].setText("已连接" if status["network_link_up"] else "断开")
            self.status_labels["mig"].setText("已校准" if status["ddr_calibrated"] else "未校准")
            self.status_labels["capture"].setText("ARM" if status["adc_armed"] else ("忙" if status["control_busy"] else "空闲"))
            self.status_labels["adc"].setText("正常" if status["adc_clock_alive"] else "异常")
            self.status_labels["mmcm"].setText("锁定" if status["mmcm_locked"] else "未锁定")

    def _on_frame(self, frame: CompletedFrame, persist_measurement: bool = True) -> None:
        if frame.header.sample_format == SampleFormat.RAW32:
            self.latest_raw_frame_id = frame.header.frame_id
            self.raw_frame_spin.setValue(frame.header.frame_id)
        if frame.header.sample_format == SampleFormat.MEASUREMENT_V1:
            measurement = decode_measurement_v1(frame.payload)
            if persist_measurement:
                self.store.save_measurement(frame.header.frame_id, measurement)
            values = [
                measurement.min_a, measurement.max_a, measurement.vpp_a, measurement.frequency_hz_a,
                measurement.min_b, measurement.max_b, measurement.vpp_b, measurement.frequency_hz_b,
            ]
            for label, value in zip(self.measurement_labels, values):
                label.setText(str(value))
            self.status_labels["otr"].setText(f"{measurement.otr_count_a}/{measurement.otr_count_b}")
        else:
            # 测量包只更新读数，不能覆盖用户准备保存/回放的波形帧。
            self.current_frame = frame
            self.plot_widget.display_frame(frame)

    def _on_udp_stats(self, stats: dict[str, int]) -> None:
        self.status_labels["loss"].setText(f"{stats['errors']}/{stats['dropped_frames']}")

    def _set_timebase(self, text: str) -> None:
        value, unit = text.split()[:2]
        seconds = float(value) * ({"ms/div": 1e-3, "s/div": 1.0}[unit])
        self.plot_widget.set_timebase(seconds)

    def _set_analysis(self, index: int) -> None:
        self.plot_widget.set_fft_enabled(index == 1)
        if self.current_frame is not None:
            self.plot_widget.display_frame(self.current_frame)

    def _save_current(self) -> None:
        if self.current_frame is None:
            self.statusBar().showMessage("当前没有可保存帧", 3000)
            return
        config = {
            "mode": self.mode_combo.currentText(), "decimation": int(self.decimation_combo.currentText()),
            "display_points": self.display_points_spin.value(), "refresh_hz": self.refresh_spin.value(),
        }
        record_id = self.store.save_frame(self.current_frame, config=config, note=self.note_edit.text())
        self.statusBar().showMessage(f"已保存记录 {record_id}", 3000)
        self._refresh_records()

    def _refresh_records(self) -> None:
        records = self.store.list_captures()
        self.records_table.setRowCount(len(records))
        for row, record in enumerate(records):
            values = [record.id, record.captured_at, record.frame_id, record.sample_format, record.total_samples, record.payload_bytes, record.note]
            for column, value in enumerate(values):
                self.records_table.setItem(row, column, QtWidgets.QTableWidgetItem(str(value)))

    def _selected_record_id(self) -> int | None:
        row = self.records_table.currentRow()
        item = self.records_table.item(row, 0) if row >= 0 else None
        return int(item.text()) if item else None

    def _replay_selected(self) -> None:
        record_id = self._selected_record_id()
        if record_id is not None:
            self._on_frame(self.store.load_frame(record_id), persist_measurement=False)

    def _delete_selected(self) -> None:
        record_id = self._selected_record_id()
        if record_id is not None:
            self.store.delete_capture(record_id)
            self._refresh_records()

    def closeEvent(self, event: QtGui.QCloseEvent) -> None:
        self.status_timer.stop()
        self.serial_link.disconnect_port()
        self.udp_receiver.stop()
        self.store.close()
        super().closeEvent(event)
