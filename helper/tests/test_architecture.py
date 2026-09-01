"""Static no-hang architecture checks for the production helper.

These checks parse Python rather than grepping source text.  AST names and
calls exclude comments and docstrings, so documentation can describe a
forbidden design without accidentally making the production architecture
test fail.
"""

from __future__ import annotations

import ast
import math
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).parents[1] / "ejn_helper"


def _production_files() -> tuple[Path, ...]:
    return tuple(sorted(ROOT.glob("*.py")))


def _tree(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _names(tree: ast.AST) -> set[str]:
    result: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            result.add(node.id)
        elif isinstance(node, ast.Attribute):
            result.add(node.attr)
        elif isinstance(node, ast.alias):
            result.add(node.name)
            if node.asname:
                result.add(node.asname)
        elif isinstance(node, ast.ImportFrom) and node.module:
            result.add(node.module)
        elif isinstance(node, ast.keyword) and node.arg:
            result.add(node.arg)
    return result


def _string_constants(tree: ast.AST) -> set[str]:
    """Return string literals used by the parsed module."""
    result: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Constant) and isinstance(node.value, str):
            result.add(node.value)
    return result


def _calls(tree: ast.AST) -> list[ast.Call]:
    return [node for node in ast.walk(tree) if isinstance(node, ast.Call)]


def _qualified_name(node: ast.AST) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        parent = _qualified_name(node.value)
        return f"{parent}.{node.attr}" if parent else node.attr
    return None


def _process_launches(tree: ast.AST) -> list[ast.Call]:
    """Find statically named process-launch calls, including import aliases.

    The helper boundary forbids more than ``subprocess``: an ``asyncio`` child,
    an ``os.spawn*``/``exec*`` call, a PTY child, or a process pool can wedge or
    silently expand the same authority.  Resolve the standard launch families
    without treating unrelated methods named ``run`` or ``start`` as children.
    """
    launch_apis = {
        "subprocess": {"Popen", "run", "call", "check_call", "check_output"},
        "asyncio": {"create_subprocess_exec", "create_subprocess_shell"},
        "os": {
            "system", "popen", "fork", "forkpty", "posix_spawn", "posix_spawnp",
            "spawnl", "spawnle", "spawnlp", "spawnlpe", "spawnv", "spawnve",
            "spawnvp", "spawnvpe", "execl", "execle", "execlp", "execlpe",
            "execv", "execve", "execvp", "execvpe",
        },
        "pty": {"spawn", "fork"},
        "multiprocessing": {"Process", "Pool"},
        "concurrent.futures": {"ProcessPoolExecutor"},
    }
    module_aliases = {module: {module} for module in launch_apis}
    imported_launches: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in launch_apis:
                    module_aliases[alias.name].add(alias.asname or alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module in launch_apis:
            for alias in node.names:
                if alias.name in launch_apis[node.module]:
                    imported_launches.add(alias.asname or alias.name)

    launches = []
    for call in _calls(tree):
        if isinstance(call.func, ast.Name):
            if call.func.id in imported_launches:
                launches.append(call)
        elif isinstance(call.func, ast.Attribute):
            qualified = _qualified_name(call.func)
            if qualified:
                prefix = qualified.rsplit(".", 1)[0]
                for module, aliases in module_aliases.items():
                    if prefix in aliases and call.func.attr in launch_apis[module]:
                        launches.append(call)
                        break
    return launches


def _assert_no_forbidden_names(source: str, forbidden: set[str]) -> None:
    names = _names(ast.parse(source))
    overlap = names & forbidden
    if overlap:
        raise AssertionError(f"forbidden production names: {sorted(overlap)}")


def _assert_thumbnail_launch(source: str) -> None:
    tree = ast.parse(source)
    launches = _process_launches(tree)
    if len(launches) != 1:
        raise AssertionError(f"expected one fixed subprocess launch, got {len(launches)}")
    launch = launches[0]
    if len(launch.args) != 1 or not isinstance(launch.args[0], ast.Call):
        raise AssertionError("worker executable is not fixed by _worker_argv")
    worker_argv = launch.args[0]
    if (
        _qualified_name(worker_argv.func) != "_worker_argv"
        or worker_argv.args
        or worker_argv.keywords
    ):
        raise AssertionError("worker executable accepts caller arguments")
    keyword_names = {keyword.arg for keyword in launch.keywords if keyword.arg}
    required = {"stdin", "stdout", "stderr", "close_fds", "shell", "start_new_session", "env"}
    if not required <= keyword_names:
        raise AssertionError(f"worker launch missing controls: {sorted(required - keyword_names)}")
    keywords = {keyword.arg: keyword.value for keyword in launch.keywords if keyword.arg}
    if _qualified_name(keywords["stdin"]) != "input_fd":
        raise AssertionError("worker stdin is not the pinned inherited input fd")
    if _qualified_name(keywords["stdout"]) != "output_fd":
        raise AssertionError("worker stdout is not the pinned inherited output fd")
    if _qualified_name(keywords["stderr"]) != "subprocess.DEVNULL":
        raise AssertionError("worker stderr is not discarded")
    for name, expected in (("close_fds", True), ("shell", False), ("start_new_session", True)):
        value = keywords[name]
        if not isinstance(value, ast.Constant) or value.value is not expected:
            raise AssertionError(f"worker {name} is not fixed to {expected!r}")

    argv_functions = [
        node for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
        and node.name == "_worker_argv"
    ]
    if len(argv_functions) != 1:
        raise AssertionError("fixed worker argv helper is missing or duplicated")
    argv_function = argv_functions[0]
    if (
        argv_function.args.posonlyargs
        or argv_function.args.args
        or argv_function.args.kwonlyargs
        or argv_function.args.vararg
        or argv_function.args.kwarg
    ):
        raise AssertionError("worker argv helper accepts caller arguments")
    returns = [node for node in ast.walk(argv_function) if isinstance(node, ast.Return)]
    if len(returns) != 1 or not isinstance(returns[0].value, ast.Tuple):
        raise AssertionError("worker argv is not a fixed three-item tuple")
    values = returns[0].value.elts
    if len(values) != 3:
        raise AssertionError("worker argv is not a fixed three-item tuple")
    if _qualified_name(values[0]) != "sys.executable":
        raise AssertionError("worker executable is not the Python interpreter")
    if not isinstance(values[1], ast.Constant) or values[1].value != "-I":
        raise AssertionError("worker interpreter is not isolated")
    worker_path = values[2]
    worker_path_call = (
        worker_path.args[0]
        if isinstance(worker_path, ast.Call)
        and len(worker_path.args) == 1
        and isinstance(worker_path.args[0], ast.Call)
        else None
    )
    path_constructor = (
        worker_path_call.func.value
        if isinstance(worker_path_call, ast.Call)
        and isinstance(worker_path_call.func, ast.Attribute)
        and worker_path_call.func.attr == "with_name"
        else None
    )
    if (
        not isinstance(worker_path, ast.Call)
        or _qualified_name(worker_path.func) != "str"
        or len(worker_path.args) != 1
        or worker_path.keywords
        or not isinstance(worker_path_call, ast.Call)
        or not isinstance(worker_path_call.func, ast.Attribute)
        or worker_path_call.func.attr != "with_name"
        or len(worker_path_call.args) != 1
        or not isinstance(worker_path_call.args[0], ast.Constant)
        or worker_path_call.args[0].value != "thumbnail_worker.py"
        or worker_path_call.keywords
        or not isinstance(path_constructor, ast.Call)
        or _qualified_name(path_constructor.func) != "Path"
        or len(path_constructor.args) != 1
        or not isinstance(path_constructor.args[0], ast.Name)
        or path_constructor.args[0].id != "__file__"
        or path_constructor.keywords
    ):
        raise AssertionError("worker path is not fixed to thumbnail_worker.py")


def _assert_worker_safety(source: str) -> None:
    tree = ast.parse(source)
    worker = _function(tree, "run_worker")
    signal_group = _function(tree, "_signal_process_group")
    names = _names(worker)
    if "shell" not in names or "start_new_session" not in names:
        raise AssertionError("worker process-group isolation controls are absent")
    if not _calls_named(worker, {"time.monotonic"}):
        raise AssertionError("worker deadline is not monotonic")
    if not _calls_named(signal_group, {"os.killpg"}):
        raise AssertionError("worker process-group termination is absent")
    if not _calls_named(signal_group, {"process.send_signal"}):
        raise AssertionError("worker process-group termination is absent")
    if "DEVNULL" not in names:
        raise AssertionError("worker output is not bounded/discarded")


def _function(tree: ast.AST, name: str) -> ast.FunctionDef | ast.AsyncFunctionDef:
    functions = [
        node for node in ast.walk(tree)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name == name
    ]
    if len(functions) != 1:
        raise AssertionError(f"expected exactly one {name} function")
    return functions[0]


def _calls_named(tree: ast.AST, qualified_names: set[str]) -> list[ast.Call]:
    return [
        call for call in _calls(tree)
        if _qualified_name(call.func) in qualified_names
    ]


def _assert_no_base64_identifier(source: str) -> None:
    if "base64" in _names(ast.parse(source)):
        raise AssertionError("base64 must not cross the event encoder")


def _assert_finite_limits(values: list[object]) -> None:
    if not all(
        type(value) is int and 0 < value < 2**63
        for value in values
    ):
        raise AssertionError("protocol limits must be finite positive integers")


class ArchitectureTests(unittest.TestCase):
    def test_production_has_no_kernel_manager_or_kernel_launch_api(self):
        forbidden = {
            "AsyncKernelManager", "KernelManager", "start_kernel",
            "launch_kernel", "kernel_manager", "kernel_spec_manager",
        }
        for path in _production_files():
            _assert_no_forbidden_names(path.read_text(encoding="utf-8"), forbidden)

    def test_production_has_no_general_subprocess_launch(self):
        launches: list[tuple[Path, ast.Call]] = []
        for path in _production_files():
            launches.extend((path, call) for call in _process_launches(_tree(path)))
        self.assertEqual([path.name for path, _ in launches], ["thumbnail.py"])
        _assert_thumbnail_launch(launches[0][0].read_text(encoding="utf-8"))

    def test_worker_has_fixed_command_fds_and_isolation(self):
        source = (ROOT / "thumbnail.py").read_text(encoding="utf-8")
        _assert_thumbnail_launch(source)
        _assert_worker_safety(source)
        tree = _tree(ROOT / "thumbnail_worker.py")
        names = _names(tree) | _string_constants(tree)
        for required in {"RLIMIT_CPU", "RLIMIT_FSIZE", "RLIMIT_NOFILE",
                         "RLIMIT_CORE", "RLIMIT_AS", "setrlimit",
                         "EJN_MAX_SOURCE_PIXELS", "EJN_MAX_PREVIEW_DIMENSION",
                         "EJN_MAX_PREVIEW_BYTES"}:
            self.assertIn(required, names)
        limit_calls = _calls_named(tree, {"_set_limit"})
        limit_names = {
            call.args[0].value
            for call in limit_calls
            if call.args
            and isinstance(call.args[0], ast.Constant)
            and isinstance(call.args[0].value, str)
        }
        self.assertTrue({"RLIMIT_CPU", "RLIMIT_FSIZE", "RLIMIT_NOFILE",
                         "RLIMIT_CORE", "RLIMIT_AS"} <= limit_names)
        main = _function(tree, "main")
        limit_lines = [
            call.lineno for call in _calls_named(main, {"apply_limits"})
        ]
        pillow_lines = [
            node.lineno for node in ast.walk(main)
            if isinstance(node, ast.ImportFrom) and node.module == "PIL"
        ]
        self.assertTrue(limit_lines and pillow_lines and min(limit_lines) < min(pillow_lines))

    def test_no_base64_identifier_in_event_encoder_modules(self):
        for name in ("flow.py", "dispatcher.py", "runtime.py", "framing.py", "outputs.py"):
            _assert_no_base64_identifier((ROOT / name).read_text(encoding="utf-8"))

    def test_protocol_frame_and_queue_limits_are_finite(self):
        from ejn_helper import dispatcher, flow, framing, runtime

        values = [
            flow.EJN_MAX_TO_EMACS_FRAME,
            flow.EJN_MAX_RESPONSE_FRAME,
            flow.EJN_MAX_EVENT_QUEUE,
            flow.EJN_MAX_PRIORITY_QUEUE,
            flow.EJN_MAX_EVENT_CREDIT,
            flow.EJN_STREAM_CHUNK_BYTES,
            flow.EJN_MAX_INFLIGHT_REQUESTS,
            dispatcher.EJN_MAX_CODE_BYTES,
            framing._check_limits(5),
            runtime.EJN_MAX_RAW_ACCUMULATOR,
        ]
        _assert_finite_limits(values)
        self.assertTrue(all(math.isfinite(float(value)) for value in values))

    def test_stripped_source_fixture_ignores_comments_and_docstrings(self):
        source = textwrap.dedent('''
        # AsyncKernelManager and subprocess.Popen are documentation only.
        """KernelManager start_kernel subprocess.run"""
        value = 1
        ''')
        _assert_no_forbidden_names(source, {
            "AsyncKernelManager", "KernelManager", "start_kernel", "Popen", "run"
        })
        self.assertEqual(_process_launches(ast.parse(source)), [])

    def test_mutation_fixture_detects_manager_import_and_launch(self):
        with self.assertRaises(AssertionError):
            _assert_no_forbidden_names(
                "from jupyter_client import AsyncKernelManager\n"
                "manager = AsyncKernelManager()\n"
                "manager.start_kernel()\n",
                {"AsyncKernelManager", "KernelManager", "start_kernel"},
            )

    def test_mutation_fixture_detects_arbitrary_process_launch(self):
        tree = ast.parse("import subprocess\nsubprocess.run(command, shell=True)\n")
        self.assertEqual(len(_process_launches(tree)), 1)
        with self.assertRaises(AssertionError):
            _assert_thumbnail_launch(ast.unparse(tree))
        imported = ast.parse("from subprocess import Popen\nPopen(command)\n")
        self.assertEqual(len(_process_launches(imported)), 1)
        aliased = ast.parse("import subprocess as sp\nsp.Popen(command)\n")
        self.assertEqual(len(_process_launches(aliased)), 1)

    def test_mutation_fixture_detects_subprocess_module_alias(self):
        source = "import subprocess as child_process\nchild_process.run(command)\n"
        self.assertEqual(len(_process_launches(ast.parse(source))), 1)

    def test_mutation_fixture_detects_non_subprocess_launch_families(self):
        fixtures = (
            "import asyncio as aio\naio.create_subprocess_shell(command)\n",
            "from os import posix_spawnp as launch\nlaunch(command, argv, env)\n",
            "import os\nos.execve(command, argv, env)\n",
            "import pty\npty.spawn(command)\n",
            "from multiprocessing import Process\nProcess(target=work)\n",
            "import concurrent.futures as futures\nfutures.ProcessPoolExecutor()\n",
        )
        for source in fixtures:
            with self.subTest(source=source):
                self.assertEqual(len(_process_launches(ast.parse(source))), 1)

    def test_mutation_fixture_detects_unpinned_worker_controls(self):
        source = textwrap.dedent('''
        import subprocess
        def run_worker(input_fd, output_fd, command):
            subprocess.Popen(command, stdin=input_fd, stdout=output_fd,
                             stderr=subprocess.PIPE, shell=True,
                             close_fds=False, start_new_session=False)
        ''')
        with self.assertRaises(AssertionError):
            _assert_thumbnail_launch(source)

    def test_mutation_fixture_detects_missing_monotonic_kill_and_limits(self):
        with self.assertRaises(AssertionError):
            _assert_worker_safety("import subprocess\nsubprocess.Popen([])\n")

    def test_mutation_fixture_detects_each_worker_safety_control(self):
        controls = {
            "shell": "shell",
            "start_new_session": "start_new_session",
            "monotonic": "time.monotonic()",
            "killpg": "os.killpg(1, signal.SIGTERM)",
            "send_signal": "process.send_signal(signal.SIGTERM)",
            "DEVNULL": "subprocess.DEVNULL",
        }
        for missing in controls:
            body = "\n".join(
                f"    {line}" for name, line in controls.items() if name != missing
            )
            with self.subTest(missing=missing), self.assertRaises(AssertionError):
                _assert_worker_safety(
                    "import os, signal, subprocess, time\n"
                    "def _signal_process_group(process, signal_number):\n"
                    f"{body}\n"
                    "def run_worker(input_fd, output_fd):\n"
                    f"{body}\n"
                )

    def test_mutation_fixture_detects_base64_and_unbounded_limits(self):
        with self.assertRaises(AssertionError):
            _assert_no_base64_identifier("import base64\nencode = base64.b64encode\n")
        with self.assertRaises(AssertionError):
            _assert_no_base64_identifier("from base64 import b64encode\n")
        with self.assertRaises(AssertionError):
            _assert_finite_limits([262144, None, 1048576])


if __name__ == "__main__":
    unittest.main()
