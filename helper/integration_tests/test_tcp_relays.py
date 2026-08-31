"""Integration tests for the bounded, test-only TCP relay harness."""

from __future__ import annotations

import asyncio
import contextlib
import json
import stat
import unittest
from unittest.mock import AsyncMock, Mock, patch

from kernel_fixture import LocalKernelFixture
from tcp_relays import CHANNELS, RelayError, TcpRelayHarness


class TcpRelayTests(unittest.IsolatedAsyncioTestCase):
    async def _backend_request(self, backend, operation: str, params: dict):
        completion = asyncio.get_running_loop().create_future()
        backend.start(operation, params, lambda _event: None, completion.set_result)
        return await asyncio.wait_for(completion, 8)

    async def _echo_server(self):
        async def echo(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            try:
                while data := await reader.read(4096):
                    writer.write(data)
                    await writer.drain()
            finally:
                writer.close()
                with contextlib.suppress(ConnectionError, OSError):
                    await writer.wait_closed()

        return await asyncio.start_server(echo, "127.0.0.1", 0)

    @staticmethod
    def _echo_connection(server: asyncio.AbstractServer) -> dict:
        sockets = server.sockets or ()
        assert len(sockets) == 1
        port = sockets[0].getsockname()[1]
        return {
            "ip": "127.0.0.1", "transport": "tcp", "key": "test",
            "signature_scheme": "hmac-sha256",
            **{f"{channel}_port": port for channel in CHANNELS},
        }

    async def _echo(self, port: int, data: bytes) -> bytes:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection("127.0.0.1", port), 2
        )
        try:
            writer.write(data)
            await asyncio.wait_for(writer.drain(), 2)
            return await asyncio.wait_for(reader.readexactly(len(data)), 2)
        finally:
            writer.close()
            with contextlib.suppress(ConnectionError, OSError):
                await writer.wait_closed()

    async def test_byte_echo_stop_active_and_restart_same_ports(self) -> None:
        server = await self._echo_server()
        relay = TcpRelayHarness(
            self._echo_connection(server), deadline=1, max_buffer=1024
        )
        try:
            await relay.start()
            original_ports = relay.ports
            copied = json.loads(relay.connection_path.read_text(encoding="utf-8"))
            self.assertEqual(stat.S_IMODE(relay.connection_path.stat().st_mode), 0o600)
            self.assertEqual(
                {name: copied[f"{name}_port"] for name in CHANNELS}, original_ports
            )
            self.assertEqual(
                await self._echo(original_ports["shell"], b"relay bytes"),
                b"relay bytes",
            )

            reader, writer = await asyncio.open_connection(
                "127.0.0.1", original_ports["iopub"]
            )
            writer.write(b"active")
            await writer.drain()
            self.assertEqual(await asyncio.wait_for(reader.readexactly(6), 2), b"active")
            writer.write(b"more")
            await writer.drain()
            await relay.stop()
            self.assertFalse(relay.started)
            self.assertEqual(relay._tasks, set())
            with contextlib.suppress(ConnectionError):
                await asyncio.wait_for(reader.read(), 2)
                self.assertEqual(await asyncio.wait_for(reader.read(), 2), b"")
            writer.close()
            with contextlib.suppress(ConnectionError, OSError):
                await writer.wait_closed()

            await relay.restart()
            self.assertEqual(relay.ports, original_ports)
            self.assertEqual(
                await self._echo(original_ports["control"], b"after restart"),
                b"after restart",
            )
            copied_path = relay.connection_path
            await relay.close()
            await relay.close()
            self.assertFalse(copied_path.exists())
            self.assertEqual(relay._tasks, set())
            self.assertEqual(relay._servers, {})
            self.assertEqual(relay._writers, set())
        finally:
            await relay.close()
            server.close()
            await server.wait_closed()

    async def test_idle_connection_survives_multiple_bounded_polls(self) -> None:
        server = await self._echo_server()
        relay = TcpRelayHarness(self._echo_connection(server), deadline=0.05)
        try:
            await relay.start()
            self.assertTrue(relay.started)
            reader, writer = await asyncio.open_connection(
                "127.0.0.1", relay.ports["stdin"]
            )
            await asyncio.sleep(0.2)
            writer.write(b"still connected")
            await writer.drain()
            self.assertEqual(await reader.readexactly(15), b"still connected")
            writer.close()
            await writer.wait_closed()
        finally:
            await relay.close()
            server.close()
            await server.wait_closed()

    @unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
    async def test_kernel_evaluation_and_state_survive_idle_stop_and_restart(self) -> None:
        from ejn_helper.jupyter_backend import JupyterBackend

        fixture = LocalKernelFixture(startup_timeout=10)
        await asyncio.to_thread(fixture.start)
        assert fixture.connection is not None
        original_connection = dict(fixture.connection)
        relay = TcpRelayHarness(fixture.connection, deadline=3)
        backend = None
        try:
            manager_pid = fixture.manager_pid
            kernel_pid = fixture.kernel_pid
            await asyncio.to_thread(fixture.evaluate, "relay_preserved_state = 719", 8)
            connection_path = await relay.start()
            artifact_dir = connection_path.parent / "artifacts"
            artifact_dir.mkdir(mode=0o700)
            backend = JupyterBackend(deadline=6)
            connected = await self._backend_request(
                backend,
                "connect",
                {
                    "connection_file": str(connection_path),
                    "artifact_dir": str(artifact_dir),
                },
            )
            self.assertIsNone(connected.error)
            reply = await self._backend_request(
                backend, "execute", {"code": "assert relay_preserved_state == 719"}
            )
            self.assertIsNone(reply.error)
            self.assertEqual(reply.result.get("status"), "ok")
            backend.close()
            await backend.wait_closed()
            await relay.stop()  # idle outage only retires local listeners.
            with self.assertRaises(OSError):
                await asyncio.open_connection("127.0.0.1", relay.ports["shell"])
            direct = await asyncio.to_thread(
                fixture.evaluate, "assert relay_preserved_state == 719", 8
            )
            self.assertEqual(direct.get("status"), "ok")
            self.assertEqual(fixture.manager_pid, manager_pid)
            self.assertEqual(fixture.kernel_pid, kernel_pid)
            self.assertEqual(fixture.connection, original_connection)
            await relay.restart()
            backend = JupyterBackend(deadline=6)
            connected = await self._backend_request(
                backend,
                "connect",
                {
                    "connection_file": str(relay.connection_path),
                    "artifact_dir": str(artifact_dir),
                },
            )
            self.assertIsNone(connected.error)
            reply = await self._backend_request(
                backend, "execute", {"code": "assert relay_preserved_state + 1 == 720"}
            )
            self.assertIsNone(reply.error)
            self.assertEqual(reply.result.get("status"), "ok")
            backend.close()
            await backend.wait_closed()
            self.assertEqual(fixture.manager_pid, manager_pid)
            self.assertEqual(fixture.kernel_pid, kernel_pid)
            direct = await asyncio.to_thread(
                fixture.evaluate, "assert relay_preserved_state == 719", 8
            )
            self.assertEqual(direct.get("status"), "ok")
        finally:
            if backend is not None and not backend.closed:
                backend.close()
                await backend.wait_closed()
            await relay.close()
            await asyncio.to_thread(fixture.cleanup)

    async def test_stop_is_idempotent_and_refuses_non_loopback(self) -> None:
        with self.assertRaisesRegex(RelayError, "loopback"):
            TcpRelayHarness(
                {
                    "ip": "192.0.2.1",
                    "transport": "tcp",
                    **{f"{name}_port": 1 for name in CHANNELS},
                }
            )
        server = await self._echo_server()
        relay = TcpRelayHarness(self._echo_connection(server), deadline=1)
        try:
            await relay.start()
            await relay.stop()
            await relay.stop()
            self.assertEqual(relay._servers, {})
            self.assertEqual(relay._writers, set())
        finally:
            await relay.close()
            server.close()
            await server.wait_closed()

    async def test_stalled_forward_task_still_clears_all_bookkeeping(self) -> None:
        class Server:
            closed = False
            waited = False

            def close(self) -> None:
                self.closed = True

            async def wait_closed(self) -> None:
                self.waited = True

        connection = {
            "ip": "127.0.0.1",
            "transport": "tcp",
            **{f"{name}_port": 1 for name in CHANNELS},
        }
        relay = TcpRelayHarness(connection, deadline=0.1)
        server = Server()
        writer = Mock()
        blocked = asyncio.create_task(asyncio.Event().wait())
        relay._servers["shell"] = server
        relay._writers.add(writer)
        relay._tasks.add(blocked)
        relay._connection_count = 1
        try:
            with patch(
                "tcp_relays.asyncio.wait",
                new=AsyncMock(return_value=(set(), {blocked})),
            ):
                with self.assertRaisesRegex(RelayError, "did not stop"):
                    await relay.stop()
            self.assertTrue(server.closed)
            self.assertTrue(server.waited)
            writer.close.assert_called_once_with()
            self.assertEqual(relay._servers, {})
            self.assertEqual(relay._writers, set())
            self.assertEqual(relay._tasks, set())
            self.assertEqual(relay._connection_count, 0)
            self.assertTrue(blocked.done())
        finally:
            blocked.cancel()
            await asyncio.gather(blocked, return_exceptions=True)
            await relay.close()


if __name__ == "__main__":
    unittest.main()
