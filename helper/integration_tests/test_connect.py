"""Integration coverage for the local-only async Jupyter backend."""

from __future__ import annotations

import asyncio
import inspect
import json
import os
import socket
import sys
import tempfile
import threading
import types
import unittest
from pathlib import Path
from unittest.mock import patch

from ejn_helper.backend import BackendError
from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture


class ConnectTests(unittest.IsolatedAsyncioTestCase):
    async def _completion(self, backend, operation, params):
        future = asyncio.get_running_loop().create_future()
        backend.start(operation, params, lambda _event: None, future.set_result)
        return await asyncio.wait_for(future, 12)

    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_attach_kernel_info_close_and_kernel_survives(self):
        with LocalKernelFixture(startup_timeout=10) as fixture:
            backend = JupyterBackend(deadline=5)
            assert fixture.connection_path is not None
            connected = await self._completion(
                backend,
                "connect",
                {"connection_file": str(fixture.connection_path)},
            )
            self.assertIsNone(connected.error)
            self.assertEqual(connected.result, {"attached": True})
            info = await self._completion(backend, "kernel_info", {})
            self.assertIsNone(info.error)
            manager_pid, kernel_pid = fixture.manager_pid, fixture.kernel_pid
            self.assertEqual(
                fixture.evaluate("ejn_survives = 41", timeout=8).get("status"),
                "ok",
            )
            backend.close()
            backend.close()
            self.assertEqual(fixture.manager_pid, manager_pid)
            self.assertEqual(fixture.kernel_pid, kernel_pid)
            self.assertEqual(
                fixture.evaluate("assert ejn_survives == 41", timeout=8).get(
                    "status"
                ),
                "ok",
            )

    async def test_invalid_connection_is_local_failure(self):
        backend = JupyterBackend(deadline=0.1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "connection.json"
            path.write_text('{"ip":"192.0.2.1"}', encoding="utf-8")
            result = await self._completion(backend, "connect", {"connection_file": str(path)})
        self.assertEqual(getattr(result.error, "code", None), "invalid-request")
        backend.close()

    def test_connection_schema_rejects_every_sensitive_field(self):
        base = {"ip": "127.0.0.1", "transport": "tcp", "key": "key",
                "signature_scheme": "hmac-sha256", "shell_port": 1,
                "iopub_port": 2, "stdin_port": 3, "control_port": 4, "hb_port": 5}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "connection.json"
            mutations = [
                {"ip": "localhost"}, {"key": None}, {"key": ""},
                {"key": "x" * 4097}, {"signature_scheme": None},
                {"signature_scheme": "x" * 129}, {"transport": "ipc"},
            ] + [
                {name: value}
                for name in (
                    "shell_port",
                    "iopub_port",
                    "stdin_port",
                    "control_port",
                    "hb_port",
                )
                for value in (None, "1", 0, 65536)
            ]
            for mutation in mutations:
                data = dict(base)
                data.update(mutation)
                path.write_text(json.dumps(data), encoding="utf-8")
                with self.assertRaises(BackendError) as caught:
                    JupyterBackend._connection(str(path))
                self.assertEqual(caught.exception.code, "invalid-request")
            for field in base:
                data = dict(base); data.pop(field)
                path.write_text(json.dumps(data), encoding="utf-8")
                with self.assertRaises(BackendError) as caught:
                    JupyterBackend._connection(str(path))
                self.assertEqual(caught.exception.code, "invalid-request")
            path.write_text("{", encoding="utf-8")
            with self.assertRaises(BackendError) as caught:
                JupyterBackend._connection(str(path))
            self.assertEqual(caught.exception.code, "invalid-request")
            relative = Path("relative.json")
            with self.assertRaises(BackendError) as caught:
                JupyterBackend._connection(str(relative))
            self.assertEqual(caught.exception.code, "invalid-request")
            path.write_text(json.dumps(base), encoding="utf-8")
            link = root / "link.json"
            link.symlink_to(path)
            with self.assertRaises(BackendError) as caught:
                JupyterBackend._connection(str(link))
            self.assertEqual(caught.exception.code, "invalid-request")
            path.write_text("x" * 65_537, encoding="utf-8")
            with self.assertRaises(BackendError) as caught:
                JupyterBackend._connection(str(path))
            self.assertEqual(caught.exception.code, "invalid-request")
            with self.assertRaises(BackendError) as caught:
                JupyterBackend._connection(str(root))
            self.assertEqual(caught.exception.code, "invalid-request")
            if hasattr(os, "getuid"):
                path.write_text(json.dumps(base), encoding="utf-8")
                metadata = path.stat()
                with patch(
                    "ejn_helper.jupyter_backend.os.fstat",
                    return_value=types.SimpleNamespace(
                        st_mode=metadata.st_mode,
                        st_size=metadata.st_size,
                        st_uid=os.getuid() + 1,
                    ),
                ):
                    with self.assertRaises(BackendError) as caught:
                        JupyterBackend._connection(str(path))
                    self.assertEqual(caught.exception.code, "invalid-request")

    async def test_unused_loopback_port_deadlines(self):
        with tempfile.TemporaryDirectory() as directory:
            ports = []
            for _ in range(5):
                sock = socket.socket()
                sock.bind(("127.0.0.1", 0)); ports.append(sock.getsockname()[1]); sock.close()
            path = Path(directory) / "connection.json"
            path.write_text(json.dumps({"ip":"127.0.0.1", "transport":"tcp", "key":"x", "signature_scheme":"hmac-sha256", **dict(zip(("shell_port","iopub_port","stdin_port","control_port","hb_port"), ports))}))
            backend = JupyterBackend(deadline=0.1)
            result = await self._completion(backend, "connect", {"connection_file": str(path)})
            self.assertIn(getattr(result.error, "code", None), {"timeout", "transport-error"})
            self.assertIsNone(backend.client)
            backend.close()

    async def test_black_hole_deadlines_and_releases_client(self):
        handlers = set()
        async def black_hole(reader, writer):
            task = asyncio.current_task(); handlers.add(task)
            try:
                await reader.read()
            finally:
                writer.close()
                await writer.wait_closed()
                handlers.discard(task)
        servers = [await asyncio.start_server(black_hole, "127.0.0.1", 0) for _ in range(5)]
        try:
            ports = [server.sockets[0].getsockname()[1] for server in servers]
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "connection.json"
                path.write_text(json.dumps({"ip":"127.0.0.1", "transport":"tcp", "key":"x", "signature_scheme":"hmac-sha256", **dict(zip(("shell_port","iopub_port","stdin_port","control_port","hb_port"), ports))}))
                backend = JupyterBackend(deadline=0.1)
                result = await self._completion(backend, "connect", {"connection_file": str(path)})
                self.assertEqual(getattr(result.error, "code", None), "timeout")
                self.assertIsNone(backend.client)
                backend.close()
        finally:
            for server in servers:
                server.close(); await server.wait_closed()
            if handlers:
                await asyncio.wait_for(asyncio.gather(*handlers), 1)

    async def test_cancel_and_close_suppress_late_completion(self):
        backend = JupyterBackend(deadline=1)
        seen = []
        cancel = backend.start("kernel_info", {}, lambda _event: None, seen.append)
        assert cancel is not None
        cancel.cancel()
        await asyncio.sleep(0)
        backend.close()
        self.assertEqual(seen, [])

    async def test_closed_callback_is_deferred_and_protected(self):
        backend = JupyterBackend()
        backend.close()
        calls = []

        def callback(_value):
            calls.append(True)
            raise RuntimeError("consumer failed")

        backend.start("kernel_info", {}, lambda _event: None, callback)
        self.assertEqual(calls, [])
        await asyncio.sleep(0)
        self.assertEqual(calls, [True])

    async def test_completion_exception_is_not_retried(self):
        backend = JupyterBackend(deadline=1)
        calls = []
        def callback(_completion):
            calls.append(True)
            raise RuntimeError("consumer failure")
        backend.start("kernel_info", {}, lambda _event: None, callback)
        await asyncio.sleep(0)
        self.assertEqual(calls, [True])
        backend.close()

    async def test_provisional_client_cancel_stops_channels_once(self):
        created = []
        started = asyncio.Event()

        class Client:
            def __init__(self): self.started = self.stopped = 0; created.append(self)
            def load_connection_info(self, _info): pass
            def start_channels(self): self.started += 1; started.set()
            def stop_channels(self): self.stopped += 1
            def kernel_info(self): return "id"
            async def get_shell_msg(self, timeout): await asyncio.sleep(60)
        old = sys.modules.get("jupyter_client")
        sys.modules["jupyter_client"] = types.SimpleNamespace(AsyncKernelClient=Client)
        try:
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "connection.json"
                path.write_text(json.dumps({"ip":"127.0.0.1", "transport":"tcp", "key":"x", "signature_scheme":"hmac-sha256", "shell_port":1, "iopub_port":2, "stdin_port":3, "control_port":4, "hb_port":5}))
                backend = JupyterBackend(deadline=5); callbacks = []
                token = backend.start("connect", {"connection_file": str(path)}, lambda _event: None, callbacks.append)
                await asyncio.wait_for(started.wait(), 1)
                busy = []
                backend.start("connect", {"connection_file": str(path)}, lambda _event: None, busy.append)
                await asyncio.sleep(0)
                self.assertEqual(getattr(busy[0].error, "code", None), "busy")
                token.cancel()
                for _ in range(3):
                    await asyncio.sleep(0)
                    if not backend._tasks:
                        break
                self.assertEqual(created[0].started, 1)
                self.assertEqual(created[0].stopped, 1)
                self.assertIsNone(backend.client)
                self.assertEqual(callbacks, [])
                self.assertEqual(backend._tasks, set())
                backend.close(); self.assertEqual(created[0].stopped, 1)
        finally:
            if old is None: sys.modules.pop("jupyter_client", None)
            else: sys.modules["jupyter_client"] = old

    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_repeated_attach_close_has_bounded_local_resources(self):
        fd_before = len(list(Path("/proc/self/fd").iterdir())) if Path("/proc/self/fd").is_dir() else None
        threads_before = len(threading.enumerate())
        tasks_before = len(asyncio.all_tasks())
        with LocalKernelFixture(startup_timeout=10) as fixture:
            assert fixture.connection_path is not None
            warm = JupyterBackend(deadline=5)
            await self._completion(warm, "connect", {"connection_file": str(fixture.connection_path)})
            warm.close(); await asyncio.sleep(0)
            fd_before = len(list(Path("/proc/self/fd").iterdir())) if fd_before is not None else None
            threads_before, tasks_before = len(threading.enumerate()), len(asyncio.all_tasks())
            for _ in range(5):
                backend = JupyterBackend(deadline=5)
                self.assertIsNone((await self._completion(backend, "connect", {"connection_file": str(fixture.connection_path)})).error)
                backend.close()
                await asyncio.sleep(0)
                self.assertEqual(backend._tasks, set())
        if fd_before is not None:
            self.assertLessEqual(len(list(Path("/proc/self/fd").iterdir())), fd_before + 2)
        self.assertLessEqual(len(threading.enumerate()), threads_before + 2)
        self.assertLessEqual(len(asyncio.all_tasks()), tasks_before + 2)

    def test_deadline_validation_and_lifetime_source(self):
        for value in (0, -1, float("inf"), True):
            with self.assertRaises(ValueError):
                JupyterBackend(deadline=value)
        source = inspect.getsource(__import__("ejn_helper.jupyter_backend", fromlist=["*"]))
        for forbidden in ("KernelManager", "BlockingKernelClient", "subprocess", ".shutdown("):
            self.assertNotIn(forbidden, source)


if __name__ == "__main__":
    unittest.main()
