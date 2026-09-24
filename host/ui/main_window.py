"""M8 上位机主窗口。"""

from __future__ import annotations

from enum import IntEnum
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from math import ceil
from time import monotonic

from PyQt5 import QtCore, QtGui, QtWidgets
from serial.tools import list_ports

from host.comm.control_protocol import (
    Command, DataMode, Response, StatusCode, Waveform, acquisition_payload,
    generator_payload, parse_device_status, processing_payload,
    raw_request_payload, retransmit_payload,
)
from host.comm.data_protocol import (
    CompletedFrame, Measurement, SampleFormat, decode_measurement_v1,
    decode_envelope64, decode_raw32,
)
from host.comm.serial_link import SerialLink
from host.comm.udp_receiver import UdpReceiver
from host.config import (
    ADC_SAMPLE_RATE_HZ, INTERLEAVE_SAMPLE_RATE_HZ, GBE_ENVELOPE_BYTES_PER_SEC, MAX_ENVELOPE_POINTS,
    PC_IP, UART_BAUD, UDP_PORT,
)
from host.core.dac_calibration import (
    TEST_FRACTION, full_scale_vpp_from_test, nominal_vpk_for_target,
)
from host.core.waveform import (
    MeasurementDisplayFilter, code_to_voltage, fixed_dc_offset_v, format_frequency_hz,
    format_voltage, gain_from_known_vpp, square_plateau_stats, vpp_from_code_span,
    zero_crossing_frequency,
)
from host.db.sqlite_store import SqliteStore
from host.ui.plot_widget import ChannelDisplayMode, DEFAULT_SMOOTHING_START_HZ, PlotWidget
from host.ui.icons import ICON_ON_ACCENT, icon
from host.ui.segmented import SegmentedControl
from host.ui.theme import CH1_COLOR, CH2_COLOR, PLOT_BACKGROUND, STYLE_SHEET, set_led


class AcquisitionMode(IntEnum):
    CONTINUOUS = 0
    MANUAL = 1


RAW_MAX_SAMPLES = 58_720_256
MANUAL_MAX_SECONDS = 0.9
MANUAL_MAX_MS = 900
VOLTAGE_PER_DIV = (0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0)
TIME_PER_DIV = (
    (10e-9, "10 ns/div"), (20e-9, "20 ns/div"), (50e-9, "50 ns/div"),
    (100e-9, "100 ns/div"), (200e-9, "200 ns/div"), (500e-9, "500 ns/div"),
    (1e-6, "1 µs/div"), (2e-6, "2 µs/div"), (5e-6, "5 µs/div"),
    (10e-6, "10 µs/div"), (20e-6, "20 µs/div"), (50e-6, "50 µs/div"),
    (100e-6, "100 µs/div"), (200e-6, "200 µs/div"), (500e-6, "500 µs/div"),
    (1e-3, "1 ms/div"), (2e-3, "2 ms/div"), (5e-3, "5 ms/div"),
    (10e-3, "10 ms/div"), (20e-3, "20 ms/div"), (50e-3, "50 ms/div"),
    (100e-3, "100 ms/div"),  # 手动 900 ms 记录需要 1 s 的十格窗口。
)
DAC_GAIN_MODES = ("low", "high")
STATUS_OK = {"已连接", "已校准", "锁定", "正常", "就绪", "空闲", "ARM"}
STATUS_BAD = {"断开", "未校准", "未锁定", "异常", "溢出", "未就绪"}


class MainWindow(QtWidgets.QMainWindow):
    def __init__(
        self, database_path: str | Path, parent: QtWidgets.QWidget | None = None,
        *, auto_connect: bool = False, settings: QtCore.QSettings | None = None,
    ) -> None:
        super().__init__(parent)
        self.setWindowTitle("FPGA 信号发生与采集系统")
        self.resize(1480, 900)
        self.serial_link = SerialLink(self)
        self.udp_receiver = UdpReceiver(self)
        self.store = SqliteStore(database_path)
        self.current_frame: CompletedFrame | None = None
        self.latest_raw_frame_id = 0
        self._last_measurement: Measurement | None = None
        self._last_measurement_mask = 0
        self._displayed_measurement: Measurement | None = None
        self._measurement_filter = MeasurementDisplayFilter()
        self._hardware_measurement: Measurement | None = None
        self._hardware_measurement_mask = 0
        self._square_amplitude: dict[str, int] = {}
        self._square_amplitude_mask = 0
        self._square_amplitude_time = 0.0
        self._adc_gain = {1: 1.0, 2: 1.0}
        self._adc_offset = {1: 0.0, 2: 0.0}
        self._uart_connected = False
        self._continuous_running = False
        self._pending_trigger_alignment: tuple[int, int, tuple[int, int, int, bool]] | None = None
        self._acquisition_mode = AcquisitionMode.CONTINUOUS
        self._sampling_mode = 0
        self._interleave_supported = False
        self._status_received = False
        self._mode_switching = False
        self._mode_steps = []
        self._mode_token = None
        self._mode_target = 0
        self._mode_deadline = 0.0
        self._mode_command = None
        self._mode_retry = QtCore.QTimer(self)
        self._mode_retry.setSingleShot(True)
        self._mode_retry.timeout.connect(self._send_mode_step)
        self._manual_busy = False
        self._manual_retried = False
        self.settings = settings or QtCore.QSettings("FPGA Signal System", "Host")
        self._load_adc_calibration()
        self._dac_full_scale_vpp: dict[tuple[int, int], float] = {}
        self._dac_test_modes: tuple[int, int] | None = None
        self._load_dac_calibration()
        self._build_ui()
        self._connect_signals()
        self._refresh_ports()
        self._refresh_records()
        self.status_timer = QtCore.QTimer(self)
        self.status_timer.timeout.connect(self._query_status)
        self.status_timer.start(1000)
        self._manual_timeout = QtCore.QTimer(self)
        self._manual_timeout.setSingleShot(True)
        self._manual_timeout.timeout.connect(self._on_manual_timeout)
        if auto_connect:
            QtCore.QTimer.singleShot(0, self._auto_connect)

    @property
    def _continuous_running(self) -> bool:
        return self._running

    @_continuous_running.setter
    def _continuous_running(self, running: bool) -> None:
        self._running = bool(running)
        if hasattr(self, "run_button"):
            self._update_run_button()

    def _update_run_button(self) -> None:
        running = self._continuous_running
        self.run_button.setText("停止" if running else "运行")
        self.run_button.setIcon(icon("stop" if running else "play", ICON_ON_ACCENT))
        self.run_button.setToolTip("停止连续采集" if running else "开始连续采集")
        self._styled(self.run_button, kind="stop" if running else "run")
        self.run_button.style().unpolish(self.run_button)
        self.run_button.style().polish(self.run_button)

    def _toggle_run(self) -> None:
        if self._continuous_running:
            self._stop_acquisition()
        else:
            self._run_acquisition()

    def _apply_icons(self) -> None:
        for button, name, color in (
            (self.refresh_port_button, "refresh", None),
            (self.uart_button, "link", ICON_ON_ACCENT),
            (self.udp_button, "network", ICON_ON_ACCENT),
            (self.apply_generator_button, "output", ICON_ON_ACCENT),
            (self.dac_test_button, "send", ICON_ON_ACCENT),
            (self.apply_acquisition_button, "check", None),
            *((self.calibrate_buttons[ch], "target", None) for ch in (1, 2)),
            *((self.reset_cal_buttons[ch], "reset", None) for ch in (1, 2)),
            (self.save_button, "save", None),
            (self.refresh_records_button, "refresh", None),
            (self.replay_button, "play", None),
            (self.delete_record_button, "reset", None),
        ):
            button.setIcon(icon(name, color) if color else icon(name))
            button.setIconSize(QtCore.QSize(15, 15))
        for index, name in enumerate(("target", "target", "sliders")):
            self.settings_tabs.setTabIcon(index, icon(name))
        self.settings_tabs.setIconSize(QtCore.QSize(16, 16))

    def _build_ui(self) -> None:
        self.setStyleSheet(STYLE_SHEET)
        sidebar = self._build_control_panel()
        display = self._build_display_panel()
        body = QtWidgets.QHBoxLayout()
        body.setContentsMargins(0, 0, 0, 0)
        body.setSpacing(0)
        body.addWidget(sidebar)
        body.addWidget(display, 1)
        root = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(root)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)
        layout.addWidget(self._build_header())
        layout.addLayout(body, 1)
        self.setCentralWidget(root)
        self.settings_dialog = self._build_settings_dialog()
        self._apply_icons()
        self._build_status_bar()
        self._update_acquisition_mode_widgets()
        self.statusBar().showMessage("就绪")

    @staticmethod
    def _styled(widget: QtWidgets.QWidget, **properties: str) -> QtWidgets.QWidget:
        for name, value in properties.items():
            widget.setProperty(name, value)
        return widget

    @staticmethod
    def _hint(text: str) -> QtWidgets.QLabel:
        label = QtWidgets.QLabel(text)
        label.setWordWrap(True)
        label.setProperty("role", "hint")
        return label

    @staticmethod
    def _form(group: QtWidgets.QWidget) -> QtWidgets.QFormLayout:
        form = QtWidgets.QFormLayout(group)
        form.setContentsMargins(0, 0, 0, 0)
        form.setHorizontalSpacing(14)
        form.setVerticalSpacing(10)
        form.setLabelAlignment(QtCore.Qt.AlignLeft | QtCore.Qt.AlignVCenter)
        form.setFieldGrowthPolicy(QtWidgets.QFormLayout.AllNonFixedFieldsGrow)
        return form

    def _segmented(self, combo: QtWidgets.QComboBox, labels: list[str] | None = None) -> SegmentedControl:
        return SegmentedControl(combo, self, labels)

    def _build_header(self) -> QtWidgets.QWidget:
        """顶部工具条：标题 + 运行控制，采集状态一眼可见。"""
        header = QtWidgets.QWidget()
        header.setObjectName("header")
        header.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        header.setFixedHeight(60)
        row = QtWidgets.QHBoxLayout(header)
        row.setContentsMargins(12, 0, 16, 0)
        row.setSpacing(10)
        # 左上角设置入口：校准与显示平滑等低频配置集中在设置窗口。
        self.settings_button = QtWidgets.QToolButton()
        self.settings_button.setObjectName("settingsButton")
        self.settings_button.setIcon(icon("settings"))
        self.settings_button.setIconSize(QtCore.QSize(20, 20))
        self.settings_button.setFixedSize(38, 38)
        self.settings_button.setToolTip("设置：DAC/ADC 校准、显示平滑")
        self.settings_button.setCursor(QtCore.Qt.PointingHandCursor)
        self.settings_button.clicked.connect(self._show_settings)
        row.addWidget(self.settings_button)
        row.addSpacing(4)
        titles = QtWidgets.QVBoxLayout()
        titles.setSpacing(0)
        title = QtWidgets.QLabel("Signal Studio")
        title.setObjectName("appTitle")
        subtitle = QtWidgets.QLabel("FPGA 信号发生与采集系统")
        subtitle.setObjectName("appSubtitle")
        titles.addStretch(1)
        titles.addWidget(title)
        titles.addWidget(subtitle)
        titles.addStretch(1)
        row.addLayout(titles)
        row.addStretch(1)
        row.addWidget(self.capture_progress)
        row.addWidget(self.acquisition_mode_segment)
        row.addSpacing(6)
        row.addWidget(self.run_button)
        row.addWidget(self.capture_button)
        return header

    @staticmethod
    def _scrolled(widget: QtWidgets.QWidget) -> QtWidgets.QScrollArea:
        scroll = QtWidgets.QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setFrameShape(QtWidgets.QFrame.NoFrame)
        scroll.setHorizontalScrollBarPolicy(QtCore.Qt.ScrollBarAlwaysOff)
        scroll.setWidget(widget)
        return scroll

    def _build_control_panel(self) -> QtWidgets.QWidget:
        sidebar = QtWidgets.QWidget()
        sidebar.setObjectName("sidebar")
        sidebar.setAttribute(QtCore.Qt.WA_StyledBackground, True)
        sidebar.setFixedWidth(520)
        outer = QtWidgets.QVBoxLayout(sidebar)
        outer.setContentsMargins(0, 0, 0, 0)
        tabs = QtWidgets.QTabWidget()
        tabs.setDocumentMode(True)
        # 示波器页放第一位；信号源、连接和记录分别独立，避免长滚动。
        pages = (
            ("示波器", "scope", (self._acquisition_group,)),
            ("信号源", "wave", (self._generator_group,)),
            ("连接", "plug", (self._connection_group,)),
            ("记录", "save", (self._records_page,)),
        )
        tabs.setIconSize(QtCore.QSize(16, 16))
        for title, icon_name, builders in pages:
            page = QtWidgets.QWidget()
            layout = QtWidgets.QVBoxLayout(page)
            layout.setContentsMargins(14, 6, 10, 14)
            layout.setSpacing(12)
            for build in builders:
                layout.addWidget(build())
            layout.addStretch(1)
            tabs.addTab(self._scrolled(page), icon(icon_name), title)
        outer.addWidget(tabs)
        self.control_tabs = tabs
        return sidebar

    def _connection_group(self) -> QtWidgets.QGroupBox:
        group = QtWidgets.QGroupBox("连接")
        form = self._form(group)
        self.port_combo = QtWidgets.QComboBox()
        self.baud_combo = QtWidgets.QComboBox()
        self.baud_combo.addItems([str(UART_BAUD), "460800", "115200"])
        self.uart_button = self._styled(QtWidgets.QPushButton("连接 UART"), kind="primary")
        self.refresh_port_button = self._styled(QtWidgets.QPushButton("刷新"), kind="ghost")
        self.udp_bind_edit = QtWidgets.QLineEdit(PC_IP)
        self.udp_port_spin = QtWidgets.QSpinBox()
        self.udp_port_spin.setRange(1, 65535)
        self.udp_port_spin.setValue(UDP_PORT)
        self.udp_port_spin.setFixedWidth(84)
        self.udp_button = self._styled(QtWidgets.QPushButton("启动 UDP"), kind="primary")
        port_row = QtWidgets.QHBoxLayout()
        port_row.addWidget(self.port_combo, 1)
        port_row.addWidget(self.refresh_port_button)
        udp_row = QtWidgets.QHBoxLayout()
        udp_row.addWidget(self.udp_bind_edit, 1)
        udp_row.addWidget(self.udp_port_spin)
        form.addRow("串口", port_row)
        form.addRow("波特率", self.baud_combo)
        form.addRow(self.uart_button)
        form.addRow("UDP", udp_row)
        form.addRow(self.udp_button)
        return group

    def _records_page(self) -> QtWidgets.QWidget:
        page = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)
        records = QtWidgets.QGroupBox("SQLite 记录与回放")
        record_layout = QtWidgets.QVBoxLayout(records)
        self.records_table = QtWidgets.QTableWidget(0, 7)
        self.records_table.setHorizontalHeaderLabels(
            ["ID", "时间", "帧号", "类型", "点数", "字节", "备注"]
        )
        self.records_table.setEditTriggers(QtWidgets.QAbstractItemView.NoEditTriggers)
        self.records_table.setSelectionBehavior(QtWidgets.QAbstractItemView.SelectRows)
        self.records_table.setSelectionMode(QtWidgets.QAbstractItemView.SingleSelection)
        self.records_table.cellDoubleClicked.connect(lambda _r, _c: self._replay_selected())
        header = self.records_table.horizontalHeader()
        header.setSectionResizeMode(QtWidgets.QHeaderView.ResizeToContents)
        header.setSectionResizeMode(1, QtWidgets.QHeaderView.Interactive)
        header.setSectionResizeMode(6, QtWidgets.QHeaderView.Stretch)
        self.records_table.verticalHeader().setDefaultSectionSize(28)
        record_layout.addWidget(self.records_table)
        record_buttons = QtWidgets.QHBoxLayout()
        self.refresh_records_button = QtWidgets.QPushButton("刷新")
        self.replay_button = QtWidgets.QPushButton("回放")
        self.delete_record_button = QtWidgets.QPushButton("删除")
        for btn in (self.refresh_records_button, self.replay_button, self.delete_record_button):
            btn.setCursor(QtCore.Qt.PointingHandCursor)
        record_buttons.addStretch(1)
        record_buttons.addWidget(self.refresh_records_button)
        record_buttons.addWidget(self.replay_button)
        record_buttons.addWidget(self.delete_record_button)
        record_layout.addLayout(record_buttons)
        layout.addWidget(records, 1)
        return page

    def _generator_group(self) -> QtWidgets.QGroupBox:
        group = QtWidgets.QGroupBox("DAC 波形控制")
        layout = QtWidgets.QVBoxLayout(group)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)
        self.wave_boxes, self.frequency_spins, self.amplitude_spins = [], [], []
        self.dac_mode_boxes, self.dac_measured_spins = [], []
        self.dac_calibration_labels = []
        for channel in range(2):
            channel_group = QtWidgets.QGroupBox(f"●  CH{channel + 1}")
            channel_group.setObjectName(f"ch{channel + 1}Card")
            form = self._form(channel_group)
            wave = QtWidgets.QComboBox()
            wave.addItems(["正弦", "三角", "方波"])
            frequency = QtWidgets.QDoubleSpinBox()
            frequency.setRange(0, 50_000)
            frequency.setDecimals(3)
            frequency.setValue(1000 * (channel + 1))
            frequency.setSuffix(" Hz")
            mode = QtWidgets.QComboBox()
            mode.addItems(["低压档（最小增益）", "高压档（最大增益）"])
            amplitude = QtWidgets.QDoubleSpinBox()
            amplitude.setRange(0, 5)
            amplitude.setDecimals(3)
            amplitude.setSingleStep(0.1)
            amplitude.setValue(0.1)
            amplitude.setSuffix(" Vpp")
            amplitude.setSpecialValueText("关闭")
            self.wave_boxes.append(wave)
            self.frequency_spins.append(frequency)
            self.dac_mode_boxes.append(mode)
            self.amplitude_spins.append(amplitude)
            form.addRow("波形", self._segmented(wave))
            form.addRow("频率", frequency)
            form.addRow("幅度", amplitude)
            form.addRow("增益档", self._segmented(mode, ["低", "高"]))
            layout.addWidget(channel_group)
        self.apply_generator_button = self._styled(
            QtWidgets.QPushButton("输出两通道波形"), kind="primary")
        self.apply_generator_button.setMinimumHeight(38)
        layout.addWidget(self.apply_generator_button)
        layout.addWidget(self._hint(
            "切档请旋到已标定端点：CH1 高档顺时针，CH2 高档逆时针；低档相反。"
            "档位标定在左上角「设置」中完成。"))
        return group

    def _acquisition_group(self) -> QtWidgets.QWidget:
        container = QtWidgets.QWidget()
        outer = QtWidgets.QVBoxLayout(container)
        outer.setContentsMargins(0, 0, 0, 0)
        outer.setSpacing(12)
        self.acquisition_mode_combo = QtWidgets.QComboBox()
        self.acquisition_mode_combo.addItem("连续", AcquisitionMode.CONTINUOUS)
        self.acquisition_mode_combo.addItem("手动", AcquisitionMode.MANUAL)
        self.acquisition_mode_segment = self._segmented(self.acquisition_mode_combo)
        self.acquisition_mode_segment.setFixedSize(150, 38)
        self.sampling_mode_combo = QtWidgets.QComboBox()
        self.sampling_mode_combo.addItems(["双通道 65 MSps", "INA 交织 130 MSps"])
        self.sampling_mode_combo.setEnabled(False)
        self.sampling_hint = self._hint("双通道：跳帽 B–C")
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
        self.smoothing_frequency_spins: dict[int, QtWidgets.QDoubleSpinBox] = {}
        for channel in (1, 2):
            spin = QtWidgets.QDoubleSpinBox()
            spin.setRange(1.0, 65_000.0)
            spin.setDecimals(1)
            spin.setSingleStep(50.0)
            spin.setSuffix(" kHz")
            spin.setKeyboardTracking(False)
            spin.setToolTip("本通道信号达到该频率时启用显示平滑；修改立即生效并自动保存。")
            spin.setValue(self.settings.value(
                f"display/ch{channel}_smoothing_start_hz",
                DEFAULT_SMOOTHING_START_HZ[channel], type=float,
            ) / 1000.0)
            self.smoothing_frequency_spins[channel] = spin
        self.trigger_source = QtWidgets.QComboBox(); self.trigger_source.addItems(["CH A", "CH B"])
        self.trigger_edge = QtWidgets.QComboBox(); self.trigger_edge.addItems(["上升沿", "下降沿"])
        self.threshold_spin = QtWidgets.QSpinBox(); self.threshold_spin.setRange(0, 4095); self.threshold_spin.setValue(2048)
        self.hysteresis_spin = QtWidgets.QSpinBox(); self.hysteresis_spin.setRange(0, 4095); self.hysteresis_spin.setValue(16)
        self.depth_spin = QtWidgets.QSpinBox(); self.depth_spin.setRange(1, 58_720_256); self.depth_spin.setValue(20_000)
        self.pretrigger_spin = QtWidgets.QDoubleSpinBox(); self.pretrigger_spin.setRange(0, 100); self.pretrigger_spin.setValue(50); self.pretrigger_spin.setSuffix(" %")
        # 连续走 ENVELOPE；手动走 RAW 立即采集。DECIMATED 不再暴露。
        self.mode_combo = QtWidgets.QComboBox(); self.mode_combo.addItems(["RAW", "ENVELOPE"])
        self.mode_combo.setCurrentIndex(1)
        self.decimation_combo = QtWidgets.QComboBox(); self.decimation_combo.addItems([str(1 << i) for i in range(11)])
        self.display_points_spin = QtWidgets.QSpinBox(); self.display_points_spin.setRange(1, MAX_ENVELOPE_POINTS); self.display_points_spin.setValue(MAX_ENVELOPE_POINTS)
        self.refresh_spin = QtWidgets.QDoubleSpinBox(); self.refresh_spin.setRange(0.001, 4_000_000); self.refresh_spin.setDecimals(3); self.refresh_spin.setValue(20); self.refresh_spin.setSuffix(" Hz")
        self.timebase_combo = QtWidgets.QComboBox()
        for value, label in TIME_PER_DIV:
            self.timebase_combo.addItem(label, value)
        # 1 µs/div × 10 格 = 10 µs，65Msps 下 650 点 1:1，4MHz 每格约 4 个周期。
        self.timebase_combo.setCurrentText("1 µs/div")
        self.duration_spin = QtWidgets.QSpinBox()
        self.duration_spin.setRange(1, MANUAL_MAX_MS)
        self.duration_spin.setValue(10)
        self.duration_spin.setSuffix(" ms")
        self.depth_spin.setVisible(False)
        self.pretrigger_spin.setVisible(False)
        self.display_points_spin.setVisible(False)
        self.refresh_spin.setVisible(False)
        # 运行按钮放在顶部工具条（_build_header），这里只创建。运行/停止
        # 合并为一个切换按钮；stop_button 保留为同一对象的别名。
        self.run_button = QtWidgets.QPushButton()
        self.run_button.setMinimumWidth(104)
        self.stop_button = self.run_button
        self.capture_button = self._styled(QtWidgets.QPushButton("单次采集"), kind="run")
        self.capture_button.setIcon(icon("capture", ICON_ON_ACCENT))
        for button in (self.run_button, self.capture_button):
            button.setCursor(QtCore.Qt.PointingHandCursor)
            button.setIconSize(QtCore.QSize(14, 14))
        self._update_run_button()
        self.capture_progress = self._styled(QtWidgets.QLabel(""), role="caption")

        acquisition = QtWidgets.QGroupBox("采集")
        form = self._form(acquisition)
        form.addRow("采样", self._segmented(self.sampling_mode_combo, ["65 MSps ×2", "130 MSps 交织"]))
        form.addRow(self.sampling_hint)
        form.addRow("通道", self._segmented(self.channel_mode_combo))
        form.addRow("时基", self.timebase_combo)
        self.duration_row_label = QtWidgets.QLabel("时长")
        form.addRow(self.duration_row_label, self.duration_spin)
        outer.addWidget(acquisition)

        for channel, vdiv, position in (
            (1, self.ch1_vdiv_combo, self.ch1_position_spin),
            (2, self.ch2_vdiv_combo, self.ch2_position_spin),
        ):
            vertical = QtWidgets.QGroupBox(f"●  CH{channel}")
            vertical.setObjectName(f"ch{channel}Card")
            vertical_form = self._form(vertical)
            vertical_form.addRow("刻度", vdiv)
            vertical_form.addRow("位置", position)
            outer.addWidget(vertical)

        trigger = QtWidgets.QGroupBox("触发")
        trigger_form = self._form(trigger)
        self._trigger_form_rows = []
        for label, widget in (
            ("信源", self._segmented(self.trigger_source, ["CH1", "CH2"])),
            ("边沿", self._segmented(self.trigger_edge, ["↑ 上升", "↓ 下降"])),
            ("阈值码", self.threshold_spin), ("迟滞码", self.hysteresis_spin),
        ):
            trigger_form.addRow(label, widget)
            self._trigger_form_rows.append((trigger_form.labelForField(widget), widget))
        self.apply_acquisition_button = QtWidgets.QPushButton("应用采集参数")
        trigger_form.addRow(self.apply_acquisition_button)
        outer.addWidget(trigger)
        return container

    def _build_settings_dialog(self) -> QtWidgets.QDialog:
        """设置窗口：DAC/ADC 校准与显示平滑。非模态，校准时仍可观察波形。"""
        dialog = QtWidgets.QDialog(self)
        dialog.setWindowTitle("设置")
        dialog.setModal(False)
        dialog.resize(480, 620)
        tabs = QtWidgets.QTabWidget()
        tabs.setDocumentMode(True)
        for title, build in (
            ("DAC 校准", self._dac_calibration_page),
            ("ADC 校准", self._adc_calibration_group),
            ("显示", self._display_settings_group),
        ):
            page = QtWidgets.QWidget()
            layout = QtWidgets.QVBoxLayout(page)
            layout.setContentsMargins(16, 8, 16, 16)
            layout.setSpacing(12)
            layout.addWidget(build())
            layout.addStretch(1)
            tabs.addTab(self._scrolled(page), title)
        layout = QtWidgets.QVBoxLayout(dialog)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.addWidget(tabs)
        self.settings_tabs = tabs
        self._update_channel_controls()
        return dialog

    def _show_settings(self) -> None:
        self.settings_dialog.show()
        self.settings_dialog.raise_()
        self.settings_dialog.activateWindow()

    def _dac_calibration_page(self) -> QtWidgets.QWidget:
        page = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(page)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(12)
        steps = QtWidgets.QGroupBox("DAC 档位标定")
        steps_layout = QtWidgets.QVBoxLayout(steps)
        steps_layout.setContentsMargins(0, 0, 0, 0)
        steps_layout.setSpacing(10)
        steps_layout.addWidget(self._hint(
            "① 选择各通道增益档，并把增益旋钮旋到对应端点\n"
            "② 发送 1 kHz / 25% 标定波形\n"
            "③ 用高阻示波器测量峰峰值，填入后保存"))
        self.dac_test_button = self._styled(
            QtWidgets.QPushButton("发送 1 kHz / 25% 标定波形（双通道）"), kind="primary")
        steps_layout.addWidget(self.dac_test_button)
        layout.addWidget(steps)
        self.dac_measured_spins = []
        self.dac_calibration_labels = []
        for channel in (1, 2):
            card = QtWidgets.QGroupBox(f"●  CH{channel}")
            card.setObjectName(f"ch{channel}Card")
            form = self._form(card)
            measured = QtWidgets.QDoubleSpinBox()
            measured.setRange(0, 10)
            measured.setDecimals(3)
            measured.setSuffix(" Vpp")
            calibrate = QtWidgets.QPushButton("保存标定")
            calibrate.setIcon(icon("save"))
            calibrate.setIconSize(QtCore.QSize(15, 15))
            calibrate.clicked.connect(
                lambda _checked=False, ch=channel: self._calibrate_dac_amplitude(ch)
            )
            calibration_label = self._hint("")
            self.dac_measured_spins.append(measured)
            self.dac_calibration_labels.append(calibration_label)
            # 与信号源页共用同一个增益档模型，两处切换始终同步。
            form.addRow("增益档", self._segmented(self.dac_mode_boxes[channel - 1], ["低", "高"]))
            row = QtWidgets.QHBoxLayout()
            row.addWidget(measured, 1)
            row.addWidget(calibrate)
            form.addRow("实测", row)
            form.addRow(calibration_label)
            self._update_dac_calibration_label(channel)
            layout.addWidget(card)
        return page

    def _adc_calibration_group(self) -> QtWidgets.QGroupBox:
        group = QtWidgets.QGroupBox("ADC 幅度校准")
        layout = QtWidgets.QVBoxLayout(group)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(10)
        self.cal_vpp_spins: dict[int, QtWidgets.QDoubleSpinBox] = {}
        self.calibrate_buttons: dict[int, QtWidgets.QPushButton] = {}
        self.reset_cal_buttons: dict[int, QtWidgets.QPushButton] = {}
        layout.addWidget(self._hint("输入已知信号的峰峰值，运行采集后点击校准。"))
        layout.addLayout(self._make_cal_row(1))
        layout.addLayout(self._make_cal_row(2))
        return group

    def _display_settings_group(self) -> QtWidgets.QGroupBox:
        group = QtWidgets.QGroupBox("波形显示平滑")
        form = self._form(group)
        form.addRow(self._hint("信号频率达到起始频率时启用显示平滑，仅影响显示，修改立即生效并自动保存。"))
        for channel in (1, 2):
            label = QtWidgets.QLabel(f"CH{channel} 起始频率")
            label.setStyleSheet(f"color: {CH1_COLOR if channel == 1 else CH2_COLOR};")
            form.addRow(label, self.smoothing_frequency_spins[channel])
        return group

    def _build_status_bar(self) -> None:
        """设备状态以指示灯形式常驻状态栏右侧。"""
        self.statusBar().setSizeGripEnabled(False)
        self.status_labels: dict[str, QtWidgets.QLabel] = {}
        self._status_dots: dict[str, QtWidgets.QLabel] = {}
        names = [
            ("uart", "UART"), ("phy", "PHY"), ("mig", "DDR"),
            ("capture", "采集"), ("adc", "ADC"), ("mmcm", "MMCM"),
            ("loss", "UDP错/丢"), ("otr", "OTR"),
        ]
        for key, text in names:
            pill = QtWidgets.QWidget()
            row = QtWidgets.QHBoxLayout(pill)
            row.setContentsMargins(8, 0, 8, 0)
            row.setSpacing(5)
            dot = self._styled(QtWidgets.QLabel("●"), role="led")
            row.addWidget(dot)
            row.addWidget(self._styled(QtWidgets.QLabel(text), role="caption"))
            label = self._styled(QtWidgets.QLabel("未知"), role="led")
            self.status_labels[key] = label
            self._status_dots[key] = dot
            row.addWidget(label)
            self.statusBar().addPermanentWidget(pill)

    def _set_status(self, key: str, text: str) -> None:
        label = self.status_labels[key]
        label.setText(text)
        state = "ok" if text in STATUS_OK else "bad" if text in STATUS_BAD else None
        set_led(label, state)
        set_led(self._status_dots[key], state)

    def _build_display_panel(self) -> QtWidgets.QWidget:
        panel = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(panel)
        layout.setContentsMargins(16, 14, 16, 12)
        layout.setSpacing(10)
        # 单行顶栏：显示模式 + 状态徽章 + 备注与保存（方案 B）
        self.analysis_combo = QtWidgets.QComboBox(); self.analysis_combo.addItems(["时域", "FFT"])
        info = QtWidgets.QHBoxLayout()
        info.setSpacing(8)
        info.addWidget(QtWidgets.QLabel("显示"))
        info.addWidget(self.analysis_combo)
        info.addSpacing(4)
        self.ch1_badge = self._styled(QtWidgets.QLabel(), role="chip")
        self.ch2_badge = self._styled(QtWidgets.QLabel(), role="chip")
        self.timebase_badge = self._styled(QtWidgets.QLabel(), role="chip")
        self.trigger_badge = self._styled(QtWidgets.QLabel(), role="chip")
        self.ch1_badge.setStyleSheet(f"color: {CH1_COLOR};")
        self.ch2_badge.setStyleSheet(f"color: {CH2_COLOR};")
        self.trigger_badge.setStyleSheet("color: #ff9f5a;")
        info.addWidget(self.ch1_badge)
        info.addWidget(self.ch2_badge)
        info.addSpacing(4)
        info.addWidget(self.timebase_badge)
        info.addWidget(self.trigger_badge)
        info.addStretch(1)
        self.note_edit = QtWidgets.QLineEdit()
        self.note_edit.setPlaceholderText("记录备注")
        self.note_edit.setFixedWidth(150)
        self.save_button = QtWidgets.QPushButton("保存当前帧")
        self.save_button.setCursor(QtCore.Qt.PointingHandCursor)
        info.addWidget(self.note_edit)
        info.addWidget(self.save_button)
        layout.addLayout(info)
        self.plot_widget = PlotWidget()
        self.plot_widget.set_timebase(float(self.timebase_combo.currentData()))
        self.plot_widget.set_volts_per_div(1, float(self.ch1_vdiv_combo.currentData()))
        self.plot_widget.set_volts_per_div(2, float(self.ch2_vdiv_combo.currentData()))
        for channel, spin in self.smoothing_frequency_spins.items():
            self.plot_widget.set_smoothing_start_frequency(channel, spin.value() * 1000.0)
        self._apply_adc_calibration()
        screen = QtWidgets.QFrame()
        screen.setObjectName("scopeScreen")
        screen.setStyleSheet(
            f"#scopeScreen {{ border: 1px solid #232b38; border-radius: 14px; background: {PLOT_BACKGROUND}; }}")
        screen_layout = QtWidgets.QVBoxLayout(screen)
        screen_layout.setContentsMargins(10, 10, 10, 10)
        screen_layout.addWidget(self.plot_widget)
        layout.addWidget(screen, 1)
        # 测量卡片：每通道一张，四项读数用大号等宽字体。
        self.measurement_labels = []
        for _ in range(8):
            value = self._styled(QtWidgets.QLabel("—"), role="value")
            value.setWordWrap(True)
            self.measurement_labels.append(value)
        cards = QtWidgets.QHBoxLayout()
        cards.setSpacing(12)
        for channel in (1, 2):
            card = QtWidgets.QGroupBox(f"●  CH{channel}  测量")
            card.setObjectName(f"ch{channel}Card")
            grid = QtWidgets.QGridLayout(card)
            grid.setContentsMargins(0, 0, 0, 0)
            grid.setHorizontalSpacing(12)
            grid.setVerticalSpacing(4)
            for i, title in enumerate(("最小值", "最大值", "峰峰值", "频率")):
                row, column = divmod(i, 2)
                grid.addWidget(self._styled(QtWidgets.QLabel(title), role="caption"), row * 2, column)
                grid.addWidget(self.measurement_labels[(channel - 1) * 4 + i], row * 2 + 1, column)
                grid.setColumnStretch(column, 1)
            cards.addWidget(card)
        layout.addLayout(cards)
        self._update_channel_controls()
        return panel

    def _update_scope_badges(self) -> None:
        if not hasattr(self, "trigger_badge"):
            return
        is_fft = hasattr(self, "analysis_combo") and self.analysis_combo.currentText() == "FFT"
        mode = ChannelDisplayMode(self.channel_mode_combo.currentData())
        if is_fft:
            freq_div = self.plot_widget.fft_freq_per_div
            volts_div = self.plot_widget.fft_volts_per_div
            span = self.plot_widget.fft_span_hz
            for channel, badge in ((1, self.ch1_badge), (2, self.ch2_badge)):
                active = mode == ChannelDisplayMode.BOTH or int(mode) == channel
                v_text = format_voltage(volts_div) if volts_div > 0 else "—"
                badge.setText(f"CH{channel} {v_text}/div" if active else f"CH{channel}  OFF")
                badge.setEnabled(active)
            self.timebase_badge.setText(f"{format_frequency_hz(freq_div)}/div" if freq_div > 0 else "FFT")
            self.trigger_badge.setText(f"SPAN {format_frequency_hz(span)}" if span > 0 else "FFT 频域")
            return

        for channel, badge, combo, position in (
            (1, self.ch1_badge, self.ch1_vdiv_combo, self.ch1_position_spin),
            (2, self.ch2_badge, self.ch2_vdiv_combo, self.ch2_position_spin),
        ):
            active = mode == ChannelDisplayMode.BOTH or int(mode) == channel
            badge.setText(f"CH{channel} {combo.currentText().replace(' ', '')} {position.value():+.2f}"
                          if active else f"CH{channel}  OFF")
            badge.setEnabled(active)
        self.timebase_badge.setText(self.timebase_combo.currentText().replace(" ", ""))
        edge = "↑" if self.trigger_edge.currentIndex() == 0 else "↓"
        self.trigger_badge.setText(
            f"CH{self.trigger_source.currentIndex() + 1} {edge} {self.threshold_spin.value()}")

    def _make_cal_row(self, channel: int) -> QtWidgets.QHBoxLayout:
        spin = QtWidgets.QDoubleSpinBox()
        spin.setRange(0.1, 10.0)
        spin.setDecimals(3)
        spin.setSingleStep(0.1)
        spin.setValue(2.0)
        spin.setSuffix(" Vpp")
        calibrate = QtWidgets.QPushButton(f"校准 CH{channel}")
        reset = self._styled(QtWidgets.QPushButton("复位"), kind="ghost")
        self.cal_vpp_spins[channel] = spin
        self.calibrate_buttons[channel] = calibrate
        self.reset_cal_buttons[channel] = reset
        row = QtWidgets.QHBoxLayout()
        caption = QtWidgets.QLabel(f"CH{channel}")
        caption.setStyleSheet(
            f"color: {CH1_COLOR if channel == 1 else CH2_COLOR}; font-weight: 700;")
        caption.setFixedWidth(36)
        row.addWidget(caption)
        row.addWidget(spin, 1)
        row.addWidget(calibrate)
        row.addWidget(reset)
        return row

    def _connect_signals(self) -> None:
        self.refresh_port_button.clicked.connect(self._refresh_ports)
        self.uart_button.clicked.connect(self._toggle_uart)
        self.udp_button.clicked.connect(self._toggle_udp)
        self.apply_generator_button.clicked.connect(self._apply_generator)
        self.dac_test_button.clicked.connect(self._send_dac_calibration_test)
        for channel in (1, 2):
            self.dac_mode_boxes[channel - 1].currentIndexChanged.connect(
                lambda _index, ch=channel: self._on_dac_mode_changed(ch)
            )
        self.apply_acquisition_button.clicked.connect(self._apply_acquisition)
        self.run_button.clicked.connect(self._toggle_run)
        self.capture_button.clicked.connect(self._start_manual_capture)
        self.acquisition_mode_combo.currentIndexChanged.connect(self._on_acquisition_mode_changed)
        self.timebase_combo.currentTextChanged.connect(self._set_timebase)
        self.sampling_mode_combo.currentIndexChanged.connect(self._change_sampling_mode)
        self.channel_mode_combo.currentIndexChanged.connect(self._set_channel_mode)
        self.ch1_vdiv_combo.currentIndexChanged.connect(lambda: self._set_vdiv(1))
        self.ch2_vdiv_combo.currentIndexChanged.connect(lambda: self._set_vdiv(2))
        self.ch1_position_spin.valueChanged.connect(lambda value: self.plot_widget.set_vertical_position_div(1, value))
        self.ch2_position_spin.valueChanged.connect(lambda value: self.plot_widget.set_vertical_position_div(2, value))
        for signal in (
            self.ch1_vdiv_combo.currentIndexChanged, self.ch2_vdiv_combo.currentIndexChanged,
            self.ch1_position_spin.valueChanged, self.ch2_position_spin.valueChanged,
            self.timebase_combo.currentIndexChanged, self.trigger_source.currentIndexChanged,
            self.trigger_edge.currentIndexChanged, self.threshold_spin.valueChanged,
            self.analysis_combo.currentIndexChanged,
        ):
            signal.connect(self._update_scope_badges)
        self._update_scope_badges()
        self.analysis_combo.currentIndexChanged.connect(self._set_analysis)
        self.save_button.clicked.connect(self._save_current)
        self.refresh_records_button.clicked.connect(self._refresh_records)
        self.replay_button.clicked.connect(self._replay_selected)
        self.delete_record_button.clicked.connect(self._delete_selected)
        for channel in (1, 2):
            self.smoothing_frequency_spins[channel].valueChanged.connect(
                lambda value, ch=channel: self._set_smoothing_frequency(ch, value)
            )
            self.calibrate_buttons[channel].clicked.connect(
                lambda _checked=False, ch=channel: self._calibrate_amplitude(ch)
            )
            self.reset_cal_buttons[channel].clicked.connect(
                lambda _checked=False, ch=channel: self._reset_adc_calibration(ch)
            )
        self.serial_link.connection_changed.connect(self._on_uart_connection)
        self.serial_link.response_received.connect(self._on_response)
        self.serial_link.request_failed.connect(self._on_request_failed)
        self.udp_receiver.running_changed.connect(self._on_udp_running)
        self.udp_receiver.frame_received.connect(self._on_frame)
        self.udp_receiver.packet_error.connect(lambda error: self.statusBar().showMessage(error, 3000))
        self.udp_receiver.retransmit_required.connect(self._request_retransmit)
        self.udp_receiver.stats_updated.connect(self._on_udp_stats)
        self.udp_receiver.raw_progress.connect(self._on_raw_progress)

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

    def _dac_calibration_key(self, channel: int, mode: int) -> str:
        return f"dac_cal/ch{channel}/{DAC_GAIN_MODES[mode]}_full_scale_vpp"

    def _load_dac_calibration(self) -> None:
        for channel in (1, 2):
            for mode in range(len(DAC_GAIN_MODES)):
                key = self._dac_calibration_key(channel, mode)
                if self.settings.contains(key):
                    self._dac_full_scale_vpp[(channel, mode)] = self.settings.value(key, type=float)

    def _update_dac_calibration_label(self, channel: int) -> None:
        mode = self.dac_mode_boxes[channel - 1].currentIndex()
        full_scale = self._dac_full_scale_vpp.get((channel, mode))
        self.dac_calibration_labels[channel - 1].setText(
            f"满码等效 {full_scale:.3f} Vpp" if full_scale is not None else "该档未标定"
        )

    def _on_dac_mode_changed(self, channel: int) -> None:
        self._dac_test_modes = None
        self._update_dac_calibration_label(channel)
        self.statusBar().showMessage("请手动将对应通道的增益旋钮调到所选档位端点", 6000)

    def _send_dac_calibration_test(self) -> None:
        self._dac_test_modes = None
        for channel in (1, 2):
            payload = generator_payload(
                channel, Waveform.SINE, 1000.0, 5.0 * TEST_FRACTION,
                commit=(channel == 2),
            )
            self.serial_link.send_command(Command.SET_GENERATOR, payload)
        self._dac_test_modes = tuple(box.currentIndex() for box in self.dac_mode_boxes)
        self.statusBar().showMessage("已发送双通道 25% 测试波形；高阻示波器测量后分别保存标定", 8000)

    def _calibrate_dac_amplitude(self, channel: int) -> None:
        mode = self.dac_mode_boxes[channel - 1].currentIndex()
        if self._dac_test_modes is None or self._dac_test_modes[channel - 1] != mode:
            self.statusBar().showMessage("请先发送当前档位的标定测试波形", 5000)
            return
        try:
            full_scale = full_scale_vpp_from_test(self.dac_measured_spins[channel - 1].value())
        except ValueError as exc:
            self.statusBar().showMessage(str(exc), 5000)
            return
        self._dac_full_scale_vpp[(channel, mode)] = full_scale
        self.settings.setValue(self._dac_calibration_key(channel, mode), full_scale)
        self._update_dac_calibration_label(channel)
        self.statusBar().showMessage(f"CH{channel} {DAC_GAIN_MODES[mode]} 档已标定", 5000)

    def _apply_generator(self) -> None:
        amplitudes = []
        for channel in (1, 2):
            mode = self.dac_mode_boxes[channel - 1].currentIndex()
            target_vpp = self.amplitude_spins[channel - 1].value()
            try:
                if 0 < target_vpp < 0.1:
                    raise ValueError("目标峰峰值须为 0 或至少 0.1 Vpp")
                nominal_vpk = nominal_vpk_for_target(
                    target_vpp, self._dac_full_scale_vpp.get((channel, mode), 0.0),
                )
            except ValueError as exc:
                self.statusBar().showMessage(f"CH{channel} {exc}", 6000)
                return
            amplitudes.append(nominal_vpk)
        self._dac_test_modes = None
        for channel in (1, 2):
            payload = generator_payload(
                channel, Waveform(self.wave_boxes[channel - 1].currentIndex()),
                self.frequency_spins[channel - 1].value(),
                amplitudes[channel - 1], commit=(channel == 2),
            )
            self.serial_link.send_command(Command.SET_GENERATOR, payload)

    @property
    def sample_rate_hz(self) -> int:
        return INTERLEAVE_SAMPLE_RATE_HZ if self._sampling_mode else ADC_SAMPLE_RATE_HZ

    def _change_sampling_mode(self, mode: int) -> None:
        if self._mode_switching or mode == self._sampling_mode:
            return
        if not self._uart_connected or not self._interleave_supported or self._manual_busy:
            self.sampling_mode_combo.blockSignals(True)
            self.sampling_mode_combo.setCurrentIndex(self._sampling_mode)
            self.sampling_mode_combo.blockSignals(False)
            self.statusBar().showMessage("请先连接支持交织的固件，并等待当前采集上传结束", 5000)
            return
        mask = 1 if mode else 3
        rate = INTERLEAVE_SAMPLE_RATE_HZ if mode else ADC_SAMPLE_RATE_HZ
        depth = max(1, min(RAW_MAX_SAMPLES, int(ceil(rate * float(self.timebase_combo.currentData()) * 10))))
        payload = acquisition_payload(
            0, self.threshold_spin.value(), self.hysteresis_spin.value(),
            self.trigger_edge.currentIndex(), depth, self.pretrigger_spin.value(),
            channel_mask=mask, sampling_mode=mode, commit=True)
        self._mode_switching = True
        self._pending_trigger_alignment = None
        self.plot_widget.set_trigger_alignment(None)
        self._mode_deadline = monotonic() + 30.0
        self._mode_target = mode
        self._continuous_running = False
        self.sampling_mode_combo.setEnabled(False)
        self.run_button.setEnabled(False)
        self.capture_button.setEnabled(False)
        self.udp_receiver.discard_pending()
        self._clear_continuous_measurement()
        self._mode_steps = [(Command.STOP, b""), (Command.ENVELOPE_ENABLE, b"\x00"), (Command.SET_ACQUISITION, payload)]
        self._send_mode_step()

    def _send_mode_step(self) -> None:
        if not self._mode_switching:
            return
        if self._mode_steps:
            command, payload = self._mode_steps.pop(0)
            self._mode_command = (command, payload)
            self._mode_token = self.serial_link.send_command(command, payload)
            return
        self._mode_retry.stop()
        self._sampling_mode = self._mode_target
        self._mode_switching = False
        self._mode_token = None
        self._sync_sampling_widgets()
        self.udp_receiver.discard_pending()
        self.current_frame = None
        self.plot_widget.clear_frame()
        self.sampling_hint.setText(
            "已停止。请将跳帽切到 A–B，信号接 INA，然后点击运行。" if self._sampling_mode else
            "已停止。请将跳帽切到 B–C，信号接 INA/INB，然后点击运行。")
        self.statusBar().showMessage("模式已切换，完成跳帽调整后手动运行", 8000)

    def _sync_sampling_widgets(self) -> None:
        self.sampling_hint.setText("交织：跳帽 A–B，信号接 INA。" if self._sampling_mode else
                                  "双通道：跳帽 B–C，信号接 INA/INB。")
        self.sampling_mode_combo.blockSignals(True)
        self.sampling_mode_combo.setCurrentIndex(self._sampling_mode)
        self.sampling_mode_combo.blockSignals(False)
        self.sampling_mode_combo.setEnabled(self._uart_connected and self._interleave_supported and not self._mode_switching)
        self.channel_mode_combo.blockSignals(True)
        self.channel_mode_combo.setCurrentIndex(1 if self._sampling_mode else 0)
        self.channel_mode_combo.blockSignals(False)
        self.channel_mode_combo.setEnabled(not self._sampling_mode and not self._mode_switching)
        self.plot_widget.set_channel_mode(self.channel_mode_combo.currentData())
        self._update_channel_controls()
        self._clear_measurement_labels()
        # DDR 容量固定；130 MSps 的最长记录约为 451.7 ms。
        self.duration_spin.setMaximum(min(MANUAL_MAX_MS, RAW_MAX_SAMPLES * 1000 // self.sample_rate_hz))
        self._sync_timebase_options()
        self.run_button.setEnabled(not self._mode_switching)
        self.capture_button.setEnabled(not self._mode_switching)

    def _sync_timebase_options(self) -> None:
        """连续采集受 DDR 深度限制；手动回放允许完整显示长记录。"""
        manual = self._acquisition_mode == AcquisitionMode.MANUAL
        blocked = self.timebase_combo.blockSignals(True)
        last_enabled = 0
        for index in range(self.timebase_combo.count()):
            allowed = manual or self.timebase_combo.itemData(index) * 10 * self.sample_rate_hz <= RAW_MAX_SAMPLES
            self.timebase_combo.model().item(index).setEnabled(allowed)
            if allowed:
                last_enabled = index
        if self.timebase_combo.currentIndex() > last_enabled:
            self.timebase_combo.setCurrentIndex(last_enabled)
        self.timebase_combo.blockSignals(blocked)
        self.plot_widget.set_timebase(float(self.timebase_combo.currentData()))
        self._update_scope_badges()

    def _fail_mode_switch(self, message: str) -> None:
        self._mode_retry.stop()
        self._mode_switching = False
        self._mode_steps.clear()
        self._mode_token = None
        self._sync_sampling_widgets()
        self.sampling_hint.setText("切换失败，保持停止：" + message)
        self._query_status()

    def _on_request_failed(self, token: int, error: str) -> None:
        if (self._pending_trigger_alignment is not None and
                token in self._pending_trigger_alignment[:2]):
            self._pending_trigger_alignment = None
        if self._mode_switching and token == self._mode_token:
            self._fail_mode_switch(error)
        self.statusBar().showMessage(error, 5000)

    def _channel_mask(self) -> int:
        if self._sampling_mode:
            return 1
        return {
            ChannelDisplayMode.CH1: 0x01,
            ChannelDisplayMode.CH2: 0x02,
            ChannelDisplayMode.BOTH: 0x03,
        }[ChannelDisplayMode(self.channel_mode_combo.currentData())]

    def _manual_capture_depth(self) -> int:
        duration_s = min(MANUAL_MAX_SECONDS, max(0.001, self.duration_spin.value() / 1000.0))
        return max(1, min(RAW_MAX_SAMPLES, int(round(self.sample_rate_hz * duration_s))))

    def _apply_acquisition(self) -> None:
        if self._mode_switching:
            return
        self.plot_widget.set_trigger_alignment(None)
        self._pending_trigger_alignment = None
        self._clear_continuous_measurement()
        was_continuous = self._continuous_running
        if self._uart_connected:
            self.serial_link.send_command(Command.STOP)
        channel_mask = self._channel_mask()
        time_per_div = float(self.timebase_combo.currentData())
        requested_depth = int(ceil(self.sample_rate_hz * time_per_div * 10.0))
        capture_depth = max(1, min(RAW_MAX_SAMPLES, requested_depth))
        acquisition_token = self.serial_link.send_command(Command.SET_ACQUISITION, acquisition_payload(
            self.trigger_source.currentIndex(), self.threshold_spin.value(),
            self.hysteresis_spin.value(), self.trigger_edge.currentIndex(),
            capture_depth, self.pretrigger_spin.value(),
            channel_mask=channel_mask, sampling_mode=(self._sampling_mode if self._interleave_supported else None), commit=False,
        ))
        self.depth_spin.setValue(capture_depth)
        self.display_points_spin.setValue(
            max(1, min(self.display_points_spin.value(), capture_depth))
        )
        display_points = self._envelope_display_points(
            capture_depth, channel_mask, self.refresh_spin.value(),
        )
        self.display_points_spin.setValue(display_points)
        self.mode_combo.setCurrentIndex(DataMode.ENVELOPE)
        token = self.serial_link.send_command(Command.SET_PROCESSING, processing_payload(
            DataMode.ENVELOPE, int(self.decimation_combo.currentText()),
            display_points, self.refresh_spin.value(), commit=True,
        ))
        # SET_PROCESSING 提交整组采集参数；成功应答后再启用新触发配置。
        self._pending_trigger_alignment = (acquisition_token, token, (
            self.trigger_source.currentIndex() + 1, self.threshold_spin.value(),
            self.hysteresis_spin.value(), bool(self.trigger_edge.currentIndex()),
        ))
        if was_continuous:
            self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x01")

    def _run_acquisition(self) -> None:
        if self._mode_switching:
            return
        self.acquisition_mode_combo.setCurrentIndex(AcquisitionMode.CONTINUOUS)
        self.mode_combo.setCurrentIndex(DataMode.ENVELOPE)
        self._apply_acquisition()
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x01")
        self._continuous_running = True
        self.statusBar().showMessage("连续运行", 2000)

    def _stop_acquisition(self) -> None:
        self._continuous_running = False
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x00")
        self.serial_link.send_command(Command.STOP)
        self.udp_receiver.discard_pending()
        self.statusBar().showMessage("已停止", 2000)

    def _on_acquisition_mode_changed(self, _: int) -> None:
        mode = AcquisitionMode(self.acquisition_mode_combo.currentData())
        if mode == self._acquisition_mode:
            self._update_acquisition_mode_widgets()
            return
        if self._manual_busy:
            self.acquisition_mode_combo.blockSignals(True)
            self.acquisition_mode_combo.setCurrentIndex(int(self._acquisition_mode))
            self.acquisition_mode_combo.blockSignals(False)
            return
        if self._acquisition_mode == AcquisitionMode.CONTINUOUS and self._continuous_running:
            self._stop_acquisition()
        if mode == AcquisitionMode.CONTINUOUS and self._uart_connected:
            self.serial_link.send_command(Command.STOP)
        self._acquisition_mode = mode
        self._clear_continuous_measurement()
        self._update_acquisition_mode_widgets()

    def _update_acquisition_mode_widgets(self) -> None:
        manual = self._acquisition_mode == AcquisitionMode.MANUAL
        self.run_button.setVisible(not manual)
        self.apply_acquisition_button.setVisible(not manual)
        self.capture_button.setVisible(manual)
        self.duration_spin.setVisible(manual)
        self.duration_row_label.setVisible(manual)
        self.capture_progress.setVisible(manual)
        for label, widget in self._trigger_form_rows:
            if label is not None:
                label.setVisible(not manual)
            widget.setVisible(not manual)
        self.acquisition_mode_combo.setEnabled(not self._manual_busy)
        self.channel_mode_combo.setEnabled(not self._manual_busy and not self._sampling_mode and not self._mode_switching)
        self.sampling_mode_combo.setEnabled(self._uart_connected and self._interleave_supported and not self._manual_busy and not self._mode_switching)
        self.capture_button.setEnabled(manual and not self._manual_busy)
        self.duration_spin.setEnabled(manual and not self._manual_busy)
        self._sync_timebase_options()

    def _start_manual_capture(self) -> None:
        if self._mode_switching:
            return
        if self._manual_busy:
            return
        self._continuous_running = False
        self._manual_busy = True
        self._manual_retried = False
        self._update_acquisition_mode_widgets()
        self.capture_progress.setText("采集中")
        self.plot_widget.clear_frame()
        self.udp_receiver.discard_pending()
        channel_mask = self._channel_mask()
        capture_depth = self._manual_capture_depth()
        self.depth_spin.setValue(capture_depth)
        self.mode_combo.setCurrentIndex(DataMode.RAW)
        self.serial_link.send_command(Command.STOP)
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x00")
        self.serial_link.send_command(Command.SET_ACQUISITION, acquisition_payload(
            self.trigger_source.currentIndex(), self.threshold_spin.value(),
            self.hysteresis_spin.value(), self.trigger_edge.currentIndex(),
            capture_depth, 0.0, channel_mask=channel_mask, sampling_mode=(self._sampling_mode if self._interleave_supported else None), commit=False,
        ))
        self.serial_link.send_command(Command.SET_PROCESSING, processing_payload(
            DataMode.RAW, 1, 1, self.refresh_spin.value(), commit=True,
        ))
        self.serial_link.send_command(Command.ARM)
        duration_s = capture_depth / float(self.sample_rate_hz)
        upload_s = capture_depth * (2 if channel_mask in (1, 2) else 4) / 8_000_000
        self._manual_timeout.start(int((duration_s + upload_s + 3.0) * 1000))
        self.statusBar().showMessage("手动采集中")

    def _finish_manual_capture(self, message: str) -> None:
        self._manual_timeout.stop()
        self._manual_busy = False
        self._update_acquisition_mode_widgets()
        self.capture_progress.setText(message)
        self.statusBar().showMessage(message, 4000)

    def _on_manual_timeout(self) -> None:
        if not self._manual_busy:
            return
        if self._uart_connected and not self._manual_retried:
            self._manual_retried = True
            self.serial_link.send_command(Command.REQUEST_RAW, raw_request_payload(0))
            self.capture_progress.setText("上传超时，正在重试")
            self._manual_timeout.start(5000)
            return
        self._finish_manual_capture("手动采集超时")

    def _on_raw_progress(self, received: int, total: int) -> None:
        if not self._manual_busy or total <= 0:
            return
        percent = min(100, int(received * 100 / total))
        self.capture_progress.setText(f"上传中 {percent}%")

    def _request_retransmit(self, frame_id: int, offset: int, length: int) -> None:
        if self._uart_connected:
            self.serial_link.send_command(Command.REQUEST_RETRANSMIT, retransmit_payload(frame_id, offset, length))

    def _query_status(self) -> None:
        if self._uart_connected:
            self.serial_link.send_command(Command.QUERY_STATUS)

    def _on_uart_connection(self, connected: bool, detail: str) -> None:
        self._uart_connected = connected
        self._interleave_supported = False
        self._status_received = False
        if not connected:
            self._pending_trigger_alignment = None
            self.plot_widget.set_trigger_alignment(None)
            self._mode_retry.stop()
            self._mode_switching = False
            self._mode_steps.clear()
            self._mode_token = None
            self._continuous_running = False
            self._sync_sampling_widgets()
        self.sampling_mode_combo.setEnabled(False)
        self._clear_continuous_measurement()
        if connected:
            self.settings.setValue("connection/serial_port", detail)
            # 先读取实际模式；用户确认跳帽位置后再手动运行。
            QtCore.QTimer.singleShot(100, self._query_status)
        self.uart_button.setText("断开 UART" if connected else "连接 UART")
        self._set_status("uart", "已连接" if connected else "断开")
        self.statusBar().showMessage(detail, 3000)

    def _sync_scope_configuration(self) -> None:
        if not self._uart_connected:
            return
        if self._acquisition_mode == AcquisitionMode.MANUAL:
            return
        self._apply_acquisition()
        self.serial_link.send_command(Command.ENVELOPE_ENABLE, b"\x01")
        self._continuous_running = True

    def _on_udp_running(self, running: bool, detail: str) -> None:
        self.udp_button.setText("停止 UDP" if running else "启动 UDP")
        self.statusBar().showMessage(detail, 3000)

    def _on_response(self, token: int, response: Response) -> None:
        if (self._pending_trigger_alignment is not None and
                token in self._pending_trigger_alignment[:2]):
            _, commit_token, settings = self._pending_trigger_alignment
            if not response.ok:
                self._pending_trigger_alignment = None
            elif token == commit_token:
                self._pending_trigger_alignment = None
                self.plot_widget.set_trigger_alignment(*settings)
        if self._mode_switching and token == self._mode_token:
            if response.ok:
                self._send_mode_step()
            elif response.command == Command.SET_ACQUISITION and response.status == StatusCode.BUSY and monotonic() < self._mode_deadline:
                # STOP 后旧 RAW 帧可能仍在上传；等待传输结束再提交模式。
                self._mode_steps.insert(0, self._mode_command)
                self._mode_retry.start(100)
                self.statusBar().showMessage("正在等待 RAW 上传完成，再提交配置")
            else:
                self._fail_mode_switch(response.status_name)
            return
        if not response.ok:
            self.statusBar().showMessage(f"命令 0x{response.command:02X}: {response.status_name}", 5000)
            return
        if response.command == Command.QUERY_STATUS:
            status = parse_device_status(response.payload)
            first_status = not self._status_received
            self._status_received = True
            self._interleave_supported = bool(status["interleave_supported"])
            if not self._mode_switching:
                actual_mode = int(status["sampling_mode"]) if self._interleave_supported else 0
                if actual_mode != self._sampling_mode or first_status:
                    self._sampling_mode = actual_mode
                    self._sync_sampling_widgets()
            self._set_status("phy", "已连接" if status["network_link_up"] else "断开")
            self._set_status("mig", "已校准" if status["ddr_calibrated"] else "未校准")
            self._set_status("capture", "ARM" if status["adc_armed"] else ("忙" if status["control_busy"] else "空闲"))
            if self._interleave_supported:
                self._set_status("adc", "溢出" if status["sample_overflow"] else
                                                  ("就绪" if status["sample_ready"] else "未就绪"))
            else:
                self._set_status("adc", "正常" if status["adc_clock_alive"] else "异常")
            self._set_status("mmcm", "锁定" if status["mmcm_locked"] else "未锁定")

    def _on_frame(self, frame: CompletedFrame, persist_measurement: bool = True) -> None:
        if persist_measurement and (self._mode_switching or bool(frame.header.flags & 0x0100) != bool(self._sampling_mode)):
            return
        is_raw = frame.header.sample_format in (SampleFormat.RAW32, SampleFormat.RAW16)
        if is_raw:
            self.latest_raw_frame_id = frame.header.frame_id
        if persist_measurement and (self._manual_busy or self._acquisition_mode == AcquisitionMode.MANUAL):
            if is_raw:
                self._accept_manual_raw(frame)
            return
        if frame.header.sample_format == SampleFormat.MEASUREMENT_V1:
            self._hardware_measurement = decode_measurement_v1(frame.payload)
            self._hardware_measurement_mask = frame.header.channel_mask
            self._refresh_continuous_measurement()
            if persist_measurement:
                self.store.save_measurement(frame.header.frame_id, self._last_measurement)
        else:
            # 时基切换期间残留的旧包络帧不能覆盖即时过渡显示；只有
            # 帧头时长匹配当前窗口的新帧才更新当前波形。回放帧不受此过滤。
            if (persist_measurement and
                    frame.header.sample_format in
                    (SampleFormat.ENVELOPE64, SampleFormat.ENVELOPE32) and
                    not self._envelope_matches_timebase(frame)):
                return
            # 测量包只更新读数，不能覆盖用户准备保存/回放的波形帧。
            self.current_frame = frame
            if persist_measurement:
                self.plot_widget.display_frame(frame)
            else:
                # 历史帧没有保存触发参数，不能套用当前设备的触发设置。
                self.plot_widget.display_frame(frame, align_trigger=False)
            if is_raw:
                self._clear_continuous_measurement()
                self._measure_raw_frame(frame)
            else:
                self._update_square_amplitude(frame)
            self._update_scope_badges()

    def _clear_continuous_measurement(self) -> None:
        self._hardware_measurement = None
        self._hardware_measurement_mask = 0
        self._square_amplitude = {}
        self._square_amplitude_mask = 0
        self._square_amplitude_time = 0.0
        self._displayed_measurement = None
        self._measurement_filter.reset()
        self._clear_measurement_labels()

    def _clear_measurement_labels(self) -> None:
        mask = self._channel_mask()
        states = []
        for channel in (1, 2):
            active = bool(mask & (1 << (channel - 1)))
            states.append("—" if active else "未启用")
            for label in self.measurement_labels[(channel - 1) * 4:channel * 4]:
                label.setText(states[-1])
        self._set_status("otr", "/".join(states))

    def _update_square_amplitude(self, frame: CompletedFrame) -> None:
        # 每帧重建。显示无法整形时仍可用平台电平；非方波不能沿用上一帧。
        self._square_amplitude = {}
        self._square_amplitude_mask = frame.header.channel_mask
        self._square_amplitude_time = monotonic()
        if frame.header.sample_format in (SampleFormat.ENVELOPE64, SampleFormat.ENVELOPE32):
            decoded = decode_envelope64(frame.payload, frame.header.channel_mask)
            for channel, name in ((1, "a"), (2, "b")):
                if not frame.header.channel_mask & channel:
                    continue
                stats = square_plateau_stats(decoded[f"min_{name}"], decoded[f"max_{name}"])
                if stats is None:
                    continue
                low, high, mean = stats
                minimum, maximum = int(round(low)), int(round(high))
                self._square_amplitude.update({
                    f"min_{name}": minimum, f"max_{name}": maximum,
                    f"vpp_{name}": maximum - minimum,
                    f"mean_{name}": int(round(mean)),
                })
        self._refresh_continuous_measurement()

    def _refresh_continuous_measurement(self) -> None:
        if self._hardware_measurement is None:
            return
        measurement = self._hardware_measurement
        mask = self._hardware_measurement_mask
        # 两类报文独立编号，幅度取最近有效波形，频率/OTR 取硬件包。
        # 超过三个刷新周期（至少 0.5 秒）无新波形时，不继续套用旧幅度。
        fresh = monotonic() - self._square_amplitude_time <= max(0.5, 3.0 / max(1.0, self.refresh_spin.value()))
        if mask == self._square_amplitude_mask and fresh:
            measurement = replace(measurement, **self._square_amplitude)
        self._publish_measurement(measurement, mask)

    def _accept_manual_raw(self, frame: CompletedFrame) -> None:
        self.current_frame = frame
        self._fit_timebase_to_record(frame)
        self.plot_widget.display_frame(frame)
        self._measure_raw_frame(frame)
        if self._manual_busy:
            samples = frame.header.total_samples
            duration_ms = samples * 1000.0 / max(1, frame.header.sample_rate_hz)
            self._finish_manual_capture(f"采集完成 {duration_ms:.1f} ms / {samples} 点")

    def _fit_timebase_to_record(self, frame: CompletedFrame) -> None:
        if frame.header.sample_rate_hz <= 0 or frame.header.total_samples <= 0:
            return
        duration = frame.header.total_samples / float(frame.header.sample_rate_hz)
        needed = duration / PlotWidget.HORIZONTAL_DIVISIONS
        selected = TIME_PER_DIV[-1][0]
        for seconds, _label in TIME_PER_DIV:
            if seconds >= needed:
                selected = seconds
                break
        self.timebase_combo.blockSignals(True)
        self.timebase_combo.setCurrentIndex(
            next(i for i, (value, _) in enumerate(TIME_PER_DIV) if value == selected)
        )
        self.timebase_combo.blockSignals(False)
        self.plot_widget.set_timebase(float(selected))
        self._update_scope_badges()

    def _measure_raw_frame(self, frame: CompletedFrame) -> None:
        decoded = decode_raw32(frame.payload, frame.header.channel_mask)
        sample_rate = float(frame.header.sample_rate_hz)
        mask = frame.header.channel_mask

        def stats(codes) -> tuple[int, int, int, int, int, bool]:
            if codes.size == 0:
                return 0, 0, 0, 0, 0, False
            plateau = square_plateau_stats(codes)
            if plateau is None:
                minimum = int(round(codes.min()))
                maximum = int(round(codes.max()))
                mean = int(round(codes.mean()))
            else:
                low, high, mean_level = plateau
                minimum, maximum = int(round(low)), int(round(high))
                mean = int(round(mean_level))
            frequency = zero_crossing_frequency(codes, sample_rate)
            return (minimum, maximum, maximum - minimum, mean,
                    int(round(frequency)), frequency > 0)

        min_a, max_a, vpp_a, mean_a, freq_a, valid_a = stats(decoded["a"])
        min_b, max_b, vpp_b, mean_b, freq_b, valid_b = stats(decoded["b"])
        measurement = Measurement(
            min_a=min_a, max_a=max_a, min_b=min_b, max_b=max_b,
            mean_a=mean_a, mean_b=mean_b,
            vpp_a=vpp_a, vpp_b=vpp_b,
            otr_count_a=int(decoded["otr_a"].sum()),
            otr_count_b=int(decoded["otr_b"].sum()),
            period_samples_a=0, period_samples_b=0,
            frequency_hz_a=freq_a, frequency_hz_b=freq_b,
            period_valid_a=valid_a, period_valid_b=valid_b,
            calculation_overrun=False,
        )
        self._measurement_filter.reset()
        self._publish_measurement(measurement, mask)

    def _publish_measurement(self, measurement: Measurement, mask: int) -> None:
        """保存原始测量，界面只显示稳定后的幅度和频率。"""
        self._last_measurement = measurement
        self._last_measurement_mask = mask
        self._displayed_measurement = self._stabilize_for_display(measurement, mask)
        self._render_measurement(self._displayed_measurement, mask)

    def _stabilize_for_display(self, measurement: Measurement, mask: int) -> Measurement:
        updates: dict[str, int | float | bool] = {}
        for channel, suffix in ((1, "a"), (2, "b")):
            minimum, maximum, vpp, frequency, valid = self._measurement_filter.update_channel(
                channel,
                getattr(measurement, f"min_{suffix}"),
                getattr(measurement, f"max_{suffix}"),
                float(getattr(measurement, f"frequency_hz_{suffix}")),
                frequency_valid=bool(getattr(measurement, f"period_valid_{suffix}")),
                active=bool(mask & channel),
            )
            updates[f"min_{suffix}"] = minimum
            updates[f"max_{suffix}"] = maximum
            updates[f"vpp_{suffix}"] = vpp
            updates[f"frequency_hz_{suffix}"] = int(round(frequency))
            updates[f"period_valid_{suffix}"] = valid
        return replace(measurement, **updates)

    def _load_adc_calibration(self) -> None:
        for channel in (1, 2):
            self._adc_gain[channel] = self.settings.value(
                f"adc_cal/ch{channel}_gain", 1.0, type=float,
            )
            self._adc_offset[channel] = self.settings.value(
                f"adc_cal/ch{channel}_offset", 0.0, type=float,
            )

    def _save_adc_calibration(self) -> None:
        for channel in (1, 2):
            self.settings.setValue(f"adc_cal/ch{channel}_gain", self._adc_gain[channel])
            self.settings.setValue(
                f"adc_cal/ch{channel}_offset", self._adc_offset[channel],
            )

    def _apply_adc_calibration(self) -> None:
        for channel in (1, 2):
            self.plot_widget.set_adc_calibration(
                channel, self._adc_gain[channel],
                self._adc_offset[channel] + fixed_dc_offset_v(channel, self._adc_gain[channel]),
            )

    def _render_measurement(self, measurement: Measurement, channel_mask: int) -> None:
        channels = (
            (1, measurement.min_a, measurement.max_a, measurement.vpp_a,
             measurement.frequency_hz_a, measurement.period_valid_a),
            (2, measurement.min_b, measurement.max_b, measurement.vpp_b,
             measurement.frequency_hz_b, measurement.period_valid_b),
        )
        for channel, min_code, max_code, vpp_code, frequency, valid in channels:
            labels = self.measurement_labels[(channel - 1) * 4:channel * 4]
            if not (channel_mask & (1 << (channel - 1))):
                for label in labels:
                    label.setText("未启用")
                continue
            gain = self._adc_gain[channel]
            offset = self._adc_offset[channel] + fixed_dc_offset_v(channel, gain)
            labels[0].setText(format_voltage(code_to_voltage(min_code, gain=gain, offset_v=offset)))
            labels[1].setText(format_voltage(code_to_voltage(max_code, gain=gain, offset_v=offset)))
            labels[2].setText(format_voltage(
                vpp_from_code_span(vpp_code, gain=gain), peak_to_peak=True,
            ))
            labels[3].setText(format_frequency_hz(frequency) if valid else "无效")
        otr_a = (str(measurement.otr_count_a) if channel_mask & 0x01 else "未启用")
        otr_b = (str(measurement.otr_count_b) if channel_mask & 0x02 else "未启用")
        self._set_status("otr", f"{otr_a}/{otr_b}")

    def _calibrate_amplitude(self, channel: int) -> None:
        if channel not in (1, 2):
            raise ValueError("通道必须为 1 或 2")
        if self._last_measurement is None:
            self.statusBar().showMessage("没有可用于校准的测量，请先运行采集", 4000)
            return
        mask = self._last_measurement_mask
        if not (mask & (1 << (channel - 1))):
            self.statusBar().showMessage(f"CH{channel} 未启用，无法校准", 4000)
            return
        measurement = self._last_measurement
        vpp_code = measurement.vpp_a if channel == 1 else measurement.vpp_b
        known_vpp = self.cal_vpp_spins[channel].value()
        try:
            gain = gain_from_known_vpp(vpp_code, known_vpp)
        except ValueError as exc:
            self.statusBar().showMessage(f"CH{channel} {exc}", 5000)
            return
        self._adc_gain[channel] = gain
        self._save_adc_calibration()
        self._apply_adc_calibration()
        self._render_measurement(self._displayed_measurement or measurement, mask)
        if self.current_frame is not None:
            self.plot_widget.display_frame(self.current_frame)
        self.statusBar().showMessage(
            f"幅度已校准：CH{channel}×{self._adc_gain[channel]:.4f}", 5000,
        )

    def _reset_adc_calibration(self, channel: int) -> None:
        if channel not in (1, 2):
            raise ValueError("通道必须为 1 或 2")
        self._adc_gain[channel] = 1.0
        self._adc_offset[channel] = 0.0
        self._save_adc_calibration()
        self._apply_adc_calibration()
        if self._displayed_measurement is not None:
            self._render_measurement(self._displayed_measurement, self._last_measurement_mask)
        if self.current_frame is not None:
            self.plot_widget.display_frame(self.current_frame)
        self.statusBar().showMessage(f"CH{channel} 已恢复标称 ±5V 换算", 3000)

    def _envelope_display_points(
        self, capture_depth: int, channel_mask: int, refresh_hz: float,
    ) -> int:
        """按 1:1 优先、千兆网和 FIFO 深度截断，计算包络帧点数。

        短时基（窗口点数 ≤ 2048）保持 ADC 原样。长时基做 Min/Max 抽桶时，
        点数取 ``ceil(capture_depth / bucket)``，让 ``点数 × 桶长`` 贴住
        十格窗口。若固定 2048 点，5/10/20 µs 的桶取整会把帧时长拉长超过
        5%，``_envelope_matches_timebase`` 会把新帧全部丢掉，波形卡死。
        """
        bytes_per_point = 4 if channel_mask in (1, 2) else 8
        refresh = max(float(refresh_hz), 1.0)
        max_by_gbe = max(
            1,
            int(GBE_ENVELOPE_BYTES_PER_SEC / refresh / bytes_per_point),
        )
        cap = max(1, int(capture_depth))
        limit = max(1, min(MAX_ENVELOPE_POINTS, max_by_gbe))
        if cap <= limit:
            return cap
        bucket = (cap + limit - 1) // limit
        return max(1, (cap + bucket - 1) // bucket)

    def _envelope_matches_timebase(self, frame: CompletedFrame) -> bool:
        """判断包络帧总时长是否匹配当前示波器横轴。"""
        sample_rate = frame.header.sample_rate_hz
        sample_count = frame.header.total_samples
        seconds_per_div = self.timebase_combo.currentData()
        if sample_rate <= 0 or sample_count <= 0 or seconds_per_div is None:
            return False
        actual = sample_count / float(sample_rate)
        window = 10.0 * float(seconds_per_div)
        # 与 SET_ACQUISITION 相同：十格窗口按 ADC 样点取整，10 ns/div
        # 的 6.5 点会变成 7 点，不能拿理想 100 ns 去卡 5%。
        capture = max(1, min(RAW_MAX_SAMPLES, int(ceil(self.sample_rate_hz * window))))
        expected = capture / float(self.sample_rate_hz)
        # 桶大小取整会产生很小的误差，5% 足以区分相邻时基的旧帧。
        return abs(actual - expected) <= expected * 0.05

    def _on_udp_stats(self, stats: dict[str, int]) -> None:
        self._set_status("loss", f"{stats['errors']}/{stats['dropped_frames']}")

    def _set_timebase(self, text: str) -> None:
        seconds = self.timebase_combo.currentData()
        if seconds is None:
            return
        self.plot_widget.set_timebase(float(seconds))
        if self.current_frame is not None:
            self.plot_widget.display_frame(self.current_frame)
        if self._acquisition_mode == AcquisitionMode.MANUAL:
            return
        self._clear_continuous_measurement()
        # 先清掉 socket 中的旧配置报文，再提交 FPGA 新参数；旧帧
        # 仍可由下面的即时重绘作为过渡，但不会排队数秒后才看到新帧。
        self.udp_receiver.discard_pending()
        if self._uart_connected:
            self._apply_acquisition()

    def _set_channel_mode(self, _: int) -> None:
        mode = self.channel_mode_combo.currentData()
        if mode is None:
            return
        self.plot_widget.set_channel_mode(mode)
        self._update_channel_controls()
        if self._manual_busy or self._acquisition_mode == AcquisitionMode.MANUAL:
            return
        self._clear_continuous_measurement()
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
        self.smoothing_frequency_spins[1].setEnabled(ch1_active)
        self.smoothing_frequency_spins[2].setEnabled(ch2_active)
        if getattr(self, "cal_vpp_spins", None):
            for widget in (
                self.cal_vpp_spins[1], self.calibrate_buttons[1],
                self.reset_cal_buttons[1],
            ):
                widget.setEnabled(ch1_active)
            for widget in (
                self.cal_vpp_spins[2], self.calibrate_buttons[2],
                self.reset_cal_buttons[2],
            ):
                widget.setEnabled(ch2_active)
        self.channel_mode_combo.setEnabled(not self._sampling_mode and not self._mode_switching)
        self.trigger_source.setEnabled(not self._sampling_mode and mode == ChannelDisplayMode.BOTH)
        if mode == ChannelDisplayMode.CH1:
            self.trigger_source.setCurrentIndex(0)
        elif mode == ChannelDisplayMode.CH2:
            self.trigger_source.setCurrentIndex(1)
        self._update_scope_badges()

    def _set_vdiv(self, channel: int) -> None:
        combo = self.ch1_vdiv_combo if channel == 1 else self.ch2_vdiv_combo
        value = combo.currentData()
        if value is not None:
            self.plot_widget.set_volts_per_div(channel, float(value))

    def _set_smoothing_frequency(self, channel: int, frequency_khz: float) -> None:
        frequency_hz = frequency_khz * 1000.0
        self.plot_widget.set_smoothing_start_frequency(channel, frequency_hz)
        self.settings.setValue(f"display/ch{channel}_smoothing_start_hz", frequency_hz)

    def _set_analysis(self, index: int) -> None:
        self.plot_widget.set_fft_enabled(index == 1)
        if self.current_frame is not None:
            self.plot_widget.display_frame(self.current_frame)
        self._update_scope_badges()

    def _save_current(self) -> None:
        if self.current_frame is None:
            self.statusBar().showMessage("当前没有可保存帧", 3000)
            return
        config = {
            "timebase": self.timebase_combo.currentText(),
            "sampling_mode": self._sampling_mode,
            "channel_mode": self.channel_mode_combo.currentText(),
            "acquisition_mode": self.acquisition_mode_combo.currentText(),
            "ch1_vdiv": self.ch1_vdiv_combo.currentText(),
            "ch2_vdiv": self.ch2_vdiv_combo.currentText(),
            "ch1_position": self.ch1_position_spin.value(),
            "ch2_position": self.ch2_position_spin.value(),
            "trigger_source": self.trigger_source.currentText(),
            "trigger_edge": self.trigger_edge.currentText(),
            "threshold": self.threshold_spin.value(),
            "hysteresis": self.hysteresis_spin.value(),
        }
        note = self.note_edit.text().strip()
        record_id = self.store.save_frame(self.current_frame, config=config, note=note)
        self.statusBar().showMessage(f"已保存记录 #{record_id}", 3000)
        self._refresh_records()

    def _refresh_records(self) -> None:
        records = self.store.list_captures()
        format_names = {
            SampleFormat.RAW32: "RAW32",
            SampleFormat.RAW16: "RAW16",
            SampleFormat.ENVELOPE64: "包络64",
            SampleFormat.ENVELOPE32: "包络32",
            SampleFormat.DECIMATED32: "抽点32",
            SampleFormat.MEASUREMENT_V1: "测量",
        }
        self.records_table.setRowCount(len(records))
        for row, record in enumerate(records):
            fmt_str = format_names.get(record.sample_format, f"格式{record.sample_format}")
            try:
                dt = datetime.fromisoformat(record.captured_at)
                if dt.tzinfo is not None:
                    dt = dt.astimezone()
                time_str = dt.strftime("%Y-%m-%d %H:%M:%S")
            except Exception:
                time_str = str(record.captured_at)[:19].replace("T", " ")
            values = [
                record.id,
                time_str,
                record.frame_id,
                fmt_str,
                record.total_samples,
                record.payload_bytes,
                record.note,
            ]
            for column, value in enumerate(values):
                item = QtWidgets.QTableWidgetItem(str(value))
                if column in (0, 2, 4, 5):
                    item.setTextAlignment(QtCore.Qt.AlignRight | QtCore.Qt.AlignVCenter)
                elif column in (1, 3):
                    item.setTextAlignment(QtCore.Qt.AlignCenter | QtCore.Qt.AlignVCenter)
                self.records_table.setItem(row, column, item)

    def _selected_record_id(self) -> int | None:
        row = self.records_table.currentRow()
        item = self.records_table.item(row, 0) if row >= 0 else None
        return int(item.text()) if item else None

    def _replay_selected(self) -> None:
        record_id = self._selected_record_id()
        if record_id is None:
            self.statusBar().showMessage("请先在列表中选择一条记录", 3000)
            return
        if self._continuous_running:
            self._stop_acquisition()
        frame = self.store.load_frame(record_id)
        self._on_frame(frame, persist_measurement=False)
        self.statusBar().showMessage(f"已回放记录 #{record_id}（帧号 {frame.header.frame_id}）", 4000)

    def _delete_selected(self) -> None:
        record_id = self._selected_record_id()
        if record_id is None:
            self.statusBar().showMessage("请先在列表中选择一条记录", 3000)
            return
        self.store.delete_capture(record_id)
        self._refresh_records()
        self.statusBar().showMessage(f"已删除记录 #{record_id}", 3000)

    def closeEvent(self, event: QtGui.QCloseEvent) -> None:
        self._mode_retry.stop()
        self._mode_switching = False
        self.status_timer.stop()
        self.serial_link.disconnect_port()
        self.udp_receiver.stop()
        self.store.close()
        super().closeEvent(event)
