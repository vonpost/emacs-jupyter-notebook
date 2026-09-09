"""Shared allocation identities for source snapshots, displays and local workers."""

from dataclasses import dataclass


MAX_MEMORY = 256 * 1024 * 1024


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
