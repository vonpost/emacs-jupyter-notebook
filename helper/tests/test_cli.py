import os
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

from ejn_helper import __version__

HELPER_ROOT = Path(__file__).resolve().parents[1]
PYPROJECT = HELPER_ROOT / "pyproject.toml"


class CliTests(unittest.TestCase):
    def run_cli(self, *args, extra_pythonpath=()):
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

    def test_missing_dependency_is_bounded(self):
        with tempfile.TemporaryDirectory() as directory:
            blocker = Path(directory)
            (blocker / "sitecustomize.py").write_text(
                "import builtins\n"
                "real_import = builtins.__import__\n"
                "def blocked(name, *args, **kwargs):\n"
                "    if name == 'jupyter_client' or name.startswith('jupyter_client.'):\n"
                "        raise ModuleNotFoundError('blocked by test')\n"
                "    return real_import(name, *args, **kwargs)\n"
                "builtins.__import__ = blocked\n",
                encoding="utf-8",
            )
            result = self.run_cli("--protocol", extra_pythonpath=(blocker,))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertEqual(
            result.stderr,
            "ejn-helper: protocol runtime unavailable; install jupyter_client and pyzmq\n",
        )
        self.assertLess(len(result.stderr), 128)

    def test_protocol_mode_with_stub_runtime_is_silent(self):
        with tempfile.TemporaryDirectory() as directory:
            stubs = Path(directory)
            (stubs / "jupyter_client.py").write_text("", encoding="utf-8")
            (stubs / "zmq.py").write_text("", encoding="utf-8")
            result = self.run_cli("--protocol", extra_pythonpath=(stubs,))
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
