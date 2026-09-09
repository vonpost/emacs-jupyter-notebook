"""Qt controls, bounded scheduling, and stale measurement fencing."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import gc
from types import SimpleNamespace
import threading
import time
import unittest
from unittest import mock

import numpy as np
from PySide6 import QtCore, QtTest, QtWidgets

from ejn_viewer.analysis import DIFFERENCE
from ejn_viewer.analysis_worker import AnalysisJob, AnalysisWorker, compute
from ejn_viewer.workspace import WorkspaceWindow
from ejn_viewer.memory import source_allocations
from ejn_viewer.ipc import MAX_MEMORY, PipeServer


APP = QtWidgets.QApplication.instance() or QtWidgets.QApplication([])


def snapshot(*, sample="sample", generation=1, numerical=True, delta=0):
    arrays = {"reference": np.arange(12, dtype=np.float32).reshape(3, 4) + delta,
              "candidate": np.arange(12, dtype=np.float32).reshape(3, 4) + delta + 2}
    for array in arrays.values():
        array.setflags(write=False)
    return SimpleNamespace(planes=arrays, numerical=numerical, generation=generation,
                           workspace="test", nbytes=sum(a.nbytes for a in arrays.values()),
                           manifest={"sample_id": sample, "planes": [
                               {"name": name, "grid_id": "grid", "units": "HU"} for name in arrays]})


def pump_until(predicate, timeout=5):
    deadline = time.monotonic() + timeout
    while not predicate() and time.monotonic() < deadline:
        APP.processEvents()
        QtTest.QTest.qWait(5)
    if not predicate():
        raise AssertionError("timed out waiting for local analysis")


class AnalysisGuiTests(unittest.TestCase):
    def window(self, data=None, **kw):
        window = WorkspaceWindow(**kw)
        self.addCleanup(window.close)
        window.install_snapshot(data or snapshot())
        window.show()
        APP.processEvents()
        return window

    def test_signed_absolute_selectors_and_linked_rectangle_measurement(self):
        window = self.window()
        before = {name: array.copy() for name, array in window._snapshot.planes.items()}
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, np.full((3, 4), 2.))
        self.assertEqual(len(window._views), 3)
        self.assertIn("candidate − reference", window._display_name(DIFFERENCE))
        window.rectangle_button.click()
        identifier = window.roi_selector.currentData()
        item = window._roi_items[identifier, "reference"]
        item.setPos((0, 0))
        item.setSize((2, 2))
        pump_until(lambda: len(window._statistics) == 3)
        result = window._statistics[identifier, "reference"]
        self.assertEqual((result.mean, result.finite, result.excluded), (2.5, 4, 0))
        self.assertAlmostEqual(result.sd, np.sqrt(4.25))
        derived = window._statistics[identifier, DIFFERENCE]
        self.assertEqual((derived.mean, derived.sd), (2, 0))
        for name in ("candidate", DIFFERENCE):
            self.assertEqual(tuple(window._roi_items[identifier, name].pos()), (0, 0))
            self.assertEqual(tuple(window._roi_items[identifier, name].size()), (2, 2))
        self.assertEqual(window.stats_table.rowCount(), 3)
        token, stats = window._analysis_token, window._statistics
        window.level.setValue(50)
        window.width.setValue(5)
        window.fit()
        APP.processEvents()
        self.assertEqual(window._analysis_token, token)
        self.assertIs(window._statistics, stats)
        window.reference.setCurrentText("candidate")
        window.candidate.setCurrentText("reference")
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, np.full((3, 4), -2.))
        window.comparison.setCurrentIndex(2)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, np.full((3, 4), 2.))
        for name, array in window._snapshot.planes.items():
            np.testing.assert_array_equal(array, before[name])

    def test_ellipse_move_resize_remove_and_definition_limit(self):
        window = self.window()
        window.ellipse_button.click()
        identifier = window.roi_selector.currentData()
        roi = window._roi_items[identifier, "reference"]
        roi.setPos((.5, .5))
        roi.setSize((2, 2))
        self.assertFalse(any(handle["type"] in ("r", "sr") for handle in roi.handles))
        pump_until(lambda: bool(window._statistics))
        stats = window._statistics[identifier, "reference"]
        self.assertEqual((stats.mean, stats.finite), (5, 5))
        window.remove_roi_button.click()
        self.assertFalse(window._regions)
        self.assertFalse(window._statistics)
        self.assertFalse(window._roi_items)
        for _ in range(17):
            window.add_roi("rectangle")
            gc.collect()
        self.assertEqual(len(window._regions), 16)
        self.assertFalse(window.rectangle_button.isEnabled())
        retained = dict(window._roi_items)
        window.remove_roi(next(iter(window._regions)))
        # Addition/removal must not churn every surviving Qt handle; that
        # formerly allowed cyclic GC to destroy scene objects mid-construction.
        for key, item in window._roi_items.items():
            self.assertIs(item, retained[key])

    def test_missing_metadata_is_explicit_and_conflicting_units_stay_disabled(self):
        data = snapshot()
        for meta in data.manifest["planes"]:
            meta.pop("grid_id")
            meta.pop("units")
        window = self.window(data)
        window.comparison.setCurrentIndex(1)
        self.assertIn("pixel grids", window.analysis_status.text())
        window.declare_grid.setChecked(True)
        self.assertIn("matching units", window.analysis_status.text())
        window.declare_units.setChecked(True)
        pump_until(lambda: window._difference is not None)
        window.rectangle_button.click()
        window.install_snapshot(data)
        self.assertTrue(window.declare_grid.isChecked())
        self.assertTrue(window.declare_units.isChecked())
        self.assertEqual(len(window._regions), 1)
        window._metadata["candidate"]["units"] = "different"
        window._comparison_changed()
        self.assertIsNone(window._difference)
        self.assertIn("matching units", window.analysis_status.text())

    def test_raster_quantitative_controls_are_explicitly_disabled(self):
        window = self.window(snapshot(numerical=False))
        for widget in (window.rectangle_button, window.ellipse_button, window.comparison,
                       window.reference, window.candidate):
            self.assertFalse(widget.isEnabled())
        self.assertIn("Rendered image", window.analysis_status.text())
        window.add_roi("rectangle")
        self.assertFalse(window._regions)
        self.assertIsNone(window._worker.active)

    def test_roi_preserved_only_for_same_declared_sample_and_generation(self):
        window = self.window()
        window.rectangle_button.click()
        identifier = window.roi_selector.currentData()
        roi = window._roi_items[identifier, "reference"]
        roi.setPos((1, 1))
        roi.setSize((1, 1))
        region = window._regions[identifier]
        window.install_snapshot(snapshot(delta=100))
        self.assertEqual(window._regions[identifier], region)
        pump_until(lambda: bool(window._statistics))
        self.assertEqual(window._statistics[identifier, "reference"].mean, 105)
        window.install_snapshot(snapshot(sample="another"))
        self.assertFalse(window._regions)
        window.rectangle_button.click()
        window.install_snapshot(snapshot(sample="another", generation=2))
        self.assertFalse(window._regions)

    def test_difference_display_range_survives_compatible_rerun(self):
        window = self.window()
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        original_levels = tuple(window._items[DIFFERENCE].getLevels())
        replacement = snapshot()
        replacement.planes["candidate"] = replacement.planes["candidate"] + 100
        window.install_snapshot(replacement)
        pump_until(lambda: window._difference is not None)
        self.assertEqual(tuple(window._items[DIFFERENCE].getLevels()), original_levels)
        np.testing.assert_array_equal(window._difference, np.full((3, 4), 102.))

    def test_worker_coalesces_off_thread_and_fences_snapshot_and_roi_changes(self):
        entered, release = threading.Event(), threading.Event()
        threads = []
        original = compute
        def delayed(job):
            threads.append(threading.get_ident())
            entered.set()
            if len(threads) == 1:
                release.wait(5)
                # Simulate a successful obsolete result even after cancellation.
                job.cancelled.clear()
            return original(job)
        with mock.patch("ejn_viewer.analysis_worker.compute", side_effect=delayed):
            window = self.window()
            self.addCleanup(release.set)
            window.rectangle_button.click()
            window._analysis_timer.stop()
            window._submit_analysis()
            pump_until(entered.is_set)
            old = window._worker.active
            for shift in range(6):
                item = window._roi_items[1, "reference"]
                item.setPos((shift / 10, 0))
                window._analysis_timer.stop()
                window._submit_analysis()
            self.assertIs(window._worker.active, old)
            self.assertIsNotNone(window._worker.pending)
            self.assertEqual(window._worker.pending.token, window._analysis_token)
            window.install_snapshot(snapshot(delta=100))
            window._analysis_timer.stop()
            window._submit_analysis()
            # GUI callbacks still run while numerical work is blocked.
            ticks = []
            QtCore.QTimer.singleShot(0, lambda: ticks.append(True))
            APP.processEvents()
            self.assertTrue(ticks)
            release.set()
            pump_until(lambda: bool(window._statistics))
            self.assertGreater(window._statistics[1, "reference"].mean, 100)
            self.assertEqual(len(threads), 2)
            self.assertTrue(all(identifier != threading.get_ident() for identifier in threads))

    def test_worker_budget_rejection_and_release_on_close(self):
        worker = AnalysisWorker(admit=lambda: False)
        self.addCleanup(worker.shutdown)
        window = self.window(analysis_worker=worker)
        window.rectangle_button.click()
        pump_until(lambda: "memory budget" in window.analysis_status.text())
        self.assertEqual(worker.reserved, 0)
        self.assertIsNone(worker.active)
        self.assertIsNone(worker.pending)
        window.close()
        window._analysis_ready(window, window._analysis_token - 1, (None, {}), "stale")
        self.assertNotEqual(window.analysis_status.text(), "stale")

    def test_cancelled_active_source_reservation_survives_window_close(self):
        entered, release = threading.Event(), threading.Event()
        def delayed(job):
            entered.set()
            release.wait(5)
            return compute(job)
        worker = AnalysisWorker()
        self.addCleanup(worker.shutdown)
        with mock.patch("ejn_viewer.analysis_worker.compute", side_effect=delayed):
            window = self.window(analysis_worker=worker)
            self.addCleanup(release.set)
            window.rectangle_button.click()
            window._analysis_timer.stop()
            window._submit_analysis()
            pump_until(entered.is_set)
            charge = worker.reserved
            self.assertGreater(charge, window._snapshot.nbytes)
            window.close()
            self.assertEqual(worker.reserved, charge)
            self.assertIsNot(worker.active.owner, window)
            release.set()
            pump_until(lambda: worker.reserved == 0)

    def test_2048_difference_roi_and_coalesced_move_fit_shared_budget(self):
        # Shape-only broadcast fixtures avoid allocating megabytes just to test
        # the real admission formulas; production snapshots are contiguous.
        data = snapshot()
        data.planes = {name: np.broadcast_to(np.float32(1), (2048, 2048))
                       for name in data.planes}
        data.nbytes = sum(array.nbytes for array in data.planes.values())
        derived = np.broadcast_to(np.float64(0), (2048, 2048))
        window = SimpleNamespace(allocations={**source_allocations(data), ("array", id(derived)): derived.nbytes, ("render", "test"): 3 * derived.size * 8})
        server = SimpleNamespace(windows={"test": window}, active=None)
        worker = AnalysisWorker(admit=lambda: PipeServer.memory_used(server) <= MAX_MEMORY)
        server.analysis = worker
        self.addCleanup(worker.shutdown)
        entered, release = threading.Event(), threading.Event()
        owner = object()
        def delayed(job):
            entered.set()
            release.wait(5)
            return compute(job)
        def job(token):
            return AnalysisJob(owner, token, data, (), {}, "reference", "candidate",
                               cached_difference=derived)
        with mock.patch("ejn_viewer.analysis_worker.compute", side_effect=delayed):
            self.addCleanup(release.set)
            worker.submit(job(1))
            pump_until(entered.is_set)
            self.assertLessEqual(PipeServer.memory_used(server), MAX_MEMORY)
            active_charge = worker.reserved
            for token in range(2, 10):
                worker.submit(job(token))
            self.assertIsNotNone(worker.pending)
            self.assertEqual(worker.pending.token, 9)
            self.assertEqual(worker.reserved, active_charge)
            release.set()
            pump_until(lambda: worker.active is None and worker.pending is None)


if __name__ == "__main__":
    unittest.main()
