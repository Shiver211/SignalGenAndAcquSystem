"""SVG 图标加载：模板中的 ``currentColor`` 在运行时替换为指定颜色。"""

from __future__ import annotations

from functools import lru_cache

from PyQt5 import QtCore, QtGui, QtSvg

from host.ui.theme import ASSETS_DIR

ICON_MUTED = "#aab3c2"
ICON_ON_ACCENT = "#ffffff"


@lru_cache(maxsize=None)
def _svg(name: str) -> str:
    return (ASSETS_DIR / f"{name}.svg").read_text(encoding="utf-8")


def icon(name: str, color: str = ICON_MUTED, disabled: str = "#4d5666") -> QtGui.QIcon:
    """按颜色渲染 SVG 图标；同时生成禁用态，高 DPI 下保持清晰。"""
    result = QtGui.QIcon()
    for mode, tint in ((QtGui.QIcon.Normal, color), (QtGui.QIcon.Disabled, disabled)):
        renderer = QtSvg.QSvgRenderer(QtCore.QByteArray(
            _svg(name).replace("currentColor", tint).encode("utf-8")))
        for size in (16, 20, 24, 48):
            pixmap = QtGui.QPixmap(size, size)
            pixmap.fill(QtCore.Qt.transparent)
            painter = QtGui.QPainter(pixmap)
            renderer.render(painter)
            painter.end()
            result.addPixmap(pixmap, mode)
    return result
