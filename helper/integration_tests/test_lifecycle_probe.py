"""Executable contract probe for Jupyter lifecycle control messages.

This is deliberately independent of EJN's backend.  It establishes what the
``jupyter kernel --KernelManager.connection_file=...`` parent used by the
test fixture actually does when given protocol-level lifecycle requests.
"""

from __future__ import annotations

import json
import time
import unittest
from queue import Empty

from kernel_fixture import KernelAppFixture


def _wait_message(
    client, channel: str, message_id: str, message_type: str, timeout: float
):
    """Return one correlated message from a test-owned blocking client."""
    deadline = time.monotonic() + timeout
    getter = getattr(client, f"get_{channel}_msg")
    while time.monotonic() < deadline:
        try:
            message = getter(timeout=max(0.05, deadline - time.monotonic()))
        except Empty:
            continue
        if (
            message.get("msg_type") == message_type
            and message.get("parent_header", {}).get("msg_id") == message_id
        ):
            return message
    raise TimeoutError(f"timed out waiting for {message_type}")


def _wait_execute(client, message_id: str, timeout: float) -> dict:
    return _wait_message(client, "shell", message_id, "execute_reply", timeout)


def _wait_status(client, message_id: str, state: str, timeout: float) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        message = _wait_message(
            client,
            "iopub",
            message_id,
            "status",
            max(0.05, deadline - time.monotonic()),
        )
        if message.get("content", {}).get("execution_state") == state:
            return message
    raise TimeoutError(f"timed out waiting for status={state}")


class LifecycleProtocolProbe(unittest.TestCase):
    """Record the lifecycle behavior of the exact fixture launch shape."""

    @unittest.skipUnless(KernelAppFixture.available(), "jupyter_client unavailable")
    def test_protocol_interrupt_leaves_the_kernel_usable(self) -> None:
        with KernelAppFixture(startup_timeout=10) as fixture:
            from jupyter_client import BlockingKernelClient

            assert fixture.connection is not None
            client = BlockingKernelClient()
            client.load_connection_info(fixture.connection)
            client.start_channels()
            try:
                client.wait_for_ready(timeout=8)
                before = (fixture.manager_pid, fixture.kernel_pid)
                execution_id = client.execute("import time\ntime.sleep(30)")
                _wait_status(client, execution_id, "busy", 8)
                interrupt_id = client.session.send(
                    client.control_channel.socket,
                    "interrupt_request",
                    content={},
                )["header"]["msg_id"]
                reply = _wait_message(
                    client, "control", interrupt_id, "interrupt_reply", 8
                )
                shell_reply = _wait_execute(client, execution_id, 8)
                after = (fixture.manager_pid, fixture._descendant_pid())
                self.assertEqual(reply["content"].get("status"), "ok")
                self.assertEqual(shell_reply["content"].get("status"), "error")
                self.assertEqual(before, after)
                self.assertEqual(
                    _wait_execute(client, client.execute("40 + 2"), 8)[
                        "content"
                    ].get("status"),
                    "ok",
                )
            finally:
                client.stop_channels()

    @unittest.skipUnless(KernelAppFixture.available(), "jupyter_client unavailable")
    def test_protocol_restart_does_not_restart_under_kernelapp_parent(self) -> None:
        with KernelAppFixture(startup_timeout=10) as fixture:
            from jupyter_client import BlockingKernelClient

            assert fixture.connection is not None
            assert fixture.connection_path is not None
            client = BlockingKernelClient()
            client.load_connection_info(fixture.connection)
            client.start_channels()
            fresh_client = None
            try:
                client.wait_for_ready(timeout=8)
                self.assertEqual(
                    _wait_execute(client, client.execute("probe_value = 73"), 8)[
                        "content"
                    ].get("status"),
                    "ok",
                )
                manager_before = fixture.manager_pid
                kernel_before = fixture._descendant_pid()
                connection_before = json.loads(
                    fixture.connection_path.read_text("utf-8")
                )
                restart_id = client.shutdown(restart=True)
                reply = _wait_message(
                    client, "control", restart_id, "shutdown_reply", 8
                )
                # A shutdown reply only acknowledges the request.  The
                # KernelApp parent has no restarter, so verify that a *fresh*
                # client cannot attach to a replacement kernel either.
                deadline = time.monotonic() + 8
                kernel_after = fixture._descendant_pid()
                while (
                    kernel_after == kernel_before
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.05)
                    kernel_after = fixture._descendant_pid()
                connection_after = json.loads(
                    fixture.connection_path.read_text("utf-8")
                )
                fresh_client = BlockingKernelClient()
                fresh_client.load_connection_info(connection_after)
                fresh_client.start_channels()
                with self.assertRaises((RuntimeError, TimeoutError)):
                    fresh_client.wait_for_ready(timeout=4)
                self.assertEqual(reply["content"].get("restart"), True)
                self.assertEqual(manager_before, fixture.manager_pid)
                self.assertIsNone(fixture._process.poll())
                if kernel_before is not None:
                    self.assertIsNone(kernel_after)
                self.assertEqual(connection_before, connection_after)
            finally:
                client.stop_channels()
                if fresh_client is not None:
                    fresh_client.stop_channels()

    @unittest.skipUnless(KernelAppFixture.available(), "jupyter_client unavailable")
    def test_protocol_shutdown_stops_child_but_not_kernelapp_parent(self) -> None:
        with KernelAppFixture(startup_timeout=10) as fixture:
            from jupyter_client import BlockingKernelClient

            assert fixture.connection is not None and fixture._process is not None
            client = BlockingKernelClient()
            client.load_connection_info(fixture.connection)
            client.start_channels()
            fresh_client = None
            try:
                client.wait_for_ready(timeout=8)
                manager_before = fixture.manager_pid
                kernel_before = fixture._descendant_pid()
                connection_before = dict(fixture.connection)
                shutdown_id = client.shutdown(restart=False)
                reply = _wait_message(
                    client, "control", shutdown_id, "shutdown_reply", 8
                )
                deadline = time.monotonic() + 8
                kernel_after = fixture._descendant_pid()
                while (
                    kernel_after == kernel_before
                    and time.monotonic() < deadline
                ):
                    time.sleep(0.05)
                    kernel_after = fixture._descendant_pid()
                fresh_client = BlockingKernelClient()
                fresh_client.load_connection_info(fixture.connection)
                fresh_client.start_channels()
                with self.assertRaises((RuntimeError, TimeoutError)):
                    fresh_client.wait_for_ready(timeout=4)
                self.assertEqual(reply["content"].get("restart"), False)
                self.assertEqual(manager_before, fixture.manager_pid)
                self.assertIsNone(fixture._process.poll())
                self.assertEqual(connection_before, fixture.connection)
                if kernel_before is not None:
                    self.assertIsNone(kernel_after)
            finally:
                client.stop_channels()
                if fresh_client is not None:
                    fresh_client.stop_channels()


if __name__ == "__main__":
    unittest.main()
