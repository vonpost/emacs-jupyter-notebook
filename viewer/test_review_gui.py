"""Persistent local review controls, precise ROI gestures and retained budgets."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

import gc
import unittest

import numpy as np
from PySide6 import QtCore, QtTest

from ejn_viewer.analysis import DIFFERENCE
from ejn_viewer.analysis_worker import AnalysisJob, AnalysisWorker
from ejn_viewer.memory import AnalysisSource, merge_allocations, source_allocations
from ejn_viewer.workspace import PINNED, WorkspaceWindow
from test_analysis_gui import APP, pump_until, snapshot


class ReviewGuiTests(unittest.TestCase):
    def window(self, data=None, **kwargs):
        window = WorkspaceWindow(**kwargs)
        self.addCleanup(window.close)
        window.install_snapshot(data or snapshot())
        window.show()
        APP.processEvents()
        return window

    def use_menu(self, button, interact, *, keyboard=False):
        """Exercise an InstantPopup through its nested Qt event loop."""
        menu = button.menu()
        errors = []

        def while_open():
            try:
                self.assertTrue(menu.isVisible())
                interact(menu)
            except BaseException as error:
                errors.append(error)
            finally:
                menu.close()

        if keyboard:
            button.setFocus()
            self.assertIs(APP.focusWidget(), button)
        QtCore.QTimer.singleShot(0, while_open)
        if keyboard:
            QtTest.QTest.keyClick(APP.focusWidget(), QtCore.Qt.Key.Key_Space)
        else:
            QtTest.QTest.mouseClick(button, QtCore.Qt.MouseButton.LeftButton)
        APP.processEvents()
        if errors:
            raise errors[0]

    def test_pin_old_reference_accepts_new_candidate_preserving_camera_levels_roi(self):
        original = snapshot()
        window = self.window(original)
        window.pin_button.click()
        self.assertIs(window._pinned, original)
        self.assertEqual(window._reference_name(), PINNED)
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        window.rectangle_button.click()
        identifier = window.roi_selector.currentData()
        region = window._regions[identifier]
        self.assertEqual(region.plane, PINNED)
        window.level.setValue(6)
        window.width.setValue(3)
        window._views[PINNED].setRange(xRange=(1, 3), yRange=(.5, 2.5), padding=0)
        from ejn_viewer.navigation import camera
        old_camera = camera(window._views[PINNED])
        replacement = snapshot(delta=10)
        window.install_snapshot(replacement)
        pump_until(lambda: window._difference is not None and bool(window._statistics))
        self.assertIs(window._pinned, original)
        self.assertIs(window._snapshot, replacement)
        self.assertEqual(window._regions[identifier], region)
        np.testing.assert_array_equal(window._planes[PINNED], original.planes["reference"])
        np.testing.assert_array_equal(window._difference, np.full((3, 4), 12.))
        np.testing.assert_allclose(camera(window._views[PINNED]), old_camera)
        self.assertEqual(tuple(window._items[PINNED].getLevels()), (4.5, 7.5))
        self.assertEqual(window._statistics[identifier, DIFFERENCE].mean, 12)
        window.pin_button.click()
        self.assertIsNone(window._pinned)
        self.assertNotIn(PINNED, window._planes)

    def test_single_plane_can_compare_its_previous_evaluation(self):
        data = snapshot()
        data.planes.pop("candidate")
        data.nbytes = data.planes["reference"].nbytes
        window = self.window(data)
        window.pin_button.click()
        self.assertEqual(len(window._planes), 2)
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, 0)
        replacement = snapshot(delta=7)
        replacement.planes.pop("candidate")
        replacement.nbytes = replacement.planes["reference"].nbytes
        window.install_snapshot(replacement)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, 7)

    def test_freeze_skips_updates_and_unfreeze_accepts_future_snapshot(self):
        window = self.window()
        original = window._snapshot
        window.freeze_button.click()
        self.assertFalse(window.install_snapshot(snapshot(delta=100)))
        self.assertIs(window._snapshot, original)
        self.assertIn("Frozen", window.publication_status.text())
        window.freeze_button.click()
        self.assertIs(window._snapshot, original)
        latest = snapshot(delta=200)
        self.assertTrue(window.install_snapshot(latest))
        self.assertIs(window._snapshot, latest)

    def test_hold_to_blink_uses_reference_and_restores_original_candidate(self):
        window = self.window()
        window.pin_button.click()
        window.install_snapshot(snapshot(delta=10))
        candidate = window._planes["candidate"]
        token = window._analysis_token
        window._blink(True)
        self.assertTrue(np.shares_memory(window._items["candidate"].image, window._pinned.planes["reference"]))
        self.assertIs(window._planes["candidate"], candidate)
        window._blink(False)
        self.assertTrue(np.shares_memory(window._items["candidate"].image, candidate))
        self.assertEqual(window._analysis_token, token)
        QtTest.QTest.keyPress(window, QtCore.Qt.Key.Key_B)
        self.assertTrue(window._blinking)
        QtTest.QTest.keyRelease(window, QtCore.Qt.Key.Key_B)
        self.assertFalse(window._blinking)

    def test_incompatible_candidate_keeps_pin_but_blocks_difference_and_links(self):
        window = self.window()
        window.pin_button.click()
        pinned = window._pinned
        window.comparison.setCurrentIndex(1)
        window.install_snapshot(snapshot(sample="different", delta=5))
        self.assertIs(window._pinned, pinned)
        self.assertIn("same declared sample", window.analysis_status.text())
        self.assertIsNone(window._difference)
        self.assertFalse(window._linked)
        self.assertFalse(window.blink_button.isEnabled())

    def test_pin_budget_failure_keeps_current_view_and_unpins_nothing(self):
        window = self.window(admit=lambda: False)
        before = dict(window._planes)
        window.pin_button.click()
        self.assertIsNone(window._pinned)
        self.assertFalse(window.pin_button.isChecked())
        self.assertEqual(window._planes.keys(), before.keys())
        self.assertIn("memory budget", window.analysis_status.text())

    def test_pane_expansion_is_admitted_before_changing_controls_or_views(self):
        data = snapshot()
        data.planes.update({"third": data.planes["reference"], "fourth": data.planes["candidate"]})
        data.manifest["planes"] += [{"name": name, "grid_id": "grid", "units": "HU"}
                                    for name in ("third", "fourth")]
        window = self.window(data)
        window.pin_button.click()
        self.assertEqual(len(window._planes), 2)
        calls = []
        window._admit = lambda: calls.append(True) or False
        old_views = dict(window._views)
        window.reference.setCurrentText("reference")
        self.assertTrue(calls)
        self.assertEqual(window._reference_name(), PINNED)
        self.assertEqual(window._views, old_views)
        self.assertIn("memory budget", window.analysis_status.text())

    def test_compact_window_keeps_images_visible_and_optional_patches_collapse(self):
        window = self.window()
        for width, height, image_fraction in ((1100, 800, .75), (860, 440, .65)):
            with self.subTest(size=(width, height)):
                window.resize(width, height)
                APP.processEvents()
                self.assertEqual(window.size(), QtCore.QSize(width, height))
                self.assertGreater(window.graphics.height(), height * image_fraction)
                self.assertTrue(all(view.height() > 100 for view in window._views.values()))
                self.assertFalse(window.magnifier.isVisible())
                self.assertFalse(window.stats_table.isVisible())
                self.assertTrue(window.analysis_status.isVisible())
                self.assertTrue(window.publication_status.isVisible())
        window.install_snapshot(snapshot(delta=3))
        self.assertFalse(window.magnifier.isVisible())
        window.resize(1100, 800)
        APP.processEvents()
        self.assertFalse(window.magnifier.isVisible())
        window.magnifier_toggle.setChecked(True)
        self.assertTrue(window.magnifier.isVisible())
        window.resize(860, 440)
        APP.processEvents()
        self.assertFalse(window.magnifier.isVisible())
        window.resize(1100, 800)
        APP.processEvents()
        self.assertTrue(window.magnifier.isVisible())

    def test_compare_dropdown_controls_select_difference_pin_and_blink(self):
        data = snapshot()
        for metadata in data.manifest["planes"]:
            metadata.pop("grid_id")
            metadata.pop("units")
        window = self.window(data)
        self.assertFalse(window.reference.isVisible())

        def compare(_menu):
            for widget in (window.reference, window.candidate, window.comparison,
                           window.declare_grid, window.declare_units, window.pin_button,
                           window.blink_button):
                self.assertTrue(widget.isVisible())
            QtTest.QTest.keyClick(window.comparison, QtCore.Qt.Key.Key_Down)
            self.assertEqual(window.comparison.currentData(), "signed")
            QtTest.QTest.mouseClick(window.declare_grid, QtCore.Qt.MouseButton.LeftButton)
            QtTest.QTest.mouseClick(window.declare_units, QtCore.Qt.MouseButton.LeftButton)
            QtTest.QTest.keyClick(window.reference, QtCore.Qt.Key.Key_End)
            QtTest.QTest.keyClick(window.candidate, QtCore.Qt.Key.Key_Home)
            self.assertEqual(window._reference_name(), "candidate")
            self.assertEqual(window._candidate_name(), "reference")

        self.use_menu(window.compare_button, compare)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, np.full((3, 4), -2.))
        self.assertFalse(window.reference.isVisible())

        def pin_and_blink(_menu):
            QtTest.QTest.mouseClick(window.pin_button, QtCore.Qt.MouseButton.LeftButton)
            self.assertTrue(window.pin_button.isChecked())
            candidate = window._candidate_name()
            QtTest.QTest.mousePress(window.blink_button, QtCore.Qt.MouseButton.LeftButton)
            self.assertTrue(np.shares_memory(window._items[candidate].image, data.planes["candidate"]))
            QtTest.QTest.mouseRelease(window.blink_button, QtCore.Qt.MouseButton.LeftButton)
            self.assertTrue(np.shares_memory(window._items[candidate].image, data.planes["reference"]))

        self.use_menu(window.compare_button, pin_and_blink)

    def test_settings_menus_support_keyboard_focus_and_skip_disabled_controls(self):
        window = self.window()

        def compare(menu):
            self.assertIs(APP.focusWidget(), window.reference)
            order = (window.reference, window.candidate, window.comparison, window.pin_button,
                     window.blink_button, window.declare_grid, window.declare_units)
            for expected in (*order[1:], order[0]):
                QtTest.QTest.keyClick(APP.focusWidget(), QtCore.Qt.Key.Key_Tab)
                self.assertIs(APP.focusWidget(), expected)
            for expected in (*reversed(order[1:]), order[0]):
                QtTest.QTest.keyClick(APP.focusWidget(), QtCore.Qt.Key.Key_Backtab)
                self.assertIs(APP.focusWidget(), expected)
            QtTest.QTest.keyClick(APP.focusWidget(), QtCore.Qt.Key.Key_Escape)
            self.assertFalse(menu.isVisible())
            self.assertTrue(window.isVisible())

        self.use_menu(window.compare_button, compare, keyboard=True)
        # A fresh window avoids offscreen Qt's stale popup activation after
        # the nested key event returns; native Qt restores toolbar focus.
        window = self.window()
        window.resize(860, 440)
        APP.processEvents()

        def options(menu):
            self.assertFalse(window.magnifier_toggle.isEnabled())
            self.assertIs(APP.focusWidget(), window.freeze_button)
            for key in (QtCore.Qt.Key.Key_Tab, QtCore.Qt.Key.Key_Backtab):
                QtTest.QTest.keyClick(APP.focusWidget(), key)
                self.assertIs(APP.focusWidget(), window.freeze_button)
            QtTest.QTest.keyClick(APP.focusWidget(), QtCore.Qt.Key.Key_Space)
            self.assertTrue(window.frozen)
            QtTest.QTest.keyClick(APP.focusWidget(), QtCore.Qt.Key.Key_Escape)
            self.assertFalse(menu.isVisible())
            self.assertTrue(window.isVisible())

        self.use_menu(window.options_button, options, keyboard=True)

    def test_options_dropdown_freezes_updates_and_enables_magnifier(self):
        window = self.window()
        original = window._snapshot

        def enable(_menu):
            self.assertTrue(window.freeze_button.isVisible())
            self.assertTrue(window.magnifier_toggle.isVisible())
            QtTest.QTest.mouseClick(window.freeze_button, QtCore.Qt.MouseButton.LeftButton)
            QtTest.QTest.mouseClick(window.magnifier_toggle, QtCore.Qt.MouseButton.LeftButton,
                                   pos=QtCore.QPoint(8, window.magnifier_toggle.height() // 2))

        self.use_menu(window.options_button, enable)
        self.assertFalse(window.install_snapshot(snapshot(delta=50)))
        self.assertIs(window._snapshot, original)
        self.assertIn("Frozen", window.publication_status.text())
        self.assertTrue(window.magnifier.isVisible())
        self.use_menu(window.options_button, lambda _menu: QtTest.QTest.mouseClick(
            window.freeze_button, QtCore.Qt.MouseButton.LeftButton))
        self.assertTrue(window.install_snapshot(snapshot(delta=100)))

    def test_measurements_toggle_restores_image_space_and_retains_measurements(self):
        window = self.window()
        full_height = window.graphics.height()
        QtTest.QTest.mouseClick(window.measurements_button, QtCore.Qt.MouseButton.LeftButton)
        APP.processEvents()
        self.assertTrue(window.stats_table.isVisible())
        self.assertTrue(window.roi_name.isVisible())
        self.assertLess(window.graphics.height(), full_height)
        QtTest.QTest.mouseClick(window.rectangle_button, QtCore.Qt.MouseButton.LeftButton)
        pump_until(lambda: bool(window._statistics))
        window.roi_name.selectAll()
        QtTest.QTest.keyClicks(window.roi_name, "Review region")
        QtTest.QTest.keyClick(window.roi_name, QtCore.Qt.Key.Key_Return)
        identifier = window.roi_selector.currentData()
        region = window._regions[identifier]
        statistics = dict(window._statistics)
        displayed_rows = [[window.stats_table.item(row, col).text()
                           for col in range(window.stats_table.columnCount())]
                          for row in range(window.stats_table.rowCount())]
        self.assertIn("Review region", displayed_rows[0][0])
        QtTest.QTest.mouseClick(window.measurements_button, QtCore.Qt.MouseButton.LeftButton)
        APP.processEvents()
        self.assertFalse(window.stats_table.isVisible())
        self.assertEqual(window.graphics.height(), full_height)
        QtTest.QTest.mouseClick(window.measurements_button, QtCore.Qt.MouseButton.LeftButton)
        APP.processEvents()
        self.assertTrue(window.stats_table.isVisible())
        self.assertEqual(window.roi_selector.currentData(), identifier)
        self.assertEqual(window._regions[identifier], region)
        self.assertEqual(window._statistics, statistics)
        self.assertEqual([[window.stats_table.item(row, col).text()
                           for col in range(window.stats_table.columnCount())]
                          for row in range(window.stats_table.rowCount())], displayed_rows)
        QtTest.QTest.mouseClick(window.copy_button, QtCore.Qt.MouseButton.LeftButton)
        self.assertIn("Review region\treference\tHU", APP.clipboard().text())

    def test_long_values_and_drawing_leave_compact_window_width_stable(self):
        data = snapshot()
        data.execution = "evaluation-" + "1234567890" * 20
        window = self.window(data)
        window.resize(860, 440)
        window.level.setValue(1.0e30)
        window.width.setValue(1.0e30)
        window._show_cursor("reference", 1, 2)
        APP.processEvents()
        self.assertEqual(window.size(), QtCore.QSize(860, 440))

        def draw(menu):
            action = next(action for action in menu.actions() if action.text() == "Draw rectangle")
            QtTest.QTest.mouseClick(menu, QtCore.Qt.MouseButton.LeftButton,
                                   pos=menu.actionGeometry(action).center())

        self.use_menu(window.draw_button, draw)
        self.assertEqual(window._draw_kind, "rectangle")
        self.assertEqual(window.size(), QtCore.QSize(860, 440))
        self.assertGreater(window.graphics.height(), 440 * .65)
        for widget in (window.fit_button, window.level, window.width, window.compare_button,
                       window.draw_button, window.measurements_button, window.options_button):
            self.assertTrue(widget.isVisible())
            point = widget.mapTo(window.centralWidget(), QtCore.QPoint(0, 0))
            self.assertTrue(window.centralWidget().rect().contains(QtCore.QRect(point, widget.size())))
        QtTest.QTest.keyClick(window.graphics, QtCore.Qt.Key.Key_Escape)
        self.assertIsNone(window._draw_kind)

    def test_changed_sample_clears_all_cursor_values_and_tooltips(self):
        window = self.window()
        window._show_cursor("reference", 1, 2)
        window.install_snapshot(snapshot(sample="other", delta=100))
        self.assertIsNone(window._cursor)
        self.assertEqual(window.readout.text(), "Pixel: —")
        self.assertEqual(window.readout.toolTip(), "")

    def test_difference_result_cannot_replace_a_live_drawing_target(self):
        window = self.window()
        window.comparison.setCurrentIndex(1)
        window._analysis_timer.stop()
        view = window._views["reference"]
        window.arm_roi("rectangle")
        window._draw_region(view, QtCore.QPointF(0, 0), QtCore.QPointF(2, 2), False)
        window._analysis_ready(window._analysis_owner, window._analysis_token,
                               (np.full((3, 4), 2.), {}), "")
        self.assertIs(window._views["reference"], view)
        self.assertIsNone(window._difference)
        window._draw_region(view, QtCore.QPointF(0, 0), QtCore.QPointF(2, 2), True)
        pump_until(lambda: window._difference is not None)

    def test_latest_publication_waits_for_roi_release_with_bounded_reservation(self):
        window = self.window()
        original = window._snapshot
        view = window._views["reference"]
        window.arm_roi("ellipse")
        window._draw_region(view, QtCore.QPointF(0, 0), QtCore.QPointF(2, 2), False)
        first = snapshot(delta=50)
        latest = snapshot(delta=100)
        self.assertFalse(window.install_snapshot(first))
        self.assertFalse(window.install_snapshot(latest))
        self.assertIs(window._snapshot, original)
        self.assertIs(window._pending_snapshot, latest)
        self.assertIs(window._views["reference"], view)
        self.assertNotIn(("source", id(first)), window.allocations)
        self.assertIn(("source", id(latest)), window.allocations)
        self.assertIn(("pending-render", id(window)), window.allocations)
        window._draw_region(view, QtCore.QPointF(0, 0), QtCore.QPointF(2, 2), True)
        pump_until(lambda: window._snapshot is latest)
        self.assertEqual(len(window._regions), 1)
        self.assertNotIn(("pending-render", id(window)), window.allocations)

    def test_shared_pin_sources_are_counted_once_with_active_worker(self):
        first, second = snapshot(), snapshot(delta=2)
        source = AnalysisSource({**second.planes, PINNED: first.planes["reference"]}, (first, second))
        worker = AnalysisWorker()
        self.addCleanup(worker.shutdown)
        worker.active = AnalysisJob(object(), 1, source, (), {})
        shared = merge_allocations(source_allocations(first), source_allocations(second), worker.allocations)
        retained = {key: value for key, value in shared.items() if key[0] == "source"}
        self.assertEqual(sum(retained.values()), first.nbytes + second.nbytes)
        worker.pending = AnalysisJob(object(), 2, source, (), {})
        self.assertEqual(worker.reserved, sum(shared.values()))
        worker.active = worker.pending = None

    def test_drag_create_rename_nudge_copy_and_cancel(self):
        window = self.window()
        view = window._views["reference"]
        viewport = window.graphics.viewport()
        def position(x, y):
            return window.graphics.mapFromScene(view.mapViewToScene(QtCore.QPointF(x, y)))
        window.arm_roi("rectangle")
        QtTest.QTest.mousePress(viewport, QtCore.Qt.MouseButton.LeftButton, pos=position(2.9, 2.9))
        QtTest.QTest.mouseMove(viewport, position(.1, .1))
        QtTest.QTest.mouseRelease(viewport, QtCore.Qt.MouseButton.LeftButton, pos=position(.1, .1))
        self.assertIsNone(window._draw_kind)
        self.assertEqual(len(window._regions), 1)
        pump_until(lambda: bool(window._statistics))
        identifier = window.roi_selector.currentData()
        self.assertEqual(window._statistics[identifier, "reference"].finite, 9)
        self.assertEqual(window._statistics[identifier, "reference"].mean, 5)
        window.roi_name.setText("Lesion center")
        QtTest.QTest.keyClick(window.roi_name, QtCore.Qt.Key.Key_Return)
        self.assertEqual(window._regions[identifier].name, "Lesion center")
        original = window._regions[identifier]
        window.nudge_roi(1, -1)
        self.assertEqual(window._regions[identifier].x, original.x + 1)
        self.assertEqual(window._regions[identifier].y, original.y - 1)
        pump_until(lambda: bool(window._statistics))
        copied = window.copy_statistics()
        self.assertEqual(APP.clipboard().text(), copied)
        self.assertIn("Lesion center\treference\tHU", copied)
        self.assertIn("SD (population)", copied)
        window.arm_roi("ellipse")
        window._draw_region(view, QtCore.QPointF(0, 0), QtCore.QPointF(2, 2), False)
        self.assertEqual(len(window._regions), 2)
        QtTest.QTest.keyClick(window, QtCore.Qt.Key.Key_Escape)
        self.assertEqual(len(window._regions), 1)
        self.assertTrue(window.isVisible())

    def test_linked_readout_and_magnifier_use_exact_samples_and_bound_copies(self):
        window = self.window()
        window.magnifier_toggle.setChecked(True)
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        window._show_cursor("reference", 1, 2)
        window._update_magnifier()
        self.assertIn("reference=6", window.readout.text())
        self.assertIn("candidate=8", window.readout.text())
        self.assertIn("candidate − reference=2", window.readout.text())
        self.assertEqual(len(window.magnifier.items), 3)
        for name, cross in window._crosshairs.items():
            self.assertTrue(all(line.isVisible() for line in cross))
            self.assertEqual(cross[0].value(), 2.5)
            self.assertEqual(cross[1].value(), 1.5)
            patch = window.magnifier.items[name].image
            np.testing.assert_array_equal(patch, window._planes[name])
            self.assertFalse(np.shares_memory(patch, window._planes[name]))
            self.assertLessEqual(patch.size, 31 * 31)
        token = window._analysis_token
        window.level.setValue(20)
        self.assertEqual(window._analysis_token, token)
        self.assertEqual(window._planes["reference"][1, 2], 6)
        window._metadata["candidate"]["grid_id"] = "different"
        window._comparison_changed()
        window._show_cursor("reference", 1, 2)
        window._update_magnifier()
        self.assertEqual(tuple(window.magnifier.items), ("reference",))
        self.assertFalse(window._crosshairs["candidate"][0].isVisible())

    def test_close_clears_pin_patches_and_source_references_under_gc(self):
        window = self.window()
        window.magnifier_toggle.setChecked(True)
        window.pin_button.click()
        window._show_cursor(PINNED, 1, 1)
        window._update_magnifier()
        window.close()
        gc.collect()
        self.assertIsNone(window._pinned)
        self.assertIsNone(window._snapshot)
        self.assertIsNone(window._analysis_source)
        self.assertFalse(window.magnifier.items)
        self.assertFalse(window._crosshairs)


if __name__ == "__main__":
    unittest.main()
