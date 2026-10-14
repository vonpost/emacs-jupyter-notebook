"""Qt workspace for local numerical snapshots, differences and measurements."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import replace
import html
import math

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtGui, QtWidgets

from .analysis import (DIFFERENCE, MAX_ROIS, MAX_PROFILE_BYTES, Profile, Region, comparison_error,
                       correspondence, frame_correspondence, scalar_array, VolumeSelection)
from .spatial import plane_geometry, project_metadata
from .analysis_worker import AnalysisJob, AnalysisWorker
from .navigation import ImageGraphicsWidget, ImageViewBox, NavigationGroup, PaneLabel, camera
from .memory import AnalysisSource, memory_budget, merge_allocations, source_allocations, render_bytes
from .magnifier import Magnifier, MAX_PATCH_BYTES


MAX_LEVEL_SAMPLE = 65_536
PINNED = "\0pinned"


def _sample_extrema(array: np.ndarray) -> tuple[float, float] | None:
    """Return finite extrema from at most MAX_LEVEL_SAMPLE source samples."""
    # Flat indexing samples strided faces without flattening/copying the face.
    step = max(1, (array.size + MAX_LEVEL_SAMPLE - 1) // MAX_LEVEL_SAMPLE)
    sample = array.flat[::step]
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
        self._labels = {}
        self._plots = {}
        self._layout_columns = self._layout_rows = 0
        self._views: dict[str, pg.ViewBox] = {}
        self._metadata: dict[str, dict] = {}
        self._volume_selections: dict[str, VolumeSelection] = {}
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
        self._profiles = {}
        self._profile_curves = {}
        self._profile_identifier = None
        self._profile_error = ""
        self._closed = False
        self._analysis_owner = object()
        self._owns_worker = analysis_worker is None
        self._worker = analysis_worker or AnalysisWorker(self)
        self._admit = admit or (lambda: sum(merge_allocations(
            self.allocations, self._worker.allocations).values()) <= memory_budget())
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
        self._layout_timer = QtCore.QTimer(self)
        self._layout_timer.setSingleShot(True)
        self._layout_timer.timeout.connect(self._layout_panes)

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

        image_controls = QtWidgets.QHBoxLayout()
        image_controls.addWidget(QtWidgets.QLabel("View", central))
        self.view_selector = QtWidgets.QComboBox(central)
        self.view_selector.setMinimumWidth(170)
        self.view_selector.setMaximumWidth(280)
        self.view_selector.addItem("All images", None)
        self.view_selector.setToolTip("Show one retained image, or all images. [ and ] flip between images locally.")
        image_controls.addWidget(self.view_selector)
        image_controls.addWidget(QtWidgets.QLabel("[ / ] flip images", central))
        image_controls.addStretch(1)
        outer.addLayout(image_controls)

        self.volume_controls = QtWidgets.QWidget(central)
        volume_layout = QtWidgets.QHBoxLayout(self.volume_controls)
        volume_layout.setContentsMargins(0, 0, 0, 0)
        self.volume_selector = QtWidgets.QComboBox(self.volume_controls)
        self.volume_selector.setMaximumWidth(180)
        self.volume_axis = QtWidgets.QComboBox(self.volume_controls)
        for axis, text in enumerate(("Axes 1 × 2 (slice axis 0)",
                                     "Axes 0 × 2 (slice axis 1)",
                                     "Axes 0 × 1 (slice axis 2)")):
            self.volume_axis.addItem(text, axis)
        self.slice_slider = QtWidgets.QSlider(QtCore.Qt.Orientation.Horizontal, self.volume_controls)
        self.slice_index = QtWidgets.QSpinBox(self.volume_controls)
        self.slice_index.setPrefix("Slice ")
        self.slice_status = QtWidgets.QLabel(self.volume_controls)
        for widget in (self.volume_selector, self.volume_axis, self.slice_slider,
                       self.slice_index, self.slice_status):
            volume_layout.addWidget(widget)
        volume_layout.setStretch(2, 1)
        self.volume_controls.setToolTip(
            "Browse the retained crop locally. Axes follow ndarray order; rows × columns. "
            "Indices start at zero within the crop. Shift+wheel or PageUp/PageDown changes slice. "
            "Matching declared volume grids browse together.")
        outer.addWidget(self.volume_controls)
        self.volume_controls.hide()

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
        self.graphics.viewport().installEventFilter(self)
        outer.addWidget(self.graphics, 1)
        self.magnifier = Magnifier(central)
        outer.addWidget(self.magnifier)
        self.magnifier.hide()

        self.measurements_button = QtWidgets.QToolButton(central)
        self.measurements_button.setText("Measurements")
        self.measurements_button.setCheckable(True)
        self.measurements_button.setToolTip("Show ROI tools, statistics and line profiles")
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
        for kind in ("line", "rectangle", "ellipse"):
            action = menu.addAction("Draw " + kind)
            action.triggered.connect(lambda _checked=False, shape=kind: self.arm_roi(shape))
        menu.addAction("Cancel drawing", self.cancel_drawing)
        self.draw_button.setMenu(menu)
        controls.addWidget(self.draw_button)
        controls.addWidget(self.measurements_button)
        self.capture_button = QtWidgets.QToolButton(central)
        self.capture_button.setText("Capture")
        self.capture_button.setToolTip("Save the displayed images and their recorded context (Ctrl+S)")
        self.capture_button.clicked.connect(self.capture_finding)
        controls.addWidget(self.capture_button)
        self.findings_button = QtWidgets.QToolButton(central)
        self.findings_button.setText("Findings")
        self.findings_button.setToolTip("Review saved images and observations")
        self.findings_button.clicked.connect(self.show_findings)
        controls.addWidget(self.findings_button)
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
        self.profile_status = StatusLabel(parent=central)
        measurements_layout.addWidget(self.profile_status)
        self.profile_plot = pg.PlotWidget(central)
        self.profile_plot.setMinimumHeight(150)
        self.profile_plot.setMaximumHeight(240)
        self.profile_plot.setLabel("bottom", "Distance from A", units="pixels")
        self.profile_plot.setLabel("left", "Value")
        self.profile_plot.showGrid(x=True, y=True, alpha=.2)
        self.profile_plot.setMenuEnabled(False)
        self.profile_plot.addLegend(offset=(10, 10))
        measurements_layout.addWidget(self.profile_plot)
        self.profile_status.hide()
        self.profile_plot.hide()
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
        self.view_selector.currentIndexChanged.connect(self._view_changed)
        self.volume_selector.currentIndexChanged.connect(self._sync_volume_controls)
        self.volume_axis.currentIndexChanged.connect(
            lambda: self.select_volume_slice(axis=self.volume_axis.currentData()))
        self.slice_slider.valueChanged.connect(lambda index: self.select_volume_slice(index=index))
        self.slice_index.valueChanged.connect(lambda index: self.select_volume_slice(index=index))
        self._slice_shortcuts = []
        self._capture_shortcut = QtGui.QShortcut(QtGui.QKeySequence("Ctrl+S"), self)
        self._capture_shortcut.activated.connect(self.capture_finding)
        for key, step in (("PgUp", -1), ("PgDown", 1)):
            shortcut = QtGui.QShortcut(QtGui.QKeySequence(key), self.graphics)
            shortcut.setContext(QtCore.Qt.ShortcutContext.WidgetWithChildrenShortcut)
            shortcut.activated.connect(lambda delta=step: self._step_slice(delta))
            self._slice_shortcuts.append(shortcut)
        for key, step in (("[", -1), ("]", 1)):
            shortcut = QtGui.QShortcut(QtGui.QKeySequence(key), self.graphics)
            shortcut.setContext(QtCore.Qt.ShortcutContext.WidgetWithChildrenShortcut)
            shortcut.activated.connect(lambda delta=step: self._cycle_images(delta))
            self._slice_shortcuts.append(shortcut)
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

    def capture_finding(self):
        from .findings import FindingError
        from .findings_gui import findings_service
        try:
            findings_service().capture(self)
        except FindingError as exc:
            self.analysis_status.setText(str(exc))

    def show_findings(self):
        from .findings_gui import findings_service
        findings_service().show_review()

    @property
    def frozen(self):
        return self.freeze_button.isChecked()

    @property
    def allocations(self):
        result = {}
        result["magnifier", id(self)] = MAX_PATCH_BYTES
        # One selected line, four originals, a pin and a difference. Include
        # NumPy vectors, plot paths, finite masks and plotting conversions.
        if self._profile_identifier is not None:
            result["profiles", id(self)] = MAX_PROFILE_BYTES * 6 * 8
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
            result["pending-render", id(self)] = sum(render_bytes(array, numerical=self._pending_snapshot.numerical)
                for array in self._pending_snapshot.planes.values())
        return result

    def _raw_planes(self):
        arrays = dict(self._snapshot.planes)
        if self._pinned is not None:
            arrays[PINNED] = self._pinned.planes[self._pinned_name]
        return arrays

    def _all_planes(self):
        return {name: self._volume_selections[name].plane(array)
                if name in self._volume_selections else array
                for name, array in self._raw_planes().items()}

    def _populate_volumes(self):
        selected = self.volume_selector.currentData()
        with QtCore.QSignalBlocker(self.volume_selector):
            self.volume_selector.clear()
            for name in self._raw_planes():
                if name in self._volume_selections:
                    label = "Pinned: " + self._pinned_name if name == PINNED else name
                    self.volume_selector.addItem(label, name)
            index = self.volume_selector.findData(selected)
            self.volume_selector.setCurrentIndex(max(0, index))
        self.volume_controls.setVisible(bool(self.volume_selector.count()))
        self._sync_volume_controls()

    def _populate_views(self):
        selected = self.view_selector.currentData()
        with QtCore.QSignalBlocker(self.view_selector):
            self.view_selector.clear()
            self.view_selector.addItem("All images", None)
            for name in self._raw_planes():
                label = "Pinned: " + self._pinned_name if name == PINNED else name
                self.view_selector.addItem(label, name)
            self.view_selector.setCurrentIndex(max(0, self.view_selector.findData(selected)))

    def _view_changed(self, *_):
        if self._snapshot is None or self._closed:
            return
        if self.graphics._roi_drag is not None or self.graphics.scene().mouseGrabberItem() is not None:
            with QtCore.QSignalBlocker(self.view_selector):
                self.view_selector.setCurrentIndex(self.view_selector.findData(
                    next(iter(self._planes)) if len(self._planes) == 1 else None))
            return
        self.cancel_drawing()
        self._blink(False)
        selected = self.view_selector.currentData()
        old_planes, self._planes = self._planes, self._display_planes()
        allowed = self._admit()
        self._planes = old_planes
        if not allowed:
            with QtCore.QSignalBlocker(self.view_selector):
                self.view_selector.setCurrentIndex(self.view_selector.findData(
                    next(iter(self._planes)) if len(self._planes) == 1 else None))
            self.analysis_status.setText("This view exceeds the local memory budget; close another workspace first.")
            return
        if selected in self._volume_selections:
            self.volume_selector.setCurrentIndex(self.volume_selector.findData(selected))
        preserve = selected is None or any(self._corresponds(selected, name) for name in old_planes)
        self._render(preserve=preserve)
        self._schedule_analysis()

    def _cycle_images(self, step):
        count = self.view_selector.count() - 1
        if count <= 0:
            return
        index = self.view_selector.currentIndex() - 1
        target = (index + step) % count if index >= 0 else (0 if step > 0 else count - 1)
        self.view_selector.setCurrentIndex(target + 1)

    def _sync_volume_controls(self, *_):
        name = self.volume_selector.currentData()
        if name not in self._volume_selections:
            return
        selection = self._volume_selections[name]
        shape = self._raw_planes()[name].shape
        index = selection.indices[selection.axis]
        with QtCore.QSignalBlocker(self.volume_axis):
            self.volume_axis.setCurrentIndex(selection.axis)
        for widget in (self.slice_slider, self.slice_index):
            with QtCore.QSignalBlocker(widget):
                widget.setRange(0, shape[selection.axis] - 1)
                widget.setValue(index)
        status = f"/ {shape[selection.axis] - 1}"
        meta = self._raw_meta(name)
        if meta.get("spacing"):
            position = meta["origin"][selection.axis] + index * meta["spacing"][selection.axis]
            status += f" · {position:g} {meta['spatial_units']}"
        self.slice_status.setText(status)

    def _volume_corresponds(self, first, second):
        arrays = self._raw_planes()
        return (first == second or first in self._volume_selections
                and second in self._volume_selections
                and self._sample(first) == self._sample(second)
                and frame_correspondence(arrays[first], arrays[second],
                                   self._raw_meta(first), self._raw_meta(second),
                                   declared=self.declare_grid.isChecked()))

    @staticmethod
    def _mapped_slice_index(index, axis, source_meta, target_meta):
        if source_meta.get("spacing") and target_meta.get("spacing"):
            position = source_meta["origin"][axis] + index * source_meta["spacing"][axis]
            return math.floor((position - target_meta["origin"][axis]) / target_meta["spacing"][axis] + .5)
        return index

    def select_volume_slice(self, *, name=None, axis=None, index=None):
        """Select a locally retained face and invalidate all old derived results."""
        name = self.volume_selector.currentData() if name is None else name
        if name not in self._volume_selections or self._closed:
            return
        # Replacing a ViewBox while Qt owns a scene drag target invalidates
        # its handle. Slider drags are outside this scene and remain live.
        if self.graphics._roi_drag is not None or self.graphics.scene().mouseGrabberItem() is not None:
            self._sync_volume_controls()
            return
        self.cancel_drawing()
        previous = dict(self._volume_selections)
        old_links = {(first, second): self._corresponds(first, second)
                     for first in self._planes for second in self._planes}
        selection = previous[name].select(self._raw_planes()[name].shape, axis=axis, index=index)
        if selection == previous[name]:
            return
        targets = [target for target in self._volume_selections if self._volume_corresponds(name, target)]
        for target in targets:
            target_index = self._mapped_slice_index(selection.indices[selection.axis], selection.axis,
                                                    self._raw_meta(name), self._raw_meta(target))
            self._volume_selections[target] = previous[target].select(
                self._raw_planes()[target].shape, axis=selection.axis,
                index=target_index)
        old_planes, old_difference = self._planes, self._difference
        self._difference = None
        self._planes = self._display_planes()
        allowed = self._admit()
        self._planes, self._difference = old_planes, old_difference
        if not allowed:
            self._volume_selections = previous
            self._sync_volume_controls()
            self.analysis_status.setText("This slice exceeds the local memory budget; close another workspace first.")
            return
        self._blink(False)
        self._worker.cancel(self._analysis_owner)
        self._analysis_token += 1
        self._difference = self._difference_key = None
        self._statistics = {}
        self._profiles = {}
        changed_axis = any(previous[target].axis != selection.axis for target in targets)
        if changed_axis:
            self._regions = {key: region for key, region in self._regions.items()
                             if region.plane not in targets}
        self._update_analysis_source()
        self._sync_volume_controls()
        links_unchanged = all(self._corresponds(first, second) == linked
                              for (first, second), linked in old_links.items())
        # Keep ViewBoxes/ROI handles alive while scrubbing one orientation.
        # Full scene construction is only needed for shape/layout changes.
        if not changed_axis and links_unchanged and DIFFERENCE not in self._planes:
            self._planes = self._display_planes()
            for target, array in self._planes.items():
                item = self._items[target]
                item.setImage(array, autoLevels=False, levels=item.getLevels())
                self._set_pane_label(target)
            for index in range(self.roi_plane.count()):
                self.roi_plane.setItemText(index, self._display_name(self.roi_plane.itemData(index)))
            self.blink_button.setEnabled(self._comparison_error() is None)
            self._clear_cursor()
        else:
            self._render(preserve=not changed_axis)
        self._schedule_analysis()

    def _step_slice(self, delta, name=None):
        name = self.volume_selector.currentData() if name is None else name
        if name in self._volume_selections:
            selection = self._volume_selections[name]
            self.select_volume_slice(name=name, index=selection.indices[selection.axis] + delta)

    def eventFilter(self, watched, event):
        if watched is self.graphics.viewport() and event.type() == QtCore.QEvent.Type.Resize:
            self._layout_timer.start(0)
        if (watched is self.graphics.viewport() and event.type() == QtCore.QEvent.Type.Wheel
                and event.modifiers() & QtCore.Qt.KeyboardModifier.ShiftModifier):
            view, _scene = self.graphics._view_at(event.position())
            name = next((name for name, target in self._views.items() if target is view), None)
            if name == DIFFERENCE:
                name = self._candidate_name()
            if name in self._volume_selections:
                delta = event.angleDelta().y() or event.pixelDelta().y()
                if delta:
                    self.volume_selector.setCurrentIndex(self.volume_selector.findData(name))
                    self._step_slice(1 if delta < 0 else -1, name)
                event.accept()
                return True
        return super().eventFilter(watched, event)

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
            if name in self._volume_selections:
                self._volume_selections[PINNED] = self._volume_selections[name]
            # Promotion shares source bytes but adds a displayed baseline.
            # Keep every current member and admit all render buffers first.
            previous_planes, previous_difference = self._planes, self._difference
            self._planes = self._display_planes()
            self._difference = None
            allowed = self._admit()
            self._planes, self._difference = previous_planes, previous_difference
            if not allowed:
                self._pinned = self._pinned_name = None
                self._volume_selections.pop(PINNED, None)
                self.pin_button.blockSignals(True)
                self.pin_button.setChecked(False)
                self.pin_button.blockSignals(False)
                self.analysis_status.setText("Pinning exceeds the local memory budget.")
                return
        else:
            previous_pin, previous_name = self._pinned, self._pinned_name
            previous_planes, previous_difference = self._planes, self._difference
            self._pinned = self._pinned_name = None
            self._planes, self._difference = self._display_planes(), None
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
            self._volume_selections.pop(PINNED, None)
        self._populate_selectors()
        if checked:
            self.reference.blockSignals(True)
            self.reference.setCurrentIndex(self.reference.findData(PINNED))
            self.reference.blockSignals(False)
        self.pin_button.setText("Unpin reference" if checked else "Pin reference")
        self._populate_volumes()
        self._populate_views()
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
               or (numerical and not scalar_array(array))
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
        if numerical:
            for name, array in planes.items():
                meta = new_meta.get(name, {})
                if array.ndim == 3:
                    # Validate every selectable face before changing the UI.
                    for axis in range(3):
                        geometry = plane_geometry(project_metadata(meta, array.shape, axis, 0))
                        geometry.image_rect(tuple(size for i, size in enumerate(array.shape) if i != axis))
                else:
                    plane_geometry(meta).image_rect(array.shape)
        old = self._snapshot
        old_manifest = getattr(old, "manifest", None) or {}
        preserve = bool(old is not None and old.numerical and numerical
                        and old.workspace == snapshot.workspace
                        and old.generation == snapshot.generation
                        and old_manifest.get("sample_id")
                        and old_manifest.get("sample_id") == manifest.get("sample_id")
                        and set(old.planes) == set(planes)
                        and all(frame_correspondence(old.planes[name], planes[name],
                                               self._metadata.get(name, {}), new_meta.get(name, {}),
                                               declared=self.declare_grid.isChecked())
                                for name in planes))
        self._worker.cancel(self._analysis_owner)
        self._analysis_token += 1
        self._analysis_timer.stop()
        self._difference = self._difference_key = None
        self._statistics = {}
        self._profiles = {}
        self._clear_profile_plot()
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
        previous_selections = self._volume_selections
        self._volume_selections = {}
        old_meta = _plane_metadata(old_manifest)
        for name, array in planes.items():
            if not numerical or array.ndim != 3:
                continue
            selection = VolumeSelection.centered(array.shape)
            if name in previous_selections and old is not None and name in old.planes:
                before, after = old_meta.get(name, {}), new_meta.get(name, {})
                if preserve and before.get("spacing") and after.get("spacing"):
                    previous = previous_selections[name]
                    for axis in range(3):
                        selection = selection.select(array.shape, axis=axis, index=self._mapped_slice_index(
                            previous.indices[axis], axis, before, after))
                    selection = selection.select(array.shape, axis=previous.axis)
                elif old.planes[name].shape == array.shape:
                    selection = previous_selections[name]
            self._volume_selections[name] = selection
        if PINNED in previous_selections and self._pinned is not None:
            self._volume_selections[PINNED] = previous_selections[PINNED]
        if old is None:
            # Select one physical slice per compatible frame on first display.
            names = list(self._volume_selections)
            for index, name in enumerate(names):
                for reference in names[:index]:
                    if self._volume_corresponds(reference, name):
                        source = self._volume_selections[reference]
                        self._volume_selections[name] = self._volume_selections[name].select(
                            planes[name].shape, axis=source.axis, index=self._mapped_slice_index(
                                source.indices[source.axis], source.axis,
                                self._raw_meta(reference), self._raw_meta(name)))
                        break
        self._populate_volumes()
        self._populate_views()
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
                self.comparison.currentData(), id(self._pinned),
                tuple(self._volume_selections.items()))

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
            label = "Pinned: " + self._pinned_name
        elif name != DIFFERENCE:
            label = name
        else:
            order = self.candidate.currentText() + " − " + self.reference.currentText()
            label = "|" + order + "|" if self.comparison.currentData() == "absolute" else order
            name = self._candidate_name()
        if name in self._volume_selections:
            selection = self._volume_selections[name]
            remaining = [axis for axis in range(3) if axis != selection.axis]
            label += f" · axis {selection.axis}={selection.indices[selection.axis]}"
            meta = self._raw_meta(name)
            if meta.get("spacing"):
                position = meta["origin"][selection.axis] + selection.indices[selection.axis] * meta["spacing"][selection.axis]
                label += f" ({position:g} {meta['spatial_units']})"
            label += f" · rows {remaining[0]}, cols {remaining[1]}"
        return label

    def _raw_meta(self, name):
        if name == PINNED:
            return _plane_metadata(self._pinned.manifest).get(self._pinned_name, {})
        if name == DIFFERENCE:
            name = self._candidate_name()
        return self._metadata.get(name, {})

    def _meta(self, name):
        if name == DIFFERENCE:
            name = self._candidate_name()
        if name != PINNED and not self._snapshot.numerical:
            return {}
        meta = self._raw_meta(name)
        if name in self._volume_selections:
            selection = self._volume_selections[name]
            meta = project_metadata(meta, self._raw_planes()[name].shape, selection.axis,
                                    selection.indices[selection.axis])
        return meta

    def _corresponds(self, first, second):
        arrays = self._all_planes()
        if self._difference is not None:
            arrays[DIFFERENCE] = self._difference
        return (first == second or
                first in arrays and second in arrays and
                self._sample(first) == self._sample(second) and
                frame_correspondence(arrays[first], arrays[second], self._meta(first), self._meta(second),
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
        planes = self._all_planes()
        selected = self.view_selector.currentData()
        if selected in planes:
            return {selected: planes[selected]}
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
        self._labels.clear()
        self._plots.clear()
        self._views.clear()
        self.graphics.clear()
        numerical = self._snapshot.numerical
        self._planes = self._display_planes()
        extrema = [_sample_extrema(array) for name, array in self._planes.items()
                   if numerical and name != DIFFERENCE and not (preserve and old_levels)]
        extrema = [value for value in extrema if value is not None]
        low = min((value[0] for value in extrema), default=0.0)
        high = max((value[1] for value in extrema), default=1.0)
        if high <= low:
            high = low + 1.0
        if preserve and old_levels:
            low = self.level.value() - self.width.value() / 2
            high = self.level.value() + self.width.value() / 2
        columns = min(len(self._planes), 3 if len(self._planes) == 3 or len(self._planes) >= 5 else 2)
        for index, (name, array) in enumerate(self._planes.items()):
            row, col = divmod(index, columns)
            units = self._meta(name).get("units") or "unspecified units"
            title = self._display_name(name) + (" [" + units + "]" if numerical else " (rendered image)")
            label = PaneLabel(title)
            self.graphics.addItem(label, row=row * 2, col=col)
            label.setToolTip(title)
            self._labels[name] = label
            view = ImageViewBox()
            geometry = plane_geometry(self._meta(name))
            # Every pane has identical axis strips, including pixel-only data.
            # Mixed calibration and long ticks cannot make one image narrower.
            plot = pg.PlotItem(viewBox=view, enableMenu=False)
            selection = self._volume_selections.get(self._candidate_name() if name == DIFFERENCE else name)
            axes = [axis for axis in range(3) if selection is None or axis != selection.axis]
            if selection is None:
                axes = [0, 1]
            for edge, axis in (("left", axes[0]), ("bottom", axes[1])):
                plot.getAxis(edge).enableAutoSIPrefix(False)
                plot.setLabel(edge, f"Axis {axis}", units=geometry.units or "px")
            plot.getAxis("left").setWidth(110)
            plot.getAxis("bottom").setHeight(48)
            plot.hideButtons()
            self.graphics.addItem(plot, row=row * 2 + 1, col=col)
            self._plots[name] = plot
            view.setMenuEnabled(False)
            levels = (low, high) if numerical else (0.0, 255.0)
            if name == DIFFERENCE:
                bounds = _sample_extrema(array) or (0.0, 1.0)
                limit = max(abs(bounds[0]), abs(bounds[1]), 1.0e-12)
                levels = (0.0 if self.comparison.currentData() == "absolute" else -limit, limit)
                # Display ranges belong to the pair/mode, not every visited
                # slice; scrubbing must not grow a per-slice settings cache.
                key = self._comparison_key()[1:5]
                levels = self._difference_levels.get(key, levels)
                self._displayed_comparison = key
            item = pg.ImageItem(array, axisOrder="row-major", autoLevels=False, levels=levels)
            item.setAutoDownsample(False)
            if geometry.physical:
                item.setRect(QtCore.QRectF(*geometry.image_rect(array.shape)))
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
            if previous is None and preserve:
                previous = next((state for name, state in cameras.items()
                                 if any(self._corresponds(name, member) for member in members)), None)
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
        self._layout_timer.start(0)

    def _layout_panes(self):
        """Allocate identical actual image rectangles, independent of labels."""
        if self._closed or not self._plots:
            return
        count = len(self._plots)
        columns = min(count, 3 if count == 3 or count >= 5 else 2)
        rows = (count + columns - 1) // columns
        layout = self.graphics.ci.layout
        left, top, right, bottom = layout.getContentsMargins()
        width = max(1, (self.graphics.viewport().width() - left - right - 8 * (columns - 1)) / columns)
        height = max(1, (self.graphics.viewport().height() - top - bottom - 24 * rows - 6 * (2 * rows - 1)) / rows)
        # Clear old slots too: a single image must occupy the full area after
        # flipping out of a two/three-column layout, and vice versa.
        for column in range(max(columns, self._layout_columns)):
            layout.setColumnFixedWidth(column, width if column < columns else 0)
            layout.setColumnSpacing(column, 8 if column < columns - 1 else 0)
        for row in range(max(rows, self._layout_rows)):
            layout.setRowFixedHeight(2 * row, 24 if row < rows else 0)
            layout.setRowFixedHeight(2 * row + 1, height if row < rows else 0)
            layout.setRowSpacing(2 * row, 6 if row < rows else 0)
            layout.setRowSpacing(2 * row + 1, 6 if row < rows - 1 else 0)
        self._layout_columns, self._layout_rows = columns, rows
        layout.activate()

    def _set_pane_label(self, name):
        units = self._meta(name).get("units") or "unspecified units"
        title = self._display_name(name) + " [" + units + "]"
        self._labels[name].setText(title)
        self._labels[name].setToolTip(title)

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

    def _measurement_planes(self):
        """Every retained original participates even while one image is shown."""
        arrays = self._all_planes()
        if self._difference is not None:
            arrays[DIFFERENCE] = self._difference
        return arrays

    def _measurement_targets(self, region):
        return tuple(name for name in self._measurement_planes() if self._corresponds(region.plane, name))

    def _rebuild_rois(self):
        wanted = {(region.identifier, name) for region in self._regions.values()
                  for name in self._targets(region)}
        for key in list(self._roi_items):
            if key not in wanted:
                self._dispose_roi(key)
        selected = self.roi_selector.currentData()
        self.roi_selector.blockSignals(True)
        self.roi_selector.clear()
        for region in self._regions.values():
            self.roi_selector.addItem(region.name, region.identifier)
            for name in self._targets(region):
                if (region.identifier, name) in self._roi_items:
                    continue
                pen = pg.intColor(region.identifier, hues=MAX_ROIS)
                if region.kind == "line":
                    item = pg.LineSegmentROI(((0, 0), (region.width, region.height)),
                                             pos=(region.x, region.y), pen=pen,
                                             removable=True, rotatable=False)
                    item._endpoint_labels = tuple(pg.TextItem(text, color=pen, anchor=(0, 1))
                                                  for text in ("A", "B"))
                    for label in item._endpoint_labels:
                        label.setParentItem(item)
                        label.setAcceptedMouseButtons(QtCore.Qt.MouseButton.NoButton)
                    self._label_line(item)
                else:
                    cls = pg.RectROI if region.kind == "rectangle" else pg.EllipseROI
                    item = cls((region.x, region.y), (region.width, region.height),
                               pen=pen, removable=True, rotatable=False)
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
        self.roi_selector.blockSignals(False)
        self._roi_selection_changed()
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
        if kind not in ("line", "rectangle", "ellipse"):
            raise ValueError("unsupported ROI shape")
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
        self.draw_button.setToolTip("Draw a line, rectangle or ellipse directly on an image")
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
        if self._draw_kind == "line":
            self._syncing_rois = True
            try:
                self._set_line(item, start, end)
            finally:
                self._syncing_rois = False
            self._roi_changed(self._drawing_region, item)
        else:
            item.setPos((min(start.x(), end.x()), min(start.y(), end.y())))
            item.setSize((max(.001, abs(end.x() - start.x())), max(.001, abs(end.y() - start.y()))))
        if finished:
            line = self._draw_kind == "line"
            self._drawing_region = None
            self.cancel_drawing()
            if line:
                self.measurements_button.setChecked(True)

    def _roi_selection_changed(self, *_):
        region = self._regions.get(self.roi_selector.currentData())
        self.roi_name.setText(region.name if region is not None else "")
        self.roi_name.setEnabled(region is not None)
        identifier = region.identifier if region is not None and region.kind == "line" else None
        if identifier != self._profile_identifier:
            self._profile_identifier = identifier
            self._schedule_analysis()
            if identifier is not None and not self._gesturing():
                self.measurements_button.setChecked(True)
        self._render_profile()

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
        self._render_profile()

    def nudge_roi(self, dx, dy):
        identifier = self.roi_selector.currentData()
        item = next((item for (key, _name), item in self._roi_items.items() if key == identifier), None)
        if item is not None:
            dx, dy = plane_geometry(self._meta(self._regions[identifier].plane)).pixel_delta_to_world(dx, dy)
            item.setPos(item.pos() + QtCore.QPointF(dx, dy))

    def copy_statistics(self):
        rows = ["ROI\tPlane\tUnits\tMean\tSD (population)\tFinite N\tExcluded"]
        for (identifier, name), value in self._statistics.items():
            if identifier not in self._regions or name not in self._measurement_planes():
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
        if kind not in ("line", "rectangle", "ellipse"):
            raise ValueError("unsupported ROI shape")
        if not self._snapshot or not self._snapshot.numerical or len(self._regions) >= MAX_ROIS:
            return
        name = self.roi_plane.currentData()
        array = self._planes[name]
        view = self._views[name].viewRect()
        geometry = plane_geometry(self._meta(name))
        bounds = QtCore.QRectF(*geometry.image_rect(array.shape))
        width = max(geometry.spacing[1], min(bounds.width(), view.width()) / 3)
        height = max(geometry.spacing[0], min(bounds.height(), view.height()) / 3)
        x = min(max(view.center().x() - width / 2, bounds.left()), bounds.right() - width)
        y = min(max(view.center().y() - height / 2, bounds.top()), bounds.bottom() - height)
        if kind == "line":
            y += height / 2
            height = 0
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
        self.roi_selector.setCurrentIndex(self.roi_selector.findData(identifier))
        line = self._regions[identifier].kind == "line"
        if line:
            pos, end = (item.mapToParent(point) for point in item.listPoints())
            size = end - pos
            self._label_line(item)
        else:
            pos, size = item.pos(), item.size()
        self._regions[identifier] = replace(self._regions[identifier], x=float(pos.x()),
                                            y=float(pos.y()), width=float(size.x()), height=float(size.y()))
        self._syncing_rois = True
        try:
            for (other_id, _name), other in self._roi_items.items():
                if other_id == identifier and other is not item:
                    if line:
                        self._set_line(other, pos, pos + size)
                    else:
                        other.setPos(pos)
                        other.setSize(size)
        finally:
            self._syncing_rois = False
        self._schedule_analysis()

    @staticmethod
    def _label_line(item):
        for label, point in zip(item._endpoint_labels, item.listPoints()):
            label.setPos(point)

    @classmethod
    def _set_line(cls, item, start, end):
        # Free handles store their positions separately from the ROI size.
        # Callers guard signals while both endpoints are being replaced.
        for handle, point in zip(item.getHandles(), (start, end)):
            item.movePoint(handle, point, finish=False, coords="parent")
        cls._label_line(item)

    def _schedule_analysis(self, *_):
        self._analysis_token += 1
        self._statistics = {}
        self._profiles = {}
        self._profile_error = ""
        self.stats_table.setRowCount(0)
        self._render_profile()
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
        regions = tuple(roi for roi in self._regions.values()
                        if roi.kind != "line" or roi.identifier == self._profile_identifier)
        targets = {roi.identifier: self._measurement_targets(roi) for roi in regions}
        if compare:
            for roi in regions:
                if self._corresponds(roi.plane, candidate):
                    targets[roi.identifier] = tuple(dict.fromkeys((*targets[roi.identifier], DIFFERENCE)))
        self._worker.submit(AnalysisJob(self._analysis_owner, self._analysis_token, self._analysis_source,
                                       regions, targets, reference, candidate,
                                       self.comparison.currentData() == "absolute",
                                       self._difference if self._difference_key == self._comparison_key() else None,
                                       metadata={name: self._meta(name) for name in
                                                 (*self._analysis_source.planes, DIFFERENCE)}))

    @QtCore.Slot(object, int, object, str)
    def _analysis_ready(self, owner, token, result, error):
        if owner is not self._analysis_owner or self._closed or token != self._analysis_token:
            return
        if error:
            self._profile_error = error
            self._render_profile()
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
        self._statistics = {key: value for key, value in statistics.items()
                            if not isinstance(value, Profile)}
        self._profiles = {key: value for key, value in statistics.items()
                          if isinstance(value, Profile)}
        if derived is not None and self._difference is not derived:
            self._difference = derived
            self._difference_key = self._comparison_key()
            self._render(preserve=True)
        self._render_statistics()
        self._render_profile()
        comparison_error_text = self._comparison_error() if self.comparison.currentData() else None
        self.analysis_status.setText(comparison_error_text or
                                    ("Line profile uses original samples; drag A/B endpoints or the line to compare edges."
                                     if self._profile_identifier is not None else
                                     "Local original-sample measurements; SD is population SD (ddof=0)."))

    def _clear_profile_plot(self):
        self.profile_plot.clear()
        self._profile_curves.clear()

    def _render_profile(self):
        self._clear_profile_plot()
        region = self._regions.get(self._profile_identifier)
        enabled = region is not None and region.kind == "line"
        self.profile_plot.setVisible(enabled)
        self.profile_status.setVisible(enabled)
        self.stats_table.setVisible(not enabled)
        self.copy_button.setEnabled(not enabled)
        if not enabled:
            self.profile_status.setText("")
            self.profile_plot.setTitle("")
            return
        title = (f"{region.name}: A ({region.x:.4g}, {region.y:.4g}) → "
                 f"B ({region.x + region.width:.4g}, {region.y + region.height:.4g})")
        self.profile_plot.setTitle(html.escape(region.name))
        entries = [(name, self._profiles[region.identifier, name]) for name in self._measurement_planes()
                   if (region.identifier, name) in self._profiles]
        distance_units = plane_geometry(self._meta(region.plane)).units or "pixels"
        self.profile_plot.setLabel("bottom", "Distance from A", units=distance_units)
        for index, (name, profile) in enumerate(entries):
            units = self._meta(name).get("units") or "unspecified units"
            label = self._display_name(name) + " [" + units + "]"
            color = pg.intColor(index, hues=max(3, len(entries)))
            curve = self.profile_plot.plot(profile.distance, profile.values,
                                           name=html.escape(label), pen=pg.mkPen(color, width=2),
                                           connect="finite", symbol="o" if profile.values.size == 1 else None,
                                           symbolBrush=color, symbolSize=6)
            self._profile_curves[name] = curve
        if self._profile_error:
            message = self._profile_error
        elif not entries:
            message = ("Computing profile…" if self._measurement_targets(region) else
                       "No corresponding visible image for this line.")
        elif not any(profile.values.size for _name, profile in entries):
            message = "Line is outside the image."
        elif not any(np.isfinite(profile.values).any() for _name, profile in entries):
            message = "No finite values along this line."
        else:
            capped = any(profile.capped for _name, profile in entries)
            message = ("4096 samples (limit); evenly spaced, bilinear interpolation." if capped else
                       f"Bilinear interpolation; distance in {distance_units}; non-finite samples leave gaps.")
        self.profile_status.setText(title + " · " + message)
        self.profile_plot.setToolTip(
            "Values from original samples along A → B, clipped to the image. "
            "Coordinates and distance use the declared spatial units, or pixels when unspecified. "
            "Edge values extend to the image boundary. "
            "Sample spacing is at most one pixel, except lines limited to 4096 samples. "
            "Each curve lists its intensity units; no normalization or unit conversion is applied.")
        if entries:
            self.profile_plot.enableAutoRange()

    def _render_statistics(self):
        rows = [(key, value) for key, value in self._statistics.items() if key[1] in self._measurement_planes()]
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
            x, y = plane_geometry(self._meta(name)).world_to_pixel(point.x(), point.y())
            col, row = math.floor(x), math.floor(y)
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
        geometry = plane_geometry(self._meta(name))
        world_x, world_y = geometry.pixel_to_world(col + .5, row + .5)
        values = []
        for target, array in self._planes.items():
            linked = self._corresponds(name, target)
            target_geometry = plane_geometry(self._meta(target))
            pixel_x, pixel_y = target_geometry.world_to_pixel(world_x, world_y)
            target_col, target_row = math.floor(pixel_x), math.floor(pixel_y)
            linked = linked and 0 <= target_row < array.shape[0] and 0 <= target_col < array.shape[1]
            for line in self._crosshairs[target]:
                line.setVisible(linked)
            if linked:
                self._crosshairs[target][0].setPos(world_x)
                self._crosshairs[target][1].setPos(world_y)
                label = self._display_name(target)
                if geometry.physical:
                    label += f" [{target_row},{target_col}]"
                values.append(label + "=" + str(array[target_row, target_col]))
        if name in self._volume_selections:
            selection = self._volume_selections[name]
            voxel = [row, col]
            voxel.insert(selection.axis, selection.indices[selection.axis])
            coordinate = "crop [" + ",".join(map(str, voxel)) + "]"
        else:
            coordinate = f"[{row},{col}]"
        if geometry.physical:
            coordinate += f" · ({world_y:g}, {world_x:g}) {geometry.units}"
        text = coordinate + " " + " · ".join(values)
        self.readout.setText(text)
        self.readout.setToolTip(text)
        self._cursor_timer.start()

    def _update_magnifier(self):
        if self._closed or self._cursor is None or not self.magnifier.isVisible():
            return
        name, row, col = self._cursor
        if name not in self._planes:
            return
        geometry = plane_geometry(self._meta(name))
        world = geometry.pixel_to_world(col + .5, row + .5)
        planes = []
        for target, array in self._planes.items():
            if self._corresponds(name, target):
                label = self._display_name(target)
                if self._blinking and target == self._candidate_name():
                    array = self._all_planes()[self._reference_name()]
                    label += " (reference blink)"
                planes.append((target, label, array, self._items[target].getLevels()))
        self.magnifier.display(planes, row, col, metadata={target: self._meta(target) for target, *_ in planes},
                               world=world if geometry.physical else None)

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
        elif event.key() in (QtCore.Qt.Key_PageUp, QtCore.Qt.Key_PageDown) and self._volume_selections:
            self._step_slice(-1 if event.key() == QtCore.Qt.Key_PageUp else 1)
        elif event.key() in (QtCore.Qt.Key_BracketLeft, QtCore.Qt.Key_BracketRight):
            self._cycle_images(-1 if event.key() == QtCore.Qt.Key_BracketLeft else 1)
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
        self._layout_timer.stop()
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
        self._labels.clear()
        self._plots.clear()
        self._views.clear()
        self.graphics.clear()
        self._planes.clear()
        self._profiles.clear()
        self._statistics.clear()
        self._regions.clear()
        self._volume_selections.clear()
        self._profile_identifier = None
        self._clear_profile_plot()
        self._snapshot = self._difference = self._pinned = self._analysis_source = self._pending_snapshot = None
        self.closed.emit()
        super().closeEvent(event)
