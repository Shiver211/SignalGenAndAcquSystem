"""GUI 测试使用独立 INI 文件，避免本机串口和 ADC 校准设置影响结果。"""

from pathlib import Path

from PyQt5 import QtCore

from host.ui.main_window import MainWindow


def create_window(
    database: Path, *, settings: QtCore.QSettings | None = None,
) -> MainWindow:
    if settings is None:
        settings = QtCore.QSettings(str(database.with_suffix(".ini")), QtCore.QSettings.IniFormat)
    return MainWindow(database, settings=settings)
