"""Bounded local stdio control for the experimental numerical viewer."""

from __future__ import annotations

from collections import deque
from concurrent.futures import ThreadPoolExecutor
import json
import os
import struct
import sys

from PySide6 import QtCore, QtWidgets

from .snapshots import load_snapshot
from .workspace import WorkspaceWindow
from .analysis_worker import AnalysisWorker

MAX_FRAME = 65536
MAX_MEMORY = 256 * 1024 * 1024
MAX_WORKSPACES = 4


def encode(value):
    payload = json.dumps(value, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(payload) + 4 > MAX_FRAME:
        raise ValueError("reply too large")
    return struct.pack(">I", len(payload)) + payload


def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key")
        result[key] = value
    return result


class Decoder:
    def __init__(self):
        self.buffer = bytearray()

    def feed(self, data):
        if len(self.buffer) + len(data) > MAX_FRAME * 2:
            raise ValueError("input backlog exceeded")
        self.buffer.extend(data)

    def pop(self):
        if len(self.buffer) < 4:
            return None
        length = struct.unpack(">I", self.buffer[:4])[0]
        if not 1 <= length <= MAX_FRAME - 4:
            raise ValueError("invalid frame size")
        if len(self.buffer) < length + 4:
            return None
        payload = bytes(self.buffer[4:length + 4])
        del self.buffer[:length + 4]
        return json.loads(payload.decode("utf-8"), object_pairs_hook=_unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError("nonfinite JSON")))


def snapshot_charge(snapshot):
    # Source bytes plus conservative full-resolution render/intermediate RGBA
    # buffers. This is an application allocation budget, not total Qt RSS.
    return snapshot.nbytes + sum(array.shape[0] * array.shape[1] * 8
                                 for array in snapshot.planes.values())


class PipeServer(QtCore.QObject):
    completed = QtCore.Signal(object, object)

    def __init__(self, app, input_fd=0, output_fd=1):
        super().__init__()
        self.app = app
        self.input_fd, self.output_fd = input_fd, output_fd
        os.set_blocking(input_fd, False)
        os.set_blocking(output_fd, False)
        self.decoder = Decoder()
        self.output = bytearray()
        self.windows = {}
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="ejn-snapshot")
        self.active = None
        self.pending = None
        self.analysis = AnalysisWorker(self, admit=lambda extra: self.memory_used() + extra <= MAX_MEMORY)
        self.finished = deque(maxlen=128)
        self.negotiated = False
        self.closed = False
        self.parse_scheduled = False
        self.reader = QtCore.QSocketNotifier(input_fd, QtCore.QSocketNotifier.Type.Read, self)
        self.writer = QtCore.QSocketNotifier(output_fd, QtCore.QSocketNotifier.Type.Write, self)
        self.writer.setEnabled(False)
        self.reader.activated.connect(self.read)
        self.writer.activated.connect(self.flush)
        self.completed.connect(self.loaded)
        self.partial_timer = QtCore.QTimer(self)
        self.partial_timer.setSingleShot(True)
        self.partial_timer.timeout.connect(self.stop)

    def reply(self, request_id, result=None, error=None):
        if self.closed:
            return
        value = {"v": 1, "id": request_id, "ok": error is None}
        if error is None:
            value["result"] = result or {}
        else:
            value["error"] = {"code": error, "message": error}
        frame = encode(value)
        if len(self.output) + len(frame) > MAX_FRAME:
            self.stop()
            return
        self.output.extend(frame)
        self.writer.setEnabled(True)
        self.flush()

    def flush(self, *_):
        if self.closed:
            return
        try:
            if self.output:
                count = os.write(self.output_fd, self.output[:MAX_FRAME])
                del self.output[:count]
            self.writer.setEnabled(bool(self.output))
        except BlockingIOError:
            pass
        except OSError:
            self.stop()

    def read(self, *_):
        try:
            data = os.read(self.input_fd, MAX_FRAME)
            if not data:
                self.stop()
                return
            self.decoder.feed(data)
            if not self.parse_scheduled:
                self.parse()
        except BlockingIOError:
            pass
        except (OSError, ValueError, RecursionError):
            self.stop()

    def parse(self):
        self.parse_scheduled = False
        if self.closed:
            return
        try:
            for _ in range(4):
                request = self.decoder.pop()
                if request is None:
                    if self.decoder.buffer and not self.partial_timer.isActive():
                        self.partial_timer.start(5000)
                    elif not self.decoder.buffer:
                        self.partial_timer.stop()
                    return
                self.partial_timer.stop()
                self.dispatch(request)
                if self.closed:
                    return
            if self.decoder.buffer and not self.parse_scheduled:
                self.parse_scheduled = True
                QtCore.QTimer.singleShot(0, self.parse)
        except (ValueError, TypeError, KeyError, RecursionError):
            self.stop()

    def dispatch(self, request):
        if not isinstance(request, dict) or type(request.get("v")) is not int or request["v"] != 1:
            raise ValueError("invalid request")
        request_id = request.get("id")
        if not isinstance(request_id, str) or not 1 <= len(request_id) <= 128 or not request_id.isascii():
            raise ValueError("invalid request id")
        op, params = request.get("op"), request.get("params", {})
        if not isinstance(op, str) or not isinstance(params, dict):
            raise ValueError("invalid operation")
        if op == "hello":
            self.negotiated = True
            self.reply(request_id, {"version": 1, "capabilities": ["array-group-v1", "raster-v1"]})
        elif not self.negotiated:
            self.reply(request_id, error="hello-required")
        elif op == "ping":
            self.reply(request_id, {"alive": True})
        elif op == "open":
            if any(job and job["id"] == request_id for job in (self.active, self.pending)):
                self.reply(request_id, error="duplicate-request")
                return
            workspace = params.get("workspace")
            size = params.get("artifact", {}).get("size") if isinstance(params.get("artifact"), dict) else None
            if (not isinstance(workspace, str) or not 1 <= len(workspace) <= 512
                    or type(size) is not int or not 1 <= size <= 67108864):
                self.reply(request_id, error="invalid-open")
                return
            job = {"id": request_id, "params": params, "cancelled": False}
            if self.active:
                if self.active["params"]["workspace"] == workspace and not self.active["cancelled"]:
                    self.active["cancelled"] = True
                    self.reply(self.active["id"], error="superseded")
                if self.pending:
                    self.reply(self.pending["id"], error="superseded")
                self.pending = job
            else:
                self.start(job)
        elif op == "cancel":
            target = params.get("id")
            found = False
            for job in (self.active, self.pending):
                if job and job["id"] == target and not job["cancelled"]:
                    job["cancelled"] = True
                    self.reply(target, error="cancelled")
                    found = True
            if self.pending and self.pending["cancelled"]:
                self.pending = None
            self.reply(request_id, {"cancelled": found, "completed": target in self.finished})
        elif op in {"focus", "close_workspace"}:
            window = self.windows.get(params.get("workspace"))
            if window:
                if op == "focus":
                    window.show()
                    window.raise_()
                    window.activateWindow()
                else:
                    window.close()
            self.reply(request_id, {"found": window is not None})
        elif op == "close":
            self.stop()
        else:
            self.reply(request_id, error="unsupported-operation")

    def start(self, job):
        params = job["params"]
        workspace = params["workspace"]
        retained = self.memory_used()
        # Two source buffers may overlap at chunk-join time. Raster decoding
        # additionally reserves three worst-case RGBA planes before allocation.
        reserve = 2 * params["artifact"]["size"]
        if params.get("kind") == "raster":
            reserve += 3 * 16777216 * 4
        if (workspace not in self.windows and len(self.windows) >= MAX_WORKSPACES
                or retained + reserve > MAX_MEMORY):
            self.reply(job["id"], error="viewer-budget-exceeded")
            return
        self.active = job
        job["reserve"] = reserve
        future = self.executor.submit(load_snapshot, params)
        def finished(completed):
            if not self.closed:
                try:
                    self.completed.emit(job, completed)
                except RuntimeError:
                    pass  # QObject was retired with the local process epoch.
        future.add_done_callback(finished)

    @QtCore.Slot(object, object)
    def loaded(self, job, future):
        window = None
        try:
            if self.closed or job["cancelled"] or self.active is not job:
                return
            snapshot = future.result()
            # Loading allocations are now owned by SNAPSHOT. Replacing this
            # reservation with its actual charge still includes analysis jobs
            # retaining an older publication and displayed difference buffers.
            job["reserve"] = 0
            retained = self.memory_used()
            if retained + snapshot_charge(snapshot) > MAX_MEMORY:
                self.reply(job["id"], error="viewer-budget-exceeded")
                return
            window = self.windows.get(snapshot.workspace)
            if window and window._snapshot.generation > snapshot.generation:
                self.reply(job["id"], error="stale-generation")
                return
            if window is None:
                window = WorkspaceWindow(analysis_worker=self.analysis)
                window.setAttribute(QtCore.Qt.WidgetAttribute.WA_DeleteOnClose)
                window.closed.connect(lambda key=snapshot.workspace: self.workspace_closed(key))
                self.windows[snapshot.workspace] = window
            window.install_snapshot(snapshot)
            window.show()
            if snapshot.focus:
                window.raise_()
                window.activateWindow()
            self.finished.append(job["id"])
            self.reply(job["id"], {"state": "visible"})
        except Exception:
            if window is not None:
                job["cancelled"] = True
                window.close()
            self.reply(job["id"], error="snapshot-load-failed")
        finally:
            if self.active is job:
                self.active = None
            if not self.closed and self.pending:
                pending, self.pending = self.pending, None
                self.start(pending)

    def memory_used(self):
        """Conservative application allocations, including worker references."""
        return (sum(snapshot_charge(window._snapshot) + window.analysis_bytes
                    for window in self.windows.values() if window._snapshot is not None)
                + self.analysis.reserved
                + (self.active.get("reserve", 0) if self.active is not None else 0))

    def workspace_closed(self, key):
        self.windows.pop(key, None)
        for job in (self.active, self.pending):
            if job and job["params"]["workspace"] == key and not job["cancelled"]:
                job["cancelled"] = True
                self.reply(job["id"], error="workspace-closed")
        if self.pending and self.pending["cancelled"]:
            self.pending = None

    def stop(self, *_):
        if self.closed:
            return
        self.closed = True
        self.reader.setEnabled(False)
        self.writer.setEnabled(False)
        self.partial_timer.stop()
        for job in (self.active, self.pending):
            if job:
                job["cancelled"] = True
        self.pending = None
        for window in list(self.windows.values()):
            window.close()
        self.analysis.shutdown()
        self.executor.shutdown(wait=False, cancel_futures=True)
        self.app.quit()


def run():
    app = QtWidgets.QApplication(sys.argv)
    app.setQuitOnLastWindowClosed(False)
    server = PipeServer(app)
    app.aboutToQuit.connect(server.stop)
    return app.exec()
