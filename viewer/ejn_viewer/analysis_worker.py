"""One active local analysis job and one replaceable pending job for the viewer."""

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
import threading

from PySide6 import QtCore

from .analysis import DIFFERENCE, SCRATCH_BYTES, difference, statistics


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

    @property
    def charge(self):
        # Retained old sources count even after their window advances. Reserve
        # raw difference + its display conversion before allocating either.
        derived = (self.cached_difference.nbytes if self.cached_difference is not None else
                   self.snapshot.planes[self.reference].size * 16
                   if self.reference is not None else 0)
        return self.snapshot.nbytes + derived + SCRATCH_BYTES


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
            results[region.identifier, name] = statistics(arrays[name], region)
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
        self.admit = admit or (lambda extra: self.reserved + extra <= 256 * 1024 * 1024)
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ejn-analysis")
        self.active = self.pending = None
        self.closed = False
        self.completed.connect(self._finished)

    @property
    def reserved(self):
        return ((self.active.charge if self.active is not None else 0)
                + (self._pending_charge(self.pending) if self.pending is not None else 0))

    def _pending_charge(self, job):
        # Pending jobs only retain references, and may share them with the
        # active job. Scratch/output is admitted when computation starts.
        active = self.active
        source = 0 if active is not None and active.snapshot is job.snapshot else job.snapshot.nbytes
        cached = job.cached_difference
        derived = (cached.nbytes if cached is not None and
                   (active is None or active.cached_difference is not cached) else 0)
        return source + derived

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
        charge = job.charge if self.active is None else self._pending_charge(job)
        if not self.admit(charge):
            self.ready.emit(job.owner, job.token, None, "Analysis exceeds the local memory budget.")
            return
        if self.active is None:
            self._start(job)
        else:
            self.pending = job

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
        if self.admit(pending.charge):
            self._start(pending)
        else:
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
