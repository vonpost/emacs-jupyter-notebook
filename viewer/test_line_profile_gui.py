"""Line drawing, linked profile plots, and bounded asynchronous lifecycle."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import threading
import unittest
from unittest import mock

import numpy as np
import pyqtgraph as pg
from PySide6 import QtCore, QtTest

from ejn_viewer.analysis import DIFFERENCE
from ejn_viewer.analysis_worker import AnalysisWorker, compute
from ejn_viewer.workspace import PINNED, WorkspaceWindow
from test_analysis_gui import APP, pump_until, snapshot


class LineProfileGuiTests(unittest.TestCase):
    def window(self, data=None, **kwargs):
        window = WorkspaceWindow(**kwargs)
        self.addCleanup(window.close)
        window.install_snapshot(data or snapshot())
        window.show()
        APP.processEvents()
        return window

    def line(self, window, start=(.5, 1.5), end=(3.5, 1.5), pane="reference"):
        """Complete the normal drawing callback with exact pixel coordinates."""
        window.arm_roi("line")
        window._draw_region(window._views[pane], QtCore.QPointF(*start),
                            QtCore.QPointF(*end), True)
        return window.roi_selector.currentData()

    def endpoints(self, item):
        points = [item.mapToParent(handle.pos()) for handle in item.getHandles()]
        return np.array([(point.x(), point.y()) for point in points])

    def assert_plotted(self, window, identifier, name, expected):
        profile = window._profiles[identifier, name]
        np.testing.assert_allclose(profile.values, expected)
        curve = window._profile_curves[name]
        distance, values = curve.getData()
        np.testing.assert_array_equal(distance, profile.distance)
        np.testing.assert_array_equal(values, profile.values)
        self.assertIn(curve, window.profile_plot.listDataItems())
        self.assertTrue(window.profile_plot.isVisible())
        return profile

    def test_draw_menu_reverse_slope_keeps_direction_and_plots_original_values(self):
        window = self.window()
        self.assertFalse(window.measurements_button.isChecked())
        action = next(action for action in window.draw_button.menu().actions()
                      if action.text() == "Draw line")
        action.trigger()
        self.assertEqual(window._draw_kind, "line")
        view = window._views["reference"]
        viewport = window.graphics.viewport()

        def position(x, y):
            return window.graphics.mapFromScene(view.mapViewToScene(QtCore.QPointF(x, y)))

        QtTest.QTest.mousePress(viewport, QtCore.Qt.MouseButton.LeftButton,
                               pos=position(.7, 2.2))
        QtTest.QTest.mouseMove(viewport, position(3.2, .7))
        self.assertFalse(window.measurements_button.isChecked())
        QtTest.QTest.mouseRelease(viewport, QtCore.Qt.MouseButton.LeftButton,
                                 pos=position(3.2, .7))
        self.assertIsNone(window._draw_kind)
        self.assertTrue(window.measurements_button.isChecked())
        identifier = window.roi_selector.currentData()
        region = window._regions[identifier]
        self.assertEqual(region.kind, "line")
        self.assertLess(region.height, 0)
        np.testing.assert_allclose((region.x, region.y), (.7, 2.2), atol=.04)
        np.testing.assert_allclose((region.x + region.width, region.y + region.height),
                                   (3.2, .7), atol=.04)
        pump_until(lambda: len(window._profiles) == 2)
        profile = window._profiles[identifier, "reference"]
        length = np.hypot(region.width, region.height)
        fraction = profile.distance / length
        # The fixture is f(x,y) = (x-.5) + 4*(y-.5). Bilinear
        # interpolation must preserve this plane at every sample position.
        expected = ((region.x + fraction * region.width - .5)
                    + 4 * (region.y + fraction * region.height - .5))
        self.assert_plotted(window, identifier, "reference", expected)
        self.assert_plotted(window, identifier, "candidate", expected + 2)
        self.assertAlmostEqual(profile.distance[0], 0)
        self.assertAlmostEqual(profile.distance[-1], length)
        self.assertFalse(window._statistics)
        self.assertEqual(window.stats_table.rowCount(), 0)
        self.assertIn(region.name, window.profile_status.text())
        self.assertIn("pixel", window.profile_plot.getAxis("bottom").labelText.lower()
                      + window.profile_plot.getAxis("bottom").labelUnits.lower())
        legend = window.profile_plot.getPlotItem().legend
        labels = [label.text for _, label in legend.items]
        self.assertTrue(any("reference" in label and "HU" in label for label in labels))
        self.assertTrue(any("candidate" in label and "HU" in label for label in labels))

    def test_endpoint_edit_and_nudge_keep_linked_handles_and_samples_in_sync(self):
        window = self.window()
        identifier = self.line(window)
        pump_until(lambda: len(window._profiles) == 2)
        item = window._roi_items[identifier, "candidate"]
        self.assertIsInstance(item, pg.LineSegmentROI)
        item.movePoint(item.getHandles()[1], QtCore.QPointF(2.5, .5), coords="parent")
        pump_until(lambda: len(window._profiles) == 2)
        np.testing.assert_allclose(self.endpoints(item), ((.5, 1.5), (2.5, .5)))
        for name in ("reference", "candidate"):
            np.testing.assert_allclose(self.endpoints(window._roi_items[identifier, name]),
                                       ((.5, 1.5), (2.5, .5)))
        self.assertEqual(window._regions[identifier].height, -1)
        old_values = window._profiles[identifier, "reference"].values.copy()
        old_distance = window._profiles[identifier, "reference"].distance.copy()
        window.nudge_roi(1, 1)
        pump_until(lambda: len(window._profiles) == 2)
        for name in ("reference", "candidate"):
            np.testing.assert_allclose(self.endpoints(window._roi_items[identifier, name]),
                                       ((1.5, 2.5), (3.5, 1.5)))
        np.testing.assert_array_equal(window._profiles[identifier, "reference"].distance, old_distance)
        self.assert_plotted(window, identifier, "reference", old_values + 5)

    def test_mouse_endpoint_drag_defers_sampling_until_release(self):
        window = self.window()
        identifier = self.line(window)
        pump_until(lambda: len(window._profiles) == 2)
        item = window._roi_items[identifier, "reference"]
        viewport = window.graphics.viewport()
        view = window._views["reference"]
        start = window.graphics.mapFromScene(item.getHandles()[1].scenePos())
        end = window.graphics.mapFromScene(view.mapViewToScene(QtCore.QPointF(2.5, .5)))
        with mock.patch.object(window._worker, "submit", wraps=window._worker.submit) as submit:
            QtTest.QTest.mousePress(viewport, QtCore.Qt.MouseButton.LeftButton, pos=start)
            try:
                QtTest.QTest.mouseMove(viewport, end)
                QtTest.QTest.qWait(160)
                self.assertEqual(submit.call_count, 0)
                self.assertFalse(window._profile_curves)
            finally:
                QtTest.QTest.mouseRelease(viewport, QtCore.Qt.MouseButton.LeftButton, pos=end)
            pump_until(lambda: len(window._profiles) == 2)
            self.assertEqual(submit.call_count, 1)
        np.testing.assert_allclose(self.endpoints(item), ((.5, 1.5), (2.5, .5)), atol=.04)
        profile = window._profiles[identifier, "reference"]
        self.assertAlmostEqual(profile.values[0], 4, places=5)
        self.assertAlmostEqual(profile.values[-1], 2, delta=.1)

    def test_long_line_plot_is_capped_and_nonfinite_or_outside_values_are_explicit(self):
        data = snapshot()
        data.planes = {name: np.arange(5000, dtype=np.float32)[None, :] + delta
                       for name, delta in (("reference", 0), ("candidate", 2))}
        for array in data.planes.values():
            array.setflags(write=False)
        data.nbytes = sum(array.nbytes for array in data.planes.values())
        window = self.window(data)
        identifier = self.line(window, start=(.5, .5), end=(4999.5, .5))
        pump_until(lambda: len(window._profiles) == 2)
        profile = window._profiles[identifier, "reference"]
        self.assertEqual(profile.values.size, 4096)
        self.assert_plotted(window, identifier, "reference", np.linspace(0, 4999, 4096))
        self.assertIn("4096", window.profile_status.text())
        self.assertIn("limit", window.profile_status.text())
        window.close()
        data = snapshot()
        data.planes["reference"] = np.full((3, 4), np.nan, dtype=np.float32)
        data.planes["candidate"] = np.full((3, 4), np.inf, dtype=np.float32)
        for array in data.planes.values():
            array.setflags(write=False)
        window = self.window(data)
        identifier = self.line(window)
        pump_until(lambda: len(window._profiles) == 2)
        self.assertIn("No finite", window.profile_status.text())
        self.assertTrue(all(np.isnan(curve.getData()[1]).all()
                            for curve in window._profile_curves.values()))
        window.nudge_roi(0, 10)
        pump_until(lambda: len(window._profiles) == 2)
        self.assertIn("outside", window.profile_status.text())
        self.assertTrue(all(profile.values.size == 0 for profile in window._profiles.values()))

    def test_selected_line_only_is_cached_and_area_measurements_remain_available(self):
        window = self.window()
        window.add_roi("rectangle")
        area = window.roi_selector.currentData()
        first = self.line(window, start=(.5, .5), end=(3.5, .5))
        pump_until(lambda: len(window._profiles) == 2 and len(window._statistics) == 2)
        self.assert_plotted(window, first, "reference", np.arange(4))
        second = self.line(window)
        pump_until(lambda: set(key[0] for key in window._profiles) == {second})
        self.assert_plotted(window, second, "reference", np.arange(4) + 4)
        self.assertEqual({key[0] for key in window._statistics}, {area})
        window.roi_selector.setCurrentIndex(window.roi_selector.findData(first))
        pump_until(lambda: set(key[0] for key in window._profiles) == {first})
        self.assert_plotted(window, first, "reference", np.arange(4))
        window.rename_roi("Upper edge")
        self.assertIn("Upper edge", window.profile_status.text())
        window.roi_selector.setCurrentIndex(window.roi_selector.findData(area))
        APP.processEvents()
        self.assertFalse(window.profile_plot.isVisible())
        self.assertFalse(window._profile_curves)
        self.assertTrue(window.stats_table.isVisible())
        pump_until(lambda: len(window._statistics) == 2)
        self.assertEqual(window.stats_table.rowCount(), 2)

    def test_display_changes_do_not_resample_or_mutate_source_arrays(self):
        data = snapshot()
        before = {name: array.copy() for name, array in data.planes.items()}
        window = self.window(data)
        identifier = self.line(window)
        pump_until(lambda: len(window._profiles) == 2)
        profiles = window._profiles
        token = window._analysis_token
        plotted = {name: tuple(array.copy() for array in curve.getData())
                   for name, curve in window._profile_curves.items()}
        window.level.setValue(500)
        window.width.setValue(3)
        window.fit()
        window._views["reference"].setRange(xRange=(1, 2), yRange=(1, 2), padding=0)
        window.blink_button.pressed.emit()
        window.blink_button.released.emit()
        APP.processEvents()
        self.assertEqual(window._analysis_token, token)
        self.assertIs(window._profiles, profiles)
        for name, (distance, values) in plotted.items():
            np.testing.assert_array_equal(window._profile_curves[name].getData()[0], distance)
            np.testing.assert_array_equal(window._profile_curves[name].getData()[1], values)
        for name, original in before.items():
            np.testing.assert_array_equal(data.planes[name], original)
            self.assertFalse(data.planes[name].flags.writeable)
        self.assert_plotted(window, identifier, "reference", np.arange(4) + 4)

    def test_pinned_reference_rerun_refreshes_candidate_and_difference_profiles(self):
        original = snapshot()
        window = self.window(original)
        window.pin_button.click()
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        identifier = self.line(window, pane=PINNED)
        pump_until(lambda: len(window._profiles) == 3)
        self.assert_plotted(window, identifier, PINNED, np.arange(4) + 4)
        self.assert_plotted(window, identifier, DIFFERENCE, np.full(4, 2))
        region = window._regions[identifier]
        replacement = snapshot(delta=10)
        window.install_snapshot(replacement)
        pump_until(lambda: len(window._profiles) == 3 and window._difference is not None)
        self.assertIs(window._pinned, original)
        self.assertEqual(window._regions[identifier], region)
        self.assert_plotted(window, identifier, PINNED, np.arange(4) + 4)
        self.assert_plotted(window, identifier, "candidate", np.arange(4) + 16)
        self.assert_plotted(window, identifier, DIFFERENCE, np.full(4, 12))

    def test_incompatible_grid_omits_false_comparison_and_missing_units_are_visible(self):
        data = snapshot()
        data.manifest["planes"][0].pop("units")
        data.manifest["planes"][1]["grid_id"] = "unrelated grid"
        window = self.window(data)
        identifier = self.line(window)
        pump_until(lambda: bool(window._profiles))
        self.assertEqual(set(window._profiles), {(identifier, "reference")})
        self.assertEqual(set(window._profile_curves), {"reference"})
        self.assertNotIn((identifier, "candidate"), window._roi_items)
        legend = window.profile_plot.getPlotItem().legend
        labels = [label.text.lower() for _, label in legend.items]
        self.assertTrue(any("unspecified" in label for label in labels))

    def test_add_line_opens_measurements_and_cancelled_drawing_leaves_no_profile(self):
        window = self.window()
        window.add_roi("line")
        self.assertTrue(window.measurements_button.isChecked())
        identifier = window.roi_selector.currentData()
        pump_until(lambda: len(window._profiles) == 2)
        self.assertTrue(window.profile_plot.isVisible())
        window.arm_roi("line")
        window._draw_region(window._views["reference"], QtCore.QPointF(.5, .5),
                            QtCore.QPointF(3.5, 2.5), False)
        cancelled = window.roi_selector.currentData()
        self.assertNotEqual(cancelled, identifier)
        QtTest.QTest.keyClick(window.graphics, QtCore.Qt.Key.Key_Escape)
        self.assertNotIn(cancelled, window._regions)
        self.assertIsNone(window._draw_kind)
        pump_until(lambda: set(key[0] for key in window._profiles) == {identifier})
        self.assertFalse(any(key[0] == cancelled for key in window._roi_items))
        window.remove_roi(identifier)
        APP.processEvents()
        self.assertFalse(window._profiles)
        self.assertFalse(window._profile_curves)
        self.assertFalse(window.profile_plot.isVisible())

    def test_slow_obsolete_profile_cannot_replace_selected_line_and_budget_is_released(self):
        entered, release = threading.Event(), threading.Event()
        threads, submitted = [], []
        worker = AnalysisWorker()
        self.addCleanup(worker.shutdown)

        def delayed(job):
            threads.append(threading.get_ident())
            submitted.append(job)
            if len(submitted) == 1:
                entered.set()
                release.wait(5)
                # Deliberately deliver a successful result from an obsolete
                # job to exercise the GUI's ownership/token fence itself.
                job.cancelled.clear()
            return compute(job)

        with mock.patch("ejn_viewer.analysis_worker.compute", side_effect=delayed):
            window = self.window(analysis_worker=worker)
            self.addCleanup(release.set)
            first = self.line(window, start=(.5, .5), end=(3.5, .5))
            window._analysis_timer.stop()
            window._submit_analysis()
            pump_until(entered.is_set)
            active = worker.active
            reservation = worker.reserved
            self.assertGreater(reservation, window._snapshot.nbytes)
            second = self.line(window)
            window._analysis_timer.stop()
            window._submit_analysis()
            self.assertIs(worker.active, active)
            self.assertIsNotNone(worker.pending)
            window.roi_selector.setCurrentIndex(window.roi_selector.findData(first))
            window.roi_selector.setCurrentIndex(window.roi_selector.findData(second))
            window._analysis_timer.stop()
            window._submit_analysis()
            self.assertEqual(worker.pending.token, window._analysis_token)
            ticks = []
            QtCore.QTimer.singleShot(0, lambda: ticks.append(True))
            APP.processEvents()
            self.assertTrue(ticks)
            self.assertFalse(window._profile_curves)
            release.set()
            pump_until(lambda: set(key[0] for key in window._profiles) == {second})
            self.assert_plotted(window, second, "reference", np.arange(4) + 4)
            self.assertEqual(len(submitted), 2)
            self.assertTrue(all(thread != threading.get_ident() for thread in threads))
            window._analysis_ready(window._analysis_owner, active.token, compute(active), "")
            self.assert_plotted(window, second, "reference", np.arange(4) + 4)
            pump_until(lambda: worker.reserved == 0)

    def test_close_active_line_job_fences_completion_and_releases_source(self):
        entered, release = threading.Event(), threading.Event()
        worker = AnalysisWorker()
        self.addCleanup(worker.shutdown)

        def delayed(job):
            entered.set()
            release.wait(5)
            return compute(job)

        with mock.patch("ejn_viewer.analysis_worker.compute", side_effect=delayed):
            window = self.window(analysis_worker=worker)
            self.addCleanup(release.set)
            self.line(window)
            window._analysis_timer.stop()
            window._submit_analysis()
            pump_until(entered.is_set)
            charge = worker.reserved
            active = worker.active
            owner = window._analysis_owner
            window.close()
            self.assertGreater(charge, 0)
            self.assertEqual(worker.reserved, charge)
            self.assertTrue(active.cancelled.is_set())
            self.assertIsNone(window._snapshot)
            self.assertFalse(window._profiles)
            self.assertFalse(window._profile_curves)
            window._analysis_ready(owner, active.token, None, "obsolete line result")
            self.assertNotEqual(window.analysis_status.text(), "obsolete line result")
            release.set()
            pump_until(lambda: worker.reserved == 0)

    def test_line_budget_denial_reports_failure_and_never_shows_stale_curves(self):
        worker = AnalysisWorker(admit=lambda: False)
        self.addCleanup(worker.shutdown)
        window = self.window(analysis_worker=worker)
        self.line(window)
        pump_until(lambda: "memory budget" in window.analysis_status.text())
        self.assertFalse(window._profiles)
        self.assertFalse(window._profile_curves)
        self.assertIn("memory budget", window.profile_status.text().lower())
        self.assertEqual(worker.reserved, 0)
        self.assertIsNone(worker.active)
        self.assertIsNone(worker.pending)


if __name__ == "__main__":
    unittest.main()
