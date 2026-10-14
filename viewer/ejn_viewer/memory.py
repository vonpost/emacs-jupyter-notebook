"""Shared allocation identities for source snapshots, displays and local workers."""

from dataclasses import dataclass

import numpy as np


MIB = 1024**2
DEFAULT_MEMORY_BUDGET_MIB = 2048
MIN_MEMORY_BUDGET_MIB = 256
MAX_MEMORY_BUDGET_MIB = 1024 * 1024
_memory_budget = DEFAULT_MEMORY_BUDGET_MIB * MIB


def memory_budget():
    """Return the shared application allocation budget in bytes.

    Admission reads this on every check, so one launch-time setting covers
    snapshots, displays, analysis and findings alike.
    """
    return _memory_budget


def set_memory_budget(mib):
    """Install a finite budget of MIB mebibytes, rejecting unsupported values."""
    global _memory_budget
    if (type(mib) is not int
            or not MIN_MEMORY_BUDGET_MIB <= mib <= MAX_MEMORY_BUDGET_MIB):
        raise ValueError(f"memory budget must be {MIN_MEMORY_BUDGET_MIB}-"
                         f"{MAX_MEMORY_BUDGET_MIB} MiB")
    _memory_budget = mib * MIB


def render_bytes(array, *, numerical=True):
    """Reserve the largest selectable face, including conversion and RGBA."""
    shape = sorted(array.shape) if numerical and array.ndim == 3 else array.shape[:2]
    return shape[-2] * shape[-1] * 8


def array_owner(array):
    """Return the ndarray owning ARRAY's memory, so views share one charge."""
    while isinstance(array.base, np.ndarray):
        array = array.base
    return array


def merge_allocations(*groups):
    """Count shared immutable resources once, keeping conservative charges."""
    result = {}
    for group in groups:
        for key, size in group.items():
            result[key] = max(result.get(key, 0), size)
    return result


def source_allocations(snapshot):
    sources = getattr(snapshot, "sources", (snapshot,))
    return {("source", id(source)): source.nbytes for source in sources}


@dataclass(frozen=True)
class AnalysisSource:
    """Cheap immutable references to current and explicitly pinned samples."""

    planes: dict
    sources: tuple

    @property
    def nbytes(self):
        return sum(source_allocations(self).values())
