"""Qt workspace for local numerical snapshots, differences and measurements."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import replace
import math

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtWidgets

from .analysis import (DIFFERENCE, MAX_ROIS, Region, comparison_error,
                       correspondence, scalar_plane)
from .analysis_worker import AnalysisJob, AnalysisWorker
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


class WorkspaceWindow(QtWidgets.QMainWindow):
    """Persistent row-major panes; all numerical analysis runs off the GUI."""

    closed = QtCore.Signal()

    def __init__(self, parent=None, *, analysis_worker=None):
        super().__init__(parent)
        self.setWindowTitle("EJN viewer")
        self.resize(1100, 800)
        self._snapshot = None
        self._planes: dict[str, np.ndarray] = {}
        self._items: dict[str, pg.ImageItem] = {}
        self._views: dict[str, pg.ViewBox] = {}
        self._metadata: dict[str, dict] = {}
        self._levels: dict[str, tuple[float, float]] = {}
        self._linked = False
        self._navigation_groups = []
        self._regions: dict[int, Region] = {}
        self._roi_items = {}
        self._next_region = 0
        self._syncing_rois = False
        self._difference = None
        self._difference_key = None
        self._difference_levels = {}
        self._displayed_comparison = None
        self._analysis_token = 0
        self._statistics = {}
        self._closed = False
        self._analysis_owner = object()
        self._owns_worker = analysis_worker is None
        self._worker = analysis_worker or AnalysisWorker(self)
        self._worker.ready.connect(self._analysis_ready)
        self._analysis_timer = QtCore.QTimer(self)
        self._analysis_timer.setSingleShot(True)
        self._analysis_timer.setInterval(75)
        self._analysis_timer.timeout.connect(self._submit_analysis)

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
        self.level.setToolTip("Original image display level; measurements use original samples.")
        self.width.setToolTip("Original image display width; difference uses its own range.")
        self.readout = QtWidgets.QLabel("Pixel: —", central)
        self.readout.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored,
                                   QtWidgets.QSizePolicy.Policy.Preferred)
        for widget in (self.fit_button, self.level, self.width):
            controls.addWidget(widget)
        controls.addWidget(self.readout, 1)
        outer.addLayout(controls)

        comparison_controls = QtWidgets.QHBoxLayout()
        self.reference = QtWidgets.QComboBox(central)
        self.candidate = QtWidgets.QComboBox(central)
        self.comparison = QtWidgets.QComboBox(central)
        self.comparison.addItem("Original images", None)
        self.comparison.addItem("Signed difference", "signed")
        self.comparison.addItem("Absolute difference", "absolute")
        self.declare_grid = QtWidgets.QCheckBox("Declare matching grids", central)
        self.declare_grid.setToolTip("Explicitly declare pixel correspondence when both grid IDs are absent.")
        self.declare_units = QtWidgets.QCheckBox("Declare common units", central)
        self.declare_units.setToolTip("Explicitly declare common intensity units when both units are absent.")
        comparison_controls.addWidget(QtWidgets.QLabel("Reference", central))
        comparison_controls.addWidget(self.reference)
        comparison_controls.addWidget(QtWidgets.QLabel("Candidate", central))
        comparison_controls.addWidget(self.candidate)
        for widget in (self.comparison, self.declare_grid, self.declare_units):
            comparison_controls.addWidget(widget)
        outer.addLayout(comparison_controls)
        self.analysis_status = QtWidgets.QLabel(central)
        self.analysis_status.setWordWrap(True)
        self.analysis_status.setMinimumHeight(30)
        outer.addWidget(self.analysis_status)
        self.graphics = ImageGraphicsWidget(central)
        outer.addWidget(self.graphics, 1)

        roi_controls = QtWidgets.QHBoxLayout()
        self.roi_plane = QtWidgets.QComboBox(central)
        self.rectangle_button = QtWidgets.QPushButton("Rectangle ROI", central)
        self.ellipse_button = QtWidgets.QPushButton("Ellipse ROI", central)
        self.roi_selector = QtWidgets.QComboBox(central)
        self.remove_roi_button = QtWidgets.QPushButton("Remove ROI", central)
        self.refresh_button = QtWidgets.QPushButton("Refresh", central)
        roi_controls.addWidget(QtWidgets.QLabel("ROI pane", central))
        for widget in (self.roi_plane, self.rectangle_button, self.ellipse_button,
                       self.roi_selector, self.remove_roi_button, self.refresh_button):
            roi_controls.addWidget(widget)
        outer.addLayout(roi_controls)
        self.stats_table = QtWidgets.QTableWidget(0, 6, central)
        self.stats_table.setHorizontalHeaderLabels(["ROI / pane", "Units", "Mean", "SD (population)",
                                                    "Finite N", "Excluded"])
        self.stats_table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.stats_table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.stats_table.setMaximumHeight(175)
        outer.addWidget(self.stats_table)
        self.setCentralWidget(central)
        self.fit_button.clicked.connect(self.fit)
        self.level.valueChanged.connect(self._levels_changed)
        self.width.valueChanged.connect(self._levels_changed)
        self.graphics.scene().sigMouseMoved.connect(self._mouse_moved)
        for combo in (self.reference, self.candidate, self.comparison):
            combo.currentIndexChanged.connect(self._comparison_changed)
        self.declare_grid.toggled.connect(self._comparison_changed)
        self.declare_units.toggled.connect(self._comparison_changed)
        self.rectangle_button.clicked.connect(lambda: self.add_roi("rectangle"))
        self.ellipse_button.clicked.connect(lambda: self.add_roi("ellipse"))
        self.remove_roi_button.clicked.connect(lambda: self.remove_roi(self.roi_selector.currentData()))
        self.refresh_button.clicked.connect(self._schedule_analysis)

    @property
    def analysis_bytes(self):
        """Retained derived data and conservative render conversion reservation."""
        return 0 if self._difference is None else self._difference.nbytes * 2

    def install_snapshot(self, snapshot) -> None:
        """Install SNAPSHOT, preserving geometry only for declared correspondence."""
        planes = getattr(snapshot, "planes", None)
        if not isinstance(planes, Mapping) or not 1 <= len(planes) <= 4:
            raise ValueError("snapshot must contain 1 to 4 planes")
        numerical = bool(getattr(snapshot, "numerical", True))
        if any(not isinstance(name, str) or not isinstance(array, np.ndarray)
               or (numerical and not scalar_plane(array))
               or (not numerical and array.ndim != 2 and not
                   (array.ndim == 3 and array.shape[-1] in (3, 4)))
               for name, array in planes.items()):
            raise ValueError("snapshot planes have unsupported shape or dtype")
        manifest = getattr(snapshot, "manifest", None) or {}
        new_meta = _plane_metadata(manifest)
        old = self._snapshot
        old_manifest = getattr(old, "manifest", None) or {}
        preserve = bool(old is not None and old.numerical and numerical
                        and old.workspace == snapshot.workspace
                        and old.generation == snapshot.generation
                        and old_manifest.get("sample_id")
                        and old_manifest.get("sample_id") == manifest.get("sample_id")
                        and set(old.planes) == set(planes)
                        and all(correspondence(old.planes[name], planes[name],
                                               self._metadata.get(name, {}), new_meta.get(name, {}),
                                               declared=self.declare_grid.isChecked())
                                for name in planes))
        self._worker.cancel(self._analysis_owner)
        self._analysis_token += 1
        self._analysis_timer.stop()
        self._difference = self._difference_key = None
        self._statistics = {}
        if not preserve:
            self._regions.clear()
            self._difference_levels.clear()
            self.declare_grid.blockSignals(True)
            self.declare_units.blockSignals(True)
            self.declare_grid.setChecked(False)
            self.declare_units.setChecked(False)
            self.declare_grid.blockSignals(False)
            self.declare_units.blockSignals(False)
        self._snapshot = snapshot
        self._metadata = new_meta
        names = list(planes)
        for combo, default in ((self.reference, names[0]),
                               (self.candidate, names[min(1, len(names) - 1)])):
            previous = combo.currentText()
            combo.blockSignals(True)
            combo.clear()
            combo.addItems(names)
            combo.setCurrentText(previous if preserve and previous in names else default)
            combo.blockSignals(False)
        for widget in (self.reference, self.candidate, self.comparison, self.declare_grid,
                       self.declare_units, self.rectangle_button, self.ellipse_button,
                       self.roi_plane, self.refresh_button):
            widget.setEnabled(numerical)
        self.level.setEnabled(numerical)
        self.width.setEnabled(numerical)
        self._render(preserve=preserve)
        self._schedule_analysis()

    def _comparison_error(self):
        if not self._snapshot.numerical:
            return "Rendered image: differences and quantitative ROI statistics are unavailable."
        names = self.reference.currentText(), self.candidate.currentText()
        if names[0] == names[1]:
            return "Select distinct reference and candidate images."
        manifest = self._snapshot.manifest or {}
        return comparison_error(self._snapshot.planes[names[0]], self._snapshot.planes[names[1]],
                                self._metadata.get(names[0], {}), self._metadata.get(names[1], {}),
                                manifest.get("sample_id"), manifest.get("sample_id"),
                                declared_grid=self.declare_grid.isChecked(),
                                declared_units=self.declare_units.isChecked())

    def _comparison_key(self):
        return (id(self._snapshot), self.reference.currentText(), self.candidate.currentText(),
                self.comparison.currentData())

    def _comparison_changed(self, *_):
        if self._snapshot is None:
            return
        self._difference = self._difference_key = None
        self._render(preserve=True)
        self._schedule_analysis()

    def _display_name(self, name):
        if name != DIFFERENCE:
            return name
        order = self.candidate.currentText() + " − " + self.reference.currentText()
        return "|" + order + "|" if self.comparison.currentData() == "absolute" else order

    def _meta(self, name):
        if name == DIFFERENCE:
            name = self.candidate.currentText()
        return self._metadata.get(name, {})

    def _corresponds(self, first, second):
        arrays = dict(self._snapshot.planes)
        if self._difference is not None:
            arrays[DIFFERENCE] = self._difference
        return (first == second or
                first in arrays and second in arrays and
                correspondence(arrays[first], arrays[second], self._meta(first), self._meta(second),
                               declared=self.declare_grid.isChecked()))

    def _render(self, *, preserve):
        cameras = {name: camera(view) for name, view in self._views.items()}
        old_levels = {name: tuple(item.getLevels()) for name, item in self._items.items()}
        if preserve and DIFFERENCE in old_levels:
            self._difference_levels[self._displayed_comparison] = old_levels[DIFFERENCE]
        for group in self._navigation_groups:
            group.dispose()
        self._navigation_groups.clear()
        for key in list(self._roi_items):
            self._dispose_roi(key)
        for item in self._items.values():
            item.deleteLater()
        self._items.clear()
        self._views.clear()
        self.graphics.clear()
        numerical = self._snapshot.numerical
        self._planes = dict(self._snapshot.planes)
        if self._difference is not None:
            self._planes = {name: self._snapshot.planes[name] for name in
                            (self.reference.currentText(), self.candidate.currentText())}
            self._planes[DIFFERENCE] = self._difference
        extrema = [_sample_extrema(array) for array in self._snapshot.planes.values() if numerical]
        extrema = [value for value in extrema if value is not None]
        low = min((value[0] for value in extrema), default=0.0)
        high = max((value[1] for value in extrema), default=1.0)
        if high <= low:
            high = low + 1.0
        if preserve and old_levels:
            low = self.level.value() - self.width.value() / 2
            high = self.level.value() + self.width.value() / 2
        for index, (name, array) in enumerate(self._planes.items()):
            row, col = divmod(index, 2)
            units = self._meta(name).get("units") or "unspecified units"
            title = self._display_name(name) + (" [" + units + "]" if numerical else " (rendered image)")
            self.graphics.addLabel(title, row=row * 2, col=col)
            view = ImageViewBox()
            self.graphics.addItem(view, row=row * 2 + 1, col=col)
            view.setMenuEnabled(False)
            levels = (low, high) if numerical else (0.0, 255.0)
            if name == DIFFERENCE:
                bounds = _sample_extrema(array) or (0.0, 1.0)
                limit = max(abs(bounds[0]), abs(bounds[1]), 1.0e-12)
                levels = (0.0 if self.comparison.currentData() == "absolute" else -limit, limit)
                key = self._comparison_key()[1:]
                levels = self._difference_levels.get(key, levels)
                self._displayed_comparison = key
            item = pg.ImageItem(array, axisOrder="row-major", autoLevels=False, levels=levels)
            item.setAutoDownsample(False)
            view.addItem(item)
            view.invertY(True)
            self._views[name], self._items[name] = view, item
            self._levels[name] = levels
        names = list(self._planes)
        groups = []
        for name in names:
            matching = next((group for group in groups if numerical
                             and self._corresponds(group[0], name)), None)
            if matching is None:
                groups.append([name])
            else:
                matching.append(name)
        self._linked = numerical and len(groups) == 1 and bool(self._meta(names[0]).get("grid_id")
                                                               or self.declare_grid.isChecked())
        for members in groups:
            group = NavigationGroup([self._views[name] for name in members])
            self._navigation_groups.append(group)
            previous = next((cameras[name] for name in members if name in cameras), None)
            if preserve and previous is not None:
                group.restore(previous)
            else:
                group.fit()
        self.level.blockSignals(True)
        self.width.blockSignals(True)
        self.level.setValue((low + high) / 2)
        self.width.setValue(max(high - low, 1.0e-12))
        self.level.blockSignals(False)
        self.width.blockSignals(False)
        selected = self.roi_plane.currentData()
        self.roi_plane.clear()
        for name in names:
            self.roi_plane.addItem(self._display_name(name), name)
        index = self.roi_plane.findData(selected)
        if index >= 0:
            self.roi_plane.setCurrentIndex(index)
        self._rebuild_rois()

    def _targets(self, region):
        return tuple(name for name in self._planes if self._corresponds(region.plane, name))

    def _rebuild_rois(self):
        wanted = {(region.identifier, name) for region in self._regions.values()
                  for name in self._targets(region)}
        for key in list(self._roi_items):
            if key not in wanted:
                self._dispose_roi(key)
        selected = self.roi_selector.currentData()
        self.roi_selector.clear()
        for region in self._regions.values():
            self.roi_selector.addItem(region.name, region.identifier)
            for name in self._targets(region):
                if (region.identifier, name) in self._roi_items:
                    continue
                cls = pg.RectROI if region.kind == "rectangle" else pg.EllipseROI
                item = cls((region.x, region.y), (region.width, region.height),
                           pen=pg.intColor(region.identifier, hues=MAX_ROIS),
                           removable=True, rotatable=False)
                # EllipseROI includes a rotation handle even with rotatable=False.
                for handle in list(item.handles):
                    if handle["type"] in ("r", "sr"):
                        item.removeHandle(handle["item"])
                        handle["item"].setParentItem(None)
                        handle["item"].deleteLater()
                item.setZValue(20)
                self._views[name].addItem(item, ignoreBounds=True)
                self._roi_items[region.identifier, name] = item
                item.sigRegionChanged.connect(
                    lambda changed, identifier=region.identifier: self._roi_changed(identifier, changed))
                item.sigRemoveRequested.connect(
                    lambda _item, identifier=region.identifier: self.remove_roi(identifier))
        index = self.roi_selector.findData(selected)
        if index >= 0:
            self.roi_selector.setCurrentIndex(index)
        self.remove_roi_button.setEnabled(bool(self._regions))
        allowed = self._snapshot.numerical and len(self._regions) < MAX_ROIS
        self.rectangle_button.setEnabled(allowed)
        self.ellipse_button.setEnabled(allowed)

    def _dispose_roi(self, key):
        """Break signal cycles and let Qt retire the ROI and its child handles."""
        item = self._roi_items.pop(key)
        item.sigRegionChanged.disconnect()
        item.sigRemoveRequested.disconnect()
        self._views[key[1]].removeItem(item)
        item.deleteLater()

    def add_roi(self, kind):
        """Add a centered ROI in the selected pane; drag it or its resize handle."""
        if not self._snapshot or not self._snapshot.numerical or len(self._regions) >= MAX_ROIS:
            return
        name = self.roi_plane.currentData()
        array = self._planes[name]
        view = self._views[name].viewRect()
        width, height = max(1, min(array.shape[1], view.width()) / 3), max(1, min(array.shape[0], view.height()) / 3)
        x = min(max(view.center().x() - width / 2, 0), array.shape[1] - width)
        y = min(max(view.center().y() - height / 2, 0), array.shape[0] - height)
        self._next_region += 1
        identifier = self._next_region
        source = self.candidate.currentText() if name == DIFFERENCE else name
        self._regions[identifier] = Region(identifier, f"ROI {identifier} ({kind})", source,
                                           kind, x, y, width, height)
        self._rebuild_rois()
        self.roi_selector.setCurrentIndex(self.roi_selector.findData(identifier))
        self._schedule_analysis()

    def remove_roi(self, identifier):
        if identifier in self._regions:
            del self._regions[identifier]
            self._rebuild_rois()
            self._schedule_analysis()

    def _roi_changed(self, identifier, item):
        if self._syncing_rois or identifier not in self._regions:
            return
        pos, size = item.pos(), item.size()
        self._regions[identifier] = replace(self._regions[identifier], x=float(pos.x()),
                                            y=float(pos.y()), width=float(size.x()), height=float(size.y()))
        self._syncing_rois = True
        try:
            for (other_id, _name), other in self._roi_items.items():
                if other_id == identifier and other is not item:
                    other.setPos(pos)
                    other.setSize(size)
        finally:
            self._syncing_rois = False
        self._schedule_analysis()

    def _schedule_analysis(self, *_):
        self._analysis_token += 1
        self._statistics = {}
        self.stats_table.setRowCount(0)
        self._worker.cancel(self._analysis_owner)
        self._analysis_timer.stop()
        if self._closed or self._snapshot is None:
            return
        if not self._snapshot.numerical:
            self.analysis_status.setText(self._comparison_error())
            return
        error = self._comparison_error() if self.comparison.currentData() else None
        if error:
            self.analysis_status.setText(error)
        elif self.comparison.currentData() or self._regions:
            self.analysis_status.setText("Computing from original samples…")
        else:
            self.analysis_status.setText("Select a difference or add an ROI; drag its body to move and handle to resize.")
        if self._regions or self.comparison.currentData() and not error:
            self._analysis_timer.start()

    def _submit_analysis(self):
        if self._closed or self._snapshot is None:
            return
        compare = bool(self.comparison.currentData() and not self._comparison_error())
        reference = self.reference.currentText() if compare else None
        candidate = self.candidate.currentText() if compare else None
        targets = {roi.identifier: self._targets(roi) for roi in self._regions.values()}
        if compare:
            for roi in self._regions.values():
                if self._corresponds(roi.plane, candidate):
                    targets[roi.identifier] = tuple(dict.fromkeys((*targets[roi.identifier], DIFFERENCE)))
        self._worker.submit(AnalysisJob(self._analysis_owner, self._analysis_token, self._snapshot,
                                       tuple(self._regions.values()), targets, reference, candidate,
                                       self.comparison.currentData() == "absolute",
                                       self._difference if self._difference_key == self._comparison_key() else None))

    @QtCore.Slot(object, int, object, str)
    def _analysis_ready(self, owner, token, result, error):
        if owner is not self._analysis_owner or self._closed or token != self._analysis_token:
            return
        if error:
            self.analysis_status.setText(error)
            return
        if result is None:
            return
        derived, self._statistics = result
        if derived is not None and self._difference is not derived:
            self._difference = derived
            self._difference_key = self._comparison_key()
            self._render(preserve=True)
        rows = [(key, value) for key, value in self._statistics.items() if key[1] in self._planes]
        self.stats_table.setRowCount(len(rows))
        for row, ((identifier, name), value) in enumerate(rows):
            region = self._regions[identifier]
            values = [region.name + " / " + self._display_name(name),
                      self._meta(name).get("units") or "unspecified",
                      "unavailable" if value.mean is None else f"{value.mean:.8g}",
                      "unavailable" if value.sd is None else f"{value.sd:.8g}",
                      str(value.finite), str(value.excluded)]
            for col, text in enumerate(values):
                self.stats_table.setItem(row, col, QtWidgets.QTableWidgetItem(text))
        comparison_error_text = self._comparison_error() if self.comparison.currentData() else None
        self.analysis_status.setText(comparison_error_text or
                                    "Local original-sample measurements; SD is population SD (ddof=0).")

    def _levels_changed(self) -> None:
        center, width = self.level.value(), self.width.value()
        for name, item in self._items.items():
            if name != DIFFERENCE:
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
                if self._snapshot.numerical:
                    self.readout.setText("%s [%d,%d] = %s" %
                                         (self._display_name(name), row, col, array[row, col]))
                else:
                    self.readout.setText("%s [%d,%d] (numeric unavailable)" % (name, row, col))
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
        if self._closed:
            super().closeEvent(event)
            return
        self._closed = True
        self._analysis_token += 1
        self._analysis_timer.stop()
        self._worker.cancel(self._analysis_owner)
        self._worker.ready.disconnect(self._analysis_ready)
        if self._owns_worker:
            self._worker.shutdown()
        for group in self._navigation_groups:
            group.dispose()
        self._navigation_groups.clear()
        for key in list(self._roi_items):
            self._dispose_roi(key)
        for item in self._items.values():
            item.deleteLater()
        self._items.clear()
        self._views.clear()
        self.graphics.clear()
        self._planes.clear()
        self._snapshot = self._difference = None
        self.closed.emit()
        super().closeEvent(event)
