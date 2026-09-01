"""Deterministic tests for the HT6 protocol dispatcher."""

import asyncio
import json
import unittest

from ejn_helper.backend import BackendCompletion, BackendError, BackendEvent
from ejn_helper.dispatcher import (
    EJN_MAX_CODE_BYTES,
    EJN_MAX_INFLIGHT_REQUESTS,
    Dispatcher,
)
from ejn_helper.flow import EJN_MAX_EVENT_CREDIT, EventQueue
from ejn_helper.framing import encode
from helper.tests.fake_backend import FakeBackend, FakePlan


def request(request_id, operation, params=None, **top_level):
    value = {
        "v": 1,
        "kind": "request",
        "id": request_id,
        "op": operation,
        "params": {} if params is None else params,
    }
    value.update(top_level)
    return value


VALID_PARAMS = {
    "hello": {"versions": [1]},
    "ping": {},
    "grant_event_credit": {"bytes": 0},
    "connect": {
        "connection_file": "/tmp/ejn-connection.json",
        "artifact_dir": "/tmp/ejn-artifacts",
        "image_max_pixels": 4_194_304,
    },
    "kernel_info": {},
    "execute": {"code": "1 + 1"},
    "complete": {"code": "pri", "cursor_pos": 3},
    "inspect": {"code": "print", "cursor_pos": 5, "detail_level": 0},
    "is_complete": {"code": "x = 1"},
    "input_reply": {
        "request_id": "exec-1",
        "input_id": "0123456789abcdef0123456789abcdef",
        "value": "yes",
    },
    "interrupt": {},
    "shutdown": {},
    "close": {},
}


def decode_events(frames):
    return [json.loads(item.frame[4:].decode("utf-8")) for item in frames]


class DispatcherTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.loop = asyncio.get_running_loop()
        self.responses = []
        self.backend = FakeBackend(self.loop)
        self.queue = EventQueue()
        self.dispatcher = Dispatcher(
            self.backend,
            self.responses.append,
            event_queue=self.queue,
            loop=self.loop,
            request_timeout=0.05,
        )

    async def negotiate(self):
        self.dispatcher.dispatch(request("hello", "hello", {"versions": [2, 1]}))
        self.assertTrue(self.responses[-1]["ok"])

    async def connect(self):
        await self.negotiate()
        self.dispatcher.dispatch(
            request("connect", "connect", VALID_PARAMS["connect"])
        )
        await asyncio.sleep(0)
        self.assertTrue(self.responses[-1]["ok"])
        self.assertTrue(self.dispatcher.connected)

    async def test_every_non_hello_operation_is_rejected_before_hello(self):
        for operation, params in VALID_PARAMS.items():
            if operation == "hello":
                continue
            with self.subTest(operation=operation):
                responses = []
                backend = FakeBackend(self.loop)
                dispatcher = Dispatcher(backend, responses.append, loop=self.loop)
                dispatcher.dispatch(request(operation, operation, params))
                self.assertFalse(responses[-1]["ok"])
                self.assertEqual(responses[-1]["error"]["code"], "busy")
                self.assertEqual(backend.starts, [])
                self.assertFalse(backend.closed)

    async def test_hello_negotiation_and_version_failure(self):
        self.dispatcher.dispatch(request("old", "hello", {"versions": [2]}))
        self.assertEqual(self.responses[-1]["error"]["code"], "unsupported")
        self.assertFalse(self.dispatcher.negotiated)

        await self.negotiate()
        result = self.responses[-1]["result"]
        self.assertEqual(result["version"], 1)
        self.assertIsInstance(result["helper_version"], str)
        self.assertIn("event-credit", result["capabilities"])
        self.dispatcher.dispatch(request("again", "hello", {"versions": [1]}))
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")

    async def test_state_rules_before_connect_and_local_operations(self):
        await self.negotiate()
        backend_operations = set(VALID_PARAMS) - {
            "hello",
            "ping",
            "grant_event_credit",
            "connect",
            "close",
        }
        for operation in sorted(backend_operations):
            with self.subTest(operation=operation):
                self.dispatcher.dispatch(
                    request(operation, operation, VALID_PARAMS[operation])
                )
                self.assertEqual(self.responses[-1]["error"]["code"], "busy")
        self.dispatcher.dispatch(request("ping", "ping"))
        self.assertEqual(self.responses[-1]["result"], {"alive": True})
        self.dispatcher.dispatch(
            request("credit", "grant_event_credit", {"bytes": 10})
        )
        self.assertEqual(self.responses[-1]["result"], {"credit": 10})
        self.assertEqual(self.backend.starts, [])

    async def test_connect_image_max_pixels_uses_exact_protocol_range(self):
        self.dispatcher.negotiated = True
        for value in (0, 4_194_304):
            with self.subTest(value=value):
                params = dict(VALID_PARAMS["connect"], image_max_pixels=value)
                self.dispatcher.dispatch(request(str(value), "connect", params))
                await asyncio.sleep(0)
                self.assertTrue(self.responses[-1]["ok"])
                self.dispatcher._inflight.clear()
                self.dispatcher.connected = False
        for value in (-1, 4_194_305, True):
            with self.subTest(value=value):
                params = dict(VALID_PARAMS["connect"], image_max_pixels=value)
                self.dispatcher.dispatch(request(str(value), "connect", params))
                self.assertEqual(
                    self.responses[-1]["error"]["code"], "invalid-request"
                )
        params = dict(VALID_PARAMS["connect"])
        params.pop("image_max_pixels")
        self.dispatcher.dispatch(request("missing", "connect", params))
        self.assertEqual(self.responses[-1]["error"]["code"], "invalid-request")

        close_responses = []
        close_backend = FakeBackend(self.loop)
        close_dispatcher = Dispatcher(
            close_backend, close_responses.append, loop=self.loop
        )
        close_dispatcher.dispatch(request("hello-close", "hello", {"versions": [1]}))
        close_dispatcher.dispatch(request("close-before-connect", "close"))
        self.assertTrue(close_responses[-1]["ok"])
        self.assertEqual(close_backend.close_calls, 1)

    async def test_unknown_operation_and_envelope_validation(self):
        self.dispatcher.dispatch(request("unknown", "not-an-operation"))
        self.assertEqual(self.responses[-1]["error"]["code"], "unsupported")
        malformed = [
            None,
            {},
            {"v": 2, "kind": "request", "id": "x", "op": "ping", "params": {}},
            {"v": 1, "kind": "other", "id": "x", "op": "ping", "params": {}},
            {"v": 1, "kind": "request", "id": 1, "op": "ping", "params": {}},
            {"v": 1, "kind": "request", "id": "x", "op": 1, "params": {}},
            {"v": 1, "kind": "request", "id": "x", "op": "ping", "params": []},
        ]
        for envelope in malformed:
            with self.subTest(envelope=envelope):
                self.dispatcher.dispatch(envelope)
                self.assertFalse(self.responses[-1]["ok"])

    async def test_every_operation_rejects_extra_params(self):
        self.dispatcher.negotiated = True
        self.dispatcher.connected = True
        for operation, params in VALID_PARAMS.items():
            with self.subTest(operation=operation):
                invalid = dict(params)
                invalid["extra"] = "not allowed"
                self.dispatcher.dispatch(request(operation, operation, invalid))
                self.assertEqual(
                    self.responses[-1]["error"]["code"], "invalid-request"
                )
        self.assertEqual(self.backend.starts, [])

    async def test_missing_and_wrong_per_operation_fields(self):
        self.dispatcher.negotiated = True
        self.dispatcher.connected = True
        invalid_cases = [
            ("hello", {}),
            ("hello", {"versions": [True]}),
            ("grant_event_credit", {}),
            ("grant_event_credit", {"bytes": True}),
            ("connect", {"connection_file": "/tmp/a"}),
            (
                "connect",
                {
                    "connection_file": "relative",
                    "artifact_dir": "/tmp/a",
                    "image_max_pixels": 4_194_304,
                },
            ),
            ("execute", {}),
            ("execute", {"code": 1}),
            ("complete", {"code": "x"}),
            ("complete", {"code": "x", "cursor_pos": True}),
            ("inspect", {"code": "x", "cursor_pos": 1, "detail_level": 2}),
            ("is_complete", {"code": None}),
            ("input_reply", {"request_id": "x"}),
            ("input_reply", {"request_id": "", "input_id": "0" * 32, "value": "x"}),
        ]
        for number, (operation, params) in enumerate(invalid_cases):
            with self.subTest(operation=operation, params=params):
                self.dispatcher.dispatch(request(str(number), operation, params))
                self.assertEqual(
                    self.responses[-1]["error"]["code"], "invalid-request"
                )
        self.assertEqual(self.backend.starts, [])

    async def test_backend_operations_dispatch_after_connect(self):
        await self.connect()
        operations = [
            "kernel_info",
            "execute",
            "complete",
            "inspect",
            "is_complete",
            "interrupt",
            "shutdown",
        ]
        for number, operation in enumerate(operations):
            if operation == "shutdown":
                self.dispatcher.connected = True
            self.dispatcher.dispatch(
                request(f"op-{number}", operation, VALID_PARAMS[operation])
            )
            await asyncio.sleep(0)
            self.assertTrue(self.responses[-1]["ok"])
        self.assertEqual(
            [item.operation for item in self.backend.starts],
            ["connect"] + operations,
        )
        self.assertFalse(self.dispatcher.connected)

    async def test_restart_is_not_a_protocol_v1_operation(self):
        await self.connect()
        self.dispatcher.dispatch(request("restart", "restart", {}))
        self.assertFalse(self.responses[-1]["ok"])
        self.assertEqual(self.responses[-1]["error"]["code"], "unsupported")
        self.assertNotIn(
            "restart", [item.operation for item in self.backend.starts]
        )

    async def test_failed_shutdown_clears_attachment_state(self):
        await self.connect()
        self.backend.queue_plan("shutdown", FakePlan(error=BackendError("timeout")))
        self.dispatcher.dispatch(request("shutdown-failed", "shutdown", {}))
        await asyncio.sleep(0)
        self.assertFalse(self.responses[-1]["ok"])
        self.assertEqual(self.responses[-1]["error"]["code"], "timeout")
        self.assertFalse(self.dispatcher.connected)

    async def test_duplicate_id_and_inflight_bound(self):
        await self.connect()
        for _number in range(EJN_MAX_INFLIGHT_REQUESTS):
            self.backend.queue_plan("kernel_info", FakePlan(delay=1.0))
        for number in range(EJN_MAX_INFLIGHT_REQUESTS):
            self.dispatcher.dispatch(
                request(f"held-{number}", "kernel_info")
            )
        self.assertEqual(self.dispatcher.inflight_count, EJN_MAX_INFLIGHT_REQUESTS)

        self.dispatcher.dispatch(request("held-0", "kernel_info"))
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")
        self.dispatcher.dispatch(request("ninth", "kernel_info"))
        self.assertEqual(self.responses[-1]["error"]["code"], "busy")
        self.dispatcher.dispatch(request("health", "ping"))
        self.assertTrue(self.responses[-1]["ok"])
        self.assertEqual(len(self.backend.starts), 1 + EJN_MAX_INFLIGHT_REQUESTS)

        self.dispatcher.dispatch(request("close", "close"))
        self.assertEqual(self.dispatcher.inflight_count, 0)

    async def test_deadline_cancels_and_ignores_late_completion(self):
        await self.connect()
        self.backend.queue_plan(
            "execute",
            FakePlan(
                delay=0.04,
                result={"status": "late"},
                events=(BackendEvent("stream", {"name": "stdout", "text": "late"}),),
                ignore_cancellation=True,
            ),
        )
        self.dispatcher.operation_timeouts["execute"] = 0.01
        self.dispatcher.dispatch(request("slow", "execute", {"code": "secret()"}))
        await asyncio.sleep(0.02)
        matching = [item for item in self.responses if item["id"] == "slow"]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["error"]["code"], "timeout")
        self.assertEqual(self.backend.cancel_calls, 1)
        await asyncio.sleep(0.04)
        self.assertEqual(
            len([item for item in self.responses if item["id"] == "slow"]), 1
        )
        self.assertEqual(self.dispatcher.late_completions, 1)
        self.assertEqual(self.dispatcher.late_events, 1)

    async def test_kernel_info_override_does_not_extend_ordinary_operation_deadline(self):
        await self.connect()
        dispatcher = Dispatcher(
            self.backend,
            self.responses.append,
            event_queue=EventQueue(),
            loop=self.loop,
            request_timeout=0.01,
            operation_timeouts={"kernel_info": 0.08},
        )
        dispatcher.negotiated = True
        dispatcher.connected = True
        self.backend.queue_plan("kernel_info", FakePlan(delay=1.0))
        self.backend.queue_plan("execute", FakePlan(delay=1.0))
        dispatcher.dispatch(request("slow-info", "kernel_info"))
        dispatcher.dispatch(request("slow-execute", "execute", {"code": "x"}))
        info_timer = dispatcher._inflight["slow-info"].timer
        execute_timer = dispatcher._inflight["slow-execute"].timer
        now = self.loop.time()
        self.assertGreater(info_timer.when() - now, 0.04)
        self.assertLess(execute_timer.when() - now, 0.04)
        dispatcher.dispose()

    async def test_duplicate_backend_completion_emits_one_response(self):
        await self.connect()
        self.backend.queue_plan(
            "kernel_info",
            FakePlan(result={"status": "ok"}, duplicate_completion=True),
        )
        self.dispatcher.dispatch(request("duplicate", "kernel_info"))
        await asyncio.sleep(0)
        self.assertEqual(
            len([item for item in self.responses if item["id"] == "duplicate"]),
            1,
        )
        self.assertEqual(self.dispatcher.late_completions, 1)

    async def test_response_callback_exception_is_terminal(self):
        calls = []

        def broken_callback(response):
            calls.append(response["id"])
            raise RuntimeError("callback path /secret")

        backend = FakeBackend(self.loop)
        dispatcher = Dispatcher(backend, broken_callback, loop=self.loop)
        dispatcher.dispatch(request("hello", "hello", {"versions": [1]}))
        dispatcher.connected = True
        backend.queue_plan("kernel_info", FakePlan(duplicate_completion=True))
        dispatcher.dispatch(request("callback", "kernel_info"))
        await asyncio.sleep(0)
        self.assertEqual(calls, ["hello", "callback"])
        self.assertEqual(dispatcher.callback_failures, 2)
        self.assertEqual(dispatcher.inflight_count, 0)
        self.assertEqual(dispatcher.late_completions, 1)

    async def test_safe_backend_errors_never_expose_exception_text(self):
        await self.connect()
        secret = "/home/user/kernel.json key=abc code=print(secret)"
        self.backend.queue_plan("execute", FakePlan(error=RuntimeError(secret)))
        self.dispatcher.dispatch(request("unsafe", "execute", {"code": secret}))
        await asyncio.sleep(0)
        unsafe = self.responses[-1]
        self.assertEqual(unsafe["error"]["code"], "transport-error")
        self.assertNotIn(secret, json.dumps(unsafe))

        self.backend.queue_plan("execute", FakePlan(error=BackendError("timeout")))
        self.dispatcher.dispatch(request("safe", "execute", {"code": secret}))
        await asyncio.sleep(0)
        safe = self.responses[-1]
        self.assertEqual(safe["error"]["code"], "timeout")
        self.assertNotIn(secret, json.dumps(safe))

        self.backend.queue_plan(
            "execute", FakePlan(raise_on_start=RuntimeError(secret))
        )
        self.dispatcher.dispatch(request("raised", "execute", {"code": secret}))
        raised = self.responses[-1]
        self.assertEqual(raised["error"]["code"], "transport-error")
        self.assertNotIn(secret, json.dumps(raised))

    async def test_code_limit_is_exact_and_oversize_is_not_dispatched(self):
        await self.connect()
        exact = "x" * EJN_MAX_CODE_BYTES
        self.dispatcher.dispatch(request("exact", "execute", {"code": exact}))
        await asyncio.sleep(0)
        self.assertTrue(self.responses[-1]["ok"])
        starts_before = len(self.backend.starts)

        over = exact + "x"
        self.dispatcher.dispatch(request("over", "execute", {"code": over}))
        self.assertEqual(self.responses[-1]["error"]["code"], "invalid-request")
        self.assertEqual(len(self.backend.starts), starts_before)
        self.assertNotIn(over, json.dumps(self.responses[-1]))

    async def test_event_correlation_credit_and_sequence_assignment(self):
        await self.connect()
        self.backend.queue_plan(
            "execute",
            FakePlan(
                events=(BackendEvent("stream", {"name": "stdout", "text": "ok"}),),
                result={"status": "ok"},
            ),
        )
        self.dispatcher.dispatch(
            request("credit", "grant_event_credit", {"bytes": EJN_MAX_EVENT_CREDIT})
        )
        self.dispatcher.dispatch(request("exec-9", "execute", {"code": "1 + 1"}))
        await asyncio.sleep(0)
        frames = decode_events(self.queue.drain())
        self.assertEqual(len(frames), 1)
        self.assertEqual(frames[0]["request_id"], "exec-9")
        self.assertIsInstance(frames[0]["seq"], int)
        self.assertNotIn("request_id", frames[0]["data"])
        self.assertEqual(self.dispatcher.inflight_count, 0)

    async def test_queue_truncation_preserves_terminal_events_and_one_marker(self):
        queue = EventQueue(ordinary_limit=1)
        dispatcher = Dispatcher(
            self.backend,
            self.responses.append,
            event_queue=queue,
            loop=self.loop,
        )
        dispatcher.negotiated = True
        dispatcher.connected = True
        self.backend.queue_plan(
            "execute",
            FakePlan(
                events=(
                    BackendEvent("stream", {"name": "stdout", "text": "first"}),
                    BackendEvent("stream", {"name": "stdout", "text": "second"}),
                    BackendEvent("execute_reply", {"status": "ok"}),
                )
            ),
        )
        dispatcher.dispatch(request("truncated", "execute", {"code": "print()"}))
        await asyncio.sleep(0)
        self.assertTrue(self.responses[-1]["ok"])
        events = decode_events(queue.drain())
        self.assertEqual(
            [item["event"] for item in events],
            ["output_truncated", "execute_reply"],
        )
        self.assertTrue(all(item["request_id"] == "truncated" for item in events))

    async def test_invalid_backend_event_finishes_with_safe_protocol_error(self):
        await self.connect()
        self.backend.queue_plan("execute", FakePlan(events=(object(),)))
        self.dispatcher.dispatch(request("bad-event", "execute", {"code": "secret"}))
        await asyncio.sleep(0)
        matching = [item for item in self.responses if item["id"] == "bad-event"]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["error"]["code"], "protocol-error")
        self.assertEqual(self.dispatcher.late_completions, 1)
        self.assertEqual(self.backend.cancel_calls, 1)
        self.assertTrue(self.backend.cancellations[-1].cancelled)
        self.assertEqual(self.dispatcher.inflight_count, 0)

    async def test_synchronous_invalid_event_cancels_returned_handle(self):
        await self.connect()
        self.backend.queue_plan(
            "execute",
            FakePlan(events=(object(),), synchronous=True),
        )
        self.dispatcher.dispatch(
            request("sync-invalid", "execute", {"code": "work()"})
        )
        matching = [item for item in self.responses if item["id"] == "sync-invalid"]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["error"]["code"], "protocol-error")
        self.assertEqual(self.backend.cancel_calls, 1)
        self.assertTrue(self.backend.cancellations[-1].cancelled)
        self.assertEqual(self.dispatcher.late_completions, 1)
        self.assertEqual(self.dispatcher.inflight_count, 0)

    async def test_normal_synchronous_completion_does_not_cancel(self):
        await self.connect()
        self.backend.queue_plan(
            "kernel_info", FakePlan(result={"status": "ok"}, synchronous=True)
        )
        self.dispatcher.dispatch(request("sync-ok", "kernel_info"))
        self.assertTrue(self.responses[-1]["ok"])
        self.assertEqual(self.backend.cancel_calls, 0)
        self.assertFalse(self.backend.cancellations[-1].cancelled)
        self.assertEqual(self.dispatcher.inflight_count, 0)

    async def test_fatal_flow_event_failure_cancels_backend_operation(self):
        await self.connect()
        self.backend.queue_plan(
            "execute",
            FakePlan(
                events=(
                    BackendEvent("status", {"value": "x" * 70_000}),
                )
            ),
        )
        self.dispatcher.dispatch(
            request("flow-failure", "execute", {"code": "work()"})
        )
        await asyncio.sleep(0)
        response = next(
            item for item in self.responses if item["id"] == "flow-failure"
        )
        self.assertEqual(response["error"]["code"], "frame-too-large")
        self.assertEqual(self.backend.cancel_calls, 1)
        self.assertEqual(self.dispatcher.inflight_count, 0)

    async def test_nonfinite_timeouts_are_rejected(self):
        for invalid in (float("nan"), float("inf"), float("-inf")):
            with self.subTest(kind="request", invalid=invalid):
                with self.assertRaises(ValueError):
                    Dispatcher(
                        self.backend,
                        self.responses.append,
                        loop=self.loop,
                        request_timeout=invalid,
                    )
            with self.subTest(kind="operation", invalid=invalid):
                with self.assertRaises(ValueError):
                    Dispatcher(
                        self.backend,
                        self.responses.append,
                        loop=self.loop,
                        operation_timeouts={"execute": invalid},
                    )

    async def test_closed_loop_is_one_safe_error_without_inflight_state(self):
        await self.negotiate()
        self.dispatcher.connected = True
        closed_loop = asyncio.new_event_loop()
        closed_loop.close()
        dispatcher = Dispatcher(
            self.backend,
            self.responses.append,
            loop=closed_loop,
        )
        dispatcher.negotiated = True
        dispatcher.connected = True
        starts_before = len(self.backend.starts)
        dispatcher.dispatch(request("closed-loop", "kernel_info"))
        matching = [item for item in self.responses if item["id"] == "closed-loop"]
        self.assertEqual(len(matching), 1)
        self.assertEqual(matching[0]["error"]["code"], "transport-error")
        self.assertEqual(dispatcher.inflight_count, 0)
        self.assertEqual(len(self.backend.starts), starts_before)

    async def test_surrogates_are_rejected_before_backend_or_response_encoding(self):
        dispatcher = Dispatcher(
            self.backend,
            self.responses.append,
            loop=self.loop,
        )
        dispatcher.negotiated = True
        dispatcher.connected = True
        surrogate = "\ud800"
        cases = [
            request(surrogate, "kernel_info"),
            request("code", "execute", {"code": surrogate}),
            request(
                "connection-path",
                "connect",
                {
                    "connection_file": f"/tmp/{surrogate}",
                    "artifact_dir": "/tmp/artifacts",
                    "image_max_pixels": 4_194_304,
                },
            ),
            request(
                "artifact-path",
                "connect",
                {
                    "connection_file": "/tmp/connection.json",
                    "artifact_dir": f"/tmp/{surrogate}",
                    "image_max_pixels": 4_194_304,
                },
            ),
            request(
                "input-id",
                "input_reply",
                {
                    "request_id": surrogate,
                    "input_id": "0" * 32,
                    "value": "value",
                },
            ),
            request(
                "input-value",
                "input_reply",
                {
                    "request_id": "exec",
                    "input_id": "0" * 32,
                    "value": surrogate,
                },
            ),
        ]
        for envelope in cases:
            with self.subTest(request_id=envelope["id"]):
                dispatcher.dispatch(envelope)
                response = self.responses[-1]
                self.assertFalse(response["ok"])
                encode(response, 65_536)
        self.assertEqual(self.responses[-len(cases)]["id"], "")
        self.assertEqual(self.backend.starts, [])

    async def test_oversized_backend_result_becomes_bounded_error(self):
        await self.connect()
        self.backend.queue_plan(
            "kernel_info", FakePlan(result={"value": "x" * 70_000})
        )
        self.dispatcher.dispatch(request("large-result", "kernel_info"))
        await asyncio.sleep(0)
        response = self.responses[-1]
        self.assertFalse(response["ok"])
        self.assertEqual(response["error"]["code"], "frame-too-large")
        self.assertLess(len(json.dumps(response)), 1_000)

        responses = []
        backend = FakeBackend(self.loop)
        dispatcher = Dispatcher(backend, responses.append, loop=self.loop)
        dispatcher.dispatch(request("hello-large", "hello", {"versions": [1]}))
        backend.queue_plan("connect", FakePlan(result={"value": "x" * 70_000}))
        dispatcher.dispatch(
            request("large-connect", "connect", VALID_PARAMS["connect"])
        )
        await asyncio.sleep(0)
        self.assertEqual(responses[-1]["error"]["code"], "frame-too-large")
        self.assertFalse(dispatcher.connected)

    async def test_close_is_local_cancels_inflight_and_ignores_late_callback(self):
        await self.connect()
        self.backend.queue_plan(
            "execute",
            FakePlan(delay=0.03, ignore_cancellation=True),
        )
        self.dispatcher.dispatch(request("running", "execute", {"code": "work()"}))
        self.dispatcher.event_queue.enqueue(
            {
                "v": 1,
                "kind": "event",
                "event": "status",
                "request_id": "running",
                "data": {"execution_state": "busy"},
            }
        )
        self.assertGreater(self.dispatcher.event_queue.buffered_bytes, 0)
        self.dispatcher.dispatch(request("close", "close"))
        matching = {
            item["id"]: item
            for item in self.responses
            if item["id"] in {"running", "close"}
        }
        self.assertEqual(matching["running"]["error"]["code"], "transport-error")
        self.assertTrue(matching["close"]["ok"])
        self.assertEqual(self.backend.close_calls, 1)
        self.assertTrue(self.backend.closed)
        self.assertEqual(self.backend.cancel_calls, 1)
        self.assertEqual(self.dispatcher.event_queue.buffered_bytes, 0)
        self.assertNotIn("shutdown", [item.operation for item in self.backend.starts])
        await asyncio.sleep(0.04)
        self.assertEqual(self.dispatcher.late_completions, 1)
        self.dispatcher.dispatch(request("after", "ping"))
        self.assertEqual(self.responses[-1]["error"]["code"], "transport-error")

    async def test_close_blocks_reentrant_work_from_cancellation_response(self):
        backend = FakeBackend(self.loop)
        responses = []
        dispatcher = None

        def reentrant(response):
            responses.append(response)
            if response["id"] == "running":
                dispatcher.dispatch(request("reentrant", "kernel_info"))

        dispatcher = Dispatcher(backend, reentrant, loop=self.loop)
        dispatcher.dispatch(request("hello", "hello", {"versions": [1]}))
        dispatcher.connected = True
        backend.queue_plan("execute", FakePlan(delay=1.0))
        dispatcher.dispatch(request("running", "execute", {"code": "work()"}))
        dispatcher.dispatch(request("close", "close"))
        reentrant_response = next(
            item for item in responses if item["id"] == "reentrant"
        )
        self.assertEqual(reentrant_response["error"]["code"], "transport-error")
        self.assertEqual([item.operation for item in backend.starts], ["execute"])
        self.assertEqual(dispatcher.inflight_count, 0)

    async def test_dispose_is_local_idempotent_and_emits_nothing(self):
        await self.connect()
        self.backend.queue_plan("execute", FakePlan(delay=1.0))
        self.dispatcher.dispatch(request("active", "execute", {"code": "x"}))
        await asyncio.sleep(0)
        self.dispatcher.event_queue.enqueue(
            {
                "v": 1,
                "kind": "event",
                "event": "display_data",
                "request_id": "active",
                "data": {"text/plain": "retained"},
            }
        )
        self.dispatcher.event_queue.enqueue(
            {
                "v": 1,
                "kind": "event",
                "event": "status",
                "request_id": "active",
                "data": {"execution_state": "busy"},
            }
        )
        self.dispatcher.event_queue.grant_credit(1)
        self.assertGreater(self.dispatcher.event_queue.buffered_bytes, 0)
        response_count = len(self.responses)
        self.dispatcher.dispose()
        self.dispatcher.dispose()
        self.assertTrue(self.dispatcher.closed)
        self.assertFalse(self.dispatcher.connected)
        self.assertEqual(self.dispatcher.inflight_count, 0)
        self.assertEqual(len(self.responses), response_count)
        self.assertEqual(self.backend.close_calls, 1)
        self.assertEqual(self.backend.cancel_calls, 1)
        self.assertEqual(self.dispatcher.event_queue.buffered_bytes, 0)
        self.assertEqual(self.dispatcher.event_queue.credit, 0)

    async def test_dispose_finishes_cleanup_before_classified_failure(self):
        class ResetRaisesQueue(EventQueue):
            def reset_request(self, _request_id):
                raise RuntimeError("private queue failure")

        class ReentrantCancellation:
            def __init__(self, event_callback, completion_callback):
                self.calls = 0
                self.event_callback = event_callback
                self.completion_callback = completion_callback

            def cancel(self):
                self.calls += 1
                # Both callbacks are stale by the time disposal invokes this.
                self.event_callback(BackendEvent("stream", {"name": "stdout", "text": "late"}))
                self.completion_callback(BackendCompletion.success({"late": True}))
                raise RuntimeError("private cancellation failure")

        class DisposalBackend:
            def __init__(self):
                self.close_calls = 0
                self.cancellation = None

            def start(self, _operation, _params, event_callback, completion_callback):
                self.cancellation = ReentrantCancellation(event_callback, completion_callback)
                return self.cancellation

            def close(self):
                self.close_calls += 1
                raise RuntimeError("private close failure")

        responses = []
        backend = DisposalBackend()
        dispatcher = Dispatcher(
            backend,
            responses.append,
            event_queue=ResetRaisesQueue(),
            loop=self.loop,
        )
        dispatcher.negotiated = True
        dispatcher.connected = True
        dispatcher.dispatch(request("active", "execute", {"code": "x"}))
        record = dispatcher._inflight["active"]
        with self.assertRaises(BackendError) as raised:
            dispatcher.dispose()
        self.assertEqual(raised.exception.code, "transport-error")
        self.assertTrue(dispatcher.closed)
        self.assertFalse(dispatcher.connected)
        self.assertEqual(dispatcher.inflight_count, 0)
        self.assertTrue(record.timer.cancelled())
        self.assertEqual(backend.cancellation.calls, 1)
        self.assertEqual(backend.close_calls, 1)
        self.assertEqual(responses, [])
        self.assertEqual(dispatcher.event_queue.buffered_bytes, 0)
        dispatcher.dispose()
        self.assertEqual(backend.close_calls, 1)

    async def test_dispose_idle_is_idempotent_and_never_emits(self):
        dispatcher = Dispatcher(self.backend, self.responses.append, loop=self.loop)
        dispatcher.dispose()
        dispatcher.dispose()
        self.assertTrue(dispatcher.closed)
        self.assertEqual(self.responses, [])
        self.assertEqual(self.backend.close_calls, 1)


if __name__ == "__main__":
    unittest.main()
