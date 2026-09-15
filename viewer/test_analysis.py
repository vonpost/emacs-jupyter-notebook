"""Exact, display-independent numerical comparison and ROI fixtures."""

import unittest
from unittest import mock
from types import SimpleNamespace

import numpy as np

from ejn_viewer.analysis import (DIFFERENCE, MAX_PROFILE_BYTES, MAX_PROFILE_SAMPLES,
                                SCRATCH_BYTES, Profile, Region, Statistics,
                                comparison_error, correspondence, difference,
                                line_profile, statistics)
from ejn_viewer.analysis_worker import (AnalysisJob, AnalysisWorker, compute,
                                       profile_result_bytes)


def region(kind="rectangle", x=0, y=0, width=4, height=3):
    return Region(1, "ROI 1", "reference", kind, x, y, width, height)


class AnalysisTests(unittest.TestCase):
    def test_unsigned_difference_promotes_before_subtraction(self):
        reference = np.array([[255, 10], [0, 2**32 - 1]], dtype=np.uint32)
        candidate = np.array([[0, 20], [7, 0]], dtype=np.uint32)
        before = reference.copy(), candidate.copy()
        expected = [[-255, 10], [7, -(2**32 - 1)]]
        actual = difference(reference, candidate)
        self.assertEqual(actual.dtype, np.float64)
        self.assertFalse(actual.flags.writeable)
        np.testing.assert_array_equal(actual, expected)
        np.testing.assert_array_equal(difference(reference, candidate, absolute=True), np.abs(expected))
        np.testing.assert_array_equal(reference, before[0])
        np.testing.assert_array_equal(candidate, before[1])

    def test_nonfinite_operands_and_float_overflow_are_excluded(self):
        reference = np.array([[np.nan, np.inf, -np.inf, -1e308, 1.]])
        candidate = np.array([[1., np.inf, 3., 1e308, 4.]])
        result = difference(reference, candidate)
        self.assertTrue(np.all(np.isnan(result[0, :4])))
        stats = statistics(result, region(width=5, height=1))
        self.assertEqual((stats.mean, stats.sd, stats.finite, stats.excluded), (3, 0, 1, 4))

    def test_compatibility_rejects_undeclared_sample_grid_and_units(self):
        array = np.zeros((2, 2), dtype=np.float32)
        meta = {"grid_id": "g", "units": "HU", "spacing": [1, 1]}
        def error(first=meta, second=meta, sample="s", other_sample="s", other=array, **kw):
            return comparison_error(array, other, first, second, sample, other_sample, **kw)
        self.assertIsNone(error())
        for args in ({"sample": ""}, {"other_sample": "different"},
                     {"second": dict(meta, grid_id="other")},
                     {"second": dict(meta, spacing=[2, 1])},
                     {"second": dict(meta, units="counts")},
                     {"other": np.zeros((3, 2), dtype=np.float32)}):
            self.assertIsNotNone(error(**args))
        absent = {"spacing": [1, 1]}
        self.assertIsNotNone(error(absent, absent))
        self.assertIsNone(error(absent, absent, declared_grid=True, declared_units=True))
        self.assertIsNotNone(error(meta, dict(meta, grid_id="other"), declared_grid=True))
        self.assertIsNotNone(error(meta, dict(meta, units="counts"), declared_units=True))
        self.assertFalse(correspondence(array, array, {}, {}))

    def test_int64_and_non_scalar_precision_is_rejected(self):
        for dtype in (np.int64, np.uint64, np.complex64, np.bool_, np.float16):
            with self.assertRaises(ValueError):
                difference(np.zeros((2, 2), dtype=dtype), np.zeros((2, 2), dtype=dtype))
            with self.assertRaises(ValueError):
                statistics(np.zeros((2, 2), dtype=dtype), region())
        with self.assertRaises(ValueError):
            statistics(np.zeros((2, 2, 3), dtype=np.uint8), region())

    def test_difference_budget_before_allocating(self):
        with mock.patch("ejn_viewer.analysis.MAX_DIFFERENCE_BYTES", 31):
            with self.assertRaises(ValueError):
                difference(np.zeros((2, 2)), np.ones((2, 2)))

    def test_rectangle_half_open_pixel_centers_and_clipping(self):
        array = np.arange(12, dtype=np.float64).reshape(3, 4)
        # Centers x=0.5,1.5 are included; x=2.5 is excluded. y=1.5 is excluded.
        stats = statistics(array, region(x=.5, y=.5, width=2, height=1))
        self.assertEqual((stats.mean, stats.sd, stats.finite), (.5, .5, 2))
        clipped = statistics(array, region(x=-10, y=-10, width=12, height=12))
        self.assertEqual(clipped.finite, 4)
        self.assertEqual(clipped.mean, 2.5)  # 0,1,4,5
        self.assertAlmostEqual(clipped.sd, np.sqrt(4.25))

    def test_ellipse_known_mask_and_inclusive_edge(self):
        array = np.arange(9, dtype=np.float64).reshape(3, 3)
        # Ellipse center (1.5,1.5), radius 1: exactly the five-center cross.
        stats = statistics(array, region("ellipse", .5, .5, 2, 2))
        self.assertEqual((stats.mean, stats.finite, stats.excluded), (4, 5, 0))
        self.assertEqual(stats.sd, 2)  # deviations -3,-1,0,1,3, variance 4
        corner = statistics(array, region("ellipse", -1, -1, 2, 2))
        self.assertEqual((corner.mean, corner.sd, corner.finite), (0, 0, 1))

    def test_empty_single_all_nonfinite_and_mixed_regions(self):
        array = np.array([[1, np.nan], [np.inf, 5]], dtype=np.float64)
        for selection in (region(x=9), region(width=0), region("ellipse", width=-1)):
            self.assertEqual(statistics(array, selection).finite, 0)
            self.assertIsNone(statistics(array, selection).sd)
        one = statistics(array, region(width=1, height=1))
        self.assertEqual((one.mean, one.sd, one.finite, one.excluded), (1, 0, 1, 0))
        invalid = statistics(array, region(x=1, width=1, height=1))
        self.assertEqual((invalid.mean, invalid.sd, invalid.finite, invalid.excluded), (None, None, 0, 1))
        all_values = statistics(array, region(width=2, height=2))
        self.assertEqual((all_values.mean, all_values.sd, all_values.finite, all_values.excluded), (3, 2, 2, 2))

    def test_blockwise_stable_population_statistics(self):
        array = (1e12 + np.tile(np.arange(4, dtype=np.float64), (7, 1)))
        before = array.copy()
        with mock.patch("ejn_viewer.analysis.BLOCK_PIXELS", 4):
            actual = statistics(array, region(width=4, height=7))
        self.assertEqual(actual.mean, 1e12 + 1.5)
        self.assertAlmostEqual(actual.sd, np.sqrt(1.25))
        np.testing.assert_array_equal(array, before)
        extreme = statistics(np.array([[-1e308, 1e308]]), region(width=2, height=1))
        self.assertEqual(extreme.mean, 0)
        self.assertEqual(extreme.sd, 1e308)

    def test_sd_keeps_halfway_mean_precision_at_large_common_offset(self):
        array = np.array([[1e16, 1e16 + 2]])
        # The true mean 1e16+1 is not representable in float64; its rounded
        # display value must not become the origin for variance calculation.
        result = statistics(array, region(width=2, height=1))
        self.assertEqual(result.mean, 1e16)
        self.assertEqual(result.sd, 1)
        # Force one sample per row block so the pairwise merge has the same
        # precision guarantee as a single-block calculation.
        with mock.patch("ejn_viewer.analysis.BLOCK_PIXELS", 1):
            split = statistics(array.T, region(width=1, height=2))
        self.assertEqual(split.sd, 1)
        with mock.patch("ejn_viewer.analysis.BLOCK_PIXELS", 1):
            four = statistics(np.array([[1e16], [1e16 + 2], [1e16 + 4], [1e16 + 6]]),
                              region(width=1, height=4))
        self.assertEqual(four.sd, np.sqrt(5))

    def test_adjacent_extreme_floats_keep_their_actual_difference(self):
        low = 1e308
        high = np.nextafter(low, np.inf)
        expected = (high - low) / 2
        actual = statistics(np.array([[low, high]]), region(width=2, height=1))
        self.assertAlmostEqual(actual.sd / expected, 1.0, places=15)
        with mock.patch("ejn_viewer.analysis.BLOCK_PIXELS", 1):
            split = statistics(np.array([[low], [high]]), region(width=1, height=2))
        self.assertAlmostEqual(split.sd / expected, 1.0, places=15)


class LineProfileTests(unittest.TestCase):
    def test_horizontal_vertical_and_reversed_pixel_centers(self):
        array = np.arange(12, dtype=np.float64).reshape(3, 4)
        horizontal = line_profile(array, region("line", .5, 1.5, 3, 0))
        np.testing.assert_array_equal(horizontal.distance, [0, 1, 2, 3])
        np.testing.assert_array_equal(horizontal.values, [4, 5, 6, 7])
        vertical = line_profile(array, region("line", 1.5, .5, 0, 2))
        np.testing.assert_array_equal(vertical.values, [1, 5, 9])
        reverse = line_profile(array, region("line", 3.5, 1.5, -3, 0))
        np.testing.assert_array_equal(reverse.distance, horizontal.distance)
        np.testing.assert_array_equal(reverse.values, horizontal.values[::-1])

    def test_diagonal_bilinear_sampling_uses_directed_pixel_distance(self):
        array = np.array([[0, 10, 20], [100, 110, 120], [200, 210, 220]], dtype=np.float64)
        profile = line_profile(array, region("line", .5, .5, 2, 2))
        np.testing.assert_allclose(profile.distance, np.linspace(0, np.sqrt(8), 4))
        np.testing.assert_allclose(profile.values, np.linspace(0, 220, 4))
        reverse = line_profile(array, region("line", 2.5, 2.5, -2, -2))
        np.testing.assert_allclose(reverse.values, profile.values[::-1])

    def test_subpixel_bilinear_weights_and_unsigned_samples(self):
        array = np.array([[0, 10], [20, 30]], dtype=np.uint32)
        profile = line_profile(array, region("line", .75, 1, 0, 0))
        np.testing.assert_array_equal(profile.distance, [0])
        np.testing.assert_array_equal(profile.values, [12.5])
        maximum = np.iinfo(np.uint32).max
        high = line_profile(np.array([[maximum, 0]], dtype=np.uint32),
                            region("line", 1, .5, 0, 0))
        self.assertEqual(high.values[0], maximum / 2)

    def test_clipping_preserves_original_origin_and_extends_edge_pixels(self):
        array = np.array([[0, 10, 20]], dtype=np.float64)
        forward = line_profile(array, region("line", -1, .5, 5, 0))
        np.testing.assert_array_equal(forward.distance, [1, 2, 3, 4])
        np.testing.assert_array_equal(forward.values, [0, 5, 15, 20])
        backward = line_profile(array, region("line", 4, .5, -5, 0))
        np.testing.assert_array_equal(backward.distance, [1, 2, 3, 4])
        np.testing.assert_array_equal(backward.values, [20, 15, 5, 0])
        diagonal = line_profile(np.array([[0, 10], [20, 30]], dtype=np.float64),
                                region("line", -1, -1, 4, 4))
        np.testing.assert_allclose(diagonal.distance[[0, -1]], [np.sqrt(2), 3 * np.sqrt(2)])
        np.testing.assert_allclose(diagonal.values, [0, 5, 25, 30])

    def test_empty_missed_single_pixel_and_corner_touch(self):
        array = np.array([[7]], dtype=np.float64)
        for selection in (region("line", -1, -1, 0, 0),
                          region("line", -2, .5, 1, 0),
                          region("line", -2, 2, 4, 0)):
            profile = line_profile(array, selection)
            self.assertEqual(profile.values.size, 0)
            self.assertEqual(profile.distance.size, 0)
        empty = line_profile(np.empty((0, 2)), region("line", 0, 0, 1, 0))
        self.assertEqual(empty.values.size, 0)
        corner = line_profile(array, region("line", -1, 1, 1, -1))
        np.testing.assert_allclose(corner.distance, [np.sqrt(2)])
        np.testing.assert_array_equal(corner.values, [7])
        along = line_profile(array, region("line", 0, .5, 1, 0))
        np.testing.assert_array_equal(along.values, [7, 7])

    def test_nonfinite_neighbors_only_exclude_nonzero_weights(self):
        array = np.array([[10, np.nan], [np.inf, -np.inf]])
        exact = line_profile(array, region("line", .5, .5, 0, 0))
        np.testing.assert_array_equal(exact.values, [10])
        edge = line_profile(array, region("line", 0, 0, .5, .5))
        np.testing.assert_array_equal(edge.values, [10, 10])
        for point in ((1, .5), (.5, 1), (1, 1), (1.5, 1.5)):
            sampled = line_profile(array, region("line", *point, 0, 0))
            self.assertTrue(np.isnan(sampled.values[0]))

    def test_extreme_finite_samples_do_not_overflow_interpolation(self):
        maximum = np.finfo(np.float64).max
        with np.errstate(all="raise"):
            constant = line_profile(np.full((2, 2), maximum),
                                    region("line", .625, .875, .5, .25))
            np.testing.assert_array_equal(constant.values, [maximum, maximum])
            opposite = line_profile(np.array([[maximum, -maximum]]),
                                    region("line", 1, .5, 0, 0))
            np.testing.assert_array_equal(opposite.values, [0])
            nearby = line_profile(np.array([[maximum, np.nextafter(maximum, 0)]]),
                                  region("line", .75, .5, 0, 0))
            self.assertTrue(np.isfinite(nearby.values[0]))

    def test_sample_cap_is_uniform_keeps_endpoints_and_reports_coarsening(self):
        array = np.arange(10_000, dtype=np.float64)[None, :]
        profile = line_profile(array, region("line", .5, .5, 9999, 0))
        self.assertEqual(profile.values.size, MAX_PROFILE_SAMPLES)
        self.assertEqual(profile.nbytes, MAX_PROFILE_BYTES)
        self.assertTrue(profile.capped)
        np.testing.assert_allclose(profile.distance, np.linspace(0, 9999, MAX_PROFILE_SAMPLES))
        np.testing.assert_allclose(profile.values, profile.distance)
        uncapped = line_profile(array, region("line", .5, .5, MAX_PROFILE_SAMPLES - 1, 0))
        self.assertEqual(uncapped.values.size, MAX_PROFILE_SAMPLES)
        self.assertFalse(uncapped.capped)

    def test_readonly_noncontiguous_input_and_result_immutability(self):
        original = np.arange(20, dtype=np.float32).reshape(4, 5)
        before = original.copy()
        view = original[::-1, ::2]
        view.setflags(write=False)
        profile = line_profile(view, region("line", .5, .5, 2, 3))
        for array in (profile.distance, profile.values):
            self.assertEqual(array.dtype, np.float64)
            self.assertFalse(array.flags.writeable)
            with self.assertRaises(ValueError):
                array[0] = 9
        np.testing.assert_array_equal(original, before)

    def test_invalid_shapes_and_geometry_raise_without_allocation(self):
        for array in (np.zeros((2, 2), dtype=np.int64), np.zeros((2, 2, 3)),
                      np.zeros((2, 2), dtype=np.bool_)):
            with self.assertRaises(ValueError):
                line_profile(array, region("line"))
        array = np.zeros((2, 2))
        for selection in (region(), region("line", np.nan),
                          region("line", 0, 0, np.inf, 1),
                          region("line", 1e308, 1e308, 1e308, 1e308)):
            with self.assertRaises(ValueError):
                line_profile(array, selection)


class LineProfileWorkerTests(unittest.TestCase):
    def job(self, regions, targets, **kwargs):
        first = np.array([[0., 10., 20.]])
        second = np.array([[5., 15., 25.]])
        snapshot = SimpleNamespace(planes={"reference": first, "candidate": second},
                                   nbytes=first.nbytes + second.nbytes)
        return AnalysisJob(object(), 1, snapshot, regions, targets, **kwargs)

    def test_compute_mixes_line_profiles_area_statistics_and_difference(self):
        line = region("line", .5, .5, 2, 0)
        area = Region(2, "Area", "reference", "rectangle", 0, 0, 3, 1)
        job = self.job((line, area), {1: ("reference", "candidate", DIFFERENCE),
                                     2: ("reference",)},
                       reference="reference", candidate="candidate")
        derived, results = compute(job)
        for name in ("reference", "candidate", DIFFERENCE):
            self.assertIsInstance(results[1, name], Profile)
        self.assertIsInstance(results[2, "reference"], Statistics)
        np.testing.assert_array_equal(results[1, DIFFERENCE].values, [5, 5, 5])
        np.testing.assert_array_equal(results[1, "candidate"].values, [5, 15, 25])
        self.assertEqual(results[2, "reference"].mean, 10)
        self.assertFalse(derived.flags.writeable)

    def test_cancelled_job_returns_no_partial_profiles(self):
        job = self.job((region("line"),), {1: ("reference",)})
        job.cancelled.set()
        self.assertIsNone(compute(job))

    def test_worker_reserves_profiles_with_scratch_and_retained_sources(self):
        line = region("line", .5, .5, 2, 0)
        area = Region(2, "Area", "reference", "rectangle", 0, 0, 3, 1)
        job = self.job((line, area), {1: ("reference", "candidate"),
                                     2: ("reference",)})
        self.assertEqual(profile_result_bytes(job.regions, job.targets), 2 * MAX_PROFILE_BYTES)
        worker = AnalysisWorker()
        self.addCleanup(worker.shutdown)
        worker.active = job
        self.assertEqual(worker.reserved, job.snapshot.nbytes + SCRATCH_BYTES + 2 * MAX_PROFILE_BYTES)
        # A replaceable pending request only retains input references until it
        # becomes active and is admitted again with scratch and result space.
        worker.pending = self.job((line,), {1: ("reference",)})
        self.assertEqual(worker.reserved, job.snapshot.nbytes + worker.pending.snapshot.nbytes
                         + SCRATCH_BYTES + 2 * MAX_PROFILE_BYTES)
        worker.active = None
        worker.pending = None


if __name__ == "__main__":
    unittest.main()
