#!/usr/bin/env python3
"""Small deterministic protocol-v1 helper for Gate 3 lifecycle faults."""
import argparse
import json
import struct
import sys
import time

MAX_FRAME = 1048576


def frame(value):
    payload = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
    if len(payload) + 4 > MAX_FRAME:
        raise ValueError("fixture frame too large")
    return struct.pack(">I", len(payload)) + payload


def read_frame(stream):
    prefix = stream.read(4)
    if len(prefix) != 4:
        return None
    length = struct.unpack(">I", prefix)[0]
    if length + 4 > MAX_FRAME:
        return None
    payload = stream.read(length)
    if len(payload) != length:
        return None
    value = json.loads(payload.decode("utf-8"))
    return value if isinstance(value, dict) else None


def response(request, result=None):
    return frame({"v": 1, "kind": "response", "id": request.get("id", ""),
                  "ok": True, "result": result or {}})


def write(stream, payload):
    stream.buffer.write(payload)
    stream.buffer.flush()


def run(phase, timing, late_delay):
    request = read_frame(sys.stdin.buffer)
    if request is None:
        return 0
    if phase == "hello" and timing == "pre":
        return 0
    if request.get("op") != "hello":
        return 0
    write(sys.stdout, response(request, {"version": 1, "helper_version": "ag3-lifecycle",
                                         "capabilities": ["ping", "connect", "execute"]}))
    if phase == "hello":
        return 0
    while True:
        request = read_frame(sys.stdin.buffer)
        if request is None:
            return 0
        operation = request.get("op")
        if operation == "grant_event_credit":
            if phase == "grant_event_credit" and timing == "pre":
                return 0
            write(sys.stdout, response(request, {"credited": request.get("params", {}).get("bytes", 0)}))
            if phase in ("grant_event_credit", "ready-idle"):
                return 0
            continue
        if operation == "ping":
            if phase == "ping" and timing == "pre":
                return 0
            if phase == "late-ping":
                time.sleep(late_delay)
            write(sys.stdout, response(request, {"pong": True}))
            if phase == "ping":
                return 0
            continue
        if operation in ("connect", "execute", "close"):
            if operation == phase and timing == "pre":
                return 0
            write(sys.stdout, response(request, {"accepted": operation}))
            if operation == phase:
                return 0


def self_test():
    import subprocess
    for phase, timing in (("hello", "pre"), ("hello", "post"),
                          ("grant_event_credit", "pre"), ("grant_event_credit", "post"),
                          ("ready-idle", "post"), ("ping", "pre"), ("ping", "post"),
                          ("connect", "pre"), ("connect", "post"),
                          ("execute", "pre"), ("execute", "post"),
                          ("close", "pre"), ("close", "post")):
        child = subprocess.Popen([sys.executable, __file__, phase, timing],
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE)
        hello = {"v": 1, "kind": "request", "id": "h", "op": "hello", "params": {}}
        child.stdin.write(frame(hello)); child.stdin.flush()
        if not (phase == "hello" and timing == "pre"):
            assert read_frame(child.stdout) is not None
        if not (phase == "hello"):
            child.stdin.write(frame({"v": 1, "kind": "request", "id": "g", "op": "grant_event_credit", "params": {"bytes": 262144}})); child.stdin.flush()
            if not (phase == "grant_event_credit" and timing == "pre"):
                assert read_frame(child.stdout) is not None
        if phase == "ping":
            child.stdin.write(frame({"v": 1, "kind": "request", "id": "p", "op": "ping", "params": {}})); child.stdin.flush()
            if timing == "post": assert read_frame(child.stdout) is not None
        if phase in ("connect", "execute", "close"):
            child.stdin.write(frame({"v": 1, "kind": "request", "id": "o",
                                     "op": phase, "params": {}})); child.stdin.flush()
            if timing == "post": assert read_frame(child.stdout) is not None
        child.stdin.close(); child.wait(timeout=2)
        assert child.returncode == 0 and child.stderr.read() == b""
    child = subprocess.Popen(
        [sys.executable, __file__, "late-ping", "post", "--late-delay", "0.05"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    for message in (
            {"v": 1, "kind": "request", "id": "late-h", "op": "hello", "params": {}},
            {"v": 1, "kind": "request", "id": "late-g", "op": "grant_event_credit",
             "params": {"bytes": 262144}}):
        child.stdin.write(frame(message)); child.stdin.flush()
        assert read_frame(child.stdout) is not None
    started = time.monotonic()
    child.stdin.write(frame({"v": 1, "kind": "request", "id": "late-p",
                             "op": "ping", "params": {}}))
    child.stdin.flush()
    assert read_frame(child.stdout) is not None
    assert time.monotonic() - started >= 0.04
    child.stdin.close(); child.wait(timeout=2)
    assert child.returncode == 0 and child.stderr.read() == b""
    print("ag3 lifecycle fixture self-test: valid")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("phase", nargs="?")
    parser.add_argument("timing", nargs="?", choices=("pre", "post"))
    parser.add_argument("--late-delay", type=float, default=0.5)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test(); return 0
    if args.phase not in {"hello", "grant_event_credit", "ready-idle", "ping", "late-ping", "connect", "execute", "close"}:
        parser.error("unsupported lifecycle phase")
    return run(args.phase, args.timing or "post", args.late_delay)


if __name__ == "__main__":
    raise SystemExit(main())
