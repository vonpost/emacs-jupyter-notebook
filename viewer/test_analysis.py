"""Exact, display-independent numerical comparison and ROI fixtures."""

import unittest
from unittest import mock

import numpy as np

from ejn_viewer.analysis import (Region, comparison_error, correspondence,
                                difference, statistics)


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


if __name__ == "__main__":
    unittest.main()
