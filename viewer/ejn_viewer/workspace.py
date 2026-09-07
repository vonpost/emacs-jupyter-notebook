"""Qt workspace window for bounded local numerical snapshot inspection."""

from __future__ import annotations

from collections.abc import Mapping
import math

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtWidgets

from .navigation import ImageGraphicsWidget, ImageViewBox, NavigationGroup, camera


MAX_LEVEL_SAMPLE = 65_536


def _sample_extrema(array: np.ndarray) -> tuple[float, float] | None:
    """Return finite extrema from at most MAX_LEVEL_SAMPLE source samples."""
    flat = np.asarray(array).reshape(-1)
    step = max(1, (flat.size + MAX_LEVEL_SAMPLE - 1) // MAX_LEVEL_SAMPLE)
    sample = flat[::step]
    finite = sample[np.isfinite(sample)]
    if not finite.size:
        return None
    return float(np.min(finite)), float(np.max(finite))


def _plane_metadata(manifest: dict) -> dict[str, dict]:
    planes = manifest.get("planes", []) if isinstance(manifest, dict) else []
    return {p.get("name"): p for p in planes if isinstance(p, dict)
            and isinstance(p.get("name"), str)}


def _spatial_key(meta: dict) -> tuple:
    return tuple(meta.get(name) for name in
                 ("grid_id", "spacing", "origin", "direction", "spatial_units"))


class WorkspaceWindow(QtWidgets.QMainWindow):
    """Persistent row-major pane workspace owned by the GUI thread."""

    closed = QtCore.Signal()

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setWindowTitle("EJN viewer")
        self.resize(1100, 700)
        self._snapshot = None
        self._planes: dict[str, np.ndarray] = {}
        self._items: dict[str, pg.ImageItem] = {}
        self._views: dict[str, pg.ViewBox] = {}
        self._metadata: dict[str, dict] = {}
        self._levels: dict[str, tuple[float, float]] = {}
        self._linked = False
        self._navigation_groups = []

        central = QtWidgets.QWidget(self)
        outer = QtWidgets.QVBoxLayout(central)
        controls = QtWidgets.QHBoxLayout()
        self.fit_button = QtWidgets.QPushButton("Fit", central)
        self.level = QtWidgets.QDoubleSpinBox(central)
        self.level.setRange(-1.0e30, 1.0e30)
        self.level.setDecimals(6)
        self.level.setPrefix("Level ")
        self.width = QtWidgets.QDoubleSpinBox(central)
        self.width.setRange(1.0e-12, 1.0e30)
        self.width.setDecimals(6)
        self.width.setPrefix("Width ")
        self.readout = QtWidgets.QLabel("Pixel: —", central)
        self.readout.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored,
                                   QtWidgets.QSizePolicy.Policy.Preferred)
        controls.addWidget(self.fit_button)
        controls.addWidget(self.level)
        controls.addWidget(self.width)
        controls.addWidget(self.readout, 1)
        outer.addLayout(controls)
        self.graphics = ImageGraphicsWidget(central)
        outer.addWidget(self.graphics, 1)
        self.setCentralWidget(central)
        self.fit_button.clicked.connect(self.fit)
        self.level.valueChanged.connect(self._levels_changed)
        self.width.valueChanged.connect(self._levels_changed)
        self.graphics.scene().sigMouseMoved.connect(self._mouse_moved)

    def install_snapshot(self, snapshot) -> None:
        """Install SNAPSHOT, preserving compatible pane ranges and levels."""
        planes = getattr(snapshot, "planes", None)
        if not isinstance(planes, Mapping) or not 1 <= len(planes) <= 4:
            raise ValueError("snapshot must contain 1 to 4 planes")
        numerical = bool(getattr(snapshot, "numerical", True))
        if any(not isinstance(name, str) or not isinstance(array, np.ndarray)
               or (array.ndim != 2 and not (not numerical and array.ndim == 3
                                            and array.shape[-1] in (3, 4)))
               for name, array in planes.items()):
            raise ValueError("snapshot planes have unsupported shape")
        old_snapshot = self._snapshot
        preserved_level = self.level.value()
        preserved_width = self.width.value()
        preserve = False
        if old_snapshot is not None:
            old_manifest = getattr(old_snapshot, "manifest", None) or {}
            manifest = getattr(snapshot, "manifest", None) or {}
            old_names = set(getattr(old_snapshot, "planes", {}))
            new_names = set(planes)
            old_meta = _plane_metadata(old_manifest)
            new_meta = _plane_metadata(manifest)
            preserve = (getattr(old_snapshot, "workspace", None)
                        == getattr(snapshot, "workspace", None)
                        and getattr(old_snapshot, "generation", None)
                        == getattr(snapshot, "generation", None)
                        and old_manifest.get("sample_id") == manifest.get("sample_id")
                        and old_names == new_names
                        and all(new_meta.get(name, {}).get("grid_id")
                                and old_meta.get(name, {}).get("grid_id")
                                and tuple(getattr(old_snapshot.planes[name], "shape", ()))
                                == tuple(getattr(planes[name], "shape", ()))
                                and _spatial_key(old_meta[name]) == _spatial_key(new_meta[name])
                                for name in new_names))
        cameras = {name: camera(view) for name, view in self._views.items()}
        for group in self._navigation_groups:
            group.dispose()
        self._navigation_groups.clear()
        if self._items:
            self._levels = {name: tuple(item.getLevels()) for name, item in self._items.items()}
        for item in self._items.values():
            item.deleteLater()
        self._items.clear()
        self._views.clear()
        self._planes = dict(planes)
        self._snapshot = snapshot
        self._metadata = _plane_metadata(getattr(snapshot, "manifest", {}))
        self.graphics.clear()
        names = list(self._planes)
        extrema = [_sample_extrema(self._planes[name]) for name in names if numerical]
        extrema = [value for value in extrema if value is not None]
        global_low = min((value[0] for value in extrema), default=0.0)
        global_high = max((value[1] for value in extrema), default=1.0)
        if global_high <= global_low:
            global_high = global_low + 1.0
        for index, name in enumerate(names):
            row, col = divmod(index, 2)
            self.graphics.addLabel(name, row=row * 2, col=col)
            view = ImageViewBox()
            self.graphics.addItem(view, row=row * 2 + 1, col=col)
            view.setMenuEnabled(False)
            initial_levels = (global_low, global_high) if numerical else (0.0, 255.0)
            item = pg.ImageItem(self._planes[name], axisOrder="row-major",
                                autoLevels=False, levels=initial_levels)
            item.setAutoDownsample(False)
            view.addItem(item)
            view.invertY(True)
            self._views[name] = view
            self._items[name] = item
            self._levels[name] = initial_levels
            if preserve and name in self._levels:
                item.setLevels(self._levels[name])
        self._linked = self._linkable(names)
        groups = [names] if self._linked else [[name] for name in names]
        for members in groups:
            group = NavigationGroup([self._views[name] for name in members])
            self._navigation_groups.append(group)
            if preserve:
                group.restore(cameras[members[0]])
        if names:
            low, high = self._items[names[0]].getLevels()
            if preserve:
                low = preserved_level - preserved_width / 2.0
                high = preserved_level + preserved_width / 2.0
                for item in self._items.values():
                    item.setLevels((low, high))
            self.level.blockSignals(True)
            self.width.blockSignals(True)
            self.level.setValue((low + high) / 2.0)
            self.width.setValue(max(high - low, 1.0e-12))
            self.level.blockSignals(False)
            self.width.blockSignals(False)
        if not preserve:
            self.fit()
        self.level.setEnabled(numerical)
        self.width.setEnabled(numerical)

    def _linkable(self, names: list[str]) -> bool:
        if not names or not getattr(self._snapshot, "numerical", True):
            return False
        first = self._metadata.get(names[0], {})
        grid = first.get("grid_id")
        if not grid:
            return False
        shape = self._planes[names[0]].shape
        return all(self._metadata.get(name, {}).get("grid_id") == grid
                   and self._planes[name].shape == shape
                   and _spatial_key(self._metadata.get(name, {})) == _spatial_key(first)
                   for name in names)

    def _levels_changed(self) -> None:
        if not self._items:
            return
        center, width = self.level.value(), self.width.value()
        for item in self._items.values():
            item.setLevels((center - width / 2.0, center + width / 2.0))

    def fit(self) -> None:
        for group in self._navigation_groups:
            group.fit()

    def _mouse_moved(self, position) -> None:
        for name, view in self._views.items():
            if not view.sceneBoundingRect().contains(position):
                continue
            point = view.mapSceneToView(position)
            col, row = math.floor(point.x()), math.floor(point.y())
            array = self._planes[name]
            if 0 <= row < array.shape[0] and 0 <= col < array.shape[1]:
                if getattr(self._snapshot, "numerical", True):
                    self.readout.setText("%s [%d,%d] = %s" %
                                        (name, row, col, array[row, col]))
                else:
                    self.readout.setText("%s [%d,%d] (numeric unavailable)" %
                                        (name, row, col))
                return
        self.readout.setText("Pixel: —")

    def keyPressEvent(self, event) -> None:
        if event.key() == QtCore.Qt.Key_F:
            self.fit()
        elif event.key() == QtCore.Qt.Key_Escape:
            self.close()
        else:
            super().keyPressEvent(event)

    def closeEvent(self, event) -> None:
        for group in self._navigation_groups:
            group.dispose()
        self._navigation_groups.clear()
        self.closed.emit()
        super().closeEvent(event)
