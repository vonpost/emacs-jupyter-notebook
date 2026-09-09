"""Bounded stdio IPC tests for the local viewer process."""

import hashlib
import io
import json
import os
import selectors
import struct
import subprocess
import sys
import tempfile
import time
import unittest

import numpy as np

from ejn_viewer.ipc import Decoder, MAX_FRAME, encode


def _group(array):
    header = {"v": 1, "key": "k", "sample_id": "sample",
              "publication_id": "0123456789abcdef0123456789abcdef",
              "planes": [{"id": "0", "name": "plane", "shape": list(array.shape),
                          "dtype": array.dtype.str, "offset": 0,
                          "nbytes": array.nbytes}]}
    payload = json.dumps(header, separators=(",", ":")).encode()
    return b"EJNARR01" + struct.pack(">I", len(payload)) + payload + array.tobytes()


def _request(identifier, operation, params=None):
    return {"v": 1, "id": identifier, "op": operation,
            "params": {} if params is None else params}


class DecoderTests(unittest.TestCase):
    def test_fragmented_and_coalesced_frames(self):
        first = encode(_request("a", "ping"))
        second = encode(_request("b", "ping"))
        decoder = Decoder()
        for byte in first:
            decoder.feed(bytes([byte]))
            if byte != first[-1]:
                self.assertIsNone(decoder.pop())
        self.assertEqual(decoder.pop()["id"], "a")
        decoder.feed(first + second)
        self.assertEqual(decoder.pop()["id"], "a")
        self.assertEqual(decoder.pop()["id"], "b")

    def test_oversize_invalid_json_and_nonfinite_are_rejected(self):
        decoder = Decoder()
        decoder.feed(struct.pack(">I", MAX_FRAME - 3))
        with self.assertRaises(ValueError):
            decoder.pop()
        decoder = Decoder()
        payload = b"{bad"
        decoder.feed(struct.pack(">I", len(payload)) + payload)
        with self.assertRaises(ValueError):
            decoder.pop()
        decoder = Decoder()
        payload = b'{"x":NaN}'
        decoder.feed(struct.pack(">I", len(payload)) + payload)
        with self.assertRaises(ValueError):
            decoder.pop()

    def test_input_backlog_bound(self):
        with self.assertRaises(ValueError):
            Decoder().feed(b"x" * (MAX_FRAME * 2 + 1))


class StdioProcessTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        os.chmod(self.root.name, 0o700)
        self.path = os.path.join(self.root.name,
                                 "ejn-artifact-0123456789abcdef0123456789abcdef")
        data = _group(np.array([[1, 2], [300, 400]], dtype="<u2"))
        with open(self.path, "wb") as handle:
            handle.write(data)
        os.chmod(self.path, 0o600)
        root = os.stat(self.root.name)
        artifact = os.stat(self.path)
        with open(self.path, "rb") as handle:
            digest = hashlib.sha256(handle.read()).hexdigest()
        self.params = {"workspace": "ipc-test", "generation": 1,
                       "execution": "exec-1", "kind": "array-group", "focus": False,
                       "artifact": {"root": self.root.name, "path": self.path,
                                     "root_device": root.st_dev, "root_inode": root.st_ino,
                                     "device": artifact.st_dev, "inode": artifact.st_ino,
                                     "size": artifact.st_size, "sha256": digest}}

    def tearDown(self):
        self.root.cleanup()

    def process(self):
        # In a Nix install-check the package and ejn-array-protocol are already
        # in the interpreter environment.  Do not replace Nix's import path
        # with relative source paths (the check cwd is the unpacked package).
        env = dict(os.environ, QT_QPA_PLATFORM="offscreen")
        return subprocess.Popen(
            [sys.executable, "-c", "from ejn_viewer.ipc import run; raise SystemExit(run())"],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=env)

    def send(self, process, value):
        process.stdin.write(encode(value))
        process.stdin.flush()

    def receive(self, process, timeout=5):
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        data = bytearray()
        deadline = time.monotonic() + timeout
        while len(data) < 4:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, "timed out waiting for IPC frame")
            self.assertTrue(selector.select(remaining))
            data.extend(os.read(process.stdout.fileno(), 4 - len(data)))
        length = struct.unpack(">I", data)[0]
        self.assertLessEqual(length, MAX_FRAME - 4)
        while len(data) < 4 + length:
            remaining = deadline - time.monotonic()
            self.assertGreater(remaining, 0, "timed out waiting for IPC payload")
            self.assertTrue(selector.select(remaining))
            data.extend(os.read(process.stdout.fileno(), 4 + length - len(data)))
        return json.loads(bytes(data[4:]))

    def test_handshake_open_ping_source_delete_and_close(self):
        process = self.process()
        try:
            self.send(process, {"v": 1, "id": "hello", "op": "hello", "params": {}})
            hello = self.receive(process)
            self.assertTrue(hello["ok"])
            self.assertIn("array-group-v1", hello["result"]["capabilities"])
            self.send(process, _request("open-1", "open", self.params))
            opened = self.receive(process, timeout=10)
            self.assertEqual(opened["result"]["state"], "visible")
            os.unlink(self.path)
            self.send(process, _request("ping-1", "ping"))
            self.assertEqual(self.receive(process)["result"], {"alive": True})
            self.send(process, _request("close-1", "close"))
            process.stdin.close()
            self.assertEqual(process.wait(timeout=5), 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            process.stderr.close()

    def test_denied_open_returns_error_and_process_survives(self):
        process = self.process()
        try:
            self.send(process, {"v": 1, "id": "hello", "op": "hello", "params": {}})
            self.receive(process)
            denied = dict(self.params)
            denied["artifact"] = dict(self.params["artifact"], sha256="0" * 64)
            self.send(process, _request("bad-open", "open", denied))
            response = self.receive(process, timeout=10)
            self.assertFalse(response["ok"])
            self.send(process, _request("ping-2", "ping"))
            self.assertEqual(self.receive(process)["result"], {"alive": True})
        finally:
            if not process.stdin.closed:
                process.stdin.close()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()

    def test_closed_workspace_ignores_automatic_follow_until_explicit_inspect(self):
        process = self.process()
        try:
            self.send(process, _request("hello", "hello"))
            self.receive(process)
            self.send(process, _request("first", "open", self.params))
            self.assertTrue(self.receive(process, timeout=10)["ok"])
            self.send(process, _request("close-workspace", "close_workspace", {"workspace": "ipc-test"}))
            self.assertTrue(self.receive(process)["result"]["found"])
            self.send(process, _request("follow", "open", self.params))
            self.assertEqual(self.receive(process)["result"], {"state": "visible", "closed": True})
            self.send(process, _request("focus-closed", "focus", {"workspace": "ipc-test"}))
            self.assertFalse(self.receive(process)["result"]["found"])
            self.send(process, _request("inspect", "open", dict(self.params, focus=True)))
            self.assertEqual(self.receive(process, timeout=10)["result"], {"state": "visible"})
        finally:
            process.stdin.close()
            process.wait(timeout=5)
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
