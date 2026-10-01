"""Physical frame navigation and measurements across unequal source grids."""

import os
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from types import SimpleNamespace
import unittest

import numpy as np
from PySide6 import QtCore, QtTest

from ejn_viewer.navigation import camera
from ejn_viewer.spatial import plane_geometry
from ejn_viewer.workspace import WorkspaceWindow, PINNED, DIFFERENCE
from test_analysis_gui import APP, pump_until


def spatial_snapshot(*, specifications=None, delta=0):
    specifications = specifications or {
        "coarse": ((4, 5), (.2, .3), (1, 2)),
        "fine": ((7, 13), (.1, .1), (1, 2)),
    }
    arrays, members = {}, []
    for name, (shape, spacing, origin) in specifications.items():
        coordinates = np.indices(shape)
        array = np.zeros(shape, dtype=np.float32) + delta
        for axis, (step, offset) in enumerate(zip(spacing, origin)):
            array += (offset + coordinates[axis] * step) * 10 ** (len(shape) - axis - 1)
        array.setflags(write=False)
        arrays[name] = array
        members.append(dict(name=name, shape=list(shape), grid_id="frame", units="signal",
                            spacing=list(spacing), origin=list(origin), spatial_units="mm",
                            direction=np.eye(len(shape)).reshape(-1).tolist()))
    return SimpleNamespace(planes=arrays, numerical=True, generation=1, execution=str(delta),
                           workspace="spatial", nbytes=sum(value.nbytes for value in arrays.values()),
                           manifest={"sample_id": "s", "planes": members})


class SpatialGuiTests(unittest.TestCase):
    def window(self, data=None):
        window = WorkspaceWindow()
        self.addCleanup(window.close)
        window.install_snapshot(data or spatial_snapshot())
        window.resize(1100, 800)
        window.show()
        APP.processEvents()
        return window

    def test_physical_image_centers_axes_and_linked_camera(self):
        window = self.window()
        self.assertTrue(window._linked)
        self.assertFalse(window.blink_button.isEnabled())
        window.comparison.setCurrentIndex(1)
        self.assertIsNone(window._difference)
        self.assertIn("same sample lattice", window.analysis_status.text())
        for name in ("coarse", "fine"):
            item = window._items[name]
            center = item.mapToParent(QtCore.QPointF(.5, .5))
            np.testing.assert_allclose((center.x(), center.y()), (2, 1))
            self.assertEqual(window._plots[name].getAxis("bottom").labelUnits, "mm")
        window._views["fine"].setRange(xRange=(2.3, 2.7), yRange=(1.1, 1.5), padding=0)
        np.testing.assert_allclose(camera(window._views["fine"]), camera(window._views["coarse"]))

    def test_fit_shows_union_including_offset_crop(self):
        data = spatial_snapshot(specifications={
            "left": ((3, 4), (.2, .2), (0, 0)),
            "right": ((5, 7), (.1, .1), (2, 3)),
        })
        window = self.window(data)
        window.fit()
        APP.processEvents()
        for name, view in window._views.items():
            for other in window._planes:
                rect = QtCore.QRectF(*plane_geometry(window._meta(other)).image_rect(window._planes[other].shape))
                self.assertTrue(view.viewRect().contains(rect), (name, other, view.viewRect(), rect))

    def test_linked_cursor_uses_world_point_and_each_grid_original_sample(self):
        window = self.window()
        window._show_cursor("coarse", 2, 2)
        self.assertIn("(1.4, 2.6) mm", window.readout.text())
        self.assertIn("fine [4,6]", window.readout.text())
        for cross in window._crosshairs.values():
            self.assertAlmostEqual(cross[0].value(), 2.6)
            self.assertAlmostEqual(cross[1].value(), 1.4)
        # Mouse picking uses the inverse image transform, not physical values as indices.
        world = window._views["fine"].mapViewToScene(QtCore.QPointF(2.6, 1.4))
        window._mouse_moved(world)
        self.assertEqual(window._cursor, ("fine", 4, 6))

    def test_world_rectangle_samples_each_grid_without_resampling(self):
        window = self.window()
        window.add_roi("rectangle")
        identifier = window.roi_selector.currentData()
        item = window._roi_items[identifier, "coarse"]
        item.setPos((1.95, .95))
        item.setSize((.4, .3))
        pump_until(lambda: len(window._statistics) == 2)
        self.assertEqual(window._statistics[identifier, "coarse"].finite, 4)
        self.assertEqual(window._statistics[identifier, "fine"].finite, 12)
        self.assertAlmostEqual(window._statistics[identifier, "coarse"].mean, 13.15, places=5)
        self.assertAlmostEqual(window._statistics[identifier, "fine"].mean, 13.15, places=5)
        fine = window._roi_items[identifier, "fine"]
        np.testing.assert_allclose(tuple(fine.pos()), tuple(item.pos()))
        np.testing.assert_allclose(tuple(fine.size()), tuple(item.size()))
        before = item.pos()
        window.nudge_roi(10, -1)
        np.testing.assert_allclose(tuple(item.pos() - before), (3, -.2))

    def test_line_profiles_share_mm_distance_and_physical_endpoints(self):
        window = self.window()
        window.add_roi("line")
        identifier = window.roi_selector.currentData()
        item = window._roi_items[identifier, "coarse"]
        window._syncing_rois = True
        window._set_line(item, QtCore.QPointF(2, 1), QtCore.QPointF(3.2, 1))
        window._syncing_rois = False
        window._roi_changed(identifier, item)
        pump_until(lambda: len(window._profiles) == 2)
        for name in ("coarse", "fine"):
            profile = window._profiles[identifier, name]
            self.assertEqual(profile.distance_units, "mm")
            self.assertAlmostEqual(profile.distance[0], 0)
            self.assertAlmostEqual(profile.distance[-1], 1.2)
            np.testing.assert_allclose(profile.values, 12 + profile.distance, rtol=1e-6)
        self.assertEqual(window.profile_plot.getAxis("bottom").labelUnits, "mm")
        self.assertIn("distance in mm", window.profile_status.text())

    def test_magnifier_has_shared_world_field_of_view_and_bounded_samples(self):
        data = spatial_snapshot(specifications={
            "coarse": ((50, 60), (.2, .3), (0, 0)),
            "fine": ((100, 180), (.1, .1), (0, 0)),
        })
        window = self.window(data)
        window.magnifier_toggle.setChecked(True)
        APP.processEvents()
        window._show_cursor("coarse", 20, 20)
        window._update_magnifier()
        source, target = window.magnifier.items["coarse"], window.magnifier.items["fine"]
        self.assertLess(source.image.shape[0], target.image.shape[0])
        self.assertLess(source.image.shape[1], target.image.shape[1])
        self.assertTrue(all(size <= 31 for item in (source, target) for size in item.image.shape))
        first, second = (window.magnifier.views[name][0].viewRect() for name in ("coarse", "fine"))
        np.testing.assert_allclose((first.center().x(), first.center().y()), (6, 4))
        np.testing.assert_allclose((second.width(), second.height()), (first.width(), first.height()))

    def test_resampling_update_preserves_world_roi_camera_and_pin(self):
        window = self.window()
        window.add_roi("rectangle")
        identifier = window.roi_selector.currentData()
        region = window._regions[identifier]
        window._views["coarse"].setRange(xRange=(2.1, 2.7), yRange=(1.1, 1.5), padding=0)
        before = camera(window._views["coarse"])
        replacement = spatial_snapshot(specifications={
            "coarse": ((7, 9), (.1, .15), (1, 2)),
            "fine": ((13, 25), (.05, .05), (1, 2)),
        })
        window.install_snapshot(replacement)
        self.assertEqual(window._regions[identifier], region)
        np.testing.assert_allclose(camera(window._views["coarse"]), before)
        window.pin_button.click()
        pinned = window._pinned
        window.install_snapshot(spatial_snapshot())
        self.assertIs(window._pinned, pinned)
        self.assertTrue(window._corresponds(PINNED, "fine"))
        self.assertIsNotNone(window._comparison_error())

    def test_physical_volumes_project_all_axes_and_select_nearest_world_slice(self):
        data = spatial_snapshot(specifications={
            "coarse": ((4, 5, 6), (.2, .3, .4), (1, 2, 3)),
            "fine": ((7, 13, 21), (.1, .1, .1), (1, 2, 3)),
        })
        window = self.window(data)
        for axis, index, target in ((0, 1, 2), (1, 2, 6), (2, 3, 12)):
            window.select_volume_slice(name="coarse", axis=axis, index=index)
            self.assertEqual(window._volume_selections["fine"].indices[axis], target)
            self.assertTrue(window._corresponds("coarse", "fine"))
            remaining = [value for value in range(3) if value != axis]
            self.assertEqual(window._meta("coarse")["spacing"], [(.2, .3, .4)[i] for i in remaining])
            self.assertEqual(window._plots["coarse"].getAxis("bottom").labelText, f"Axis {remaining[1]}")
        window.select_volume_slice(name="fine", axis=0, index=1)
        self.assertEqual(window._volume_selections["coarse"].indices[0], 1)
        self.assertTrue(window._corresponds("coarse", "fine"))
        self.assertFalse(window.blink_button.isEnabled())
        self.assertIn("(1.2 mm)", window._display_name("coarse"))
        self.assertIn("(1.1 mm)", window._display_name("fine"))

    def test_one_named_variable_pins_a_then_shows_resampled_b_side_by_side(self):
        data = spatial_snapshot(specifications={"image": ((4, 5), (.2, .3), (1, 2))})
        original = data.planes["image"].copy()
        window = self.window(data)
        window.add_roi("rectangle")
        identifier = window.roi_selector.currentData()
        region = window._regions[identifier]
        window._views["image"].setRange(xRange=(2.1, 2.8), yRange=(1.1, 1.5), padding=0)
        window.pin_button.click()
        before = camera(window._views[PINNED])
        # A second publication can reuse exactly the same variable/member name.
        data = spatial_snapshot(specifications={"image": ((7, 13), (.1, .1), (1, 2))}, delta=100)
        window.install_snapshot(data)
        self.assertEqual(set(window._planes), {PINNED, "image"})
        np.testing.assert_array_equal(window._planes[PINNED], original)
        self.assertFalse(window._planes[PINNED].flags.writeable)
        self.assertIs(window._planes["image"], data.planes["image"])
        self.assertTrue(window._linked)
        self.assertIsNotNone(window._comparison_error())
        self.assertEqual(window._regions[identifier], region)
        np.testing.assert_allclose(camera(window._views[PINNED]), before)

    def test_input_a_pinned_prediction_b_and_new_prediction_c_remain_visible(self):
        specs = {name: ((4, 5), (.2, .3), (1, 2)) for name in ("input", "prediction")}
        original = spatial_snapshot(specifications=specs)
        window = self.window(original)
        window.reference.setCurrentText("prediction")
        window.pin_button.click()
        self.assertEqual(window._candidate_name(), "prediction")
        latest = spatial_snapshot(specifications=specs)
        latest.planes["prediction"] = latest.planes["prediction"] + 5
        latest.planes["prediction"].setflags(write=False)
        window.install_snapshot(latest)
        self.assertEqual(set(window._planes), {"input", "prediction", PINNED})
        self.assertEqual(window._candidate_name(), "prediction")
        self.assertIs(window._pinned, original)
        np.testing.assert_array_equal(window._planes["input"], original.planes["input"])
        np.testing.assert_array_equal(window._planes[PINNED], original.planes["prediction"])
        np.testing.assert_array_equal(window._planes["prediction"], original.planes["prediction"] + 5)
        window.add_roi("rectangle")
        identifier = window.roi_selector.currentData()
        pump_until(lambda: len(window._statistics) == 3)
        self.assertEqual({name for key, name in window._roi_items if key == identifier}, set(window._planes))
        window.comparison.setCurrentIndex(1)
        pump_until(lambda: window._difference is not None and len(window._statistics) == 4)
        self.assertEqual(set(window._planes), {"input", "prediction", PINNED, DIFFERENCE})
        np.testing.assert_allclose(window._difference, 5, rtol=1e-5)
        self.assertAlmostEqual(window._statistics[identifier, DIFFERENCE].mean, 5)

    def test_single_image_flips_input_pinned_and_current_without_losing_measurements(self):
        specs = {name: ((4, 5), (.2, .3), (1, 2)) for name in ("input", "prediction")}
        baseline = spatial_snapshot(specifications=specs)
        window = self.window(baseline)
        window.reference.setCurrentText("prediction")
        window.pin_button.click()
        current = spatial_snapshot(specifications=specs)
        current.planes["prediction"] = current.planes["prediction"] + 7
        current.planes["prediction"].setflags(write=False)
        window.install_snapshot(current)
        window.view_selector.setCurrentIndex(window.view_selector.findData("input"))
        window._views["input"].setRange(xRange=(2.1, 2.8), yRange=(1.1, 1.5), padding=0)
        before = camera(window._views["input"])
        window.level.setValue(17)
        window.width.setValue(6)
        window.add_roi("line")
        identifier = window.roi_selector.currentData()
        pump_until(lambda: len(window._profiles) == 3)
        self.assertEqual(set(window._profile_curves), {"input", "prediction", PINNED})
        for key, name in ((QtCore.Qt.Key.Key_BracketRight, "prediction"),
                          (QtCore.Qt.Key.Key_BracketRight, PINNED),
                          (QtCore.Qt.Key.Key_BracketRight, "input"),
                          (QtCore.Qt.Key.Key_BracketLeft, PINNED)):
            QtTest.QTest.keyClick(window, key)
            APP.processEvents()
            self.assertEqual(set(window._planes), {name})
            expected = baseline.planes["prediction"] if name == PINNED else current.planes[name]
            self.assertIs(window._planes[name], expected)
            np.testing.assert_allclose(camera(window._views[name]), before)
            self.assertEqual(tuple(window._items[name].getLevels()), (14, 20))
            self.assertEqual({target for region, target in window._roi_items if region == identifier}, {name})
            pump_until(lambda: len(window._profiles) == 3)
        window.view_selector.setCurrentIndex(window.view_selector.findData("prediction"))
        window.install_snapshot(spatial_snapshot(specifications=specs, delta=20))
        self.assertEqual(window.view_selector.currentData(), "prediction")
        self.assertEqual(set(window._planes), {"prediction"})
        self.assertIs(window._pinned, baseline)

    def test_volume_image_flips_keep_selected_world_slice_and_physical_camera(self):
        specs = {name: ((4, 5, 6), (.2, .3, .4), (1, 2, 3)) for name in ("input", "prediction")}
        window = self.window(spatial_snapshot(specifications=specs))
        window.select_volume_slice(name="prediction", axis=2, index=3)
        window.reference.setCurrentText("prediction")
        window.pin_button.click()
        window.install_snapshot(spatial_snapshot(specifications=specs, delta=30))
        window.view_selector.setCurrentIndex(window.view_selector.findData("input"))
        before = camera(window._views["input"])
        for name in ("prediction", PINNED, "input"):
            window.view_selector.setCurrentIndex(window.view_selector.findData(name))
            self.assertEqual(window.volume_selector.currentData(), name)
            self.assertEqual(window.volume_axis.currentIndex(), 2)
            self.assertEqual(window.slice_index.value(), 3)
            np.testing.assert_allclose(camera(window._views[name]), before)
        window.select_volume_slice(index=4)
        self.assertTrue(all(state.indices[2] == 4 for state in window._volume_selections.values()))

    def test_volume_resampling_update_preserves_world_positions(self):
        window = self.window(spatial_snapshot(specifications={"volume": ((4, 5, 6), (.2, .3, .4), (1, 2, 3))}))
        for axis, index in ((0, 1), (1, 2), (2, 3)):
            window.select_volume_slice(axis=axis, index=index)
        window.install_snapshot(spatial_snapshot(specifications={"volume": ((7, 13, 21), (.1, .1, .1), (1, 2, 3))}))
        self.assertEqual(window._volume_selections["volume"].axis, 2)
        self.assertEqual(window._volume_selections["volume"].indices, (2, 6, 12))

    def test_mixed_physical_pixel_units_and_rotated_metadata_do_not_mislead(self):
        data = spatial_snapshot()
        member = data.manifest["planes"][1]
        for field in ("spacing", "origin", "direction", "spatial_units"):
            member.pop(field)
        window = self.window(data)
        self.assertFalse(window._linked)
        data = spatial_snapshot()
        data.manifest["planes"][1]["spatial_units"] = "cm"
        window.install_snapshot(data)
        self.assertFalse(window._linked)
        data = spatial_snapshot()
        data.manifest["planes"][0]["direction"] = [0, -1, 1, 0]
        before = window._snapshot
        with self.assertRaisesRegex(ValueError, "identity"):
            window.install_snapshot(data)
        self.assertIs(window._snapshot, before)

    def test_image_rectangles_equal_despite_long_titles_axes_resize_and_flip(self):
        long_name = "prediction with a very long model and checkpoint name " * 4
        specs = {
            "input": ((40, 60), (.2, .3), (1, 2)),
            long_name: ((17, 101), (.1, .1), (1234567, -8901234)),
            "pixel image": ((71, 32), (1, 1), (0, 0)),
        }
        for count in (2, 3):
            with self.subTest(panes=count):
                data = spatial_snapshot(specifications=dict(list(specs.items())[:count]))
                data.manifest["planes"][1]["grid_id"] = "offset frame"
                if count == 3:
                    for field in ("spacing", "origin", "direction", "spatial_units"):
                        data.manifest["planes"][2].pop(field)
                window = self.window(data)
                for width, height in ((1120, 800), (880, 560), (1300, 840)):
                    window.resize(width, height)
                    QtTest.QTest.qWait(25)
                    sizes = [(view.width(), view.height(), view.sceneBoundingRect().top())
                             for view in window._views.values()]
                    self.assertGreater(sizes[0][0], 100)
                    for size in sizes[1:]:
                        np.testing.assert_allclose(size, sizes[0], atol=.01)
                    # A real tiling window manager owns the top-level size;
                    # equality is required at its actual viewport dimensions.
                    if APP.platformName() == "offscreen":
                        self.assertEqual(window.size().width(), width)
                window.view_selector.setCurrentIndex(window.view_selector.findData(long_name))
                QtTest.QTest.qWait(25)
                self.assertGreater(window._plots[long_name].width(), window.graphics.viewport().width() * .9)
                window.view_selector.setCurrentIndex(0)
                QtTest.QTest.qWait(25)
                sizes = [(view.width(), view.height()) for view in window._views.values()]
                for size in sizes[1:]:
                    np.testing.assert_allclose(size, sizes[0], atol=.01)
                window.close()


if __name__ == "__main__":
    unittest.main()
