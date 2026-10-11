"""Capture the current view and review saved findings with one local IO job."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict
import base64
import html
import json

from PySide6 import QtCore, QtGui, QtWidgets

from .findings import (Capture, FindingError, FindingStore, MAX_CAPTURE_BYTES,
                       MAX_IMAGE_PIXELS, MAX_IMAGE_EXTENT, MAX_NOTE, MAX_OVERVIEW_BYTES, json_bytes)
from .memory import MAX_MEMORY, merge_allocations, source_allocations

IO_RESERVE = 192 * 1024**2
ORG_RESERVE = 64 * 1024**2
# Three derived image/PNG buffers plus coefficient tables for two bounded axes.
PREVIEW_RESERVE = MAX_OVERVIEW_BYTES * 3 + 2 * 1024**2


def freeze_window(window, *, admit=None):
    """Freeze exactly the visible image items before any prompt or event loop."""
    from .analysis import DIFFERENCE
    from .workspace import PINNED

    if window._snapshot is None or not window._items:
        raise FindingError("There is no displayed image to capture.")
    arrays, panes, sources = [], [], {}

    def origin(name):
        snapshot = window._pinned if name == PINNED else window._snapshot
        sources[id(snapshot)] = snapshot
        selection = window._volume_selections.get(name)
        return {"member": window._pinned_name if name == PINNED else name,
                "workspace": snapshot.workspace, "generation": snapshot.generation,
                "execution": getattr(snapshot, "execution", ""),
                "publication": (snapshot.manifest or {}).get("publication_id"),
                "sample": (snapshot.manifest or {}).get("sample_id"),
                "selection": asdict(selection) if selection is not None else None,
                "context": getattr(snapshot, "context", {})}

    for name, item in window._items.items():
        array = item.image
        if array is None or array.flags.writeable:
            raise FindingError("Capture needs immutable loaded image samples.")
        visible_name = (window._reference_name() if window._blinking
                        and name == window._candidate_name() else name)
        provenance = ([origin(window._reference_name()), origin(window._candidate_name())]
                      if name == DIFFERENCE else [origin(visible_name)])
        panes.append({"name": name, "label": window._display_name(name),
                      "showing": visible_name, "numerical": window._snapshot.numerical,
                      "metadata": window._meta(visible_name),
                      "levels": list(map(float, item.getLevels())),
                      "range": window._views[name].viewRange(), "sources": provenance})
        arrays.append(array)
    if sum(array.nbytes for array in arrays) > MAX_CAPTURE_BYTES:
        raise FindingError("Visible planes exceed the capture size limit.")
    metadata = {"panes": panes, "rois": [asdict(value) for value in window._regions.values()],
                "comparison": list(window._rendered_selection or ()),
                "blinking": window._blinking,
                "statistics": [{"roi": identifier, "pane": name, **asdict(result)}
                               for (identifier, name), result in window._statistics.items()
                               if hasattr(result, "mean")]}
    # Deep-copy all mutable metadata before the viewer can accept a new output.
    metadata = json.loads(json_bytes(metadata))
    scale = window.graphics.devicePixelRatioF()
    if (window.graphics.width() * window.graphics.height() * scale * scale > MAX_IMAGE_PIXELS
            or max(window.graphics.width(), window.graphics.height()) * scale > MAX_IMAGE_EXTENT):
        raise FindingError("This display is too large to capture; reduce the viewer window.")
    if admit is not None:
        admit(Capture(None, tuple(arrays), metadata, tuple(sources.values())),
              int(window.graphics.width() * window.graphics.height() * scale * scale * 4))
    # Keep ROI markings and calibrated axes. Cursor crosshairs are transient.
    crosses = [(line, line.isVisible()) for pair in window._crosshairs.values() for line in pair]
    try:
        for line, _ in crosses:
            line.hide()
        image = window.graphics.grab().toImage().copy()
    finally:
        for line, visible in crosses:
            line.setVisible(visible)
    if image.isNull():
        raise FindingError("The displayed image could not be captured.")
    return Capture(image, tuple(arrays), metadata, tuple(sources.values()))


class FindingsService(QtCore.QObject):
    """One explicit operation at a time; saves outlive disposable workspaces."""

    completed = QtCore.Signal(object, object)
    changed = QtCore.Signal()

    def __init__(self, parent=None, *, store=None):
        super().__init__(parent)
        self.store = store or FindingStore()
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ejn-findings")
        self.active = None
        self.closed = False
        self.review = None
        self._clipboard_mime = None
        self._clipboard_bytes = 0
        QtWidgets.QApplication.clipboard().dataChanged.connect(self._clipboard_changed)
        self.admit = lambda: sum(self.allocations.values()) <= MAX_MEMORY
        self.completed.connect(self._finished)

    @property
    def allocations(self):
        result = {}
        if self._clipboard_bytes:
            result["finding-clipboard", id(self)] = self._clipboard_bytes
        if self.active is not None:
            capture = self.active.get("capture")
            if capture is not None:
                for source in capture.sources:
                    result = merge_allocations(result, source_allocations(source))
                for array in capture.arrays:
                    result["capture-array", id(array)] = array.nbytes
                # Detached pixels, encoded PNG, decoded pixels, Pillow's RGBA
                # premultiplication and resampling intermediate can coexist.
                # Derived preview pixels/encoding remain separately bounded.
                image_bytes = (capture.image.sizeInBytes() if capture.image is not None
                               else self.active.get("image_bytes", 0))
                result["capture-image", id(capture)] = image_bytes * 5 + PREVIEW_RESERVE
                result["finding-io", id(self)] = self.active.get("reserve_bytes", 0)
            else:
                result["finding-io", id(self)] = self.active.get("reserve_bytes", IO_RESERVE)
        if self.review is not None and not self.review._closed:
            result["finding-review", id(self)] = self.review.reserved_bytes
        return result

    def _clipboard_changed(self):
        if QtWidgets.QApplication.clipboard().mimeData() is not self._clipboard_mime:
            self._clipboard_mime = None
            self._clipboard_bytes = 0

    def submit(self, function, callback, *, capture=None, reserve_bytes=IO_RESERVE):
        if self.closed or self.active is not None:
            raise FindingError("A findings operation is still running; try again shortly.")
        job = {"callback": callback, "capture": capture, "reserve_bytes": reserve_bytes}
        self.active = job
        if not self.admit():
            self.active = None
            raise FindingError("This operation exceeds the local memory budget; close another viewer first.")
        future = self.executor.submit(function)

        def done(value):
            if not self.closed:
                try:
                    self.completed.emit(job, value)
                except RuntimeError:
                    pass
        future.add_done_callback(done)

    def _finished(self, job, future):
        if self.active is not job:
            return
        self.active = None
        if self.closed:
            return
        try:
            result, error = future.result(), ""
        except Exception as exc:
            result, error = None, str(exc) or "The local findings operation failed."
        job["callback"](result, error)

    def submit_mutation(self, function, callback, *, success_message, capture=None):
        """Commit a change and refresh its Org index in the same worker job.

        The assets are durable before index generation. A failed index must
        never turn that completed change into a failure the user might repeat.
        """
        def update():
            result = function()
            try:
                self.store.org_overview()
            except Exception as exc:
                return result, str(exc) or "The local overview operation failed."
            return result, ""

        def updated(value, error):
            if error:
                callback(None, error)
                return
            result, warning = value
            callback(result, "")
            if warning:
                self._message(success_message + ", but the Org overview could not be refreshed.\n" + warning)

        self.submit(update, updated, capture=capture, reserve_bytes=ORG_RESERVE)

    def capture(self, window, *, ask_note=True):
        if self.active is not None:
            raise FindingError("A findings operation is still running; try again shortly.")
        def admit(capture, image_bytes):
            self.active = {"capture": capture, "image_bytes": image_bytes,
                           "reserve_bytes": ORG_RESERVE}
            try:
                if not self.admit():
                    raise FindingError("This capture exceeds the local memory budget; reduce the viewer window or close another viewer.")
            finally:
                self.active = None
        frozen = freeze_window(window, admit=admit)

        def saved(result, error):
            if not window._closed:
                window.analysis_status.setText(error or "Finding saved. Review it with Findings.")
            if error:
                return
            if ask_note:
                self.edit_note(result["id"], "", window if not window._closed else None)
            else:
                self.changed.emit()

        window.analysis_status.setText("Saving finding…")
        self.submit_mutation(lambda: self.store.save(frozen), saved,
                             success_message="Finding saved", capture=frozen)

    def edit_note(self, identifier, note, parent=None):
        dialog = QtWidgets.QDialog(parent)
        dialog.setWindowTitle("Finding saved")
        layout = QtWidgets.QVBoxLayout(dialog)
        label = QtWidgets.QLabel("Optional observation (you can edit it later):", dialog)
        label.setTextFormat(QtCore.Qt.TextFormat.PlainText)
        layout.addWidget(label)
        line = QtWidgets.QLineEdit(note, dialog)
        line.setMaxLength(MAX_NOTE)
        line.setMinimumWidth(420)
        layout.addWidget(line)
        buttons = QtWidgets.QDialogButtonBox(QtWidgets.QDialogButtonBox.StandardButton.Save
                    | QtWidgets.QDialogButtonBox.StandardButton.Cancel, dialog)
        layout.addWidget(buttons)
        buttons.rejected.connect(dialog.reject)
        dialog._closed = False
        dialog.finished.connect(lambda: setattr(dialog, "_closed", True))
        dialog.destroyed.connect(lambda: setattr(dialog, "_closed", True))
        dialog.setAttribute(QtCore.Qt.WidgetAttribute.WA_DeleteOnClose)
        # Retain top-level dialogs after a workspace closes during saving.
        self._note_dialog = dialog

        # Rejection/busy must leave the entered observation available to retry.
        def accepted():
            def updated(_value, error):
                if error:
                    if dialog._closed:
                        self._message(error)
                    else:
                        label.setText(error + "\nObservation:")
                        buttons.setEnabled(True)
                else:
                    if not dialog._closed:
                        dialog.accept()
                    self.changed.emit()
            try:
                buttons.setEnabled(False)
                self.submit_mutation(lambda value=line.text(): self.store.update_note(identifier, value), updated,
                                     success_message="Observation saved")
            except FindingError as exc:
                label.setText(str(exc) + "\nObservation:")
                buttons.setEnabled(True)
        buttons.accepted.connect(accepted)
        dialog.rejected.connect(self.changed.emit)
        dialog.open()

    def _message(self, message):
        box = QtWidgets.QMessageBox(self.review)
        box.setAttribute(QtCore.Qt.WidgetAttribute.WA_DeleteOnClose)
        box.setWindowTitle("Findings")
        box.setText(message)
        box.open()
        self._message_box = box

    def show_review(self):
        if self.review is None or self.review._closed:
            self.review = FindingsWindow(self)
        self.review.show()
        self.review.raise_()
        self.review.activateWindow()
        self.review.refresh()
        return self.review

    def shutdown(self):
        if self.closed:
            return
        self.closed = True
        QtWidgets.QApplication.clipboard().dataChanged.disconnect(self._clipboard_changed)
        if self.review is not None:
            self.review.close()
        self.executor.shutdown(wait=False, cancel_futures=True)


def findings_service():
    app = QtWidgets.QApplication.instance()
    service = getattr(app, "_ejn_findings", None)
    if service is None or service.closed:
        service = FindingsService(app)
        app._ejn_findings = service
        app.aboutToQuit.connect(service.shutdown)
    return service


class FindingsWindow(QtWidgets.QMainWindow):
    def __init__(self, service):
        super().__init__()
        self.service = service
        self._closed = False
        self._current = None
        self._image_bytes = b""
        self._pixmap = QtGui.QPixmap()
        self._token = 0
        self.reserved_bytes = 0
        self._thumbnail_bytes = 0
        self.setWindowTitle("EJN findings")
        self.resize(1050, 760)
        central = QtWidgets.QWidget()
        layout = QtWidgets.QVBoxLayout(central)
        buttons = QtWidgets.QHBoxLayout()
        for text, callback in (("Refresh", self.refresh), ("Edit note", self.edit_note),
                               ("Copy image + caption", self.copy),
                               ("Remove", self.remove)):
            button = QtWidgets.QPushButton(text)
            button.clicked.connect(callback)
            buttons.addWidget(button)
        layout.addLayout(buttons)
        split = QtWidgets.QSplitter()
        self.list = QtWidgets.QListWidget()
        self.list.setSelectionMode(QtWidgets.QAbstractItemView.SelectionMode.ExtendedSelection)
        self.list.setIconSize(QtCore.QSize(120, 80))
        self.list.setMinimumWidth(280)
        self.list.setToolTip("Select a finding to review. Ctrl/Shift selects several for removal.")
        split.addWidget(self.list)
        details = QtWidgets.QWidget()
        detail = QtWidgets.QVBoxLayout(details)
        self.image = QtWidgets.QLabel("Select a finding")
        self.image.setAlignment(QtCore.Qt.AlignmentFlag.AlignCenter)
        self.image.setMinimumSize(160, 160)
        self.image.setSizePolicy(QtWidgets.QSizePolicy.Policy.Ignored, QtWidgets.QSizePolicy.Policy.Expanding)
        self.note = QtWidgets.QLabel()
        self.note.setWordWrap(True)
        self.note.setTextFormat(QtCore.Qt.TextFormat.PlainText)
        self.note.setTextInteractionFlags(QtCore.Qt.TextInteractionFlag.TextSelectableByMouse)
        self.context = QtWidgets.QPlainTextEdit()
        self.context.setReadOnly(True)
        self.context.setMaximumHeight(200)
        self.context.hide()
        self.context_button = QtWidgets.QToolButton()
        self.context_button.setText("Execution context")
        self.context_button.setCheckable(True)
        self.context_button.setArrowType(QtCore.Qt.ArrowType.RightArrow)
        self.context_button.setToolButtonStyle(QtCore.Qt.ToolButtonStyle.ToolButtonTextBesideIcon)
        self.context_button.setToolTip("Show recorded code, source identities and display settings")
        self.context_button.toggled.connect(self.context.setVisible)
        self.context_button.toggled.connect(lambda checked: self.context_button.setArrowType(
            QtCore.Qt.ArrowType.DownArrow if checked else QtCore.Qt.ArrowType.RightArrow))
        detail.addWidget(self.image, 1)
        detail.addWidget(self.note)
        detail.addWidget(self.context_button)
        detail.addWidget(self.context)
        split.addWidget(details)
        split.setStretchFactor(1, 1)
        layout.addWidget(split, 1)
        self.status = QtWidgets.QLabel("Saved findings stay here when outputs and kernels are gone.")
        self.status.setWordWrap(True)
        layout.addWidget(self.status)
        self.setCentralWidget(central)
        self.list.currentItemChanged.connect(self._selected)
        service.changed.connect(self.refresh)

    def _run(self, action, done, *, reserve_bytes=IO_RESERVE):
        try:
            self.service.submit(action, lambda result, error: None if self._closed else done(result, error),
                                reserve_bytes=reserve_bytes)
        except FindingError as exc:
            self.status.setText(str(exc))

    def refresh(self):
        if self._closed:
            return
        selected = self.list.currentItem()
        selected = selected.data(QtCore.Qt.ItemDataRole.UserRole) if selected else None
        self.list.blockSignals(True)
        self.list.clear()
        self.list.blockSignals(False)
        self._thumbnail_bytes = 0
        self._clear_preview()
        self._token += 1

        def loaded(value, error):
            if error:
                self.status.setText(error)
                return
            items, damaged = value
            self.list.blockSignals(True)
            self.list.clear()
            self._thumbnail_bytes = 0
            for value in items:
                pixmap = QtGui.QPixmap()
                pixmap.loadFromData(value["thumbnail"], "PNG")
                self._thumbnail_bytes += pixmap.width() * pixmap.height() * 4
                item = QtWidgets.QListWidgetItem(QtGui.QIcon(pixmap), value["created"][:16] + "\n" + (value["note"] or "Untitled finding"))
                item.setData(QtCore.Qt.ItemDataRole.UserRole, value["id"])
                self.list.addItem(item)
                if value["id"] == selected:
                    self.list.setCurrentItem(item)
            self.list.blockSignals(False)
            self._update_reservation()
            self.status.setText(f"{len(items)} findings, in capture order. Ctrl/Shift selects several for removal."
                                + (f" {damaged} unreadable findings skipped." if damaged else ""))
            if self.list.currentItem() is not None:
                self._selected(self.list.currentItem())
        self._run(self.service.store.catalog, loaded)

    def _selected(self, item, *_):
        self._token += 1
        token = self._token
        if item is None:
            return
        identifier = item.data(QtCore.Qt.ItemDataRole.UserRole)
        self._clear_preview()

        def loaded(value, error):
            if token != self._token:
                # A later click while IO was busy is resolved after this load.
                if self.list.currentItem() is not None:
                    self._selected(self.list.currentItem())
                return
            if error:
                self.status.setText(error)
                return
            self._current, self._image_bytes, preview = value
            self._pixmap.loadFromData(preview, "PNG")
            self._update_reservation()
            self.note.setText(self._current["note"] or "Untitled finding")
            self.context.setPlainText(json.dumps(self._current["view"], ensure_ascii=False, indent=2))
            self._paint_image()
        self._run(lambda: self.service.store.preview(identifier), loaded)

    def _clear_preview(self):
        self._current = None
        self._image_bytes = b""
        self._pixmap = QtGui.QPixmap()
        self.image.clear()
        self.note.clear()
        self.context.clear()
        self._update_reservation()

    def _paint_image(self):
        if not self._pixmap.isNull():
            self.image.setPixmap(self._pixmap.scaled(self.image.size().boundedTo(self._pixmap.size()),
                QtCore.Qt.AspectRatioMode.KeepAspectRatio, QtCore.Qt.TransformationMode.SmoothTransformation))

    def _update_reservation(self):
        self.reserved_bytes = (self._thumbnail_bytes + len(self._image_bytes)
                               + self._pixmap.width() * self._pixmap.height() * 8)

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._paint_image()

    def edit_note(self):
        if self._current:
            self.service.edit_note(self._current["id"], self._current["note"], self)

    def copy(self):
        if self._current is None:
            return
        if self.service.active is not None:
            self.status.setText("Wait for the current findings operation before copying.")
            return
        # Clipboard HTML and platform adapters can each duplicate the bytes.
        from .findings import MAX_IMAGE_PIXELS
        reserve = len(self._image_bytes) * 7 + MAX_IMAGE_PIXELS * 8
        self.service.active = {"reserve_bytes": reserve}
        try:
            if not self.service.admit():
                self.status.setText("Copy exceeds the local memory budget; close another viewer first.")
                return
        finally:
            self.service.active = None
        mime = QtCore.QMimeData()
        note = self._current["note"]
        image = QtGui.QImage.fromData(self._image_bytes, "PNG")
        mime.setImageData(image)
        mime.setText(note)
        encoded = base64.b64encode(self._image_bytes).decode("ascii")
        mime.setHtml('<figure><img src="data:image/png;base64,' + encoded + '"><figcaption>'
                     + html.escape(note) + '</figcaption></figure>')
        self.service._clipboard_mime = mime
        self.service._clipboard_bytes = image.sizeInBytes() * 2 + len(self._image_bytes) * 3
        QtWidgets.QApplication.clipboard().setMimeData(mime)
        self.status.setText("Copied image and caption.")

    def selected_ids(self):
        return [self.list.item(index).data(QtCore.Qt.ItemDataRole.UserRole)
                for index in range(self.list.count()) if self.list.item(index).isSelected()]

    def remove(self):
        identifiers = self.selected_ids()
        if identifiers and QtWidgets.QMessageBox.question(self, "Remove saved findings",
                f"Permanently remove {len(identifiers)} saved finding(s)?") == QtWidgets.QMessageBox.StandardButton.Yes:
            def removed(_value, error):
                if not self._closed:
                    if error:
                        self.status.setText(error)
                    else:
                        self.refresh()
            try:
                self.service.submit_mutation(lambda: self.service.store.delete(identifiers), removed,
                                             success_message="Findings removed")
            except FindingError as exc:
                self.status.setText(str(exc))

    def closeEvent(self, event):
        self._closed = True
        self._token += 1
        self.service.changed.disconnect(self.refresh)
        self._pixmap = QtGui.QPixmap()
        self._image_bytes = b""
        self.list.clear()
        self.reserved_bytes = 0
        super().closeEvent(event)
