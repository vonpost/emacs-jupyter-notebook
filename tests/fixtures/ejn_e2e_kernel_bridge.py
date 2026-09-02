#!/usr/bin/env python3
"""Private control bridge for the Emacs/helper E2E test gate.

The bridge, rather than Emacs, owns the test kernel.  That ownership lets the
parent runner clean an exact process group even when an Emacs batch test times
out.  The filesystem protocol is deliberately tiny and private to a 0700
temporary directory supplied by the runner.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sys
import tempfile
import time
from pathlib import Path


def _repository_root() -> Path:
    return Path(__file__).resolve().parents[2]


sys.path.insert(0, str(_repository_root() / "helper" / "integration_tests"))
from direct_kernel_fixture import _read_kernelspec_output, resolve_kernelspec_document  # noqa: E402
from kernel_fixture import LocalKernelFixture  # noqa: E402


def _write_json(path: Path, value: object) -> None:
    temporary = path.with_name(path.name + ".tmp")
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            descriptor = -1
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _state(
    fixture: LocalKernelFixture, owner_token: str, kernel_pgids: list[int]
) -> dict[str, object]:
    if fixture.connection_path is None or fixture.kernel_pid is None:
        raise RuntimeError("fixture has not launched")
    return {
        "owner_token": owner_token,
        "bridge_pid": os.getpid(),
        "bridge_pgid": os.getpgrp(),
        "connection_file": str(fixture.connection_path),
        "kernel_pid": fixture.kernel_pid,
        "kernel_pgid": fixture._owned_pgid,
        "kernel_pgids": list(kernel_pgids),
        "connection": fixture.connection,
        "ready": fixture.connection is not None,
        "alive": bool(fixture._process is not None and fixture._process.poll() is None),
    }


def _terminal_state(owner_token: str, kernel_pgids: list[int]) -> dict[str, object]:
    """Return the final ownership ledger after bridge-local cleanup."""
    return {
        "owner_token": owner_token,
        "bridge_pid": os.getpid(),
        "bridge_pgid": os.getpgrp(),
        "kernel_pgids": list(kernel_pgids),
        "cleaned": True,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--control-dir", required=True, type=Path)
    parser.add_argument("--token", required=True)
    parser.add_argument("--owner-token", required=True)
    parser.add_argument("--startup-timeout", type=float, default=15.0)
    args = parser.parse_args()

    args.control_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(args.control_dir, 0o700)
    stopped = False

    def stop(_signal: int, _frame: object) -> None:
        nonlocal stopped
        stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    fixture = LocalKernelFixture(startup_timeout=args.startup_timeout)
    kernel_pgids: list[int] = []

    def record_kernel_group() -> None:
        pgid = fixture._owned_pgid
        if not isinstance(pgid, int) or pgid <= 0:
            raise RuntimeError("fixture has no owned kernel process group")
        if pgid not in kernel_pgids:
            kernel_pgids.append(pgid)

    def launch_owned_initial() -> None:
        """Mirror fixture startup while publishing ownership before readiness."""
        if fixture._process is not None:
            raise RuntimeError("fixture is already started")
        fixture._tempdir = tempfile.TemporaryDirectory(prefix=fixture.session_id + "-")
        root = Path(fixture._tempdir.name)
        fixture.connection_path = root / "connection.json"
        fixture.cwd = root / "cwd"
        fixture.cwd.mkdir()
        try:
            fixture.resolved = resolve_kernelspec_document(
                _read_kernelspec_output(fixture.startup_timeout),
                fixture.kernelspec,
                str(fixture.connection_path),
                base_environment=os.environ,
            )
            fixture._launch()
            record_kernel_group()
            # The runner can now clean the kernel even if readiness blocks or
            # the bridge is terminated before entering its control loop.
            _write_json(args.state, _state(fixture, args.owner_token, kernel_pgids))
            fixture._wait_ready(fixture.startup_timeout)
        except BaseException:
            fixture.cleanup()
            raise

    def relaunch_owned() -> None:
        """Relaunch while publishing the new PGID before readiness can block."""
        if fixture._process is None or fixture.connection_path is None:
            raise RuntimeError("fixture is not started")
        previous_group = fixture._owned_pgid
        if not isinstance(previous_group, int) or previous_group <= 0:
            raise RuntimeError("fixture has no previous owned kernel process group")
        if fixture._process.poll() is None:
            fixture._terminate_group(previous_group, fixture._process)
        if fixture._group_exists(previous_group):
            fixture._terminate_group(previous_group, fixture._process)
        if fixture._group_exists(previous_group):
            raise RuntimeError("previous kernel process group survived")
        fixture._process = None
        fixture.kernel_pid = None
        fixture._owned_pgid = None
        fixture._launch()
        record_kernel_group()
        # The parent supervisor can now clean this exact group even if the
        # readiness probe stalls or the bridge must be killed afterward.
        _write_json(args.state, _state(fixture, args.owner_token, kernel_pgids))
        fixture._wait_ready(fixture.startup_timeout)

    try:
        launch_owned_initial()
        _write_json(args.state, _state(fixture, args.owner_token, kernel_pgids))
        while not stopped:
            for request_path in sorted(args.control_dir.glob("request-*.json")):
                response_path = request_path.with_name(
                    request_path.name.replace("request-", "response-", 1)
                )
                try:
                    request = json.loads(request_path.read_text(encoding="utf-8"))
                    if not isinstance(request, dict) or request.get("token") != args.token:
                        raise RuntimeError("invalid bridge request")
                    operation = request.get("op")
                    if operation == "status":
                        response = {"ok": True, "state": _state(fixture, args.owner_token, kernel_pgids)}
                    elif operation == "restart":
                        # A shutdown reply may arrive before the direct
                        # kernel process has left its test-owned group.  This
                        # bridge is the sole owner, so it can finish that
                        # bounded teardown before asking the fixture to
                        # relaunch; it never searches for unrelated PIDs.
                        relaunch_owned()
                        _write_json(args.state, _state(fixture, args.owner_token, kernel_pgids))
                        response = {"ok": True, "state": _state(fixture, args.owner_token, kernel_pgids)}
                    elif operation == "stop":
                        stopped = True
                        response = {"ok": True}
                    else:
                        raise RuntimeError("unsupported bridge operation")
                except Exception as exc:  # Deliberately bounded test-only diagnostic.
                    response = {"ok": False, "error": str(exc)[:240]}
                _write_json(response_path, response)
                request_path.unlink(missing_ok=True)
            time.sleep(0.02)
    finally:
        fixture.cleanup()
        # Preserve the exact ownership ledger for the parent runner's
        # postcondition check.  The runner owns and removes its temp root only
        # after every recorded process group is proved absent.
        _write_json(args.state, _terminal_state(args.owner_token, kernel_pgids))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
