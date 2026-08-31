"""Test-owned direct kernelspec launcher.

Unlike ``kernel_fixture.py``, this fixture does not launch ``jupyter kernel``
or a KernelManager parent.  It resolves one kernelspec from the structured
``jupyter kernelspec list --json`` response and execs its argv directly.
"""

from __future__ import annotations

import asyncio
import json
import math
import os
import re
import select
import shutil
import signal
import string
import subprocess
import sys
import tempfile
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Mapping


MAX_KERNELSPEC_JSON_BYTES = 65_536
MAX_KERNELSPEC_STDERR_BYTES = 4_096
MAX_KERNELSPEC_ITEMS = 64
MAX_KERNELSPEC_ARGV = 64
MAX_KERNELSPEC_ENV = 64
MAX_KERNELSPEC_TEXT_BYTES = 4_096
MAX_KERNELSPEC_ARGV_BYTES = 16_384
_PORTS = ("shell_port", "iopub_port", "stdin_port", "control_port", "hb_port")
_LOOPBACK = {"127.0.0.1", "localhost", "::1"}
_ENVIRONMENT_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*\Z")
_PLACEHOLDERS = {"{connection_file}", "{resource_dir}"}


class DirectKernelFixtureError(RuntimeError):
    """The test-owned direct kernel could not be resolved or started."""


def close_installed_sync_event_loop() -> None:
    """Close the loop jupyter-core creates for blocking client calls."""
    try:
        loop = asyncio.get_event_loop()
    except RuntimeError:
        return
    if not loop.is_running():
        loop.close()
        asyncio.set_event_loop(None)


@dataclass(frozen=True, slots=True)
class ResolvedKernelSpec:
    """The small, validated subset of one kernelspec needed for exec."""

    argv: tuple[str, ...]
    env: Mapping[str, str]
    resource_dir: str


def _bounded_utf8_size(value: str, ceiling: int) -> int:
    total = 0
    for character in value:
        codepoint = ord(character)
        if 0xD800 <= codepoint <= 0xDFFF:
            return ceiling + 1
        if codepoint <= 0x7F:
            total += 1
        elif codepoint <= 0x7FF:
            total += 2
        elif codepoint <= 0xFFFF:
            total += 3
        else:
            total += 4
        if total > ceiling:
            return total
    return total


def _bounded_text(value: object, field: str) -> str:
    if (
        not isinstance(value, str)
        or "\x00" in value
        or _bounded_utf8_size(value, MAX_KERNELSPEC_TEXT_BYTES)
        > MAX_KERNELSPEC_TEXT_BYTES
    ):
        raise DirectKernelFixtureError(f"invalid kernelspec {field}")
    return value


def _substitute(value: str, replacements: Mapping[str, str], field: str) -> str:
    """Expand only documented placeholders, including embedded argv values."""
    output = []
    offset = 0
    while offset < len(value):
        opening = value.find("{", offset)
        closing = value.find("}", offset)
        if closing >= 0 and (opening < 0 or closing < opening):
            raise DirectKernelFixtureError(
                f"unsupported kernelspec placeholder in {field}"
            )
        if opening < 0:
            output.append(value[offset:])
            break
        end = value.find("}", opening + 1)
        if end < 0:
            raise DirectKernelFixtureError(
                f"unsupported kernelspec placeholder in {field}"
            )
        output.append(value[offset:opening])
        placeholder = value[opening : end + 1]
        if placeholder not in _PLACEHOLDERS:
            raise DirectKernelFixtureError(
                f"unsupported kernelspec placeholder in {field}"
            )
        output.append(replacements[placeholder])
        offset = end + 1
    result = "".join(output)
    return _bounded_text(result, field)


def _rewrite_python_executable(argv: list[str]) -> list[str]:
    """Match KernelManager's portable treatment of bare Python executable names."""
    if re.fullmatch(r"python(?:3(?:\.\d+)?)?", argv[0]):
        return [sys.executable, *argv[1:]]
    return argv


def _substitute_environment(
    value: str, base_environment: Mapping[str, str], field: str
) -> str:
    """Mirror KernelSpec's documented ``$NAME`` environment substitution."""
    try:
        result = string.Template(value).safe_substitute(base_environment)
    except ValueError as exc:
        raise DirectKernelFixtureError(
            f"invalid kernelspec environment template in {field}"
        ) from exc
    return _bounded_text(result, field)


def resolve_kernelspec_document(
    raw: bytes,
    name: str,
    connection_file: str,
    *,
    base_environment: Mapping[str, str] | None = None,
) -> ResolvedKernelSpec:
    """Strictly select and resolve one bounded JSON kernelspec document."""
    if not isinstance(raw, bytes) or len(raw) > MAX_KERNELSPEC_JSON_BYTES:
        raise DirectKernelFixtureError("kernelspec JSON exceeds the limit")
    name = _bounded_text(name, "name")
    connection_file = _bounded_text(connection_file, "connection file")
    if not os.path.isabs(connection_file):
        raise DirectKernelFixtureError("connection file must be absolute")
    if base_environment is None:
        base_environment = os.environ
    if not isinstance(base_environment, Mapping):
        raise DirectKernelFixtureError("kernelspec base environment is invalid")
    try:
        document = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise DirectKernelFixtureError("invalid kernelspec JSON") from exc
    if not isinstance(document, dict) or set(document) != {"kernelspecs"}:
        raise DirectKernelFixtureError("invalid kernelspec document")
    kernelspecs = document["kernelspecs"]
    if (
        not isinstance(kernelspecs, dict)
        or not 0 < len(kernelspecs) <= MAX_KERNELSPEC_ITEMS
    ):
        raise DirectKernelFixtureError("invalid kernelspec collection")
    entry = kernelspecs.get(name)
    if not isinstance(entry, dict) or set(entry) != {"resource_dir", "spec"}:
        raise DirectKernelFixtureError("selected kernelspec is missing or invalid")
    resource_dir = _bounded_text(entry["resource_dir"], "resource directory")
    if not os.path.isabs(resource_dir) or not Path(resource_dir).is_dir():
        raise DirectKernelFixtureError("kernelspec resource directory is invalid")
    spec = entry["spec"]
    if not isinstance(spec, dict):
        raise DirectKernelFixtureError("kernelspec spec is invalid")
    argv = spec.get("argv")
    env = spec.get("env")
    if not isinstance(argv, list) or not 1 <= len(argv) <= MAX_KERNELSPEC_ARGV:
        raise DirectKernelFixtureError("kernelspec argv is invalid")
    if not isinstance(env, dict) or len(env) > MAX_KERNELSPEC_ENV:
        raise DirectKernelFixtureError("kernelspec env is invalid")
    replacements = {
        "{connection_file}": connection_file,
        "{resource_dir}": resource_dir,
    }
    resolved_argv = []
    connection_count = 0
    argv_bytes = 0
    for index, value in enumerate(argv):
        value = _bounded_text(value, f"argv[{index}]")
        connection_count += value.count("{connection_file}")
        value = _substitute(value, replacements, f"argv[{index}]")
        if not value:
            raise DirectKernelFixtureError("kernelspec argv contains an empty value")
        argv_bytes += _bounded_utf8_size(value, MAX_KERNELSPEC_ARGV_BYTES)
        if argv_bytes > MAX_KERNELSPEC_ARGV_BYTES:
            raise DirectKernelFixtureError("kernelspec argv exceeds the limit")
        resolved_argv.append(value)
    if connection_count != 1:
        raise DirectKernelFixtureError("kernelspec requires one connection file placeholder")
    resolved_env = {}
    for key, value in env.items():
        key = _bounded_text(key, "environment name")
        if not _ENVIRONMENT_NAME.fullmatch(key):
            raise DirectKernelFixtureError("kernelspec environment name is invalid")
        value = _bounded_text(value, f"environment {key}")
        resolved_env[key] = _substitute_environment(
            value, base_environment, f"environment {key}"
        )
    resolved_argv = _rewrite_python_executable(resolved_argv)
    if (
        sum(
            _bounded_utf8_size(value, MAX_KERNELSPEC_ARGV_BYTES)
            for value in resolved_argv
        )
        > MAX_KERNELSPEC_ARGV_BYTES
    ):
        raise DirectKernelFixtureError("kernelspec argv exceeds the limit")
    return ResolvedKernelSpec(tuple(resolved_argv), resolved_env, resource_dir)


def _read_kernelspec_output(timeout: float) -> bytes:
    """Run the structured resolver with bounded stdout and stderr capture."""
    jupyter = shutil.which("jupyter")
    if jupyter is None:
        raise DirectKernelFixtureError("jupyter executable is unavailable")
    process = subprocess.Popen(
        [jupyter, "kernelspec", "list", "--json"],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=False,
    )
    assert process.stdout is not None and process.stderr is not None
    stdout = bytearray()
    stderr = bytearray()
    streams = {
        process.stdout.fileno(): (process.stdout, stdout, MAX_KERNELSPEC_JSON_BYTES),
        process.stderr.fileno(): (process.stderr, stderr, MAX_KERNELSPEC_STDERR_BYTES),
    }
    deadline = time.monotonic() + timeout
    try:
        while streams:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("kernelspec resolution timed out")
            ready, _, _ = select.select(list(streams), [], [], remaining)
            if not ready:
                raise TimeoutError("kernelspec resolution timed out")
            for descriptor in ready:
                stream, collected, ceiling = streams[descriptor]
                chunk = os.read(descriptor, min(4096, ceiling + 1 - len(collected)))
                if not chunk:
                    stream.close()
                    streams.pop(descriptor)
                    continue
                collected.extend(chunk)
                if len(collected) > ceiling:
                    raise DirectKernelFixtureError(
                        "kernelspec resolver output exceeds the limit"
                    )
        if process.wait(timeout=max(0.05, deadline - time.monotonic())) != 0:
            raise DirectKernelFixtureError("kernelspec resolver failed")
        return bytes(stdout)
    except BaseException:
        process.kill()
        try:
            process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            pass
        raise
    finally:
        for stream, _collected, _ceiling in streams.values():
            stream.close()


class DirectKernelFixture:
    """A direct, process-group-owned kernelspec process for integration tests."""

    def __init__(
        self,
        *,
        kernelspec: str = "python3",
        startup_timeout: float = 15.0,
        poll_interval: float = 0.02,
    ) -> None:
        self._validate_timeout(startup_timeout, "startup_timeout")
        self._validate_timeout(poll_interval, "poll_interval")
        self.kernelspec = kernelspec
        self.startup_timeout = float(startup_timeout)
        self.poll_interval = float(poll_interval)
        self.session_id = "ejn-direct-" + uuid.uuid4().hex
        self._tempdir: tempfile.TemporaryDirectory[str] | None = None
        self._process: subprocess.Popen[bytes] | None = None
        self._owned_pgid: int | None = None
        self.connection_path: Path | None = None
        self.cwd: Path | None = None
        self.connection: dict[str, Any] | None = None
        self.kernel_pid: int | None = None
        self.resolved: ResolvedKernelSpec | None = None

    @staticmethod
    def available() -> bool:
        try:
            import jupyter_client  # noqa: F401
        except ImportError:
            return False
        return shutil.which("jupyter") is not None

    @staticmethod
    def _validate_timeout(value: float, field: str) -> None:
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(value)
            or value <= 0
        ):
            raise ValueError(f"{field} must be finite and positive")

    def __enter__(self) -> "DirectKernelFixture":
        self.start()
        return self

    def __exit__(self, *_: object) -> None:
        self.cleanup()

    def start(self) -> None:
        if self._process is not None:
            return
        self._tempdir = tempfile.TemporaryDirectory(prefix=self.session_id + "-")
        root = Path(self._tempdir.name)
        self.connection_path = root / "connection.json"
        self.cwd = root / "cwd"
        self.cwd.mkdir()
        try:
            self.resolved = resolve_kernelspec_document(
                _read_kernelspec_output(self.startup_timeout),
                self.kernelspec,
                str(self.connection_path),
                base_environment=os.environ,
            )
            self._launch()
            self._wait_ready(self.startup_timeout)
        except BaseException:
            self.cleanup()
            raise

    def _launch(self) -> None:
        assert self.resolved is not None and self.cwd is not None
        environment = os.environ.copy()
        environment.update(self.resolved.env)
        self._process = subprocess.Popen(
            self.resolved.argv,
            cwd=self.cwd,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            shell=False,
        )
        self.kernel_pid = self._process.pid
        self._owned_pgid = self._process.pid

    @staticmethod
    def _validate_connection(data: object) -> dict[str, Any]:
        if not isinstance(data, dict) or data.get("ip", data.get("host")) not in _LOOPBACK:
            raise DirectKernelFixtureError("kernel connection is not loopback-only")
        if data.get("transport") != "tcp":
            raise DirectKernelFixtureError("kernel connection transport is invalid")
        for port in _PORTS:
            value = data.get(port)
            if type(value) is not int or not 1 <= value <= 65_535:
                raise DirectKernelFixtureError("kernel connection ports are invalid")
        return data

    def _wait_ready(self, timeout: float) -> None:
        assert self._process is not None and self.connection_path is not None
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if self._process.poll() is not None:
                raise DirectKernelFixtureError("direct kernel exited before ready")
            if self.connection_path.is_file():
                try:
                    data = self._validate_connection(
                        json.loads(self.connection_path.read_text("utf-8"))
                    )
                except (OSError, ValueError, DirectKernelFixtureError):
                    data = None
                if data is not None:
                    self.connection = data
                    self._wait_client_ready(max(0.05, deadline - time.monotonic()))
                    return
            time.sleep(min(self.poll_interval, max(0.001, deadline - time.monotonic())))
        raise TimeoutError("timed out waiting for direct kernel readiness")

    def _wait_client_ready(self, timeout: float) -> None:
        assert self.connection is not None
        from jupyter_client import BlockingKernelClient

        client = BlockingKernelClient()
        client.load_connection_info(self.connection)
        client.start_channels()
        try:
            client.wait_for_ready(timeout=timeout)
        finally:
            client.stop_channels()
            close_installed_sync_event_loop()

    def wait_exited(self, timeout: float = 10.0) -> int:
        self._validate_timeout(timeout, "timeout")
        if self._process is None:
            raise DirectKernelFixtureError("direct kernel is not running")
        try:
            return self._process.wait(timeout=timeout)
        except subprocess.TimeoutExpired as exc:
            raise TimeoutError("timed out waiting for direct kernel exit") from exc

    def relaunch(self, connection_data: Mapping[str, object] | None = None) -> None:
        """Start a fresh direct kernel, optionally restoring test-owned metadata."""
        if self._process is None or self.connection_path is None:
            raise DirectKernelFixtureError("direct kernel is not started")
        if self._process.poll() is None:
            raise DirectKernelFixtureError("refusing to relaunch a live kernel")
        previous_group = self._owned_pgid
        if previous_group is not None and self._group_exists(previous_group):
            self._terminate_group(previous_group, self._process)
            if self._group_exists(previous_group):
                raise DirectKernelFixtureError("previous direct kernel group survived")
        if connection_data is not None:
            restored = self._validate_connection(dict(connection_data))
            descriptor = os.open(
                self.connection_path,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            try:
                os.fchmod(descriptor, 0o600)
                with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                    descriptor = -1
                    json.dump(restored, stream, sort_keys=True)
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
        self._process = None
        self.kernel_pid = None
        self._owned_pgid = None
        self._launch()
        self._wait_ready(self.startup_timeout)

    @staticmethod
    def _group_exists(pgid: int) -> bool:
        try:
            os.killpg(pgid, 0)
        except ProcessLookupError:
            return False
        return True

    @staticmethod
    def _terminate_group(pgid: int, process: subprocess.Popen[bytes] | None) -> None:
        """Bounded cleanup for this fixture's process group only."""
        try:
            os.killpg(pgid, signal.SIGTERM)
        except ProcessLookupError:
            return
        if process is not None:
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                pass
        deadline = time.monotonic() + 2
        while DirectKernelFixture._group_exists(pgid) and time.monotonic() < deadline:
            time.sleep(0.02)
        if DirectKernelFixture._group_exists(pgid):
            try:
                os.killpg(pgid, signal.SIGKILL)
            except ProcessLookupError:
                return
            deadline = time.monotonic() + 2
            while DirectKernelFixture._group_exists(pgid) and time.monotonic() < deadline:
                time.sleep(0.02)

    def cleanup(self) -> None:
        process, pgid, directory = self._process, self._owned_pgid, self._tempdir
        self._process = None
        self._owned_pgid = None
        self.kernel_pid = None
        self.connection = None
        self.connection_path = None
        self.cwd = None
        self.resolved = None
        self._tempdir = None
        try:
            if pgid is not None:
                self._terminate_group(pgid, process)
        finally:
            if directory is not None:
                directory.cleanup()
