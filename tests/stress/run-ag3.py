#!/usr/bin/env python3
"""Run bounded AG3 stress repetitions with one exact TH2/TH3 owner."""

from __future__ import annotations

import argparse
import contextlib
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
EMACS_OUTPUT_LIMIT = 8 * 1024 * 1024
EMACS_OUTPUT_TAIL_LIMIT = 128 * 1024
FIXTURE_OUTPUT_LIMIT = 64 * 1024
BRIDGE_OUTPUT_LIMIT = 1024 * 1024
STATE_JSON_LIMIT = 1024 * 1024
CONNECTION_JSON_LIMIT = 64 * 1024
METRICS_JSON_LIMIT = 1024 * 1024
ERROR_DETAIL_LIMIT = 240
EXPECTED_ERT_SUMMARY = b"Ran 13 tests, 13 results as expected, 0 unexpected"


def die(message: str) -> RuntimeError:
    return RuntimeError(f"AG3: {message}")


def bounded_detail(error: BaseException | str, limit: int = ERROR_DETAIL_LIMIT) -> str:
    """Return diagnostic text without allowing an untrusted path to flood logs."""
    detail = str(error)
    return detail if len(detail) <= limit else detail[:limit - 3] + "..."


def read_bounded(path: Path, limit: int, label: str) -> bytes:
    """Read PATH only when it fits LIMIT, rejecting concurrent growth."""
    try:
        with path.open("rb") as stream:
            value = stream.read(limit + 1)
    except OSError as exc:
        raise die(f"cannot read {label}: {bounded_detail(exc)}") from exc
    if len(value) > limit:
        raise die(f"{label} exceeded {limit} bytes")
    return value


def read_bounded_json(path: Path, limit: int, label: str) -> object:
    """Read and parse a small JSON document, never parsing an unbounded body."""
    try:
        return json.loads(read_bounded(path, limit, label))
    except (ValueError, RecursionError) as exc:
        raise die(f"invalid {label} JSON: {bounded_detail(exc)}") from exc


def state(path: Path, owner: str, pid: int, ready: bool = True) -> dict:
    value = read_bounded_json(path, STATE_JSON_LIMIT, "relay bridge state")
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
        if len(connection) > 4096:
            raise die("rewritten relay connection path exceeded 4096 characters")
        connection = read_bounded_json(
            Path(connection), CONNECTION_JSON_LIMIT, "rewritten relay connection")
        if not isinstance(connection, dict):
            raise die("rewritten relay connection is not an object")
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


def wait_state(path: Path, owner: str, bridge: subprocess.Popen[bytes], timeout: float,
               output: bytearray, output_bytes: int) -> tuple[dict, int]:
    deadline = time.monotonic() + timeout
    last_error: str | None = None
    while time.monotonic() < deadline:
        output_bytes = drain_output(
            bridge, output, output_bytes, BRIDGE_OUTPUT_LIMIT)
        if output_bytes > BRIDGE_OUTPUT_LIMIT:
            raise die(f"relay bridge output exceeded {BRIDGE_OUTPUT_LIMIT} bytes")
        if bridge.poll() is not None:
            raise die("relay bridge exited before readiness")
        if path.is_file():
            try:
                return state(path, owner, bridge.pid), output_bytes
            except (OSError, ValueError, RuntimeError) as exc:
                last_error = bounded_detail(exc)
        time.sleep(POLL)
    detail = f"; last state error: {last_error}" if last_error else ""
    raise die(f"relay bridge readiness timed out{detail}")


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


def drain_output(process: subprocess.Popen[bytes], tail: bytearray, total: int,
                 limit: int = EMACS_OUTPUT_LIMIT) -> int:
    """Drain PROCESS output without exposing it to the supervisor's stdout."""
    if process.stdout is None:
        return total
    while True:
        try:
            chunk = os.read(process.stdout.fileno(), 65536)
        except BlockingIOError:
            break
        if not chunk:
            break
        total += len(chunk)
        if len(chunk) >= EMACS_OUTPUT_TAIL_LIMIT:
            tail[:] = chunk[-EMACS_OUTPUT_TAIL_LIMIT:]
        else:
            tail.extend(chunk)
            excess = len(tail) - EMACS_OUTPUT_TAIL_LIMIT
            if excess > 0:
                del tail[:excess]
        if total > limit:
            break
    return total


def output_tail(tail: bytearray) -> str:
    """Return a printable bounded diagnostic from captured child output."""
    return bytes(tail).decode("utf-8", "replace").strip()


def check_emacs_result(returncode: int, total: int, tail: bytearray) -> None:
    """Require bounded output, zero status, and the exact AG3 ERT summary."""
    if total > EMACS_OUTPUT_LIMIT:
        raise die(
            f"Emacs stress output exceeded {EMACS_OUTPUT_LIMIT} bytes; "
            f"bounded tail follows:\n{output_tail(tail)}")
    if returncode:
        raise die(
            f"Emacs stress batch failed with {returncode}; bounded output "
            f"tail follows:\n{output_tail(tail)}")
    if EXPECTED_ERT_SUMMARY not in tail:
        raise die(
            "Emacs exited successfully without the exact 13/13 ERT summary; "
            f"bounded output tail follows:\n{output_tail(tail)}")


def run_bounded_capture(command: list[str], env: dict[str, str], timeout: float,
                        limit: int) -> tuple[int, bytearray]:
    """Run COMMAND in its own group with bounded merged output and time."""
    process = subprocess.Popen(
        command, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, start_new_session=True)
    if process.stdout is None:
        stop(process, time.monotonic() + 2)
        raise die("bounded child output capture was not created")
    os.set_blocking(process.stdout.fileno(), False)
    deadline = time.monotonic() + timeout
    tail = bytearray()
    total = 0
    try:
        while process.poll() is None and time.monotonic() < deadline:
            total = drain_output(process, tail, total, limit)
            if total > limit:
                stop(process, min(deadline, time.monotonic() + 5))
                raise die(f"bounded child output exceeded {limit} bytes")
            time.sleep(POLL)
        total = drain_output(process, tail, total, limit)
        if process.poll() is None:
            stop(process, min(deadline + 5, time.monotonic() + 5))
            raise die(f"bounded child timed out after {timeout:.1f}s")
        if total > limit:
            raise die(f"bounded child output exceeded {limit} bytes")
        return process.returncode, tail
    finally:
        if process.poll() is None:
            stop(process, min(deadline + 5, time.monotonic() + 5))
        if process.stdout is not None:
            process.stdout.close()


@contextlib.contextmanager
def retained_tempdir(prefix: str):
    """Yield a private temp directory and retain it when the batch fails."""
    path = Path(tempfile.mkdtemp(prefix=prefix))
    try:
        yield path
    except BaseException:
        try:
            print(f"AG3 failure evidence retained at {path}", file=sys.stderr)
        except (BrokenPipeError, OSError):
            pass
        raise


def remove_tree_bounded(path: Path, deadline: float) -> None:
    """Remove a successful batch directory before DEADLINE or fail visibly."""
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise die(f"cleanup deadline expired; evidence retained at {path}")
    try:
        result = subprocess.run(
            ["rm", "-rf", str(path)], stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
            timeout=remaining, check=False)
    except subprocess.TimeoutExpired as exc:
        raise die(f"temp cleanup timed out; evidence retained at {path}") from exc
    if result.returncode or path.exists():
        raise die(f"temp cleanup failed; evidence retained at {path}")


def run_once(args: argparse.Namespace, number: int) -> None:
    started = time.monotonic()
    bridge: subprocess.Popen[bytes] | None = None
    child: subprocess.Popen[bytes] | None = None
    known_kernel_groups: set[int] = set()
    current_kernel_group: int | None = None
    received_signal: int | None = None
    child_output = bytearray()
    child_output_bytes = 0
    bridge_output = bytearray()
    bridge_output_bytes = 0

    def on_signal(signum: int, _frame: object) -> None:
        nonlocal received_signal
        received_signal = signum

    old_handlers = {signum: signal.signal(signum, on_signal)
                    for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)}
    with retained_tempdir(prefix="ejn-ag3-") as root:
        control, bridge_state, metrics = root / "control", root / "state.json", root / "metrics.json"
        token, owner = uuid.uuid4().hex, uuid.uuid4().hex
        env = os.environ.copy()
        env.update({"PYTHONDONTWRITEBYTECODE": "1", "EJN_AG3_STATE": str(bridge_state),
                    "EJN_AG3_CONTROL_DIR": str(control), "EJN_AG3_TOKEN": token,
                    "EJN_AG3_METRICS": str(metrics), "EJN_E2E_STATE": str(bridge_state),
                    "EJN_E2E_CONTROL_DIR": str(control), "EJN_E2E_TOKEN": token,
                    "EJN_E2E_ROOT": str(root), "EJN_E2E_HELPER": str(args.helper),
                    "TMPDIR": str(root), "TMP": str(root), "TEMP": str(root)})
        try:
            fixture_started = time.monotonic()
            fixture_status, fixture_output = run_bounded_capture(
                [sys.executable, "-B", str(args.root / "tests/stress/fixtures/ag3_stress_fixtures.py"),
                 "self-test"],
                env, min(30, max(0.1, started + args.timeout - time.monotonic())),
                FIXTURE_OUTPUT_LIMIT)
            if fixture_status:
                detail = output_tail(fixture_output)[-512:]
                raise die(f"AG3 artifact fixture self-test failed: {detail}")
            fixture_elapsed = time.monotonic() - fixture_started
            bridge = subprocess.Popen(
                [sys.executable, "-B", str(args.root / "tests/stress/relay_bridge.py"),
                 "--state", str(bridge_state), "--control-dir", str(control),
                 "--token", token, "--owner-token", owner],
                env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, start_new_session=True)
            if bridge.stdout is None:
                raise die("relay bridge output capture was not created")
            os.set_blocking(bridge.stdout.fileno(), False)
            initial, bridge_output_bytes = wait_state(
                bridge_state, owner, bridge, 20,
                bridge_output, bridge_output_bytes)
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
            child = subprocess.Popen(
                command, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, start_new_session=True)
            if child.stdout is None:
                raise die("Emacs output capture was not created")
            os.set_blocking(child.stdout.fileno(), False)
            deadline = started + args.timeout - 15
            while (received_signal is None and time.monotonic() < deadline):
                child_output_bytes = drain_output(child, child_output, child_output_bytes)
                bridge_output_bytes = drain_output(
                    bridge, bridge_output, bridge_output_bytes, BRIDGE_OUTPUT_LIMIT)
                if bridge_output_bytes > BRIDGE_OUTPUT_LIMIT:
                    raise die(
                        f"relay bridge output exceeded {BRIDGE_OUTPUT_LIMIT} bytes; "
                        f"bounded tail follows:\n{output_tail(bridge_output)}")
                if child_output_bytes > EMACS_OUTPUT_LIMIT:
                    stop(child, min(started + args.timeout - 7, time.monotonic() + 8))
                    check_emacs_result(child.returncode or -1,
                                       child_output_bytes, child_output)
                if child.poll() is not None:
                    break
                time.sleep(POLL)
            child_output_bytes = drain_output(child, child_output, child_output_bytes)
            bridge_output_bytes = drain_output(
                bridge, bridge_output, bridge_output_bytes, BRIDGE_OUTPUT_LIMIT)
            if bridge_output_bytes > BRIDGE_OUTPUT_LIMIT:
                raise die(
                    f"relay bridge output exceeded {BRIDGE_OUTPUT_LIMIT} bytes; "
                    f"bounded tail follows:\n{output_tail(bridge_output)}")
            if child_output_bytes > EMACS_OUTPUT_LIMIT:
                if child.poll() is None:
                    stop(child, min(started + args.timeout - 7, time.monotonic() + 8))
                check_emacs_result(child.returncode or -1,
                                   child_output_bytes, child_output)
            if received_signal is not None:
                raise KeyboardInterrupt(f"received signal {received_signal}")
            if child.poll() is None:
                stop(child, min(started + args.timeout - 7, time.monotonic() + 8))
                raise die("Emacs stress batch timed out")
            check_emacs_result(child.returncode, child_output_bytes, child_output)
            if not metrics.is_file():
                raise die("Emacs emitted no structured metrics")
            parsed = read_bounded_json(metrics, METRICS_JSON_LIMIT, "structured metrics")
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
            if child is not None and child.stdout is not None:
                try:
                    child_output_bytes = drain_output(child, child_output, child_output_bytes)
                    child.stdout.close()
                except OSError as exc:
                    errors.append(f"cannot close Emacs output capture: {exc}")
            if bridge is not None and bridge.stdout is not None:
                try:
                    bridge_output_bytes = drain_output(
                        bridge, bridge_output, bridge_output_bytes,
                        BRIDGE_OUTPUT_LIMIT)
                    bridge.stdout.close()
                    if bridge_output_bytes > BRIDGE_OUTPUT_LIMIT:
                        errors.append(
                            f"relay bridge output exceeded {BRIDGE_OUTPUT_LIMIT} bytes")
                except OSError as exc:
                    errors.append(f"cannot close relay bridge output capture: {exc}")
            try:
                (root / "emacs.output.tail").write_bytes(bytes(child_output))
                (root / "bridge.output.tail").write_bytes(bytes(bridge_output))
            except OSError as exc:
                errors.append(f"cannot persist bounded output tails: {exc}")
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
    remove_tree_bounded(root, started + args.timeout)
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
