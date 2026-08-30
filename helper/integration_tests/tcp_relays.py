"""Bounded, stoppable loopback TCP relays for local-kernel integration tests.

The relays deliberately know nothing about Jupyter messages.  They only copy
bytes between a local listener and the original loopback endpoint described by
a copied connection dictionary.  In particular, stopping a relay never sends a
signal or a protocol message to the kernel.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import math
import os
import tempfile
from pathlib import Path
from typing import Any, Mapping


CHANNELS = ("shell", "iopub", "stdin", "control", "hb")
_PORT_FIELDS = {channel: f"{channel}_port" for channel in CHANNELS}


class RelayError(RuntimeError):
    """The relay could not be started with a safe local connection."""


class TcpRelayHarness:
    """Five bounded loopback relays with a rewritten, private connection file."""

    def __init__(
        self,
        connection: Mapping[str, Any],
        *,
        deadline: float = 3.0,
        max_connections: int = 16,
        max_buffer: int = 65536,
    ) -> None:
        if (
            not isinstance(deadline, (int, float))
            or isinstance(deadline, bool)
            or not math.isfinite(deadline)
            or deadline <= 0
        ):
            raise ValueError("deadline must be finite and positive")
        if (
            not isinstance(max_connections, int)
            or isinstance(max_connections, bool)
            or max_connections <= 0
        ):
            raise ValueError("max_connections must be positive")
        if (
            not isinstance(max_buffer, int)
            or isinstance(max_buffer, bool)
            or max_buffer <= 0
        ):
            raise ValueError("max_buffer must be positive")
        self._connection = self._validated_connection(connection)
        self._target_host = self._connection.get("ip") or self._connection.get("host")
        self.deadline = float(deadline)
        self.max_connections = max_connections
        self.max_buffer = max_buffer
        self._servers: dict[str, asyncio.AbstractServer] = {}
        self._ports: dict[str, int] = {}
        self._tasks: set[asyncio.Task[None]] = set()
        self._writers: set[asyncio.StreamWriter] = set()
        self._connection_count = 0
        self._lifecycle_lock = asyncio.Lock()
        self._started = False
        self._closed = False
        self._tempdir = tempfile.TemporaryDirectory(prefix="ejn-tcp-relays-")
        self.connection_path = Path(self._tempdir.name) / "connection.json"
        self.connection_info: dict[str, Any] = {}

    @staticmethod
    def _validated_connection(connection: Mapping[str, Any]) -> dict[str, Any]:
        if not isinstance(connection, Mapping):
            raise RelayError("connection must be a mapping")
        data = dict(connection)
        host = data.get("ip") or data.get("host")
        if host not in {"127.0.0.1", "::1", "localhost"}:
            raise RelayError("relay target must be loopback")
        if data.get("transport", "tcp") != "tcp":
            raise RelayError("relay target transport must be tcp")
        for field in _PORT_FIELDS.values():
            port = data.get(field)
            if (
                not isinstance(port, int)
                or isinstance(port, bool)
                or not 0 < port < 65536
            ):
                raise RelayError(f"invalid {field}")
        return data

    @property
    def ports(self) -> dict[str, int]:
        """Return the allocated relay ports, keyed by Jupyter channel."""
        return dict(self._ports)

    @property
    def started(self) -> bool:
        return self._started

    async def start(self) -> Path:
        """Start every listener and write the private rewritten connection file."""
        async with self._lifecycle_lock:
            if self._closed:
                raise RelayError("relay is closed")
            if self._started:
                return self.connection_path
            try:
                for channel in CHANNELS:
                    port = self._ports.get(channel, 0)
                    server = await asyncio.wait_for(
                        asyncio.start_server(
                            lambda reader, writer, name=channel: self._accepted(
                                name, reader, writer
                            ),
                            "127.0.0.1",
                            port,
                            limit=self.max_buffer,
                        ),
                        timeout=self.deadline,
                    )
                    self._servers[channel] = server
                    sockets = server.sockets or ()
                    if len(sockets) != 1:
                        raise RelayError(f"could not allocate {channel} relay port")
                    self._ports[channel] = int(sockets[0].getsockname()[1])
                self._write_connection()
                self._started = True
                return self.connection_path
            except BaseException:
                await self._stop_locked()
                raise

    async def restart(self) -> Path:
        """Stop local relays and rebind the original allocated ports."""
        await self.stop()
        return await self.start()

    async def stop(self) -> None:
        """Close listeners and forwarding connections, leaving the kernel alone."""
        async with self._lifecycle_lock:
            await self._stop_locked()

    async def close(self) -> None:
        """Idempotently stop relays and remove only their copied connection file."""
        async with self._lifecycle_lock:
            if self._closed:
                return
            await self._stop_locked()
            self._closed = True
            self._tempdir.cleanup()

    async def __aenter__(self) -> "TcpRelayHarness":
        await self.start()
        return self

    async def __aexit__(self, *_: object) -> None:
        await self.close()

    def _write_connection(self) -> None:
        data = dict(self._connection)
        data["ip"] = "127.0.0.1"
        data.pop("host", None)
        for channel, field in _PORT_FIELDS.items():
            data[field] = self._ports[channel]
        self.connection_info = data
        temporary_path = self.connection_path.with_suffix(".tmp")
        encoded = json.dumps(data, sort_keys=True).encode("utf-8")
        descriptor = os.open(
            temporary_path,
            os.O_WRONLY | os.O_CREAT | os.O_TRUNC,
            0o600,
        )
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                descriptor = None
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary_path, self.connection_path)
        except BaseException:
            with contextlib.suppress(FileNotFoundError):
                temporary_path.unlink()
            raise
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def _accepted(
        self, channel: str, local_reader: asyncio.StreamReader, local_writer: asyncio.StreamWriter
    ) -> None:
        if not self._started or self._closed or self._connection_count >= self.max_connections:
            local_writer.close()
            return
        self._connection_count += 1
        task = asyncio.create_task(
            self._relay_connection(channel, local_reader, local_writer),
            name=f"ejn-relay-{channel}",
        )
        self._tasks.add(task)
        task.add_done_callback(self._retire_connection_task)

    def _retire_connection_task(self, task: asyncio.Task[None]) -> None:
        self._tasks.discard(task)
        self._connection_count = max(0, self._connection_count - 1)

    async def _relay_connection(
        self, channel: str, local_reader: asyncio.StreamReader, local_writer: asyncio.StreamWriter
    ) -> None:
        remote_writer: asyncio.StreamWriter | None = None
        forward: asyncio.Task[None] | None = None
        backward: asyncio.Task[None] | None = None
        self._writers.add(local_writer)
        try:
            remote_reader, remote_writer = await asyncio.wait_for(
                asyncio.open_connection(
                    self._target_host,
                    self._connection[_PORT_FIELDS[channel]],
                    limit=self.max_buffer,
                ),
                timeout=self.deadline,
            )
            self._writers.add(remote_writer)
            forward = asyncio.create_task(self._copy(local_reader, remote_writer))
            backward = asyncio.create_task(self._copy(remote_reader, local_writer))
            done, pending = await asyncio.wait(
                (forward, backward), return_when=asyncio.FIRST_COMPLETED
            )
            for task in pending:
                task.cancel()
            await asyncio.wait_for(
                asyncio.gather(*done, *pending, return_exceptions=True), self.deadline
            )
        except (asyncio.TimeoutError, ConnectionError, OSError):
            pass
        finally:
            for task in (forward, backward):
                if task is not None and not task.done():
                    task.cancel()
            pending_copies = tuple(
                task for task in (forward, backward) if task is not None
            )
            if pending_copies:
                with contextlib.suppress(asyncio.TimeoutError):
                    await asyncio.wait_for(
                        asyncio.gather(*pending_copies, return_exceptions=True),
                        self.deadline,
                    )
            self._writers.discard(local_writer)
            if remote_writer is not None:
                self._writers.discard(remote_writer)
            await self._close_writer(local_writer)
            if remote_writer is not None:
                await self._close_writer(remote_writer)

    async def _copy(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        while self._started and not self._closed:
            try:
                chunk = await asyncio.wait_for(
                    reader.read(self.max_buffer), timeout=self.deadline
                )
            except asyncio.TimeoutError:
                # A quiet Jupyter channel remains valid.  The bounded poll is
                # solely an opportunity to observe local relay shutdown.
                continue
            if not chunk:
                return
            writer.write(chunk)
            await asyncio.wait_for(writer.drain(), timeout=self.deadline)

    async def _stop_locked(self) -> None:
        # Prevent a server callback already queued by the event loop from
        # creating a new forwarding task after this snapshot is taken.
        self._started = False
        servers = tuple(self._servers.values())
        writers = tuple(self._writers)
        tasks = tuple(self._tasks)
        teardown_failed = False
        try:
            for server in servers:
                server.close()
            for writer in writers:
                writer.close()
            for task in tasks:
                task.cancel()
            if tasks:
                done, pending = await asyncio.wait(tasks, timeout=self.deadline)
                if pending:
                    teardown_failed = True
                    for task in pending:
                        task.cancel()
                    with contextlib.suppress(asyncio.TimeoutError):
                        await asyncio.wait_for(
                            asyncio.gather(*pending, return_exceptions=True),
                            self.deadline,
                        )
                if done:
                    await asyncio.gather(*done, return_exceptions=True)
            if servers:
                try:
                    await asyncio.wait_for(
                        asyncio.gather(
                            *(server.wait_closed() for server in servers)
                        ),
                        self.deadline,
                    )
                except asyncio.TimeoutError:
                    teardown_failed = True
        finally:
            self._servers.clear()
            self._writers.clear()
            self._tasks.clear()
            self._connection_count = 0
        if teardown_failed:
            raise RelayError("relay forwarding task did not stop")

    async def _close_writer(self, writer: asyncio.StreamWriter) -> None:
        writer.close()
        with contextlib.suppress(ConnectionError, OSError, asyncio.TimeoutError):
            await asyncio.wait_for(writer.wait_closed(), timeout=self.deadline)
