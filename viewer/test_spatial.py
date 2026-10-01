"""Calibrated upsampling correspondence and original-sample ROI geometry."""

import unittest
from types import SimpleNamespace

import numpy as np

from ejn_viewer.analysis import (Region, correspondence, frame_correspondence,
                                comparison_error, line_profile, world_region_to_pixel)
from ejn_viewer.analysis_worker import AnalysisJob, compute
from ejn_viewer.spatial import (plane_geometry, project_metadata,
                               physical_frame_correspondence)


def metadata(spacing=(.2, .2), origin=None, units="mm", grid="scan"):
    ndim = len(spacing)
    return {"spacing": list(spacing), "origin": list(origin or (0.,) * ndim),
            "direction": [float(row == col) for row in range(ndim) for col in range(ndim)],
            "spatial_units": units, "grid_id": grid, "units": "HU"}


class SpatialGeometryTests(unittest.TestCase):
    def test_index_zero_is_sample_center_and_pixels_have_half_edges(self):
        geometry = plane_geometry(metadata((.1, .2), (10, 20)))
        self.assertEqual(geometry.pixel_to_world(.5, .5), (20, 10))
        np.testing.assert_allclose(geometry.pixel_to_world(2.5, 3.5), (20.4, 10.3))
        np.testing.assert_allclose(geometry.world_to_pixel(20.4, 10.3), (2.5, 3.5))
        np.testing.assert_allclose(geometry.image_rect((3, 5)), (19.9, 9.95, 1, .3))
        np.testing.assert_allclose(geometry.pixel_delta_to_world(3, 2), (.6, .2))
        np.testing.assert_allclose(geometry.world_delta_to_pixel(.6, .2), (3, 2))

    def test_no_metadata_is_exact_pixel_identity(self):
        geometry = plane_geometry({})
        self.assertFalse(geometry.physical)
        self.assertIsNone(geometry.units)
        self.assertEqual(geometry.pixel_to_world(.5, 2.5), (.5, 2.5))
        self.assertEqual(geometry.world_to_pixel(0, -2), (0, -2))
        self.assertEqual(geometry.image_rect((3, 4)), (0, 0, 4, 3))
        roi = Region(1, "area", "original", "rectangle", -.5, 1, 2, 3)
        self.assertEqual(world_region_to_pixel(roi, {}), roi)

    def test_upsampled_axis_links_physical_frame_but_forbids_difference(self):
        original = np.zeros((3, 4), np.float32)
        upsampled = np.zeros((5, 4), np.float32)
        first, second = metadata((.2, .3)), metadata((.1, .3))
        self.assertTrue(frame_correspondence(original, upsampled, first, second))
        self.assertFalse(correspondence(original, upsampled, first, second))
        self.assertIsNotNone(comparison_error(original, upsampled, first, second, "s", "s"))
        # Equal shape alone also cannot make unequal sample spacing subtractable.
        self.assertFalse(correspondence(original, original, first, second))
        self.assertTrue(frame_correspondence(original, original, first,
                                            metadata((.2, .3), (10, 20))))

    def test_physical_frame_checks_units_direction_and_grid(self):
        array = np.zeros((2, 2))
        first = metadata()
        for second in (metadata(units="cm"), metadata(grid="another"),
                       dict(first, direction=[0, 1, -1, 0]), {},
                       {"spacing": [.1, .1]}):
            self.assertFalse(frame_correspondence(array, array, first, second))
        absent = metadata(grid="")
        self.assertFalse(frame_correspondence(array, array, absent, absent))
        self.assertTrue(frame_correspondence(array, array, absent, absent, declared=True))
        self.assertFalse(frame_correspondence(array, array, first,
                                             metadata(grid="other"), declared=True))
        # Different intensity units do not change spatial coordinates.
        self.assertTrue(frame_correspondence(array, array, first, dict(first, units="counts")))

    def test_legacy_grid_matching_is_unchanged(self):
        first, other_shape = np.zeros((2, 2)), np.zeros((4, 2))
        self.assertTrue(frame_correspondence(first, first, {"grid_id": "g"}, {"grid_id": "g"}))
        self.assertFalse(frame_correspondence(first, other_shape,
                                             {"grid_id": "g"}, {"grid_id": "g"}))
        self.assertFalse(frame_correspondence(first, first, {}, {}))
        self.assertTrue(frame_correspondence(first, first, {}, {}, declared=True))

    def test_volumes_project_source_axes_and_match_physical_slice(self):
        first = metadata((.2, .3, .4), (1, 2, 3))
        second = metadata((.1, .3, .4), (1, 2, 3))
        original, upsampled = np.zeros((5, 7, 9)), np.zeros((9, 7, 9))
        self.assertTrue(frame_correspondence(original, upsampled, first, second))
        a = project_metadata(first, original.shape, 0, 2)
        b = project_metadata(second, upsampled.shape, 0, 4)
        self.assertEqual(a["spacing"], [.3, .4])
        self.assertEqual(a["origin"], [2, 3])
        self.assertAlmostEqual(a["_volume_slice"]["position"], 1.4)
        self.assertTrue(frame_correspondence(original[2], upsampled[4], a, b))
        # Although raw volume sampling differs, these selected planes share a lattice.
        self.assertTrue(correspondence(original[2], upsampled[4], a, b))
        shifted = project_metadata(second, upsampled.shape, 0, 3)
        self.assertTrue(frame_correspondence(original[2], upsampled[3], a, shifted))
        self.assertFalse(correspondence(original[2], upsampled[3], a, shifted))
        orientation = project_metadata(first, original.shape, 1, 2)
        self.assertFalse(frame_correspondence(original[2], original[:, 2], a, orientation))

    def test_slice_tolerance_cannot_merge_distinct_slices_at_large_origins(self):
        array = np.zeros((5, 2, 2))
        for step, origin in ((.1, 1e9), (1e-12, 0)):
            meta = metadata((step, .1, .1), (origin, 0, 0))
            first = project_metadata(meta, array.shape, 0, 0)
            second = project_metadata(meta, array.shape, 0, 2)
            self.assertFalse(correspondence(array[0], array[2], first, second))
            self.assertTrue(frame_correspondence(array[0], array[2], first, second))
            self.assertIsNotNone(comparison_error(array[0], array[2], first, second, "s", "s"))
        # Decimal arithmetic on coincident sample centers still gets its ULP allowance.
        first = project_metadata(metadata((.1, .1, .1)), array.shape, 0, 3)
        second = project_metadata(metadata((.3, .1, .1)), array.shape, 0, 1)
        self.assertTrue(correspondence(array[3], array[1], first, second))

    def test_projection_legacy_shape_slice_identity_is_retained(self):
        projected = project_metadata({"grid_id": "g"}, (3, 4, 5), 1, 2)
        self.assertEqual(projected["_volume_slice"], ((3, 4, 5), 1, 2))
        self.assertNotIn("spacing", projected)
        self.assertEqual(plane_geometry(projected).image_rect((3, 5)), (0, 0, 5, 3))

    def test_invalid_or_unrepresentable_coordinates_fail_before_display(self):
        first = metadata()
        for invalid in (dict(first, spacing=[0, 1]), dict(first, spacing=[float("inf"), 1]),
                        dict(first, origin=[float("nan"), 0]),
                        dict(first, direction=[0, 1, -1, 0]),
                        dict(first, spatial_units=""), {"spacing": [.1, .1]}):
            with self.assertRaises(ValueError):
                plane_geometry(invalid)
        huge = metadata((1e308, 1e308))
        with self.assertRaises(ValueError):
            plane_geometry(huge).image_rect((4, 4))
        self.assertFalse(physical_frame_correspondence((4, 4), (4, 4), huge, huge))
        with self.assertRaises(ValueError):
            plane_geometry(metadata((.1, .1), (1e20, 0))).image_rect((4, 4))
        with self.assertRaises(ValueError):
            project_metadata(metadata((1e308, 1, 1)), (4, 4, 4), 0, 0)


class PhysicalAnalysisTests(unittest.TestCase):
    def job(self, region, original, upsampled, first_meta, second_meta):
        snapshot = SimpleNamespace(planes={"original": original, "upsampled": upsampled})
        return AnalysisJob(object(), 1, snapshot, (region,),
                           {region.identifier: ("original", "upsampled")},
                           metadata={"original": first_meta, "upsampled": second_meta})

    def test_same_world_line_samples_each_native_lattice_with_mm_distances(self):
        first, second = metadata((1, .2)), metadata((1, .1))
        original = np.array([[0., 10., 20.]])
        upsampled = np.array([[0., 5., 10., 15., 20.]])
        line = Region(1, "line", "original", "line", 0, 0, .4, 0)
        _, results = compute(self.job(line, original, upsampled, first, second))
        coarse, fine = results[1, "original"], results[1, "upsampled"]
        np.testing.assert_allclose(coarse.distance, [0, .2, .4])
        np.testing.assert_allclose(fine.distance, [0, .1, .2, .3, .4])
        np.testing.assert_allclose(coarse.values, original[0])
        np.testing.assert_allclose(fine.values, upsampled[0])
        self.assertEqual(coarse.distance_units, "mm")
        self.assertEqual(fine.distance_units, "mm")
        self.assertFalse(fine.distance.flags.writeable)

    def test_shared_world_rectangle_measures_native_sample_counts(self):
        original = np.array([[0., 10., 20.]])
        upsampled = np.array([[0., 5., 10., 15., 20.]])
        region = Region(1, "area", "original", "rectangle", .1, -.5, .2, 1)
        _, results = compute(self.job(region, original, upsampled,
                                      metadata((1, .2)), metadata((1, .1))))
        coarse, fine = results[1, "original"], results[1, "upsampled"]
        self.assertEqual((coarse.finite, coarse.mean), (1, 10))
        self.assertEqual((fine.finite, fine.mean), (2, 7.5))

    def test_translated_decimal_roi_retains_half_open_sample_membership(self):
        original = np.arange(10., dtype=np.float64).reshape(1, 10)
        finer = np.arange(20., dtype=np.float64).reshape(1, 20) / 2
        region = Region(1, "area", "original", "rectangle", 10.3, -.5, .2, 1)
        first, second = metadata((1, .1), (0, 10)), metadata((1, .05), (0, 10))
        mapped = world_region_to_pixel(region, first)
        self.assertEqual((mapped.x, mapped.width), (3.5, 2))
        _, results = compute(self.job(region, original, finer, first, second))
        self.assertEqual((results[1, "original"].finite, results[1, "original"].mean), (2, 3.5))
        self.assertEqual((results[1, "upsampled"].finite, results[1, "upsampled"].mean), (4, 3.75))
        # Deliberately off-center boundaries farther than arithmetic ULPs do not snap.
        off_center = plane_geometry(first).world_to_pixel(10.30001, 0)[0]
        self.assertGreater(off_center, 3.5)

    def test_world_roi_translation_accounts_for_each_crop_origin(self):
        first = metadata((1, .2), (0, 0))
        second = metadata((1, .1), (0, .2))
        original = np.array([[0., 10., 20.]])
        shifted = np.array([[10., 15., 20.]])
        line = Region(1, "line", "original", "line", .2, 0, .2, 0)
        _, results = compute(self.job(line, original, shifted, first, second))
        np.testing.assert_allclose(results[1, "original"].values, [10, 20])
        np.testing.assert_allclose(results[1, "upsampled"].values, [10, 15, 20])
        np.testing.assert_allclose(results[1, "upsampled"].distance, [0, .1, .2])

    def test_anisotropic_diagonal_profiles_use_physical_arclength(self):
        array = np.arange(9.).reshape(3, 3)
        profile = line_profile(array, Region(1, "line", "p", "line", .5, .5, 2, 2),
                               spacing=(.1, .2), distance_units="mm")
        self.assertAlmostEqual(profile.distance[-1], np.hypot(.2, .4))
        self.assertEqual(profile.distance_units, "mm")
        clipped = line_profile(array, Region(1, "line", "p", "line", -1, .5, 4, 0),
                               spacing=(.1, .2), distance_units="mm")
        self.assertAlmostEqual(clipped.distance[0], .2)
        self.assertAlmostEqual(clipped.distance[-1], .8)
        self.assertEqual(line_profile(array, Region(1, "line", "p", "line", .5, .5, 2, 0)).distance_units,
                         "px")


if __name__ == "__main__":
    unittest.main()
