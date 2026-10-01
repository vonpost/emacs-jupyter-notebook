"""Axis-aligned physical geometry for retained numerical planes and crops.

Array indices name sample centers. Image coordinates name pixel edges, so
sample (row, col) is at (col + .5, row + .5). Metadata origins name center
index zero in ndarray axis order. Without metadata, all mappings are identity.
No routine resamples or modifies array data.
"""

from __future__ import annotations

from dataclasses import dataclass
import math


SPATIAL_FIELDS = frozenset(("spacing", "origin", "direction", "spatial_units"))


def _numbers(values, count, label, *, positive=False):
    if not isinstance(values, (tuple, list)) or len(values) != count:
        raise ValueError(f"{label} must have {count} axis values")
    if not all(type(value) in (int, float) and math.isfinite(value)
               and (not positive or value > 0) for value in values):
        raise ValueError(f"{label} must be finite" + (" and positive" if positive else ""))
    return tuple(float(value) for value in values)


def _axis_values(meta, ndim):
    present = SPATIAL_FIELDS.intersection(meta)
    if not present:
        return (1.0,) * ndim, (.5,) * ndim, None, False
    if present != SPATIAL_FIELDS:
        raise ValueError("incomplete spatial metadata")
    spacing = _numbers(meta["spacing"], ndim, "spacing", positive=True)
    origin = _numbers(meta["origin"], ndim, "origin")
    direction = _numbers(meta["direction"], ndim * ndim, "direction")
    identity = tuple(float(row == col) for row in range(ndim) for col in range(ndim))
    if direction != identity:
        raise ValueError("physical display requires an identity direction matrix")
    units = meta["spatial_units"]
    if not isinstance(units, str) or not units:
        raise ValueError("spatial units must be a nonempty string")
    return spacing, origin, units, True


def _finite(*values):
    if not all(math.isfinite(value) for value in values):
        raise ValueError("physical coordinates exceed finite display bounds")
    return tuple(values)


def _extent(shape, spacing, origin):
    if (len(shape) != len(spacing)
            or any(type(size) is not int or size <= 0 for size in shape)):
        raise ValueError("spatial shape must have positive axis sizes")
    for size, step, center in zip(shape, spacing, origin):
        edge = center - .5 * step
        _finite(edge, size * step, edge + size * step)
        if edge + size * step <= edge or size > 1 and center + step == center:
            raise ValueError("physical sampling is below coordinate precision")


def _pixel_coordinate(world, center, step):
    """Invert one axis, removing only arithmetic noise at sample centers.

    Subtracting a translated origin amplifies its ULP error by 1/spacing.
    Snapping that error prevents a half-open ROI edge from shifting across a
    sample center. The tolerance never exceeds one millionth of a pixel.
    """
    position = _finite((world - center) / step + .5)[0]
    nearest = round(position - .5) + .5
    uncertainty = 4 * ((math.ulp(world) + math.ulp(center)) / step + math.ulp(position))
    return nearest if abs(position - nearest) <= min(1e-6, uncertainty) else position


@dataclass(frozen=True)
class PlaneGeometry:
    """Row/column calibration; x is column and y is row in the viewer."""

    spacing: tuple[float, float]
    origin: tuple[float, float]
    units: str | None
    physical: bool

    def pixel_to_world(self, x, y):
        return _finite(self.origin[1] + (x - .5) * self.spacing[1],
                       self.origin[0] + (y - .5) * self.spacing[0])

    def world_to_pixel(self, x, y):
        return (_pixel_coordinate(x, self.origin[1], self.spacing[1]),
                _pixel_coordinate(y, self.origin[0], self.spacing[0]))

    def pixel_delta_to_world(self, dx, dy):
        return _finite(dx * self.spacing[1], dy * self.spacing[0])

    def world_delta_to_pixel(self, dx, dy):
        return _finite(dx / self.spacing[1], dy / self.spacing[0])

    def image_rect(self, shape):
        """Return finite image edge bounds (world x, y, width, height)."""
        _extent(shape, self.spacing, self.origin)
        return (*self.pixel_to_world(0, 0),
                shape[1] * self.spacing[1], shape[0] * self.spacing[0])


def plane_geometry(meta):
    """Return calibrated 2D geometry, or exact pixel identity if absent."""
    return PlaneGeometry(*_axis_values(meta, 2))


def project_metadata(meta, shape, axis, index):
    """Project a 3D member's calibration and selected physical slice to 2D.

    A physical slice is identified by source axis and sample-center position,
    never by its index or volume shape. Legacy uncalibrated slices retain the
    shape/axis/index identity so differing unknown grids cannot accidentally link.
    """
    if (len(shape) != 3 or type(axis) is not int or not 0 <= axis < 3
            or type(index) is not int or not 0 <= index < shape[axis]):
        raise ValueError("invalid volume slice")
    spacing, origin, units, physical = _axis_values(meta, 3)
    _extent(shape, spacing, origin)
    if not physical:
        return dict(meta, _volume_slice=(tuple(shape), axis, index))
    retained = [dimension for dimension in range(3) if dimension != axis]
    position = _finite(origin[axis] + index * spacing[axis])[0]
    return dict(meta, spacing=[spacing[item] for item in retained],
                origin=[origin[item] for item in retained],
                direction=[1.0, 0.0, 0.0, 1.0],
                _volume_slice={"axis": axis, "position": position,
                               "spacing": spacing[axis], "spatial_units": units})


def slice_correspondence(first_meta, second_meta):
    """Compare selected physical planes with only floating-point tolerance."""
    first, second = first_meta.get("_volume_slice"), second_meta.get("_volume_slice")
    if isinstance(first, dict) or isinstance(second, dict):
        if not isinstance(first, dict) or not isinstance(second, dict):
            return False
        try:
            first_position, second_position = first["position"], second["position"]
            step = min(first["spacing"], second["spacing"])
            if not all(math.isfinite(value) for value in
                       (first_position, second_position, step)) or step <= 0:
                return False
            # Relative-to-origin tolerance can merge genuinely different slices
            # after a large physical translation. Admit only arithmetic ULPs,
            # always capped to a tiny fraction of the finer axis sampling.
            tolerance = min(step * 1e-6,
                            max(4 * math.ulp(first_position),
                                4 * math.ulp(second_position), step * 1e-12))
        except (KeyError, TypeError, ValueError, OverflowError):
            return False
        return (first.get("axis") == second.get("axis")
                and first.get("spatial_units") == second.get("spatial_units")
                and math.isclose(first_position, second_position,
                                 rel_tol=0.0, abs_tol=tolerance))
    return first == second


def _slice_frame_correspondence(first_meta, second_meta):
    """Link cameras in the same orientation even at different nearest slices."""
    first, second = first_meta.get("_volume_slice"), second_meta.get("_volume_slice")
    if isinstance(first, dict) or isinstance(second, dict):
        return (isinstance(first, dict) and isinstance(second, dict)
                and first.get("axis") == second.get("axis")
                and first.get("spatial_units") == second.get("spatial_units"))
    return first == second


def physical_frame_correspondence(first_shape, second_shape, first_meta, second_meta):
    """Check physical calibration compatibility independently of sample/grid IDs.

    Shapes, spacing and center origins may differ; both arrays must describe
    axes in the same physical units and orientation. Nearest volume slices
    may differ in position; only numerical differences require coincidence.
    Malformed, uncalibrated, rotated and nonfinite display grids fail closed.
    """
    if len(first_shape) != len(second_shape) or len(first_shape) not in (2, 3):
        return False
    try:
        first = _axis_values(first_meta, len(first_shape))
        second = _axis_values(second_meta, len(second_shape))
        _extent(first_shape, first[0], first[1])
        _extent(second_shape, second[0], second[1])
    except (TypeError, ValueError, OverflowError):
        return False
    return (first[3] and second[3] and first[2] == second[2]
            and _slice_frame_correspondence(first_meta, second_meta))
