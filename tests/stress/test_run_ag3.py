#!/usr/bin/env python3
"""Deterministic unit tests for the AG3 supervisor's output isolation."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
from pathlib import Path

sys.dont_write_bytecode = True


def load_module(name: str, filename: str):
    path = Path(__file__).with_name(filename)
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {filename}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = load_module("ejn_run_ag3", "run-ag3.py")
RELAY = load_module("ejn_relay_bridge", "relay_bridge.py")
SHELL_WRAPPER = Path(__file__).with_name("run-ag3.sh")


class OutputIsolationTests(unittest.TestCase):
    def test_finite_output_keeps_only_bounded_tail(self) -> None:
        child = subprocess.Popen(
            [sys.executable, "-c",
             "import os; os.write(1, b'x' * 200000); os.write(2, b'TAIL-MARKER\\n')"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertIsNotNone(child.stdout)
        assert child.stdout is not None
        os.set_blocking(child.stdout.fileno(), False)
        tail = bytearray()
        total = 0
        try:
            while child.poll() is None:
                total = RUNNER.drain_output(child, tail, total)
                time.sleep(0.001)
            total = RUNNER.drain_output(child, tail, total)
            self.assertEqual(total, 200012)
            self.assertEqual(len(tail), RUNNER.EMACS_OUTPUT_TAIL_LIMIT)
            self.assertTrue(RUNNER.output_tail(tail).endswith("TAIL-MARKER"))
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=2)
            child.stdout.close()

    def test_endless_output_returns_after_hard_cap(self) -> None:
        child = subprocess.Popen(
            [sys.executable, "-c",
             "import os\nwhile True: os.write(1, b'x' * 65536)"],
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertIsNotNone(child.stdout)
        assert child.stdout is not None
        os.set_blocking(child.stdout.fileno(), False)
        tail = bytearray()
        total = 0
        limit = 256 * 1024
        deadline = time.monotonic() + 2
        try:
            while total <= limit and time.monotonic() < deadline:
                total = RUNNER.drain_output(child, tail, total, limit)
                time.sleep(0.001)
            self.assertGreater(total, limit)
            self.assertLessEqual(total, limit + 65536)
            self.assertEqual(len(tail), RUNNER.EMACS_OUTPUT_TAIL_LIMIT)
        finally:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=2)
            child.stdout.close()

    def test_result_validation_requires_cap_status_and_exact_summary(self) -> None:
        good = bytearray(RUNNER.EXPECTED_ERT_SUMMARY + b"\n")
        RUNNER.check_emacs_result(0, len(good), good)
        with self.assertRaisesRegex(RuntimeError, "exceeded"):
            RUNNER.check_emacs_result(
                0, RUNNER.EMACS_OUTPUT_LIMIT + 1, bytearray(b"bounded tail"))
        with self.assertRaisesRegex(RuntimeError, "failed with 7"):
            RUNNER.check_emacs_result(7, len(good), good)
        with self.assertRaisesRegex(RuntimeError, "exact 17/17 ERT summary"):
            RUNNER.check_emacs_result(0, 4, bytearray(b"nope"))

    def test_failure_tempdir_is_retained_until_explicit_bounded_removal(self) -> None:
        root = None
        diagnostic = io.StringIO()
        with contextlib.redirect_stderr(diagnostic):
            with self.assertRaisesRegex(RuntimeError, "injected"):
                with RUNNER.retained_tempdir("ejn-ag3-unit-") as owned:
                    root = owned
                    (root / "evidence").write_text("kept", encoding="utf-8")
                    raise RuntimeError("injected")
        self.assertIsNotNone(root)
        assert root is not None
        self.assertIn(str(root), diagnostic.getvalue())
        self.assertEqual((root / "evidence").read_text(encoding="utf-8"), "kept")
        RUNNER.remove_tree_bounded(root, time.monotonic() + 2)
        self.assertFalse(root.exists())

    def test_bounded_child_rejects_unlimited_output(self) -> None:
        with self.assertRaisesRegex(RuntimeError, "output exceeded"):
            RUNNER.run_bounded_capture(
                [sys.executable, "-c",
                 "import os\nwhile True: os.write(1, b'x' * 65536)"],
                os.environ.copy(), 2, 128 * 1024)


class BoundedJsonTests(unittest.TestCase):
    def test_runner_rejects_oversized_json_before_parsing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ejn-ag3-unit-") as temporary:
            path = Path(temporary) / "too-large.json"
            path.write_bytes(b"x" * 33)
            with mock.patch.object(RUNNER.json, "loads", side_effect=AssertionError("parsed")):
                with self.assertRaisesRegex(RuntimeError, "unit JSON exceeded 32 bytes"):
                    RUNNER.read_bounded_json(path, 32, "unit JSON")

    def test_state_rejects_oversized_rewritten_connection(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ejn-ag3-unit-") as temporary:
            root = Path(temporary)
            connection = root / "connection.json"
            connection.write_bytes(b"x" * 33)
            state_path = root / "state.json"
            ports = {"shell": 1001, "iopub": 1002, "stdin": 1003,
                     "control": 1004, "hb": 1005}
            state_path.write_text(
                json.dumps({
                    "owner_token": "owner", "bridge_pid": 42, "ready": True,
                    "connection_file": str(connection), "relay_ports": ports,
                    "kernel_pgid": 43, "kernel_pgids": [43], "alive": True,
                }),
                encoding="utf-8")
            with mock.patch.object(RUNNER, "CONNECTION_JSON_LIMIT", 32):
                with self.assertRaisesRegex(
                        RuntimeError, "rewritten relay connection exceeded 32 bytes"):
                    RUNNER.state(state_path, "owner", 42)

    def test_relay_rejects_oversized_request_before_parsing(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ejn-ag3-unit-") as temporary:
            path = Path(temporary) / "request-too-large.json"
            path.write_bytes(b"x" * (RELAY.REQUEST_JSON_LIMIT + 1))
            with mock.patch.object(RELAY.json, "loads", side_effect=AssertionError("parsed")):
                with self.assertRaisesRegex(
                        RuntimeError,
                        f"bridge request exceeded {RELAY.REQUEST_JSON_LIMIT} bytes"):
                    RELAY.read_request_json(path)

    def test_error_evidence_is_capped(self) -> None:
        detail = RELAY.bounded_detail("x" * (RELAY.ERROR_DETAIL_LIMIT + 10))
        self.assertEqual(len(detail), RELAY.ERROR_DETAIL_LIMIT)
        self.assertTrue(detail.endswith("..."))


class ShellWrapperTests(unittest.TestCase):
    def run_shell(self, script: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("Bash is required by run-ag3.sh")
        environment = os.environ.copy()
        environment.update({"EJN_AG3_TERM_GRACE": "1", "PYTHONDONTWRITEBYTECODE": "1"})
        return subprocess.run(
            [bash, "-c", script, "ag3-shell-test", str(SHELL_WRAPPER), *arguments],
            env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, timeout=8, check=False)

    def test_wrapper_preserves_successful_command_stdout(self) -> None:
        result = self.run_shell(
            "source \"$1\"; output=$(run_bounded 2 \"$2\" -c "
            "'import sys; sys.stdout.write(\"/nix/store/helper\")'); "
            "test \"$output\" = /nix/store/helper",
            sys.executable)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrapper_timeout_kills_the_owned_process_group(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ejn-ag3-unit-") as temporary:
            root = Path(temporary)
            worker, child_pid = root / "worker.py", root / "child.pid"
            worker.write_text(
                "import signal\n"
                "import subprocess\n"
                "import sys\n"
                "import time\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'])\n"
                "with open(sys.argv[1], 'w', encoding='utf-8') as stream:\n"
                "    stream.write(str(child.pid))\n"
                "time.sleep(30)\n",
                encoding="utf-8")
            result = self.run_shell(
                "source \"$1\"; set +e; run_bounded 1 \"$2\" \"$3\" \"$4\"; "
                "status=$?; set -e; test \"$status\" = 124 || exit 20; "
                "test -s \"$4\" || exit 21; child=$(cat \"$4\"); "
                "deadline=$((SECONDS + 3)); "
                "while kill -0 \"$child\" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.1; done; "
                "kill -0 \"$child\" 2>/dev/null && exit 22; exit 0",
                sys.executable, str(worker), str(child_pid))
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrapper_reaps_descendants_after_successful_leader_exit(self) -> None:
        with tempfile.TemporaryDirectory(prefix="ejn-ag3-unit-") as temporary:
            root = Path(temporary)
            worker, child_pid = root / "worker.py", root / "child.pid"
            worker.write_text(
                "import subprocess\n"
                "import sys\n"
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(30)'])\n"
                "with open(sys.argv[1], 'w', encoding='utf-8') as stream:\n"
                "    stream.write(str(child.pid))\n",
                encoding="utf-8")
            result = self.run_shell(
                "source \"$1\"; set +e; run_bounded 2 \"$2\" \"$3\" \"$4\"; "
                "status=$?; set -e; test \"$status\" = 1 || exit 30; "
                "test -s \"$4\" || exit 31; child=$(cat \"$4\"); "
                "deadline=$((SECONDS + 3)); "
                "while kill -0 \"$child\" 2>/dev/null && (( SECONDS < deadline )); do sleep 0.1; done; "
                "kill -0 \"$child\" 2>/dev/null && exit 32; exit 0",
                sys.executable, str(worker), str(child_pid))
            self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
