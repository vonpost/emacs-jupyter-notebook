"""W21 numerical artifact publication and bounded output ownership guards."""

import asyncio
import base64
import hashlib
import json
from pathlib import Path
import struct
import tempfile
import threading
from types import SimpleNamespace
import unittest
from unittest import mock

from ejn_array import MIME
from ejn_helper.artifacts import ArtifactDataError, ArtifactStore
from ejn_helper.dispatcher import Dispatcher
from ejn_helper.flow import EventQueue
from ejn_helper.outputs import OutputNormalizer


FIXTURES = Path(__file__).resolve().parents[2] / "tests/fixtures/viewer-contract-v1.json"


def vectors():
    return json.loads(FIXTURES.read_text(encoding="utf-8"))


def group(vector):
    header = vector["header_json"].encode("utf-8")
    return b"EJNARR01" + struct.pack(">I", len(header)) + header + bytes.fromhex(vector["raw_hex"])


def encoded(raw):
    return base64.b64encode(raw).decode("ascii")


def rich(payload, **extra):
    return {"msg_type": "display_data", "content": {
        "data": {MIME: payload, **extra}, "metadata": {}}}


class BlockingArrayStore(ArtifactStore):
    """Pause only numerical publication; all leases and I/O remain real."""

    def __init__(self, directory):
        super().__init__(directory)
        self.entered = threading.Event()
        self.release = threading.Event()
        self.calls = 0
        self.closed = False

    def make_array(self, payload):
        self.calls += 1
        self.entered.set()
        if not self.release.wait(5):
            raise RuntimeError("test did not release numerical worker")
        return super().make_array(payload)

    def close(self):
        self.closed = True
        super().close()


class ArrayArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name)
        self.store = ArtifactStore(self.directory)

    def tearDown(self):
        self.store.close()
        self.temporary.cleanup()

    def test_shared_golden_groups_preserve_bytes_manifest_and_hash(self):
        for vector in vectors()["valid"]:
            with self.subTest(vector=vector["name"]):
                raw = group(vector)
                result = self.store.make_array(encoded(raw))
                self.assertEqual(result.manifest, json.loads(vector["header_json"]))
                self.assertEqual(result.original.path.read_bytes(), raw)
                self.assertEqual(result.original.byte_count, len(raw))
                self.assertEqual(result.original.sha256, hashlib.sha256(raw).hexdigest())
                self.assertTrue(self.store.discard(result.original))
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_every_invalid_shared_vector_discards_spooled_file(self):
        for vector in vectors()["rejections"]:
            with self.subTest(vector=vector["name"]):
                with self.assertRaises(ArtifactDataError):
                    self.store.make_array(encoded(group(vector)))
                self.assertEqual(list(self.directory.iterdir()), [])

    def test_bad_base64_truncated_group_and_oversized_header_leave_no_files(self):
        raw = group(vectors()["valid"][0])
        for payload in ("%%%?", encoded(raw[:-1]),
                        encoded(b"EJNARR01" + struct.pack(">I", 16385) + b"x")):
            with self.subTest(payload=payload[:20]):
                with self.assertRaises(ArtifactDataError):
                    self.store.make_array(payload)
                self.assertEqual(list(self.directory.iterdir()), [])

    def test_unexpected_validator_failure_also_discards_publication(self):
        with mock.patch("ejn_helper.artifacts.read_manifest",
                        side_effect=RuntimeError("test validator failure")):
            with self.assertRaisesRegex(RuntimeError, "test validator failure"):
                self.store.make_array(encoded(group(vectors()["valid"][0])))
        self.assertEqual(list(self.directory.iterdir()), [])


class ArrayOutputTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.directory = self.root / "artifacts"
        self.directory.mkdir(mode=0o700)
        self.normalizer = OutputNormalizer(str(self.directory))
        self.events = []
        self.raw = group(vectors()["valid"][0])
        self.payload = encoded(self.raw)
        self.extra_normalizers = []
        self.blocked_stores = []

    async def asyncTearDown(self):
        for store in self.blocked_stores:
            store.release.set()
        for normalizer in [self.normalizer, *self.extra_normalizers]:
            normalizer.close()
            await asyncio.wait_for(normalizer.wait_closed(), 3)
        self.temporary.cleanup()

    async def submit(self, request, message, deliver=None):
        self.normalizer.submit(request, message,
                               self.events.append if deliver is None else deliver)
        await asyncio.wait_for(self.normalizer.finish(request), 3)

    async def blocked(self, suffix):
        directory = self.root / suffix
        directory.mkdir(mode=0o700)
        store = BlockingArrayStore(directory)
        normalizer = OutputNormalizer()
        attachment = normalizer.attach(artifact_store=store)
        self.blocked_stores.append(store)
        self.extra_normalizers.append(normalizer)
        normalizer.submit(attachment, "active", rich(self.payload), self.events.append)
        async def entered():
            while not store.entered.is_set():
                await asyncio.sleep(0.005)
        await asyncio.wait_for(entered(), 2)
        return normalizer, attachment, store, directory

    async def test_array_is_exclusive_even_with_unusable_companion_payloads(self):
        with mock.patch.object(ArtifactStore, "make_image",
                               side_effect=AssertionError("raster decoding attempted")):
            await self.submit("exclusive", rich(self.payload, **{
                "image/png": object(), "application/x-ejn-mpl-pickle": object(),
                "text/plain": "unwanted fallback"}))
        self.assertEqual(len(self.events), 1)
        self.assertEqual(set(self.events[0].data["data"]), {MIME})
        descriptor = self.events[0].data["data"][MIME]
        self.assertEqual(set(descriptor), {"path", "bytes", "sha256", "manifest"})
        self.assertEqual(descriptor["manifest"], json.loads(vectors()["valid"][0]["header_json"]))
        self.assertEqual(Path(descriptor["path"]).read_bytes(), self.raw)
        serialized = json.dumps(self.events[0].data).encode()
        self.assertLess(len(serialized), 32768)
        self.assertNotIn(self.payload.encode(), serialized)
        self.assertNotIn(self.raw, serialized)
        self.assertEqual(len(list(self.directory.iterdir())), 1)

    async def test_present_malformed_array_never_falls_back_to_image_pickle_or_text(self):
        for index, payload in enumerate((None, "", {}, "é", "%%%?", encoded(b"invalid"))):
            self.events.clear()
            with self.subTest(payload=payload), mock.patch.object(
                    ArtifactStore, "make_image", side_effect=AssertionError("raster fallback")):
                await self.submit(str(index), rich(payload, **{
                    "image/png": encoded(b"png"),
                    "application/x-ejn-mpl-pickle": encoded(b"pickle"),
                    "text/plain": "unwanted fallback"}))
                self.assertEqual(len(self.events), 1)
                self.assertEqual(self.events[0].name, "stream")
                self.assertIn("omitted", self.events[0].data["text"])
                self.assertNotIn("unwanted fallback", self.events[0].data["text"])
                self.assertEqual(list(self.directory.iterdir()), [])

    async def test_delivery_rejection_and_exception_discard_exact_publication(self):
        def failed(_event):
            raise RuntimeError("test sink failed")
        for index, deliver in enumerate((lambda _event: False, failed)):
            with self.subTest(index=index):
                await self.submit(str(index), rich(self.payload), deliver)
                self.assertEqual(list(self.directory.iterdir()), [])
                self.assertEqual(self.normalizer._pending_artifacts, 0)
                self.assertEqual(self.normalizer._retained_bytes, 0)

    async def test_cancel_during_publication_discards_late_result(self):
        normalizer, attachment, store, directory = await self.blocked("cancel")
        normalizer.cancel(attachment, "active")
        store.release.set()
        await asyncio.wait_for(normalizer.finish(attachment, "active"), 3)
        self.assertEqual(self.events, [])
        self.assertEqual(list(directory.iterdir()), [])
        self.assertEqual(normalizer._pending_artifacts, 0)

    async def test_retirement_keeps_store_until_late_publication_is_discarded(self):
        normalizer, attachment, store, directory = await self.blocked("retire")
        normalizer.retire(attachment)
        self.assertFalse(store.closed)
        store.release.set()
        await asyncio.wait_for(normalizer.finish(attachment, "active"), 3)
        self.assertTrue(store.closed)
        self.assertEqual(self.events, [])
        self.assertEqual(list(directory.iterdir()), [])

    async def test_blocked_array_keeps_ping_live_and_global_quota_across_reattach(self):
        normalizer, attachment, store, directory = await self.blocked("pressure")
        responses = []
        dispatcher = Dispatcher(object(), responses.append)
        dispatcher.dispatch({"v": 1, "kind": "request", "id": "hello",
                             "op": "hello", "params": {"versions": [1]}})
        started = asyncio.get_running_loop().time()
        dispatcher.dispatch({"v": 1, "kind": "request", "id": "ping",
                             "op": "ping", "params": {}})
        self.assertLess(asyncio.get_running_loop().time() - started, 0.05)
        self.assertEqual(responses[-1]["id"], "ping")
        self.assertTrue(responses[-1]["ok"])
        normalizer.retire(attachment)
        worker = normalizer._worker_task
        replacement_dir = self.root / "replacement"
        replacement_dir.mkdir(mode=0o700)
        replacement = normalizer.attach(str(replacement_dir))
        for index in range(3):
            normalizer.submit(replacement, str(index), rich(self.payload), self.events.append)
        self.assertEqual(normalizer._pending_artifacts, 1)
        self.assertEqual(normalizer._pending_artifact_bytes, len(self.payload))
        self.assertIs(normalizer._worker_task, worker)
        self.assertEqual(store.calls, 1)
        store.release.set()
        await asyncio.wait_for(normalizer.finish(attachment, "active"), 3)
        for index in range(3):
            await asyncio.wait_for(normalizer.finish(replacement, str(index)), 3)
        self.assertEqual(list(directory.iterdir()), [])
        self.assertEqual(list(replacement_dir.iterdir()), [])
        self.assertEqual(len(self.events), 3)
        self.assertTrue(all(event.name == "stream" for event in self.events))
        self.assertEqual(normalizer._pending_artifact_bytes, 0)
        self.assertEqual(normalizer._retained_bytes, 0)

    async def test_dispatcher_credit_rejection_discards_array_and_emits_truncation(self):
        queue = EventQueue(ordinary_limit=1)
        dispatcher = Dispatcher(object(), lambda _response: None, event_queue=queue)
        dispatcher.negotiated = dispatcher.connected = True
        record = SimpleNamespace(terminal=False, request_id="drop", operation="execute",
                                 timer=asyncio.get_running_loop().call_later(60, lambda: None),
                                 cancellation=None, cancel_requested=False)
        dispatcher._inflight["drop"] = record
        try:
            await self.submit("drop", rich(self.payload),
                              lambda event: dispatcher._backend_event("drop", record, event))
        finally:
            record.timer.cancel()
        self.assertEqual(list(self.directory.iterdir()), [])
        frames = [json.loads(item.frame[4:]) for item in queue.drain()]
        self.assertEqual([frame["event"] for frame in frames], ["output_truncated"])
        self.assertNotIn(self.payload, json.dumps(frames))

    async def test_admitted_dispatcher_frame_has_manifest_but_no_numerical_payload(self):
        queue = EventQueue()
        queue.grant_credit(262144)
        dispatcher = Dispatcher(object(), lambda _response: None, event_queue=queue)
        dispatcher.negotiated = dispatcher.connected = True
        record = SimpleNamespace(terminal=False, request_id="admit", operation="execute",
                                 timer=asyncio.get_running_loop().call_later(60, lambda: None),
                                 cancellation=None, cancel_requested=False)
        dispatcher._inflight["admit"] = record
        try:
            await self.submit("admit", rich(self.payload),
                              lambda event: dispatcher._backend_event("admit", record, event))
        finally:
            record.timer.cancel()
        frames = [item.frame for item in queue.drain()]
        self.assertEqual(len(frames), 1)
        self.assertNotIn(self.payload.encode(), frames[0])
        self.assertNotIn(self.raw, frames[0])
        descriptor = json.loads(frames[0][4:])["data"]["data"][MIME]
        self.assertEqual(descriptor["manifest"]["planes"][0]["dtype"], "<u2")
        self.assertEqual(Path(descriptor["path"]).read_bytes(), self.raw)


if __name__ == "__main__":
    unittest.main()
