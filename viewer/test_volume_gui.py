"""Explicit local crop browsing, axis identity and stale analysis protection."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from types import SimpleNamespace
import unittest
from unittest import mock

import numpy as np
from PySide6 import QtCore, QtGui, QtTest, QtWidgets

from ejn_viewer.analysis import DIFFERENCE, VolumeSelection
from ejn_viewer.analysis_worker import compute
from ejn_viewer.ipc import snapshot_charge
from ejn_viewer.memory import render_bytes, source_allocations
from ejn_viewer.navigation import camera
from ejn_viewer.workspace import PINNED, WorkspaceWindow, _sample_extrema
from test_analysis_gui import APP, pump_until


def volume_snapshot(*, delta=0, shape=(3, 5, 7), sample="sample", grid="grid", dtype="<f4"):
    z, y, x = np.indices(shape)
    original = (100 * z + 10 * y + x + delta).astype(dtype)
    arrays = {"reference": original, "candidate": original + 2}
    for array in arrays.values():
        array.setflags(write=False)
    return SimpleNamespace(planes=arrays, numerical=True, generation=1, execution=str(delta),
                           workspace="test", nbytes=sum(array.nbytes for array in arrays.values()),
                           manifest={"sample_id": sample, "planes": [
                               {"name": name, "grid_id": grid, "units": "value", "shape": list(shape)}
                               for name in arrays]})


class VolumeGuiTests(unittest.TestCase):
    def window(self, snapshot=None, **kwargs):
        window = WorkspaceWindow(**kwargs)
        self.addCleanup(window.close)
        window.install_snapshot(snapshot or volume_snapshot())
        window.show()
        APP.processEvents()
        return window

    def test_asymmetric_axes_are_zero_copy_and_remember_independent_indices(self):
        snapshot = volume_snapshot()
        window = self.window(snapshot)
        array = snapshot.planes["reference"]
        np.testing.assert_array_equal(window._planes["reference"], array[1, :, :])
        for axis, index, expected in ((0, 2, array[2]), (1, 4, array[:, 4]), (2, 6, array[:, :, 6])):
            window.select_volume_slice(axis=axis, index=index)
            np.testing.assert_array_equal(window._planes["reference"], expected)
            self.assertTrue(np.shares_memory(array, window._planes["reference"]))
            self.assertFalse(window._planes["reference"].flags.writeable)
            self.assertEqual(window.slice_slider.maximum(), array.shape[axis] - 1)
        for axis, index in ((0, 2), (1, 4), (2, 6)):
            window.volume_axis.setCurrentIndex(axis)
            self.assertEqual(window.slice_index.value(), index)
        window._show_cursor("reference", 1, 2)
        self.assertIn("crop [1,2,6]", window.readout.text())
        np.testing.assert_array_equal(snapshot.planes["reference"], array)

    def test_index_bounds_and_slider_keyboard_and_shift_wheel(self):
        window = self.window()
        window.select_volume_slice(index=999)
        self.assertEqual(window.slice_index.value(), 2)
        window.select_volume_slice(index=-999)
        self.assertEqual(window.slice_index.value(), 0)
        window.slice_slider.setValue(1)
        self.assertEqual(window.slice_index.value(), 1)
        QtTest.QTest.keyClick(window, QtCore.Qt.Key.Key_PageDown)
        self.assertEqual(window.slice_index.value(), 2)
        QtTest.QTest.keyClick(window, QtCore.Qt.Key.Key_PageUp)
        self.assertEqual(window.slice_index.value(), 1)
        view = window._views["reference"]
        before = camera(view)
        pos = QtCore.QPointF(window.graphics.mapFromScene(view.sceneBoundingRect().center()))
        event = QtGui.QWheelEvent(pos, window.graphics.viewport().mapToGlobal(pos),
                                 QtCore.QPoint(), QtCore.QPoint(0, 120),
                                 QtCore.Qt.MouseButton.NoButton, QtCore.Qt.KeyboardModifier.ShiftModifier,
                                 QtCore.Qt.ScrollPhase.NoScrollPhase, False)
        QtWidgets.QApplication.sendEvent(window.graphics.viewport(), event)
        self.assertEqual(window.slice_index.value(), 0)
        self.assertIs(window._views["reference"], view)
        np.testing.assert_array_equal(camera(view), before)

    def test_one_voxel_axis_and_float16_render_and_measure(self):
        window = self.window(volume_snapshot(shape=(1, 3, 4), dtype="<f2"))
        self.assertEqual(window.slice_index.maximum(), 0)
        window.select_volume_slice(index=1)
        self.assertEqual(window.slice_index.value(), 0)
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, 2)
        self.assertFalse(window.grab().isNull())

    def test_volume_comparison_statistics_profile_use_selected_face(self):
        window = self.window()
        window.select_volume_slice(axis=1, index=3)
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, np.full((3, 7), 2))
        window.add_roi("rectangle")
        identifier = window.roi_selector.currentData()
        item = window._roi_items[identifier, "reference"]
        item.setPos((0, 0))
        item.setSize((2, 2))
        pump_until(lambda: len(window._statistics) == 3)
        self.assertEqual(window._statistics[identifier, "reference"].mean, 80.5)
        old_token = window._analysis_token
        window.select_volume_slice(index=4)
        self.assertGreater(window._analysis_token, old_token)
        self.assertFalse(window._statistics)
        pump_until(lambda: bool(window._statistics))
        self.assertEqual(window._statistics[identifier, "reference"].mean, 90.5)
        window.add_roi("line")
        line = window.roi_selector.currentData()
        item = window._roi_items[line, "reference"]
        window._syncing_rois = True
        window._set_line(item, QtCore.QPointF(.5, .5), QtCore.QPointF(3.5, .5))
        window._syncing_rois = False
        window._roi_changed(line, item)
        pump_until(lambda: bool(window._profiles))
        np.testing.assert_array_equal(window._profiles[line, "reference"].values, [40, 41, 42, 43])
        window.select_volume_slice(axis=2)
        self.assertFalse(window._regions)
        self.assertFalse(window._statistics)
        self.assertFalse(window._profiles)

    def test_late_slice_job_cannot_paint_new_slice_or_new_snapshot(self):
        window = self.window()
        window.add_roi("rectangle")
        jobs = []
        with mock.patch.object(window._worker, "submit", side_effect=jobs.append):
            window._submit_analysis()
            old_job = jobs[-1]
            old_result = compute(old_job)
            window.select_volume_slice(index=2)
            window._analysis_ready(old_job.owner, old_job.token, old_result, "")
            self.assertFalse(window._statistics)
            window._submit_analysis()
            next_job = jobs[-1]
            window.install_snapshot(volume_snapshot(delta=500))
            window._analysis_ready(next_job.owner, next_job.token, compute(next_job), "")
            self.assertFalse(window._statistics)
            self.assertEqual(window.slice_index.value(), 2)
            self.assertEqual(window._planes["reference"][0, 0], 700)

    def test_pin_retains_entire_crop_and_browses_with_new_matching_evaluation(self):
        original = volume_snapshot()
        window = self.window(original)
        window.select_volume_slice(axis=2, index=5)
        window.pin_button.click()
        self.assertIs(window._pinned, original)
        window.install_snapshot(volume_snapshot(delta=20))
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._difference, 22)
        window.select_volume_slice(axis=1, index=4)
        pump_until(lambda: window._difference is not None)
        np.testing.assert_array_equal(window._planes[PINNED], original.planes["reference"][:, 4])
        np.testing.assert_array_equal(window._difference, 22)
        window._blink(True)
        np.testing.assert_array_equal(window._items["candidate"].image, original.planes["reference"][:, 4])
        window._blink(False)
        window.pin_button.click()
        self.assertNotIn(PINNED, window._volume_selections)

    def test_freeze_keeps_data_but_permits_local_browsing(self):
        window = self.window()
        original = window._snapshot
        window.freeze_button.click()
        self.assertFalse(window.install_snapshot(volume_snapshot(delta=1000)))
        window.select_volume_slice(axis=2, index=0)
        self.assertIs(window._snapshot, original)
        np.testing.assert_array_equal(window._planes["reference"], original.planes["reference"][:, :, 0])

    def test_full_volume_shape_and_slice_identity_are_required_for_links(self):
        data = volume_snapshot(shape=(4, 4, 4))
        window = self.window(data)
        window._volume_selections["candidate"] = VolumeSelection.centered((4, 4, 4)).select((4, 4, 4), index=0)
        self.assertFalse(window._corresponds("reference", "candidate"))
        self.assertIsNotNone(window._comparison_error())
        window._volume_selections["candidate"] = VolumeSelection.centered((4, 4, 4)).select((4, 4, 4), axis=1)
        self.assertFalse(window._corresponds("reference", "candidate"))
        data = volume_snapshot(shape=(4, 5, 7))
        data.planes["candidate"] = data.planes["candidate"][:3]
        window.install_snapshot(data)
        self.assertEqual(window._planes["reference"].shape, window._planes["candidate"].shape)
        self.assertFalse(window._corresponds("reference", "candidate"))
        window.select_volume_slice(index=3)
        self.assertEqual(window._volume_selections["candidate"].indices[0], 1)

    def test_volume_and_same_shape_plane_never_link_implicitly(self):
        data = volume_snapshot()
        data.planes["candidate"] = data.planes["candidate"][1]
        window = self.window(data)
        self.assertFalse(window._corresponds("reference", "candidate"))
        self.assertIsNotNone(window._comparison_error())

    def test_new_unrelated_sample_clears_regions_but_retains_indices(self):
        window = self.window()
        window.select_volume_slice(axis=2, index=5)
        window.add_roi("rectangle")
        window.install_snapshot(volume_snapshot(sample="other"))
        self.assertFalse(window._regions)
        self.assertEqual(window.volume_axis.currentIndex(), 2)
        self.assertEqual(window.slice_index.value(), 5)

    def test_incompatible_volume_control_is_independent(self):
        data = volume_snapshot()
        data.manifest["planes"][1]["grid_id"] = "other"
        window = self.window(data)
        initial = window._volume_selections["candidate"]
        window.select_volume_slice(axis=2, index=6)
        self.assertEqual(window._volume_selections["candidate"], initial)
        window.volume_selector.setCurrentText("candidate")
        self.assertEqual(window.volume_axis.currentIndex(), 0)
        self.assertEqual(window.slice_index.value(), 1)

    def test_scrubbing_into_correspondence_rebuilds_links_roi_and_blink(self):
        window = self.window(volume_snapshot(grid=None))
        window.select_volume_slice(name="reference", index=0)
        window.declare_grid.setChecked(True)
        window.add_roi("rectangle")
        identifier = window.roi_selector.currentData()
        self.assertFalse(window._linked)
        self.assertNotIn((identifier, "candidate"), window._roi_items)
        window.select_volume_slice(name="reference", index=2)
        self.assertTrue(window._linked)
        self.assertEqual(len(window._navigation_groups), 1)
        self.assertIn((identifier, "candidate"), window._roi_items)
        self.assertTrue(window.blink_button.isEnabled())
        self.assertIn("axis 0=2", window.roi_plane.itemText(0))
        window.select_volume_slice(name="reference", index=1)
        self.assertIn("axis 0=1", window.roi_plane.itemText(0))

    def test_budget_rejection_does_not_change_image_controls_or_workers(self):
        window = self.window()
        initial = dict(window._volume_selections)
        planes = dict(window._planes)
        token = window._analysis_token
        window._admit = lambda: False
        window.volume_axis.setCurrentIndex(2)
        self.assertEqual(window._volume_selections, initial)
        self.assertEqual(window.volume_axis.currentIndex(), 0)
        self.assertEqual(window._analysis_token, token)
        for name in planes:
            self.assertIs(window._planes[name], planes[name])

    def test_slice_input_during_scene_drag_keeps_qt_targets_alive(self):
        window = self.window()
        view = window._views["reference"]
        with mock.patch.object(window.graphics.scene(), "mouseGrabberItem", return_value=object()):
            window.volume_axis.setCurrentIndex(2)
            QtTest.QTest.keyClick(window, QtCore.Qt.Key.Key_PageDown)
        self.assertIs(window._views["reference"], view)
        self.assertEqual(window.volume_axis.currentIndex(), 0)
        self.assertEqual(window.slice_index.value(), 1)

    def test_memory_charge_counts_largest_face_and_full_retained_source(self):
        data = volume_snapshot(shape=(2, 5, 11))
        self.assertEqual(render_bytes(data.planes["reference"]), 5 * 11 * 8)
        self.assertEqual(snapshot_charge(data), data.nbytes + 2 * 5 * 11 * 8)
        window = self.window(data)
        self.assertEqual(sum(source_allocations(window._analysis_source).values()), data.nbytes)
        window.pin_button.click()
        window.install_snapshot(volume_snapshot(delta=100, shape=(2, 5, 11)))
        self.assertEqual(sum(source_allocations(window._analysis_source).values()), 2 * data.nbytes)

    def test_levels_only_sample_selected_face(self):
        data = volume_snapshot()
        with mock.patch("ejn_viewer.workspace._sample_extrema", wraps=_sample_extrema) as sample:
            self.window(data)
        self.assertTrue(sample.call_args_list)
        self.assertTrue(all(call.args[0].ndim == 2 for call in sample.call_args_list))


if __name__ == "__main__":
    unittest.main()
