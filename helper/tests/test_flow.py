"""Deterministic model tests for the pure HT4 event-flow queue."""

import json
import unittest
from unittest import mock

from ejn_helper import flow as flow_module
from ejn_helper.flow import (
    EJN_MAX_EVENT_CREDIT,
    EJN_MAX_EVENT_QUEUE,
    EJN_MAX_RESPONSE_FRAME,
    EJN_SEQUENCE_END,
    EJN_SEQUENCE_START,
    EJN_STREAM_CHUNK_BYTES,
    EventQueue,
    FlowControlError,
)
from ejn_helper.framing import encode


def event(event_name, request_id="request-1", **data):
    value = {
        "v": 1,
        "kind": "event",
        "event": event_name,
        "data": data,
    }
    if request_id is not None:
        value["request_id"] = request_id
    return value


def stream(text, request_id="request-1", name="stdout"):
    return event("stream", request_id, name=name, text=text)


def with_sequence(value, sequence=EJN_SEQUENCE_START):
    framed_value = dict(value)
    framed_value["seq"] = sequence
    return framed_value


def frame_size(value, limit=262_144):
    return len(encode(with_sequence(value), limit))


def decoded(drained):
    return [json.loads(item.frame[4:].decode("utf-8")) for item in drained]


class EventQueueTests(unittest.TestCase):
    def test_discard_releases_both_lanes_credit_and_truncation_state(self):
        queue = EventQueue()
        queue.grant_credit(10)
        queue.enqueue(stream("buffered", request_id="ordinary"))
        dropped = queue.enqueue(
            stream("x" * (EJN_STREAM_CHUNK_BYTES + 1), request_id="discarded")
        )
        self.assertTrue(dropped.marker_enqueued)
        queue.enqueue(event("status", "priority", execution_state="busy"))
        self.assertGreater(queue.ordinary_count, 0)
        self.assertGreater(queue.priority_count, 0)
        self.assertGreater(queue.buffered_bytes, 0)

        queue.discard()
        self.assertEqual(queue.ordinary_count, 0)
        self.assertEqual(queue.priority_count, 0)
        self.assertEqual(queue.buffered_bytes, 0)
        self.assertEqual(queue.credit, 0)

        # Disposal clears the per-request truncation ledger as well.
        accepted = queue.enqueue(stream("after", request_id="discarded"))
        self.assertTrue(accepted.queued)
        queue.discard()
        self.assertEqual(queue.buffered_bytes, 0)

    def test_zero_credit_startup_blocks_ordinary_but_not_priority(self):
        queue = EventQueue()
        queue.enqueue(stream("ordinary"))
        self.assertEqual(queue.credit, 0)
        self.assertEqual(queue.drain(), [])
        queue.enqueue(event("status", execution_state="busy"))
        output = queue.drain()
        self.assertEqual([item.priority for item in output], [True])
        self.assertEqual(decoded(output)[0]["event"], "status")
        self.assertEqual(decoded(output)[0]["seq"], EJN_SEQUENCE_START)
        self.assertEqual(queue.ordinary_count, 1)

    def test_exact_frame_charge_and_exact_replenishment(self):
        queued = stream("abc")
        charge = frame_size(queued)
        queue = EventQueue()
        queue.enqueue(queued)
        self.assertEqual(queue.ordinary_bytes, charge)
        queue.grant_credit(charge - 1)
        self.assertEqual(queue.drain(), [])
        queue.grant_credit(1)
        output = queue.drain()
        self.assertEqual(len(output), 1)
        self.assertEqual(output[0].credit_charge, charge)
        self.assertEqual(len(output[0].frame), charge)
        self.assertEqual(queue.credit, 0)
        self.assertEqual(queue.grant_credit(charge), charge)

    def test_invalid_and_overflowing_credit_grants_are_rejected(self):
        queue = EventQueue()
        for invalid in (True, False, -1, 1.5, "1", None):
            with self.subTest(invalid=invalid):
                with self.assertRaises(FlowControlError) as error:
                    queue.grant_credit(invalid)
                self.assertEqual(error.exception.code, "invalid-request")
        queue.grant_credit(EJN_MAX_EVENT_CREDIT)
        with self.assertRaises(FlowControlError):
            queue.grant_credit(1)

    def test_producer_sequence_is_rejected_and_request_id_is_top_level(self):
        queue = EventQueue()
        supplied = stream("bad")
        supplied["seq"] = 1
        with self.assertRaises(FlowControlError) as error:
            queue.enqueue(supplied)
        self.assertEqual(error.exception.code, "invalid-event")

        nested = event("stream", None, name="stdout", text="bad")
        nested["data"]["request_id"] = "nested-is-not-correlation"
        with self.assertRaises(FlowControlError):
            queue.enqueue(nested)

    def test_multibyte_stream_coalescing_stops_at_32k_without_splitting(self):
        queue = EventQueue()
        first = "é" * ((EJN_STREAM_CHUNK_BYTES // 2) - 1)
        self.assertTrue(queue.enqueue(stream(first)).queued)
        self.assertTrue(queue.enqueue(stream("é")).coalesced)
        self.assertFalse(queue.enqueue(stream("é")).coalesced)
        queue.grant_credit(EJN_MAX_EVENT_CREDIT)
        output = decoded(queue.drain())
        texts = [item["data"]["text"] for item in output]
        self.assertEqual([len(text.encode("utf-8")) for text in texts], [32_768, 2])
        self.assertEqual("".join(texts), first + "éé")

    def test_only_adjacent_same_request_and_stream_coalesce(self):
        queue = EventQueue()
        self.assertTrue(queue.enqueue(stream("a")).queued)
        self.assertTrue(queue.enqueue(stream("b")).coalesced)
        self.assertFalse(queue.enqueue(stream("c", name="stderr")).coalesced)
        self.assertFalse(queue.enqueue(stream("d", request_id="request-2")).coalesced)
        queue.enqueue(event("status", execution_state="busy"))
        self.assertFalse(queue.enqueue(stream("e", request_id="request-2")).coalesced)
        queue.grant_credit(EJN_MAX_EVENT_CREDIT)
        output = decoded(queue.drain())
        self.assertEqual(
            [(item["event"], item["data"].get("text")) for item in output],
            [
                ("stream", "ab"),
                ("stream", "c"),
                ("stream", "d"),
                ("status", None),
                ("stream", "e"),
            ],
        )

    def test_coalesced_accounting_uses_one_exact_complete_frame(self):
        queue = EventQueue()
        queue.enqueue(stream("alpha"))
        queue.enqueue(stream("beta"))
        expected = frame_size(stream("alphabeta"))
        self.assertEqual(queue.ordinary_bytes, expected)
        queue.grant_credit(expected)
        output = queue.drain()
        self.assertEqual(output[0].credit_charge, expected)
        self.assertEqual(len(output[0].frame), expected)

    def test_100_mib_logical_stream_is_bounded_and_suppressed_before_encode(self):
        queue = EventQueue()
        chunk = "x" * EJN_STREAM_CHUNK_BYTES
        logical_bytes = 100 * 1024 * 1024
        with mock.patch.object(flow_module, "encode", wraps=encode) as instrumented:
            for _offset in range(0, logical_bytes, len(chunk)):
                queue.enqueue(stream(chunk))
        self.assertLess(queue.ordinary_count, 64)
        self.assertLessEqual(queue.ordinary_bytes, EJN_MAX_EVENT_QUEUE)
        self.assertLessEqual(queue.max_observed_ordinary_bytes, EJN_MAX_EVENT_QUEUE)
        self.assertEqual(queue.priority_count, 1)
        self.assertLessEqual(
            queue.max_observed_total_bytes,
            queue.ordinary_limit + queue.priority_limit,
        )
        self.assertGreater(queue.dropped_events, 1_000)
        self.assertLess(instrumented.call_count, 100)
        markers = decoded(queue.drain())
        self.assertEqual([item["event"] for item in markers], ["output_truncated"])
        self.assertEqual(markers[0]["request_id"], "request-1")
        self.assertEqual(markers[0]["data"], {})

    def test_stream_over_chunk_limit_is_dropped_without_retaining_text(self):
        queue = EventQueue()
        too_large = "é" * ((EJN_STREAM_CHUNK_BYTES // 2) + 1)
        result = queue.enqueue(stream(too_large))
        self.assertTrue(result.dropped)
        self.assertTrue(result.marker_enqueued)
        self.assertEqual(queue.ordinary_bytes, 0)
        self.assertEqual(queue.ordinary_count, 0)

    def test_truncated_request_stays_suppressed_after_drain_until_reset(self):
        first = stream("a")
        charge = frame_size(first)
        queue = EventQueue(ordinary_limit=charge)
        queue.enqueue(first)
        first_drop = queue.enqueue(stream("b"))
        self.assertTrue(first_drop.marker_enqueued)
        markers = decoded(queue.drain())
        self.assertEqual([item["event"] for item in markers], ["output_truncated"])
        self.assertEqual(markers[0]["request_id"], "request-1")
        self.assertNotIn("request_id", markers[0]["data"])

        queue.grant_credit(charge)
        queue.drain()
        later_drop = queue.enqueue(stream("c"))
        self.assertTrue(later_drop.dropped)
        self.assertFalse(later_drop.marker_enqueued)
        self.assertEqual(queue.ordinary_count, 0)
        self.assertEqual(queue.priority_count, 0)

        queue.reset_request("request-1")
        accepted = queue.enqueue(stream("d"))
        self.assertTrue(accepted.queued)
        self.assertFalse(accepted.dropped)

    def test_overflow_tracks_markers_independently_per_request(self):
        first = stream("a")
        queue = EventQueue(ordinary_limit=frame_size(first))
        queue.enqueue(first)
        self.assertTrue(queue.enqueue(stream("b")).marker_enqueued)
        self.assertFalse(queue.enqueue(stream("c")).marker_enqueued)
        self.assertTrue(
            queue.enqueue(stream("d", request_id="request-2")).marker_enqueued
        )
        markers = decoded(queue.drain())
        self.assertEqual(
            [item["request_id"] for item in markers],
            ["request-1", "request-2"],
        )

    def test_truncated_request_limit_is_validated_and_reset_reuses_a_slot(self):
        for invalid in (True, 0, 9):
            with self.subTest(invalid=invalid):
                with self.assertRaises(ValueError):
                    EventQueue(max_truncated_requests=invalid)

        first = stream("a")
        queue = EventQueue(ordinary_limit=frame_size(first))
        queue.enqueue(first)
        for number in range(1, 9):
            result = queue.enqueue(stream("b", request_id=f"request-{number}"))
            self.assertTrue(result.marker_enqueued)
        self.assertEqual(queue.priority_count, 8)

        queue.reset_request("request-1")
        replacement = queue.enqueue(stream("c", request_id="request-9"))
        self.assertTrue(replacement.marker_enqueued)
        self.assertFalse(queue.failed)
        self.assertEqual(queue.priority_count, 9)

    def test_ninth_unreset_truncated_request_fails_closed(self):
        first = stream("a")
        queue = EventQueue(ordinary_limit=frame_size(first))
        queue.enqueue(first)
        queue.grant_credit(10)
        for number in range(1, 9):
            queue.enqueue(stream("b", request_id=f"request-{number}"))

        with self.assertRaises(FlowControlError) as error:
            queue.enqueue(stream("c", request_id="request-9"))
        self.assertTrue(error.exception.fatal)
        self.assertEqual(error.exception.code, "credit-exhausted")
        self.assertTrue(queue.failed)
        self.assertEqual(queue.buffered_bytes, 0)
        self.assertEqual(queue.ordinary_count, 0)
        self.assertEqual(queue.priority_count, 0)
        self.assertEqual(queue.credit, 0)

    def test_terminal_and_control_events_deliver_with_credit_exhausted(self):
        queue = EventQueue()
        queue.enqueue(stream("blocked"))
        names = ["status", "execute_reply", "input_request"]
        for name in names:
            queue.enqueue(event(name, value=name))
        queue.enqueue(event("transport_error", None, message="lost"))
        output = queue.drain()
        self.assertEqual(
            [item["event"] for item in decoded(output)],
            names + ["transport_error"],
        )
        self.assertTrue(
            all(item.priority and item.credit_charge == 0 for item in output)
        )
        self.assertEqual(queue.ordinary_count, 1)

    def test_priority_exact_frame_boundary_and_exhaustion_fail_closed(self):
        template = event("transport_error", None, message="")
        empty_size = frame_size(template, EJN_MAX_RESPONSE_FRAME)
        template["data"]["message"] = "x" * (EJN_MAX_RESPONSE_FRAME - empty_size)
        self.assertEqual(
            frame_size(template, EJN_MAX_RESPONSE_FRAME), EJN_MAX_RESPONSE_FRAME
        )
        queue = EventQueue(priority_limit=EJN_MAX_RESPONSE_FRAME)
        queue.enqueue(stream("retained"))
        queue.grant_credit(10)
        queue.enqueue(template)
        with self.assertRaises(FlowControlError) as error:
            queue.enqueue(event("status", execution_state="idle"))
        self.assertTrue(error.exception.fatal)
        self.assertEqual(error.exception.code, "credit-exhausted")
        self.assertTrue(queue.failed)
        self.assertEqual(queue.buffered_bytes, 0)
        self.assertEqual(queue.ordinary_count, 0)
        self.assertEqual(queue.priority_count, 0)
        self.assertEqual(queue.credit, 0)
        queue.discard()
        self.assertTrue(queue.failed)
        with self.assertRaises(FlowControlError):
            queue.grant_credit(1)

        oversized = event("transport_error", None, message="")
        oversized["data"]["message"] = "x" * (
            EJN_MAX_RESPONSE_FRAME - empty_size + 1
        )
        other = EventQueue()
        other.enqueue(stream("also-retained"))
        with self.assertRaises(FlowControlError) as error:
            other.enqueue(oversized)
        self.assertTrue(error.exception.fatal)
        self.assertEqual(error.exception.code, "frame-too-large")
        self.assertEqual(other.buffered_bytes, 0)
        self.assertEqual(other.ordinary_count, 0)

    def test_wire_sequences_follow_bypass_order_and_lane_fifo(self):
        queue = EventQueue()
        ordinary = stream("blocked")
        ordinary_charge = frame_size(ordinary)
        queue.enqueue(ordinary)
        queue.enqueue(event("status", execution_state="busy"))
        queue.enqueue(event("execute_reply", status="ok"))

        priority = decoded(queue.drain())
        self.assertEqual(
            [item["event"] for item in priority], ["status", "execute_reply"]
        )
        queue.grant_credit(ordinary_charge)
        later_ordinary = decoded(queue.drain())
        wire = priority + later_ordinary
        self.assertEqual(
            [item["event"] for item in wire],
            ["status", "execute_reply", "stream"],
        )
        self.assertEqual(
            [item["seq"] for item in wire],
            [EJN_SEQUENCE_START, EJN_SEQUENCE_START + 1, EJN_SEQUENCE_START + 2],
        )

        ready = EventQueue()
        ready_ordinary = stream("first")
        ready.enqueue(ready_ordinary)
        ready.enqueue(event("status", execution_state="busy"))
        ready.grant_credit(frame_size(ready_ordinary))
        self.assertEqual(
            [item["event"] for item in decoded(ready.drain())],
            ["stream", "status"],
        )

    def test_sequence_exhaustion_is_fatal_and_releases_queued_payloads(self):
        queue = EventQueue(
            sequence_start=EJN_SEQUENCE_END,
            sequence_end=EJN_SEQUENCE_END,
        )
        ordinary = stream("retained-after-priority")
        queue.enqueue(ordinary)
        queue.enqueue(event("status", execution_state="busy"))
        delivered = decoded(queue.drain())
        self.assertEqual(delivered[0]["seq"], EJN_SEQUENCE_END)
        queue.grant_credit(frame_size(ordinary))
        with self.assertRaises(FlowControlError) as error:
            queue.drain()
        self.assertTrue(error.exception.fatal)
        self.assertEqual(error.exception.code, "protocol-error")
        self.assertEqual(queue.buffered_bytes, 0)
        self.assertEqual(queue.ordinary_count, 0)
        self.assertEqual(queue.priority_count, 0)
        self.assertEqual(queue.credit, 0)


if __name__ == "__main__":
    unittest.main()
