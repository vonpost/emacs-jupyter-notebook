"""HT9 bounded output, protocol shape, and artifact-handoff tests."""

import asyncio
import base64
import json
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest import mock

import ejn_helper.outputs as outputs_module
from ejn_helper.artifacts import ArtifactStore
from ejn_helper.backend import BackendError, BackendEvent
from ejn_helper.dispatcher import Dispatcher
from ejn_helper.flow import EventQueue
from ejn_helper.jupyter_backend import JupyterBackend, _Pending
from ejn_helper.outputs import (
    EJN_MAX_ARTIFACT_ENCODED_BYTES,
    EJN_MAX_PENDING_OUTPUTS,
    EJN_MAX_RETAINED_OUTPUT_BYTES,
    _MARKER_BYTES,
    OutputNormalizer,
    _safe_metadata,
)
from ejn_helper.requests import ExecutionState


def message(message_type, content):
    return {"msg_type": message_type, "content": content}


def contains(value, needle):
    if isinstance(value, str):
        return needle in value
    if isinstance(value, dict):
        return any(contains(item, needle) for item in value.values())
    if isinstance(value, (list, tuple)):
        return any(contains(item, needle) for item in value)
    return False


class _BlockingStore:
    def __init__(self, directory):
        self.store = ArtifactStore(directory)
        self.entered = threading.Event()
        self.release = threading.Event()
        self.discard_entered = threading.Event()
        self.discard_release = threading.Event()
        self.block_discard = False
        self.closed = False

    def store_base64(self, payload):
        self.entered.set()
        self.release.wait(2)
        return self.store.store_base64(payload)

    def discard(self, published):
        if self.block_discard:
            self.discard_entered.set()
            self.discard_release.wait(2)
        return self.store.discard(published)

    def close(self):
        self.closed = True
        self.store.close()


class OutputNormalizerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name) / "artifacts"
        self.directory.mkdir(mode=0o700)
        self.normalizer = OutputNormalizer(str(self.directory))
        self.events = []

    async def asyncTearDown(self):
        self.normalizer.close()
        await self.normalizer.wait_closed()
        self.temporary.cleanup()

    async def submit(self, request_id, item, deliver=None):
        self.normalizer.submit(request_id, item, self.events.append if deliver is None else deliver)
        await asyncio.wait_for(self.normalizer.finish(request_id), 2)

    async def test_protocol_v1_mime_shape_preserves_metadata_and_execution_count(self):
        await self.submit(
            "result",
            message(
                "execute_result",
                {
                    "data": {"text/plain": "2"},
                    "metadata": {"text/plain": {"isolated": True}},
                    "execution_count": 7,
                },
            ),
        )
        self.assertEqual(self.events[0].name, "execute_result")
        self.assertEqual(
            self.events[0].data,
            {
                "data": {"text/plain": "2"},
                "metadata": {"text/plain": {"isolated": True}},
                "execution_count": 7,
            },
        )

    async def test_metadata_keeps_finite_floats_and_bounds_examined_keys(self):
        metadata, _size, truncated = _safe_metadata(
            {"scale": 1.5, "invalid": float("nan")}
        )
        self.assertTrue(truncated)
        self.assertEqual(
            metadata, {"scale": 1.5, "_ejn_metadata_truncated": True}
        )
        json.dumps(metadata, allow_nan=False)

        class CountingMapping(dict):
            examined = 0

            def items(self):
                for index in range(100_000):
                    self.examined += 1
                    yield (f"{'k' * 1024}{index}", "v" * 1024)

        hostile = CountingMapping()
        bounded, _size, truncated = _safe_metadata(hostile)
        self.assertTrue(truncated)
        self.assertLessEqual(hostile.examined, outputs_module.EJN_MAX_METADATA_ITEMS + 1)
        self.assertLessEqual(len(json.dumps(bounded)), 10_000)

    async def test_hundred_mib_stream_is_bounded_before_worker_retention(self):
        logical = "x" * (100 * 1024 * 1024)
        self.normalizer.submit(
            "huge-stream",
            message("stream", {"name": "stdout", "text": logical}),
            self.events.append,
        )
        del logical
        self.assertLessEqual(
            self.normalizer._retained_bytes, outputs_module.EJN_MAX_EVENT_TEXT_BYTES
        )
        await asyncio.wait_for(self.normalizer.finish("huge-stream"), 2)
        self.assertEqual([event.name for event in self.events], ["stream", "stream"])
        self.assertEqual(
            len(self.events[0].data["text"].encode("utf-8")),
            outputs_module.EJN_MAX_EVENT_TEXT_BYTES,
        )
        self.assertIn("output limit reached", self.events[1].data["text"])
        self.assertEqual(self.normalizer._retained_bytes, 0)

    async def test_stream_error_and_clear_preserve_text_and_receive_order(self):
        ansi = "\x1b[31mred\x1b[0m\n"
        request_id = "ordered-text"
        for item in (
            message("stream", {"name": "stderr", "text": ansi}),
            message("error", {"ename": "ValueError", "evalue": "bad", "traceback": [ansi]}),
            message("clear_output", {"wait": True}),
        ):
            self.normalizer.submit(request_id, item, self.events.append)
        await asyncio.wait_for(self.normalizer.finish(request_id), 2)
        self.assertEqual(
            [(event.name, event.data.get("wait")) for event in self.events],
            [("stream", None), ("stream", None), ("clear_output", True)],
        )
        self.assertEqual(self.events[0].data, {"name": "stderr", "text": ansi})
        self.assertIn(ansi, self.events[1].data["text"])

    async def test_every_artifact_mime_is_spooled_and_base64_is_absent(self):
        for index, mime in enumerate(
            ("image/png", "image/jpeg", "application/x-ejn-mpl-pickle")
        ):
            payload = base64.b64encode(f"artifact-{index}".encode()).decode("ascii")
            await self.submit(
                f"artifact-{index}",
                message("display_data", {"data": {mime: payload}, "metadata": {}}),
            )
            reference = self.events[-1].data["data"][mime]
            self.assertEqual(set(reference), {"path", "bytes", "sha256"})
            self.assertFalse(contains(self.events[-1].data, payload))

    async def test_figure_pickle_and_thumbnail_transfer_in_one_event(self):
        png = base64.b64encode(b"thumbnail").decode("ascii")
        pickle_payload = base64.b64encode(b"pickle").decode("ascii")
        await self.submit(
            "figure",
            message(
                "display_data",
                {"data": {"image/png": png,
                          "application/x-ejn-mpl-pickle": pickle_payload},
                 "metadata": {}},
            ),
        )
        data = self.events[-1].data["data"]
        self.assertEqual(set(data), {"image/png", "application/x-ejn-mpl-pickle"})
        self.assertTrue(Path(data["image/png"]["path"]).is_file())
        self.assertTrue(Path(data["application/x-ejn-mpl-pickle"]["path"]).is_file())
        self.assertFalse(contains(self.events[-1].data, png))
        self.assertFalse(contains(self.events[-1].data, pickle_payload))

    async def test_dual_artifact_second_publication_failure_rolls_back_both(self):
        """A partial dual publication cannot strand the first artifact."""
        png = base64.b64encode(b"thumbnail").decode("ascii")
        pickle_payload = base64.b64encode(b"pickle").decode("ascii")
        original = ArtifactStore.store_base64
        calls = 0

        def fail_second(store, payload):
            nonlocal calls
            calls += 1
            if calls == 2:
                raise RuntimeError("second publication failed")
            return original(store, payload)

        with mock.patch.object(ArtifactStore, "store_base64", new=fail_second):
            await self.submit(
                "dual-store-failure",
                message(
                    "display_data",
                    {"data": {"image/png": png,
                              "application/x-ejn-mpl-pickle": pickle_payload},
                     "metadata": {}},
                ),
            )
        self.assertEqual([event.name for event in self.events], ["stream"])
        self.assertIn("artifact publication failed", self.events[0].data["text"])
        self.assertEqual(list(self.directory.iterdir()), [])
        self.assertEqual(self.normalizer._retained_bytes, 0)
        self.assertEqual(self.normalizer._pending_artifact_bytes, 0)

    async def test_dual_artifact_downstream_rejection_discards_every_lease(self):
        """A false delivery acknowledgement rejects image and pickle together."""
        png = base64.b64encode(b"thumbnail").decode("ascii")
        pickle_payload = base64.b64encode(b"pickle").decode("ascii")
        await self.submit(
            "dual-delivery-rejected",
            message(
                "display_data",
                {"data": {"image/png": png,
                          "application/x-ejn-mpl-pickle": pickle_payload},
                 "metadata": {}},
            ),
            deliver=lambda _event: False,
        )
        self.assertEqual(self.events, [])
        self.assertEqual(list(self.directory.iterdir()), [])
        self.assertEqual(self.normalizer._retained_bytes, 0)
        self.assertEqual(self.normalizer._pending_artifact_bytes, 0)

    async def test_malformed_and_oversize_base64_become_small_markers(self):
        await self.submit(
            "malformed-artifact",
            message("display_data", {"data": {"image/png": "!!!!"}, "metadata": {}}),
        )
        with mock.patch.object(outputs_module, "EJN_MAX_ARTIFACT_ENCODED_BYTES", 8):
            await self.submit(
                "oversize-artifact",
                message(
                    "display_data",
                    {"data": {"image/png": "A" * 12}, "metadata": {}},
                ),
            )
        self.assertEqual([event.name for event in self.events], ["stream", "stream"])
        self.assertIn("invalid artifact", self.events[0].data["text"])
        self.assertIn("artifact exceeds the byte limit", self.events[1].data["text"])
        self.assertTrue(all(len(event.data["text"]) < 128 for event in self.events))

    async def test_no_more_jobs_are_snapshotted_after_truncation_marker(self):
        request_id = "already-truncated"
        self.normalizer.submit(
            request_id,
            message("stream", {"name": "stdout", "text": "x" * 40_000}),
            self.events.append,
        )
        for _ in range(20):
            if len(self.events) == 2:
                break
            await asyncio.sleep(0)
        self.assertEqual(len(self.events), 2)
        before = list(self.events)
        with mock.patch.object(
            self.normalizer, "_snapshot", side_effect=AssertionError("snapshotted")
        ):
            self.normalizer.submit(
                request_id,
                message("stream", {"name": "stdout", "text": "late"}),
                self.events.append,
            )
        self.assertEqual(self.events, before)
        await asyncio.wait_for(self.normalizer.finish(request_id), 2)

    async def test_artifact_reference_replaces_nested_mime_value_and_never_leaks_base64(self):
        payload = base64.b64encode(b"png-data").decode("ascii")
        await self.submit(
            "png",
            message(
                "display_data",
                {
                    "data": {"text/plain": "fallback", "image/png": payload},
                    "metadata": {"image/png": {"width": 2}},
                },
            ),
        )
        event = self.events[0]
        image = event.data["data"]["image/png"]
        self.assertEqual(event.data["metadata"], {"image/png": {"width": 2}})
        self.assertEqual(set(image), {"path", "bytes", "sha256"})
        self.assertTrue(Path(image["path"]).is_file())
        self.assertFalse(contains(event.data, payload))

    async def test_long_display_ids_are_omitted_not_truncated_into_an_alias(self):
        first = "a" * 256 + "first"
        second = "a" * 256 + "second"
        for request_id, display_id in (("one", first), ("two", second)):
            await self.submit(
                request_id,
                message(
                    "update_display_data",
                    {
                        "data": {"text/plain": request_id},
                        "metadata": {},
                        "transient": {"display_id": display_id},
                    },
                ),
            )
        for event in self.events:
            self.assertTrue(event.data["update"])
            self.assertEqual(event.data["transient"], {"display_id_omitted": True})
            self.assertNotIn("display_id", event.data["transient"])
        self.assertEqual(len(self.events), 2)

    async def test_hostile_decoded_message_is_snapshotted_without_retaining_unselected_payloads(self):
        sentinel = "HOSTILE-INBOUND-PAYLOAD"
        hostile = message(
            "display_data",
            {
                "data": {
                    "text/plain": "safe",
                    "application/x-hostile": sentinel * 100_000,
                },
                "metadata": {
                    "large": sentinel * 100_000,
                    "deep": {"one": {"two": {"three": sentinel}}},
                },
            },
        )
        await self.submit("hostile", hostile)
        self.assertFalse(contains(self.events, sentinel))
        self.assertLessEqual(self.normalizer._retained_bytes, EJN_MAX_RETAINED_OUTPUT_BYTES)
        self.assertLessEqual(len(json.dumps(self.events[0].data)), 10_000)

    async def test_slow_artifact_worker_enters_and_does_not_block_local_ping(self):
        slow_dir = Path(self.temporary.name) / "slow"
        slow_dir.mkdir(mode=0o700)
        store = _BlockingStore(slow_dir)
        normalizer = OutputNormalizer(artifact_store=store)
        payload = base64.b64encode(b"image").decode("ascii")
        normalizer.submit("slow", message("display_data", {"data": {"image/png": payload}, "metadata": {}}), lambda _event: True)
        for _ in range(20):
            if store.entered.is_set():
                break
            await asyncio.sleep(0.01)
        self.assertTrue(store.entered.is_set(), "artifact worker never entered store I/O")
        responses = []
        dispatcher = Dispatcher(object(), responses.append)
        dispatcher.dispatch({"v": 1, "kind": "request", "id": "hello", "op": "hello", "params": {"versions": [1]}})
        started = asyncio.get_running_loop().time()
        dispatcher.dispatch({"v": 1, "kind": "request", "id": "ping", "op": "ping", "params": {}})
        self.assertLess(asyncio.get_running_loop().time() - started, 0.05)
        self.assertTrue(responses[-1]["ok"])
        store.release.set()
        await asyncio.wait_for(normalizer.finish("slow"), 1)
        normalizer.close()
        await asyncio.wait_for(normalizer.wait_closed(), 1)

    async def test_timeout_cancel_and_repeated_reattach_share_one_active_artifact_quota(self):
        old_dir = Path(self.temporary.name) / "old"
        new_dir = Path(self.temporary.name) / "new"
        old_dir.mkdir(mode=0o700)
        new_dir.mkdir(mode=0o700)
        store = _BlockingStore(old_dir)
        backend = JupyterBackend()
        normalizer = backend._outputs
        old = normalizer.attach(artifact_store=store)
        backend._output_attachment = old
        payload = base64.b64encode(b"active artifact").decode("ascii")
        pending = _Pending(
            asyncio.get_running_loop().create_future(),
            ExecutionState("active"),
            lambda _event: True,
            old,
        )
        normalizer.submit(
            old,
            "active",
            message("display_data", {"data": {"image/png": payload}, "metadata": {}}),
            lambda event: JupyterBackend._output_event(pending, event),
        )
        for _ in range(20):
            if store.entered.is_set():
                break
            await asyncio.sleep(0.01)
        self.assertTrue(store.entered.is_set())
        worker = normalizer._worker_task
        pending.future.set_exception(BackendError("timeout"))
        pending.future.exception()
        backend._pending["active"] = pending
        backend._unregister_pending("active", pending)
        backend._stop_channels()
        replacement = normalizer.attach(str(new_dir))
        for index in range(64):
            normalizer.submit(replacement, f"next-{index}", message("display_data", {"data": {"image/png": payload}, "metadata": {}}), lambda _event: True)
            normalizer.retire(replacement)
            replacement = normalizer.attach(str(new_dir))
        # Retiring queue-blocked generations releases their stores, but the
        # worker remains the single owner that settles their retained markers.
        queued_markers = normalizer._queue.qsize()
        self.assertEqual(queued_markers, EJN_MAX_PENDING_OUTPUTS)
        self.assertEqual(normalizer._pending_artifacts, 1)
        self.assertEqual(normalizer._pending_artifact_bytes, len(payload))
        self.assertEqual(
            normalizer._retained_bytes,
            len(payload) + (queued_markers * _MARKER_BYTES),
        )
        self.assertIs(normalizer._worker_task, worker)
        self.assertEqual(len(normalizer._attachments), 2)
        store.release.set()
        await asyncio.wait_for(normalizer.finish(old, "active"), 1)
        self.assertEqual(list(old_dir.iterdir()), [])
        self.assertEqual(len(normalizer._attachments), 1)
        self.assertEqual(normalizer._pending_artifacts, 0)
        self.assertEqual(normalizer._pending_artifact_bytes, 0)
        self.assertEqual(normalizer._retained_bytes, 0)
        backend.close()
        await asyncio.wait_for(backend.wait_closed(), 1)

    async def test_rejected_artifact_discard_stays_off_the_event_loop(self):
        directory = Path(self.temporary.name) / "discard"
        directory.mkdir(mode=0o700)
        store = _BlockingStore(directory)
        store.release.set()
        store.block_discard = True
        normalizer = OutputNormalizer(artifact_store=store)
        queue = EventQueue(ordinary_limit=1)
        dispatcher = Dispatcher(object(), lambda _response: None, event_queue=queue)
        dispatcher.negotiated = True
        dispatcher.connected = True
        loop = asyncio.get_running_loop()
        record = type("Record", (), {"terminal": False})()
        record.request_id = "discard"
        record.operation = "execute"
        record.timer = loop.call_later(60, lambda: None)
        record.cancellation = None
        record.cancel_requested = False
        dispatcher._inflight["discard"] = record
        payload = base64.b64encode(b"rollback").decode("ascii")
        try:
            normalizer.submit(
                "discard",
                message(
                    "display_data",
                    {"data": {"image/png": payload}, "metadata": {}},
                ),
                lambda event: dispatcher._backend_event("discard", record, event),
            )
            for _ in range(20):
                if store.discard_entered.is_set():
                    break
                await asyncio.sleep(0.01)
            self.assertTrue(store.discard_entered.is_set())
            responses = []
            ping = Dispatcher(object(), responses.append)
            ping.negotiated = True
            started = loop.time()
            ping.dispatch(
                {
                    "v": 1,
                    "kind": "request",
                    "id": "ping",
                    "op": "ping",
                    "params": {},
                }
            )
            self.assertLess(loop.time() - started, 0.05)
            self.assertTrue(responses[-1]["ok"])
            store.discard_release.set()
            await asyncio.wait_for(normalizer.finish("discard"), 1)
            self.assertEqual(list(directory.iterdir()), [])
        finally:
            record.timer.cancel()
            store.release.set()
            store.discard_release.set()
            normalizer.close()
            await normalizer.wait_closed()

    async def test_finish_observes_an_unexpected_worker_stop(self):
        normalizer = OutputNormalizer(str(self.directory))
        entered = asyncio.Event()
        blocker = asyncio.Event()

        async def blocked_normalize(_job, _store):
            entered.set()
            await blocker.wait()
            return []

        normalizer._normalize = blocked_normalize
        normalizer.submit(
            "worker-stop",
            message("stream", {"name": "stdout", "text": "waiting"}),
            lambda _event: True,
        )
        await asyncio.wait_for(entered.wait(), 1)
        assert normalizer._worker_task is not None
        normalizer._worker_task.cancel()
        with self.assertRaisesRegex(RuntimeError, "output worker stopped"):
            await asyncio.wait_for(normalizer.finish("worker-stop"), 1)
        normalizer.close()
        await normalizer.wait_closed()

    async def test_dispatcher_drop_discards_unhanded_artifact_and_keeps_truncation_marker(self):
        queue = EventQueue(ordinary_limit=1)
        dispatcher = Dispatcher(object(), lambda _response: None, event_queue=queue)
        dispatcher.negotiated = True
        dispatcher.connected = True
        loop = asyncio.get_running_loop()
        record = type("Record", (), {"terminal": False})()
        # Use a real inflight record so admission follows the exact dispatcher
        # path without starting a fake backend operation.
        record.request_id = "drop"
        record.operation = "execute"
        record.timer = loop.call_later(60, lambda: None)
        record.cancellation = None
        record.cancel_requested = False
        dispatcher._inflight["drop"] = record
        payload = base64.b64encode(b"discard me").decode("ascii")
        await self.submit(
            "drop",
            message("display_data", {"data": {"image/png": payload}, "metadata": {}}),
            lambda event: dispatcher._backend_event("drop", record, event),
        )
        record.timer.cancel()
        self.assertEqual(list(self.directory.iterdir()), [])
        frames = [json.loads(item.frame[4:].decode("utf-8")) for item in queue.drain()]
        self.assertEqual([item["event"] for item in frames], ["output_truncated"])
        self.assertEqual(frames[0]["request_id"], "drop")

    async def test_admitted_artifact_is_absent_from_backend_event_and_drained_frame(self):
        queue = EventQueue()
        queue.grant_credit(262_144)
        dispatcher = Dispatcher(object(), lambda _response: None, event_queue=queue)
        dispatcher.negotiated = True
        dispatcher.connected = True
        loop = asyncio.get_running_loop()
        record = type("Record", (), {"terminal": False})()
        record.request_id = "admit"
        record.operation = "execute"
        record.timer = loop.call_later(60, lambda: None)
        record.cancellation = None
        record.cancel_requested = False
        dispatcher._inflight["admit"] = record
        backend_events = []
        payload = base64.b64encode(b"frame-safe").decode("ascii")
        await self.submit(
            "admit",
            message("display_data", {"data": {"image/png": payload}, "metadata": {}}),
            lambda event: backend_events.append(event)
            or dispatcher._backend_event("admit", record, event),
        )
        record.timer.cancel()
        self.assertEqual(len(backend_events), 1)
        self.assertFalse(contains(backend_events[0].data, payload))
        self.assertIn("image/png", backend_events[0].data["data"])
        frames = [item.frame for item in queue.drain()]
        self.assertEqual(len(frames), 1)
        self.assertNotIn(payload.encode(), frames[0])
        decoded = json.loads(frames[0][4:].decode("utf-8"))
        self.assertIn("image/png", decoded["data"]["data"])
        self.assertTrue(list(self.directory.iterdir()))

    async def test_post_idle_output_is_ignored_before_it_can_reorder_status(self):
        backend = JupyterBackend()
        attachment = backend._outputs.attach(str(self.directory))
        backend._output_attachment = attachment
        events = []
        pending = _Pending(
            asyncio.get_running_loop().create_future(),
            ExecutionState("message-1"),
            lambda event: events.append(event) or True,
            attachment,
        )
        parent = {"parent_header": {"msg_id": "message-1"}}
        backend._route_iopub(
            pending,
            {**parent, "msg_type": "status", "content": {"execution_state": "idle"}},
        )
        backend._route_iopub(
            pending,
            {**parent, "msg_type": "stream", "content": {"name": "stdout", "text": "late"}},
        )
        self.assertEqual([event.name for event in events], ["status"])
        backend.close()
        await backend.wait_closed()


if __name__ == "__main__":
    unittest.main()
