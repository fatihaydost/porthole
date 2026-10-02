#!/usr/bin/env python3
"""Drive the widget's real Service.qml against a live sshd.

Loads tests/Harness.qml in a plain QML engine (PyQt6, system Qt 6) with a
stand-in for KLocalizedContext, so every tunnel action goes through the same
code path the plasmoid uses: Exec.qml -> plasma5support executable engine ->
bash -> systemd-run / systemctl / ss / journalctl.

Usage: tests/harness.py <scratch dir with the test sshd>   (run by tests/run-e2e.sh)
The store is isolated with XDG_CONFIG_HOME=<scratch>/config.
"""
import getpass
import os
import re
import sys

from PyQt6.QtCore import QObject, QTimer, QUrl, pyqtSlot
from PyQt6.QtGui import QGuiApplication
from PyQt6.QtQml import QQmlComponent, QQmlEngine


class I18n(QObject):
    """Bare i18n()/i18nc() for the QML context, like KLocalizedContext."""

    @staticmethod
    def _fill(text, args):
        for i, a in enumerate(args, 1):
            text = text.replace("%" + str(i), str(a))
        return text

    @pyqtSlot(str, result=str)
    @pyqtSlot(str, "QVariant", result=str)
    @pyqtSlot(str, "QVariant", "QVariant", result=str)
    @pyqtSlot(str, "QVariant", "QVariant", "QVariant", result=str)
    def i18n(self, text, *args):
        return self._fill(text, args)

    @pyqtSlot(str, str, result=str)
    @pyqtSlot(str, str, "QVariant", result=str)
    @pyqtSlot(str, str, "QVariant", "QVariant", result=str)
    @pyqtSlot(str, str, "QVariant", "QVariant", "QVariant", result=str)
    def i18nc(self, context, text, *args):
        return self._fill(text, args)


def main():
    scratch = os.path.abspath(sys.argv[1])
    os.environ["XDG_CONFIG_HOME"] = os.path.join(scratch, "config")
    os.environ.pop("SSH_AUTH_SOCK", None)
    here = os.path.dirname(os.path.abspath(__file__))

    app = QGuiApplication(sys.argv[:1])
    engine = QQmlEngine()
    engine.addImportPath("/usr/lib/qt6/qml")
    ctx = I18n()
    engine.rootContext().setContextObject(ctx)
    engine.rootContext().setContextProperty("scratchDir", scratch)
    engine.rootContext().setContextProperty("userName", getpass.getuser())

    comp = QQmlComponent(engine, QUrl.fromLocalFile(os.path.join(here, "Harness.qml")))
    if comp.isError():
        for e in comp.errors():
            print("QML error:", e.toString())
        return 2
    root = comp.create()
    if root is None:
        for e in comp.errors():
            print("QML error:", e.toString())
        return 2

    result = {"code": 1}

    def finished(code):
        result["code"] = code
        app.quit()

    root.finished.connect(finished)
    QTimer.singleShot(240000, lambda: finished(3))  # global timeout
    app.exec()
    return result["code"]


if __name__ == "__main__":
    sys.exit(main())
