#!/usr/bin/env python3
"""Run one bounded AG2 Emacs batch with exact local-process ownership.

The bridge and each test kernel use their own POSIX process group.  This
supervisor records only the IDs the bridge publishes under a random ownership
token, and never searches the host process table.  It handles normal exits,
its internal deadline, and TERM/INT/HUP by stopping Emacs, then the bridge,
then verifying every recorded bridge/kernel group is gone.

SIGKILL cannot run Python or bridge cleanup handlers.  The shell entry point
therefore deliberately has no second kill-based watchdog; callers requiring a
harder machine-level guarantee must supervise the whole invocation's cgroup or
job object and clean that owner after SIGKILL.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path
from typing import Any, Callable


STARTUP_TIMEOUT = 20.0
SHUTDOWN_TIMEOUT = 5.0
CLEANUP_STAGE_TIMEOUT = 8.0
CLEANUP_RESERVE = 30.0
POLL_INTERVAL = 0.02


class E2EError(RuntimeError):
    """A fail-closed test prerequisite or owned-process check failed."""


def positive_int(value: object, name: str) -> int:
    if type(value) is not int or value <= 0:
        raise E2EError(f"bridge state has invalid {name}")
    return value


def read_state(path: Path, owner_token: str, bridge_pid: int) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise E2EError(f"cannot read bridge state: {exc}") from exc
    if not isinstance(value, dict):
        raise E2EError("bridge state is not an object")
    if value.get("owner_token") != owner_token:
        raise E2EError("bridge state ownership token mismatch")
    if positive_int(value.get("bridge_pid"), "bridge_pid") != bridge_pid:
        raise E2EError("bridge state PID mismatch")
    positive_int(value.get("bridge_pgid"), "bridge_pgid")
    groups = value.get("kernel_pgids")
    if not isinstance(groups, list) or not groups:
        raise E2EError("bridge state has no owned kernel groups")
    for group in groups:
        positive_int(group, "kernel_pgids")
    return value


def wait_for_state(
    path: Path,
    process: subprocess.Popen[Any],
    owner_token: str,
    timeout: float,
    interrupted: Callable[[], bool],
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if interrupted():
            raise KeyboardInterrupt("received signal during bridge startup")
        if path.is_file():
            state = read_state(path, owner_token, process.pid)
            if state.get("ready") is True:
                return state
        if process.poll() is not None:
            raise E2EError("E2E kernel bridge exited before becoming ready")
        time.sleep(POLL_INTERVAL)
    raise E2EError("timed out waiting for E2E kernel bridge")


def group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError as exc:
        raise E2EError(f"cannot inspect owned process group {pgid}: {exc}") from exc
    return True


def signal_group(pgid: int, signum: signal.Signals) -> None:
    try:
        os.killpg(pgid, signum)
    except ProcessLookupError:
        return
    except PermissionError as exc:
        raise E2EError(f"cannot signal owned process group {pgid}: {exc}") from exc


def wait_group_gone(pgid: int, deadline: float) -> bool:
    while group_exists(pgid) and time.monotonic() < deadline:
        time.sleep(POLL_INTERVAL)
    return not group_exists(pgid)


def stop_group(pgid: int, deadline: float) -> None:
    """Stop only one already-owned POSIX process group, bounded."""
    if not group_exists(pgid):
        return
    signal_group(pgid, signal.SIGTERM)
    remaining = max(0.0, deadline - time.monotonic())
    term_deadline = min(
        deadline, time.monotonic() + min(SHUTDOWN_TIMEOUT, remaining / 2.0)
    )
    if wait_group_gone(pgid, term_deadline):
        return
    signal_group(pgid, signal.SIGKILL)
    if not wait_group_gone(pgid, deadline):
        raise E2EError(f"owned process group {pgid} survived SIGKILL")


def stop_child_group(
    process: subprocess.Popen[Any], deadline: float
) -> None:
    """Stop and reap a direct child that leads its owned process group."""
    pgid = process.pid
    if process.poll() is None:
        signal_group(pgid, signal.SIGTERM)
        remaining = max(0.0, deadline - time.monotonic())
        term_timeout = min(SHUTDOWN_TIMEOUT, remaining / 2.0)
        try:
            process.wait(timeout=term_timeout)
        except subprocess.TimeoutExpired:
            signal_group(pgid, signal.SIGKILL)
            try:
                process.wait(timeout=max(0.0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired as exc:
                raise E2EError(
                    f"owned child process group {pgid} survived SIGKILL"
                ) from exc
    else:
        # `poll' reaps a child that already exited.
        process.wait()
    if group_exists(pgid):
        stop_group(pgid, deadline)


def collect_owned_groups(
    state_path: Path, owner_token: str, bridge: subprocess.Popen[Any], known: set[int]
) -> dict[str, Any] | None:
    """Add groups from a current, token-bound bridge state when available."""
    if state_path.is_file():
        state = read_state(state_path, owner_token, bridge.pid)
        known.update(positive_int(group, "kernel_pgids") for group in state["kernel_pgids"])
        return state
    return None


def cleanup_owned(
    bridge: subprocess.Popen[Any] | None,
    state_path: Path | None,
    owner_token: str | None,
    known_kernel_groups: set[int],
    emacs: subprocess.Popen[Any] | None,
    deadline: float,
) -> None:
    """Bounded cleanup and postcondition verification for exact owned groups."""
    errors: list[str] = []
    current_kernel_group: int | None = None

    def stage_deadline() -> float:
        return min(deadline, time.monotonic() + CLEANUP_STAGE_TIMEOUT)

    if emacs is not None:
        try:
            stop_child_group(emacs, stage_deadline())
        except E2EError as exc:
            errors.append(str(exc))
    if bridge is not None:
        try:
            if state_path is not None and owner_token is not None:
                before = collect_owned_groups(
                    state_path, owner_token, bridge, known_kernel_groups
                )
                if before is not None and "kernel_pgid" in before:
                    current_kernel_group = positive_int(
                        before["kernel_pgid"], "kernel_pgid"
                    )
        except E2EError as exc:
            errors.append(str(exc))
        try:
            stop_child_group(bridge, stage_deadline())
        except E2EError as exc:
            errors.append(str(exc))
        try:
            if state_path is not None and owner_token is not None:
                after = collect_owned_groups(
                    state_path, owner_token, bridge, known_kernel_groups
                )
                if after is not None and after.get("cleaned") is True:
                    current_kernel_group = None
        except E2EError as exc:
            errors.append(str(exc))
    if current_kernel_group is not None and group_exists(current_kernel_group):
        try:
            stop_group(current_kernel_group, stage_deadline())
        except E2EError as exc:
            errors.append(str(exc))
    for pgid in sorted(known_kernel_groups):
        if group_exists(pgid):
            errors.append(
                f"historical owned kernel group {pgid} still exists; refusing to signal a reusable PGID"
            )
    if errors:
        raise E2EError("; ".join(errors))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--emacs", required=True)
    parser.add_argument("--code-cells", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=105.0,
                        help="per-batch wall clock deadline in seconds")
    args = parser.parse_args()
    if args.timeout <= STARTUP_TIMEOUT + CLEANUP_RESERVE:
        raise E2EError("--timeout must exceed bridge startup plus cleanup time")
    if not args.helper.is_file() or not os.access(args.helper, os.X_OK):
        raise E2EError("E2E helper executable is unavailable")
    if not (args.code_cells / "code-cells.el").is_file():
        raise E2EError("CODE_CELLS_DIR does not contain code-cells.el")
    if shutil.which(args.emacs) is None and not Path(args.emacs).is_file():
        raise E2EError("Emacs executable is unavailable")

    started = time.monotonic()
    deadline = started + args.timeout
    execution_deadline = deadline - CLEANUP_RESERVE
    bridge: subprocess.Popen[Any] | None = None
    emacs: subprocess.Popen[Any] | None = None
    state: Path | None = None
    owner_token: str | None = None
    owned_groups: set[int] = set()
    received_signal: int | None = None
    temporary: tempfile.TemporaryDirectory[str] | None = None
    result = 1

    def on_signal(signum: int, _frame: object) -> None:
        nonlocal received_signal
        received_signal = signum

    previous_handlers = {
        signum: signal.signal(signum, on_signal)
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
    }
    try:
        # Keep this directory alive through owned-process cleanup.  A context
        # manager would unlink state before the outer finally could verify its
        # final kernel-group ledger.
        temporary = tempfile.TemporaryDirectory(prefix="ejn-helper-e2e-")
        root = Path(temporary.name)
        control = root / "control"
        state = root / "kernel-state.json"
        token = uuid.uuid4().hex
        owner_token = uuid.uuid4().hex
        bridge_environment = os.environ.copy()
        bridge_environment["PYTHONDONTWRITEBYTECODE"] = "1"
        bridge = subprocess.Popen(
            [sys.executable, str(args.root / "tests" / "fixtures" / "ejn_e2e_kernel_bridge.py"),
             "--state", str(state), "--control-dir", str(control), "--token", token,
             "--owner-token", owner_token],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            env=bridge_environment,
            start_new_session=True,
        )
        initial = wait_for_state(
            state, bridge, owner_token,
            min(STARTUP_TIMEOUT,
                max(POLL_INTERVAL, execution_deadline - time.monotonic())),
            lambda: received_signal is not None,
        )
        owned_groups.update(positive_int(group, "kernel_pgids")
                            for group in initial["kernel_pgids"])
        environment = os.environ.copy()
        environment.update(
            EJN_E2E_STATE=str(state), EJN_E2E_CONTROL_DIR=str(control),
            EJN_E2E_TOKEN=token, EJN_E2E_ROOT=str(root),
            EJN_E2E_HELPER=str(args.helper), EJN_E2E_BRIDGE_PID=str(bridge.pid),
        )
        command = [
            args.emacs, "-Q", "--batch", "-L", str(args.root), "-L", str(args.root / "tests"),
            "-L", str(args.code_cells), "-l", str(args.root / "tests" / "emacs-jupyter-notebook-helper-e2e.el"),
            "--eval", "(ert-run-tests-batch-and-exit %s)" %
            json.dumps(os.environ.get("EJN_E2E_SELECTOR", "^ejn-ag2-")),
        ]
        emacs = subprocess.Popen(command, env=environment, start_new_session=True)
        while (emacs.poll() is None and received_signal is None
               and time.monotonic() < execution_deadline):
            collect_owned_groups(state, owner_token, bridge, owned_groups)
            time.sleep(POLL_INTERVAL)
        if received_signal is not None:
            raise KeyboardInterrupt(f"received signal {received_signal}")
        if emacs.poll() is None:
            raise TimeoutError(
                f"AG2 Emacs batch exhausted its cleanup-reserved {args.timeout:.1f}s deadline"
            )
        result = emacs.returncode
    finally:
        try:
            cleanup_owned(
                bridge, state, owner_token, owned_groups, emacs, deadline
            )
        finally:
            if temporary is not None:
                temporary.cleanup()
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)
    elapsed = time.monotonic() - started
    if elapsed >= args.timeout:
        raise TimeoutError(
            f"AG2 batch cleanup exceeded the {args.timeout:.1f}s wall clock"
        )
    return result


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt as exc:
        print(f"run-helper-e2e: {exc}", file=sys.stderr)
        raise SystemExit(128)
    except (E2EError, TimeoutError) as exc:
        print(f"run-helper-e2e: {exc}", file=sys.stderr)
        raise SystemExit(124 if isinstance(exc, TimeoutError) else 1)
