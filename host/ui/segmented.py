"""分段选择控件：以按钮组呈现 QComboBox 的选项。

QComboBox 仍作为唯一的数据模型（currentIndex/currentData/信号均不变），
本控件只负责显示和点击，因此业务代码与测试无需区分两者。
"""

from __future__ import annotations

from PyQt5 import QtCore, QtWidgets


class SegmentedControl(QtWidgets.QFrame):
    def __init__(
        self, combo: QtWidgets.QComboBox, owner: QtWidgets.QWidget,
        labels: list[str] | None = None,
    ) -> None:
        super().__init__()
        self.setObjectName("segmented")
        self._combo = combo
        # 组合框挂在窗口上但永不显示；不能挂在本控件下，否则禁用状态会互相影响。
        combo.setParent(owner)
        combo.hide()
        layout = QtWidgets.QHBoxLayout(self)
        layout.setContentsMargins(3, 3, 3, 3)
        layout.setSpacing(2)
        self._group = QtWidgets.QButtonGroup(self)
        self._group.setExclusive(True)
        for index in range(combo.count()):
            button = QtWidgets.QPushButton(labels[index] if labels else combo.itemText(index))
            button.setObjectName("segment")
            button.setCheckable(True)
            button.setCursor(QtCore.Qt.PointingHandCursor)
            self._group.addButton(button, index)
            layout.addWidget(button, 1)
        self._group.buttonClicked[int].connect(combo.setCurrentIndex)
        combo.currentIndexChanged.connect(self._sync)
        combo.installEventFilter(self)
        self.setEnabled(combo.isEnabled())
        self._sync()

    def _sync(self, *_args) -> None:
        button = self._group.button(self._combo.currentIndex())
        if button is not None:
            button.setChecked(True)

    def eventFilter(self, watched: QtCore.QObject, event: QtCore.QEvent) -> bool:
        if watched is self._combo and event.type() == QtCore.QEvent.EnabledChange:
            self.setEnabled(self._combo.isEnabled())
        return False
