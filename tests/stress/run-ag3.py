#!/usr/bin/env python3
"""Run bounded AG3 stress repetitions with one exact TH2/TH3 owner."""

from __future__ import annotations

import argparse
import json
import math
import os
import platform
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path


POLL = 0.05
SUPPORTED_HOSTS = {("Linux", "x86_64"), ("Darwin", "arm64")}


def die(message: str) -> RuntimeError:
    return RuntimeError(f"AG3: {message}")


def state(path: Path, owner: str, pid: int, ready: bool = True) -> dict:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict) or value.get("owner_token") != owner:
        raise die("relay bridge state ownership mismatch")
    if value.get("bridge_pid") != pid:
        raise die("relay bridge state PID mismatch")
    if ready and value.get("ready") is not True:
        raise die("relay bridge did not become ready")
    if ready:
        connection = value.get("connection_file")
        ports = value.get("relay_ports")
        if not isinstance(connection, str) or not os.path.isabs(connection):
            raise die("relay bridge returned no absolute rewritten connection file")
        if not isinstance(ports, dict) or set(ports) != {"shell", "iopub", "stdin", "control", "hb"}:
            raise die("relay bridge did not publish exactly five channel ports")
        if any(type(port) is not int or not 0 < port < 65536 for port in ports.values()):
            raise die("relay bridge returned invalid channel port")
        try:
            connection = json.loads(Path(connection).read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise die(f"cannot read rewritten relay connection: {exc}") from exc
        if connection.get("ip") not in {"127.0.0.1", "::1", "localhost"}:
            raise die("rewritten relay connection is not loopback")
        if any(connection.get(f"{name}_port") != port for name, port in ports.items()):
            raise die("rewritten connection ports differ from bridge state")
        if len(set(ports.values())) != 5:
            raise die("relay bridge ports are not distinct")
        if type(value.get("kernel_pgid")) is not int or value["kernel_pgid"] <= 0:
            raise die("relay bridge returned invalid current kernel PGID")
        if value.get("alive") is not True:
            raise die("relay bridge kernel is not alive")
    groups = value.get("kernel_pgids")
    if not isinstance(groups, list) or any(type(group) is not int or group <= 0 for group in groups):
        raise die("relay bridge returned invalid kernel ownership ledger")
    return value


def wait_state(path: Path, owner: str, bridge: subprocess.Popen[bytes], timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if bridge.poll() is not None:
            raise die("relay bridge exited before readiness")
        if path.is_file():
            try:
                return state(path, owner, bridge.pid)
            except (OSError, ValueError, RuntimeError):
                pass
        time.sleep(POLL)
    raise die("relay bridge readiness timed out")


def stop(process: subprocess.Popen[bytes] | None, deadline: float) -> None:
    """Terminate and reap one test-owned process group before DEADLINE."""
    if process is None:
        return
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGTERM)
    while process.poll() is None and time.monotonic() < deadline:
        time.sleep(POLL)
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=max(0.1, deadline - time.monotonic()))
    else:
        process.wait()
    if group_exists(process.pid):
        stop_group(process.pid, deadline)


def group_exists(pgid: int) -> bool:
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    return True


def stop_group(pgid: int, deadline: float) -> None:
    """Stop only a presently-owned group, with no process-table search."""
    if not group_exists(pgid):
        return
    os.killpg(pgid, signal.SIGTERM)
    term_deadline = min(deadline, time.monotonic() + 3.0)
    while group_exists(pgid) and time.monotonic() < term_deadline:
        time.sleep(POLL)
    if group_exists(pgid):
        os.killpg(pgid, signal.SIGKILL)
    while group_exists(pgid) and time.monotonic() < deadline:
        time.sleep(POLL)
    if group_exists(pgid):
        raise die(f"owned process group {pgid} survived SIGKILL")


def run_once(args: argparse.Namespace, number: int) -> None:
    started = time.monotonic()
    bridge: subprocess.Popen[bytes] | None = None
    child: subprocess.Popen[bytes] | None = None
    known_kernel_groups: set[int] = set()
    current_kernel_group: int | None = None
    received_signal: int | None = None

    def on_signal(signum: int, _frame: object) -> None:
        nonlocal received_signal
        received_signal = signum

    old_handlers = {signum: signal.signal(signum, on_signal)
                    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    with tempfile.TemporaryDirectory(prefix="ejn-ag3-") as temp:
        root = Path(temp)
        control, bridge_state, metrics = root / "control", root / "state.json", root / "metrics.json"
        token, owner = uuid.uuid4().hex, uuid.uuid4().hex
        env = os.environ.copy()
        env.update({"PYTHONDONTWRITEBYTECODE": "1", "EJN_AG3_STATE": str(bridge_state),
                    "EJN_AG3_CONTROL_DIR": str(control), "EJN_AG3_TOKEN": token,
                    "EJN_AG3_METRICS": str(metrics), "EJN_E2E_STATE": str(bridge_state),
                    "EJN_E2E_CONTROL_DIR": str(control), "EJN_E2E_TOKEN": token,
                    "EJN_E2E_ROOT": str(root), "EJN_E2E_HELPER": str(args.helper)})
        try:
            fixture_started = time.monotonic()
            fixture = subprocess.run(
                [sys.executable, "-B", str(args.root / "tests/stress/fixtures/ag3_stress_fixtures.py"),
                 "self-test"],
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                timeout=30, check=False)
            if fixture.returncode:
                detail = fixture.stderr[:512].decode("utf-8", "replace")
                raise die(f"AG3 artifact fixture self-test failed: {detail}")
            fixture_elapsed = time.monotonic() - fixture_started
            bridge_log = root / "bridge.stderr"
            bridge_stream = bridge_log.open("wb")
            bridge = subprocess.Popen(
                [sys.executable, "-B", str(args.root / "tests/stress/relay_bridge.py"),
                 "--state", str(bridge_state), "--control-dir", str(control),
                 "--token", token, "--owner-token", owner],
                env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=bridge_stream, start_new_session=True)
            bridge_stream.close()
            initial = wait_state(bridge_state, owner, bridge, 20)
            known_kernel_groups.update(int(group) for group in initial["kernel_pgids"])
            current_kernel_group = int(initial["kernel_pgid"])
            stress_modules = [
                args.root / "tests/stress/emacs-jupyter-notebook-lifecycle-stress.el",
                args.root / "tests/stress/emacs-jupyter-notebook-panel-stress.el",
                args.root / "tests/stress/emacs-jupyter-notebook-artifact-stress.el",
                args.root / "tests/stress/emacs-jupyter-notebook-execution-stress.el",
                args.root / "tests/stress/emacs-jupyter-notebook-reconnect-stress.el",
            ]
            missing_modules = [str(module) for module in stress_modules if not module.is_file()]
            if missing_modules:
                raise die(f"AG3 stress modules are unavailable: {', '.join(missing_modules)}")
            command = [args.emacs, "-Q", "--batch", "-L", str(args.root), "-L", str(args.root / "tests"),
                       "-L", str(args.code_cells), "-l",
                       str(args.root / "tests/stress/emacs-jupyter-notebook-stress.el")]
            for module in stress_modules:
                command.extend(["-l", str(module)])
            command.extend(["--eval", "(ert-run-tests-batch-and-exit \"^ejn-ag3-\")"])
            child = subprocess.Popen(command, env=env, start_new_session=True)
            deadline = started + args.timeout - 15
            while (child.poll() is None and received_signal is None
                   and time.monotonic() < deadline):
                time.sleep(POLL)
            if received_signal is not None:
                raise KeyboardInterrupt(f"received signal {received_signal}")
            if child.poll() is None:
                stop(child, min(started + args.timeout - 7, time.monotonic() + 8))
                raise die("Emacs stress batch timed out")
            if child.returncode:
                raise die(f"Emacs stress batch failed with {child.returncode}")
            if not metrics.is_file():
                raise die("Emacs emitted no structured metrics")
            parsed = json.loads(metrics.read_text(encoding="utf-8"))
            if not isinstance(parsed, list) or not parsed:
                raise die("structured metrics are empty")
            print(json.dumps({"batch": number, "elapsed": round(time.monotonic() - started, 3),
                              "fixture_elapsed": round(fixture_elapsed, 3),
                              "metrics": parsed}, sort_keys=True))
        finally:
            cleanup_deadline = started + args.timeout
            errors: list[str] = []
            # Three independently bounded stages leave room for final state
            # verification; a wedged Emacs cannot consume bridge cleanup.
            for process in (child, bridge):
                try:
                    stop(process, min(cleanup_deadline, time.monotonic() + 8.0))
                except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
                    errors.append(str(exc))
            if bridge is not None and bridge_state.is_file():
                try:
                    terminal = state(bridge_state, owner, bridge.pid, ready=False)
                    known_kernel_groups.update(int(group) for group in terminal["kernel_pgids"])
                    if terminal.get("cleaned") is True:
                        current_kernel_group = None
                    elif isinstance(terminal.get("kernel_pgid"), int):
                        current_kernel_group = int(terminal["kernel_pgid"])
                except (OSError, ValueError, RuntimeError, KeyError) as exc:
                    errors.append(f"cannot read terminal bridge ledger: {exc}")
            if current_kernel_group is not None:
                try:
                    stop_group(current_kernel_group,
                               min(cleanup_deadline, time.monotonic() + 8.0))
                except (OSError, RuntimeError) as exc:
                    errors.append(str(exc))
            for pgid in sorted(known_kernel_groups):
                if group_exists(pgid):
                    errors.append(f"historical kernel process group {pgid} survived; refusing reusable PGID")
            for signum, handler in old_handlers.items():
                signal.signal(signum, handler)
            if errors:
                raise die("; ".join(errors))
    if time.monotonic() >= started + args.timeout:
        raise die("cleanup exceeded batch deadline")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, type=Path)
    parser.add_argument("--emacs", default="emacs")
    parser.add_argument("--code-cells", required=True, type=Path)
    parser.add_argument("--helper", required=True, type=Path)
    parser.add_argument("--repeat", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()
    host = (platform.system(), platform.machine())
    if host not in SUPPORTED_HOSTS:
        raise die("supported hosts are x86_64-linux and aarch64-darwin")
    if args.repeat <= 0 or not math.isfinite(args.timeout) or args.timeout <= 45:
        raise die("repeat must be positive and timeout must be finite and exceed 45 seconds")
    if not args.helper.is_file() or not os.access(args.helper, os.X_OK):
        raise die("helper executable is unavailable")
    if not (args.code_cells / "code-cells.el").is_file():
        raise die("code-cells.el is unavailable")
    for number in range(1, args.repeat + 1):
        run_once(args, number)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
