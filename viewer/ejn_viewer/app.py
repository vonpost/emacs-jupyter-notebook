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


def _image_variation(image: QtGui.QImage) -> bool:
    """Require nontrivial content rather than a uniform white/black surface."""
    colors = set()
    for y in range(0, image.height(), max(1, image.height() // 20)):
        for x in range(0, image.width(), max(1, image.width() // 20)):
            color = image.pixelColor(x, y)
            colors.add((color.red(), color.green(), color.blue()))
    if len(colors) < 8:
        return False
    luminance = [0.2126 * r + 0.7152 * g + 0.0722 * b for r, g, b in colors]
    return max(luminance) - min(luminance) > 10.0


def _pane_nonblank(window: ViewerWindow, index: int) -> bool:
    """Check varying pixels inside one specific ImageItem's ViewBox."""
    graphics = window._graphics
    image = graphics.grab().toImage().convertToFormat(QtGui.QImage.Format_RGB32)
    if image.isNull() or index >= len(window._views):
        return False
    rect = window._items[index].sceneBoundingRect().intersected(
        window._views[index].sceneBoundingRect()).adjusted(5, 5, -5, -5)
    top_left = graphics.mapFromScene(rect.topLeft())
    bottom_right = graphics.mapFromScene(rect.bottomRight())
    scale = image.devicePixelRatio()
    x = max(0, round(top_left.x() * scale))
    y = max(0, round(top_left.y() * scale))
    right = min(image.width(), round(bottom_right.x() * scale))
    bottom = min(image.height(), round(bottom_right.y() * scale))
    if right <= x or bottom <= y:
        return False
    return _image_variation(image.copy(x, y, right - x, bottom - y))


def _nonblank(window: ViewerWindow) -> bool:
    """Check that every image viewport contains painted, varying image data."""
    if getattr(window, "_views", None):
        return all(_pane_nonblank(window, index)
                   for index in range(len(window._views)))
    image = window._graphics.grab().toImage().convertToFormat(QtGui.QImage.Format_RGB32)
    if image.isNull():
        return False
    return _image_variation(image)


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
    screen = window.screen()
    evidence.update({"architecture": platform.machine(),
                     "python_version": platform.python_version(),
                     "qt_version": QtCore.qVersion(),
                     "pyqtgraph_version": pg.__version__,
                     "numpy_version": np.__version__,
                     "screen_size": [screen.size().width(), screen.size().height()],
                     "logical_dpi": round(screen.logicalDotsPerInch(), 2)})

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
        # Establish the canonical fit after the first layout pass; the initial
        # constructor auto-range can precede the final widget aspect ratio.
        window.fit_images()
        app.processEvents()
        evidence["painted_before_resize"] = _nonblank(window)
        evidence["painted_panes_before_resize"] = [
            _pane_nonblank(window, index) for index in range(len(window._views))]
        initial = [(view.viewRange()[0], view.viewRange()[1])
                   for view in window._views]
        evidence["initial_ranges"] = initial
        for view, (x_range, y_range) in zip(window._views, initial):
            x0, x1 = x_range
            y0, y1 = y_range
            view.setRange(xRange=(x0 + (x1 - x0) * .2,
                                  x1 - (x1 - x0) * .2),
                          yRange=(y0 + (y1 - y0) * .2,
                                  y1 - (y1 - y0) * .2), padding=0)
        # Scheduled observation time, not a measured first-paint latency.
        evidence["paint_observed_ms"] = round((time.monotonic() - started) * 1000, 2)
        QtCore.QTimer.singleShot(150, zoomed)

    def zoomed():
        current = [(view.viewRange()[0], view.viewRange()[1])
                   for view in window._views]
        initial = evidence["initial_ranges"]
        def changed(old, new):
            return max(abs(old[0][0] - new[0][0]),
                       abs(old[0][1] - new[0][1]),
                       abs(old[1][0] - new[1][0]),
                       abs(old[1][1] - new[1][1])) > 1e-3
        evidence["zoom_ranges_changed"] = all(
            changed(old, new) for old, new in zip(initial, current))
        evidence["painted_after_zoom"] = _nonblank(window)
        window.fit_images()
        QtCore.QTimer.singleShot(150, fit_checked)

    def fit_checked():
        current = [(view.viewRange()[0], view.viewRange()[1])
                   for view in window._views]
        initial = evidence["initial_ranges"]
        def close(old, new):
            return max(abs(old[0][0] - new[0][0]),
                       abs(old[0][1] - new[0][1]),
                       abs(old[1][0] - new[1][0]),
                       abs(old[1][1] - new[1][1])) <= 1.0
        evidence["fit_restored_ranges"] = all(
            close(old, new) for old, new in zip(initial, current))
        evidence["painted_after_fit"] = _nonblank(window)
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
                               "painted_after_reopen", "painted_after_zoom",
                               "painted_after_fit", "zoom_ranges_changed",
                               "fit_restored_ranges", "closed"))
    print(json.dumps(evidence, sort_keys=True))
    return 0 if evidence["painted"] and not evidence["timed_out"] else 1


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Local EJN PyQtGraph viewer")
    parser.add_argument("--demo", action="store_true", help="show demo planes")
    parser.add_argument("--stdio", action="store_true", help="serve bounded local Emacs control")
    parser.add_argument("--smoke-test", action="store_true", help="run a paint/resize smoke test")
    parser.add_argument("--offscreen", action="store_true", help="use Qt's offscreen platform for smoke tests")
    args = parser.parse_args(argv)
    if args.stdio:
        from .ipc import run
        return run()
    if args.smoke_test:
        return smoke_test(args.offscreen)
    if not args.demo:
        parser.error("one of --demo, --smoke-test or --stdio is required")
    app = QtWidgets.QApplication(sys.argv if argv is None else [sys.argv[0], *argv])
    window = ViewerWindow(demo_planes())
    window.show()
    return app.exec()
