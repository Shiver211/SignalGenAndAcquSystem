"""M8 上位机主窗口。"""

from __future__ import annotations

from pathlib import Path
from math import ceil

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
from host.ui.plot_widget import ChannelDisplayMode, PlotWidget


ADC_SAMPLE_RATE_HZ = 65_000_000
RAW_MAX_SAMPLES = 58_720_256
# FPGA 当前每个包络桶对应一个 UDP 应用包。点数上限用于限制
# 接收线程、CRC 校验和 Qt 事件队列的实时负载，避免长时基下
# 每帧大量小包让界面持续积压。另一个上限按时间窗保留短时基分辨率。
MAX_ENVELOPE_POINTS_PER_SECOND = 75_000
MAX_ENVELOPE_UDP_PACKETS_PER_SECOND = 10_000
VOLTAGE_PER_DIV = (0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0)
TIME_PER_DIV = (
    (10e-9, "10 ns/div"), (20e-9, "20 ns/div"), (50e-9, "50 ns/div"),
    (100e-9, "100 ns/div"), (200e-9, "200 ns/div"), (500e-9, "500 ns/div"),
    (1e-6, "1 µs/div"), (2e-6, "2 µs/div"), (5e-6, "5 µs/div"),
    (10e-6, "10 µs/div"), (20e-6, "20 µs/div"), (50e-6, "50 µs/div"),
    (100e-6, "100 µs/div"), (200e-6, "200 µs/div"), (500e-6, "500 µs/div"),
    (1e-3, "1 ms/div"), (2e-3, "2 ms/div"), (5e-3, "5 ms/div"),
    (10e-3, "10 ms/div"), (20e-3, "20 ms/div"), (50e-3, "50 ms/div"),
    # RAW 环形区最多约 0.90s；保留到 50ms/div（0.5s/屏），避免
    # UI 显示的十格时间窗超过 FPGA 实际可采集深度。
)


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
        self._continuous_running = False
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
        splitter.setSizes([430, 1050])
        self.setCentralWidget(splitter)
        self.statusBar().showMessage("就绪")

    def _build_control_panel(self) -> QtWidgets.QWidget:
        panel = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(panel)
        layout.addWidget(self._connection_group())
        # 发生器仍保留为兼容接口，但基础示波器界面默认不展示高级功能。
        # 这样左侧不会被三列表格撑出横向滚动条。
        generator = self._generator_group()
        generator.setVisible(False)
        layout.addWidget(generator)
        layout.addWidget(self._acquisition_group())
        layout.addWidget(self._device_status_group())
        layout.addStretch(1)
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
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
        self.channel_mode_combo = QtWidgets.QComboBox()
        self.channel_mode_combo.addItem("双通道", ChannelDisplayMode.BOTH)
        self.channel_mode_combo.addItem("CH1", ChannelDisplayMode.CH1)
        self.channel_mode_combo.addItem("CH2", ChannelDisplayMode.CH2)
        self.ch1_vdiv_combo = QtWidgets.QComboBox()
        self.ch2_vdiv_combo = QtWidgets.QComboBox()
        for value in VOLTAGE_PER_DIV:
            label = f"{value:g} V/div" if value >= 1 else f"{value * 1000:g} mV/div"
            self.ch1_vdiv_combo.addItem(label, value)
            self.ch2_vdiv_combo.addItem(label, value)
        self.ch1_vdiv_combo.setCurrentIndex(5)  # 500mV/div
        self.ch2_vdiv_combo.setCurrentIndex(5)
        self.ch1_position_spin = QtWidgets.QDoubleSpinBox()
        self.ch2_position_spin = QtWidgets.QDoubleSpinBox()
        for spin in (self.ch1_position_spin, self.ch2_position_spin):
            spin.setRange(-4, 4); spin.setDecimals(2); spin.setSingleStep(0.1)
            spin.setSuffix(" div")
        self.trigger_source = QtWidgets.QComboBox(); self.trigger_source.addItems(["CH A", "CH B"])
        self.trigger_edge = QtWidgets.QComboBox(); self.trigger_edge.addItems(["上升沿", "下降沿"])
        self.threshold_spin = QtWidgets.QSpinBox(); self.threshold_spin.setRange(0, 4095); self.threshold_spin.setValue(2048)
        self.hysteresis_spin = QtWidgets.QSpinBox(); self.hysteresis_spin.setRange(0, 4095); self.hysteresis_spin.setValue(16)
        self.depth_spin = QtWidgets.QSpinBox(); self.depth_spin.setRange(1, 58_720_256); self.depth_spin.setValue(20_000)
        self.pretrigger_spin = QtWidgets.QDoubleSpinBox(); self.pretrigger_spin.setRange(0, 100); self.pretrigger_spin.setValue(50); self.pretrigger_spin.setSuffix(" %")
        # 基础示波器只需要 RAW 单次和 ENVELOPE 连续显示；DECIMATED 的
        # DDR 读回/UDP 链路尚未纳入基础功能，因此不在 UI 暴露死路径。
        self.mode_combo = QtWidgets.QComboBox(); self.mode_combo.addItems(["RAW", "ENVELOPE"])
        self.mode_combo.setCurrentIndex(1)
        self.decimation_combo = QtWidgets.QComboBox(); self.decimation_combo.addItems([str(1 << i) for i in range(11)])
        self.display_points_spin = QtWidgets.QSpinBox(); self.display_points_spin.setRange(1, 1_000_000); self.display_points_spin.setValue(1024)
        self.refresh_spin = QtWidgets.QDoubleSpinBox(); self.refresh_spin.setRange(0.001, 4_000_000); self.refresh_spin.setDecimals(3); self.refresh_spin.setValue(20); self.refresh_spin.setSuffix(" Hz")
        self.timebase_combo = QtWidgets.QComboBox()
        for value, label in TIME_PER_DIV:
            self.timebase_combo.addItem(label, value)
        self.timebase_combo.setCurrentText("1 ms/div")
        form.addRow("通道模式", self.channel_mode_combo)
        form.addRow("CH1 电压", self.ch1_vdiv_combo)
        form.addRow("CH1 位置", self.ch1_position_spin)
        form.addRow("CH2 电压", self.ch2_vdiv_combo)
        form.addRow("CH2 位置", self.ch2_position_spin)
        for label, widget in (
            ("触发源", self.trigger_source), ("触发边沿", self.trigger_edge),
            ("阈值码", self.threshold_spin), ("迟滞码", self.hysteresis_spin),
            ("采集深度", self.depth_spin), ("预触发", self.pretrigger_spin),
            ("显示点数", self.display_points_spin), ("刷新率", self.refresh_spin),
            ("时间基准", self.timebase_combo),
        ):
            form.addRow(label, widget)
        self.apply_acquisition_button = QtWidgets.QPushButton("提交采集/处理参数")
        form.addRow(self.apply_acquisition_button)
        buttons = QtWidgets.QHBoxLayout()
        self.run_button = QtWidgets.QPushButton("运行")
        self.stop_button = QtWidgets.QPushButton("停止")
        self.single_button = QtWidgets.QPushButton("单次")
        self.arm_button = self.single_button  # 兼容旧代码中的控件名
        buttons.addWidget(self.run_button); buttons.addWidget(self.stop_button); buttons.addWidget(self.single_button)
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
        toolbar.addWidget(QtWidgets.QLabel("波形显示（10 × 8 div）"))
        toolbar.addStretch(1)
        # FFT、记录/回放属于后续高级功能，保留对象和槽函数但不放入主布局。
        self.analysis_combo.setVisible(False)
        self.note_edit.setVisible(False)
        self.save_button.setVisible(False)
        layout.addLayout(toolbar)
        self.plot_widget = PlotWidget()
        self.plot_widget.set_timebase(float(self.timebase_combo.currentData()))
        self.plot_widget.set_volts_per_div(1, float(self.ch1_vdiv_combo.currentData()))
        self.plot_widget.set_volts_per_div(2, float(self.ch2_vdiv_combo.currentData()))
        self._update_channel_controls()
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
        records.setVisible(False)
        layout.addWidget(records)
        return panel

    def _connect_signals(self) -> None:
        self.refresh_port_button.clicked.connect(self._refresh_ports)
        self.uart_button.clicked.connect(self._toggle_uart)
        self.udp_button.clicked.connect(self._toggle_udp)
        self.apply_generator_button.clicked.connect(self._apply_generator)
        self.apply_acquisition_button.clicked.connect(self._apply_acquisition)
        self.run_button.clicked.connect(self._run_acquisition)
        self.stop_button.clicked.connect(self._stop_acquisition)
        self.single_button.clicked.connect(self._single_acquisition)
        self.raw_request_button.clicked.connect(self._request_raw)
        self.timebase_combo.currentTextChanged.connect(self._set_timebase)
        self.channel_mode_combo.currentIndexChanged.connect(self._set_channel_mode)
        self.ch1_vdiv_combo.currentIndexChanged.connect(lambda: self._set_vdiv(1))
        self.ch2_vdiv_combo.currentIndexChanged.connect(lambda: self._set_vdiv(2))
        self.ch1_position_spin.valueChanged.connect(lambda value: self.plot_widget.set_vertical_position_div(1, value))
        self.ch2_position_spin.valueChanged.connect(lambda value: self.plot_widget.set_vertical_position_div(2, value))
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
        was_continuous = self._continuous_running
        if self._uart_connected:
            self.serial_link.send_command(Command.STOP)
        channel_mask = {
            ChannelDisplayMode.CH1: 0x01,
            ChannelDisplayMode.CH2: 0x02,
            ChannelDisplayMode.BOTH: 0x03,
        }[ChannelDisplayMode(self.channel_mode_combo.currentData())]
        time_per_div = float(self.timebase_combo.currentData())
        requested_depth = int(ceil(ADC_SAMPLE_RATE_HZ * time_per_div * 10.0))
        capture_depth = max(1, min(RAW_MAX_SAMPLES, requested_depth))
        self.serial_link.send_command(Command.SET_ACQUISITION, acquisition_payload(
            self.trigger_source.currentIndex(), self.threshold_spin.value(),
            self.hysteresis_spin.value(), self.trigger_edge.currentIndex(),
            capture_depth, self.pretrigger_spin.value(),
            channel_mask=channel_mask, commit=False,
        ))
        self.depth_spin.setValue(capture_depth)
        self.display_points_spin.setValue(
            max(1, min(self.display_points_spin.value(), capture_depth))
        )
        display_points = self.display_points_spin.value()
        if DataMode(self.mode_combo.currentIndex()) == DataMode.ENVELOPE:
            max_envelope_points = max(
                1,
                int(10.0 * time_per_div * MAX_ENVELOPE_POINTS_PER_SECOND),
            )
            max_points_by_packet_rate = max(
                1,
                int(MAX_ENVELOPE_UDP_PACKETS_PER_SECOND /
                    max(self.refresh_spin.value(), 1.0)),
            )
            # 包络模式的点数由时基和链路能力决定。每次提交都重新
            # 计算，避免短时基曾经降到 100 点后，切回长时基仍只剩
            # 100 点的状态残留。硬件一个点占一个 UDP 包，额外限制
            # 每秒包数，防止长时基把接收线程和 Qt 事件队列压满。
            display_points = min(
                capture_depth, max_envelope_points, max_points_by_packet_rate,
            )
            self.display_points_spin.setValue(display_points)
        self.serial_link.send_command(Command.SET_PROCESSING, processing_payload(
            DataMode(self.mode_combo.currentIndex()), int(self.decimation_combo.currentText()),
            display_points, self.refresh_spin.value(), commit=True,
        ))
        if was_continuous:
            self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x01")

    def _run_acquisition(self) -> None:
        self.mode_combo.setCurrentIndex(DataMode.ENVELOPE)
        self._apply_acquisition()
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x01")
        self._continuous_running = True
        self.statusBar().showMessage("连续运行", 2000)

    def _stop_acquisition(self) -> None:
        self._continuous_running = False
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x00")
        self.serial_link.send_command(Command.STOP)
        self.statusBar().showMessage("已停止", 2000)

    def _single_acquisition(self) -> None:
        self._continuous_running = False
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x00")
        self.mode_combo.setCurrentIndex(DataMode.RAW)
        self._apply_acquisition()
        self.serial_link.send_command(Command.ARM)
        self.statusBar().showMessage("等待单次触发", 2000)

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
            # FPGA 可能还保留上一次会话的显示点数（例如 100 点）。
            # 连接后立即按当前 UI 时基同步一次，避免旧配置继续驱动
            # 新窗口；延迟一个事件循环周期以确保串口工作线程已就绪。
            QtCore.QTimer.singleShot(100, self._sync_scope_configuration)
        self.uart_button.setText("断开 UART" if connected else "连接 UART")
        self.status_labels["uart"].setText("已连接" if connected else "断开")
        self.statusBar().showMessage(detail, 3000)

    def _sync_scope_configuration(self) -> None:
        if not self._uart_connected:
            return
        self._apply_acquisition()
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x01")
        self._continuous_running = True

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
        if frame.header.sample_format in (SampleFormat.RAW32, SampleFormat.RAW16):
            self.latest_raw_frame_id = frame.header.frame_id
            self.raw_frame_spin.setValue(frame.header.frame_id)
        if frame.header.sample_format == SampleFormat.MEASUREMENT_V1:
            measurement = decode_measurement_v1(frame.payload)
            if persist_measurement:
                self.store.save_measurement(frame.header.frame_id, measurement)
            values = (
                (measurement.min_a, measurement.max_a, measurement.vpp_a,
                 measurement.frequency_hz_a, measurement.period_valid_a),
                (measurement.min_b, measurement.max_b, measurement.vpp_b,
                 measurement.frequency_hz_b, measurement.period_valid_b),
            )
            for channel, channel_values in enumerate(values, start=1):
                enabled = bool(frame.header.channel_mask & (1 << (channel - 1)))
                text_values = (
                    str(value) if enabled and (index != 3 or valid)
                    else ("无效" if enabled else "未启用")
                    for index, value in enumerate(channel_values[:4])
                    for valid in [index != 3 or channel_values[4]]
                )
                for label, value in zip(self.measurement_labels[(channel - 1) * 4:channel * 4],
                                        text_values):
                    label.setText(value)
            otr_a = (str(measurement.otr_count_a)
                     if frame.header.channel_mask & 0x01 else "未启用")
            otr_b = (str(measurement.otr_count_b)
                     if frame.header.channel_mask & 0x02 else "未启用")
            self.status_labels["otr"].setText(f"{otr_a}/{otr_b}")
        else:
            # 时基切换期间残留的旧包络帧不能覆盖即时过渡显示；只有
            # 帧头时长匹配当前窗口的新帧才更新当前波形。
            if (frame.header.sample_format in
                    (SampleFormat.ENVELOPE64, SampleFormat.ENVELOPE32) and
                    not self._envelope_matches_timebase(frame)):
                return
            # 测量包只更新读数，不能覆盖用户准备保存/回放的波形帧。
            self.current_frame = frame
            self.plot_widget.display_frame(frame)

    def _envelope_matches_timebase(self, frame: CompletedFrame) -> bool:
        """判断包络帧总时长是否匹配当前示波器横轴。"""
        sample_rate = frame.header.sample_rate_hz
        sample_count = frame.header.total_samples
        seconds_per_div = self.timebase_combo.currentData()
        if sample_rate <= 0 or sample_count <= 0 or seconds_per_div is None:
            return False
        actual = sample_count / float(sample_rate)
        expected = 10.0 * float(seconds_per_div)
        # 桶大小取整会产生很小的误差，5% 足以区分相邻时基的旧帧。
        return abs(actual - expected) <= expected * 0.05

    def _on_udp_stats(self, stats: dict[str, int]) -> None:
        self.status_labels["loss"].setText(f"{stats['errors']}/{stats['dropped_frames']}")

    def _set_timebase(self, text: str) -> None:
        seconds = self.timebase_combo.currentData()
        if seconds is not None:
            self.plot_widget.set_timebase(float(seconds))
            # 先清掉 socket 中的旧配置报文，再提交 FPGA 新参数；旧帧
            # 仍可由下面的即时重绘作为过渡，但不会排队数秒后才看到新帧。
            self.udp_receiver.discard_pending()
            # 立即按新时基重绘当前帧；包络显示会把它映射到新的
            # 10 格时间窗，不再等待 FPGA 产生下一帧。
            if self.current_frame is not None:
                self.plot_widget.display_frame(self.current_frame)
            if self._uart_connected:
                self._apply_acquisition()

    def _set_channel_mode(self, _: int) -> None:
        mode = self.channel_mode_combo.currentData()
        if mode is not None:
            self.plot_widget.set_channel_mode(mode)
            self._update_channel_controls()
            # 通道开关属于采集配置：已连接时立即让 FPGA 停止采集/传输未选通道。
            if self._uart_connected:
                self._apply_acquisition()

    def _update_channel_controls(self) -> None:
        """让 UI 的可调项与 FPGA 实际启用的通道保持一致。"""
        mode = ChannelDisplayMode(self.channel_mode_combo.currentData())
        ch1_active = mode in (ChannelDisplayMode.BOTH, ChannelDisplayMode.CH1)
        ch2_active = mode in (ChannelDisplayMode.BOTH, ChannelDisplayMode.CH2)
        self.ch1_vdiv_combo.setEnabled(ch1_active)
        self.ch1_position_spin.setEnabled(ch1_active)
        self.ch2_vdiv_combo.setEnabled(ch2_active)
        self.ch2_position_spin.setEnabled(ch2_active)
        self.trigger_source.setEnabled(mode == ChannelDisplayMode.BOTH)
        if mode == ChannelDisplayMode.CH1:
            self.trigger_source.setCurrentIndex(0)
        elif mode == ChannelDisplayMode.CH2:
            self.trigger_source.setCurrentIndex(1)

    def _set_vdiv(self, channel: int) -> None:
        combo = self.ch1_vdiv_combo if channel == 1 else self.ch2_vdiv_combo
        value = combo.currentData()
        if value is not None:
            self.plot_widget.set_volts_per_div(channel, float(value))

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
