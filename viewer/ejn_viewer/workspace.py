"""Qt workspace for local numerical snapshots, differences and measurements."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import replace
import html
import math

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtGui, QtWidgets

from .analysis import (DIFFERENCE, MAX_ROIS, Region, comparison_error,
                       correspondence, scalar_plane)
from .analysis_worker import AnalysisJob, AnalysisWorker
from .navigation import ImageGraphicsWidget, ImageViewBox, NavigationGroup, camera
from .memory import AnalysisSource, MAX_MEMORY, merge_allocations, source_allocations
from .magnifier import Magnifier, MAX_PATCH_BYTES


MAX_LEVEL_SAMPLE = 65_536
PINNED = "\0pinned"


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


class StatusLabel(QtWidgets.QLabel):
    """Single-line status that cannot enlarge the window; hover for full text."""

    def __init__(self, text="", parent=None):
        super().__init__(parent)
        self.setTextFormat(QtCore.Qt.TextFormat.PlainText)
        self.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored,
                           QtWidgets.QSizePolicy.Policy.Fixed)
        self.setText(text)

    def setText(self, text):
        super().setText(text)
        self.setToolTip(text)

    def paintEvent(self, event):
        painter = QtGui.QPainter(self)
        text = self.fontMetrics().elidedText(self.text(), QtCore.Qt.TextElideMode.ElideRight,
                                            self.contentsRect().width())
        painter.setPen(self.palette().color(self.foregroundRole()))
        painter.drawText(self.contentsRect(), self.alignment(), text)


class SettingsMenu(QtWidgets.QMenu):
    """A popup form whose controls participate in keyboard focus traversal."""

    def focusNextPrevChild(self, forward):
        content = self.actions()[0].defaultWidget()
        controls = [widget for widget in content.findChildren(QtWidgets.QWidget)
                    if widget.focusPolicy() & QtCore.Qt.FocusPolicy.TabFocus
                    and widget.isEnabled() and widget.isVisible()]
        if not controls:
            return False
        focused = QtWidgets.QApplication.focusWidget()
        index = controls.index(focused) if focused in controls else (-1 if forward else 0)
        reason = (QtCore.Qt.FocusReason.TabFocusReason if forward
                  else QtCore.Qt.FocusReason.BacktabFocusReason)
        controls[(index + (1 if forward else -1)) % len(controls)].setFocus(reason)
        return True

    def showEvent(self, event):
        super().showEvent(event)
        self.focusNextPrevChild(True)


def _settings_menu(button, content):
    """Keep related, keyboard-accessible controls together in one popup."""
    menu = SettingsMenu(button)
    action = QtWidgets.QWidgetAction(menu)
    action.setDefaultWidget(content)
    menu.addAction(action)
    button.setPopupMode(QtWidgets.QToolButton.ToolButtonPopupMode.InstantPopup)
    button.setMenu(menu)


class WorkspaceWindow(QtWidgets.QMainWindow):
    """Persistent row-major panes; all numerical analysis runs off the GUI."""

    closed = QtCore.Signal()

    def __init__(self, parent=None, *, analysis_worker=None, admit=None):
        super().__init__(parent)
        self.setWindowTitle("EJN viewer")
        self.resize(1100, 800)
        self._snapshot = None
        self._pinned = None
        self._pinned_name = None
        self._analysis_source = None
        self._pending_snapshot = None
        self._blinking = False
        self._draw_kind = None
        self._drawing_region = None
        self._crosshairs = {}
        self._cursor = None
        self._rendered_selection = None
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
        self._admit = admit or (lambda: sum(merge_allocations(
            self.allocations, self._worker.allocations).values()) <= MAX_MEMORY)
        if self._owns_worker:
            self._worker.admit = self._admit
        self._worker.ready.connect(self._analysis_ready)
        self._analysis_timer = QtCore.QTimer(self)
        self._analysis_timer.setSingleShot(True)
        self._analysis_timer.setInterval(75)
        self._analysis_timer.timeout.connect(self._submit_analysis)
        self._cursor_timer = QtCore.QTimer(self)
        self._cursor_timer.setSingleShot(True)
        self._cursor_timer.setInterval(25)
        self._cursor_timer.timeout.connect(self._update_magnifier)
        self._pending_snapshot_timer = QtCore.QTimer(self)
        self._pending_snapshot_timer.setSingleShot(True)
        self._pending_snapshot_timer.setInterval(75)
        self._pending_snapshot_timer.timeout.connect(self._adopt_pending_snapshot)

        central = QtWidgets.QWidget(self)
        outer = QtWidgets.QVBoxLayout(central)
        outer.setContentsMargins(6, 6, 6, 6)
        outer.setSpacing(4)
        controls = QtWidgets.QHBoxLayout()
        controls.setSpacing(4)
        self.fit_button = QtWidgets.QToolButton(central)
        self.fit_button.setText("Fit")
        self.fit_button.setToolTip("Fit all images (F)")
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
        for spin in (self.level, self.width):
            spin.setMinimumWidth(95)
            spin.setMaximumWidth(150)
        self.readout = StatusLabel("Pixel: —", central)
        for widget in (self.fit_button, self.level, self.width):
            controls.addWidget(widget)
        outer.addLayout(controls)

        self.compare_button = QtWidgets.QToolButton(central)
        self.compare_button.setText("Compare")
        self.compare_button.setToolTip("Select images, differences and a pinned reference")
        comparison_panel = QtWidgets.QWidget()
        comparison_controls = QtWidgets.QFormLayout(comparison_panel)
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
        comparison_controls.addRow("Reference", self.reference)
        comparison_controls.addRow("Candidate", self.candidate)
        comparison_controls.addRow("Display", self.comparison)
        self.pin_button = QtWidgets.QPushButton("Pin reference", central)
        self.pin_button.setCheckable(True)
        self.freeze_button = QtWidgets.QPushButton("Freeze updates", central)
        self.freeze_button.setCheckable(True)
        self.freeze_button.setToolTip("Keep the current images; discard updates until unfrozen.")
        self.blink_button = QtWidgets.QPushButton("Hold to blink (B)", central)
        self.blink_button.setToolTip("While held, show the reference in the candidate pane.")
        comparison_controls.addRow(self.pin_button)
        comparison_controls.addRow(self.blink_button)
        comparison_controls.addRow(self.declare_grid)
        comparison_controls.addRow(self.declare_units)
        _settings_menu(self.compare_button, comparison_panel)
        controls.addWidget(self.compare_button)

        self.options_button = QtWidgets.QToolButton(central)
        self.options_button.setText("Options")
        options_panel = QtWidgets.QWidget()
        options_controls = QtWidgets.QVBoxLayout(options_panel)
        self.magnifier_toggle = QtWidgets.QCheckBox("Magnifier", central)
        options_controls.addWidget(self.magnifier_toggle)
        options_controls.addWidget(self.freeze_button)
        help_label = QtWidgets.QLabel("F: fit images · B: hold to blink\n"
                                     "Drag / two-finger scroll: pan\n"
                                     "Wheel / pinch: zoom", options_panel)
        options_controls.addWidget(help_label)
        _settings_menu(self.options_button, options_panel)
        self.publication_status = StatusLabel(parent=central)
        self.analysis_status = StatusLabel(parent=central)
        self.graphics = ImageGraphicsWidget(central)
        self.graphics.setFocusPolicy(QtCore.Qt.FocusPolicy.StrongFocus)
        self.graphics.setMinimumHeight(180)
        outer.addWidget(self.graphics, 1)
        self.magnifier = Magnifier(central)
        outer.addWidget(self.magnifier)
        self.magnifier.hide()

        self.measurements_button = QtWidgets.QToolButton(central)
        self.measurements_button.setText("Measurements")
        self.measurements_button.setCheckable(True)
        self.measurements_button.setToolTip("Show ROI tools and statistics")
        self.measurements_panel = QtWidgets.QWidget(central)
        measurements_layout = QtWidgets.QVBoxLayout(self.measurements_panel)
        measurements_layout.setContentsMargins(0, 4, 0, 0)
        measurements_layout.setSpacing(4)
        roi_controls = QtWidgets.QHBoxLayout()
        self.roi_plane = QtWidgets.QComboBox(central)
        self.rectangle_button = QtWidgets.QPushButton("Rectangle ROI", central)
        self.ellipse_button = QtWidgets.QPushButton("Ellipse ROI", central)
        self.roi_selector = QtWidgets.QComboBox(central)
        for combo in (self.reference, self.candidate, self.roi_plane, self.roi_selector):
            combo.setMinimumContentsLength(8)
            combo.setSizeAdjustPolicy(QtWidgets.QComboBox.SizeAdjustPolicy.AdjustToMinimumContentsLengthWithIcon)
            combo.setMaximumWidth(220)
        self.remove_roi_button = QtWidgets.QPushButton("Remove ROI", central)
        self.refresh_button = QtWidgets.QPushButton("Refresh", central)
        roi_controls.addWidget(QtWidgets.QLabel("ROI pane", central))
        for widget in (self.roi_plane, self.rectangle_button, self.ellipse_button,
                       self.roi_selector, self.remove_roi_button, self.refresh_button):
            roi_controls.addWidget(widget)
        measurements_layout.addLayout(roi_controls)
        roi_edit_controls = QtWidgets.QHBoxLayout()
        self.draw_button = QtWidgets.QToolButton(central)
        self.draw_button.setText("Draw ROI")
        self.draw_button.setPopupMode(QtWidgets.QToolButton.ToolButtonPopupMode.InstantPopup)
        menu = QtWidgets.QMenu(self.draw_button)
        for kind in ("rectangle", "ellipse"):
            action = menu.addAction("Draw " + kind)
            action.triggered.connect(lambda _checked=False, shape=kind: self.arm_roi(shape))
        menu.addAction("Cancel drawing", self.cancel_drawing)
        self.draw_button.setMenu(menu)
        controls.addWidget(self.draw_button)
        controls.addWidget(self.measurements_button)
        controls.addStretch(1)
        controls.addWidget(self.options_button)
        self.roi_name = QtWidgets.QLineEdit(central)
        self.roi_name.setPlaceholderText("ROI name (Enter to rename)")
        self.roi_name.setMaxLength(128)
        self.copy_button = QtWidgets.QPushButton("Copy statistics", central)
        roi_edit_controls.addWidget(self.roi_name, 1)
        self.roi_name.setToolTip("Enter to rename. Arrow keys on the image nudge the ROI; Shift moves 10 pixels.")
        roi_edit_controls.addWidget(self.copy_button)
        measurements_layout.addLayout(roi_edit_controls)
        self.stats_table = QtWidgets.QTableWidget(0, 6, central)
        self.stats_table.setHorizontalHeaderLabels(["ROI / pane", "Units", "Mean", "SD (population)",
                                                    "Finite N", "Excluded"])
        self.stats_table.setEditTriggers(QtWidgets.QAbstractItemView.EditTrigger.NoEditTriggers)
        self.stats_table.horizontalHeader().setSectionResizeMode(QtWidgets.QHeaderView.ResizeMode.Stretch)
        self.stats_table.setMaximumHeight(150)
        measurements_layout.addWidget(self.stats_table)
        outer.addWidget(self.measurements_panel)
        self.measurements_panel.hide()
        self.measurements_button.toggled.connect(self.measurements_panel.setVisible)
        outer.addWidget(self.analysis_status)
        status = QtWidgets.QHBoxLayout()
        status.addWidget(self.readout, 1)
        status.addWidget(self.publication_status, 1)
        self.publication_status.setAlignment(QtCore.Qt.AlignmentFlag.AlignRight |
                                             QtCore.Qt.AlignmentFlag.AlignVCenter)
        outer.addLayout(status)
        self.setCentralWidget(central)
        self.fit_button.clicked.connect(self.fit)
        self.level.valueChanged.connect(self._levels_changed)
        self.width.valueChanged.connect(self._levels_changed)
        self.graphics.scene().sigMouseMoved.connect(self._mouse_moved)
        self.graphics.roiDragged.connect(self._draw_region)
        for combo in (self.reference, self.candidate, self.comparison):
            combo.currentIndexChanged.connect(self._comparison_changed)
        self.declare_grid.toggled.connect(self._comparison_changed)
        self.declare_units.toggled.connect(self._comparison_changed)
        self.rectangle_button.clicked.connect(lambda: self.add_roi("rectangle"))
        self.ellipse_button.clicked.connect(lambda: self.add_roi("ellipse"))
        self.remove_roi_button.clicked.connect(lambda: self.remove_roi(self.roi_selector.currentData()))
        self.refresh_button.clicked.connect(self._schedule_analysis)
        self.pin_button.toggled.connect(self._pin_toggled)
        self.freeze_button.toggled.connect(self._publication_status)
        self.blink_button.pressed.connect(lambda: self._blink(True))
        self.blink_button.released.connect(lambda: self._blink(False))
        self.magnifier_toggle.toggled.connect(self._magnifier_toggled)
        self.roi_selector.currentIndexChanged.connect(self._roi_selection_changed)
        self.roi_name.returnPressed.connect(lambda: self.rename_roi(self.roi_name.text()))
        self.copy_button.clicked.connect(self.copy_statistics)
        self._roi_shortcuts = []
        for key, dx, dy in (("Left", -1, 0), ("Right", 1, 0), ("Up", 0, -1), ("Down", 0, 1)):
            for prefix, step in (("", 1), ("Shift+", 10)):
                shortcut = QtGui.QShortcut(QtGui.QKeySequence(prefix + key), self.graphics)
                shortcut.setContext(QtCore.Qt.ShortcutContext.WidgetWithChildrenShortcut)
                shortcut.activated.connect(lambda x=dx * step, y=dy * step: self.nudge_roi(x, y))
                self._roi_shortcuts.append(shortcut)

    @property
    def analysis_bytes(self):
        """Retained derived data and conservative render conversion reservation."""
        return 0 if self._difference is None else self._difference.nbytes * 2

    @property
    def frozen(self):
        return self.freeze_button.isChecked()

    @property
    def allocations(self):
        result = {}
        result["magnifier", id(self)] = MAX_PATCH_BYTES
        for snapshot in (self._snapshot, self._pinned):
            if snapshot is not None:
                result = merge_allocations(result, source_allocations(snapshot))
        for name, array in self._planes.items():
            result["render", id(self), name] = array.shape[0] * array.shape[1] * 8
        if self._difference is not None:
            result["array", id(self._difference)] = self._difference.nbytes
        if DIFFERENCE in self._planes:
            array = self._planes[DIFFERENCE]
            result["array", id(array)] = array.nbytes
        if self._pending_snapshot is not None:
            result = merge_allocations(result, source_allocations(self._pending_snapshot))
            result["pending-render", id(self)] = sum(array.shape[0] * array.shape[1] * 8
                for array in self._pending_snapshot.planes.values())
        return result

    def _all_planes(self):
        arrays = dict(self._snapshot.planes)
        if self._pinned is not None:
            arrays[PINNED] = self._pinned.planes[self._pinned_name]
        return arrays

    def _update_analysis_source(self):
        sources = tuple({id(value): value for value in (self._snapshot, self._pinned)
                         if value is not None}.values())
        self._analysis_source = AnalysisSource(self._all_planes(), sources)

    def _reference_name(self):
        return self.reference.currentData()

    def _candidate_name(self):
        return self.candidate.currentData()

    def _sample(self, name):
        snapshot = self._pinned if name == PINNED else self._snapshot
        return (snapshot.manifest or {}).get("sample_id")

    def _publication_status(self, *_):
        if self._snapshot is None:
            return
        state = "Frozen: new updates are skipped" if self.frozen else "Following latest updates"
        execution = getattr(self._snapshot, "execution", "")
        if execution:
            state += " · " + execution
        if self._pinned is not None:
            state += " · pinned " + self._pinned_name + " / " + getattr(self._pinned, "execution", "saved evaluation")
        if self._blinking:
            state += " · showing reference in candidate pane"
        if self._pending_snapshot is not None:
            state += " · new evaluation ready after drag"
        self.publication_status.setText(state)
        self.publication_status.setToolTip(state)

    def _populate_selectors(self, preserve=True):
        names = list(self._snapshot.planes)
        for combo, default in ((self.reference, names[0]),
                               (self.candidate, names[min(1, len(names) - 1)])):
            previous = combo.currentData()
            combo.blockSignals(True)
            combo.clear()
            for name in names:
                combo.addItem(name, name)
            if combo is self.reference and self._pinned is not None:
                combo.addItem("Pinned: " + self._pinned_name, PINNED)
            index = combo.findData(previous) if preserve else -1
            combo.setCurrentIndex(index if index >= 0 else combo.findData(default))
            combo.blockSignals(False)

    def _pin_toggled(self, checked):
        if self._snapshot is None:
            return
        self._blink(False)
        if checked:
            name = self._reference_name()
            if name == PINNED or not self._snapshot.numerical:
                return
            if self._snapshot.planes[name].flags.writeable:
                self.pin_button.blockSignals(True)
                self.pin_button.setChecked(False)
                self.pin_button.blockSignals(False)
                self.analysis_status.setText("Pinning requires an immutable loaded snapshot.")
                return
            self._pinned, self._pinned_name = self._snapshot, name
            # Promotion shares source bytes but adds a second displayed pane
            # for a single-plane publication. Admit its render buffers first.
            previous_planes, previous_difference = self._planes, self._difference
            self._planes = {PINNED: self._pinned.planes[name],
                            self._candidate_name(): self._snapshot.planes[self._candidate_name()]}
            self._difference = None
            allowed = self._admit()
            self._planes, self._difference = previous_planes, previous_difference
            if not allowed:
                self._pinned = self._pinned_name = None
                self.pin_button.blockSignals(True)
                self.pin_button.setChecked(False)
                self.pin_button.blockSignals(False)
                self.analysis_status.setText("Pinning exceeds the local memory budget.")
                return
        else:
            previous_pin, previous_name = self._pinned, self._pinned_name
            previous_planes, previous_difference = self._planes, self._difference
            self._pinned = self._pinned_name = None
            self._planes, self._difference = dict(self._snapshot.planes), None
            allowed = self._admit()
            self._pinned, self._pinned_name = previous_pin, previous_name
            self._planes, self._difference = previous_planes, previous_difference
            if not allowed:
                self.pin_button.blockSignals(True)
                self.pin_button.setChecked(True)
                self.pin_button.blockSignals(False)
                self.analysis_status.setText("This display exceeds the local memory budget; keep the reference pinned or close another workspace.")
                return
            replacement = self._candidate_name()
            for identifier, region in list(self._regions.items()):
                if region.plane == PINNED:
                    if self._corresponds(PINNED, replacement):
                        self._regions[identifier] = replace(region, plane=replacement)
                    else:
                        del self._regions[identifier]
            self._pinned = self._pinned_name = None
        self._populate_selectors()
        if checked:
            self.reference.blockSignals(True)
            self.reference.setCurrentIndex(self.reference.findData(PINNED))
            self.reference.blockSignals(False)
        self.pin_button.setText("Unpin reference" if checked else "Pin reference")
        self._update_analysis_source()
        self._comparison_changed()
        self._publication_status()

    def install_snapshot(self, snapshot) -> None:
        """Install SNAPSHOT, preserving geometry only for declared correspondence."""
        if self.frozen and self._snapshot is not None:
            return False
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
        if self._snapshot is not None and self._gesturing():
            self._pending_snapshot = snapshot
            self._pending_snapshot_timer.start()
            self._publication_status()
            return False
        self._pending_snapshot = None
        self._pending_snapshot_timer.stop()
        self.cancel_drawing()
        manifest = getattr(snapshot, "manifest", None) or {}
        self._blink(False)
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
        self._populate_selectors(preserve=preserve or self._pinned is not None)
        self._update_analysis_source()
        for widget in (self.reference, self.candidate, self.comparison, self.declare_grid,
                       self.declare_units, self.rectangle_button, self.ellipse_button,
                       self.roi_plane, self.refresh_button):
            widget.setEnabled(numerical)
        self.level.setEnabled(numerical)
        self.width.setEnabled(numerical)
        self.pin_button.setEnabled(numerical or self._pinned is not None)
        self.draw_button.setEnabled(numerical)
        self.magnifier_toggle.setEnabled(numerical)
        self.magnifier.setVisible(numerical and self.magnifier_toggle.isChecked())
        self._render(preserve=preserve)
        self._schedule_analysis()
        self._publication_status()
        self._compact_layout()
        return True

    def _adopt_pending_snapshot(self):
        if self._closed or self._pending_snapshot is None:
            return
        if self.frozen:
            self._pending_snapshot = None
            self._publication_status()
        elif self._gesturing():
            self._pending_snapshot_timer.start()
        else:
            snapshot, self._pending_snapshot = self._pending_snapshot, None
            self.install_snapshot(snapshot)

    def _comparison_error(self):
        if not self._snapshot.numerical:
            return "Rendered image: differences and quantitative ROI statistics are unavailable."
        names = self._reference_name(), self._candidate_name()
        if names[0] == names[1]:
            return "Select distinct reference and candidate images."
        arrays = self._all_planes()
        return comparison_error(arrays[names[0]], arrays[names[1]],
                                self._meta(names[0]), self._meta(names[1]),
                                self._sample(names[0]), self._sample(names[1]),
                                declared_grid=self.declare_grid.isChecked(),
                                declared_units=self.declare_units.isChecked())

    def _comparison_key(self):
        return (id(self._snapshot), self._reference_name(), self._candidate_name(),
                self.comparison.currentData(), id(self._pinned))

    def _comparison_changed(self, *_):
        if self._snapshot is None:
            return
        self.cancel_drawing()
        self._blink(False)
        previous_difference, previous_key = self._difference, self._difference_key
        self._difference = self._difference_key = None
        old_planes, self._planes = self._planes, self._display_planes()
        allowed = self._admit()
        self._planes = old_planes
        if not allowed:
            self._difference, self._difference_key = previous_difference, previous_key
            self._restore_selection()
            self.analysis_status.setText("This display exceeds the local memory budget; close another workspace first.")
            return
        self._render(preserve=True)
        self._schedule_analysis()
        self.blink_button.setEnabled(self._comparison_error() is None)

    def _display_name(self, name):
        if name == PINNED:
            return "Pinned: " + self._pinned_name
        if name != DIFFERENCE:
            return name
        order = self.candidate.currentText() + " − " + self.reference.currentText()
        return "|" + order + "|" if self.comparison.currentData() == "absolute" else order

    def _meta(self, name):
        if name == PINNED:
            return _plane_metadata(self._pinned.manifest).get(self._pinned_name, {})
        if name == DIFFERENCE:
            name = self.candidate.currentText()
        return self._metadata.get(name, {})

    def _corresponds(self, first, second):
        arrays = self._all_planes()
        if self._difference is not None:
            arrays[DIFFERENCE] = self._difference
        return (first == second or
                first in arrays and second in arrays and
                self._sample(first) == self._sample(second) and
                correspondence(arrays[first], arrays[second], self._meta(first), self._meta(second),
                               declared=self.declare_grid.isChecked()))

    def _selection(self):
        return (self._reference_name(), self._candidate_name(), self.comparison.currentIndex(),
                self.declare_grid.isChecked(), self.declare_units.isChecked())

    def _restore_selection(self):
        if self._rendered_selection is None:
            return
        reference, candidate, mode, grid, units = self._rendered_selection
        for combo, value in ((self.reference, reference), (self.candidate, candidate)):
            combo.blockSignals(True)
            combo.setCurrentIndex(combo.findData(value))
            combo.blockSignals(False)
        self.comparison.blockSignals(True)
        self.comparison.setCurrentIndex(mode)
        self.comparison.blockSignals(False)
        for widget, value in ((self.declare_grid, grid), (self.declare_units, units)):
            widget.blockSignals(True)
            widget.setChecked(value)
            widget.blockSignals(False)

    def _display_planes(self):
        planes = dict(self._snapshot.planes)
        if self._difference is not None or self._reference_name() == PINNED:
            arrays = self._all_planes()
            planes = {name: arrays[name] for name in (self._reference_name(), self._candidate_name())}
        if self._difference is not None:
            planes[DIFFERENCE] = self._difference
        return planes

    def _render(self, *, preserve):
        cameras = {name: camera(view) for name, view in self._views.items()}
        old_levels = {name: tuple(item.getLevels()) for name, item in self._items.items()}
        if preserve and DIFFERENCE in old_levels:
            self._difference_levels[self._displayed_comparison] = old_levels[DIFFERENCE]
        for group in self._navigation_groups:
            group.dispose()
        self._navigation_groups.clear()
        self.graphics._gesture_view = None
        for key in list(self._roi_items):
            self._dispose_roi(key)
        self._clear_crosshairs()
        for item in self._items.values():
            item.clear()
            item.deleteLater()
        self._items.clear()
        self._views.clear()
        self.graphics.clear()
        numerical = self._snapshot.numerical
        self._planes = self._display_planes()
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
            label = self.graphics.addLabel(html.escape(title if len(title) <= 64 else title[:61] + "…"),
                                           row=row * 2, col=col)
            label.setToolTip(title)
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
            cross = (pg.InfiniteLine(angle=90, pen=pg.mkPen("#f5dd42", width=1)),
                     pg.InfiniteLine(angle=0, pen=pg.mkPen("#f5dd42", width=1)))
            for line in cross:
                line.setZValue(30)
                line.setVisible(False)
                view.addItem(line, ignoreBounds=True)
            self._crosshairs[name] = cross
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
        self.blink_button.setEnabled(numerical and self._comparison_error() is None)
        if not preserve:
            self._cursor = None
        if self._cursor is not None and self._cursor[0] in self._planes:
            self._show_cursor(*self._cursor)
        else:
            self._clear_cursor()
        self._apply_blink_image()
        self._rendered_selection = self._selection()

    def _blink(self, enabled):
        if enabled and (self._snapshot is None or self._comparison_error() is not None):
            return
        if self._blinking == enabled:
            return
        self._blinking = enabled
        self._apply_blink_image()
        self._publication_status()
        self._update_magnifier()

    def _apply_blink_image(self):
        name = self._candidate_name()
        if name in self._items:
            array = (self._all_planes()[self._reference_name()] if self._blinking
                     else self._planes[name])
            item = self._items[name]
            item.setImage(array, autoLevels=False, levels=item.getLevels())

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

    def arm_roi(self, kind):
        if self._snapshot is None or not self._snapshot.numerical or len(self._regions) >= MAX_ROIS:
            return
        self.cancel_drawing()
        self._draw_kind = kind
        self.graphics.draw_roi = True
        self.graphics.viewport().setCursor(QtCore.Qt.CursorShape.CrossCursor)
        self.draw_button.setText("Drawing…")
        self.draw_button.setToolTip("Drag to draw a " + kind + "; Esc cancels")
        self.graphics.setFocus()

    def cancel_drawing(self):
        identifier, self._drawing_region = self._drawing_region, None
        self._draw_kind = None
        self.graphics.draw_roi = False
        self.graphics._roi_drag = None
        self.graphics.viewport().unsetCursor()
        self.draw_button.setText("Draw ROI")
        self.draw_button.setToolTip("Draw a rectangle or ellipse directly on an image")
        if identifier in self._regions:
            self.remove_roi(identifier)

    def _draw_region(self, view, start, end, finished):
        if self._draw_kind is None:
            return
        name = next((key for key, value in self._views.items() if value is view), None)
        if name is None:
            return
        if self._drawing_region is None:
            if len(self._regions) >= MAX_ROIS:
                self.cancel_drawing()
                return
            self._next_region += 1
            identifier = self._next_region
            self._drawing_region = identifier
            source = self._candidate_name() if name == DIFFERENCE else name
            self._regions[identifier] = Region(identifier, f"ROI {identifier} ({self._draw_kind})",
                                               source, self._draw_kind, start.x(), start.y(), .001, .001)
            self._rebuild_rois()
            self.roi_selector.setCurrentIndex(self.roi_selector.findData(identifier))
        item = self._roi_items[self._drawing_region, name]
        item.setPos((min(start.x(), end.x()), min(start.y(), end.y())))
        item.setSize((max(.001, abs(end.x() - start.x())), max(.001, abs(end.y() - start.y()))))
        if finished:
            self._drawing_region = None
            self.cancel_drawing()

    def _roi_selection_changed(self, *_):
        region = self._regions.get(self.roi_selector.currentData())
        self.roi_name.setText(region.name if region is not None else "")
        self.roi_name.setEnabled(region is not None)

    def rename_roi(self, name):
        identifier = self.roi_selector.currentData()
        name = name.strip()
        if identifier not in self._regions:
            return
        if not name or len(name.encode("utf-8")) > 128 or not name.isprintable():
            self.analysis_status.setText("Use a nonempty ROI name of at most 128 UTF-8 bytes, without control characters.")
            return
        self._regions[identifier] = replace(self._regions[identifier], name=name)
        self.roi_selector.setItemText(self.roi_selector.currentIndex(), name)
        self.roi_name.setText(name)
        self._render_statistics()

    def nudge_roi(self, dx, dy):
        identifier = self.roi_selector.currentData()
        item = next((item for (key, _name), item in self._roi_items.items() if key == identifier), None)
        if item is not None:
            item.setPos(item.pos() + QtCore.QPointF(dx, dy))

    def copy_statistics(self):
        rows = ["ROI\tPlane\tUnits\tMean\tSD (population)\tFinite N\tExcluded"]
        for (identifier, name), value in self._statistics.items():
            if identifier not in self._regions or name not in self._planes:
                continue
            rows.append("\t".join((self._regions[identifier].name, self._display_name(name),
                                    self._meta(name).get("units") or "unspecified",
                                    "unavailable" if value.mean is None else format(value.mean, ".17g"),
                                    "unavailable" if value.sd is None else format(value.sd, ".17g"),
                                    str(value.finite), str(value.excluded))))
        QtWidgets.QApplication.clipboard().setText("\n".join(rows))
        return "\n".join(rows)

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
        source = self._candidate_name() if name == DIFFERENCE else name
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
            self.analysis_status.setText("Ready")
        if self._regions or self.comparison.currentData() and not error:
            self._analysis_timer.start()

    def _submit_analysis(self):
        if self._closed or self._snapshot is None:
            return
        if self._gesturing():
            self._analysis_timer.start()
            return
        compare = bool(self.comparison.currentData() and not self._comparison_error())
        reference = self._reference_name() if compare else None
        candidate = self._candidate_name() if compare else None
        targets = {roi.identifier: self._targets(roi) for roi in self._regions.values()}
        if compare:
            for roi in self._regions.values():
                if self._corresponds(roi.plane, candidate):
                    targets[roi.identifier] = tuple(dict.fromkeys((*targets[roi.identifier], DIFFERENCE)))
        self._worker.submit(AnalysisJob(self._analysis_owner, self._analysis_token, self._analysis_source,
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
        derived, statistics = result
        if derived is not None and self._difference is not derived and self._gesturing():
            # Replacing ViewBoxes while Qt owns a drag target can invalidate
            # its scene object. Drop this bounded result and recompute after
            # release; no extra snapshot/difference retention is needed.
            self._analysis_timer.start()
            return
        self._statistics = statistics
        if derived is not None and self._difference is not derived:
            self._difference = derived
            self._difference_key = self._comparison_key()
            self._render(preserve=True)
        self._render_statistics()
        comparison_error_text = self._comparison_error() if self.comparison.currentData() else None
        self.analysis_status.setText(comparison_error_text or
                                    "Local original-sample measurements; SD is population SD (ddof=0).")

    def _render_statistics(self):
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

    def _gesturing(self):
        return (self._drawing_region is not None or self.graphics._roi_drag is not None
                or QtWidgets.QApplication.mouseButtons() != QtCore.Qt.MouseButton.NoButton)

    def _levels_changed(self) -> None:
        center, width = self.level.value(), self.width.value()
        for name, item in self._items.items():
            if name != DIFFERENCE:
                item.setLevels((center - width / 2.0, center + width / 2.0))
        self._update_magnifier()

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
                    self._show_cursor(name, row, col)
                else:
                    self.readout.setText("%s [%d,%d] (numeric unavailable)" % (name, row, col))
                return
        self._clear_cursor()

    def _show_cursor(self, name, row, col):
        if name not in self._planes or not (0 <= row < self._planes[name].shape[0]
                                            and 0 <= col < self._planes[name].shape[1]):
            self._clear_cursor()
            return
        self._cursor = name, row, col
        values = []
        for target, array in self._planes.items():
            linked = self._corresponds(name, target)
            for line in self._crosshairs[target]:
                line.setVisible(linked)
            if linked:
                self._crosshairs[target][0].setPos(col + .5)
                self._crosshairs[target][1].setPos(row + .5)
                values.append(self._display_name(target) + "=" + str(array[row, col]))
        text = f"[{row},{col}] " + " · ".join(values)
        self.readout.setText(text)
        self.readout.setToolTip(text)
        self._cursor_timer.start()

    def _update_magnifier(self):
        if self._closed or self._cursor is None or not self.magnifier.isVisible():
            return
        name, row, col = self._cursor
        if name not in self._planes:
            return
        planes = []
        for target, array in self._planes.items():
            if self._corresponds(name, target):
                label = self._display_name(target)
                if self._blinking and target == self._candidate_name():
                    array = self._all_planes()[self._reference_name()]
                    label += " (reference blink)"
                planes.append((target, label, array, self._items[target].getLevels()))
        self.magnifier.display(planes, row, col)

    def _clear_cursor(self):
        self._cursor = None
        self._cursor_timer.stop()
        self.readout.setText("Pixel: —")
        self.readout.setToolTip("")
        self.magnifier.clear()
        for cross in self._crosshairs.values():
            for line in cross:
                line.setVisible(False)

    def _magnifier_toggled(self, enabled):
        self._compact_layout()
        if enabled:
            self._update_magnifier()
        else:
            self.magnifier.clear()

    def _compact_layout(self):
        if not hasattr(self, "magnifier"):
            return
        roomy = self.height() >= 650
        numerical = self._snapshot is not None and self._snapshot.numerical
        self.magnifier_toggle.setEnabled(numerical and roomy)
        self.magnifier_toggle.setToolTip("Show a 31×31 patch around the pointer." if roomy else
                                       "Enlarge the viewer to show magnified patches.")
        self.magnifier.setVisible(numerical and roomy and self.magnifier_toggle.isChecked())

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._compact_layout()

    def _clear_crosshairs(self):
        for name, cross in self._crosshairs.items():
            for line in cross:
                self._views[name].removeItem(line)
                line.deleteLater()
        self._crosshairs.clear()

    def keyPressEvent(self, event) -> None:
        if event.key() == QtCore.Qt.Key_F:
            self.fit()
        elif event.key() == QtCore.Qt.Key_Escape:
            if self._draw_kind is not None:
                self.cancel_drawing()
            else:
                self.close()
        elif event.key() == QtCore.Qt.Key_B:
            if not event.isAutoRepeat():
                self._blink(True)
        else:
            super().keyPressEvent(event)

    def keyReleaseEvent(self, event):
        if event.key() == QtCore.Qt.Key_B and not event.isAutoRepeat():
            self._blink(False)
        else:
            super().keyReleaseEvent(event)

    def changeEvent(self, event):
        if event.type() == QtCore.QEvent.Type.ActivationChange and not self.isActiveWindow():
            self._blink(False)
        super().changeEvent(event)

    def closeEvent(self, event) -> None:
        if self._closed:
            super().closeEvent(event)
            return
        self._closed = True
        self._analysis_token += 1
        self._analysis_timer.stop()
        self._cursor_timer.stop()
        self._pending_snapshot_timer.stop()
        self._worker.cancel(self._analysis_owner)
        self._worker.ready.disconnect(self._analysis_ready)
        if self._owns_worker:
            self._worker.shutdown()
        for group in self._navigation_groups:
            group.dispose()
        self._navigation_groups.clear()
        for key in list(self._roi_items):
            self._dispose_roi(key)
        self._clear_crosshairs()
        self.magnifier.clear()
        for item in self._items.values():
            item.clear()
            item.deleteLater()
        self._items.clear()
        self._views.clear()
        self.graphics.clear()
        self._planes.clear()
        self._snapshot = self._difference = self._pinned = self._analysis_source = self._pending_snapshot = None
        self.closed.emit()
        super().closeEvent(event)
