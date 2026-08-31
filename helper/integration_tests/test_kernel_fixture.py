"""Bounded tests for the test-owned local kernel fixture."""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from direct_kernel_fixture import DirectKernelFixtureError
from kernel_fixture import KernelAppFixture, KernelFixtureError, LocalKernelFixture


def _python(*args: str) -> list[str]:
    return [sys.executable, *args]


class KernelFixtureTests(unittest.TestCase):
    def test_startup_failure_is_bounded(self) -> None:
        fixture = KernelAppFixture(command=_python("-c", "raise SystemExit(7)"), startup_timeout=2)
        with self.assertRaises(KernelFixtureError):
            fixture.start()
        fixture.cleanup()
        self.assertIsNone(fixture._process)

    def test_popen_exec_failure_cleans_private_directory(self) -> None:
        fixture = KernelAppFixture(command=["/definitely/missing/ejn-helper"], startup_timeout=1)
        with self.assertRaises(FileNotFoundError):
            fixture.start()
        self.assertIsNone(fixture._tempdir)
        for attribute in ("connection_path", "cache_dir", "cwd", "_stdout_log", "_stderr_log"):
            self.assertIsNone(getattr(fixture, attribute))
        fixture.cleanup()

    def test_startup_timeout_is_bounded(self) -> None:
        fixture = KernelAppFixture(command=_python("-c", "import time; time.sleep(10)"), startup_timeout=0.1)
        started = time.monotonic()
        with self.assertRaises(TimeoutError):
            fixture.start()
        self.assertLess(time.monotonic() - started, 2)
        fixture.cleanup()
        self.assertIsNone(fixture.connection_path)
        self.assertFalse(list(Path(tempfile.gettempdir()).glob(f"{fixture.session_id}-*")))

    def test_owned_process_group_and_child_are_reaped(self) -> None:
        with tempfile.NamedTemporaryFile(delete=False) as marker:
            marker_path = marker.name
        child = ("import os,subprocess,sys,time; open(sys.argv[1],'w').write(str(os.getpgid(0))); "
                 "subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(10)']); time.sleep(10)")
        fixture = KernelAppFixture(command=_python("-c", child, marker_path), startup_timeout=0.1)
        with self.assertRaises(TimeoutError):
            fixture.start()
        self.assertIsNone(fixture._owned_pgid)
        self.assertIsNone(fixture.manager_pid)
        self.assertNotIn(fixture.session_id, KernelAppFixture._owners)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and not Path(marker_path).read_text().strip():
            time.sleep(0.01)
        pgid = int(Path(marker_path).read_text())
        with self.assertRaises(ProcessLookupError):
            os.killpg(pgid, 0)
        Path(marker_path).unlink(missing_ok=True)

    def test_cleanup_twice_does_not_signal_and_clears_state(self) -> None:
        process = subprocess.Popen(_python("-c", "import time; time.sleep(10)"), start_new_session=True)
        fixture = KernelAppFixture()
        fixture._process = process
        fixture._owned_pgid = process.pid
        fixture.manager_pid = process.pid
        fixture._owned_session = True
        KernelAppFixture._owners[fixture.session_id] = fixture
        fixture.cleanup()
        with patch("kernel_fixture.os.killpg") as killpg:
            fixture.cleanup()
            killpg.assert_not_called()
        self.assertFalse(fixture._owned_session)
        self.assertIsNone(fixture._owned_pgid)
        self.assertIsNone(fixture.manager_pid)
        self.assertIsNone(fixture.connection)
        self.assertIsNone(fixture.connection_path)
        self.assertIsNone(fixture.cache_dir)
        self.assertIsNone(fixture.cwd)
        self.assertIsNone(fixture._stdout_log)
        self.assertIsNone(fixture._stderr_log)
        self.assertIsNone(fixture._tempdir)

    def test_cleanup_reports_a_process_group_that_survives_kill(self) -> None:
        fixture = KernelAppFixture()
        fixture._process = Mock()
        fixture._owned_pgid = 12345
        fixture._owned_session = True
        KernelAppFixture._owners[fixture.session_id] = fixture
        with (patch("kernel_fixture.os.killpg"),
              patch.object(fixture, "_wait_group_gone", return_value=False),
              self.assertRaisesRegex(KernelFixtureError, "did not exit")):
            fixture.cleanup()
        self.assertFalse(fixture._owned_session)
        self.assertIsNone(fixture._owned_pgid)
        self.assertIsNone(fixture._process)

    def test_timeout_validation_and_identity_mutation(self) -> None:
        for kwargs in ({"startup_timeout": 0}, {"startup_timeout": float("inf")}, {"poll_interval": -1}, {"poll_interval": True}):
            with self.assertRaises(ValueError):
                KernelAppFixture(**kwargs)
        fixture = KernelAppFixture(command=_python("-c", "raise SystemExit(0)"), startup_timeout=1)
        fixture._owned_session = True
        KernelAppFixture._owners[fixture.session_id] = fixture
        original = fixture.session_id
        fixture.session_id = "mutated"
        with self.assertRaises(KernelFixtureError):
            fixture.cleanup()
        fixture.session_id = original
        fixture.cleanup()

    def test_kernelapp_fixture_retains_launcher_proof_shape(self) -> None:
        fixture = KernelAppFixture()
        fixture.connection_path = Path("/tmp/ejn-test-connection.json")
        command = fixture._command()
        self.assertIn("KernelManager.connection_file", command[-1])

    def test_default_fixture_is_direct_and_has_no_proc_dependency(self) -> None:
        fixture = LocalKernelFixture()
        self.assertFalse(hasattr(fixture, "_descendant_pid"))
        with self.assertRaises(TypeError):
            LocalKernelFixture(command=_python("-c", "raise SystemExit(0)"))

    def test_foreign_loopback_connection_is_rejected(self) -> None:
        with self.assertRaises(DirectKernelFixtureError):
            LocalKernelFixture._validate_connection({"ip": "192.0.2.1"})

    @unittest.skipUnless(LocalKernelFixture.available(), "local jupyter-client kernel unavailable")
    def test_start_evaluate_cleanup_and_metadata(self) -> None:
        with LocalKernelFixture() as fixture:
            self.assertTrue(fixture.session_id.startswith("ejn-direct-"))
            self.assertIsNotNone(fixture.connection)
            self.assertEqual(fixture.kernel_pid, fixture._process.pid)
            assert fixture.connection is not None
            self.assertIn(fixture.connection.get("ip", fixture.connection.get("host")), {"127.0.0.1", "localhost", "::1"})
            reply = fixture.evaluate("1 + 1", timeout=8)
            self.assertEqual(reply.get("status"), "ok")
            path = fixture.connection_path
            pgid = fixture._owned_pgid
        self.assertIsNone(fixture._process)
        self.assertIsNotNone(path)
        self.assertFalse(path.exists())  # type: ignore[union-attr]
        self.assertIsNotNone(pgid)
        with self.assertRaises(ProcessLookupError):
            os.killpg(pgid, 0)  # type: ignore[arg-type]

    @unittest.skipUnless(LocalKernelFixture.available(), "local jupyter-client kernel unavailable")
    def test_repeated_cycles_and_idempotent_cleanup(self) -> None:
        for _ in range(2):
            fixture = LocalKernelFixture(startup_timeout=8)
            fixture.start()
            path = fixture.connection_path
            fixture.cleanup()
            fixture.cleanup()
            self.assertFalse(path and path.exists())

    def test_refuses_foreign_session_cleanup(self) -> None:
        first = KernelAppFixture(command=_python("-c", "import time; time.sleep(10)"), startup_timeout=0.05)
        first.session_id = "foreign"
        first._owned_session = True
        KernelAppFixture._owners["foreign"] = KernelAppFixture()
        try:
            with self.assertRaises(KernelFixtureError):
                first.cleanup()
        finally:
            KernelAppFixture._owners.pop("foreign", None)


if __name__ == "__main__":
    unittest.main()
