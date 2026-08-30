#!/usr/bin/env python3
"""Deterministic live fake helper for Emacs process tests."""

import argparse
import json
import os
import selectors
import subprocess
import sys
import tempfile
import time
from pathlib import Path

MAX_TO_EMACS_FRAME = 262144
MAX_TO_HELPER_FRAME = 1048576


def encode(message):
    payload = json.dumps(message, ensure_ascii=False, sort_keys=True,
                         separators=(",", ":")).encode("utf-8")
    return len(payload).to_bytes(4, "big") + payload


def read_exact(stream, count):
    chunks = []
    remaining = count
    while remaining:
        chunk = stream.read(remaining)
        if not chunk:
            return None
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_frame(stream):
    prefix = read_exact(stream, 4)
    if prefix is None:
        return None
    length = int.from_bytes(prefix, "big")
    if length + 4 > MAX_TO_HELPER_FRAME:
        return None
    payload = read_exact(stream, length)
    if payload is None:
        return None
    try:
        message = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    return message if isinstance(message, dict) else None


def decode_frames(data):
    messages = []
    offset = 0
    while offset + 4 <= len(data):
        length = int.from_bytes(data[offset:offset + 4], "big")
        if offset + 4 + length > len(data):
            break
        messages.append(json.loads(data[offset + 4:offset + 4 + length].decode("utf-8")))
        offset += 4 + length
    return messages


def record(path, message, state):
    if path is None or state["records"] >= 1000:
        return
    text = json.dumps(message, sort_keys=True, separators=(",", ":"))
    if message.get("op") == "input_reply":
        params = dict(message.get("params", {}))
        if "value" in params:
            params["value"] = "<redacted>"
        safe = dict(message)
        safe["params"] = params
        text = json.dumps(safe, sort_keys=True, separators=(",", ":"))
    remaining = max(0, 8192 - state["bytes"])
    if remaining <= 1:
        return
    text = text[:remaining - 1]
    with open(path, "a", encoding="utf-8") as output:
        output.write(text + "\n")
        output.flush()
    state["records"] += 1
    state["bytes"] += len(text) + 1


def response(message, scenario):
    if message.get("op") == "hello":
        result = {
            "version": 1,
            "helper_version": "fake-helper-1",
            "capabilities": ["ping", "execute"],
        }
    else:
        result = {"scenario": scenario}
    return encode({"v": 1, "kind": "response", "id": message.get("id", "unknown"), "ok": True, "result": result})


def write_response(data, fragmented=False, delay_ms=0):
    if not fragmented:
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
        return
    delay = min(max(delay_ms, 0), 50) / 1000.0
    for byte in data:
        sys.stdout.buffer.write(bytes([byte]))
        sys.stdout.buffer.flush()
        if delay:
            time.sleep(delay)


def run(args):
    state = {"records": 0, "bytes": 0}
    first = read_frame(sys.stdin.buffer)
    if first is None:
        return 0
    record(args.requests, first, state)
    if args.scenario == "silent":
        while True:
            message = read_frame(sys.stdin.buffer)
            if message is None:
                return 0
            record(args.requests, message, state)
    if args.scenario == "garbage":
        sys.stdout.buffer.write(b"not-a-frame")
        sys.stdout.buffer.flush()
        return 0
    if args.scenario == "oversize":
        sys.stdout.buffer.write((MAX_TO_EMACS_FRAME - 3).to_bytes(4, "big"))
        sys.stdout.buffer.flush()
        return 0
    if args.scenario == "mid-frame-stop":
        sys.stdout.buffer.write(response(first, args.scenario)[:7])
        sys.stdout.buffer.flush()
        return 0
    if args.scenario == "late-response":
        time.sleep(min(max(args.delay_ms, 1), 5000) / 1000.0)
        write_response(response(first, args.scenario))
    elif args.scenario == "flood":
        for seq in range(min(max(args.count, 1), 1000)):
            sys.stdout.buffer.write(encode({"v": 1, "kind": "event", "seq": seq, "event": "stream", "request_id": first.get("id", "flood"), "data": {"name": "stdout", "text": "x"}}))
        write_response(response(first, args.scenario), args.scenario == "fragmented", args.fragment_delay_ms)
    elif args.scenario == "exit-after-op" and first.get("op") == args.op:
        if args.respond:
            sys.stdout.buffer.write(response(first, args.scenario))
            sys.stdout.buffer.flush()
        return 0
    else:
        write_response(response(first, args.scenario), args.scenario == "fragmented", args.fragment_delay_ms)
    if args.scenario in {"normal", "fragmented", "late-response"}:
        while True:
            message = read_frame(sys.stdin.buffer)
            if message is None:
                return 0
            record(args.requests, message, state)
            output = response(message, args.scenario)
            write_response(output, args.scenario == "fragmented", args.fragment_delay_ms)

def read_one_wire_frame(child, deadline):
    """Read and decode one child frame using a monotonic deadline."""
    with selectors.DefaultSelector() as selector:
        selector.register(child.stdout, selectors.EVENT_READ)
        data = bytearray()
        while len(data) < 4:
            if not selector.select(max(0.0, deadline - time.monotonic())):
                raise SystemExit("self-test read deadline expired")
            chunk = os.read(child.stdout.fileno(), 4 - len(data))
            if not chunk:
                raise SystemExit("self-test child closed before frame")
            data.extend(chunk)
        length = int.from_bytes(data[:4], "big")
        while len(data) < length + 4:
            if not selector.select(max(0.0, deadline - time.monotonic())):
                raise SystemExit("self-test frame deadline expired")
            chunk = os.read(child.stdout.fileno(), length + 4 - len(data))
            if not chunk:
                raise SystemExit("self-test frame truncated")
            data.extend(chunk)
    return json.loads(bytes(data[4:]).decode("utf-8")), bytes(data)


def self_test():
    script = str(Path(__file__).resolve())
    hello = decode_frames(response(
        {"id": "hello-1", "op": "hello"}, "normal"
    ))[0]
    if hello.get("result", {}).get("helper_version") != "fake-helper-1":
        raise SystemExit("self-test failed: hello helper version")
    if "build" in hello.get("result", {}):
        raise SystemExit("self-test failed: obsolete hello build field")
    request = encode({"v": 1, "kind": "request", "id": "test-1", "op": "ping", "params": {}})
    scenarios = ("normal", "silent", "garbage", "fragmented", "oversize", "mid-frame-stop", "flood", "late-response", "exit-after-op")
    for scenario in scenarios:
        for run in range(2):
            command = [sys.executable, script, scenario]
            temporary = None
            request_log = None
            if scenario == "late-response": command += ["--delay-ms", "100"]
            if scenario == "fragmented": command += ["--fragment-delay-ms", "1"]
            if scenario == "flood": command += ["--count", "7"]
            if scenario == "silent":
                temporary = tempfile.TemporaryDirectory()
                request_log = Path(temporary.name) / "requests.jsonl"
                command += ["--requests", str(request_log)]
            if scenario == "exit-after-op":
                command += ["--op", "ping"]
                if run == 1: command += ["--respond"]
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                child.stdin.write(request); child.stdin.flush()
                if scenario == "silent":
                    deadline = time.monotonic() + 2
                    while (not request_log.exists()
                           or '"id":"test-1"' not in request_log.read_text()):
                        if time.monotonic() >= deadline:
                            raise SystemExit("self-test failed: silent did not record request")
                        time.sleep(0.005)
                    if child.poll() is not None:
                        raise SystemExit("self-test failed: silent exited early")
                    with selectors.DefaultSelector() as selector:
                        selector.register(child.stdout, selectors.EVENT_READ)
                        if selector.select(0.05):
                            raise SystemExit("self-test failed: silent emitted output")
                    child.kill()
                    child.wait(timeout=2)
                    continue
                if scenario in {"normal", "fragmented", "late-response"}:
                    deadline = time.monotonic() + 3
                    if scenario == "late-response":
                        with selectors.DefaultSelector() as selector:
                            selector.register(child.stdout, selectors.EVENT_READ)
                            if selector.select(0.05):
                                raise SystemExit("self-test failed: early late response")
                    started = time.monotonic()
                    first_message, first_wire = read_one_wire_frame(child, deadline)
                    if scenario == "fragmented" and time.monotonic() - started < 0.02:
                        raise SystemExit("self-test failed: response was not fragmented")
                    if first_message.get("id") != "test-1" or first_message.get("kind") != "response" or not first_message.get("ok"):
                        raise SystemExit("self-test failed: first correlation")
                    if first_message.get("result", {}).get("scenario") != scenario:
                        raise SystemExit("self-test failed: first result")
                    child.stdin.write(request.replace(b"test-1", b"test-2")); child.stdin.flush()
                    second_message, second_wire = read_one_wire_frame(child, deadline)
                    if second_message.get("id") != "test-2" or second_message.get("kind") != "response" or not second_message.get("ok"):
                        raise SystemExit("self-test failed: second correlation")
                    if second_message.get("result", {}).get("scenario") != scenario:
                        raise SystemExit("self-test failed: second result")
                    output = bytearray(first_wire + second_wire)
                    child.stdin.close(); child.wait(timeout=2)
                else:
                    child.stdin.close(); out, _ = child.communicate(timeout=2); output = bytearray(out)
                if scenario == "garbage" and bytes(output) != b"not-a-frame": raise SystemExit("self-test failed: garbage bytes")
                if scenario == "oversize" and bytes(output) != (MAX_TO_EMACS_FRAME - 3).to_bytes(4, "big"): raise SystemExit("self-test failed: oversize prefix")
                if scenario == "mid-frame-stop" and bytes(output) != response({"id": "test-1"}, scenario)[:7]: raise SystemExit("self-test failed: partial bytes")
                if scenario == "exit-after-op" and run == 0 and output: raise SystemExit("self-test failed: early exit output")
                if scenario == "exit-after-op" and run == 1:
                    messages = decode_frames(bytes(output))
                    if len(messages) != 1 or messages[0].get("id") != "test-1": raise SystemExit("self-test failed: exit response")
                if scenario == "flood":
                    frames = decode_frames(bytes(output))
                    if len(frames) != 8 or [frame["seq"] for frame in frames[:7]] != list(range(7)) or frames[-1].get("id") != "test-1": raise SystemExit("self-test failed: flood content")
            finally:
                if child.poll() is None: child.kill(); child.wait(timeout=2)
                if temporary is not None:
                    temporary.cleanup()
    print("fake helper self-test: valid (9 live scenarios)")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("scenario", nargs="?")
    parser.add_argument("--requests", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--delay-ms", type=int, default=100)
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument("--op", default="hello")
    parser.add_argument("--respond", action="store_true")
    parser.add_argument("--fragment-delay-ms", type=int, default=0)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return 0
    scenarios = {"normal", "silent", "garbage", "fragmented", "oversize", "mid-frame-stop", "flood", "late-response", "exit-after-op"}
    if args.scenario not in scenarios:
        parser.error("scenario is required")
    return run(args)


if __name__ == "__main__":
    raise SystemExit(main())
