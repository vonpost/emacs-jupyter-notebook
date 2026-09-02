#!/usr/bin/env python3
"""Deterministic unit tests for the AG3 supervisor's output isolation."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True


def load_runner():
    path = Path(__file__).with_name("run-ag3.py")
    spec = importlib.util.spec_from_file_location("ejn_run_ag3", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load run-ag3.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


RUNNER = load_runner()


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
        with self.assertRaisesRegex(RuntimeError, "exact 13/13 ERT summary"):
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


if __name__ == "__main__":
    unittest.main()
