"""One active local analysis job and one replaceable pending job for the viewer."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import threading

from PySide6 import QtCore

from .analysis import (DIFFERENCE, MAX_PROFILE_BYTES, SCRATCH_BYTES,
                       difference, line_profile, statistics)
from .memory import MAX_MEMORY, merge_allocations, source_allocations


@dataclass
class AnalysisJob:
    owner: object
    token: int
    snapshot: object
    regions: tuple
    targets: dict
    reference: str | None = None
    candidate: str | None = None
    absolute: bool = False
    cached_difference: object = None
    cancelled: threading.Event = field(default_factory=threading.Event)


def profile_result_bytes(regions, targets):
    """Maximum retained profile vectors for one job, separate from scratch."""
    return sum(MAX_PROFILE_BYTES * len(targets[region.identifier])
               for region in regions if region.kind == "line")


def compute(job: AnalysisJob):
    derived = job.cached_difference
    if job.cancelled.is_set():
        return None
    if job.reference is not None and derived is None:
        derived = difference(job.snapshot.planes[job.reference],
                             job.snapshot.planes[job.candidate], absolute=job.absolute)
    arrays = dict(job.snapshot.planes)
    if derived is not None:
        arrays[DIFFERENCE] = derived
    results = {}
    for region in job.regions:
        for name in job.targets[region.identifier]:
            if job.cancelled.is_set():
                return None
            operation = line_profile if region.kind == "line" else statistics
            results[region.identifier, name] = operation(arrays[name], region)
    return derived, results


class AnalysisWorker(QtCore.QObject):
    """Shared GUI-owned scheduler; numerical operations run on its one thread.

    ``admit`` includes global source/load/render reservations. A replaced job
    retains its reservation until the worker actually releases its arrays.
    """

    completed = QtCore.Signal(object, object)
    ready = QtCore.Signal(object, int, object, str)

    def __init__(self, parent=None, admit=None):
        super().__init__(parent)
        self.admit = admit or (lambda: self.reserved <= MAX_MEMORY)
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ejn-analysis")
        self.active = self.pending = None
        self.closed = False
        self.completed.connect(self._finished)

    @property
    def reserved(self):
        return sum(self.allocations.values())

    @property
    def allocations(self):
        result = {}
        for job in (self.active, self.pending):
            if job is None:
                continue
            result = merge_allocations(result, source_allocations(job.snapshot))
            if job.cached_difference is not None:
                result["array", id(job.cached_difference)] = job.cached_difference.nbytes
        if self.active is not None:
            job = self.active
            result["scratch", id(job)] = SCRATCH_BYTES
            profile_bytes = profile_result_bytes(job.regions, job.targets)
            if profile_bytes:
                result["new-profiles", id(job)] = profile_bytes
            if job.reference is not None and job.cached_difference is None:
                result["new-difference", id(job)] = job.snapshot.planes[job.reference].size * 16
        return result

    def submit(self, job: AnalysisJob):
        if self.closed:
            return
        if self.pending is not None:
            old, self.pending = self.pending, None
            old.cancelled.set()
            self.ready.emit(old.owner, old.token, None,
                            "Analysis superseded by another request; press Refresh.")
        if self.active is not None and self.active.owner is job.owner:
            self.active.cancelled.set()
        if self.active is None:
            self.active = job
            if self.admit():
                self._start(job)
            else:
                self.active = None
                self.ready.emit(job.owner, job.token, None, "Analysis exceeds the local memory budget.")
        else:
            self.pending = job
            if not self.admit():
                self.pending = None
                self.ready.emit(job.owner, job.token, None, "Analysis exceeds the local memory budget.")

    def _start(self, job):
        self.active = job
        future = self.executor.submit(compute, job)
        def done(result):
            if not self.closed:
                try:
                    self.completed.emit(job, result)
                except RuntimeError:
                    pass
        future.add_done_callback(done)

    @QtCore.Slot(object, object)
    def _finished(self, job, future):
        if self.active is not job:
            return
        self.active = None
        if not self.closed and not job.cancelled.is_set():
            try:
                value = future.result()
                self.ready.emit(job.owner, job.token, value, "")
            except Exception:
                self.ready.emit(job.owner, job.token, None, "Local image analysis failed.")
        # Let this callback/future release the old snapshot and result before
        # another job allocates its scratch and difference arrays.
        if self.pending is not None and not self.closed:
            QtCore.QTimer.singleShot(0, self._start_pending)

    def _start_pending(self):
        if self.pending is None or self.closed or self.active is not None:
            return
        pending, self.pending = self.pending, None
        # Reservations can change while another snapshot is loading.
        self.active = pending
        if self.admit():
            self._start(pending)
        else:
            self.active = None
            self.ready.emit(pending.owner, pending.token, None,
                            "Analysis exceeds the local memory budget.")

    def cancel(self, owner):
        if self.active is not None and self.active.owner is owner:
            self.active.cancelled.set()
        if self.pending is not None and self.pending.owner is owner:
            self.pending.cancelled.set()
            self.pending = None

    def shutdown(self):
        self.closed = True
        for job in (self.active, self.pending):
            if job is not None:
                job.cancelled.set()
        self.pending = None
        self.executor.shutdown(wait=False, cancel_futures=True)
