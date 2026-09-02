# AG3 Stress Gate

This is a deterministic, local-only stress entry point for the helper
transport. It uses the test-owned relay bridge and local test kernel; it never
uses SSH or a remote host. The wrapper supports `x86_64-linux` and
`aarch64-darwin` only, defaults to five serial repeats, builds `.#ejn-helper`
once, and passes a finite per-batch deadline to the Python supervisor.

Run it from the repository checkout:

```sh
CODE_CELLS_DIR=/path/to/code-cells.el tests/stress/run-ag3.sh
tests/stress/run-ag3.sh --repeat 5 --timeout 120
```

`EMACS` and `CODE_CELLS_DIR` may be overridden. Arguments, host platform,
Emacs, Nix, code-cells, stress files, helper output, and deadlines fail closed.
The supervisor owns temporary directories, relay processes, kernel process
groups, Emacs, metrics, and exact cleanup verification. No GNU `timeout` is
required. A batch timeout is 120 seconds by default and may not be 45 seconds
or less.

## Gate Map

Five repeats are required for the AG3 gate; a single repeat is only a
diagnostic run.  Every row below is loaded by `run-ag3.py` and runs under the
same bounded supervisor, test-owned kernel, and five-relay bridge.

| Global gate | Current test and metric | Status |
| --- | --- | --- |
| 3. Bounded hostile helper faults | `ejn-ag3-th1-lifecycle-faults-are-bounded` covers silence, garbage, oversized prefixes, and mid-frame exit. `emacs-jupyter-notebook-lifecycle-stress.el` adds 13 pre/post exit rows across hello, initial credit, ready-idle, ping, connect, execute, and close, plus one observed late response after its request deadline. Every row asserts callbacks, complete supervision teardown, and a wall-relative 50 ms canary. | Passed five repetitions |
| 4. Five-second credited flood | `ejn-ag3-credited-flood-keeps-emacs-responsive-and-bounded` requires at least 50 canary ticks, over 100 events, two client pings, ping latency under 1000 ms, and queue/raw peaks within protocol limits. Fixture metrics also record frame count and credit/wire-byte accounting. | Passed five repetitions |
| 5. 64 MiB artifact bound | `emacs-jupyter-notebook-artifact-stress.el` sends exact-limit and one-byte-over pickle MIME through a real kernel/helper. It asserts exact `0600` file size/SHA, descriptor-only panel state, no partial file for rejection, successful bounded pings dispatched during the real worker's `.ejn-partial-*` interval, a wall-relative canary, no recognizable base64 on helper stdout, and the v1 frame/queue/raw caps. | Passed five repetitions |
| 6. 100-image and dimension-bomb retention | `emacs-jupyter-notebook-panel-stress.el` publishes 100 helper-style image bundles and asserts exact seven-entry/two-preview retention, leaf retirement, no rematerialization across view rerenders or a live window viewport/detach/reattach cycle, and zero native-image calls for oversized PNG/JPEG dimensions. Older history is retired rather than lazily rematerialized. Peak artifact bytes/files are emitted as metrics. | Passed five repetitions |
| 7. Five-relay outage and identity | `ejn-ag3-th3-public-reconnect-preserves-kernel-and-source` stops all relays until heartbeat loss, then invokes the public interactive reconnect command. Test-local seams stand in only for SSH probe, SCP retrieval, and tunnel acquisition; production registry selection, connection parsing/context, real helper connect, and finalization run. It asserts the same PID/PGID/ports, preserved kernel variable, canary progress, and pristine source. | Passed five repetitions |
| 8. FIFO and transport-boundary execution ordering | `emacs-jupyter-notebook-execution-stress.el` uses real public sends/helper/kernel counters for FIFO, dispatch-time timer arming, and admitted helper death with no queued replay. Its production ledger/reducer table covers queued, pre-write, post-write admission, reply-before-idle, idle-before-reply, and terminal late-event boundaries. Those table rows construct production-ledger states; they are not additional helper process deaths. | Passed five repetitions |

The fixture self-tests independently validate deterministic artifact
sizes/hashes, dimension headers, 100 unique descriptors, credited framing,
fragmentation, replenished credit, ping handling, monotonic sequences, bounded
hostile input and truncated-frame rejection, every lifecycle branch, and clean process exit.  The ERT gates above separately
exercise the production Emacs/helper integration paths.

The required run passed 65/65 ERT executions on `x86_64-linux` on
2026-09-02.  Fresh-process batches completed in 22.64-22.90 seconds.  Across
the five runs, the flood delivered 12,576-14,407 events with 117 canary ticks
and two pings per run (maximum observed latency 911.5 ms); its peak Emacs queue
and raw accumulators remained below 470 KiB and 254 KiB.  The 64 MiB artifact
run served 94-98 pings overall, including 9-10 initiated during the worker's
partial-file interval, with a maximum observed latency of 303.6 ms and
queue/raw peaks below 1.5 KiB.  Panel publication peaked at 14 files/308 bytes
and retained no artifact after final clear.
