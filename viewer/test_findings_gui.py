"""Freeze before reruns, preserve per-pane context, and keep IO off the UI."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from pathlib import Path
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock

import numpy as np
from PySide6 import QtCore, QtWidgets

from ejn_viewer.findings import FindingError, FindingStore, MAX_IMAGE_EXTENT
from ejn_viewer.findings_gui import FindingsService, FindingsWindow, PREVIEW_RESERVE, freeze_window
from ejn_viewer.workspace import PINNED, WorkspaceWindow
from test_analysis_gui import APP, pump_until, snapshot


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
