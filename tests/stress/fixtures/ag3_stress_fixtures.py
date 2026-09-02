#!/usr/bin/env python3
"""Deterministic AG3 flood and artifact fixtures.

This file is deliberately independent of the EJN helper package.  It emits
only protocol-v1 event frames on stdout; diagnostics and optional accounting
are written to stderr/a separate JSON file.
"""

import argparse
import hashlib
import json
import os
import select
import struct
import subprocess
import sys
import time
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


MAX_EVENT_FRAME = 262144
MAX_EVENT_QUEUE = 1048576
MAX_PENDING_OUTPUT = 65536
MAX_INPUT_BUFFER = 1048576
MAX_ARTIFACT_BYTES = 67108864
MAX_IMAGE_PIXELS = 4194304
BLOCK_BYTES = 65536
EXACT_ARTIFACT_SHA256 = "1093ffd8dc4917554eb84c889c738284cdfa9826376146c5dbb0fdabf3241ea1"


def encode_frame(obj):
    payload = json.dumps(obj, ensure_ascii=False, separators=(",", ":"),
                         sort_keys=True).encode("utf-8")
    frame = struct.pack(">I", len(payload)) + payload
    if len(frame) > MAX_EVENT_FRAME:
        raise ValueError("fixture frame exceeds v1 limit")
    return frame


@dataclass
class FloodStats:
    frames: int = 0
    payload_bytes: int = 0
    wire_bytes: int = 0
    first_seq: Optional[int] = None
    last_seq: Optional[int] = None
    cumulative_credit: int = 0
    max_outstanding_credit: int = 0
    max_ping_latency_ms: float = 0.0
    pings_handled: int = 0
    client_ids: list = None

    def as_dict(self):
        return {
            "frames": self.frames,
            "payload_bytes": self.payload_bytes,
            "wire_bytes": self.wire_bytes,
            "first_seq": self.first_seq,
            "last_seq": self.last_seq,
            "cumulative_credit": self.cumulative_credit,
            "max_outstanding_credit": self.max_outstanding_credit,
            "max_ping_latency_ms": self.max_ping_latency_ms,
            "pings_handled": self.pings_handled,
            "client_ids": list(self.client_ids or []),
        }


def iter_credited_flood(credit, *, seconds=5.0, start_seq=0,
                        request_id="ag3-flood", stop_after=None):
    """Yield legal small event frames while credited and before a deadline.

    Credit is charged by complete wire-frame length.  ``stop_after`` is a
    deterministic test seam that stops after that many frames, independent of
    wall-clock scheduling.  The normal mode runs until the five-second
    deadline or credit exhaustion.
    """
    if type(credit) is not int or credit < 0:
        raise ValueError("credit must be a non-negative integer")
    if seconds <= 0:
        return
    deadline = time.monotonic() + float(seconds)
    # Keep a single fixture invocation within the helper's bounded ordinary
    # event queue even when a caller grants more than the v1 initial credit.
    remaining = min(credit, MAX_EVENT_QUEUE)
    seq = start_seq
    emitted = 0
    while time.monotonic() < deadline:
        event = {"v": 1, "kind": "event", "seq": seq,
                 "event": "stream", "request_id": request_id,
                 "data": {"name": "stdout", "text": "x"}}
        frame = encode_frame(event)
        if len(frame) > remaining:
            break
        yield frame
        remaining -= len(frame)
        seq += 1
        emitted += 1
        if stop_after is not None and emitted >= stop_after:
            break


def run_flood(credit, *, seconds=5.0, fragment=0, stop_after=None,
              stats_path=None):
    """Write a credited flood, optionally fragmented at deterministic cuts."""
    stats = FloodStats()
    stats.client_ids = []
    for frame in iter_credited_flood(credit, seconds=seconds,
                                     stop_after=stop_after):
        cuts = (fragment if fragment else len(frame))
        if cuts <= 0:
            raise ValueError("fragment must be positive")
        for offset in range(0, len(frame), cuts):
            sys.stdout.buffer.write(frame[offset:offset + cuts])
            sys.stdout.buffer.flush()
        payload_size = len(frame) - 4
        stats.frames += 1
        stats.payload_bytes += payload_size
        stats.wire_bytes += len(frame)
        sequence = json.loads(frame[4:])["seq"]
        stats.first_seq = sequence if stats.first_seq is None else stats.first_seq
        stats.last_seq = sequence
    if stats_path:
        Path(stats_path).write_text(json.dumps(stats.as_dict(), sort_keys=True) + "\n",
                                    encoding="utf-8")
    return stats


def _write_frame(frame, fragment):
    """Write one frame, using a repeatable fixed-size fragmentation seam."""
    step = fragment or len(frame)
    if step <= 0:
        raise ValueError("fragment must be positive")
    for offset in range(0, len(frame), step):
        sys.stdout.buffer.write(frame[offset:offset + step])
        sys.stdout.buffer.flush()


def _response(request, result=None):
    return encode_frame({"v": 1, "kind": "response", "id": request.get("id", ""),
                         "ok": True, "result": result or {}})


def run_helper(*, seconds=5.0, fragment=0, stop_after=None, stats_path=None):
    """Run an interactive credited fake helper until its flood deadline.

    Input requests are read opportunistically while output is flowing.  Event
    bytes are deducted before each write, so no ordinary event can cross the
    wire without sufficient current credit.
    """
    stats = FloodStats()
    stats.client_ids = []
    input_buffer = bytearray()
    priority = []  # (frame, offset, is_event, class), control classes are response/ping
    current = None
    outstanding = 0
    sequence = 0
    emitted = 0
    pending_peak = 0
    deadline = None
    first_grant_seen = False
    ping_sent_at = {}
    fd_in = sys.stdin.buffer.fileno()
    fd_out = sys.stdout.buffer.fileno()
    os.set_blocking(fd_out, False)
    last_publish = 0.0

    def publish(force=False):
        nonlocal last_publish
        if not stats_path or not force and time.monotonic() - last_publish < 0.1:
            return
        now = time.monotonic()
        value = stats.as_dict()
        value.update({"first_grant_elapsed": (None if deadline is None else
                                                max(0.0, now - (deadline - seconds))),
                      "active_elapsed": (0.0 if deadline is None else
                                          min(float(seconds), max(0.0, now - (deadline - seconds)))),
                      "pending_output_peak": pending_peak,
                      "pending_output_bytes": ((len(current[0]) - current[1]) if current else 0) +
                      sum(len(item[0]) for item in priority)})
        temporary = stats_path + ".tmp"
        Path(temporary).write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
        os.replace(temporary, stats_path)
        last_publish = now

    def enqueue(frame, is_event=False, output_class=None):
        nonlocal current, pending_peak
        item = [bytearray(frame), 0, is_event,
                output_class or ("event" if is_event else "response")]
        # A control response may jump ahead of an event that has not started
        # writing.  A partially written frame remains current to preserve the
        # wire stream's integrity.
        if (not is_event and current is not None and current[1] == 0
                and (output_class == "ping" or (current[2] and not priority))):
            # Only the oldest ordinary response may displace an unstarted
            # event.  Otherwise a newer credit acknowledgement could jump
            # older acknowledgements already queued behind that event.  Ping
            # responses remain independently privileged for the latency gate.
            priority.insert(0, current)
            current = None
        if current is None:
            current = item
        elif is_event:
            return False
        else:
            if sum(len(queued[0]) - queued[1] for queued in priority) + len(frame) > MAX_PENDING_OUTPUT:
                return False
            if item[3] == "ping":
                index = next((i for i, queued in enumerate(priority)
                              if queued[3] != "ping"), len(priority))
                priority.insert(index, item)
            else:
                priority.append(item)
        pending = ((len(current[0]) - current[1]) if current else 0) + sum(
            len(item[0]) - item[1] for item in priority)
        pending_peak = max(pending_peak, pending)
        return True

    def handle(request):
        nonlocal outstanding, deadline, first_grant_seen
        op = request.get("op")
        if op == "hello":
            return enqueue(_response(request, {"version": 1, "helper_version": "ag3-fixture",
                                               "capabilities": ["ping", "flood"]}))
        elif op == "grant_event_credit":
            amount = request.get("params", {}).get("bytes")
            if type(amount) is not int or amount < 0:
                return enqueue(encode_frame({"v": 1, "kind": "response", "id": request.get("id", ""),
                                             "ok": False, "error": {"code": "invalid-request",
                                                                        "message": "invalid credit"}}))
            outstanding += amount
            request_id = request.get("id")
            if request_id and request_id not in stats.client_ids:
                stats.client_ids.append(request_id)
            stats.cumulative_credit += amount
            stats.max_outstanding_credit = max(stats.max_outstanding_credit, outstanding)
            if not first_grant_seen:
                first_grant_seen = True
                deadline = time.monotonic() + float(seconds)
            return enqueue(_response(request, {"credited": amount}))
        elif op == "ping":
            stats.pings_handled += 1
            request_id = request.get("id")
            if request_id and request_id not in stats.client_ids:
                stats.client_ids.append(request_id)
            sent = ping_sent_at.pop(request.get("id"), None)
            if sent is not None:
                stats.max_ping_latency_ms = max(stats.max_ping_latency_ms,
                                               (time.monotonic() - sent) * 1000.0)
            return enqueue(_response(request, {"pong": True}), output_class="ping")
        return enqueue(encode_frame({"v": 1, "kind": "response", "id": request.get("id", ""),
                                     "ok": False, "error": {"code": "unsupported",
                                                                "message": "unsupported fixture op"}}))

    def drain_input():
        input_open = True
        try:
            while select.select([fd_in], [], [], 0)[0]:
                room = MAX_INPUT_BUFFER - len(input_buffer)
                if room <= 0:
                    break
                chunk = os.read(fd_in, min(65536, room))
                if not chunk:
                    input_open = False
                    break
                input_buffer.extend(chunk)
        except OSError:
            input_open = False
        parsed = 0
        while len(input_buffer) >= 4 and parsed < 32:
            length = struct.unpack(">I", input_buffer[:4])[0]
            if length + 4 > MAX_INPUT_BUFFER:
                raise RuntimeError("AG3 fixture input frame exceeds its bound")
            if len(input_buffer) < length + 4:
                break
            payload = bytes(input_buffer[4:length + 4])
            del input_buffer[:length + 4]
            try:
                request = json.loads(payload.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                raise RuntimeError("AG3 fixture received malformed JSON")
            if not isinstance(request, dict):
                raise RuntimeError("AG3 fixture request is not an object")
            if request.get("op") == "ping":
                ping_sent_at[request.get("id")] = time.monotonic()
            handle(request)
            parsed += 1
        if not input_open and input_buffer and parsed < 32:
            raise RuntimeError("AG3 fixture received a truncated input frame")
        if len(input_buffer) >= MAX_INPUT_BUFFER:
            raise RuntimeError("AG3 fixture input accumulator reached its bound")
        return input_open

    def write_ready():
        nonlocal current
        if current is None:
            return
        try:
            limit = fragment or len(current[0])
            written = os.write(fd_out, current[0][current[1]:current[1] + limit])
        except BlockingIOError:
            written = 0
        if written:
            current[1] += written
            if current[1] == len(current[0]):
                if current[2]:
                    stats.frames += 1
                    stats.payload_bytes += len(current[0]) - 4
                    stats.wire_bytes += len(current[0])
                    stats.first_seq = sequence - stats.frames if stats.first_seq is None else stats.first_seq
                    stats.last_seq = stats.first_seq + stats.frames - 1
                current = priority.pop(0) if priority else None

    def flush_pending():
        """Finish complete queued frames without ever blocking on stdout."""
        nonlocal current
        flush_deadline = time.monotonic() + 2.0
        while current is not None or priority:
            if time.monotonic() >= flush_deadline:
                raise RuntimeError("AG3 fixture bounded output flush timed out")
            if current is None:
                current = priority.pop(0)
            readable, writable, _ = select.select([fd_in], [fd_out], [], 0.01)
            if readable:
                drain_input()
            if writable:
                write_ready()
            publish()

    try:
        while deadline is None or time.monotonic() < deadline:
            # Input is always drained before making another ordinary event.
            input_open = drain_input()
            if not input_open and not input_buffer and deadline is None:
                break
            if deadline is not None and current is None and outstanding:
                event = {"v": 1, "kind": "event", "seq": sequence,
                         "event": "stream", "request_id": "ag3-flood",
                         "data": {"name": "stdout", "text": "x"}}
                frame = encode_frame(event)
                if len(frame) <= outstanding:
                    outstanding -= len(frame)  # charge exactly once at enqueue
                    current = [bytearray(frame), 0, True, "event"]
                    sequence += 1
                    emitted += 1
                    if stop_after is not None and emitted >= stop_after:
                        deadline = time.monotonic()
            writable = current is not None
            readable, _, _ = select.select([fd_in], [fd_out] if writable else [], [], 0.002)
            if readable:
                input_open = drain_input()
                if not input_open and not input_buffer and deadline is None:
                    break
            if writable:
                write_ready()
            publish()
        flush_pending()
    finally:
        publish(force=True)
    return stats


def _stream_pattern(path, size, seed):
    """Write exactly SIZE bytes using a repeatable, bounded-memory pattern."""
    if type(size) is not int or size < 0:
        raise ValueError("size must be a non-negative integer")
    digest = hashlib.sha256(str(seed).encode("ascii")).digest()
    block = (digest * ((BLOCK_BYTES // len(digest)) + 1))[:BLOCK_BYTES]
    with open(path, "wb") as output:
        remaining = size
        while remaining:
            chunk = block[:min(remaining, len(block))]
            output.write(chunk)
            remaining -= len(chunk)


def _descriptor(path, mime):
    digest = hashlib.sha256()
    size = 0
    with open(path, "rb") as source:
        while True:
            chunk = source.read(BLOCK_BYTES)
            if not chunk:
                break
            digest.update(chunk)
            size += len(chunk)
    return {"path": str(Path(path).resolve()), "bytes": size,
            "sha256": digest.hexdigest(), "mime": mime}


def write_exact_artifact(directory, name, size, *, seed="ag3"):
    """Write an exact-size deterministic artifact and return its descriptor."""
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / name
    _stream_pattern(path, size, seed)
    return _descriptor(path, "application/x-ejn-mpl-pickle")


def tiny_png(width=1, height=1, seed=0):
    """Return a tiny metadata-valid PNG prefix, including a unique tEXt chunk."""
    text = ("ag3-%d" % seed).encode("ascii")
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    def chunk(kind, data):
        return (struct.pack(">I", len(data)) + kind + data +
                struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) +
            chunk(b"tEXt", b"Comment\0" + text) + chunk(b"IEND", b""))


def tiny_jpeg(width=1, height=1):
    """Return a minimal JPEG header with a metadata-parser-visible SOF."""
    sof = b"\xff\xc0" + struct.pack(">H", 17) + bytes((8,))
    sof += struct.pack(">HHB", height, width, 3) + b"\x01\x11\0\x02\x11\0\x03\x11\0\0\0"
    return b"\xff\xd8" + sof


def write_dimension_bomb(directory, mime, width=4097, height=1024):
    """Write a tiny PNG/JPEG advertising dimensions over the pixel ceiling."""
    if width * height <= MAX_IMAGE_PIXELS:
        raise ValueError("bomb must exceed pixel ceiling")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    suffix = ".png" if mime == "image/png" else ".jpg"
    path = directory / ("dimension-bomb" + suffix)
    data = tiny_png(width, height) if mime == "image/png" else tiny_jpeg(width, height)
    path.write_bytes(data)
    return _descriptor(path, mime)


def write_tiny_images(directory, count=100):
    """Write COUNT uniquely identified tiny PNGs and return descriptors."""
    if type(count) is not int or count < 0:
        raise ValueError("count must be a non-negative integer")
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    result = []
    for index in range(count):
        path = directory / ("tiny-%03d.png" % index)
        path.write_bytes(tiny_png(seed=index))
        descriptor = _descriptor(path, "image/png")
        descriptor["display_id"] = "ag3-%03d" % index
        result.append(descriptor)
    return result


def self_test():
    import tempfile
    with tempfile.TemporaryDirectory(prefix="ejn-ag3-") as root:
        root = Path(root)
        exact = write_exact_artifact(root, "exact", MAX_ARTIFACT_BYTES)
        over = write_exact_artifact(root, "over", MAX_ARTIFACT_BYTES + 1)
        assert exact["bytes"] == MAX_ARTIFACT_BYTES
        assert over["bytes"] == MAX_ARTIFACT_BYTES + 1
        assert exact["sha256"] == EXACT_ARTIFACT_SHA256
        png_bomb = write_dimension_bomb(root, "image/png")
        jpeg_bomb = write_dimension_bomb(root, "image/jpeg")
        assert png_bomb["bytes"] < 1024 and jpeg_bomb["bytes"] < 1024
        assert struct.unpack(">II", (root / "dimension-bomb.png").read_bytes()[16:24]) == (4097, 1024)
        assert struct.unpack(">HH", (root / "dimension-bomb.jpg").read_bytes()[7:11]) == (1024, 4097)
        images = write_tiny_images(root / "images")
        assert len(images) == 100 and len({x["display_id"] for x in images}) == 100
        assert len({x["sha256"] for x in images}) == 100
        frames = list(iter_credited_flood(4096, seconds=5, stop_after=8))
        assert len(frames) == 8 and all(len(frame) <= MAX_EVENT_FRAME for frame in frames)
        decoded = [json.loads(frame[4:]) for frame in frames]
        assert [event["seq"] for event in decoded] == list(range(8))
        assert sum(map(len, frames)) <= 4096
        command = [sys.executable, str(Path(__file__).resolve()), "helper",
                   "--seconds", "0.35", "--fragment", "3", "--stats",
                   str(root / "helper-stats.json")]
        child = subprocess.Popen(command, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            def send(obj):
                child.stdin.write(encode_frame(obj))
                child.stdin.flush()
            def read_one(deadline):
                raw = bytearray()
                while len(raw) < 4 and time.monotonic() < deadline:
                    ready, _, _ = select.select([child.stdout], [], [], 0.05)
                    if ready:
                        raw.extend(os.read(child.stdout.fileno(), 4 - len(raw)))
                if len(raw) < 4:
                    raise AssertionError("interactive helper response deadline")
                length = struct.unpack(">I", raw)[0]
                while len(raw) < length + 4:
                    ready, _, _ = select.select([child.stdout], [], [], 0.05)
                    if not ready:
                        raise AssertionError("interactive helper frame deadline")
                    raw.extend(os.read(child.stdout.fileno(), length + 4 - len(raw)))
                return json.loads(bytes(raw[4:]).decode("utf-8"))
            send({"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {}})
            assert read_one(time.monotonic() + 1)["ok"]
            send({"v": 1, "kind": "request", "id": "g1", "op": "grant_event_credit",
                  "params": {"bytes": 448}})
            # Let the child encounter a stalled reader before control traffic
            # is sent, exercising its nonblocking output/input multiplexing.
            time.sleep(0.1)
            assert read_one(time.monotonic() + 1)["id"] == "g1"
            first = read_one(time.monotonic() + 1)
            assert first["kind"] == "event"
            send({"v": 1, "kind": "request", "id": "p", "op": "ping", "params": {}})
            grants = ["g%d" % number for number in range(2, 9)]
            for grant in grants:
                send({"v": 1, "kind": "request", "id": grant,
                      "op": "grant_event_credit", "params": {"bytes": 448}})
            seen = [first["seq"]]
            ping_seen = False
            grant_replies = []
            deadline = time.monotonic() + 1
            while time.monotonic() < deadline and (not ping_seen or len(grant_replies) < len(grants)):
                obj = read_one(deadline)
                if obj["kind"] == "event":
                    seen.append(obj["seq"])
                elif obj["id"] == "p":
                    ping_seen = True
                else:
                    grant_replies.append(obj["id"])
            assert ping_seen
            assert grant_replies == grants
            assert seen == list(range(len(seen))) and len(seen) >= 2
            child.stdin.close()
            child.wait(timeout=2)
            assert child.returncode == 0
            helper_stats = json.loads((root / "helper-stats.json").read_text())
            expected_credit = 448 * (1 + len(grants))
            assert helper_stats["cumulative_credit"] == expected_credit
            assert helper_stats["wire_bytes"] <= helper_stats["cumulative_credit"]
            assert helper_stats["max_outstanding_credit"] <= expected_credit
            assert helper_stats["pings_handled"] == 1
            assert "p" in helper_stats["client_ids"]
            assert helper_stats["max_ping_latency_ms"] >= 0

            # The stop seam must flush a one-byte-fragmented response/event
            # stream rather than exiting with a partial frame.
            stop_stats_path = root / "stop-stats.json"
            stopped = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "helper",
                 "--seconds", "5", "--fragment", "1", "--stop-after", "1",
                 "--stats", str(stop_stats_path)], stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            stopped.stdin.write(encode_frame({"v": 1, "kind": "request", "id": "h2",
                                               "op": "hello", "params": {}}))
            stopped.stdin.write(encode_frame({"v": 1, "kind": "request", "id": "g2",
                                               "op": "grant_event_credit", "params": {"bytes": 448}}))
            stopped.stdin.close()
            stopped.wait(timeout=2)
            assert stopped.returncode == 0
            raw = stopped.stdout.read()
            offset = 0
            while offset < len(raw):
                assert offset + 4 <= len(raw)
                length = struct.unpack(">I", raw[offset:offset + 4])[0]
                assert offset + 4 + length <= len(raw)
                json.loads(raw[offset + 4:offset + 4 + length].decode("utf-8"))
                offset += 4 + length
            stop_stats = json.loads(stop_stats_path.read_text())
            assert stop_stats["frames"] == 1
            assert stop_stats["pending_output_bytes"] == 0
            assert stopped.stderr.read() == b""

            # Hostile input cannot grow the fixture's accumulator without a
            # bound or turn EOF in a partial frame into a successful exit.
            hostile_cases = (
                (struct.pack(">I", MAX_INPUT_BUFFER), b"input frame exceeds its bound"),
                (struct.pack(">I", 10) + b"{}", b"truncated input frame"),
            )
            for wire, diagnostic in hostile_cases:
                hostile = subprocess.run(
                    [sys.executable, str(Path(__file__).resolve()), "helper",
                     "--seconds", "5"], input=wire, stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, timeout=2, check=False)
                assert hostile.returncode != 0
                assert hostile.stdout == b""
                assert diagnostic in hostile.stderr
                assert len(hostile.stderr) < 4096
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
            # Remaining bytes are expected event frames emitted just before
            # the deadline; verify they are complete protocol frames rather
            # than treating valid output as process residue.
            tail = child.stdout.read()
            offset = 0
            while offset < len(tail):
                assert offset + 4 <= len(tail)
                length = struct.unpack(">I", tail[offset:offset + 4])[0]
                assert offset + 4 + length <= len(tail)
                json.loads(tail[offset + 4:offset + 4 + length].decode("utf-8"))
                offset += 4 + length
            assert child.stderr.read() == b""
        assert not list(root.glob(".ejn-*"))
    return True


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    flood = sub.add_parser("flood")
    flood.add_argument("--credit", type=int, required=True)
    flood.add_argument("--seconds", type=float, default=5.0)
    flood.add_argument("--fragment", type=int, default=0)
    flood.add_argument("--stop-after", type=int)
    flood.add_argument("--stats")
    helper = sub.add_parser("helper")
    helper.add_argument("--seconds", type=float, default=5.0)
    helper.add_argument("--fragment", type=int, default=0)
    helper.add_argument("--stop-after", type=int)
    helper.add_argument("--stats")
    sub.add_parser("self-test")
    args = parser.parse_args()
    if args.mode == "self-test":
        self_test()
        return 0
    if args.mode == "helper":
        run_helper(seconds=args.seconds, fragment=args.fragment,
                   stop_after=args.stop_after, stats_path=args.stats)
    else:
        run_flood(args.credit, seconds=args.seconds, fragment=args.fragment,
                  stop_after=args.stop_after, stats_path=args.stats)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
