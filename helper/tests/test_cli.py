import io
import os
import select
import signal
import subprocess
import sys
import time
import tomllib
import unittest
from unittest import mock
from pathlib import Path

from ejn_helper import __version__
from ejn_helper.__main__ import main
from ejn_helper.framing import Decoder, encode

HELPER_ROOT = Path(__file__).resolve().parents[1]
PYPROJECT = HELPER_ROOT / "pyproject.toml"


class CliTests(unittest.TestCase):
    def read_exact(self, pipe, size, timeout=5):
        deadline = time.monotonic() + timeout
        data = bytearray()
        while len(data) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            ready, _write, _error = select.select([pipe], [], [], remaining)
            if not ready:
                break
            chunk = os.read(pipe.fileno(), size - len(data))
            if not chunk:
                break
            data.extend(chunk)
        return bytes(data)

    def run_cli(self, *args, extra_pythonpath=(), input_text=None):
        merged = os.environ.copy()
        merged["PYTHONPATH"] = os.pathsep.join(
            [*(str(path) for path in extra_pythonpath), str(HELPER_ROOT)]
        )
        return subprocess.run(
            [sys.executable, "-m", "ejn_helper", *args],
            cwd=HELPER_ROOT,
            env=merged,
            text=True,
            capture_output=True,
            input=input_text,
            timeout=5,
            check=False,
        )

    def test_module_version(self):
        result = self.run_cli("--version")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.strip(), "0.1.0")
        self.assertEqual(result.stderr, "")

    def test_console_script_targets_main(self):
        project = tomllib.loads(PYPROJECT.read_text(encoding="utf-8"))
        self.assertEqual(
            project["project"]["scripts"]["ejn-helper"],
            "ejn_helper.__main__:main",
        )

    def test_package_and_cli_versions_match(self):
        project = tomllib.loads(PYPROJECT.read_text(encoding="utf-8"))
        self.assertEqual(project["project"]["version"], __version__)

    def test_no_protocol_stdout(self):
        result = self.run_cli()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(len(result.stderr.splitlines()), 1)

    def test_invalid_option_has_no_stdout(self):
        result = self.run_cli("--not-an-option")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")

    def test_protocol_mode_clean_eof_is_local_and_silent(self):
        result = self.run_cli("--protocol", input_text="")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")

    def test_protocol_subprocess_golden_hello_ping_transcript(self):
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(HELPER_ROOT)
        transcript = (
            encode(
                {"v": 1, "kind": "request", "id": "hello-1", "op": "hello", "params": {"versions": [1]}},
                1_048_576,
            )
            + encode(
                {"v": 1, "kind": "request", "id": "ping-1", "op": "ping", "params": {}},
                1_048_576,
            )
        )
        result = subprocess.run(
            [sys.executable, "-m", "ejn_helper", "--protocol"],
            cwd=HELPER_ROOT,
            env=environment,
            input=transcript,
            capture_output=True,
            timeout=5,
            check=False,
        )
        decoder = Decoder(1_048_576)
        frames = decoder.feed(result.stdout)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr, b"")
        self.assertFalse(decoder.partial_frame)
        self.assertEqual([frame["id"] for frame in frames], ["hello-1", "ping-1"])
        self.assertTrue(all(frame["ok"] for frame in frames))
        self.assertEqual(frames[-1]["result"], {"alive": True})

    def test_protocol_top_level_runtime_failure_is_fixed_and_traceback_free(self):
        async def fail_runtime():
            raise RuntimeError("private runtime detail")

        stderr, stdout = io.StringIO(), io.StringIO()
        with (
            mock.patch("ejn_helper.runtime.run_stdio", fail_runtime),
            mock.patch.object(sys, "stderr", stderr),
            mock.patch.object(sys, "stdout", stdout),
        ):
            self.assertEqual(main(["--protocol"]), 2)
        self.assertEqual(stdout.getvalue(), "")
        self.assertEqual(stderr.getvalue(), "ejn-helper: transport-error\n")
        self.assertNotIn("private", stderr.getvalue())
        self.assertNotIn("Traceback", stderr.getvalue())

    def test_protocol_sigterm_silent_peer_exits_without_protocol_garbage(self):
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(HELPER_ROOT)
        process = subprocess.Popen(
            [sys.executable, "-m", "ejn_helper", "--protocol"],
            cwd=HELPER_ROOT,
            env=environment,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        try:
            assert process.stdin is not None and process.stdout is not None
            process.stdin.write(
                encode(
                    {"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {"versions": [1]}},
                    1_048_576,
                )
            )
            process.stdin.flush()
            prefix = self.read_exact(process.stdout, 4)
            self.assertEqual(len(prefix), 4)
            payload_size = int.from_bytes(prefix, "big")
            payload = self.read_exact(process.stdout, payload_size)
            self.assertEqual(len(payload), payload_size)
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=5)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=1)
        self.assertEqual(process.returncode, 0)
        self.assertEqual(stdout, b"")
        self.assertEqual(stderr, b"")


if __name__ == "__main__":
    unittest.main()
