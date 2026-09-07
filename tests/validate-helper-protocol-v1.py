#!/usr/bin/env python3
"""Validate helper protocol v1 golden frames (Python standard library only)."""
import copy, json, os, struct, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests" / "fixtures" / "helper-protocol-v1.json"
OPS = {"hello", "ping", "grant_event_credit", "connect", "kernel_info", "execute", "complete", "inspect", "variables", "is_complete", "input_reply", "interrupt", "shutdown", "close"}
EVENTS = {"stream", "display_data", "execute_result", "clear_output", "status", "execute_reply", "input_request", "transport_error", "output_truncated"}
ERRORS = {"invalid-request", "invalid-event", "unsupported", "timeout", "protocol-error", "frame-too-large", "credit-exhausted", "transport-error", "busy"}
NO_PARAMS = {"ping", "kernel_info", "interrupt", "shutdown", "close"}
PRIORITY = {"status", "execute_reply", "input_request", "transport_error", "output_truncated"}
ENCODING = {"ensure_ascii": False, "sort_keys": True, "separators": [",", ":"]}
LIMITS = {
    "max_to_emacs_frame": 262144,
    "max_to_helper_frame": 1048576,
    "max_response_frame": 65536,
}

def fail(message): raise ValueError("helper protocol fixture invalid: " + message)
def payload(obj): return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
def frame(obj):
    data = payload(obj)
    return struct.pack(">I", len(data)) + data

def integer(value):
    return type(value) is int

def utf8_size(value, ceiling):
    if not isinstance(value, str): return ceiling + 1
    try: return min(len(value.encode("utf-8")), ceiling + 1)
    except UnicodeEncodeError: return ceiling + 1

def valid_input_id(value):
    return isinstance(value, str) and len(value) == 32 and all(c in "0123456789abcdef" for c in value)

def materialize(v):
    if v["kind"] not in {"recipe", "recipe-error"}: return v["object"]
    obj = copy.deepcopy(v["template"]); key = "result" if obj["kind"] == "response" else "params"
    empty = copy.deepcopy(obj); empty[key][v["field"]] = ""
    obj[key][v["field"]] = "a" * (v["target_frame_length"] - 4 - len(payload(empty)))
    return obj

def check_object(v, obj):
    if not isinstance(obj, dict) or not integer(obj.get("v")) or obj.get("v") != 1: fail(v["name"] + ": invalid version/object")
    kind = obj.get("kind")
    if kind == "request":
        if not isinstance(obj.get("id"), str) or not isinstance(obj.get("op"), str) or not isinstance(obj.get("params"), dict): fail(v["name"] + ": invalid request fields")
        if obj["op"] not in OPS: fail(v["name"] + ": unsupported operation")
        p = obj["params"]
        if obj["op"] in NO_PARAMS and p: fail(v["name"] + ": no-param operation has parameters")
        if obj["op"] == "hello" and (not isinstance(p.get("versions"), list) or not all(integer(x) for x in p["versions"])): fail(v["name"] + ": hello versions must be integer list")
        if obj["op"] == "grant_event_credit" and (not integer(p.get("bytes")) or p["bytes"] < 0): fail(v["name"] + ": invalid credit bytes")
        if obj["op"] == "execute" and not isinstance(p.get("code"), str): fail(v["name"] + ": execute code must be string")
        if obj["op"] in {"complete", "inspect"} and (not isinstance(p.get("code"), str) or not integer(p.get("cursor_pos"))): fail(v["name"] + ": invalid code/cursor")
        if obj["op"] == "inspect" and not integer(p.get("detail_level")): fail(v["name"] + ": invalid detail level")
        if obj["op"] == "variables":
            names, limit = p.get("names"), p.get("limit")
            if (set(p) != {"names", "limit"} or not integer(limit) or not 1 <= limit <= 200
                or (names is not None and (not isinstance(names, list) or not 1 <= len(names) <= 200
                    or any(not isinstance(n, str) or not n.isidentifier() or len(n.encode('utf-8')) > 128 for n in names)
                    or len(set(names)) != len(names)))):
                fail(v["name"] + ": invalid variables selection")
        if obj["op"] == "is_complete" and not isinstance(p.get("code"), str): fail(v["name"] + ": is_complete code must be string")
        if obj["op"] == "input_reply" and (set(p) != {"request_id", "input_id", "value"} or not isinstance(p.get("request_id"), str) or not isinstance(p.get("value"), str) or not valid_input_id(p.get("input_id")) or utf8_size(p["value"], 65536) > 65536): fail(v["name"] + ": invalid input reply")
        if obj["op"] == "connect" and (not isinstance(p.get("connection_file"), str) or not isinstance(p.get("artifact_dir"), str) or not os.path.isabs(p["connection_file"]) or not os.path.isabs(p["artifact_dir"])): fail(v["name"] + ": invalid connect paths")
    elif kind == "response":
        if not isinstance(obj.get("id"), str) or not isinstance(obj.get("ok"), bool): fail(v["name"] + ": invalid response fields")
        if obj["ok"] and ("error" in obj or not isinstance(obj.get("result"), dict)): fail(v["name"] + ": invalid success branch")
        if not obj["ok"] and ("result" in obj or not isinstance(obj.get("error"), dict) or set(obj["error"]) != {"code", "message", "admitted"} or obj["error"].get("code") not in ERRORS or not isinstance(obj["error"].get("message"), str) or type(obj["error"].get("admitted")) is not bool): fail(v["name"] + ": invalid error branch")
    elif kind == "event":
        if not integer(obj.get("seq")) or not isinstance(obj.get("event"), str) or not isinstance(obj.get("data"), dict): fail(v["name"] + ": invalid event fields")
        if obj["event"] not in EVENTS: fail(v["name"] + ": unsupported event")
        if obj["event"] not in {"transport_error"} and not isinstance(obj.get("request_id"), str): fail(v["name"] + ": execution event needs request_id")
        if obj["event"] == "input_request":
            data = obj["data"]
            if set(data) != {"input_id", "prompt", "password"} or not valid_input_id(data.get("input_id")) or not isinstance(data.get("prompt"), str) or utf8_size(data["prompt"], 4096) > 4096 or type(data.get("password")) is not bool: fail(v["name"] + ": invalid input request")
    else: fail(v["name"] + ": unknown envelope kind")

def validate(data):
    if not integer(data.get("version")) or data.get("version") != 1 or not isinstance(data.get("vectors"), list): fail("missing version or vectors")
    if data.get("encoding") != ENCODING: fail("golden encoding metadata changed")
    if data.get("limits") != LIMITS: fail("protocol frame limits changed")
    vectors = data["vectors"]; names = [v.get("name") for v in vectors]
    if any(not isinstance(n, str) or not n for n in names) or len(names) != len(set(names)): fail("vector names must be unique")
    seen_ops, seen_events, seen_errors = set(), set(), set()
    request_ids, response_ids = set(), set()
    last_seq = None
    for v in vectors:
        kind = v.get("kind")
        if kind == "raw-error":
            raw = bytes.fromhex(v["raw_hex"])
            if len(raw) < 4:
                if v.get("outcome") != "partial-frame-timeout": fail(v["name"] + ": incomplete prefix needs partial-frame-timeout")
            elif len(raw) - 4 != int.from_bytes(raw[:4], "big") and v.get("outcome") != "partial-frame-timeout": fail(v["name"] + ": raw prefix/payload mismatch")
            if v.get("error", {}).get("code") not in ERRORS: fail(v["name"] + ": unknown structured error")
            continue
        if kind in {"frame", "recipe", "recipe-error"}:
            obj = materialize(v); check_object(v, obj); wire = frame(obj)
            if kind in {"recipe", "recipe-error"} and (len(wire) - 4 != v["expected_payload_length"] or wire[:4].hex() != v["expected_prefix_hex"]): fail(v["name"] + ": recipe length/prefix mismatch")
            if kind == "recipe-error":
                ceiling = data["limits"]["max_response_frame"] if v["direction"] == "response" else (data["limits"]["max_to_emacs_frame"] if v["direction"] == "to-emacs" else data["limits"]["max_to_helper_frame"])
                if len(wire) != ceiling + 1 or v["error"]["code"] != "frame-too-large": fail(v["name"] + ": not one-byte frame oversize")
            elif len(wire) > (data["limits"]["max_response_frame"] if v.get("direction") == "response" else (data["limits"]["max_to_emacs_frame"] if v.get("direction", "to-emacs") == "to-emacs" else data["limits"]["max_to_helper_frame"])): fail(v["name"] + ": frame exceeds limit")
            if "declared_payload_length" in v and v["declared_payload_length"] != len(wire) - 4: fail(v["name"] + ": declared length mismatch")
            if "prefix_hex" in v and v["prefix_hex"] != wire[:4].hex(): fail(v["name"] + ": prefix mismatch")
            if obj["kind"] == "request": seen_ops.add(obj["op"])
            if obj["kind"] == "request":
                if not obj["id"]: fail(v["name"] + ": empty request id")
                if obj["id"] in request_ids: fail(v["name"] + ": duplicate request id")
                request_ids.add(obj["id"])
            if obj["kind"] == "response":
                if not obj["id"]: fail(v["name"] + ": empty response id")
                if obj["id"] in response_ids: fail(v["name"] + ": duplicate response id")
                response_ids.add(obj["id"])
            if obj["kind"] == "event": seen_events.add(obj["event"])
            if obj["kind"] == "event":
                if last_seq is not None and obj["seq"] <= last_seq: fail(v["name"] + ": event seq is not strictly increasing")
                last_seq = obj["seq"]
                expected_priority = obj["event"] in PRIORITY
                if v.get("priority") != expected_priority or v.get("credit_charge") != (0 if expected_priority else len(wire)): fail(v["name"] + ": invalid event credit accounting")
            if obj["kind"] == "response" and not obj["ok"]: seen_errors.add(obj["error"]["code"])
        elif kind != "coverage": fail(v["name"] + ": unknown vector kind")
    if seen_ops != OPS: fail("concrete operation coverage incomplete")
    if seen_events != EVENTS: fail("concrete event coverage incomplete")
    if seen_errors != ERRORS: fail("concrete error coverage incomplete")

def load(): return json.loads(FIXTURE.read_text(encoding="utf-8"))
def self_test():
    base = load(); by_name = lambda d, n: next(v for v in d["vectors"] if v.get("name") == n)
    cases = [("duplicate name", lambda d: d["vectors"].__setitem__(1, copy.deepcopy(d["vectors"][0]))), ("empty id", lambda d: by_name(d, "op-close")["object"].__setitem__("id", "")), ("duplicate same-kind id", lambda d: by_name(d, "op-close")["object"].__setitem__("id", "op-ping")), ("missing op coverage", lambda d: d["vectors"].remove(by_name(d, "op-close"))), ("missing event coverage", lambda d: d["vectors"].remove(by_name(d, "event-status"))), ("missing error coverage", lambda d: d["vectors"].remove(by_name(d, "error-busy"))), ("prefix mutation", lambda d: d["vectors"][0].__setitem__("prefix_hex", "ffffffff")), ("declared length mutation", lambda d: d["vectors"][0].__setitem__("declared_payload_length", 1)), ("raw mutation", lambda d: d["vectors"][-1].__setitem__("raw_hex", "00")), ("ordinary credit mutation", lambda d: by_name(d, "event-stream").__setitem__("credit_charge", 0)), ("priority credit mutation", lambda d: by_name(d, "event-status").__setitem__("priority", False)), ("schema mutation", lambda d: by_name(d, "op-execute")["object"]["params"].__setitem__("code", 4)), ("boolean integer mutation", lambda d: by_name(d, "event-status")["object"].__setitem__("seq", True)), ("relative connect path mutation", lambda d: by_name(d, "op-connect")["object"]["params"].__setitem__("connection_file", "relative.json")), ("non-monotonic seq", lambda d: by_name(d, "event-status")["object"].__setitem__("seq", 42))]
    cases.extend([
        ("encoding metadata mutation",
         lambda d: d["encoding"].__setitem__("sort_keys", False)),
        ("frame limit mutation",
         lambda d: d["limits"].__setitem__("max_response_frame", 65535)),
    ])
    for name, mutate in cases:
        test = copy.deepcopy(base); mutate(test)
        try: validate(test)
        except (ValueError, KeyError, TypeError): continue
        raise SystemExit("self-test failed to reject " + name)
    print("helper protocol v1 validator self-test: valid (%d rejection cases)" % len(cases))

def main():
    try: validate(load())
    except (ValueError, json.JSONDecodeError, KeyError, TypeError) as exc: raise SystemExit(str(exc))
    if "--self-test" in sys.argv: self_test()
    else: print("helper protocol v1 fixture: valid (%d vectors)" % len(load()["vectors"]))

if __name__ == "__main__": main()
