"""Real local-kernel proof of suspended helper ownership across tunnel loss."""

from __future__ import annotations

import asyncio
import tempfile
import unittest
from pathlib import Path

from ejn_helper.jupyter_backend import JupyterBackend
from kernel_fixture import LocalKernelFixture
from tcp_relays import TcpRelayHarness


@unittest.skipUnless(LocalKernelFixture.available(), "jupyter_client unavailable")
class TunnelRecoveryTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.fixture = LocalKernelFixture(startup_timeout=10)
        await asyncio.to_thread(self.fixture.start)
        self.addAsyncCleanup(asyncio.to_thread, self.fixture.cleanup)
        self.directory = tempfile.TemporaryDirectory(prefix="ejn-recovery-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.release = self.root / "release"
        self.finished = self.root / "finished"
        self.relay = TcpRelayHarness(self.fixture.connection, deadline=2)
        await self.relay.start()
        self.addAsyncCleanup(self.relay.close)
        self.backend = JupyterBackend(deadline=4)
        self.addAsyncCleanup(self.close_backend)
        artifact_dir = self.root / "artifacts"
        artifact_dir.mkdir(mode=0o700)
        await self.request("connect", {
            "connection_file": str(self.relay.connection_path),
            "artifact_dir": str(artifact_dir),
            "image_max_pixels": 4_194_304,
        })
        # Warm channel subscriptions before the execution boundary under test.
        await self.request("execute", {"code": "ejn_recovery_runs = 0"})
        self.kernel_pid = self.fixture.kernel_pid
        self.client = self.backend.client
        self.local_ports = self.relay.ports

    async def close_backend(self):
        self.backend.close()
        await asyncio.wait_for(self.backend.wait_closed(), 3)

    def start_request(self, operation, params=None):
        completion = asyncio.get_running_loop().create_future()
        events = []
        self.backend.start(operation, params or {}, events.append, completion.set_result)
        return completion, events

    async def request(self, operation, params=None):
        completion, _events = self.start_request(operation, params)
        result = await asyncio.wait_for(completion, 8)
        self.assertIsNone(result.error, result.error)
        return result.result

    async def until(self, predicate, timeout=4):
        async def poll():
            while not predicate():
                await asyncio.sleep(0.01)
        await asyncio.wait_for(poll(), timeout)

    async def running_execution(self):
        code = (
            "import time, pathlib\n"
            "ejn_recovery_runs += 1\n"
            "print('before outage', flush=True)\n"
            f"while not pathlib.Path({str(self.release)!r}).exists():\n"
            "    time.sleep(0.02)\n"
            "print('after recovery', flush=True)\n"
            f"pathlib.Path({str(self.finished)!r}).touch()\n"
        )
        completed, events = self.start_request("execute", {"code": code})
        await self.until(lambda: any(
            event.name == "stream" and "before outage" in event.data.get("text", "")
            for event in events
        ))
        return completed, events

    async def suspend_tunnel(self):
        self.assertEqual(await self.request("suspend"), {"suspended": True})
        await self.relay.stop()
        await asyncio.sleep(0.1)

    async def restore_tunnel(self):
        await self.relay.restart()
        self.assertEqual(await self.request("resume"), {"attached": True})
        self.assertIs(self.backend.client, self.client)
        self.assertEqual(self.relay.ports, self.local_ports)
        self.assertEqual(self.fixture.kernel_pid, self.kernel_pid)

    async def test_busy_reattach_delivers_later_output_and_runs_next_cell_once(self):
        completed, events = await self.running_execution()
        await self.suspend_tunnel()
        await self.restore_tunnel()
        self.assertFalse(completed.done())
        self.release.touch()
        result = await asyncio.wait_for(completed, 6)
        self.assertIsNone(result.error)
        self.assertEqual(result.result["status"], "ok")
        self.assertTrue(any(
            event.name == "stream" and "after recovery" in event.data.get("text", "")
            for event in events
        ))
        # The frontend dispatches its waiting cell only at this completion.
        next_reply = await self.request("execute", {
            "code": "assert ejn_recovery_runs == 1; ejn_recovery_runs += 1"
        })
        self.assertEqual(next_reply["status"], "ok")
        self.assertIsNone(self.backend._recovery_barrier)

    async def test_finished_offline_reconciles_then_admits_waiting_cell(self):
        completed, events = await self.running_execution()
        await self.suspend_tunnel()
        self.release.touch()
        await self.until(self.finished.exists)
        # Give shell reply and IOPub idle time to disappear with no relay peers.
        await asyncio.sleep(0.3)
        self.assertFalse(completed.done())
        await self.restore_tunnel()
        result = await asyncio.wait_for(completed, 6)
        self.assertIsNone(result.error)
        self.assertEqual(result.result["status"], "completed")
        self.assertEqual(
            [event.data["status"] for event in events if event.name == "execute_reply"],
            ["completed"],
        )
        next_reply = await self.request("execute", {"code": "assert ejn_recovery_runs == 1"})
        self.assertEqual(next_reply["status"], "ok")
        self.assertFalse(self.backend._pending)

    async def test_close_during_recovery_leaves_original_kernel_execution_alive(self):
        completed, _events = await self.running_execution()
        await self.suspend_tunnel()
        await self.restore_tunnel()
        await self.until(lambda: self.backend._recovery_barrier is not None)
        await self.close_backend()
        self.assertFalse(completed.done())
        self.assertIsNone(self.backend._recovery_barrier)
        self.assertFalse(self.backend._pending)
        self.release.touch()
        result = await asyncio.to_thread(
            self.fixture.evaluate, "assert ejn_recovery_runs == 1", 6
        )
        self.assertEqual(result["status"], "ok")
        self.assertEqual(self.fixture.kernel_pid, self.kernel_pid)

    async def test_stdin_recovery_prompts_again_with_a_new_one_use_lease(self):
        completed, events = self.start_request("execute", {
            "code": "ejn_recovery_runs += 1; ejn_answer = input('Answer: '); assert ejn_answer == 'new-value'"
        })
        await self.until(lambda: any(event.name == "input_request" for event in events))
        first = next(event.data["input_id"] for event in events if event.name == "input_request")
        await self.suspend_tunnel()
        rejected, _events = self.start_request("input_reply", {
            "input_id": first, "value": "discarded-offline",
        })
        self.assertEqual((await asyncio.wait_for(rejected, 2)).error.code, "busy")
        await self.restore_tunnel()
        prompts = [event.data for event in events if event.name == "input_request"]
        self.assertEqual(len(prompts), 2)
        self.assertNotEqual(first, prompts[-1]["input_id"])
        self.assertEqual(prompts[-1]["prompt"], "Answer: ")
        self.assertEqual(await self.request("input_reply", {
            "input_id": prompts[-1]["input_id"], "value": "new-value",
        }), {"accepted": True})
        self.assertEqual((await asyncio.wait_for(completed, 6)).result["status"], "ok")
        self.assertEqual((await self.request("execute", {
            "code": "assert ejn_recovery_runs == 1"
        }))["status"], "ok")


if __name__ == "__main__":
    unittest.main()
