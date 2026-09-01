"""End-to-end v1 helper protocol contract against one test-owned kernel.

This deliberately talks to ``python -m ejn_helper --protocol`` over framed
stdio.  It is not a white-box ``JupyterBackend`` test: the dispatcher, event
credit queue, runtime writer, and local process lifecycle are all live.
"""

from __future__ import annotations

import hashlib
import os
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable

from ejn_helper.flow import EJN_MAX_TO_EMACS_FRAME
from ejn_helper.framing import Decoder, encode
from kernel_fixture import LocalKernelFixture


ROOT = Path(__file__).resolve().parents[2]
HELPER_ROOT = ROOT / "helper"
EVENT_CREDIT = 262_144
REQUEST_TIMEOUT = 12.0
EJN_MAX_TO_HELPER_FRAME = 1_048_576
MAX_HELPER_STDERR_BYTES = 4_096
WHOLE_TEST_TIMEOUT = 100
PNG_BASE64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVQIHWP4z8DwHwAFgAI/"
    "ScL4iQAAAABJRU5ErkJggg=="
)


class ProtocolPeer:
    """One bounded framed client for the test-owned helper subprocess."""

    def __init__(self) -> None:
        environment = os.environ.copy()
        existing = environment.get("PYTHONPATH")
        environment["PYTHONPATH"] = (
            str(HELPER_ROOT)
            if not existing
            else str(HELPER_ROOT) + os.pathsep + existing
        )
        # A pipe without a concurrent reader can backpressure the helper and
        # turn a diagnostic flood into a false test hang.  The bounded read at
        # disposal preserves evidence without making stderr a live dependency.
        self._stderr = tempfile.TemporaryFile(mode="w+b")
        self._close_result: tuple[int | None, bytes] | None = None
        self._close_error: BaseException | None = None
        self.process = subprocess.Popen(
            [sys.executable, "-m", "ejn_helper", "--protocol"],
            cwd=HELPER_ROOT,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._stderr,
            start_new_session=True,
        )
        assert self.process.stdin is not None and self.process.stdout is not None
        self._decoder = Decoder(EJN_MAX_TO_EMACS_FRAME)
        self._ready: list[dict[str, Any]] = []
        self.responses: dict[str, dict[str, Any]] = {}
        self.events: list[dict[str, Any]] = []
        self._next_id = 0

    def close_process(self) -> tuple[int | None, bytes]:
        """Boundedly end the local helper process and return its stderr."""
        if self._close_error is not None:
            raise self._close_error
        if self._close_result is not None:
            return self._close_result
        process = self.process
        failure: BaseException | None = None
        try:
            if process.stdin is not None and not process.stdin.closed:
                process.stdin.close()
            process.wait(timeout=3)
        except BaseException as exc:
            failure = exc
        finally:
            try:
                self._terminate_exact_process_group()
            except BaseException as exc:
                if failure is None:
                    failure = exc
            self._stderr.seek(0)
            stderr = self._stderr.read(MAX_HELPER_STDERR_BYTES + 1)
            self._stderr.close()
            for stream in (process.stdin, process.stdout):
                if stream is not None and not stream.closed:
                    stream.close()
        self._close_result = (process.returncode, stderr[:MAX_HELPER_STDERR_BYTES])
        if failure is not None:
            self._close_error = failure
            raise failure
        if len(stderr) > MAX_HELPER_STDERR_BYTES:
            self._close_error = AssertionError("helper stderr exceeded 4096 bytes")
            raise self._close_error
        return self._close_result

    @staticmethod
    def _group_exists(pgid: int) -> bool:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return False
        return True

    def _terminate_exact_process_group(self) -> None:
        """Reap this peer's session group, including an orphaned child."""
        process = self.process
        pgid = process.pid
        if self._group_exists(pgid):
            os.killpg(pgid, signal.SIGTERM)
            deadline = time.monotonic() + 2
            while self._group_exists(pgid) and time.monotonic() < deadline:
                time.sleep(0.02)
        if self._group_exists(pgid):
            os.killpg(pgid, signal.SIGKILL)
            deadline = time.monotonic() + 2
            while self._group_exists(pgid) and time.monotonic() < deadline:
                time.sleep(0.02)
        if self._group_exists(pgid):
            raise AssertionError("test-owned helper process group survived cleanup")
        if process.poll() is None:
            process.wait(timeout=2)

    def send_async(self, operation: str, params: dict[str, Any]) -> str:
        self._next_id += 1
        request_id = f"ag1-{self._next_id:04d}"
        frame = encode(
            {
                "v": 1,
                "kind": "request",
                "id": request_id,
                "op": operation,
                "params": params,
            },
            EJN_MAX_TO_HELPER_FRAME,
        )
        try:
            assert self.process.stdin is not None
            self.process.stdin.write(frame)
            self.process.stdin.flush()
        except (BrokenPipeError, OSError) as exc:
            raise AssertionError("helper closed its stdin unexpectedly") from exc
        return request_id

    def request(self, operation: str, params: dict[str, Any]) -> dict[str, Any]:
        return self.await_response(self.send_async(operation, params))

    def await_response(self, request_id: str, timeout: float = REQUEST_TIMEOUT) -> dict[str, Any]:
        return self._read_until(
            lambda: self.responses.get(request_id), timeout, f"response {request_id}"
        )

    def await_event(
        self, predicate: Callable[[dict[str, Any]], bool], label: str, timeout: float = REQUEST_TIMEOUT
    ) -> dict[str, Any]:
        return self._read_until(
            lambda: next((event for event in self.events if predicate(event)), None),
            timeout,
            label,
        )

    def _read_until(self, lookup: Callable[[], dict[str, Any] | None], timeout: float, label: str) -> dict[str, Any]:
        deadline = time.monotonic() + timeout
        while True:
            found = lookup()
            if found is not None:
                return found
            if time.monotonic() >= deadline:
                raise AssertionError(f"timed out waiting for {label}")
            self._read_one(deadline)

    def _read_one(self, deadline: float) -> None:
        if self._ready:
            self._accept(self._ready.pop(0))
            return
        assert self.process.stdout is not None
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError("helper frame deadline expired")
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            if not selector.select(remaining):
                raise AssertionError("helper frame deadline expired")
        chunk = os.read(self.process.stdout.fileno(), 65_536)
        if not chunk:
            code, stderr = self.close_process()
            raise AssertionError(
                f"helper exited before required frame (status={code}, stderr={stderr[:512]!r})"
            )
        self._ready.extend(self._decoder.feed(chunk))
        if self._ready:
            self._accept(self._ready.pop(0))

    def _accept(self, envelope: dict[str, Any]) -> None:
        if envelope.get("kind") == "response":
            request_id = envelope.get("id")
            if not isinstance(request_id, str) or request_id in self.responses:
                raise AssertionError("invalid or duplicate helper response id")
            self.responses[request_id] = envelope
            return
        if envelope.get("kind") == "event":
            sequence = envelope.get("seq")
            if not isinstance(sequence, int):
                raise AssertionError("helper event lacks a numeric sequence")
            if self.events and sequence <= self.events[-1]["seq"]:
                raise AssertionError("helper event sequence is not strictly monotonic")
            self.events.append(envelope)
            return
        raise AssertionError("helper emitted an unsupported envelope kind")


def _success(response: dict[str, Any]) -> dict[str, Any]:
    if response.get("ok") is not True or not isinstance(response.get("result"), dict):
        raise AssertionError(f"unexpected helper failure: {response!r}")
    return response["result"]


def _error(response: dict[str, Any], code: str) -> None:
    if response.get("ok") is not False or response.get("error", {}).get("code") != code:
        raise AssertionError(f"expected {code} helper error: {response!r}")


class HelperProtocolContractTests(unittest.TestCase):
    """The AG1 contract is intentionally one serial kernel/helper lifecycle."""

    @classmethod
    def setUpClass(cls) -> None:
        # A gate cannot turn unavailable local dependencies into a green skip.
        if not LocalKernelFixture.available():
            raise RuntimeError(
                "AG1 requires jupyter_client and the jupyter executable in the active Python environment"
            )
        try:
            import PIL  # noqa: F401
        except ImportError as exc:
            raise RuntimeError("AG1 requires Pillow for image artifact validation") from exc

    @contextmanager
    def _whole_test_deadline(self):
        """Leave bounded cleanup time before the runner's hard 120-second kill."""
        if not hasattr(signal, "SIGALRM"):
            yield
            return
        previous_handler = signal.getsignal(signal.SIGALRM)
        previous_alarm = signal.alarm(0)

        def expired(_signum, _frame) -> None:
            raise TimeoutError("AG1 whole-test deadline expired")

        signal.signal(signal.SIGALRM, expired)
        signal.alarm(WHOLE_TEST_TIMEOUT)
        try:
            yield
        finally:
            signal.alarm(0)
            signal.signal(signal.SIGALRM, previous_handler)
            if previous_alarm:
                signal.alarm(previous_alarm)

    def _start_peer(self, fixture: LocalKernelFixture, artifacts: Path) -> ProtocolPeer:
        assert fixture.connection_path is not None
        peer = ProtocolPeer()
        hello = _success(peer.request("hello", {"versions": [1]}))
        self.assertEqual(hello["version"], 1)
        self.assertIn("event-credit", hello["capabilities"])
        self.assertEqual(_success(peer.request("grant_event_credit", {"bytes": EVENT_CREDIT}))["credit"], EVENT_CREDIT)
        self.assertEqual(
            _success(
                peer.request(
                    "connect",
                    {
                        "connection_file": str(fixture.connection_path),
                        "artifact_dir": str(artifacts),
                        "image_max_pixels": 4_194_304,
                    },
                )
            ),
            {"attached": True},
        )
        return peer

    def _close_local_only(self, peer: ProtocolPeer) -> None:
        self.assertEqual(_success(peer.request("close", {})), {"closed": True})
        code, stderr = peer.close_process()
        self.assertEqual(code, 0, stderr.decode("utf-8", "replace"))
        self.assertEqual(stderr, b"")

    def _assert_execution_terminal(self, peer: ProtocolPeer, request_id: str, expected: str) -> None:
        response = peer.await_response(request_id)
        result = _success(response)
        self.assertEqual(result.get("status"), expected)
        peer.await_event(
            lambda event: event.get("request_id") == request_id and event.get("event") == "execute_reply",
            f"execute reply for {request_id}",
        )
        status = peer.await_event(
            lambda event: event.get("request_id") == request_id and event.get("event") == "status",
            f"terminal status for {request_id}",
        )
        self.assertEqual(status["data"].get("execution_state"), "idle")
        events = [event for event in peer.events if event.get("request_id") == request_id]
        names = [event["event"] for event in events]
        self.assertEqual(names.count("execute_reply"), 1)
        self.assertEqual(names.count("status"), 1)
        # Shell execute_reply can arrive before later normalized IOPub output.
        # IOPub idle/status is the event that closes ordinary output, so it
        # must follow every ordinary event and nothing ordinary may follow it.
        status_index = names.index("status")
        self.assertTrue(
            all(name in {"execute_reply", "status"} for name in names[status_index:])
        )

    def _assert_artifact(self, artifact_root: Path, descriptor: dict[str, Any]) -> list[Path]:
        paths: list[Path] = []
        for key in ("original", "preview"):
            data = descriptor.get(key)
            if data is None:
                continue
            self.assertIsInstance(data, dict)
            path = Path(data["path"])
            self.assertEqual(path.parent, artifact_root)
            self.assertTrue(path.is_absolute())
            metadata = path.stat(follow_symlinks=False)
            self.assertTrue(stat.S_ISREG(metadata.st_mode))
            self.assertFalse(path.is_symlink())
            self.assertEqual(stat.S_IMODE(metadata.st_mode), 0o600)
            self.assertEqual(metadata.st_uid, os.getuid())
            self.assertEqual(metadata.st_nlink, 1)
            self.assertEqual(metadata.st_size, data["bytes"])
            self.assertLessEqual(data["bytes"], 67_108_864)
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), data["sha256"])
            paths.append(path)
        self.assertIn("original", descriptor)
        if "preview" in descriptor:
            self.assertEqual(descriptor["preview"].get("mime"), "image/x-portable-pixmap")
            self.assertLessEqual(descriptor["preview"]["bytes"], 4_194_304)
        return paths

    def _wait_for_marker(self, path: Path, timeout: float = REQUEST_TIMEOUT) -> None:
        """Wait only a finite interval for test-owned kernel progress."""
        deadline = time.monotonic() + timeout
        while not path.is_file():
            if time.monotonic() >= deadline:
                self.fail(f"timed out waiting for kernel marker {path.name}")
            time.sleep(0.02)
        self.assertEqual(path.read_text(encoding="utf-8"), "ready")

    def test_direct_protocol_contract(self) -> None:
        with self._whole_test_deadline(), LocalKernelFixture(
            startup_timeout=15
        ) as fixture, tempfile.TemporaryDirectory(prefix="ejn-ag1-") as temporary:
            root = Path(temporary)
            artifacts = root / "artifacts"
            artifacts.mkdir(mode=0o700)
            self.assertEqual(stat.S_IMODE(artifacts.stat().st_mode), 0o700)
            initial_connection = dict(fixture.connection or {})
            initial_pid = fixture.kernel_pid
            peer: ProtocolPeer | None = None
            restarted: ProtocolPeer | None = None
            try:
                peer = self._start_peer(fixture, artifacts)
                info = _success(peer.request("kernel_info", {}))
                self.assertEqual(info["language_info"]["name"], "python")
                _error(peer.request("restart", {}), "unsupported")

                rich = peer.send_async(
                    "execute",
                    {
                        "code": (
                            "from IPython.display import Image, clear_output, display\n"
                            "import base64\n"
                            "display({'phase': 'first'}, display_id='ejn-contract-display')\n"
                            "display({'phase': 'second'}, display_id='ejn-contract-display', update=True)\n"
                            "clear_output(wait=True)\n"
                            "print('ejn-after-clear')\n"
                            f"display(Image(data=base64.b64decode('{PNG_BASE64}'), format='png'))\n"
                            "42"
                        )
                    },
                )
                self._assert_execution_terminal(peer, rich, "ok")
                rich_events = [event for event in peer.events if event.get("request_id") == rich]
                names = [event["event"] for event in rich_events]
                first_display = names.index("display_data")
                update = next(index for index, event in enumerate(rich_events) if event["data"].get("update") is True)
                clear = names.index("clear_output")
                stream = next(index for index, event in enumerate(rich_events) if event["event"] == "stream" and "ejn-after-clear" in event["data"].get("text", ""))
                self.assertLess(first_display, update)
                self.assertLess(update, clear)
                self.assertLess(clear, stream)
                self.assertEqual(rich_events[update]["data"]["transient"]["display_id"], "ejn-contract-display")
                image_event = next(
                    event
                    for event in rich_events
                    if event["event"] == "display_data" and "image/png" in event["data"].get("data", {})
                )
                self.assertNotIn(PNG_BASE64, repr(image_event))
                artifact_paths = self._assert_artifact(artifacts, image_event["data"]["data"]["image/png"])

                failed = peer.send_async("execute", {"code": "raise RuntimeError('ejn-contract-error')"})
                self._assert_execution_terminal(peer, failed, "error")
                failure_events = [event for event in peer.events if event.get("request_id") == failed]
                self.assertTrue(any("ejn-contract-error" in event["data"].get("text", "") for event in failure_events if event["event"] == "stream"))

                busy = peer.send_async("execute", {"code": "import time; time.sleep(0.2); contract_busy = 1"})
                self.assertEqual(_success(peer.request("complete", {"code": "pri", "cursor_pos": 3}))["matches"].count("print"), 1)
                self.assertTrue(_success(peer.request("inspect", {"code": "print", "cursor_pos": 5}))["found"])
                self.assertEqual(_success(peer.request("is_complete", {"code": "x = 1"}))["status"], "complete")
                self._assert_execution_terminal(peer, busy, "ok")

                stdin_execution = peer.send_async("execute", {"code": "value = input('AG1: '); print(value)"})
                prompt = peer.await_event(
                    lambda event: event.get("request_id") == stdin_execution and event.get("event") == "input_request",
                    "stdin prompt",
                )
                self.assertEqual(prompt["data"]["password"], False)
                self.assertEqual(
                    _success(
                        peer.request(
                            "input_reply",
                            {"request_id": stdin_execution, "input_id": prompt["data"]["input_id"], "value": "Ada"},
                        )
                    ),
                    {"accepted": True},
                )
                self._assert_execution_terminal(peer, stdin_execution, "ok")
                self.assertTrue(
                    any(
                        event["event"] == "stream"
                        and "Ada" in event["data"].get("text", "")
                        for event in peer.events
                        if event.get("request_id") == stdin_execution
                    )
                )

                marker = root / "interrupt-started"
                interrupted = peer.send_async(
                    "execute",
                    {
                        "code": (
                            "from pathlib import Path\nimport time\n"
                            f"Path({str(marker)!r}).write_text('ready')\n"
                            "time.sleep(30)"
                        )
                    },
                )
                self._wait_for_marker(marker)
                self.assertEqual(_success(peer.request("interrupt", {})), {"interrupted": True})
                self._assert_execution_terminal(peer, interrupted, "error")
                followup = peer.send_async("execute", {"code": "contract_survives_close = 719"})
                self._assert_execution_terminal(peer, followup, "ok")

                self._close_local_only(peer)
                peer = None
                self.assertEqual(fixture.kernel_pid, initial_pid)
                self.assertEqual(fixture.evaluate("assert contract_survives_close == 719").get("status"), "ok")
                # A successful helper close transfers artifacts to its consumer;
                # emulate test-owned panel retirement only after identity checks.
                for path in artifact_paths:
                    path.unlink()
                self.assertEqual(list(artifacts.iterdir()), [])

                reconnected_artifacts = root / "reconnected-artifacts"
                reconnected_artifacts.mkdir(mode=0o700)
                peer = self._start_peer(fixture, reconnected_artifacts)
                reconnect = peer.send_async("execute", {"code": "assert contract_survives_close == 719"})
                self._assert_execution_terminal(peer, reconnect, "ok")

                self.assertEqual(_success(peer.request("shutdown", {})), {"shutdown": True})
                self.assertEqual(fixture.wait_exited(10), 0)
                self._close_local_only(peer)
                peer = None
                fixture.relaunch(connection_data=initial_connection)
                self.assertNotEqual(fixture.kernel_pid, initial_pid)
                self.assertEqual(fixture.connection, initial_connection)

                restart_artifacts = root / "restart-artifacts"
                restart_artifacts.mkdir(mode=0o700)
                restarted = self._start_peer(fixture, restart_artifacts)
                reset = restarted.send_async("execute", {"code": "contract_survives_close"})
                self._assert_execution_terminal(restarted, reset, "error")
                fresh = restarted.send_async("execute", {"code": "contract_after_restart = 42"})
                self._assert_execution_terminal(restarted, fresh, "ok")
                self.assertEqual(_success(restarted.request("shutdown", {})), {"shutdown": True})
                self.assertEqual(fixture.wait_exited(10), 0)
                self._close_local_only(restarted)
                restarted = None
            finally:
                if peer is not None:
                    peer.close_process()
                if restarted is not None:
                    restarted.close_process()


if __name__ == "__main__":
    unittest.main()
