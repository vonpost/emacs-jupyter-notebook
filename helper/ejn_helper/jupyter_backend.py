"""Local-only async adapter around Jupyter's asynchronous client."""

from __future__ import annotations

import asyncio
import json
import math
import os
import stat
from pathlib import Path
from typing import Mapping

from .backend import BackendCompletion, BackendError


_LOOPBACK = {"127.0.0.1", "::1"}
_PORTS = ("shell_port", "iopub_port", "stdin_port", "control_port", "hb_port")


class _TaskCancellation:
    def __init__(self, task: asyncio.Task[None]) -> None:
        self._task = task

    def cancel(self) -> None:
        self._task.cancel()


class JupyterBackend:
    """Attach to an existing local kernel without ever owning its lifetime."""

    def __init__(self, *, deadline: float = 10.0) -> None:
        if (
            isinstance(deadline, bool)
            or not isinstance(deadline, (int, float))
            or not math.isfinite(deadline)
            or deadline <= 0
        ):
            raise ValueError("deadline must be finite and positive")
        self.deadline = float(deadline)
        self.client = None
        self.closed = False
        self._tasks: set[asyncio.Task[None]] = set()
        self._channels_started = False
        self._connecting = False

    @staticmethod
    def _connection(path_value: object) -> dict:
        if not isinstance(path_value, str):
            raise BackendError("invalid-request")
        path = Path(path_value)
        if not path.is_absolute():
            raise BackendError("invalid-request")
        descriptor = None
        try:
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(path, flags)
            metadata = os.fstat(descriptor)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > 65_536:
                raise BackendError("invalid-request")
            if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
                raise BackendError("invalid-request")
            chunks = []
            remaining = 65_537
            while remaining:
                chunk = os.read(descriptor, remaining)
                if not chunk:
                    break
                chunks.append(chunk)
                remaining -= len(chunk)
            raw = b"".join(chunks)
        except OSError as exc:
            raise BackendError("invalid-request") from exc
        finally:
            if descriptor is not None:
                os.close(descriptor)
        if len(raw) > 65_536:
            raise BackendError("invalid-request")
        try:
            data = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError) as exc:
            raise BackendError("invalid-request") from exc
        if (
            not isinstance(data, dict)
            or data.get("ip", data.get("host")) not in _LOOPBACK
        ):
            raise BackendError("invalid-request")
        if (
            data.get("transport") != "tcp"
            or not isinstance(data.get("key"), str)
            or not 0 < len(data["key"]) <= 4096
            or not isinstance(data.get("signature_scheme"), str)
            or not 0 < len(data["signature_scheme"]) <= 128
        ):
            raise BackendError("invalid-request")
        for name in _PORTS:
            value = data.get(name)
            if type(value) is not int or not 1 <= value <= 65535:
                raise BackendError("invalid-request")
        return data

    def start(
        self,
        operation,
        params: Mapping[str, object],
        event_callback,
        completion_callback,
    ):
        if self.closed:
            asyncio.get_running_loop().call_soon(
                self._deliver,
                completion_callback,
                BackendCompletion.failure(BackendError("transport-error")),
            )
            return None
        if operation == "connect" and self._connecting:
            asyncio.get_running_loop().call_soon(
                self._deliver,
                completion_callback,
                BackendCompletion.failure(BackendError("busy")),
            )
            return None
        if operation == "connect":
            self._connecting = True
        task = asyncio.get_running_loop().create_task(
            self._run(operation, params, event_callback, completion_callback)
        )
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return _TaskCancellation(task)

    @staticmethod
    def _deliver(callback, completion) -> None:
        try:
            callback(completion)
        except Exception:
            pass

    async def _run(self, operation, params, event_callback, completion_callback) -> None:
        completion = None
        retire_provisional = operation == "connect"
        try:
            if operation == "connect":
                await asyncio.wait_for(self._connect(params), self.deadline)
                result = {"attached": True}
            elif operation == "kernel_info":
                result = await asyncio.wait_for(self._kernel_info(), self.deadline)
            else:
                raise BackendError("unsupported")
            completion = BackendCompletion.success(result)
        except asyncio.CancelledError:
            if retire_provisional:
                self._stop_channels()
            return
        except BackendError as exc:
            if retire_provisional:
                self._stop_channels()
            completion = BackendCompletion.failure(exc)
        except asyncio.TimeoutError:
            if retire_provisional:
                self._stop_channels()
            completion = BackendCompletion.failure(BackendError("timeout"))
        except (OSError, ValueError):
            if retire_provisional:
                self._stop_channels()
            completion = BackendCompletion.failure(BackendError("transport-error"))
        except Exception:
            if retire_provisional:
                self._stop_channels()
            completion = BackendCompletion.failure(BackendError("transport-error"))
        finally:
            if operation == "connect":
                self._connecting = False
        if completion is not None and not self.closed:
            self._deliver(completion_callback, completion)

    async def _connect(self, params: Mapping[str, object]) -> None:
        connection = self._connection(params.get("connection_file"))
        try:
            from jupyter_client import AsyncKernelClient
        except ImportError as exc:
            raise BackendError("transport-error") from exc
        self._stop_channels()
        client = AsyncKernelClient()
        client.load_connection_info(connection)
        self.client = client
        client.start_channels()
        self._channels_started = True
        await self._kernel_info()

    async def _kernel_info(self) -> dict:
        if self.client is None or not self._channels_started:
            raise BackendError("busy")
        message_id = self.client.kernel_info()
        while True:
            message = await self.client.get_shell_msg(timeout=self.deadline)
            if message.get("msg_type") == "kernel_info_reply" and message.get("parent_header", {}).get("msg_id") == message_id:
                content = message.get("content", {})
                return content if isinstance(content, dict) else {}

    def _stop_channels(self) -> None:
        if self.client is not None and self._channels_started:
            try:
                self.client.stop_channels()
            except Exception:
                pass
        self._channels_started = False
        self.client = None

    def close(self) -> None:
        if self.closed:
            return
        self.closed = True
        for task in tuple(self._tasks):
            task.cancel()
        self._tasks.clear()
        self._stop_channels()
        self._connecting = False
