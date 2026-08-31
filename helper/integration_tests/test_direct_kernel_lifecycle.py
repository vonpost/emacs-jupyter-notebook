"""Contract tests for the test-owned direct kernelspec launcher."""

from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from queue import Empty

from direct_kernel_fixture import (
    MAX_KERNELSPEC_JSON_BYTES,
    DirectKernelFixture,
    DirectKernelFixtureError,
    close_installed_sync_event_loop,
    resolve_kernelspec_document,
)


def _spec_document(resource_dir: Path, argv: list[object], env: object = None) -> bytes:
    if env is None:
        env = {}
    return json.dumps(
        {
            "kernelspecs": {
                "test": {
                    "resource_dir": str(resource_dir),
                    "spec": {"argv": argv, "env": env},
                }
            }
        }
    ).encode("utf-8")


def _wait_message(
    client, channel: str, message_id: str, message_type: str, timeout: float
) -> dict:
    deadline = time.monotonic() + timeout
    getter = getattr(client, f"get_{channel}_msg")
    while time.monotonic() < deadline:
        try:
            message = getter(timeout=max(0.05, deadline - time.monotonic()))
        except Empty:
            continue
        if (
            message.get("msg_type") == message_type
            and message.get("parent_header", {}).get("msg_id") == message_id
        ):
            return message
    raise TimeoutError(f"timed out waiting for {message_type}")


def _wait_status(client, message_id: str, state: str, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        message = _wait_message(
            client,
            "iopub",
            message_id,
            "status",
            max(0.05, deadline - time.monotonic()),
        )
        if message.get("content", {}).get("execution_state") == state:
            return message
    raise TimeoutError(f"timed out waiting for status={state}")


def _execute(client, source: str, timeout: float = 8) -> dict:
    message_id = client.execute(source)
    return _wait_message(client, "shell", message_id, "execute_reply", timeout)


class DirectKernelSpecTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.resource = self.root / "resource dir"
        self.resource.mkdir()
        self.connection = self.root / "connection file.json"

    def _resolve(self, argv: list[object], env: object = None):
        return resolve_kernelspec_document(
            _spec_document(self.resource, argv, env),
            "test",
            str(self.connection),
            base_environment={"EJN_RESOURCE_ROOT": str(self.resource)},
        )

    def test_resolves_documented_embedded_placeholders_and_bare_python(self) -> None:
        spec = self._resolve(
            [
                "python3",
                "--connection-file={connection_file}",
                "{resource_dir}",
                "argument with spaces;$(not-a-shell)",
            ],
            {
                "EJN_RESOURCE": "prefix:$EJN_RESOURCE_ROOT",
                "EJN_LITERAL_UNSET": "$UNSET",
            },
        )
        self.assertEqual(spec.argv[0], sys.executable)
        self.assertEqual(spec.argv[1], f"--connection-file={self.connection}")
        self.assertEqual(spec.argv[2], str(self.resource))
        self.assertEqual(spec.argv[3], "argument with spaces;$(not-a-shell)")
        self.assertEqual(spec.env["EJN_RESOURCE"], f"prefix:{self.resource}")
        self.assertEqual(spec.env["EJN_LITERAL_UNSET"], "$UNSET")

    def test_rejects_bad_json_shapes_and_bounds(self) -> None:
        invalid = [
            b"{",
            b"[]",
            json.dumps({"kernelspecs": []}).encode(),
            json.dumps(
                {"kernelspecs": {"test": {"resource_dir": str(self.resource)}}}
            ).encode(),
            _spec_document(self.resource, {"not": "argv"}),
            _spec_document(self.resource, ["runner", "{connection_file}"], []),
            _spec_document(self.resource, ["runner", 1, "{connection_file}"], {}),
            _spec_document(self.resource, ["runner", "{connection_file}"], {"BAD": []}),
        ]
        for raw in invalid:
            with self.subTest(raw=raw[:30]):
                with self.assertRaises(DirectKernelFixtureError):
                    resolve_kernelspec_document(raw, "test", str(self.connection))
        with self.assertRaises(DirectKernelFixtureError):
            resolve_kernelspec_document(
                b"x" * (MAX_KERNELSPEC_JSON_BYTES + 1), "test", str(self.connection)
            )

    def test_rejects_unknown_missing_duplicate_and_malformed_placeholders(self) -> None:
        cases = [
            ["runner", "plain"],
            ["runner", "{connection_file}", "{connection_file}"],
            ["runner", "{missing}", "{connection_file}"],
            ["runner", "prefix{connection_file", "{connection_file}"],
            ["runner", "orphan}", "{connection_file}"],
        ]
        for argv in cases:
            with self.subTest(argv=argv):
                with self.assertRaises(DirectKernelFixtureError):
                    self._resolve(argv)
        with self.assertRaises(DirectKernelFixtureError):
            self._resolve(["runner", "{connection_file}"], {"BAD-NAME": "x"})
        spec = self._resolve(
            ["runner", "{connection_file}"], {"BRACES": "{literal}", "DOLLAR": "${"}
        )
        self.assertEqual(spec.env["BRACES"], "{literal}")
        self.assertEqual(spec.env["DOLLAR"], "${")

    def test_rejects_all_declared_collection_and_text_bounds(self) -> None:
        too_many_specs = {
            "kernelspecs": {
                f"spec-{index}": {
                    "resource_dir": str(self.resource),
                    "spec": {"argv": ["runner", "{connection_file}"], "env": {}},
                }
                for index in range(65)
            }
        }
        too_many_specs["kernelspecs"]["test"] = {
            "resource_dir": str(self.resource),
            "spec": {"argv": ["runner", "{connection_file}"], "env": {}},
        }
        cases = [
            _spec_document(self.resource, ["runner"] * 64 + ["{connection_file}"]),
            _spec_document(
                self.resource,
                ["runner", "{connection_file}"],
                {f"KEY_{index}": "x" for index in range(65)},
            ),
            _spec_document(self.resource, ["runner", "{connection_file}", "x" * 4097]),
            _spec_document(self.resource, ["runner", "{connection_file}", "\x00"]),
            _spec_document(self.resource, ["runner", "{connection_file}", ""]),
            _spec_document(
                self.resource,
                ["runner", "{connection_file}"] + ["x" * 4096] * 4,
            ),
            json.dumps(too_many_specs).encode(),
        ]
        for raw in cases:
            with self.subTest(size=len(raw)):
                with self.assertRaises(DirectKernelFixtureError):
                    resolve_kernelspec_document(raw, "test", str(self.connection))
        with self.assertRaises(DirectKernelFixtureError):
            resolve_kernelspec_document(
                _spec_document(self.resource, ["runner", "{connection_file}"]),
                "missing",
                str(self.connection),
            )
        with self.assertRaises(DirectKernelFixtureError):
            resolve_kernelspec_document(
                b"\xff", "test", str(self.connection)
            )
        remaining = 16_384 - len("python3") - len(str(self.connection))
        pre_rewrite_filler = []
        while remaining:
            size = min(4096, remaining)
            pre_rewrite_filler.append("x" * size)
            remaining -= size
        with self.assertRaises(DirectKernelFixtureError):
            self._resolve(
                ["python3", "{connection_file}", *pre_rewrite_filler]
            )

    def test_rejects_unexpected_selected_entry_and_resource_directory(self) -> None:
        raw = json.dumps(
            {
                "kernelspecs": {
                    "test": {
                        "resource_dir": str(self.resource),
                        "spec": {"argv": ["runner", "{connection_file}"], "env": {}},
                        "unexpected": "value",
                    }
                }
            }
        ).encode()
        with self.assertRaises(DirectKernelFixtureError):
            resolve_kernelspec_document(raw, "test", str(self.connection))
        missing = self.root / "does-not-exist"
        with self.assertRaises(DirectKernelFixtureError):
            resolve_kernelspec_document(
                _spec_document(missing, ["runner", "{connection_file}"]),
                "test",
                str(self.connection),
            )


class DirectKernelLifecycleTests(unittest.TestCase):
    def test_sync_event_loop_cleanup_closes_installed_loop(self) -> None:
        import asyncio

        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        try:
            close_installed_sync_event_loop()
            self.assertTrue(loop.is_closed())
            with self.assertRaises(RuntimeError):
                asyncio.get_event_loop()
        finally:
            if not loop.is_closed():
                loop.close()
            asyncio.set_event_loop(None)

    def _client(self, fixture: DirectKernelFixture):
        from jupyter_client import BlockingKernelClient

        assert fixture.connection is not None
        client = BlockingKernelClient()
        client.load_connection_info(fixture.connection)
        client.start_channels()
        client.wait_for_ready(timeout=8)
        return client

    @unittest.skipUnless(DirectKernelFixture.available(), "direct local kernel unavailable")
    def test_direct_pid_interrupt_then_execute(self) -> None:
        with DirectKernelFixture(startup_timeout=12) as fixture:
            assert fixture._process is not None and fixture.kernel_pid is not None
            self.assertEqual(fixture.kernel_pid, fixture._process.pid)
            client = self._client(fixture)
            try:
                execution_id = client.execute("import time\ntime.sleep(30)")
                _wait_status(client, execution_id, "busy", 8)
                interrupt_id = client.session.send(
                    client.control_channel.socket,
                    "interrupt_request",
                    content={},
                )["header"]["msg_id"]
                self.assertEqual(
                    _wait_message(client, "control", interrupt_id, "interrupt_reply", 8)[
                        "content"
                    ].get("status"),
                    "ok",
                )
                self.assertEqual(
                    _wait_message(client, "shell", execution_id, "execute_reply", 8)[
                        "content"
                    ].get("status"),
                    "error",
                )
                self.assertEqual(fixture.kernel_pid, fixture._process.pid)
                self.assertEqual(_execute(client, "6 * 7")["content"].get("status"), "ok")
            finally:
                client.stop_channels()
                close_installed_sync_event_loop()

    @unittest.skipUnless(DirectKernelFixture.available(), "direct local kernel unavailable")
    def test_protocol_shutdown_exits_exact_direct_process(self) -> None:
        with DirectKernelFixture(startup_timeout=12) as fixture:
            assert fixture._process is not None and fixture.kernel_pid is not None
            process = fixture._process
            pid = fixture.kernel_pid
            client = self._client(fixture)
            try:
                shutdown_id = client.shutdown(restart=False)
                reply = _wait_message(client, "control", shutdown_id, "shutdown_reply", 8)
                self.assertEqual(reply["content"].get("restart"), False)
                self.assertEqual(fixture.wait_exited(8), 0)
                self.assertEqual(process.pid, pid)
                self.assertEqual(process.poll(), 0)
            finally:
                client.stop_channels()
                close_installed_sync_event_loop()

    @unittest.skipUnless(DirectKernelFixture.available(), "direct local kernel unavailable")
    def test_restored_connection_file_relaunches_on_same_ports(self) -> None:
        with DirectKernelFixture(startup_timeout=12) as fixture:
            assert fixture.connection is not None and fixture.kernel_pid is not None
            connection_path = fixture.connection_path
            connection_before = dict(fixture.connection)
            ports_before = tuple(connection_before[name] for name in (
                "shell_port", "iopub_port", "stdin_port", "control_port", "hb_port"
            ))
            first_pid = fixture.kernel_pid
            client = self._client(fixture)
            try:
                self.assertEqual(_execute(client, "direct_value = 73")["content"].get("status"), "ok")
                shutdown_id = client.shutdown(restart=False)
                _wait_message(client, "control", shutdown_id, "shutdown_reply", 8)
                self.assertEqual(fixture.wait_exited(8), 0)
            finally:
                client.stop_channels()
                close_installed_sync_event_loop()
            self.assertFalse(connection_path.exists())
            fixture.relaunch(connection_data=connection_before)
            assert fixture.connection is not None and fixture.kernel_pid is not None
            self.assertEqual(connection_path.stat().st_mode & 0o777, 0o600)
            self.assertNotEqual(first_pid, fixture.kernel_pid)
            self.assertEqual(connection_path, fixture.connection_path)
            ports_after = tuple(
                fixture.connection[name]
                for name in (
                    "shell_port",
                    "iopub_port",
                    "stdin_port",
                    "control_port",
                    "hb_port",
                )
            )
            self.assertEqual(ports_before, ports_after)
            self.assertEqual(connection_before, fixture.connection)
            client = self._client(fixture)
            try:
                self.assertEqual(_execute(client, "direct_value")["content"].get("status"), "error")
                self.assertEqual(_execute(client, "new_value = 42")["content"].get("status"), "ok")
            finally:
                client.stop_channels()
                close_installed_sync_event_loop()

    def test_failed_resolution_cleans_private_state(self) -> None:
        fixture = DirectKernelFixture(kernelspec="definitely-missing-ejn-kernel")
        with self.assertRaises(DirectKernelFixtureError):
            fixture.start()
        self.assertIsNone(fixture._process)
        self.assertIsNone(fixture._tempdir)
        self.assertIsNone(fixture.connection_path)
        fixture.cleanup()


if __name__ == "__main__":
    unittest.main()
