"""Test-owned local Jupyter kernel fixtures.

``LocalKernelFixture`` is the direct kernelspec process used by normal helper
integration tests.  ``KernelAppFixture`` remains solely for the historical
HT12 proof that the old ``jupyter kernel`` launcher cannot restart a child.
Both own a private process group and never search outside it.
"""

from __future__ import annotations

import json
import math
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from queue import Empty
from pathlib import Path
from typing import Any, Sequence

from direct_kernel_fixture import DirectKernelFixture


class KernelFixtureError(RuntimeError):
    """A fixture could not start or did not expose valid connection data."""


class KernelAppFixture:
    """Context-managed, test-owned local kernel process.

    ``command`` is injectable for deterministic startup failure/timeout tests.
    The default matches the production launch shape using jupyter-client's
    kernel application without requiring a shell.
    """

    _owners: dict[str, "KernelAppFixture"] = {}

    def __init__(
        self,
        *,
        command: Sequence[str] | None = None,
        startup_timeout: float = 15.0,
        poll_interval: float = 0.02,
    ) -> None:
        self._validate_timeout(startup_timeout, "startup_timeout")
        self._validate_timeout(poll_interval, "poll_interval")
        self.session_id = "ejn-test-" + uuid.uuid4().hex
        self.startup_timeout = startup_timeout
        self.poll_interval = poll_interval
        self._command_override = list(command) if command is not None else None
        self._tempdir: tempfile.TemporaryDirectory[str] | None = None
        self._process: subprocess.Popen[bytes] | None = None
        self.connection_path: Path | None = None
        self.cache_dir: Path | None = None
        self.cwd: Path | None = None
        self.connection: dict[str, Any] | None = None
        self.manager_pid: int | None = None
        self.kernel_pid: int | None = None
        self._owned_session = False
        self._owned_session_id = self.session_id
        self._owned_pgid: int | None = None
        self._stdout_log: Path | None = None
        self._stderr_log: Path | None = None

    @staticmethod
    def available() -> bool:
        """Return whether the default local kernel command can be run."""
        try:
            import jupyter_client  # noqa: F401
        except ImportError:
            return False
        return True

    def _command(self) -> list[str]:
        if self._command_override is not None:
            return list(self._command_override)
        assert self.connection_path is not None
        jupyter = shutil.which("jupyter")
        if jupyter:
            return [
                jupyter,
                "kernel",
                f"--KernelManager.connection_file={self.connection_path}",
            ]
        return [
            sys.executable,
            "-m",
            "jupyter_client.kernelapp",
            f"--KernelManager.connection_file={self.connection_path}",
        ]

    def __enter__(self) -> "KernelAppFixture":
        self.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.cleanup()

    def start(self) -> None:
        if self._process is not None:
            return
        self._validate_timeout(self.startup_timeout, "startup_timeout")
        self._validate_timeout(self.poll_interval, "poll_interval")
        self._tempdir = tempfile.TemporaryDirectory(prefix=self.session_id + "-")
        root = Path(self._tempdir.name)
        self.connection_path = root / "connection.json"
        self.cache_dir = root / "cache"
        self.cwd = root / "cwd"
        self._stdout_log = root / "stdout.log"
        self._stderr_log = root / "stderr.log"
        self.cache_dir.mkdir()
        self.cwd.mkdir()
        env = os.environ.copy()
        env["JUPYTER_RUNTIME_DIR"] = str(self.cache_dir)
        try:
            stdout = self._stdout_log.open("wb")
            stderr = self._stderr_log.open("wb")
            self._process = subprocess.Popen(
                self._command(),
                cwd=self.cwd,
                env=env,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
            stdout.close()
            stderr.close()
        except OSError:
            for stream in locals().get("stdout"), locals().get("stderr"):
                if stream is not None and not stream.closed:
                    stream.close()
            self._clear_private_state()
            raise
        self.manager_pid = self._process.pid
        # start_new_session creates a group whose ID is the child PID on the
        # supported POSIX platforms.  Capture it without a fallible /proc API.
        self._owned_pgid = self._process.pid
        KernelAppFixture._owners[self.session_id] = self
        self._owned_session = True
        try:
            self._wait_ready(self.startup_timeout)
        except BaseException:
            self.cleanup()
            raise

    def _wait_ready(self, timeout: float) -> None:
        assert self._process is not None and self.connection_path is not None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                detail = ""
                if self._stderr_log is not None:
                    try:
                        detail = self._stderr_log.read_bytes()[:512].decode("utf-8", "replace")
                    except OSError:
                        pass
                raise KernelFixtureError(f"kernel launcher exited: {detail[:256]}")
            if self.connection_path.is_file():
                try:
                    data = json.loads(self.connection_path.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    data = None
                if isinstance(data, dict):
                    self._validate_connection(data)
                    self.connection = data
                    self.kernel_pid = self._descendant_pid()
                    return
            time.sleep(min(self.poll_interval, max(0.0, deadline - time.monotonic())))
        raise TimeoutError("timed out waiting for kernel connection file")

    @staticmethod
    def _validate_connection(data: dict[str, Any]) -> None:
        host = data.get("ip", data.get("host"))
        if host not in {"127.0.0.1", "localhost", "::1"}:
            raise KernelFixtureError("kernel connection is not loopback-only")

    def _descendant_pid(self) -> int | None:
        """Find a child in our process group, without global process matching."""
        if self._process is None or not Path("/proc").is_dir():
            return None
        try:
            own_pgid = os.getpgid(self._process.pid)
        except OSError:
            return None
        for entry in Path("/proc").iterdir():
            if not entry.name.isdigit():
                continue
            try:
                pid = int(entry.name)
                if pid != self._process.pid and os.getpgid(pid) == own_pgid:
                    return pid
            except (OSError, ValueError):
                continue
        return None

    def _owned(self) -> "KernelAppFixture":
        if (self.session_id != self._owned_session_id
                or KernelAppFixture._owners.get(self.session_id) is not self):
            raise KernelFixtureError("fixture session is not owned by this instance")
        return self

    @staticmethod
    def _group_exists(pgid: int) -> bool:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return False
        return True

    def _wait_group_gone(self, pgid: int, timeout: float) -> bool:
        deadline = time.monotonic() + timeout
        while self._group_exists(pgid) and time.monotonic() < deadline:
            time.sleep(min(self.poll_interval, max(0.001, deadline - time.monotonic())))
        return not self._group_exists(pgid)

    @staticmethod
    def _validate_timeout(value: float, name: str) -> None:
        if not isinstance(value, (int, float)) or isinstance(value, bool) or not math.isfinite(value) or value <= 0:
            raise ValueError(f"{name} must be finite and positive")

    def evaluate(self, expression: str, timeout: float = 10.0) -> dict[str, Any]:
        """Evaluate one expression through a bounded blocking test client."""
        self._owned()
        self._validate_timeout(timeout, "timeout")
        if not self.connection:
            raise KernelFixtureError("kernel is not started")
        try:
            from jupyter_client import BlockingKernelClient
        except ImportError as exc:
            raise KernelFixtureError("jupyter_client is unavailable") from exc
        client = BlockingKernelClient()
        client.load_connection_info(self.connection)
        client.start_channels()
        try:
            client.wait_for_ready(timeout=timeout)
            msg_id = client.execute(expression)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    message = client.get_shell_msg(timeout=max(0.01, deadline - time.monotonic()))
                except Empty as exc:
                    raise TimeoutError("timed out waiting for execute reply") from exc
                if message["msg_type"] == "execute_reply" and message["parent_header"].get("msg_id") == msg_id:
                    return message["content"]
            raise TimeoutError("timed out waiting for execute reply")
        finally:
            client.stop_channels()

    def cleanup(self) -> None:
        """Terminate only this fixture's process group and remove its files.

        Explicit cleanup, context-manager exit, and startup exceptions are
        covered.  No in-process fixture can clean up after its owning test
        process is forcibly killed with SIGKILL.
        """
        if not self._owned_session:
            return
        owner = KernelAppFixture._owners.get(self.session_id)
        if owner is not None and owner is not self:
            raise KernelFixtureError("refusing cleanup of another fixture session")
        if self.session_id != self._owned_session_id:
            raise KernelFixtureError("refusing cleanup after session identity mutation")
        # Retire the ownership record before signaling so reentrant or
        # repeated cleanup cannot ever target a recycled process group.
        KernelAppFixture._owners.pop(self.session_id, None)
        self._owned_session = False
        process = self._process
        pgid = self._owned_pgid
        tempdir = self._tempdir
        group_survived = False
        try:
            if pgid is not None:
                try:
                    os.killpg(pgid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    if process is not None:
                        process.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(pgid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    try:
                        if process is not None:
                            process.wait(timeout=2.0)
                    except subprocess.TimeoutExpired:
                        pass
                if not self._wait_group_gone(pgid, 2.0):
                    try:
                        os.killpg(pgid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    group_survived = not self._wait_group_gone(pgid, 2.0)
            if process is not None:
                try:
                    process.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    pass
        finally:
            self._clear_private_state(tempdir)
        if group_survived:
            raise KernelFixtureError("owned kernel process group did not exit")

    def _clear_private_state(self, tempdir: tempfile.TemporaryDirectory[str] | None = None) -> None:
        """Clear private state and remove its temporary directory."""
        directory = tempdir if tempdir is not None else self._tempdir
        self._process = None
        self._owned_pgid = None
        self.manager_pid = None
        self.kernel_pid = None
        self.connection = None
        self.connection_path = None
        self.cache_dir = None
        self.cwd = None
        self._stdout_log = None
        self._stderr_log = None
        self._tempdir = None
        if directory is not None:
            directory.cleanup()


class _DirectLocalKernelFixture(DirectKernelFixture):
    """Direct fixture with the small legacy test convenience surface."""

    @property
    def manager_pid(self) -> int | None:
        """The direct process is the kernel; there is no launcher parent."""
        return self.kernel_pid

    def evaluate(self, expression: str, timeout: float = 10.0) -> dict[str, Any]:
        self._validate_timeout(timeout, "timeout")
        if self.connection is None:
            raise KernelFixtureError("direct kernel is not started")
        try:
            from jupyter_client import BlockingKernelClient
        except ImportError as exc:
            raise KernelFixtureError("jupyter_client is unavailable") from exc
        client = BlockingKernelClient()
        client.load_connection_info(self.connection)
        client.start_channels()
        try:
            client.wait_for_ready(timeout=timeout)
            message_id = client.execute(expression)
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                try:
                    message = client.get_shell_msg(
                        timeout=max(0.01, deadline - time.monotonic())
                    )
                except Empty as exc:
                    raise TimeoutError("timed out waiting for execute reply") from exc
                if (
                    message.get("msg_type") == "execute_reply"
                    and message.get("parent_header", {}).get("msg_id") == message_id
                ):
                    content = message.get("content")
                    if isinstance(content, dict):
                        return content
                    raise KernelFixtureError("invalid execute reply")
            raise TimeoutError("timed out waiting for execute reply")
        finally:
            client.stop_channels()


class LocalKernelFixture(_DirectLocalKernelFixture):
    """Default reusable fixture: one proven direct kernelspec process."""
