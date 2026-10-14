"""Freeze before reruns, preserve per-pane context, and keep IO off the UI."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from pathlib import Path
from concurrent.futures import Future
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock

import numpy as np
from PIL import Image
from PySide6 import QtCore, QtWidgets

from ejn_viewer.findings import FindingError, FindingStore, MAX_IMAGE_EXTENT
from ejn_viewer.findings_gui import (CATALOG_RESERVE, FindingsService, FindingsWindow, PREVIEW_RESERVE,
                                     freeze_window, preview_reserve)
from ejn_viewer.memory import MIB, MIN_MEMORY_BUDGET_MIB, memory_budget, set_memory_budget
from ejn_viewer.workspace import PINNED, WorkspaceWindow
from test_analysis_gui import APP, pump_until, snapshot


def completed_future(function):
    """Model a worker finishing before add_done_callback is registered."""
    future = Future()
    try:
        future.set_result(function())
    except Exception as exc:
        future.set_exception(exc)
    return future


class FindingsGuiTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = FindingStore(Path(self.tmp.name) / "findings")
        self.service = FindingsService(store=self.store)
        self.addCleanup(self.service.shutdown)

    def window(self):
        window = WorkspaceWindow()
        self.addCleanup(window.close)
        data = snapshot()
        data.execution = "model-A"
        data.context = {"entries": [{"code": "model = A"}]}
        window.install_snapshot(data)
        window.show()
        APP.processEvents()
        return window

    def test_visible_pin_and_candidate_keep_their_own_original_context(self):
        window = self.window()
        window.pin_button.click()
        latest = snapshot(delta=17)
        latest.execution = "model-B"
        latest.context = {"entries": [{"code": "model = B"}]}
        window.install_snapshot(latest)
        frozen = freeze_window(window)
        panes = {p["name"]: p for p in frozen.metadata["panes"]}
        self.assertEqual(panes[PINNED]["sources"][0]["execution"], "model-A")
        self.assertEqual(panes["candidate"]["sources"][0]["execution"], "model-B")
        latest.context["entries"][0]["code"] = "model = C"
        self.assertEqual(panes["candidate"]["sources"][0]["context"]["entries"][0]["code"], "model = B")
        np.testing.assert_array_equal(frozen.arrays[-1], window._pinned.planes["reference"])

    def test_capture_before_note_and_rerun_survives_workspace_close(self):
        window = self.window()
        entered, release = threading.Event(), threading.Event()
        original = self.store.save
        def slow(capture):
            entered.set()
            release.wait(3)
            return original(capture)
        self.addCleanup(release.set)
        notes = []
        self.service.edit_note = lambda identifier, *args: notes.append(identifier)
        with mock.patch.object(self.store, "save", slow):
            self.service.capture(window)
            pump_until(entered.is_set)
            self.assertFalse(notes)
            self.assertTrue(self.service.allocations)
            with self.assertRaisesRegex(FindingError, "still running"):
                self.service.capture(window)
            window.install_snapshot(snapshot(delta=100))
            window.close()
            release.set()
            pump_until(lambda: self.service.active is None)
        self.assertEqual(len(notes), 1)
        manifest, _image, arrays = self.store.load(notes[0], arrays=True)
        self.assertEqual(manifest["view"]["panes"][0]["sources"][0]["execution"], "model-A")
        np.testing.assert_array_equal(arrays[0], np.arange(12).reshape(3, 4))

    def test_capture_generates_overview_off_ui_before_optional_note(self):
        window = self.window()
        entered, release = threading.Event(), threading.Event()
        original = self.store.org_overview
        gui_thread = threading.get_ident()
        notes, worker_threads, overview_at_prompt = [], [], []
        def slow():
            worker_threads.append(threading.get_ident())
            entered.set()
            release.wait(3)
            return original()
        def note(identifier, *_args):
            path = self.store.root / "findings.org"
            overview_at_prompt.append(path.read_text() if path.exists() else "")
            notes.append(identifier)
        self.addCleanup(release.set)
        self.service.edit_note = note
        with mock.patch.object(self.store, "org_overview", slow):
            self.service.capture(window)
            pump_until(entered.is_set)
            self.assertFalse(notes)
            self.assertEqual(len(self.store.catalog()[0]), 1)
            with self.assertRaisesRegex(FindingError, "still running"):
                self.service.capture(window)
            # The GUI keeps processing events while generation owns the worker.
            responsive = []
            QtCore.QTimer.singleShot(0, lambda: responsive.append(True))
            pump_until(lambda: responsive)
            release.set()
            pump_until(lambda: self.service.active is None)
        self.assertEqual(len(notes), 1)
        self.assertIn(notes[0], overview_at_prompt[0])
        self.assertEqual(len(worker_threads), 1)
        self.assertNotEqual(worker_threads[0], gui_thread)

    def test_capture_admits_overview_memory_before_grabbing_image(self):
        window = self.window()
        scale = window.graphics.devicePixelRatioF()
        image_bytes = int(window.graphics.width() * window.graphics.height() * scale * scale * 4)
        # Enough for capture encoding, but not its additional 64 MiB Org job.
        available = image_bytes * 5 + PREVIEW_RESERVE + 32 * 1024**2
        self.service.admit = lambda: sum(self.service.allocations.values()) <= available
        with mock.patch.object(window.graphics, "grab", side_effect=AssertionError("unexpected screenshot")):
            with self.assertRaisesRegex(FindingError, "memory budget"):
                self.service.capture(window)
        self.assertIsNone(self.service.active)
        self.assertFalse(self.store.root.exists())

    def test_blink_capture_stores_the_actually_visible_reference_samples(self):
        window = self.window()
        window.pin_button.click()
        window.install_snapshot(snapshot(delta=100))
        window._blink(True)
        frozen = freeze_window(window)
        candidate = list(window._items).index("candidate")
        np.testing.assert_array_equal(frozen.arrays[candidate], window._pinned.planes["reference"])
        self.assertEqual(frozen.metadata["panes"][candidate]["sources"][0]["execution"], "model-A")

    def test_review_recovers_after_new_service_copies_image_and_caption(self):
        kept = self.store.save(freeze_window(self.window()), "Artifact in this slice")
        review = FindingsWindow(self.service)
        self.service.review = review
        self.addCleanup(review.close)
        review.show()
        review.refresh()
        pump_until(lambda: review.list.count() == 1)
        review.list.setCurrentRow(0)
        pump_until(lambda: review._current is not None)
        self.assertEqual(review._current["id"], kept["id"])
        self.assertIn("model = A", review.context.toPlainText())
        review.copy()
        self.assertEqual(APP.clipboard().text(), "Artifact in this slice")
        self.assertTrue(APP.clipboard().mimeData().hasImage())
        self.assertIn("figcaption", APP.clipboard().mimeData().html())
        APP.clipboard().clear()
        self.assertEqual(self.service._clipboard_bytes, 0)

    def test_review_and_preview_fit_beside_large_workspace_at_minimum_budget(self):
        kept = self.store.save(freeze_window(self.window()), "Kept")
        self.addCleanup(set_memory_budget, memory_budget() // MIB)
        set_memory_budget(MIN_MEMORY_BUDGET_MIB)
        # A workspace holding 160 MiB left no room for the former fixed
        # 192 MiB review reservation at this budget.
        self.service.admit = lambda: 160 * MIB + sum(self.service.allocations.values()) <= memory_budget()
        reserves, submit = [], self.service.submit
        def recorded(function, callback, **options):
            reserves.append(options["reserve_bytes"])
            return submit(function, callback, **options)
        review = FindingsWindow(self.service)
        self.service.review = review
        self.addCleanup(review.close)
        with mock.patch.object(self.service, "submit", side_effect=recorded):
            review.show()
            review.refresh()
            pump_until(lambda: review.list.count() == 1)
            review.list.setCurrentRow(0)
            pump_until(lambda: review._current is not None)
        self.assertEqual(review._current["id"], kept["id"])
        path = self.store.root / kept["id"] / "image.png"
        with Image.open(path) as image:
            pixels = image.width * image.height
        self.assertEqual(reserves, [CATALOG_RESERVE, preview_reserve(path.stat().st_size, pixels)])

    def test_capture_charges_source_views_once_and_derived_planes_with_workspace(self):
        window = self.window()
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        frozen = freeze_window(window)
        self.assertEqual(len(frozen.arrays), 3)
        self.service.active = {"capture": frozen, "image_bytes": 0, "reserve_bytes": 0}
        try:
            charged = self.service.allocations
        finally:
            self.service.active = None
        self.assertIn(("source", id(window._snapshot)), charged)
        # Displayed source planes are views of that charged source. Only the
        # derived difference is charged, under the key the workspace uses.
        arrays = {key for key in charged if key[0] == "array"}
        self.assertEqual(len(arrays), 1)
        self.assertLessEqual(arrays, set(window.allocations))

    def test_capture_budget_rejection_retains_no_worker_job(self):
        window = self.window()
        scale = window.graphics.devicePixelRatioF()
        image_bytes = int(window.graphics.width() * window.graphics.height() * scale * scale * 4)
        # Four screenshot buffers fit, but the resampler needs a fifth. Reject
        # before allocating a screenshot or starting any persistence work.
        available = image_bytes * 4 + PREVIEW_RESERVE
        self.service.admit = lambda: sum(self.service.allocations.values()) <= available
        with mock.patch.object(window.graphics, "grab", side_effect=AssertionError("unexpected screenshot")):
            with self.assertRaisesRegex(FindingError, "memory budget"):
                self.service.capture(window)
        self.assertIsNone(self.service.active)
        self.assertFalse(self.store.root.exists())

    def test_pathological_image_extent_rejected_before_grab_or_worker(self):
        window = self.window()
        with (mock.patch.object(window.graphics, "width", return_value=1),
              mock.patch.object(window.graphics, "height", return_value=MAX_IMAGE_EXTENT + 1),
              mock.patch.object(window.graphics, "grab", side_effect=AssertionError("unexpected screenshot"))):
            with self.assertRaisesRegex(FindingError, "reduce the viewer window"):
                self.service.capture(window)
        self.assertIsNone(self.service.active)
        self.assertFalse(self.store.root.exists())

    def test_pending_snapshot_cannot_replace_visible_capture(self):
        window = self.window()
        with mock.patch.object(window, "_gesturing", return_value=True):
            self.assertFalse(window.install_snapshot(snapshot(delta=99)))
            frozen = freeze_window(window)
        self.assertEqual(frozen.metadata["panes"][0]["sources"][0]["execution"], "model-A")
        np.testing.assert_array_equal(frozen.arrays[0], np.arange(12).reshape(3, 4))

    def test_volume_capture_keeps_selected_plane_and_original_slice_setting(self):
        from test_volume_gui import volume_snapshot
        window = self.window()
        original = volume_snapshot()
        window.install_snapshot(original)
        window.select_volume_slice(name="reference", axis=1, index=4)
        kept = self.store.save(freeze_window(window))
        manifest, _image, arrays = self.store.load(kept["id"], arrays=True)
        np.testing.assert_array_equal(arrays[0], original.planes["reference"][:, 4, :])
        setting = manifest["view"]["panes"][0]["sources"][0]["selection"]
        self.assertEqual(setting["axis"], 1)
        self.assertEqual(setting["indices"][1], 4)
        self.assertEqual(arrays[0].ndim, 2)

    def test_capture_control_requires_exact_existing_workspace(self):
        from ejn_viewer.ipc import PipeServer
        window = self.window()
        service = mock.Mock()
        server = SimpleNamespace(negotiated=True, windows={"one": window}, findings=service, reply=mock.Mock())
        PipeServer.dispatch(server, {"v": 1, "id": "a", "op": "capture", "params": {"workspace": "missing"}})
        service.capture.assert_not_called()
        server.reply.assert_called_once_with("a", error="workspace-not-found")
        PipeServer.dispatch(server, {"v": 1, "id": "b", "op": "capture", "params": {"workspace": "one"}})
        service.capture.assert_called_once_with(window)
        service.capture.side_effect = FindingError("This operation exceeds the local memory budget; close another viewer first.")
        PipeServer.dispatch(server, {"v": 1, "id": "c", "op": "capture", "params": {"workspace": "one"}})
        server.reply.assert_called_with("c", error="capture-failed")
        self.assertIn("memory budget", window.analysis_status.text())

    def test_busy_note_write_keeps_typed_observation_for_retry(self):
        kept = self.store.save(freeze_window(self.window()))
        self.service.edit_note(kept["id"], "")
        dialog = self.service._note_dialog
        self.addCleanup(lambda: dialog.close() if not dialog._closed else None)
        line = dialog.findChild(QtWidgets.QLineEdit)
        line.setText("The important observation")
        buttons = dialog.findChild(QtWidgets.QDialogButtonBox)
        self.service.active = {"reserve_bytes": 1}
        buttons.accepted.emit()
        self.assertTrue(dialog.isVisible())
        self.assertEqual(line.text(), "The important observation")
        self.service.active = None
        buttons.accepted.emit()
        pump_until(lambda: self.service.active is None)
        self.assertEqual(self.store.manifest(kept["id"])["note"], "The important observation")
        self.assertIn("* The important observation", (self.store.root / "findings.org").read_text())

    def test_removing_findings_updates_overview_including_empty_collection(self):
        first = self.store.save(freeze_window(self.window()), "Remove first")
        second = self.store.save(freeze_window(self.window()), "Remove second")
        self.store.org_overview()
        review = FindingsWindow(self.service)
        self.service.review = review
        with mock.patch.object(QtWidgets.QMessageBox, "question",
                               return_value=QtWidgets.QMessageBox.StandardButton.Yes):
            for identifier, remaining in ((first["id"], 1), (second["id"], 0)):
                with mock.patch.object(review, "selected_ids", return_value=[identifier]):
                    review.remove()
                    pump_until(lambda: self.service.active is None)
                overview = (self.store.root / "findings.org").read_text()
                self.assertNotIn(identifier, overview)
                self.assertIn(f"{remaining} findings;", overview)

    def test_overview_failure_preserves_successful_capture_note_and_deletion(self):
        window = self.window()
        kept = self.store.save(freeze_window(window), "Initial observation")
        path = Path(self.store.org_overview()["path"])
        path.chmod(0o600)
        edited = path.read_bytes() + b"\n* My report draft\n"
        path.write_bytes(edited)
        self.service._message = mock.Mock()
        notes = []
        with mock.patch.object(self.service, "edit_note", side_effect=lambda identifier, *args: notes.append(identifier)):
            self.service.capture(window)
            pump_until(lambda: self.service.active is None)
        self.assertEqual(len(notes), 1)
        self.assertEqual(len(self.store.catalog()[0]), 2)
        self.assertIn("Finding saved", window.analysis_status.text())
        self.assertEqual(path.read_bytes(), edited)
        self.service.edit_note(kept["id"], "Initial observation")
        dialog = self.service._note_dialog
        dialog.findChild(QtWidgets.QLineEdit).setText("Observation updated")
        dialog.findChild(QtWidgets.QDialogButtonBox).accepted.emit()
        pump_until(lambda: self.service.active is None)
        self.assertTrue(dialog._closed)
        self.assertEqual(self.store.manifest(kept["id"])["note"], "Observation updated")
        review = FindingsWindow(self.service)
        self.service.review = review
        with (mock.patch.object(review, "selected_ids", return_value=[kept["id"]]),
              mock.patch.object(QtWidgets.QMessageBox, "question",
                                return_value=QtWidgets.QMessageBox.StandardButton.Yes)):
            review.remove()
            pump_until(lambda: self.service.active is None)
        self.assertEqual([entry["id"] for entry in self.store.catalog()[0]], notes)
        self.assertEqual(path.read_bytes(), edited)
        self.assertEqual(self.service._message.call_count, 3)
        for call in self.service._message.call_args_list:
            self.assertIn("overview", call.args[0])
            self.assertIn("has been edited", call.args[0])

    def test_overview_io_failure_does_not_repeat_or_fail_capture(self):
        window = self.window()
        self.service._message = mock.Mock()
        with (mock.patch.object(self.store, "org_overview", side_effect=OSError("disk failure")) as overview,
              mock.patch.object(self.store, "save", wraps=self.store.save) as save):
            self.service.capture(window, ask_note=False)
            pump_until(lambda: self.service.active is None)
        save.assert_called_once()
        overview.assert_called_once()
        self.assertEqual(len(self.store.catalog()[0]), 1)
        self.assertIn("Finding saved", window.analysis_status.text())
        self.assertIn("disk failure", self.service._message.call_args.args[0])

    def test_note_overview_memory_rejection_keeps_draft_and_old_note(self):
        kept = self.store.save(freeze_window(self.window()), "Before")
        self.service.edit_note(kept["id"], "Before")
        dialog = self.service._note_dialog
        self.addCleanup(lambda: dialog.close() if not dialog._closed else None)
        line = dialog.findChild(QtWidgets.QLineEdit)
        line.setText("Keep my draft")
        self.service.admit = lambda: sum(self.service.allocations.values()) < 64 * 1024**2
        dialog.findChild(QtWidgets.QDialogButtonBox).accepted.emit()
        self.assertIsNone(self.service.active)
        self.assertTrue(dialog.isVisible())
        self.assertEqual(line.text(), "Keep my draft")
        self.assertEqual(self.store.manifest(kept["id"])["note"], "Before")

    def test_failed_capture_does_not_generate_overview_or_report_success(self):
        window = self.window()
        self.service._message = mock.Mock()
        self.service.edit_note = mock.Mock()
        with (mock.patch.object(self.store, "save", side_effect=OSError("capture disk failure")),
              mock.patch.object(self.store, "org_overview") as overview,
              mock.patch.object(self.service.executor, "submit", side_effect=completed_future)):
            self.service.capture(window)
            pump_until(lambda: self.service.active is None)
        overview.assert_not_called()
        self.service.edit_note.assert_not_called()
        self.service._message.assert_not_called()
        self.assertEqual(window.analysis_status.text(), "capture disk failure")

    def test_immediate_note_failure_keeps_observation_enabled_for_retry(self):
        kept = self.store.save(freeze_window(self.window()), "Before")
        self.service.edit_note(kept["id"], "Before")
        dialog = self.service._note_dialog
        self.addCleanup(lambda: dialog.close() if not dialog._closed else None)
        line = dialog.findChild(QtWidgets.QLineEdit)
        buttons = dialog.findChild(QtWidgets.QDialogButtonBox)
        line.setText("Keep this observation")
        with (mock.patch.object(self.store, "update_note", side_effect=OSError("note disk failure")),
              mock.patch.object(self.service.executor, "submit", side_effect=completed_future)):
            buttons.accepted.emit()
        self.assertIsNone(self.service.active)
        self.assertTrue(dialog.isVisible())
        self.assertTrue(buttons.isEnabled())
        self.assertEqual(line.text(), "Keep this observation")
        self.assertEqual(self.store.manifest(kept["id"])["note"], "Before")

    def test_note_dialog_can_close_while_worker_keeps_the_observation(self):
        kept = self.store.save(freeze_window(self.window()))
        entered, release = threading.Event(), threading.Event()
        update = self.store.update_note
        def slow(identifier, note):
            entered.set()
            release.wait(3)
            return update(identifier, note)
        self.addCleanup(release.set)
        with mock.patch.object(self.store, "update_note", slow):
            self.service.edit_note(kept["id"], "")
            dialog = self.service._note_dialog
            dialog.findChild(QtWidgets.QLineEdit).setText("Keep despite close")
            dialog.findChild(QtWidgets.QDialogButtonBox).accepted.emit()
            pump_until(entered.is_set)
            dialog.reject()
            APP.processEvents()
            release.set()
            pump_until(lambda: self.service.active is None)
        self.assertEqual(self.store.manifest(kept["id"])["note"], "Keep despite close")

    def test_org_control_acknowledges_only_after_atomic_worker_completion(self):
        from ejn_viewer.ipc import PipeServer
        self.store.save(freeze_window(self.window()), "Interesting result")
        entered, release = threading.Event(), threading.Event()
        original = self.store.org_overview
        def slow():
            entered.set()
            release.wait(3)
            return original()
        self.addCleanup(release.set)
        server = SimpleNamespace(findings=self.service, reply=mock.Mock(), negotiated=True)
        self.service._message = mock.Mock()
        with mock.patch.object(self.store, "org_overview", slow):
            PipeServer.dispatch(server, {"v": 1, "id": "overview", "op": "findings_org", "params": {}})
            pump_until(entered.is_set)
            server.reply.assert_not_called()
            PipeServer.dispatch(server, {"v": 1, "id": "busy", "op": "findings_org", "params": {}})
            server.reply.assert_called_once_with("busy", error="findings-busy")
            release.set()
            pump_until(lambda: self.service.active is None)
        args = server.reply.call_args.args
        self.assertEqual(args[0], "overview")
        self.assertEqual(args[1]["count"], 1)
        self.assertTrue(Path(args[1]["path"]).is_file())


if __name__ == "__main__":
    unittest.main()
