#!/usr/bin/env python3
"""Private TH2/TH3 bridge used only by the AG3 local stress gate.

The bridge deliberately imports the fixture and relay harness rather than
reimplementing either.  Its file protocol lives in a runner-created 0700
directory; every response is atomically replaced and token-bound.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import signal
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "helper" / "integration_tests"))
from kernel_fixture import LocalKernelFixture  # noqa: E402
from tcp_relays import TcpRelayHarness  # noqa: E402


REQUEST_JSON_LIMIT = 16 * 1024
ERROR_DETAIL_LIMIT = 240


def bounded_detail(error: BaseException | str, limit: int = ERROR_DETAIL_LIMIT) -> str:
    """Keep malformed control-file diagnostics useful and bounded."""
    detail = str(error)
    return detail if len(detail) <= limit else detail[:limit - 3] + "..."


def read_request_json(path: Path) -> object:
    """Read one claimed control request before parsing its bounded body."""
    try:
        with path.open("rb") as stream:
            body = stream.read(REQUEST_JSON_LIMIT + 1)
    except OSError as exc:
        raise RuntimeError(
            f"cannot read bridge request: {bounded_detail(exc)}") from exc
    if len(body) > REQUEST_JSON_LIMIT:
        raise RuntimeError(f"bridge request exceeded {REQUEST_JSON_LIMIT} bytes")
    try:
        return json.loads(body)
    except (ValueError, RecursionError) as exc:
        raise RuntimeError(
            f"invalid bridge request JSON: {bounded_detail(exc)}") from exc


def write_json(path: Path, value: object) -> None:
    temporary = path.with_name(path.name + ".tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            fd = -1
            json.dump(value, stream, sort_keys=True)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if fd >= 0:
            os.close(fd)


class Bridge:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.fixture = LocalKernelFixture(startup_timeout=args.startup_timeout)
        self.relay: TcpRelayHarness | None = None
        self.stopped = False
        self.kernel_pgids: list[int] = []
        self.seen_requests: list[str] = []

    def state(self, *, cleaned: bool = False) -> dict[str, object]:
        relay = self.relay
        fixture = self.fixture
        return {
            "owner_token": self.args.owner_token,
            "bridge_pid": os.getpid(),
            "bridge_pgid": os.getpgrp(),
            "kernel_pid": fixture.kernel_pid,
            "kernel_pgid": fixture._owned_pgid,
            "kernel_pgids": list(self.kernel_pgids),
            "connection_file": str(relay.connection_path) if relay else None,
            "relay_ports": relay.ports if relay else {},
            "ready": bool(relay and relay.started and fixture.connection),
            "alive": bool(fixture._process and fixture._process.poll() is None),
            "relays_running": bool(relay and relay.started),
            "cleaned": cleaned,
        }

    async def start(self) -> None:
        await asyncio.to_thread(self.fixture.start)
        if isinstance(self.fixture._owned_pgid, int) and self.fixture._owned_pgid > 0:
            self.kernel_pgids.append(self.fixture._owned_pgid)
        if self.fixture.connection is None:
            raise RuntimeError("TH2 fixture supplied no connection")
        self.relay = TcpRelayHarness(self.fixture.connection, deadline=3.0)
        await self.relay.start()
        write_json(self.args.state, self.state())

    async def stop_relays(self) -> None:
        if self.relay is None:
            raise RuntimeError("relays are unavailable")
        await self.relay.stop()
        write_json(self.args.state, self.state())

    async def restart_relays(self) -> None:
        if self.relay is None:
            raise RuntimeError("relays are unavailable")
        ports = self.relay.ports
        await self.relay.restart()
        if self.relay.ports != ports:
            raise RuntimeError("TH3 changed relay ports during restart")
        write_json(self.args.state, self.state())

    async def cleanup(self) -> None:
        if self.relay is not None:
            await self.relay.close()
        await asyncio.to_thread(self.fixture.cleanup)
        write_json(self.args.state, self.state(cleaned=True))


async def run(args: argparse.Namespace) -> int:
    args.control_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(args.control_dir, 0o700)
    bridge = Bridge(args)

    def stop(_signum: int, _frame: object) -> None:
        bridge.stopped = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        await asyncio.wait_for(bridge.start(), args.startup_timeout)
        while not bridge.stopped:
            for request in sorted(args.control_dir.glob("request-*.json")):
                # Claim first, so an interrupted controller cannot process the
                # same nonce twice after a caller observes a response.
                claimed = request.with_name(request.name + ".processing")
                try:
                    os.replace(request, claimed)
                except FileNotFoundError:
                    continue
                nonce = request.name
                response = request.with_name(request.name.replace("request-", "response-", 1))
                try:
                    if nonce in bridge.seen_requests:
                        raise RuntimeError("replayed bridge request nonce")
                    bridge.seen_requests.append(nonce)
                    if len(bridge.seen_requests) > 256:
                        del bridge.seen_requests[:128]
                    payload = read_request_json(claimed)
                    if not isinstance(payload, dict) or payload.get("token") != args.token:
                        raise RuntimeError("invalid bridge request")
                    operation = payload.get("op")
                    if operation == "status":
                        result = {"ok": True, "state": bridge.state()}
                    elif operation == "stop-relays":
                        await asyncio.wait_for(bridge.stop_relays(), 5)
                        result = {"ok": True, "state": bridge.state()}
                    elif operation == "restart-relays":
                        await asyncio.wait_for(bridge.restart_relays(), 8)
                        result = {"ok": True, "state": bridge.state()}
                    elif operation == "shutdown":
                        bridge.stopped = True
                        result = {"ok": True}
                    else:
                        raise RuntimeError("unsupported bridge operation")
                except Exception as exc:
                    result = {"ok": False, "error": bounded_detail(exc)}
                write_json(response, result)
                claimed.unlink(missing_ok=True)
            await asyncio.sleep(0.02)
    finally:
        await asyncio.wait_for(bridge.cleanup(), 12)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", required=True, type=Path)
    parser.add_argument("--control-dir", required=True, type=Path)
    parser.add_argument("--token", required=True)
    parser.add_argument("--owner-token", required=True)
    parser.add_argument("--startup-timeout", type=float, default=15.0)
    return asyncio.run(run(parser.parse_args()))


if __name__ == "__main__":
    raise SystemExit(main())
