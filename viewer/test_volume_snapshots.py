"""Volume wire snapshots retain every original voxel with no mutable copies."""

import unittest

import numpy as np

from ejn_viewer.analysis import VolumeSelection, scalar_array
from ejn_viewer.snapshots import _load_array_group
from test_snapshots import group_bytes


class VolumeSnapshotTests(unittest.TestCase):
    def test_full_crop_round_trip_and_all_orientation_views(self):
        array = np.arange(3 * 5 * 7, dtype=">f2").reshape(3, 5, 7)
        raw = group_bytes(array)
        manifest, arrays = _load_array_group(raw)
        volume = arrays["plane"]
        self.assertEqual(manifest["planes"][0]["shape"], [3, 5, 7])
        self.assertTrue(scalar_array(volume))
        self.assertEqual(volume.dtype.str, ">f2")
        self.assertFalse(volume.flags.writeable)
        self.assertIs(volume.base.base, raw)
        for axis in range(3):
            state = VolumeSelection.centered(volume.shape).select(volume.shape, axis=axis, index=0)
            expected = np.take(array, 0, axis=axis)
            face = state.plane(volume)
            np.testing.assert_array_equal(face, expected)
            self.assertTrue(np.shares_memory(face, volume))
            self.assertFalse(face.flags.writeable)

    def test_invalid_volume_axes_and_shapes_are_rejected(self):
        state = VolumeSelection.centered((3, 5, 7))
        for axis in (-1, 3, True, "1"):
            with self.assertRaises(ValueError):
                state.select((3, 5, 7), axis=axis)
        for shape in ((0, 5, 7), (3,), (2, 3, 4, 5)):
            self.assertFalse(scalar_array(np.empty(shape, dtype=np.float32)))


if __name__ == "__main__":
    unittest.main()
