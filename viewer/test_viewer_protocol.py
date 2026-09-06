"""Pure EI4V confinement and loader checks; no GUI backend is imported."""

import contextlib
import hashlib
import importlib.util
import json
import os
import pickle
import socket
import stat
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

# Explicitly test the legacy script until V10 removes it; the replacement
# package intentionally has the same public application name.
_spec = importlib.util.spec_from_file_location(
    "legacy_viewer", os.path.join(os.path.dirname(__file__), "ejn_viewer.py"))
ejn_viewer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ejn_viewer)


class ConfinedPickleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        os.chmod(self.root, 0o700)
        self.path = os.path.join(
            self.root, "ejn-artifact-0123456789abcdef0123456789abcdef"
        )
        self.payload = pickle.dumps({"figure": "test"})
        with open(self.path, "wb") as handle:
            handle.write(self.payload)
        os.chmod(self.path, 0o600)

    def tearDown(self):
        self.tmp.cleanup()

    def request(self):
        root = os.stat(self.root)
        file = os.stat(self.path)
        return (self.root, self.path, [root.st_dev, root.st_ino],
                [file.st_dev, file.st_ino], len(self.payload),
                hashlib.sha256(self.payload).hexdigest())

    def request_dict(self, request_id="req", **overrides):
        root, path, root_identity, file_identity, size, sha256 = self.request()
        request = {
            "id": request_id,
            "root": root,
            "path": path,
            "root_identity": root_identity,
            "file_identity": file_identity,
            "size": size,
            "sha256": sha256,
        }
        request.update(overrides)
        return request

    def connect_client(self, socket_path):
        client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        client.settimeout(1.0)
        client.connect(socket_path)
        return client

    def recv_ack(self, client):
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(4096)
            self.assertTrue(chunk, data)
            data += chunk
        return json.loads(data.decode("ascii"))

    def pump_until(self, pump, predicate, timeout=1.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            pump()
            if predicate():
                return
            time.sleep(0.01)
        self.fail("viewer protocol pump did not reach expected state")

    def run_headless_socket_host(self, action, *, load=None, display=None):
        socket_path = os.path.join(self.root, "viewer.sock")

        def host(pump, server, bound_socket_path):
            try:
                action(pump, bound_socket_path)
            finally:
                ejn_viewer._shutdown(server, bound_socket_path)
            return 0

        with contextlib.ExitStack() as stack:
            stack.enter_context(
                mock.patch.object(ejn_viewer, "_select_backend",
                                  return_value="Agg")
            )
            stack.enter_context(
                mock.patch.object(ejn_viewer, "_run_mpl_host",
                                  side_effect=host)
            )
            if load is not None:
                stack.enter_context(
                    mock.patch.object(ejn_viewer, "load_confined_pickle",
                                      side_effect=load)
                )
            if display is not None:
                stack.enter_context(
                    mock.patch.object(ejn_viewer, "_display_figure",
                                      side_effect=display)
                )
            self.assertEqual(ejn_viewer.run(socket_path, "Agg", 0), 0)
        self.assertFalse(os.path.exists(socket_path))

    def test_valid_file_hashes_and_loads_same_bytes(self):
        fd = ejn_viewer.open_confined_pickle(*self.request())
        self.assertEqual(ejn_viewer.load_confined_pickle(
            fd, self.request()[-1], len(self.payload)), {"figure": "test"})

    def test_rejects_path_name_mode_and_identity_changes(self):
        args = list(self.request())
        args[1] = os.path.join(self.root, "not-an-artifact")
        with self.assertRaises(ValueError):
            ejn_viewer.open_confined_pickle(*args)

    def test_rejects_relative_paths_and_non_integer_identities(self):
        args = list(self.request())
        args[0] = os.path.relpath(self.root)
        with self.assertRaises(ValueError):
            ejn_viewer.open_confined_pickle(*args)
        args = list(self.request())
        args[2] = [True, 1]
        with self.assertRaises(ValueError):
            ejn_viewer.open_confined_pickle(*args)
        args = list(self.request())
        args[2] = [0, 0]
        with self.assertRaises(ValueError):
            ejn_viewer.open_confined_pickle(*args)
        os.chmod(self.path, 0o644)
        with self.assertRaises(ValueError):
            ejn_viewer.open_confined_pickle(*self.request())
        os.chmod(self.path, 0o600)
        args = list(self.request())
        args[3] = [0, 0]
        with self.assertRaises(ValueError):
            ejn_viewer.open_confined_pickle(*args)
        with mock.patch.object(ejn_viewer.os, "geteuid",
                               return_value=os.geteuid() + 1):
            with self.assertRaises(ValueError):
                ejn_viewer.open_confined_pickle(*self.request())

    def test_rejects_symlink_and_bad_hash_or_size(self):
        os.unlink(self.path)
        os.symlink("/etc/passwd", self.path)
        with self.assertRaises(ValueError):
            ejn_viewer.open_confined_pickle(*self.request())
        os.unlink(self.path)
        with open(self.path, "wb") as handle:
            handle.write(self.payload)
        os.chmod(self.path, 0o600)
        fd = ejn_viewer.open_confined_pickle(*self.request())
        self.assertIsNone(ejn_viewer.load_confined_pickle(fd, "0" * 64,
                                                           len(self.payload)))
        self.assertLessEqual(ejn_viewer.MAX_REQUEST_BYTES, 4096)
        self.assertGreaterEqual(ejn_viewer.MAX_CLIENTS, 1)

    def test_rejects_root_symlink_and_hardlink(self):
        link_root = os.path.join(self.root, "root-link")
        os.symlink(self.root, link_root)
        args = list(self.request())
        args[0] = link_root
        args[1] = os.path.join(link_root, os.path.basename(self.path))
        args[2] = [os.stat(link_root).st_dev, os.stat(link_root).st_ino]
        with self.assertRaises(ValueError):
            ejn_viewer.open_confined_pickle(*args)

        hardlink = os.path.join(
            self.root, "ejn-artifact-fedcba9876543210fedcba9876543210"
        )
        os.link(self.path, hardlink)
        try:
            hardlink_stat = os.stat(hardlink)
            args = list(self.request())
            args[1] = hardlink
            args[3] = [hardlink_stat.st_dev, hardlink_stat.st_ino]
            with self.assertRaises(ValueError):
                ejn_viewer.open_confined_pickle(*args)
        finally:
            os.unlink(hardlink)

    def test_socket_pump_handles_partial_malformed_extra_and_oversize_frames(self):
        def load(fd, _sha256, _size):
            os.close(fd)
            return None

        def action(pump, socket_path):
            socket_stat = os.stat(socket_path)
            self.assertTrue(stat.S_ISSOCK(socket_stat.st_mode))
            self.assertEqual(stat.S_IMODE(socket_stat.st_mode), 0o600)
            self.assertEqual(socket_stat.st_uid, os.geteuid())
            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(b"{not-json\n")
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "", "accepted": False})

            for non_object in (b"[]\n", b"null\n", b'"x"\n'):
                with self.connect_client(socket_path) as client:
                    pump()
                    client.sendall(non_object)
                    pump()
                    self.assertEqual(self.recv_ack(client),
                                     {"id": "", "accepted": False})

            wrong_size = self.request_dict("bad-size",
                                           size=len(self.payload) + 1)
            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(json.dumps(wrong_size).encode("utf-8") + b"\n")
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "bad-size", "accepted": False})

            bad_schema = self.request_dict("extra")
            bad_schema["unexpected"] = True
            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(json.dumps(bad_schema).encode("utf-8") + b"\n")
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "extra", "accepted": False})

            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(b"x" * (ejn_viewer.MAX_REQUEST_BYTES + 1))
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "", "accepted": False})

            request = json.dumps(self.request_dict("partial")).encode("utf-8")
            split = len(request) // 2
            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(request[:split])
                pump()
                client.settimeout(0.05)
                with self.assertRaises(socket.timeout):
                    client.recv(1)
                client.settimeout(1.0)
                client.sendall(request[split:] + b"\n")
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "partial", "accepted": True})

        self.run_headless_socket_host(action, load=load)

    def test_socket_ack_means_worker_has_open_fd_not_path_lease(self):
        gate = threading.Event()
        started = threading.Event()
        displayed = []
        original_load = ejn_viewer.load_confined_pickle

        def load(fd, sha256, size):
            started.set()
            self.assertTrue(gate.wait(1.0))
            return original_load(fd, sha256, size)

        def display(figure):
            displayed.append(figure)

        def action(pump, socket_path):
            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(json.dumps(self.request_dict("pinned")).encode("utf-8") + b"\n")
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "pinned", "accepted": True})
                self.assertTrue(started.wait(1.0))
                os.unlink(self.path)
                gate.set()
            self.pump_until(pump, lambda: displayed)
            self.assertEqual(displayed, [{"figure": "test"}])

        self.run_headless_socket_host(action, load=load, display=display)

    def test_socket_pump_rejects_busy_then_accepts_after_ready_is_consumed(self):
        gate = threading.Event()
        started = threading.Event()
        displayed = []

        def load(fd, _sha256, _size):
            os.close(fd)
            started.set()
            self.assertTrue(gate.wait(1.0))
            return {"figure": "loaded"}

        def display(figure):
            displayed.append(figure)

        def action(pump, socket_path):
            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(json.dumps(self.request_dict("first")).encode("utf-8") + b"\n")
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "first", "accepted": True})
                self.assertTrue(started.wait(1.0))

            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(json.dumps(self.request_dict("busy")).encode("utf-8") + b"\n")
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "busy", "accepted": False})

            gate.set()
            self.pump_until(pump, lambda: displayed)
            self.assertEqual(displayed, [{"figure": "loaded"}])

            with self.connect_client(socket_path) as client:
                pump()
                client.sendall(json.dumps(self.request_dict("second")).encode("utf-8") + b"\n")
                pump()
                self.assertEqual(self.recv_ack(client),
                                 {"id": "second", "accepted": True})
            self.pump_until(pump, lambda: len(displayed) == 2)


if __name__ == "__main__":
    unittest.main()
