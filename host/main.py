"""M8 上位机入口：python host/main.py。"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from PyQt5 import QtWidgets  # noqa: E402

from host.ui.main_window import MainWindow  # noqa: E402


def main() -> int:
    app = QtWidgets.QApplication(sys.argv)
    app.setApplicationName("FPGA Signal System")
    window = MainWindow(ROOT / "host" / "data" / "signal.db", auto_connect=True)
    window.show()
    return app.exec_()


if __name__ == "__main__":
    raise SystemExit(main())
