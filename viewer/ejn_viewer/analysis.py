"""Original-sample image arithmetic and bounded pixel-center ROI statistics.

This module does no rendering and never calls a kernel.  Call its numerical
functions on the analysis worker, never from a Qt input callback.
"""

from __future__ import annotations

from dataclasses import dataclass
import math

import numpy as np


MAX_ROIS = 16
MAX_DIFFERENCE_BYTES = 32 * 1024 * 1024
MAX_PROFILE_SAMPLES = 4096
# One float64 distance and value per sample; interpolation uses SCRATCH_BYTES.
MAX_PROFILE_BYTES = MAX_PROFILE_SAMPLES * 16
# At most 65,536 values per block, including ellipse masks and float64 scratch.
BLOCK_PIXELS = 65_536
SCRATCH_BYTES = 8 * 1024 * 1024
DIFFERENCE = "\0difference"


@dataclass(frozen=True)
class Region:
    """Pixel-coordinate ROI; line width/height are signed endpoint deltas."""

    identifier: int
    name: str
    plane: str
    kind: str
    x: float
    y: float
    width: float
    height: float


@dataclass(frozen=True)
class Statistics:
    mean: float | None
    sd: float | None
    finite: int
    excluded: int


@dataclass(frozen=True)
class Profile:
    """Read-only original-sample line values and distances in pixel units.

    ``capped`` reports when the sample limit coarsened the usual spacing of
    at most one pixel. Both clipped endpoints are retained even in that case.
    """

    distance: np.ndarray
    values: np.ndarray
    capped: bool = False

    @property
    def nbytes(self):
        return self.distance.nbytes + self.values.nbytes


def scalar_plane(array: np.ndarray) -> bool:
    """V1 scalar types have no unsafe int64-to-float64 conversion."""
    return (isinstance(array, np.ndarray) and array.ndim == 2
            and ((array.dtype.kind in "ui" and array.dtype.itemsize <= 4)
                 or (array.dtype.kind == "f" and array.dtype.itemsize in (4, 8))))


def spatial_key(meta: dict) -> tuple:
    return tuple(meta.get(key) for key in
                 ("spacing", "origin", "direction", "spatial_units"))


def correspondence(first: np.ndarray, second: np.ndarray,
                   first_meta: dict, second_meta: dict, *, declared=False) -> bool:
    """Explicit local correspondence only fills absent grid declarations."""
    if first.shape != second.shape or spatial_key(first_meta) != spatial_key(second_meta):
        return False
    first_grid, second_grid = first_meta.get("grid_id"), second_meta.get("grid_id")
    return (bool(first_grid) and first_grid == second_grid
            or declared and not first_grid and not second_grid)


def comparison_error(reference: np.ndarray, candidate: np.ndarray,
                     reference_meta: dict, candidate_meta: dict,
                     reference_sample: str, candidate_sample: str, *,
                     declared_grid=False, declared_units=False) -> str | None:
    if not scalar_plane(reference) or not scalar_plane(candidate):
        return "Differences require scalar v1 arrays (no int64/uint64 or RGB)."
    if not reference_sample or reference_sample != candidate_sample:
        return "Differences require the same declared sample."
    if not correspondence(reference, candidate, reference_meta, candidate_meta,
                          declared=declared_grid):
        return "Differences require matching shape and declared pixel grids."
    first_units, second_units = reference_meta.get("units"), candidate_meta.get("units")
    if not (first_units and first_units == second_units
            or declared_units and not first_units and not second_units):
        return "Differences require matching units; declare common units if unspecified."
    if reference.size * 8 > MAX_DIFFERENCE_BYTES:
        return "Difference exceeds the 32 MiB local derived-plane limit."
    return None


def difference(reference: np.ndarray, candidate: np.ndarray, *, absolute=False) -> np.ndarray:
    """Float64 candidate minus reference; invalid/overflow pixels become NaN."""
    if not scalar_plane(reference) or not scalar_plane(candidate):
        raise ValueError("unsupported scalar dtype")
    if reference.shape != candidate.shape:
        raise ValueError("difference shape mismatch")
    if reference.size * 8 > MAX_DIFFERENCE_BYTES:
        raise ValueError("difference exceeds 32 MiB")
    result = np.empty(reference.shape, dtype=np.float64)
    rows = max(1, BLOCK_PIXELS // reference.shape[1])
    with np.errstate(invalid="ignore", over="ignore"):
        for start in range(0, reference.shape[0], rows):
            part = result[start:start + rows]
            # Promotion precedes subtraction, so unsigned samples never wrap.
            np.subtract(candidate[start:start + rows], reference[start:start + rows],
                        dtype=np.float64, out=part)
            part[~np.isfinite(part)] = np.nan
            if absolute:
                np.abs(part, out=part)
    result.setflags(write=False)
    return result


def _interpolate(first, second, weight):
    """Convex float64 interpolation, excluding only contributing nonfinites."""
    result = np.full(first.shape, np.nan, dtype=np.float64)
    at_first, at_second = weight == 0, weight == 1
    valid_first, valid_second = np.isfinite(first), np.isfinite(second)
    exact_first, exact_second = at_first & valid_first, at_second & valid_second
    result[exact_first] = first[exact_first]
    result[exact_second] = second[exact_second]
    between = ~at_first & ~at_second & valid_first & valid_second
    # Same-sign subtraction cannot overflow and keeps constant extreme data
    # exact. Opposite-sign weighted addition avoids an overflowing difference.
    same_sign = between & (np.signbit(first) == np.signbit(second))
    opposite_sign = between & ~same_sign
    with np.errstate(under="ignore"):
        result[same_sign] = (first[same_sign] + weight[same_sign]
                             * (second[same_sign] - first[same_sign]))
        result[opposite_sign] = (first[opposite_sign] * (1 - weight[opposite_sign])
                                 + second[opposite_sign] * weight[opposite_sign])
    return result


def line_profile(array: np.ndarray, roi: Region) -> Profile:
    """Bilinear profile of a directed line over immutable original samples.

    Coordinates are in image space: pixel (row, col) is centered at
    (col + .5, row + .5). Clip the segment to the closed image footprint
    [0, cols] x [0, rows], extending edge samples through the outer half pixel.
    Distances start at the original, possibly off-image first endpoint.

    The clipped segment gets ceil(length) + 1 equally spaced samples, including
    both endpoints; a point gets one sample and a missed/empty image gets none.
    At most MAX_PROFILE_SAMPLES are produced. Above that bound ``capped`` is
    true and spacing increases. Nonfinite contributing neighbors produce NaN;
    a nonfinite neighbor with zero weight does not affect an exact sample.
    """
    if not scalar_plane(array):
        raise ValueError("unsupported scalar dtype")
    if roi.kind != "line":
        raise ValueError("line profile requires a line ROI")
    x, y, dx, dy = (float(value) for value in
                    (roi.x, roi.y, roi.width, roi.height))
    length = math.hypot(dx, dy)
    if not all(math.isfinite(value) for value in
               (x, y, dx, dy, x + dx, y + dy, length)):
        raise ValueError("line coordinates and length must be finite")

    def profile(distance, values, capped=False):
        distance.setflags(write=False)
        values.setflags(write=False)
        return Profile(distance, values, capped)

    def empty():
        return profile(np.empty(0, dtype=np.float64), np.empty(0, dtype=np.float64))

    rows, cols = array.shape
    if not rows or not cols:
        return empty()
    start, stop = 0.0, 1.0
    for origin, delta, limit in ((x, dx, cols), (y, dy, rows)):
        if delta == 0:
            if not 0 <= origin <= limit:
                return empty()
            continue
        first, second = -origin / delta, (limit - origin) / delta
        start = max(start, min(first, second))
        stop = min(stop, max(first, second))
        if stop < start:
            return empty()
    # Compute clipped coordinates first so a roundoff in the clip parameter
    # does not add an extra sample to an integer-length horizontal/vertical ROI.
    first_x, last_x = (min(cols, max(0.0, x + dx * t)) for t in (start, stop))
    first_y, last_y = (min(rows, max(0.0, y + dy * t)) for t in (start, stop))
    clipped_length = math.hypot(last_x - first_x, last_y - first_y)
    requested = math.ceil(clipped_length) + 1
    count = min(MAX_PROFILE_SAMPLES, requested)
    distance = np.linspace(start * length, stop * length, count, dtype=np.float64)
    columns = np.clip(np.linspace(first_x, last_x, count) - .5, 0, cols - 1)
    rows_at = np.clip(np.linspace(first_y, last_y, count) - .5, 0, rows - 1)
    left, top = columns.astype(np.intp), rows_at.astype(np.intp)
    right, bottom = np.minimum(left + 1, cols - 1), np.minimum(top + 1, rows - 1)
    horizontal_weight, vertical_weight = columns - left, rows_at - top
    upper = _interpolate(np.asarray(array[top, left], dtype=np.float64),
                         np.asarray(array[top, right], dtype=np.float64), horizontal_weight)
    lower = _interpolate(np.asarray(array[bottom, left], dtype=np.float64),
                         np.asarray(array[bottom, right], dtype=np.float64), horizontal_weight)
    values = _interpolate(upper, lower, vertical_weight)
    return profile(distance, values, requested > MAX_PROFILE_SAMPLES)


def _blocks(array: np.ndarray, roi: Region):
    if roi.kind not in ("rectangle", "ellipse"):
        raise ValueError("unsupported ROI shape")
    x, y, width, height = roi.x, roi.y, roi.width, roi.height
    if not all(math.isfinite(value) for value in (x, y, width, height)):
        raise ValueError("ROI coordinates must be finite")
    if width <= 0 or height <= 0:
        return
    rows, cols = array.shape
    # Rectangle right/bottom edges are half-open; ellipses include their edge.
    closed = roi.kind == "ellipse"
    left = max(0, min(cols, math.ceil(x - 0.5)))
    top = max(0, min(rows, math.ceil(y - 0.5)))
    right = max(0, min(cols, (math.floor(x + width - 0.5) + 1 if closed
                             else math.ceil(x + width - 0.5))))
    bottom = max(0, min(rows, (math.floor(y + height - 0.5) + 1 if closed
                              else math.ceil(y + height - 0.5))))
    if right <= left or bottom <= top:
        return
    step = max(1, BLOCK_PIXELS // (right - left))
    if closed:
        columns = ((np.arange(left, right, dtype=np.float64) + 0.5
                    - x - width / 2) / (width / 2)) ** 2
    for start in range(top, bottom, step):
        stop = min(start + step, bottom)
        values = array[start:stop, left:right]
        if closed:
            row_centers = ((np.arange(start, stop, dtype=np.float64) + 0.5
                            - y - height / 2) / (height / 2)) ** 2
            values = values[row_centers[:, None] + columns[None, :] <= 1.0]
        yield np.asarray(values, dtype=np.float64).reshape(-1)


def statistics(array: np.ndarray, roi: Region) -> Statistics:
    """Clipped original-sample mean and population SD, with finite counts.

    Pairwise block moments use a local origin to retain small variation around
    large offsets. Extreme finite values use scaled moments when squaring
    would overflow; arithmetic follows float64 precision throughout.
    """
    if not scalar_plane(array):
        raise ValueError("unsupported scalar dtype")
    count = excluded = 0
    mean = m2 = 0.0
    scale = 0.0
    first_value = 0.0
    for values in _blocks(array, roi):
        finite = values[np.isfinite(values)]
        excluded += values.size - finite.size
        if finite.size:
            if count == 0:
                first_value = float(finite[0])
            scale = max(scale, float(np.max(np.abs(finite))))
            count += finite.size
    if not count:
        return Statistics(None, None, 0, excluded)
    # Scaling only for extremes preserves subtraction accuracy for usual data.
    divisor = scale if scale > 1.0e150 or 0 < scale < 1.0e-150 else 1.0
    origin = first_value / divisor
    seen = 0
    for values in _blocks(array, roi):
        finite = values[np.isfinite(values)]
        n = finite.size
        if not n:
            continue
        # Keep every block's mean relative to one common origin. Adding an
        # absolute 1e16 offset before subtracting the mean would round away a
        # true halfway mean and corrupt SD even for just [1e16, 1e16 + 2].
        with np.errstate(over="ignore", invalid="ignore"):
            centered = finite - first_value
        overflowed = ~np.isfinite(centered)
        centered /= divisor
        # Subtract before scaling to keep the difference between neighboring
        # very large floats. Opposite extreme signs can overflow subtraction,
        # in which case the scaled form supplies a finite relative coordinate.
        if np.any(overflowed):
            centered[overflowed] = finite[overflowed] / divisor - origin
        part_mean = float(np.mean(centered))
        centered = centered - part_mean
        # An elementwise reduction avoids BLAS thread startup/oversubscription
        # for every small block while keeping the temporary set bounded.
        part_m2 = float(np.sum(centered * centered))
        total = seen + n
        delta = part_mean - mean
        mean += delta * (n / total)
        m2 += part_m2 + delta * delta * (seen * n / total)
        seen = total
    absolute_mean = first_value + mean * divisor
    if not math.isfinite(absolute_mean):
        absolute_mean = (origin + mean) * divisor
    return Statistics(absolute_mean, math.sqrt(max(0.0, m2 / count)) * divisor,
                      count, excluded)
