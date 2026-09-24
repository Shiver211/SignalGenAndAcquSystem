"""上位机现代深色主题。"""

from __future__ import annotations

from pathlib import Path

CH1_COLOR = "#f7c948"
CH2_COLOR = "#2ee6d6"
ACCENT = "#5b8cff"
PLOT_BACKGROUND = "#0a0d12"
GRID_COLOR = (120, 136, 160, 60)

_BG = "#0d1117"
_SURFACE = "#12171f"
_CARD = "#171d27"
_INPUT = "#0f141b"
_BORDER = "#232b38"
_TEXT = "#e6e9ef"
_MUTED = "#8a94a6"
ASSETS_DIR = Path(__file__).resolve().parent / "assets"
_CHEVRON = (ASSETS_DIR / "chevron-down.svg").as_posix()

STYLE_SHEET = f"""
* {{ outline: none; }}
QWidget {{
    background: {_BG}; color: {_TEXT};
    font-family: "Segoe UI Variable Text", "Segoe UI", "Microsoft YaHei UI", sans-serif;
    font-size: 10pt;
}}
QToolTip {{ background: #1f2733; color: {_TEXT}; border: 1px solid #2f3a4a; padding: 4px 8px; border-radius: 6px; }}

/* ---- 框架区域 ---- */
QWidget#header {{ background: {_SURFACE}; border-bottom: 1px solid {_BORDER}; }}
QWidget#header QLabel {{ background: transparent; }}
QToolButton#settingsButton {{ background: transparent; border: 1px solid transparent; border-radius: 10px; }}
QToolButton#settingsButton:hover {{ background: #1c2430; border-color: #2a3444; }}
QToolButton#settingsButton:pressed {{ background: #222b3a; }}
QLabel#appTitle {{ font-size: 13pt; font-weight: 700; color: #f5f7fa; }}
QLabel#appSubtitle {{ color: {_MUTED}; font-size: 9pt; }}
QWidget#sidebar {{ background: {_SURFACE}; border-right: 1px solid {_BORDER}; }}
QWidget#sidebar QScrollArea, QWidget#sidebar QScrollArea > QWidget > QWidget {{ background: {_SURFACE}; }}
QStatusBar {{ background: {_SURFACE}; border-top: 1px solid {_BORDER}; color: {_MUTED}; min-height: 30px; }}
QStatusBar::item {{ border: none; }}
QStatusBar QWidget {{ background: transparent; }}

/* ---- 侧栏页签：胶囊样式 ---- */
QTabWidget::pane {{ border: none; }}
QTabWidget::tab-bar {{ alignment: center; }}
QTabBar {{ background: transparent; }}
QTabBar::tab {{
    background: transparent; color: {_MUTED}; padding: 7px 14px; margin: 10px 2px 6px 2px;
    border-radius: 8px; font-weight: 600;
}}
QTabBar::tab:selected {{ background: #222b3a; color: #ffffff; }}
QTabBar::tab:hover:!selected {{ color: {_TEXT}; background: #1a212c; }}

/* ---- 卡片（QGroupBox）：标题在卡片内部，无分割线 ---- */
QGroupBox {{
    background: {_CARD}; border: 1px solid {_BORDER}; border-radius: 12px;
    margin-top: 0; padding: 38px 14px 14px 14px; font-weight: 600;
}}
QGroupBox::title {{
    subcontrol-origin: padding; subcontrol-position: top left;
    left: 14px; top: 12px; color: {_MUTED}; font-size: 9pt; letter-spacing: 1px;
}}
QGroupBox QWidget {{ background: transparent; }}
QGroupBox QGroupBox {{ background: {_INPUT}; border-color: #1f2733; }}
QGroupBox#ch1Card::title {{ color: {CH1_COLOR}; }}
QGroupBox#ch2Card::title {{ color: {CH2_COLOR}; }}

QLabel {{ background: transparent; }}
QLabel[role="hint"] {{ color: #6f7a8c; font-size: 9pt; }}
QLabel[role="caption"] {{ color: {_MUTED}; font-size: 9pt; }}
QLabel[role="field"] {{ color: #aab3c2; }}
QLabel[role="value"] {{
    color: #f5f7fa; font-family: "Cascadia Mono", Consolas, monospace;
    font-size: 16pt; font-weight: 600;
}}
QLabel[role="chip"] {{
    background: #161c25; border: 1px solid {_BORDER}; border-radius: 13px;
    padding: 4px 6px; font-family: "Cascadia Mono", Consolas, monospace; font-size: 9pt;
}}
QLabel[role="led"] {{ color: #6f7a8c; font-size: 9pt; }}
QLabel[role="led"][state="ok"] {{ color: #4ade80; }}
QLabel[role="led"][state="bad"] {{ color: #f87171; }}

/* ---- 输入控件 ---- */
QComboBox, QSpinBox, QDoubleSpinBox, QLineEdit {{
    background: {_INPUT}; border: 1px solid #263040; border-radius: 8px;
    padding: 5px 10px; min-height: 22px; selection-background-color: {ACCENT};
}}
QComboBox:hover, QSpinBox:hover, QDoubleSpinBox:hover, QLineEdit:hover {{ border-color: #36445a; }}
QComboBox:focus, QSpinBox:focus, QDoubleSpinBox:focus, QLineEdit:focus {{ border-color: {ACCENT}; }}
QComboBox:disabled, QSpinBox:disabled, QDoubleSpinBox:disabled, QLineEdit:disabled {{
    color: #4d5666; border-color: #1c232d;
}}
QComboBox::drop-down {{ border: none; width: 26px; }}
QComboBox::down-arrow {{ image: url({_CHEVRON}); width: 12px; height: 12px; }}
QComboBox QAbstractItemView {{
    background: #1a212c; border: 1px solid #2c3647; border-radius: 8px; padding: 4px;
    selection-background-color: #2a3a57; outline: none;
}}
QSpinBox::up-button, QDoubleSpinBox::up-button,
QSpinBox::down-button, QDoubleSpinBox::down-button {{ width: 0; border: none; }}

/* ---- 分段选择 ---- */
QFrame#segmented {{ background: {_INPUT}; border: 1px solid #263040; border-radius: 9px; }}
QFrame#segmented:disabled {{ border-color: #1c232d; }}
QPushButton#segment {{
    background: transparent; border: none; border-radius: 6px; padding: 5px 8px;
    color: {_MUTED}; font-weight: 600; min-height: 18px;
}}
QPushButton#segment:hover {{ color: {_TEXT}; background: #18202b; }}
QPushButton#segment:checked {{ background: #273247; color: #ffffff; }}
QPushButton#segment:disabled {{ color: #454e5d; }}
QPushButton#segment:checked:disabled {{ background: #1b2230; color: #6f7a8c; }}

/* ---- 按钮 ---- */
QPushButton {{
    background: #1c2430; border: 1px solid #2a3444; border-radius: 8px;
    padding: 7px 14px; color: {_TEXT}; font-weight: 600;
}}
QPushButton:hover {{ background: #232d3b; border-color: #3a475b; }}
QPushButton:pressed {{ background: #18202a; }}
QPushButton:disabled {{ color: #4d5666; background: #151b23; border-color: #1c232d; }}
QPushButton[kind="primary"] {{ background: {ACCENT}; border: none; color: white; }}
QPushButton[kind="primary"]:hover {{ background: #7aa2ff; }}
QPushButton[kind="run"] {{ background: #16a34a; border: none; color: white; padding: 8px 22px; }}
QPushButton[kind="run"]:hover {{ background: #22c55e; }}
QPushButton[kind="stop"] {{ background: #dc2626; border: none; color: white; padding: 8px 22px; }}
QPushButton[kind="stop"]:hover {{ background: #ef4444; }}
QPushButton[kind="ghost"] {{ background: transparent; border: none; color: {_MUTED}; padding: 6px 8px; }}
QPushButton[kind="ghost"]:hover {{ color: {_TEXT}; background: #1c2430; }}

QScrollBar:vertical {{ background: transparent; width: 10px; margin: 2px; }}
QScrollBar::handle:vertical {{ background: #2a3342; border-radius: 3px; min-height: 36px; }}
QScrollBar::handle:vertical:hover {{ background: #3a4557; }}
QScrollBar::add-line, QScrollBar::sub-line {{ height: 0; }}
QScrollBar::add-page, QScrollBar::sub-page {{ background: none; }}
QTableWidget {{ background: {_INPUT}; gridline-color: {_BORDER}; border: 1px solid {_BORDER}; border-radius: 8px; }}
QHeaderView::section {{ background: {_CARD}; border: none; padding: 6px; color: {_MUTED}; }}
"""


def set_led(label, state: str | None) -> None:
    """设置状态灯颜色：``ok``/``bad``/None，并刷新样式。"""
    label.setProperty("state", state or "")
    label.style().unpolish(label)
    label.style().polish(label)
