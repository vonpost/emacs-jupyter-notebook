"""Small, real Qt/PyQtGraph shell used as the W21 viewer foundation.

This module intentionally contains no EJN IPC or numerical artifact parser.
The demo mode supplies deterministic NumPy planes so the window and display
contract can be exercised before V3/V4 connect the protocol.
"""

from __future__ import annotations

import argparse
import json
import platform
import sys
import time
from typing import Mapping

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtGui, QtWidgets


def demo_planes() -> Mapping[str, np.ndarray]:
    """Return asymmetric row-major test planes with distinct extents."""
    y, x = np.mgrid[0:96, 0:144]
    reference = (x * 0.7 + y * 2.0).astype(np.float32)
    yy, xx = np.mgrid[0:72, 0:120]
    candidate = (100.0 + xx * 1.4 - yy * 0.8).astype(np.float32)
    return {"reference": reference, "candidate": candidate}


class ViewerWindow(QtWidgets.QMainWindow):
    """Two independent demo panes; production comparison arrives in V7."""

    def __init__(self, planes: Mapping[str, np.ndarray], parent=None):
        super().__init__(parent)
        self.setWindowTitle("EJN viewer — demo")
        self.resize(1100, 650)
        self._planes = {name: np.asarray(array) for name, array in planes.items()}
        self._items = []
        self._views = []

        central = QtWidgets.QWidget(self)
        layout = QtWidgets.QVBoxLayout(central)
        controls = QtWidgets.QHBoxLayout()
        self._fit = QtWidgets.QPushButton("Fit", central)
        self._levels = QtWidgets.QDoubleSpinBox(central)
        self._levels.setRange(0.001, 1.0e12)
        self._levels.setDecimals(3)
        self._levels.setSingleStep(1.0)
        self._levels.setPrefix("Width ")
        controls.addWidget(self._fit)
        controls.addWidget(self._levels)
        controls.addStretch(1)
        layout.addLayout(controls)

        self._graphics = pg.GraphicsLayoutWidget(central)
        layout.addWidget(self._graphics, 1)
        self.setCentralWidget(central)

        names = list(self._planes)[:2]
        if not names:
            raise ValueError("at least one plane is required")
        for index, name in enumerate(names):
            self._graphics.addLabel(name, row=0, col=index)
            view = self._graphics.addViewBox(row=1, col=index, lockAspect=True)
            view.setMenuEnabled(False)
            image = pg.ImageItem(self._planes[name], axisOrder="row-major")
            view.addItem(image)
            view.invertY(True)
            self._views.append(view)
            self._items.append(image)
        self._fit.clicked.connect(self.fit_images)
        self._levels.valueChanged.connect(self.set_width)
        self._levels.setValue(self._initial_width())
        self.fit_images()

    def _initial_width(self) -> float:
        lows = []
        highs = []
        for array in self._planes.values():
            finite = array[np.isfinite(array)]
            if finite.size:
                lows.append(float(np.min(finite)))
                highs.append(float(np.max(finite)))
        return max(highs) - min(lows) if lows else 1.0

    def fit_images(self) -> None:
        for view in self._views:
            view.autoRange()

    def set_width(self, width: float) -> None:
        for image, array in zip(self._items, self._planes.values()):
            finite = array[np.isfinite(array)]
            if finite.size:
                center = float(np.mean(finite))
                image.setLevels((center - width / 2.0, center + width / 2.0))


def _nonblank(window: ViewerWindow) -> bool:
    """Check that the image viewport contains painted, varying image data."""
    image = window._graphics.grab().toImage().convertToFormat(QtGui.QImage.Format_RGB32)
    if image.isNull():
        return False
    colors = set()
    for y in range(0, image.height(), max(1, image.height() // 24)):
        for x in range(0, image.width(), max(1, image.width() // 24)):
            color = image.pixelColor(x, y)
            colors.add((color.red(), color.green(), color.blue()))
    if len(colors) < 8:
        return False
    luminance = [0.2126 * r + 0.7152 * g + 0.0722 * b for r, g, b in colors]
    return max(luminance) - min(luminance) > 10.0


def smoke_test(offscreen: bool = False) -> int:
    """Open, paint, resize, inspect, and close; print machine-readable evidence."""
    if offscreen:
        # Must be set before QApplication is constructed.
        import os

        os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])
    window = ViewerWindow(demo_planes())
    app.setQuitOnLastWindowClosed(False)
    started = time.monotonic()
    evidence = {"platform": platform.system(), "qt_platform": app.platformName(),
                "device_pixel_ratio": window.devicePixelRatioF(), "timed_out": False}

    def finish():
        evidence["painted_after_reopen"] = _nonblank(window)
        window.close()
        evidence["closed"] = not window.isVisible()
        app.quit()

    def resized():
        evidence["painted_after_resize"] = _nonblank(window)
        evidence["resized_to"] = [window.width(), window.height()]
        window.close()
        window.show()
        QtCore.QTimer.singleShot(150, finish)

    def painted():
        evidence["painted_before_resize"] = _nonblank(window)
        # Scheduled observation time, not a measured first-paint latency.
        evidence["paint_observed_ms"] = round((time.monotonic() - started) * 1000, 2)
        window.resize(840, 520)
        QtCore.QTimer.singleShot(150, resized)

    def deadline():
        evidence["timed_out"] = True
        window.close()
        app.quit()

    watchdog = QtCore.QTimer()
    watchdog.setSingleShot(True)
    watchdog.timeout.connect(deadline)
    watchdog.start(5000)
    window.show()
    QtCore.QTimer.singleShot(150, painted)
    app.exec()
    watchdog.stop()
    evidence["painted"] = all(evidence.get(key, False) for key in
                              ("painted_before_resize", "painted_after_resize",
                               "painted_after_reopen", "closed"))
    print(json.dumps(evidence, sort_keys=True))
    return 0 if evidence["painted"] and not evidence["timed_out"] else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Local EJN PyQtGraph viewer")
    parser.add_argument("--demo", action="store_true", help="show demo planes")
    parser.add_argument("--smoke-test", action="store_true", help="run a paint/resize smoke test")
    parser.add_argument("--offscreen", action="store_true", help="use Qt's offscreen platform for smoke tests")
    args = parser.parse_args(argv)
    if args.smoke_test:
        return smoke_test(args.offscreen)
    if not args.demo:
        parser.error("one of --demo or --smoke-test is required")
    app = QtWidgets.QApplication(sys.argv if argv is None else [sys.argv[0], *argv])
    window = ViewerWindow(demo_planes())
    window.show()
    return app.exec()
