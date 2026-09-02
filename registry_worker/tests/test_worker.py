"""Adversarial tests for the bounded cross-Emacs registry worker."""

from __future__ import annotations

import fcntl
import json
import multiprocessing
import os
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

from ejn_registry_worker import worker as worker_module
from ejn_registry_worker.worker import MAX_REGISTRY_BYTES, MAX_REQUEST_BYTES, execute_request


def _request(path: str, operation: str, **fields: object) -> dict[str, object]:
    return {"v": 1, "op": operation, "path": path, **fields}


def _entry(key: str, value: str) -> dict[str, object]:
    return {"key": key, "data": {"value": value}}


def _ejn_entry(key: str, local_file: str) -> dict[str, object]:
    return {
        "key": key,
        "data": {
            "@ejn": "entry",
            "fields": [["session-id", key], ["local-file", local_file]],
        },
    }


def _concurrent_create(path: str, key: str, barrier: object, queue: object) -> None:
    barrier.wait(5)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = execute_request(
            _request(path, "create-if-absent", entry=_entry(key, key))
        )
        if result["ok"]:
            queue.put(result)
            return
        if result["error"]["code"] != "busy":
            queue.put(result)
            return
        time.sleep(0.01)
    queue.put({"ok": False, "error": {"code": "timeout"}})


def _concurrent_file_claim(
    path: str, key: str, local_file: str, barrier: object, queue: object
) -> None:
    barrier.wait(5)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = execute_request(
            _request(path, "create-if-absent", entry=_ejn_entry(key, local_file))
        )
        if result["ok"] or result["error"]["code"] != "busy":
            queue.put(result)
            return
        time.sleep(0.01)
    queue.put({"ok": False, "error": {"code": "timeout"}})


def _concurrent_replace(
    path: str,
    key: str,
    expected_revision: str,
    value: str,
    barrier: object,
    queue: object,
) -> None:
    barrier.wait(5)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        result = execute_request(
            _request(
                path,
                "replace-if-revision",
                entry=_entry(key, value),
                expected_revision=expected_revision,
            )
        )
        if result["ok"] or result["error"]["code"] != "busy":
            queue.put(result)
            return
        time.sleep(0.01)
    queue.put({"ok": False, "error": {"code": "timeout"}})


class RegistryWorkerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = tempfile.mkdtemp(prefix="ejn-registry-worker-")
        os.chmod(self.root, 0o700)
        self.path = os.path.join(self.root, "registry.json")

    def tearDown(self) -> None:
        for name in os.listdir(self.root):
            os.unlink(os.path.join(self.root, name))
        os.rmdir(self.root)

    def call(self, operation: str, **fields: object) -> dict[str, object]:
        return execute_request(_request(self.path, operation, **fields))

    def create(self, key: str, value: str = "initial") -> dict[str, object]:
        result = self.call("create-if-absent", entry=_entry(key, value))
        self.assertTrue(result["ok"], result)
        return result["result"]["entry"]

    def read(self) -> dict[str, object]:
        result = self.call("read")
        self.assertTrue(result["ok"], result)
        return result["result"]

    def run_cli_raw(self, raw: bytes) -> dict[str, object]:
        environment = os.environ.copy()
        source_root = os.path.dirname(os.path.dirname(__file__))
        environment["PYTHONPATH"] = os.pathsep.join(
            filter(None, [source_root, environment.get("PYTHONPATH")])
        )
        process = subprocess.run(
            [sys.executable, "-m", "ejn_registry_worker"],
            input=raw,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        self.assertEqual(process.returncode, 0)
        self.assertEqual(process.stderr, b"")
        self.assertTrue(process.stdout.endswith(b"\n"))
        self.assertEqual(process.stdout.count(b"\n"), 1)
        return json.loads(process.stdout)

    def test_concurrent_creates_preserve_union(self) -> None:
        """Two lock-contending workers preserve both independently created records."""
        context = multiprocessing.get_context("spawn")
        barrier = context.Barrier(2)
        queue = context.Queue()
        processes = [
            context.Process(target=_concurrent_create, args=(self.path, key, barrier, queue))
            for key in ("first", "second")
        ]
        for process in processes:
            process.start()
        for process in processes:
            process.join(10)
            self.assertEqual(process.exitcode, 0)
        results = [queue.get(timeout=2) for _ in processes]
        self.assertTrue(all(result["ok"] for result in results), results)
        entries = self.read()["entries"]
        self.assertEqual({entry["key"] for entry in entries}, {"first", "second"})

    def test_local_source_file_has_one_atomic_session_claim(self) -> None:
        """Different session keys cannot claim one canonical source pathname."""
        source = os.path.join(self.root, "notebook.py")
        with open(source, "w", encoding="utf-8") as handle:
            handle.write("# %%\n")
        first = self.call("create-if-absent", entry=_ejn_entry("first", source))
        second = self.call("create-if-absent", entry=_ejn_entry("second", source))
        self.assertTrue(first["ok"], first)
        self.assertFalse(second["ok"])
        self.assertEqual(second["error"]["code"], "conflict")
        self.assertEqual([entry["key"] for entry in self.read()["entries"]], ["first"])

    def test_local_source_lookup_resolves_alias_without_mutation(self) -> None:
        """A shared-lock lookup returns the durable owner of a source alias."""
        source = os.path.join(self.root, "notebook.py")
        symlink = os.path.join(self.root, "notebook-link.py")
        with open(source, "w", encoding="utf-8") as handle:
            handle.write("# %%\n")
        os.symlink(source, symlink)
        created = self.call("create-if-absent", entry=_ejn_entry("owner", source))
        self.assertTrue(created["ok"], created)
        before = self.read()["generation"]
        lookup = self.call("read-for-local-file", local_file=symlink)
        self.assertTrue(lookup["ok"], lookup)
        self.assertEqual(lookup["result"]["matching_entry"]["key"], "owner")
        self.assertEqual(lookup["result"]["generation"], before)

    def test_local_source_claim_rejects_symlink_and_hardlink_aliases(self) -> None:
        """Path aliases cannot evade the one-session-per-source invariant."""
        source = os.path.join(self.root, "notebook.py")
        symlink = os.path.join(self.root, "notebook-link.py")
        hardlink = os.path.join(self.root, "notebook-hardlink.py")
        with open(source, "w", encoding="utf-8") as handle:
            handle.write("# %%\n")
        os.symlink(source, symlink)
        os.link(source, hardlink)
        first = self.call("create-if-absent", entry=_ejn_entry("first", source))
        via_symlink = self.call("create-if-absent", entry=_ejn_entry("second", symlink))
        via_hardlink = self.call("create-if-absent", entry=_ejn_entry("third", hardlink))
        self.assertTrue(first["ok"], first)
        for result in (via_symlink, via_hardlink):
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"]["code"], "conflict")

    def test_concurrent_local_source_claim_has_exactly_one_winner(self) -> None:
        """The registry lock serializes different-key claims before remote launch."""
        source = os.path.join(self.root, "notebook.py")
        with open(source, "w", encoding="utf-8") as handle:
            handle.write("# %%\n")
        context = multiprocessing.get_context("spawn")
        barrier = context.Barrier(2)
        queue = context.Queue()
        processes = [
            context.Process(
                target=_concurrent_file_claim,
                args=(self.path, key, source, barrier, queue),
            )
            for key in ("first", "second")
        ]
        for process in processes:
            process.start()
        for process in processes:
            process.join(10)
            self.assertEqual(process.exitcode, 0)
        results = [queue.get(timeout=2) for _ in processes]
        self.assertEqual(sum(result["ok"] for result in results), 1, results)
        self.assertEqual(
            sum(
                not result["ok"] and result["error"]["code"] == "conflict"
                for result in results
            ),
            1,
            results,
        )
        self.assertEqual(len(self.read()["entries"]), 1)

    def test_stale_revision_cannot_remove_replacement(self) -> None:
        """A stale remove keeps a same-key replacement durable."""
        original = self.create("kernel", "old")
        replaced = self.call(
            "replace-if-revision",
            entry=_entry("kernel", "new"),
            expected_revision=original["revision"],
        )
        self.assertTrue(replaced["ok"], replaced)
        stale = self.call(
            "remove-if-revision", key="kernel", expected_revision=original["revision"]
        )
        self.assertFalse(stale["ok"])
        self.assertEqual(stale["error"]["code"], "conflict")
        entry = self.read()["entries"][0]
        self.assertEqual(entry["data"], {"value": "new"})

    def test_concurrent_exact_replacements_have_one_winner(self) -> None:
        """Two writers using one revision cannot both replace the record."""
        original = self.create("kernel", "old")
        context = multiprocessing.get_context("spawn")
        barrier = context.Barrier(2)
        queue = context.Queue()
        processes = [
            context.Process(
                target=_concurrent_replace,
                args=(
                    self.path,
                    "kernel",
                    original["revision"],
                    value,
                    barrier,
                    queue,
                ),
            )
            for value in ("first", "second")
        ]
        for process in processes:
            process.start()
        for process in processes:
            process.join(10)
            self.assertEqual(process.exitcode, 0)
        results = [queue.get(timeout=2) for _ in processes]
        self.assertEqual(sum(result["ok"] for result in results), 1, results)
        self.assertEqual(
            sum(not result["ok"] and result["error"]["code"] == "conflict" for result in results),
            1,
            results,
        )
        self.assertIn(self.read()["entries"][0]["data"]["value"], {"first", "second"})

    def test_busy_returns_without_waiting_or_prompting(self) -> None:
        """A held advisory lock produces a quick structured busy reply."""
        lock = f"{self.path}.lock"
        descriptor = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            started = time.monotonic()
            result = self.call("read")
            elapsed = time.monotonic() - started
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "busy")
        self.assertLess(elapsed, 0.25)

    def test_killed_lock_holder_releases_lock_without_cleanup(self) -> None:
        """Kernel-released flock recovery never needs stale lock deletion."""
        lock = f"{self.path}.lock"
        code = (
            "import fcntl, os, sys, time; "
            "fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600); "
            "os.fchmod(fd, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); "
            "print('locked', flush=True); time.sleep(60)"
        )
        process = subprocess.Popen(
            [sys.executable, "-c", code, lock], stdout=subprocess.PIPE, text=True
        )
        try:
            self.assertEqual(process.stdout.readline().strip(), "locked")
            self.assertEqual(self.call("read")["error"]["code"], "busy")
            process.kill()
            process.wait(timeout=5)
            result = self.call("create-if-absent", entry=_entry("recovered", "yes"))
            self.assertTrue(result["ok"], result)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            if process.stdout is not None:
                process.stdout.close()

    def test_corrupt_registry_is_preserved_without_rewrite(self) -> None:
        """Old or corrupt bytes are rejected rather than migrated or replaced."""
        original = b"(:old-elisp-registry-format)\n"
        with open(self.path, "wb") as handle:
            handle.write(original)
        os.chmod(self.path, 0o600)
        result = self.call("create-if-absent", entry=_entry("new", "value"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "corrupt")
        with open(self.path, "rb") as handle:
            self.assertEqual(handle.read(), original)

    def test_new_registry_and_lock_are_private_and_nonregular_targets_reject(self) -> None:
        """The worker creates 0600 files and refuses unsafe registry targets."""
        self.create("private")
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        self.assertEqual(os.stat(f"{self.path}.lock").st_mode & 0o777, 0o600)
        os.chmod(self.path, 0o644)
        nonprivate = self.call("read")
        self.assertFalse(nonprivate["ok"])
        self.assertEqual(nonprivate["error"]["code"], "unsafe-path")
        target = os.path.join(self.root, "directory-target")
        os.mkdir(target, 0o700)
        try:
            result = execute_request(_request(target, "read"))
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"]["code"], "unsafe-path")
        finally:
            os.rmdir(target)

    def test_oversize_and_symlink_paths_are_rejected(self) -> None:
        """Unbounded input files and symlink replacement targets are fail-closed."""
        oversized = b"x" * (MAX_REGISTRY_BYTES + 1)
        with open(self.path, "wb") as handle:
            handle.write(oversized)
        os.chmod(self.path, 0o600)
        result = self.call("read")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "registry-too-large")
        with open(self.path, "rb") as handle:
            self.assertEqual(handle.read(), oversized)
        os.unlink(self.path)
        foreign = os.path.join(self.root, "foreign.json")
        with open(foreign, "w", encoding="utf-8") as handle:
            json.dump({"foreign": True}, handle)
        os.chmod(foreign, 0o600)
        os.symlink(foreign, self.path)
        result = self.call("read")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "unsafe-path")
        with open(foreign, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle), {"foreign": True})

    def test_symlink_lock_and_parent_are_rejected_without_touching_targets(self) -> None:
        """Lock and parent symlinks cannot redirect a transaction elsewhere."""
        foreign_lock = os.path.join(self.root, "foreign.lock")
        with open(foreign_lock, "wb") as handle:
            handle.write(b"lock-target")
        os.chmod(foreign_lock, 0o600)
        os.symlink(foreign_lock, f"{self.path}.lock")
        result = self.call("read")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "unsafe-path")
        with open(foreign_lock, "rb") as handle:
            self.assertEqual(handle.read(), b"lock-target")
        os.unlink(f"{self.path}.lock")

        foreign_directory = tempfile.mkdtemp(prefix="ejn-registry-parent-")
        foreign_path = os.path.join(foreign_directory, "registry.json")
        original = b'{"foreign":true}\n'
        try:
            with open(foreign_path, "wb") as handle:
                handle.write(original)
            os.chmod(foreign_path, 0o600)
            parent_link = os.path.join(self.root, "parent-link")
            os.symlink(foreign_directory, parent_link)
            result = execute_request(
                _request(os.path.join(parent_link, "registry.json"), "read")
            )
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"]["code"], "unsafe-path")
            with open(foreign_path, "rb") as handle:
                self.assertEqual(handle.read(), original)
        finally:
            if os.path.lexists(os.path.join(self.root, "parent-link")):
                os.unlink(os.path.join(self.root, "parent-link"))
            os.unlink(foreign_path)
            os.rmdir(foreign_directory)

    def test_pre_replace_failure_keeps_existing_registry(self) -> None:
        """A failure before atomic replacement leaves the old valid state intact."""
        original = self.create("stable", "old")
        before_stat = os.stat(self.path)
        before_names = set(os.listdir(self.root))

        def fail_before_replace(_temporary: str, _target: str) -> None:
            raise RuntimeError("injected")

        result = execute_request(
            _request(
                self.path,
                "replace-if-revision",
                entry=_entry("stable", "new"),
                expected_revision=original["revision"],
            ),
            before_replace=fail_before_replace,
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "write-failed")
        entry = self.read()["entries"][0]
        self.assertEqual(entry["revision"], original["revision"])
        self.assertEqual(entry["data"], {"value": "old"})
        after_stat = os.stat(self.path)
        self.assertEqual(after_stat.st_ino, before_stat.st_ino)
        self.assertEqual(set(os.listdir(self.root)), before_names)

    def test_directory_fsync_failure_reports_committed_state(self) -> None:
        """A post-replace directory fsync failure is explicit and recoverable."""
        original = self.create("durable", "old")
        real_fsync = worker_module.os.fsync

        def fail_directory_fsync(descriptor: int) -> None:
            if stat.S_ISDIR(os.fstat(descriptor).st_mode):
                raise OSError("injected directory fsync failure")
            real_fsync(descriptor)

        with mock.patch.object(worker_module.os, "fsync", side_effect=fail_directory_fsync):
            result = self.call(
                "replace-if-revision",
                entry=_entry("durable", "new"),
                expected_revision=original["revision"],
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "durability-uncertain")
        self.assertTrue(result.get("committed"))
        self.assertEqual(self.read()["entries"][0]["data"], {"value": "new"})

    def test_unlock_failure_after_commit_reports_committed_state(self) -> None:
        """A failed unlock cannot disguise a mutation that already landed."""
        real_flock = worker_module.fcntl.flock

        def fail_unlock(descriptor: int, operation: int) -> None:
            if operation == fcntl.LOCK_UN:
                raise OSError("injected unlock failure")
            real_flock(descriptor, operation)

        with mock.patch.object(worker_module.fcntl, "flock", side_effect=fail_unlock):
            result = self.call("create-if-absent", entry=_entry("unlocked", "landed"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "durability-uncertain")
        self.assertTrue(result.get("committed"))
        self.assertEqual(self.read()["entries"][0]["data"], {"value": "landed"})

    def test_fifo_registry_target_is_rejected_without_blocking(self) -> None:
        """Opening a FIFO never blocks before regular-file validation."""
        os.mkfifo(self.path, 0o600)
        started = time.monotonic()
        result = self.call("read")
        self.assertLess(time.monotonic() - started, 0.25)
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "unsafe-path")

    def test_post_replace_registry_error_reports_committed_state(self) -> None:
        """Every exception after replacement is durability-uncertain."""
        original = self.create("post-replace", "old")
        injected = worker_module.RegistryWorkerError(
            "unsafe-path", "injected post-replace validation failure"
        )
        with mock.patch.object(
            worker_module.RegistryTransaction, "_fsync_parent", side_effect=injected
        ):
            result = self.call(
                "replace-if-revision",
                entry=_entry("post-replace", "new"),
                expected_revision=original["revision"],
            )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "durability-uncertain")
        self.assertTrue(result.get("committed"))
        self.assertEqual(self.read()["entries"][0]["data"], {"value": "new"})

    def test_generation_exhaustion_preserves_valid_registry(self) -> None:
        """The largest valid generation cannot be incremented into corruption."""
        original = self.create("generation", "old")
        with open(self.path, "r", encoding="ascii") as handle:
            state = json.load(handle)
        state["generation"] = worker_module.MAX_SAFE_JSON_INTEGER
        raw = worker_module._canonical_json(state)
        with open(self.path, "wb") as handle:
            handle.write(raw)
        os.chmod(self.path, 0o600)
        before = os.stat(self.path)

        result = self.call(
            "replace-if-revision",
            entry=_entry("generation", "new"),
            expected_revision=original["revision"],
        )

        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "generation-exhausted")
        self.assertEqual(os.stat(self.path).st_ino, before.st_ino)
        with open(self.path, "rb") as handle:
            self.assertEqual(handle.read(), raw)
        self.assertEqual(self.read()["generation"], worker_module.MAX_SAFE_JSON_INTEGER)

    def test_new_parent_components_are_fsynced_before_registry_creation(self) -> None:
        """Each mkdir is linked durably before files are created beneath it."""
        with tempfile.TemporaryDirectory(prefix="parents-", dir=self.root) as subtree:
            nested_parent = os.path.join(subtree, "first", "second")
            nested_path = os.path.join(nested_parent, "registry.json")
            calls: list[str] = []
            real_fsync_directory = worker_module._fsync_directory

            def record_fsync(path: str) -> None:
                calls.append(path)
                real_fsync_directory(path)

            with mock.patch.object(
                worker_module, "_fsync_directory", side_effect=record_fsync
            ):
                result = execute_request(
                    _request(
                        nested_path,
                        "create-if-absent",
                        entry=_entry("nested", "value"),
                    )
                )
            self.assertTrue(result["ok"], result)
            self.assertEqual(calls[:2], [subtree, os.path.join(subtree, "first")])
            self.assertEqual(calls[-1], nested_parent)

        with tempfile.TemporaryDirectory(prefix="parents-fail-", dir=self.root) as subtree:
            nested_parent = os.path.join(subtree, "first", "second")
            nested_path = os.path.join(nested_parent, "registry.json")
            with mock.patch.object(
                worker_module,
                "_fsync_directory",
                side_effect=OSError("injected parent fsync failure"),
            ):
                result = execute_request(_request(nested_path, "read"))
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"]["code"], "unsafe-path")
            self.assertFalse(os.path.exists(nested_path))
            self.assertFalse(os.path.exists(f"{nested_path}.lock"))

    def test_registry_requires_a_supported_local_filesystem(self) -> None:
        """Network, unknown, and unsupported-platform storage fails before locking."""
        if sys.platform.startswith("linux"):
            self.assertIn(
                worker_module._linux_filesystem_type(self.root),
                worker_module._LINUX_LOCAL_FILESYSTEMS,
            )
        self.assertEqual(
            worker_module._decode_mountinfo_path(b"/tmp/space\\040tab\\011slash\\134"),
            b"/tmp/space tab\tslash\\",
        )
        with mock.patch.object(
            worker_module, "_linux_filesystem_type", return_value="nfs"
        ):
            result = self.call("read")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "unsafe-filesystem")
        self.assertFalse(os.path.exists(f"{self.path}.lock"))

        self.assertEqual(worker_module.ctypes.sizeof(worker_module._DarwinStatFs64), 2168)
        self.assertEqual(worker_module._DarwinStatFs64.f_flags.offset, 64)
        with mock.patch.object(worker_module.sys, "platform", "darwin"), mock.patch.object(
            worker_module, "_darwin_filesystem", return_value=("apfs", False)
        ):
            result = self.call("read")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "unsafe-filesystem")

        for filesystem in ("tmpfs", "ramfs"):
            with mock.patch.object(
                worker_module, "_linux_filesystem_type", return_value=filesystem
            ):
                result = self.call("read")
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"]["code"], "unsafe-filesystem")

        with mock.patch.object(worker_module.sys, "platform", "darwin"), mock.patch.object(
            worker_module, "_darwin_filesystem", return_value=("nfs", True)
        ):
            result = self.call("read")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "unsafe-filesystem")

        with mock.patch.object(worker_module.sys, "platform", "plan9"):
            result = self.call("read")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "unsafe-filesystem")

    def test_cli_rejects_oversized_one_shot_request(self) -> None:
        """The executable emits one bounded error rather than reading forever."""
        environment = os.environ.copy()
        source_root = os.path.dirname(os.path.dirname(__file__))
        environment["PYTHONPATH"] = os.pathsep.join(
            filter(None, [source_root, environment.get("PYTHONPATH")])
        )
        process = subprocess.run(
            [sys.executable, "-m", "ejn_registry_worker"],
            input=b" " * (MAX_REQUEST_BYTES + 1),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            check=False,
        )
        self.assertEqual(process.returncode, 0)
        self.assertEqual(process.stderr, b"")
        response = json.loads(process.stdout)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "request-too-large")

    def test_duplicate_json_keys_and_fields_are_rejected(self) -> None:
        """The wire and stored formats reject ambiguous duplicate objects."""
        duplicate_request = (
            '{"v":1,"op":"read","op":"read","path":'
            + json.dumps(self.path)
            + "}"
        ).encode()
        response = self.run_cli_raw(duplicate_request)
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "invalid-request")

        duplicate_registry = (
            b'{"v":1,"generation":0,"entries":[],"entries":[]}'
        )
        with open(self.path, "wb") as handle:
            handle.write(duplicate_registry)
        os.chmod(self.path, 0o600)
        result = self.call("read")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "corrupt")
        with open(self.path, "rb") as handle:
            self.assertEqual(handle.read(), duplicate_registry)

    def test_nested_data_and_entry_capacity_are_bounded(self) -> None:
        """Deep values and the entry-count ceiling fail before any write."""
        nested: object = "leaf"
        for _ in range(worker_module.MAX_JSON_DEPTH + 1):
            nested = [nested]
        result = self.call("create-if-absent", entry={"key": "deep", "data": {"value": nested}})
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "invalid-request")
        for index in range(worker_module.MAX_ENTRIES):
            result = self.call(
                "create-if-absent", entry=_entry(f"entry-{index}", "value")
            )
            self.assertTrue(result["ok"], result)
        result = self.call(
            "create-if-absent", entry=_entry("one-too-many", "value")
        )
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"]["code"], "capacity")
        self.assertEqual(len(self.read()["entries"]), worker_module.MAX_ENTRIES)

    def test_batch_prune_removes_only_exact_revisions(self) -> None:
        """Mixed stale and current prune targets cannot remove the replacement."""
        stale = self.create("stale", "old")
        current = self.create("current", "present")
        replaced = self.call(
            "replace-if-revision",
            entry=_entry("stale", "new"),
            expected_revision=stale["revision"],
        )
        self.assertTrue(replaced["ok"], replaced)
        result = self.call(
            "prune-if-revision",
            targets=[
                {"key": "stale", "expected_revision": stale["revision"]},
                {"key": "current", "expected_revision": current["revision"]},
            ],
        )
        self.assertTrue(result["ok"], result)
        self.assertEqual(result["result"]["removed"], ["current"])
        self.assertEqual(result["result"]["retained"], ["stale"])
        entries = self.read()["entries"]
        self.assertEqual(len(entries), 1)
        self.assertEqual(entries[0]["data"], {"value": "new"})


if __name__ == "__main__":
    unittest.main()
