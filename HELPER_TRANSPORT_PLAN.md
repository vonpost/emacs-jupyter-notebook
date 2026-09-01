# W20 - Isolated Local Jupyter Helper

This is the execution ledger for replacing EJN's in-Emacs Jupyter transport
with a supervised local helper process.  It is written for agents that should
be given one narrow row at a time.  Do not assign an agent "implement W20".

The helper is local.  It connects to the existing `127.0.0.1` SSH forwards.
It is not installed on the remote and it never owns the remote kernel process.

## Why this work exists

The present adapter can enter synchronous `emacs-jupyter` ZMQ startup/send
loops on Emacs's main thread.  It also lets complete Jupyter messages,
including base64 image payloads, cross into Emacs before EJN can bound or
decode them.  An outer Elisp timer cannot rescue Emacs while such a loop or a
large Lisp reader operation owns the main thread.

The process boundary is the fix:

```text
source buffer and panel (Emacs)
        |
        | bounded, credited, framed JSON over stdio
        v
local Python helper (`jupyter_client.AsyncKernelClient`)
        |
        | Jupyter ZMQ to 127.0.0.1 only
        v
local SSH forwards -> durable remote kernel
```

The helper may be killed and replaced at any time.  Doing that must never
delete the registry entry, remove the remote connection file, or terminate the
remote kernel.

## Agent protocol

Status legend: `[ ]` unclaimed, `[~]` claimed, `[x]` landed, `[!]` blocked.

1. In separate checkouts, an agent claims exactly one row by changing it to
   `[~] owner=<name> claimed=<YYYY-MM-DD>` and commits that claim first.  When
   agents share one checkout/index, the manager pre-claims rows in one commit;
   assigned agents do not edit this ledger or commit, and the manager stages
   and integrates their disjoint file scopes.
2. The agent reads `AGENTS.md`, `ROADMAP.md`, and `LEARNINGS.md`, plus every
   dependency named on the row.
3. The agent changes only the row's file scope.  Expanding scope requires a
   note under the row and manager approval before editing.
4. Tests are written before or with implementation.  A regression test must
   fail for the intended reason before the implementation is applied.
5. No normal test uses SSH, a remote host, Doom, a GUI, or an installed
   `emacs-jupyter`.  Real-kernel tests launch a test-owned local kernel only.
6. Every process/timer test uses `unwind-protect` and asserts that its child
   processes, process buffers, timers, and temporary directories are gone.
7. The agent reports files changed, exact verification commands, and remaining
   risks.  The manager re-reads the diff and runs the full gates.
8. On landing, the manager changes the row to `[x] sha=<short-sha>`.  Agents do
   not mark their own unmerged work landed.

Tasks sharing a file are deliberately ordered.  Do not parallelize them just
because two agents are available.  New tests belong in the task-specific test
file named below; avoid the existing monolithic ERT file until an integration
row explicitly permits it.

## Fixed decisions

Agents implement these decisions; they do not reopen them inside a task.

- Python is the first helper implementation because `jupyter_client` is the
  Jupyter reference client.  The wire protocol remains language-neutral.
- There is one helper process per source buffer/client.  Single-buffer-per-
  kernel remains binding.
- The helper uses `AsyncKernelClient`, never `KernelManager`, in production.
  Production helper code must contain no kernel-launch operation.
- SSH launch, retrieval, tunnelling, registry, cells, panels, and commands stay
  owned by EJN.  The helper owns only Jupyter channels and message processing.
- Helper `close`, process death, buffer kill, mode disable, Emacs exit, timeout,
  and reconnect failure release local resources only.
- User code is never automatically replayed.  After an ambiguous transport
  failure, any accepted non-terminal execution becomes `outcome-unknown`.
- User executions are serialized client-side.  A second send is `queued` until
  the preceding execution is terminal.  Its execution timeout starts only when
  it becomes `dispatched`, not while queued.
- Silent setup executions (formatter/watchdog injection) use the same serial
  queue and have explicit acknowledgements/deadlines.  A connect/restart is not
  ready for user code until required setup executions are terminal.
- Images and matplotlib pickle payloads are decoded/spooled by the helper.
  Base64 image or pickle strings must never be emitted on helper stdout.
- There is exactly one reader task per Jupyter channel.  Operations register
  waiters with a central router; they never compete by calling a channel's
  receive method concurrently.
- Potentially heavy artifact decode/hash/write/fsync work runs in one bounded
  worker, not on the helper asyncio event loop.  The event loop must continue
  answering supervisor pings while an artifact is being written.
- Helper stdout contains protocol frames only.  Diagnostic text goes to
  stderr and is retained through EJN's bounded log facility.
- During migration, a temporary backend selector may retain the old adapter.
  It is a rollout switch, not a permanent compatibility layer.  The final
  phase deletes the old adapter and the runtime `emacs-jupyter` dependency.
- Current `emacs-jupyter` must remain pinned during migration.  The locally
  working revision is `3b9caed3e4cc5f4bc0348eb65d17098de76904e4`.
  Current upstream `05ea84067f784fb7cd1f829d7a0fadcad20466aa`
  rejects EJN's `:connect-p` constructor argument and is not a valid baseline.

## Non-goals

- Do not move the helper to the remote host.
- Do not implement SSH, SCP, registry persistence, cells, or panel UI in Python.
- Do not implement the Jupyter wire protocol or ZMQ framing ourselves.
- Do not introduce TRAMP, `jupyter-tramp`, a remote install, or a remote daemon.
- Do not share one helper or kernel between source buffers.
- Do not persist or replay a queue across Emacs/helper restart.
- Do not build a general backend/plugin framework.
- Do not optimize for arbitrary unbounded output.  Truncation with an explicit
  marker is preferable to endangering Emacs.

## Protocol v1 contract

`HT1` turns this section into test vectors and a standalone protocol document.
Until that row lands, this section is authoritative.

### Framing and limits

Each frame is a four-byte unsigned big-endian payload length followed by one
UTF-8 JSON object.  There is no delimiter or trailing newline.  Both process
sides use binary/unibyte pipes and must handle a prefix or payload split across
arbitrary reads, as well as multiple frames in one read.

Constants for v1:

| Name | Value | Meaning |
|---|---:|---|
| `EJN_PROTOCOL_VERSION` | 1 | Handshake and envelope version |
| `EJN_MAX_TO_EMACS_FRAME` | 262144 bytes | Helper frame accepted by Emacs |
| `EJN_MAX_TO_HELPER_FRAME` | 1048576 bytes | Emacs frame accepted by helper |
| `EJN_MAX_RESPONSE_FRAME` | 65536 bytes | Response/priority frame ceiling |
| `EJN_MAX_CODE_BYTES` | 524288 bytes | UTF-8 source-code ceiling before JSON |
| `EJN_MAX_INFLIGHT_REQUESTS` | 8 | Requests awaiting responses |
| `EJN_INITIAL_EVENT_CREDIT` | 262144 bytes | Maximum unacknowledged event bytes |
| `EJN_MAX_EVENT_QUEUE` | 1048576 bytes | Helper's queued event-byte ceiling |
| `EJN_MAX_PRIORITY_QUEUE` | 524288 bytes | Responses/terminal/control queue ceiling |
| `EJN_MAX_RAW_ACCUMULATOR` | 1048576 bytes | Buffered undecoded bytes in Emacs |
| `EJN_STREAM_CHUNK_BYTES` | 32768 bytes | Largest emitted stream text chunk |
| `EJN_MAX_ARTIFACT_BYTES` | 67108864 bytes | Largest decoded image/pickle artifact |
| `EJN_PARTIAL_FRAME_TIMEOUT` | 5 seconds | Deadline after a frame prefix begins |
| `EJN_HELPER_PING_INTERVAL` | 5 seconds | Local helper liveness interval |
| `EJN_HELPER_PING_TIMEOUT` | 2 seconds | Local helper response deadline |

No setting may mean "unlimited".  Defcustoms may lower these limits.  Raising
a hard protocol limit requires a protocol-version decision and stress test.

The Emacs process filter may append bytes and decode complete envelopes, but it
must not synchronously dispatch an unbounded number of messages.  It processes
at most 16 frames or 262144 payload bytes per invocation, then schedules a
zero-delay timer to continue.  The raw accumulator must never exceed
`EJN_MAX_RAW_ACCUMULATOR`; excess or malformed input is a protocol violation
and kills the local helper.

### Envelopes

Every request has an EJN-generated string ID:

```json
{"v":1,"kind":"request","id":"r-17","op":"kernel_info","params":{}}
```

Every request gets exactly one bounded response:

```json
{"v":1,"kind":"response","id":"r-17","ok":true,"result":{}}
{"v":1,"kind":"response","id":"r-17","ok":false,
 "error":{"code":"timeout","message":"kernel_info timed out"}}
```

Asynchronous Jupyter output is an event.  `seq` is a helper-local monotonic
integer and `request_id` is the EJN execution request, not merely a Jupyter
message ID:

```json
{"v":1,"kind":"event","seq":42,"event":"stream",
 "request_id":"exec-9","data":{"name":"stdout","text":"hello\n"}}
```

Unknown top-level fields are ignored.  Unknown `kind`, `op`, or `event` values
receive/produce a structured `unsupported` error; they must not crash either
side.  A missing/wrong-type required field is `invalid-request` or
`invalid-event`.  Tracebacks and arbitrary exception representations never
cross the protocol; logs retain diagnostic detail and responses expose a short
safe message.

### Handshake

Emacs sends `hello` immediately after process creation, before granting event
credit or sending `connect`:

```json
{"v":1,"kind":"request","id":"hello-1","op":"hello",
 "params":{"versions":[1]}}
```

The response returns the selected version, helper build version, and a fixed
capability list.  Version mismatch, silence, early exit, any bytes before a
valid frame, or text written to stdout fails startup and kills the helper.

### Credit and bounded queues

Ordinary output events consume event credit equal to the complete framed byte
length.  Event credit starts at zero.  After handshake Emacs sends
`grant_event_credit` for `EJN_INITIAL_EVENT_CREDIT`.  Emacs replenishes exactly
the framed bytes of an event only after that event has been dispatched outside
the process filter.

Responses and priority events (`state`, `execute_reply`, `input_request`,
`transport_error`, and `output_truncated`) do not consume ordinary event
credit; each is limited by `EJN_MAX_RESPONSE_FRAME` and all share the bounded
`EJN_MAX_PRIORITY_QUEUE`.  Filling that queue is a fatal local transport error,
not permission to drop terminal state.  Emacs admits at most
`EJN_MAX_INFLIGHT_REQUESTS`, which bounds the responses that can be produced
without Emacs first dispatching earlier ones.

The helper coalesces adjacent same-request/same-stream events up to
`EJN_STREAM_CHUNK_BYTES`.  When event credit is exhausted, queued event bytes
remain bounded by `EJN_MAX_EVENT_QUEUE`.  On overflow it discards further
ordinary stream/result text for that request and guarantees one
`output_truncated` event.  It never drops state transitions,
`execute_reply`, `input_request`, `transport_error`, or the truncation marker.
Terminal/control events use a reserved 65536-byte lane and are themselves
strictly size-bounded.

### Operations

Protocol v1 supports only:

- `hello`
- `ping`
- `grant_event_credit`
- `connect`
- `kernel_info`
- `execute`
- `complete`
- `inspect`
- `is_complete`
- `input_reply`
- `interrupt`
- `shutdown`
- `close`

`connect` reads the already-local rewritten connection file and starts client
channels.  It reports `attached` without pretending that channel construction
proves kernel liveness.  EJN verifies liveness with bounded `kernel_info` and
retains the existing remote-PID fallback for a live-but-busy kernel.

`ping` is local helper liveness only and is answered by the asyncio control
loop without touching Jupyter.  A missed ping deadline kills/replaces the local
helper and follows the same outcome-unknown/reconnect rules as helper exit.

`execute` accepts at most `EJN_MAX_CODE_BYTES` of UTF-8 source before JSON
encoding.  Larger code is rejected locally with an explicit user-facing error;
it is never split into multiple executions.  Silent setup and user executions
share one serialization discipline, but silent setup has no panel entry.

`close` is local-only.  `interrupt` and `shutdown` are permitted only after the
explicit corresponding EJN user command.  Protocol v1 has no helper `restart`
operation: EI6 implements the user-facing restart by explicitly shutting down,
directly relaunching, reconnecting, and verifying a fresh kernel.  HT12/HT12R1
proved these semantics against both the rejected KernelApp parent shape and the
adopted direct-kernelspec launch.

### Execution states

The EJN ledger states are:

```text
queued -> dispatched -> busy -> terminal-ok
                             -> terminal-error
                             -> terminal-cancelled
queued ----------------------> terminal-cancelled
dispatched/busy --------------> outcome-unknown   (transport ambiguity only)
```

Transitions are monotonic.  Late or duplicate events are logged and ignored.
Only one user execution is dispatched at a time.  `complete`, `inspect`,
`is_complete`, `kernel_info`, stdin replies, and control-channel commands are
not part of the user-execution queue, but each has its own request ID and
deadline.

Completion/inspect timeouts discard their eventual late replies.  An execution
becomes terminal only after its correlated `execute_reply` and correlated
IOPub `status=idle` have both arrived; event ordering may be either way.

### Artifacts

Emacs creates a per-helper artifact directory with mode `0700` and passes it to
`connect`.  The helper validates that it is an absolute directory owned by the
current user and writes only beneath it.  Files are written to a random
same-directory temporary path, chmod `0600`, fsynced/closed, and atomically
renamed before an event exposes the final path.

Before base64 decode, the helper rejects input whose conservative decoded-size
estimate exceeds `EJN_MAX_ARTIFACT_BYTES`.  It verifies actual size after
decode.  Events contain only MIME type, byte count, SHA-256, and absolute path.
Emacs rejects paths outside the directory it supplied.

The panel/Emacs side owns retention and deletion after publication.  Helper
exit does not delete published artifacts.  Buffer-local cleanup and the panel
budget may delete them; Emacs startup removes stale EJN artifact directories.

## Global acceptance gates

W20 is not complete until all of these are automated except the explicitly
manual dogfood gate:

1. Killing the helper during an execution leaves the test-owned kernel alive,
   marks the execution `outcome-unknown`, and allows a new helper to reconnect.
2. A variable assigned before helper death is still present after reconnect,
   proving no fresh kernel was silently substituted.
3. A helper that is silent, writes garbage, emits an oversized prefix, stops
   mid-frame, floods legal small frames, or exits in every lifecycle phase is
   bounded and cannot wedge the ERT process.
4. During a five-second credited flood, an independent 50 ms Emacs timer fires
   at least 50 times, protocol accumulator bytes stay within their bound, and
   queued decoded events stay within their bound.  Run the whole scenario
   under an external 30-second `timeout`.
5. A 64 MiB fake PNG/pickle payload is rejected or spooled in a bounded worker
   while helper pings remain responsive; helper stdout contains no recognizable
   base64 sample and no frame exceeds the v1 maximum.
6. One hundred generated image events leave panel/artifact count and bytes at
   the configured limits after retirement; reopening/scrolling the panel does
   not rematerialize base64 or recreate retired files.  Tiny PNG/JPEG fixtures
   advertising dimensions beyond the hard pixel ceiling remain external-only
   placeholders and invoke no Emacs native image decoder API.
7. With five local TCP relays stopped long enough to trigger liveness failure,
   EJN remains responsive, enters reconnect state, and reconnects through the
   same relay ports after they return.  The local kernel PID is unchanged.
8. Two quick user sends finish in order.  The second timeout begins at its
   `dispatched` transition.  Killing transport at every boundary never causes
   either request to execute twice.
9. Source text and modified state are identical before and after every result
   and failure scenario.
10. Production source has no synchronous wait loop around helper/Jupyter I/O,
    no unbounded process filter, no direct `jupyter-*` call after migration,
    and no kernel launch in helper production code.

## Verification commands

Agents run the narrow selector from their row and the applicable suite below.
The manager runs every suite at integration gates.

```bash
export CODE_CELLS_DIR=/home/dcol/.config/emacs/.local/straight/repos/code-cells.el

# Existing and new source-based local ERT.  HT0 creates the canonical runner.
emacs -Q --batch -L . -L tests -L "$CODE_CELLS_DIR" \
  -l tests/run-local-tests.el -f ert-run-tests-batch-and-exit

# Pure helper tests.  These must not require a kernel or network.
PYTHONPATH=helper python3 -m unittest discover -s helper/tests -p 'test_*.py'

# Local-kernel integration, inside the pinned development environment.
nix develop -c env PYTHONPATH=helper python -m unittest discover \
  -s helper/integration_tests -p 'test_*.py'

# Package and static checks.
nix build .#ejn-helper
git diff --check
git status --short
```

Byte compilation remains required at integration gates.  Only the already
documented Evil free-variable warnings are acceptable.  Delete all generated
`.elc` files, then rerun the source ERT command before status/diff review.

Every possibly hanging test command is additionally wrapped by the test runner
with an external wall-clock deadline.  Production code does not call
`sleep-for`, synchronous `process-file`, or a polling `accept-process-output`
loop for helper operations.

## Dependency graph and safe parallelism

```text
IR1 -> IR2 -> IR3 -> IR3S -> IR4 -> IR5       current-code repair lane

HT0 -> HT1 -> HT2 -> HT3 -> HT4 -> HT6       protocol/Python lane
                   \-> HT5 ----/
HT6 -> HT7 -> HT8 -> HT9 -> HT10 -> HT11 -> HT12
HT12 -> HT12R1 -> HT12R2 -> HT12R3 -> HT13

HT1 -> ET1 -> ET2 -> ET3
HT1 -> TH1
HT2 -> TH2 -> TH3

IR5 + HT7 + ET3 -> EI1 -> EI1R -> EI2 -> EI3 -> EI4 -> EI4V -> EI4D -> EI5
EI5 -> EI6 -> EI7 -> EI8 -> EI9 -> EI10 -> EI11

HT13 + EI11 + TH3 -> AG1 -> AG2 -> AG3 -> AG4 -> AG5
```

Safe parallel batches:

- After `HT1`: `HT2`, `ET1`, and `TH1` touch disjoint files.
- After `HT2`: `HT3`, `HT5`, and `TH2` touch disjoint files.
- The IR lane may run beside Python-only HT work, but not beside EI work.
- Only one agent at a time works in the HT4/HT6-HT13 sequence.
- Only one agent at a time works in the ET lane or in the EI lane (including
  `EI1R` and `EI4V`).
- TH tasks may run beside implementation when their named dependencies landed.
- AG integration gates are sequential manager/critic tasks, not bulk coding
  assignments.

## Difficulty routing

Difficulty is based on the consequence of a subtle mistake, not estimated
line count.  The manager gives Luna tasks one row at a time and still reviews
their tests/diffs.  Terra receives tasks involving concurrency, process
lifecycle, durable-state rules, security boundaries, ambiguous execution, or
cross-module integration.

| Route | Tasks | Why |
|---|---|---|
| Luna - low | `HT0`, `HT1`, `TH1`, `EI11` | Runners, specifications, independent fixtures, and documentation/command resolution |
| Luna - medium | `HT2`, `HT3`, `HT10`, `ET1`, `TH2`, `EI10` | Bounded leaf implementations with exact contracts and isolated tests |
| Terra - high | `IR1`, `IR2`, `IR3`, `IR3S`, `IR4`, `IR5`, `HT4`, `HT5`, `HT6`, `HT7`, `HT8`, `HT9`, `HT11`, `HT12`, `HT12R1`, `HT12R2`, `HT12R3`, `HT13`, `ET2`, `ET3`, `TH3`, `EI1`, `EI1R`, `EI2`, `EI3`, `EI4`, `EI4V`, `EI4D`, `EI5`, `EI6`, `EI7`, `EI8`, `EI9`, `AG1`, `AG2`, `AG3`, `AG5` | Shared state, async ordering, backpressure, secrets/artifacts, kernel lifecycle, reconnect, or integration gates |
| Manager/manual | `AG4` | Requires real Doom/remote dogfood, observation over time, and an explicit human go/no-go decision |

This partition covers every ledger row exactly once.  A Luna row is promoted
to Terra if its prerequisite implementation changed the promised interface or
if its first attempt exposes an ordering, lifecycle, or security ambiguity.

## Task ledger

### Phase IR - close known UI-hang and reconnect holes

These defects exist independently of the helper.  They must land before EI
integration starts so helper work is not blamed for pre-existing behavior.
All IR rows are sequential because they share the monolithic ERT file and core
modules.

- [x] sha=b705a30 **IR1 Force full panel renders for structural mutations.**
  - Depends: none.
  - Files: `emacs-jupyter-notebook-result.el`,
    `emacs-jupyter-notebook.el`, `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: distinguish entry-content dirtiness from structural
    invalidation.  Toggle latest/history, clear all, cell reordering, and any
    mutation of the visible entry set must force the next flush through the
    full renderer even when dirty entry IDs exist.
  - Tests: `ejn-ir1-toggle-with-pending-dirty-forces-full-render`,
    `ejn-ir1-clear-with-pending-dirty-leaves-empty-panel`, and
    `ejn-ir1-reordered-cells-rebuild-visible-order`.  Each constructs pending
    dirty state before the structural operation and asserts rendered buffer
    text/regions, not only the model.
  - Narrow run: ERT selector `^ejn-ir1-` plus every existing panel test.
  - Non-goal: no image retention or helper work.

- [x] sha=9040b4d **IR2 Retire cleared artifacts and reject late output before materialization.**
  - Depends: IR1.
  - Files: `emacs-jupyter-notebook-result.el`,
    `emacs-jupyter-notebook-jupyter.el`, `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: clearing results retires all output files/cache objects before
    dropping entries.  Presentation callbacks check that their entry handle is
    live before decoding/writing/stashing; matching reply/status/stdin callbacks
    still settle protocol bookkeeping without reviving presentation.  Deferred
    viewer opens retain no payload, coalesce per entry, and are cancelled by
    every artifact-retirement path.  Published artifact cleanup also runs on
    normal Emacs exit without touching registry or remote state.
  - Tests: `ejn-ir2-clear-deletes-existing-artifacts`,
    `ejn-ir2-late-image-after-clear-creates-no-file`,
    `ejn-ir2-late-pickle-after-clear-retains-no-bytes`,
    `ejn-ir2-pickle-auto-open-coalesces-latest-update`,
    `ejn-ir2-pending-clear-retires-pickle-and-auto-open`, the clear-during-
    execution reply/status/stdin tests, and `ejn-ir2-exit-cleanup-is-local-only`.
  - Narrow run: ERT selector `^ejn-ir2-` plus W1 and W18 selectors.
  - Non-goal: do not make current base64 decoding asynchronous here.

- [x] sha=20e1e10 **IR3 Bound total panel history and artifact disk use.**
  - Depends: IR2.
  - Files: `emacs-jupyter-notebook-result.el`,
    `emacs-jupyter-notebook-vars.el`, `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: add non-nil positive defaults for maximum history entries,
    total retained text bytes, and total artifact bytes.  Evict oldest history
    entries until all three budgets hold, retire their files/cache, preserve
    latest-per-cell correctness, and show one stable eviction marker in history
    view.  "Newest images" is based on entry creation sequence, not source
    position.
  - Tests: `ejn-ir3-entry-budget-evicts-oldest`,
    `ejn-ir3-text-budget-is-global`, `ejn-ir3-artifact-budget-deletes-files`,
    `ejn-ir3-latest-cell-survives-history-eviction`, and
    `ejn-ir3-inline-images-use-creation-order`.
  - Narrow run: ERT selector `^ejn-ir3-` plus all panel/image tests.
  - Non-goal: do not silently exempt any MIME payload from a byte budget.

- [x] owner=terra-ir3s claimed=2026-08-30 landed=87469ce **IR3S Make streamed text accumulation amortized instead of quadratic.**
  - Depends: IR3.
  - Files: `emacs-jupyter-notebook-result.el`,
    `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: appending a stream chunk does not concatenate or rescan all
    text already retained by the entry.  Keep an explicit byte count and
    pending chunks; the incremental renderer consumes only new chunks, while a
    full render materializes retained text at most once.  Enforce the per-entry
    and global byte caps before retaining a chunk.  Entry snapshots expose the
    same logical text without preserving a compatibility representation.
  - Tests: 10000 one-byte appends produce correct ordered text and truncation;
    instrument the materialization helper and assert it is not called once per
    append; an incremental flush inserts only the newly appended suffix; full
    render and clear release chunks.  Do not use a fragile wall-clock threshold
    as the primary assertion.
  - Narrow run: ERT selector `^ejn-ir3s-` plus streaming/panel tests.
  - Non-goal: no helper protocol work.

- [x] owner=terra-ir4 claimed=2026-08-30 landed=7c049d3 **IR4 Remove synchronous management SSH from ordinary UI paths.**
  - Depends: IR3S.
  - Files: `emacs-jupyter-notebook-ssh.el`, `emacs-jupyter-notebook.el`,
    `emacs-jupyter-notebook-vars.el`, `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: reconnect picker liveness probes, fetch remote log, list
    remote processes, prune, and clean-orphan flows use sentinel-driven
    `make-process` operations with per-process deadlines.  Commands show a
    progress state and can be cancelled.  No user path calls the synchronous
    `emacs-jupyter-notebook-ssh-run-command`.
  - Tests: one test per command with a fake child that never exits; an
    independent timer must run, timeout/cancel must dispose process/buffers,
    and durable state must remain unchanged.  Add a stripped-source static test
    named `ejn-ir4-no-sync-ssh-in-interactive-call-graph`.
  - Narrow run: ERT selector `^ejn-ir4-` plus W4, W11, and W19 selectors.
  - Non-goal: remote smoke tests are not required.

- [x] owner=terra-ir5 claimed=2026-08-31 landed=0e40ca8 **IR5 Make automatic reconnect retry ownership and status truthful.**
  - Depends: IR4.
  - Files: `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: an evaluation-triggered or explicit reconnect may supersede a
    scheduled retry, but any transient failure schedules the next bounded retry
    exactly once.  Confirmed-dead is terminal; unreachable/timeout is not.
    Status shows phase, elapsed attempt age, retry count, next retry time, and a
    working cancel action that targets the live context.  Remove or route
    around obsolete status formatters.
  - Tests: table-driven transitions for scheduled -> explicit -> transient
    failure, evaluation -> transient failure, confirmed-dead, cancel, stale
    timer, and successful reset.  Render the actual interactive status buffer
    and invoke its advertised action.
  - Narrow run: ERT selector `^ejn-ir5-` plus W12, W15, and W19 selectors.
  - Non-goal: do not start or terminate a kernel automatically.

### Phase HT - protocol and Python helper

- [x] sha=614412d **HT0 Add canonical local test runners.**
  - Depends: none.
  - Files: `tests/run-local-tests.el`, `tests/run-local-tests.sh`, `.gitignore`.
  - Deliverable: one source-only ERT runner that discovers local unit test
    modules while explicitly excluding Doom and remote tests; it resolves
    `CODE_CELLS_DIR`, refuses stale project `.elc`, and applies an external
    wall-clock timeout.  Add a helper unittest wrapper that sets a temporary
    directory and cleans `__pycache__` through ignored artifacts, not commits.
  - Tests: run the wrapper from a clean checkout and prove a deliberately
    copied stale `.elc` causes a clear preflight failure.
  - Narrow run: `tests/run-local-tests.sh`.
  - Non-goal: no production code.

- [x] sha=a1a048c **HT1 Freeze protocol v1 documentation and golden vectors.**
  - Depends: HT0.
  - Files: `docs/helper-protocol-v1.md`,
    `tests/fixtures/helper-protocol-v1.json`,
    `tests/validate-helper-protocol-v1.py`.
  - Deliverable: copy the authoritative contract above into a standalone spec.
    Golden vectors include zero/one-byte prefix boundaries, Unicode, embedded
    newline/NUL escaping, maximum legal frames, one-byte-oversize prefixes,
    every envelope kind, every error code, and credit byte accounting including
    the four-byte prefix.  Store large-vector recipes/lengths, not a 256 KiB
    blob in git.
  - Tests: the standard-library-only validator proves fixture JSON validity,
    unique IDs/names, exact prefix hex, and declared encoded lengths.
  - Narrow run: `python3 tests/validate-helper-protocol-v1.py`.
  - Non-goal: no Elisp or helper implementation.

- [x] sha=4c45638 **HT2 Create the packaged helper skeleton and pinned dev environment.**
  - Depends: HT1.
  - Files: `helper/pyproject.toml`, `helper/ejn_helper/__init__.py`,
    `helper/ejn_helper/__main__.py`, `helper/tests/test_cli.py`, `flake.nix`,
    `flake.lock`.
  - Deliverable: `ejn-helper --version` and `python -m ejn_helper --version`
    work; stdout is empty unless protocol mode or `--version` was explicitly
    requested; missing `jupyter_client` produces one bounded stderr diagnostic
    and a nonzero exit.  Nix package contains helper, `jupyter_client`, pyzmq,
    and a test-only ipykernel in the dev shell.  Lock exact Nix inputs.
  - Tests: CLI unittest, `nix build .#ejn-helper`, and an execution from the
    built closure with an empty `PYTHONPATH`.
  - Narrow run: `PYTHONPATH=helper python3 -m unittest discover -s helper/tests -p 'test_cli.py'`
    and Nix build.
  - Non-goal: no protocol loop or kernel launch.

- [x] sha=959b739 **HT3 Implement the pure Python frame codec.**
  - Depends: HT2.
  - Files: `helper/ejn_helper/framing.py`,
    `helper/tests/test_framing.py`.
  - Deliverable: incremental decoder and encoder exactly implement HT1,
    including fragmented prefix/payload, multiple frames, UTF-8/JSON errors,
    hard directional sizes, accumulator bound, and partial-frame deadline state.
    Decoder accepts bytes only and never performs I/O.
  - Tests: consume every HT1 golden vector one byte at a time and in randomized
    deterministic chunk patterns; assert exact structured error code and no
    retained payload after failure.
  - Narrow run: `PYTHONPATH=helper python3 -m unittest discover -s helper/tests -p 'test_framing.py'`.
  - Non-goal: no asyncio or Jupyter import.

- [x] owner=terra-ht4 claimed=2026-08-30 landed=98123e6 **HT4 Implement credited event queue and stream coalescer.**
  - Depends: HT3.
  - Files: `helper/ejn_helper/flow.py`, `helper/tests/test_flow.py`.
  - Deliverable: byte-exact credits, zero-credit startup, bounded queue,
    32 KiB UTF-8-safe stream chunks, same-stream coalescing, reserved terminal
    lane, and exactly one truncation marker per affected request.  Invalid or
    overflowing credit grants are rejected rather than wrapping counters.
  - Tests: deterministic model tests for credit exhaustion/replenishment,
    multibyte boundaries, 100 MiB simulated stream input without retaining it,
    terminal delivery after overflow, and maximum observed queue bytes.
  - Narrow run: `PYTHONPATH=helper python3 -m unittest discover -s helper/tests -p 'test_flow.py'`.
  - Non-goal: no stdout writes and no sleeps.

- [x] sha=e7f3581 **HT5 Implement secure artifact spooling.**
  - Depends: HT2.
  - Files: `helper/ejn_helper/artifacts.py`,
    `helper/tests/test_artifacts.py`.
  - Deliverable: directory ownership/mode/path validation, conservative base64
    size preflight, incremental decode to a same-directory temporary file,
    actual-size verification, SHA-256, chmod 0600, atomic publish, and cleanup
    of failed partial files.  Published files survive artifact-store/helper
    close for Emacs ownership.
  - Tests: exact-limit and one-byte-over-limit data; malformed base64; symlink
    escape; relative/wrong-owner/world-writable directory rejection where the
    platform permits; injected write/fsync/rename failures; no partial files.
  - Narrow run: `PYTHONPATH=helper python3 -m unittest discover -s helper/tests -p 'test_artifacts.py'`.
  - Non-goal: no image library and no decoded bitmap allocation.

- [x] owner=terra-ht6 claimed=2026-08-30 landed=b53ab4c **HT6 Add protocol dispatcher using a fake Jupyter backend.**
  - Depends: HT4, HT5.
  - Files: `helper/ejn_helper/backend.py`,
    `helper/ejn_helper/dispatcher.py`, `helper/tests/fake_backend.py`,
    `helper/tests/test_dispatcher.py`.
  - Deliverable: typed internal backend protocol, hello negotiation, strict op
    validation, exactly-one responses, request table, deadlines, safe error
    normalization, event correlation, ping, code/inflight bounds, credit op,
    and local-only close.  Fake backend can resolve, delay, error, emit events,
    and ignore cancellation.
  - Tests: every op before hello, before connect, duplicate ID, unknown op,
    wrong field type, deadline, late result, callback exception, duplicate
    completion, and close.  Assert no traceback or arbitrary repr in frames.
  - Narrow run: `PYTHONPATH=helper python3 -m unittest discover -s helper/tests -p 'test_dispatcher.py'`.
  - Non-goal: no `jupyter_client` import in the fake test path.

- [x] owner=terra-ht7 claimed=2026-08-31 landed=e6bcbb1 **HT7 Attach `AsyncKernelClient` without owning kernel lifecycle.**
  - Depends: HT6, TH2.
  - Files: `helper/ejn_helper/jupyter_backend.py`,
    `helper/integration_tests/test_connect.py`.
  - Deliverable: validate/read a local connection file, require rewritten hosts
    to be loopback, instantiate `AsyncKernelClient`, start/stop channels, and
    implement bounded `kernel_info`.  No `KernelManager`, subprocess launch,
    blocking client, or indefinite await in production.  `close` stops channels
    and leaves kernel alive.
  - Tests: attach to TH2's test-owned kernel, kernel-info success, invalid key,
    non-loopback rejection, unused/black-hole port deadline, repeated
    connect/close with stable thread/fd/task counts, and evaluate directly after
    helper close to prove kernel survival.
  - Narrow run: local integration selector `test_connect.py` under 45 seconds.

- [x] owner=terra-ht8 claimed=2026-08-31 landed=06287a8 **HT8 Correlate all Jupyter channels and execution terminal ordering.**
  - Depends: HT7.
  - Files: `helper/ejn_helper/jupyter_backend.py`,
    `helper/ejn_helper/requests.py`,
    `helper/tests/test_requests.py`,
    `helper/integration_tests/test_execution_order.py`.
  - Deliverable: map EJN request ID <-> Jupyter `msg_id`; route shell, control,
    stdin, IOPub, and heartbeat independently; ignore unrelated parents; accept
    idle-before-reply or reply-before-idle; emit one monotonic terminal state;
    cancel/close all reader tasks deterministically.
  - Tests: fake reordered/duplicate/unrelated messages plus local-kernel normal,
    error, and no-output executions.  Assert zero pending asyncio tasks after
    close.
  - Narrow run: `test_requests.py` and `test_execution_order.py`.
  - Non-goal: no output MIME rendering.

- [x] owner=terra-ht9 claimed=2026-08-31 landed=ba25ee8 **HT9 Normalize bounded stream, error, result, display, and artifact events.**
  - Depends: HT8, HT5.
  - Files: `helper/ejn_helper/outputs.py`,
    `helper/ejn_helper/jupyter_backend.py`,
    `helper/tests/test_outputs.py`,
    `helper/integration_tests/test_outputs.py`.
  - Deliverable: enforce per-execution text/output limits before framing;
    normalize ANSI-preserving stream/error text; handle `clear_output(wait)`,
    `display_data`, `update_display_data`, execution results, PNG/JPEG, and EJN
    matplotlib pickle.  Large/unsupported MIME gets a small explicit marker.
    Image/pickle base64 is removed before any event object reaches framing.
    Artifact decode/hash/write runs through the single bounded worker so local
    `ping` remains responsive during injected slow I/O.
  - Tests: fixture messages for every MIME/event, 100 MiB logical stream,
    malformed/oversize base64, update-display identity, clear ordering, and a
    canary that recursively scans every emitted object/stdout frame for the
    input base64 substring.
  - Narrow run: output unit/integration modules; no test frame over 262144.

- [x] owner=luna-ht10 claimed=2026-08-31 landed=4859717 **HT10 Implement bounded auxiliary requests.**
  - Depends: HT9.
  - Files: `helper/ejn_helper/jupyter_backend.py`,
    `helper/tests/test_aux_requests.py`,
    `helper/integration_tests/test_aux_requests.py`.
  - Deliverable: complete, inspect, is-complete, and kernel-info each have their
    own ID/deadline, bounded response schema, late-reply discard, and maximum
    candidate/documentation sizes.  They never modify execution queue state.
  - Tests: success, timeout then late reply, malformed reply, enormous
    completion list/docstring truncation, concurrent aux requests, and request
    during a long execution.  All finish or time out without blocking another
    operation.
  - Narrow run: aux unit/integration modules.

- [x] owner=terra-ht11 claimed=2026-08-31 landed=da4e134 **HT11 Implement stdin request/reply safely.**
  - Depends: HT10.
  - Files: `helper/ejn_helper/jupyter_backend.py`,
    `helper/ejn_helper/dispatcher.py`, `docs/helper-protocol-v1.md`,
    `tests/fixtures/helper-protocol-v1.json`,
    `tests/validate-helper-protocol-v1.py`, `helper/tests/test_dispatcher.py`,
    `helper/tests/test_stdin.py`, `helper/integration_tests/test_stdin.py`.
  - Deliverable: correlate input request to execution, expose prompt/password
    boolean with bounded prompt text and a fresh opaque per-prompt `input_id`.
    An input reply must name both its execution request and exact `input_id`;
    the dispatcher atomically claims that lease before the backend sends one
    reply, so an old duplicate cannot answer a later prompt in the same
    execution.  Clear password values after send where Python permits, and
    handle cancel/timeout/helper close.  Password values never enter logs,
    events, success results, or error payloads.
  - Tests: ordinary input, password-shaped input with log capture, duplicate and
    stale reply, execution cancel while prompting, and helper close.
  - Narrow run: stdin unit/integration modules.

- [!] owner=terra-ht12 claimed=2026-08-31 evidence=7fc3aac **HT12 Prove and implement interrupt/restart/shutdown semantics.**
  - Depends: HT11, TH2.
  - Files: `helper/integration_tests/test_lifecycle_probe.py`, then
    `helper/ejn_helper/jupyter_backend.py`,
    `helper/tests/test_lifecycle.py`.
  - Deliverable part A: an executable probe launches a test-owned kernel via
    the same `jupyter kernel --KernelManager.connection_file=...` parent shape
    used by EJN and records PID/connection behavior for protocol interrupt,
    `shutdown_request(restart=true)`, and `restart=false`.  The probe must fail
    before any guessed production implementation is added if the parent does
    not provide the required behavior.
  - Deliverable part B: implement only behavior proven by part A.  Interrupt is
    bounded and leaves channels usable.  Restart waits for old liveness to go
    away and new kernel-info to succeed, then reports completion.  Shutdown is
    callable only through the explicit op and verifies terminal liveness.
  - Tests: interrupt a long sleep then execute; restart and prove namespace
    reset while manager/session identity is handled correctly; close versus
    shutdown distinction; all control replies reordered/late.  Test-owned
    cleanup is unconditional.
  - Narrow run: lifecycle probe/test under an external 90-second timeout.
  - Stop condition: if protocol-only restart/shutdown cannot control the
    production launch shape, mark `[!]` with probe output.  Do not add local PID
    signals or let the helper issue SSH.

  **Stop evidence:** the pinned executable probe proves message-mode interrupt
  works and preserves the same usable kernel, but both
  `shutdown_request(restart=true)` and `restart=false` terminate only the kernel
  child.  The `jupyter kernel` launcher remains alive; the connection file is
  unchanged; no replacement kernel becomes ready.  Base `KernelManager` has no
  active restarter in this launch shape.  No lifecycle production code was
  added.

- [x] owner=terra-ht12r1 claimed=2026-08-31 landed=dd7bc63 **HT12R1 Prove a direct kernelspec launch and relaunch contract.**
  - Depends: HT12 stop evidence, TH2.
  - Files: `helper/integration_tests/direct_kernel_fixture.py`,
    `helper/integration_tests/test_direct_kernel_lifecycle.py`.
  - Deliverable: resolve one kernelspec as structured JSON, strictly validate
    its argv/environment/placeholders, substitute an explicit test-owned
    connection file, and launch that argv directly without `KernelManager` or a
    launcher parent.  The tracked PID must be the actual kernel on both supported
    platforms.  Prove message interrupt, protocol shutdown, and a fresh direct
    relaunch on the same connection file/ports with a reset namespace.
  - Tests: malformed/oversized spec rejection; quoting and placeholder cases;
    exact PID/process exit; interrupt then execute; graceful shutdown; relaunch
    keeps connection metadata/ports, changes PID where observable, clears the
    namespace, and accepts a new execute.  Cleanup owns only the test process
    group and is unconditional.
  - Narrow run: direct-kernel fixture/probe under an external 90-second timeout.
  - Stop condition: if the same connection file/ports cannot be reused safely,
    mark `[!]` with observations before changing production launch code.

  **Proof result:** the validated kernelspec argv is the tracked process itself;
  message interrupt preserves it and protocol shutdown exits it cleanly.  A
  kernel-created connection file is removed during shutdown.  Restoring the
  saved connection JSON privately at the same path before a fresh direct launch
  reuses all five ports, yields a new PID and reset namespace, and accepts new
  execution.  The proof is portable POSIX code with no `/proc` dependency.

- [x] owner=terra-ht12r2 claimed=2026-08-31 landed=1d3f791 **HT12R2 Launch the actual remote kernel PID asynchronously.**
  - Depends: HT12R1.
  - Files: `emacs-jupyter-notebook-vars.el`,
    `emacs-jupyter-notebook-ssh.el`, `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-tests.el`,
    `tests/emacs-jupyter-notebook-remote-tests.el`, `README.md`.
  - Deliverable: replace raw shell-string `:jupyter-command` with a non-empty
    structured `:python-command` argv (default `("python3")`; no compatibility
    path).  Add a bounded asynchronous resolution phase that appends a constant
    Python resolver and the selected kernelspec as separate quoted argv.  The
    resolver may run behind explicit prefixes such as `uv run ... python`, but
    it emits only one bounded standard kernelspec JSON entry: available `$NAME`
    environment references are expanded with standard `Template.safe_substitute`
    semantics (unavailable names remain literal), bare Python is
    `sys.executable`, every other executable is resolved to an absolute path,
    resource paths are absolute, and only `{connection_file}` / `{resource_dir}`
    are substituted.
    The remote shell expands a home-relative connection path before passing it
    as a separate resolver argument.  Emacs strictly reparses the resulting
    final schema and rejects every relative executable, leftover/unknown
    placeholder, missing or duplicate connection-path occurrence, malformed
    field, or bound violation.
  - Deliverable: build a shell-quoted direct argv/environment launch in which
    the resolution prefix is absent.  The detached PID recorded in the registry
    is the kernel itself.  Persist only non-secret restart/identity data
    (`:launch-kind`, remote ports, and exact connection-file argv tokens), never
    the resolved kernelspec environment.  The launch wrapper atomically writes
    its own stable pre-`exec` PID to a private deterministic sidecar, then
    `exec`s the resolved kernel so that PID becomes the kernel; ambiguous starts
    recover the PID asynchronously from that sidecar.  PID identity checks
    recognize the exact token sequence used by the resolved argv.  Existing
    launcher-shaped registry entries are rejected clearly and left untouched
    rather than adapted.  Once launch is admitted, create a provisional durable
    entry before starting the SSH launch process.  No generic failure,
    cancellation, timeout, buffer cleanup, or supersede path removes it, even
    when local process creation fails; confirmed-dead removal stays behind the
    explicit prune/cleanup commands.  The provisional entry retains deterministic
    session, connection, and sidecar paths for reconnect or explicit cleanup.
    Cancellation/failure never kills or broadly matches a remote process; stale
    callbacks cannot promote a provisional entry to ready.
  - Tests: kernelspec success/missing/malformed/oversized/hostile values;
    placeholder and environment substitution; structured Python prefixes and
    legacy-string rejection; exact shell argv quoting; hard-bounded resolver
    stdout/stderr; phase deadline/cancel/supersede; Linux token and Darwin
    best-effort PID match/mismatch/unverified; private PID-sidecar write/read,
    malformed/stale identity, and ambiguous-start recovery; pre-admission
    resolution failure leaves the registry untouched; every post-admission
    failure retains a provisional recoverable entry; registry contains no
    kernelspec environment values.  No synchronous SSH or wait loop is permitted.
  - Narrow run: focused SSH/async start/reconnect ERT selectors plus source
    no-blocking assertions.

- [x] owner=terra-ht12r3 claimed=2026-08-31 landed=d55a894 **HT12R3 Implement proven helper interrupt and shutdown semantics.**
  - Depends: HT12R2.
  - Files: `helper/integration_tests/kernel_fixture.py`,
    `helper/ejn_helper/backend.py`, `helper/ejn_helper/dispatcher.py`,
    `helper/ejn_helper/jupyter_backend.py`, `helper/tests/test_lifecycle.py`,
    `helper/integration_tests/test_lifecycle.py`, `docs/helper-protocol-v1.md`,
    `tests/fixtures/helper-protocol-v1.json`,
    `tests/validate-helper-protocol-v1.py`.  Manager-approved dependent-test
    updates also cover `helper/tests/test_dispatcher.py`,
    `tests/emacs-jupyter-notebook-helper-protocol-tests.el`, and
    `helper/integration_tests/{test_connect.py,test_kernel_fixture.py,
    test_lifecycle_probe.py}`.
  - Deliverable: make the reusable fixture use the proven direct launch.  Add
    one correlated bounded message-mode interrupt and explicit shutdown that
    waits for both its control reply and terminal kernel liveness, retires all
    local channel/request state, and never affects a kernel on close.  Remove
    the impossible helper `restart` operation from protocol v1; there is no
    compatibility alias.  The user-facing restart remains an EJN orchestration
    implemented by EI6.
  - Tests: reordered/duplicate/late control replies; interrupt a long execution
    then execute again; shutdown during idle/busy/stdin; timeout/cancel;
    transport failure at send/reply/liveness boundaries; close leaves the direct
    kernel alive; shutdown exits it with zero readers/tasks/pending requests.
  - Narrow run: lifecycle unit/integration plus full helper tests and protocol
    validator under external deadlines.

- [x] owner=terra-ht13 claimed=2026-08-31 landed=beec019 **HT13 Complete helper main loop, signals, and fault containment.**
  - Depends: HT12R3.
  - Files: `helper/ejn_helper/__main__.py`,
    `helper/ejn_helper/runtime.py`, `helper/tests/test_runtime.py`.  The existing
    CLI contract test `helper/tests/test_cli.py` is an approved dependent-test
    update because protocol mode now remains alive instead of returning from a
    stub.  Manager-approved lifecycle scope also includes
    `helper/ejn_helper/dispatcher.py` and `helper/tests/test_dispatcher.py` for
    an idempotent local-only disposer used by EOF and signals, plus
    `helper/ejn_helper/flow.py` and `helper/tests/test_flow.py` so that disposer
    releases all queued event payloads and credit without wire output.  To preserve
    EI2's busy-kernel recovery boundary, scope also includes
    `helper/ejn_helper/jupyter_backend.py` and
    `helper/integration_tests/test_connect.py`: `connect` acknowledges bounded
    channel attachment without waiting for kernel readiness, while the
    separate bounded `kernel_info` operation owns readiness verification.
  - Deliverable: asyncio stdin/stdout loop, binary framing, partial-frame timer,
    bounded stderr logging, SIGTERM/EOF cleanup, no orphan tasks, response
    priority over credited events, immediate local ping response, and
    deterministic exit codes.  Unexpected backend errors fail affected
    requests or transport but do not print protocol garbage.
  - Tests: subprocess golden transcript; fragmented input; EOF at every byte;
    silent peer; oversized/garbage input; stdout backpressure; SIGTERM during
    connect/request/artifact write; injected backend crash; no temp partials or
    child processes.  Wrap each scenario in a parent timeout.
  - Narrow run: runtime unittest plus all pure helper tests.

### Phase ET - pure Elisp transport

- [x] owner=luna-et1 claimed=2026-08-30 landed=f6bbe94 **ET1 Implement pure unibyte frame codec.**
  - Depends: HT1.
  - Files: `emacs-jupyter-notebook-helper-protocol.el`,
    `tests/emacs-jupyter-notebook-helper-protocol-tests.el`.
  - Deliverable: encoder/incremental decoder implements HT1 with
    `json-parse-string`/`json-serialize`, hard size/UTF-8/schema errors, and no
    process/timer dependency.  It returns decoded envelopes plus unconsumed
    bytes and never scans/copies beyond the accumulator bound.
  - Tests: consume all golden vectors at every split point and multiple-frame
    groupings; exact errors for overflow, malformed prefix/payload, invalid
    UTF-8/JSON; source objects are not mutated.
  - Narrow run: ERT selector `^ejn-et1-`.

- [x] owner=terra-et2 claimed=2026-08-31 landed=e24c08a **ET2 Supervise helper process and handshake without blocking Emacs.**
  - Depends: ET1, TH1.
  - Files: `emacs-jupyter-notebook-helper.el`,
    `emacs-jupyter-notebook-vars.el`,
    `tests/emacs-jupyter-notebook-helper-process-tests.el`.
  - Deliverable: resolve configured helper argv beside source/build symlinks,
    `make-process` with binary pipes and separate stderr buffer, hello deadline,
    sentinel identity guard, partial-frame deadline, local disposer, bounded
    logs, and callbacks.  No production wait loop.  A stale sentinel cannot
    mutate a replacement session.
  - Tests: TH1 scenarios for hello success/version mismatch/silence/garbage/
    partial/oversize/early exit; supersede A with B then fire A sentinel; kill
    buffer/mode/Emacs; assert zero leaked processes, buffers, timers, and no
    durable-state calls.
  - Narrow run: ERT selector `^ejn-et2-`.

- [x] owner=terra-et3 claimed=2026-08-31 landed=d1e7d94 **ET3 Add bounded event drain, credit replenishment, requests, and deadlines.**
  - Depends: ET2.
  - Files: `emacs-jupyter-notebook-helper.el`,
    `tests/emacs-jupyter-notebook-helper-process-tests.el`.
  - Deliverable: process filter only accumulates/decodes its per-invocation
    budget; scheduled drain dispatches events and replenishes credit afterward;
    request table guarantees exactly one callback; per-op timers correlate IDs;
    late responses are ignored/logged.  A correlated periodic ping detects a
    live process with a stuck event loop and disposes it on deadline.
    Decoded-event queue and accumulator are bounded even for a malicious helper.
  - Tests: legal frame flood while an independent timer runs, callback throws,
    timeout then late response, duplicate response, credit accounting, response
    while credit zero, queue overflow, process death with pending requests.
  - Narrow run: ERT selector `^ejn-et3-`, including 30-second external limit.

### Phase TH - reusable local fault harnesses

- [x] sha=b06daea **TH1 Build a deterministic fake helper executable for ERT.**
  - Depends: HT1.
  - Files: `tests/fixtures/ejn_fake_helper.py`,
    `tests/fixtures/README.md`.
  - Deliverable: command-line scenarios `normal`, `silent`, `garbage`,
    `fragmented`, `oversize`, `mid-frame-stop`, `flood`, `late-response`, and
    `exit-after-op`.  It implements framing independently using only Python
    stdlib, records requests to a supplied temp file, and never imports EJN
    helper code (avoids shared-bug tests).
  - Tests: standalone self-test invokes every scenario with a parent deadline
    and validates deterministic bytes/exit.
  - Narrow run: command documented in fixture README.

- [x] owner=luna-th2 claimed=2026-08-30 landed=bc59530 **TH2 Build a test-owned local kernel fixture matching production launch.**
  - Depends: HT2.
  - Files: `helper/integration_tests/kernel_fixture.py`,
    `helper/integration_tests/test_kernel_fixture.py`.
  - Deliverable: launch `jupyter kernel` with explicit temporary connection
    path/cache/cwd, capture manager and kernel PIDs when possible, wait with
    deadline, expose connection metadata, and always terminate only its own
    test process tree.  It refuses non-loopback connections and session IDs not
    created by the fixture.
  - Tests: start/evaluate/cleanup, startup failure, timeout, repeated cycles,
    and proof no matching process/connection/temp files remain.
  - Narrow run: fixture integration test under 60 seconds.

- [x] owner=terra-th3 claimed=2026-08-31 landed=4fbb460 **TH3 Build five-channel stoppable TCP relay fault harness.**
  - Depends: TH2.
  - Files: `helper/integration_tests/tcp_relays.py`,
    `helper/integration_tests/test_tcp_relays.py`.
  - Deliverable: allocate five loopback relay ports, rewrite a copied
    connection file, proxy raw TCP bidirectionally to the fixture kernel, stop
    all relays without killing kernel, and restart on the same ports.  Apply
    connection/task/buffer bounds and deterministic cleanup.
  - Tests: byte echo unit, helper evaluation through relays, stop during idle
    and active traffic, restart same ports, direct fixture connection proves
    unchanged kernel PID/state.
  - Narrow run: relay integration test under 90 seconds.

### Phase EI - integrate helper backend into EJN

Only one EI row is active at a time.  These rows may touch core state and must
be manager-reviewed for durable-kernel rules.

- [x] owner=terra-ei1 claimed=2026-08-31 landed=c09e52e **EI1 Introduce the narrow async backend contract and temporary selector.**
  - Depends: IR5, HT7, ET3.
  - Files: `emacs-jupyter-notebook-backend.el`,
    `emacs-jupyter-notebook-jupyter.el`, `emacs-jupyter-notebook-vars.el`,
    `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-backend-tests.el`.
  - Deliverable: define session/connect/close/execute/aux/control/input async
    operations and event sink.  Every operation has request ID and callbacks;
    none promises synchronous completion.  Wrap the old adapter only as needed
    for temporary rollout and add selector defaulting to old backend for this
    row.  Core stops assuming the client is an emacs-jupyter EIEIO object.
  - Tests: fake backend contract, callbacks after buffer kill/supersede,
    close-local never calls shutdown, static test forbids new direct
    `jupyter-*` calls outside the legacy adapter.
  - Narrow run: ERT selector `^ejn-ei1-` plus existing adapter tests.

- [x] owner=terra-ei1r claimed=2026-08-31 landed=2d9a3fb **EI1R Extract one backend-neutral normalized event reducer.**
  - Depends: EI1.
  - Files: `emacs-jupyter-notebook-events.el`,
    `emacs-jupyter-notebook-jupyter.el`,
    `emacs-jupyter-notebook-result.el`,
    `tests/emacs-jupyter-notebook-backend-tests.el`.
  - Deliverable: a pure normalized-event reducer owns panel/fringe/kernel-state
    behavior for stream, clear, result, display, display update, error,
    execute-reply, status, input request, and truncation.  The legacy adapter
    translates emacs-jupyter messages into this schema.  It no longer contains
    a second independently evolving panel/state implementation.  Prompting and
    replies are scheduled outside the reducer/process callback.
  - Tests: a table feeds every normalized event directly, then feeds the
    equivalent legacy message translation and asserts identical panel, fringe,
    request, and kernel state.  Include malformed/late/retired events and an
    injected reducer error that is logged rather than silently swallowed.
  - Narrow run: ERT selector `^ejn-ei1r-` plus all existing adapter/panel tests.
  - Non-goal: no helper process connection in this row.

- [x] owner=terra-ei2 claimed=2026-08-31 landed=6d0a73f **EI2 Connect/finalize through the helper backend.**
  - Depends: EI1R, HT13.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook-backend.el`,
    `emacs-jupyter-notebook.el`,
    `helper/ejn_helper/jupyter_backend.py`, `helper/ejn_helper/runtime.py`,
    `helper/tests/test_dispatcher.py`, `helper/tests/test_lifecycle.py`,
    `helper/tests/test_runtime.py`,
    `tests/emacs-jupyter-notebook-backend-tests.el`, and
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: register a `helper` EI1 backend which owns one helper session
    and a mode-0700 per-session artifact directory.  The core starts and
    handshakes the helper, sends `connect` with the rewritten loopback
    connection file, marks the EI1 session attached only after that response,
    then sends a separately bounded `kernel_info` verification before normal
    finalization.  Helper callbacks are deferred out of the initiating stack
    even when a test double replies synchronously.  Attempt and backend-session
    identity gate every callback, timer, PID-probe result, and late reply.
  - Busy-kernel boundary: strict finite deadlines satisfy core arbitration
    (at most 45s) < Python backend (150s) < dispatcher (160s) < Emacs helper
    request (180s).  On reconnect, a timed-out core verify
    retains the attached helper while the bounded remote-PID probe runs: alive
    or identity-unverified finalizes as connected/busy; mismatch, confirmed
    dead, and unreachable remain distinct failures.  A fresh start still
    hard-fails verification timeout.  A late correlated `kernel_info` reply may
    move the same installed session from busy to idle before the finite helper
    deadline; it cannot revive a failed or superseded attempt.  Expiry after a
    PID-proven busy adoption retires only the obsolete readiness request and
    preserves that installed local session.
  - Cleanup/durability: every fatal/pre-adoption failure and supersede retires helper requests,
    sends local `close`/disposes the helper, tears down tunnel and timers, and
    removes only that attempt's temporary artifact directory.  It never sends
    helper `shutdown`, never terminates the remote kernel, and never deletes or
    rewrites the admitted registry entry, its durable local connection file, or
    the remote connection file.  Successful finalization preserves the existing
    registry-save-before-client-install ordering.  Formatter/watchdog setup is
    best-effort after finalization through backend-neutral silent execute.
    Process/protocol transport death is a distinct exact-once session signal;
    after adoption it marks core transport dead and schedules the existing
    bounded reconnect loop even when the connect request is already terminal.
    The legacy auxiliary heartbeat is not armed for helper sessions before EI5;
    helper/tunnel lifecycle signals provide the EI2 failure surface without
    manufacturing misses from an operation the adapter does not yet support.
  - Tests: exact successful phase/order and save/install ordering; synchronous
    fake callbacks; helper start/hello/connect/verify error and timeout at every
    boundary; connect attached but verify pending; fresh timeout; every busy PID
    classifier and late-verify permutation; A superseded by B; buffer kill and
    mode disable; registry-save failure; helper/tunnel death; callback after
    cleanup; exact-once local close; zero helper/timer/process/buffer/artifact
    leaks; no shutdown or durable deletion; raw helper events are not fed to the
    reducer before EI4; source text and modified state unchanged; static checks
    reject legacy adapter calls and synchronous waits on the helper path.
  - Narrow run: ERT selector `^ejn-ei2-` plus W13/W15/W19 selectors.

- [x] sha=ebd6351 **EI3 Replace singleton evaluation state with serialized request ledger.**
  - Depends: EI2.
  - Files: `emacs-jupyter-notebook.el`,
    `emacs-jupyter-notebook-result.el`,
    `emacs-jupyter-notebook-events.el`,
    `emacs-jupyter-notebook-jupyter.el`,
    `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook-vars.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`,
    `tests/emacs-jupyter-notebook-backend-tests.el`, and the existing W5/W13
    evaluation tests in `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: buffer-local hash ledger plus FIFO queue and one active user
    execution.  Reserve ledger/FIFO order before asynchronous completeness
    checks so replies cannot reorder user intent.  Enqueue creates
    panel/fringe queued state but sends only when no active execution.  Timeout
    arms on `dispatched`; a correlated `execute_reply` plus correlated
    `status=idle`, in either order, makes the request terminal and advances the
    queue exactly once.  Cancel queued removes without interrupt; cancel active
    sends one interrupt and cannot overlap the next request while the outcome
    remains unknown.  All callbacks and helper/legacy events correlate the
    ledger record, backend request ID, and panel-entry generation.  Install a
    real backend event sink and map helper request IDs to ledger IDs with a
    bounded per-session table.  Silent formatter/watchdog setup uses the same
    serial queue and reaches a terminal decision before user dispatch.  Code
    over the shared `EJN_MAX_CODE_BYTES` value is rejected before panel entry or
    JSON serialization and never creates a misleading running entry.  Remove
    the old singleton variables and tests rather than adding compatibility
    aliases.
  - Tests: A/B invocation order even with reversed completeness replies; B has
    no timer before dispatch; reply/idle terminal ordering in both directions;
    duplicate terminal events advance once; active and queued cancellation;
    same-cell and different-cell reruns; late A events; clear-results while A
    runs; synchronous backend callbacks; helper-to-ledger ID translation;
    setup gating; oversize rejection before panel/backend; buffer kill; source
    edits preserving captured code/cell keys; no source mutation; and rewrites
    of the old W5/W13 singleton tests to assert the ledger contract directly.
  - Narrow run: ERT selector `^ejn-ei3-` plus W5/W13 evaluation tests.

- [x] owner=terra-ei4 claimed=2026-08-31 landed=9765cc5 **EI4 Route normalized text/display/artifact events to the panel.**
  - Depends: EI3, HT9.
  - Files: `emacs-jupyter-notebook-helper.el`,
    `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook.el`, `emacs-jupyter-notebook-events.el`,
    `emacs-jupyter-notebook-result.el`,
    `tests/emacs-jupyter-notebook-helper-process-tests.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`, and the panel/event
    tests in `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: translate helper stream/error/result/clear/display/update/
    truncation envelopes into EI1R's reducer without re-decoding images.  Drain
    ordinary output, terminal events, and responses in monotonic wire-sequence
    order: a priority terminal/response may bypass credit pressure but may not
    overtake an already-received ordinary event for the same execution.
    Normalize and synchronously dispatch admitted panel events within the
    bounded drain before replenishing credit; do not allocate one timer per
    event.  Remove EI3's synthetic reply/idle bridge and retain helper request
    correlation until real `execute_reply` plus `status=idle` retire it.
    `display_data` and `update_display_data` must preserve bounded display-id
    identity and replacement semantics.

    Add a panel API accepting an already-published confined image file plus
    MIME/hash/size.  The accepted path must be an immediate child of the pinned
    publication root, a regular non-symlink owned by the current uid with exact
    mode 0600, the declared bounded size and SHA-256, and a captured device/
    inode identity.  Accepted publication transfers file lifetime to the panel;
    helper/session cleanup removes staging state but not panel-owned files.
    Entry retirement flushes the Emacs image cache and unlinks exactly once only
    while path identity is unchanged; a replaced path or symlink survives.
  - Tests: every normalized event and malformed envelope before reducer
    mutation; helper/ledger/generation correlation; stream then terminal then
    response ordering (including zero credit); callback completion before
    credit replenishment; real reply/idle terminality without synthesis;
    artifact escape/symlink/mode/owner/hash/size/replacement; clear wait/update
    and display-id replacement; retired/late event; repeated deletion;
    unsupported/truncated marker; image-cache flush; fixed panel markers; no
    base64 in Emacs state; and 100 artifacts respecting IR3 count/byte budgets.
  - Narrow run: ERT selector `^ejn-ei4-` plus all panel tests.
  - Landed verification: 18 focused EI4 ERTs, 53 combined EI3/EI4 ERTs,
    and all 658 source-based ERTs pass.  Byte compilation passes with only the
    two pre-existing optional Evil symbol warnings.  Publication admission is
    capped at 4 MiB for inline images, canonicalizes Darwin's `/var` alias,
    securely discards rejected files, and tombstones retired wire IDs.

- [x] sha=adf3816 **EI4V Move matplotlib viewer payloads to confined pickle files.**
  - Depends: EI4.
  - Files: `helper/ejn_helper/outputs.py`, `helper/tests/test_outputs.py`,
    `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook-result.el`,
    `emacs-jupyter-notebook-viewer.el`, `emacs-jupyter-notebook-events.el`,
    `emacs-jupyter-notebook-vars.el`, `emacs-jupyter-notebook.el`,
    `viewer/ejn_viewer.py`, `viewer/test_viewer_gui.py`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`, and the existing
    W8 viewer/panel tests in `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: panel entries retain pickle artifact metadata/path, never
    base64.  A rich helper event may carry at most one image descriptor plus
    one pickle descriptor so the interactive payload never suppresses its PNG
    thumbnail; all publications in a rejected event are discarded through
    their pinned leases.  The local viewer uses a private mode-0700 socket
    directory and bounded structured requests, accepts only an immediate child
    of the supplied artifact root, and validates the root and file through
    pinned descriptors/identities before use.  Pickle load/figure
    reconstruction moves off the viewer GUI event tick into one bounded
    worker.  Panel pickle count/byte eviction deletes retired files, and a
    pending/open viewer receives an explicit bounded lease/ack lifetime rather
    than racing panel deletion; the viewer never unlinks a panel-owned path.

    Python pickle is an arbitrary-code boundary, not made trustworthy by file
    ownership or hashing.  Interactive pickle loading therefore has a dedicated
    defcustom defaulting to disabled; `v` and auto-open refuse it until the user
    explicitly opts in.  Do not add a nominal "restricted unpickler" for
    Matplotlib's unrestricted object graph.  Static PNG/JPEG display and the
    external image opener remain available while pickle loading is disabled.
  - Tests: pickle opt-in disabled by default for manual and auto-open paths;
    one helper event preserves both PNG and pickle descriptors; base64 canary
    absent from panel, Elisp process payload, and viewer logs; path traversal,
    nested name, symlink, hardlink, root/file identity, mode, owner, hash, and
    size rejection; malformed/oversized socket input; retirement while a
    viewer request is queued/in flight plus timeout/death/duplicate-ack races;
    exact pickle count/byte boundaries; a blocked loader proves the socket/GUI
    pump remains responsive; and valid figure round trip using a test-owned
    local file.  No GUI is required for security/protocol tests.
  - Narrow run: ERT selector `^ejn-ei4v-` and viewer Python tests.
  - Landed verification: 667 source-based ERTs, 164 helper Python tests,
    and 8 real-socket viewer protocol tests pass.  Byte compilation passes
    with only the two pre-existing optional Evil symbol warnings.  The final
    audit also exercised real Emacs-to-Python device/inode ordering, bounded
    viewer death/timeout lease settlement, malformed non-object JSON, exact
    pickle byte/count eviction, and payload canaries across panel/wire/log
    surfaces.  GUI coverage skips cleanly when matplotlib is unavailable.

- [x] owner=terra-ei4d claimed=2026-09-01 landed=2bd65c7 **EI4D Reject compressed-image decoder bombs before Emacs image APIs.**
  - Depends: EI4V.
  - Files: `helper/ejn_helper/image_metadata.py`,
    `helper/ejn_helper/thumbnail.py`,
    `helper/ejn_helper/thumbnail_worker.py`,
    `helper/ejn_helper/artifact_verify.py`,
    `helper/ejn_helper/artifacts.py`, `helper/ejn_helper/outputs.py`,
    `helper/tests/test_image_metadata.py`,
    `helper/tests/test_image_sanitizer.py`,
    `helper/tests/test_thumbnail_worker.py`,
    `helper/tests/test_artifact_verify.py`, `helper/tests/test_artifacts.py`,
    `helper/tests/test_outputs.py`, `helper/pyproject.toml`, `flake.nix`,
    `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook-result.el`, `emacs-jupyter-notebook-vars.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`, and the panel image
    tests in `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: compressed remote image bytes are external-viewer-only and
    never reach an Emacs native image API.  A cheap bounded PNG/JPEG header
    parser rejects obvious MIME, dimension, and pixel-area violations before
    decode, but it never makes an original inline-safe.  The helper's sole
    artifact executor invokes one fixed local thumbnail worker with no shell,
    inherited pinned input/output file descriptors, a monotonic wall deadline,
    bounded or discarded stdout/stderr, a new process session, process-group
    termination on timeout, and CPU/file-size/open-file/core/address-space
    resource limits where the target supports them.  The child applies its
    limits before importing Pillow, fully decodes at most 4,194,304 source
    pixels, converts to RGB, downsizes to at most 1024 by 1024, and writes a
    canonical uncompressed P6 PPM preview no larger than 4 MiB.  Failure to
    establish required limits, import or decode safely, meet the deadline, or
    validate the exact PPM header/length produces an original-only artifact.
    The parent fsyncs, atomically publishes, and revalidates each preview.
    Original and preview are independent pinned leases transferred, rolled
    back, replaced, budgeted, and retired as one logical bundle.  Emacs accepts
    only complete nested descriptors, synchronously reads at most the PPM's
    64-byte canonical header, trusts the local parent's already-verified
    payload digest, and feeds only that PPM preview to native APIs.  The
    compressed original remains external-only.  `o` single-flights one bounded
    local verifier that pins and hashes the original outside the UI thread
    while copying exact bytes into a private snapshot; a second invocation
    cancels it.  The snapshot has an independent count/TTL bound so `open' and
    `xdg-open' may exit before their GUI consumer reads the path without racing
    panel eviction.  Retirement flushes only previews that were actually
    materialized, without rereading every retained image.  Pillow is a declared
    helper/Nix dependency.  The default configurable source-pixel budget may
    only lower the hard protocol ceiling.
  - Tests: complete PNG/JPEG success produces an exact bounded PPM whose
    dimensions, length, digest, mode, ownership, and direct-child identity are
    verified; every truncated prefix, corrupt stream/CRC/entropy, MIME-magic
    mismatch, decompression-bomb warning/error, exact ceiling, one-over
    ceiling, worker crash/timeout/import failure/resource failure, malformed or
    oversized output, stdout/stderr flood, and publication race becomes
    external-only with no partial file or leaked lease.  Prove ping/event-loop
    responsiveness during slow decode, hard pre-launch quotas, and atomic
    original+preview rollback/update/retirement.  ERT recursively canaries
    `create-image`, `image-size`, `insert-sliced-image`, and `image-flush` so no
    argument ever contains the original path; original-only entries invoke no
    native API; admission reads no more than the fixed header and never hashes
    pixels in Emacs; the external opener receives only a freshly verified
    independent snapshot that survives immediate launcher exit; repeated opens
    remain single-flight and cancellable.  Scroll, rerender, zoom, eviction,
    clear, panel kill, and exact byte/count boundaries preserve source text and
    stay bounded.  The suite runs on x86_64-linux and aarch64-darwin without
    `/proc`, GUI, SSH, or remote services, with a required real Pillow worker
    check in the Nix closure (no dependency skip is accepted).
  - Narrow run: helper image-metadata/output tests plus ERT selector
    `^ejn-ei4d-` and all panel image tests, each under an external deadline.
  - Landed verification: 677 source-based ERTs and 199 host helper tests pass;
    byte compilation reports only the two pre-existing optional Evil variable
    warnings.  The x86_64-linux Nix closure runs all 199 helper tests with
    Pillow required and no skips, including real PNG/JPEG decoder-worker
    success and corruption failure paths.  Darwin directory-fsync exceptions
    and the bounded Apple Silicon address-space limit have deterministic unit
    coverage; a real aarch64-darwin closure smoke remains an acceptance-gate
    requirement because this host cannot execute it.

- [x] owner=terra-ei5 claimed=2026-09-01 landed=cda5219 **EI5 Route completion, inspect, is-complete, heartbeat, and stdin.**
  - Depends: EI4D, HT10, HT11.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook.el`, `emacs-jupyter-notebook-events.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: preserve non-blocking cache semantics and stale-context drops;
    each aux request uses helper ID/deadline; heartbeat failure enters existing
    transport-dead path; stdin prompt is scheduled outside process filter and
    password data is cleared/not logged.
  - Tests: existing completion/inspect suites run against fake helper; capf
    remains under 5 ms; late reply and moved point; concurrent long execution;
    heartbeat miss; stdin normal/password/quit; no recursive minibuffer prompt
    from process filter.
  - Narrow run: ERT selector `^ejn-ei5-` plus W3/W4/W9 completion tests.
  - Landed verification: 696 source-based ERTs and 199 host helper tests pass
    (three expected host skips); production Elisp byte-compiles cleanly and all
    generated byte-code was removed before the source rerun.  The x86_64-linux
    Nix closure runs all 199 helper tests with no skips.  A second read-only
    review found no remaining correctness issue after malformed readiness and
    stdin acknowledgements, cancelled prompts, duplicate completion ownership,
    stale client/context replies, and busy/single-flight heartbeat races gained
    direct regression coverage.  A real aarch64-darwin closure smoke remains an
    acceptance-gate requirement because this host cannot execute it.

- [x] owner=terra-ei6 claimed=2026-09-01 landed=28fe0d2 **EI6 Route explicit interrupt/restart/shutdown correctly.**
  - Depends: EI5, HT12R3.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook.el`, `emacs-jupyter-notebook-ssh.el`,
    `emacs-jupyter-notebook-connection.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`,
    `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: helper control routing admits only exact bounded `interrupt`
    and `shutdown` operations; helper `restart` remains unsupported.  Interrupt
    is owned by the active dispatched/cancelling ledger record and never affects
    queued, auxiliary, or stale work.  Every successful attach durably records
    all five validated non-secret remote ports; restart rejects entries lacking
    the new schema rather than guessing.
  - Deliverable: at explicit restart admission, open a unique FIFO gate before
    the reversible preflight so no queued work can pass the user's replacement
    gesture.  A bounded asynchronous child reconstructs a private 0600
    remote-port connection seed from the durable local connection file while
    bounded kernelspec resolution runs; neither step can block Emacs.  Only
    after both succeed does the exact installed helper receive shutdown.  After
    confirmed terminal shutdown it releases old local transport, uploads the
    seed to a unique sibling staging path, atomically publishes it at the
    original remote connection path, and reuses HT12R2's direct launch.  The
    identity-probed replacement PID remains context-only until a fresh helper
    verifies kernel info; finalization then atomically promotes the new
    PID/ports/local connection file and injects formatter/watchdog exactly once
    before queued user work can run.
  - Deliverable: preflight failure leaves the old kernel and durable entry
    untouched.  Shutdown failure or ambiguity never launches a replacement and
    preserves the registry/local connection file while retiring only suspect
    local transport.  Every failure after confirmed shutdown retains a
    provisional recoverable entry and removes local seed/process/timer state;
    it never compensates by killing.  Explicit shutdown removes registry state
    and the local connection file only after the helper confirms terminal
    liveness.  Close, helper crash, heartbeat, reconnect, timeout, and late
    callbacks cannot dispatch shutdown or launch a replacement.
  - Tests: exact control results and restart rejection; no-active/queued/stale
    interrupt; fake event ordering, synchronous throws, timeouts, cancellation,
    and late success.  Restart preflight failures prove zero shutdown/launch;
    post-shutdown failures cover staged restore/publish, launch admission,
    sidecar/PID identity, tunnel, fresh helper attach/kernel-info, registry
    promotion, and setup.  Assert provisional save precedes launch, the new PID
    is absent from durable state until verification, all five remote ports and
    the connection key survive reconstruction without entering the registry or
    logs, setup runs once, and every process/timer/temp file is reclaimed.
    Shutdown failure preserves registry/local file; confirmed shutdown removes
    them in order.  Close and helper crash assert no terminating or launch op.
  - Narrow run: ERT selector `^ejn-ei6-` plus W1/W5/W11 lifecycle tests.
  - Landed verification: 723 source-based ERTs and 199 host helper tests pass
    (three expected host skips), including 27 focused EI6 lifecycle tests;
    production Elisp byte-compiles with only the two pre-existing optional Evil
    variable warnings, and all generated artifacts were removed before the
    canonical source rerun.  Independent review found no P0/P1 defects; its
    seed-read blocking and post-shutdown registry-truth concerns were fixed and
    the resulting async reader, disposer/watchdog coverage, and provisional
    in-memory state passed a final delta audit.  A real remote SSH lifecycle
    smoke remains an acceptance-gate requirement.

- [x] owner=terra-ei7 claimed=2026-09-01 landed=fea9441 **EI7 Mark ambiguous work outcome-unknown and reconnect without replay.**
  - Depends: EI6, TH3.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook.el`, `emacs-jupyter-notebook-result.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: helper death, protocol violation, tunnel death, or heartbeat
    death atomically marks all accepted non-terminal requests unknown, cancels
    their timers, leaves queued/not-accepted work visibly cancelled/unknown per
    dispatch evidence, releases local transport, and starts exactly one existing
    retry loop.  Reconnect never resends ledger code.
  - Tests: failure before send, immediately after send, busy, after reply before
    idle, and terminal; inspect fake-helper request log to prove zero replay;
    reconnect then new execution works; old late events ignored.
  - Narrow run: ERT selector `^ejn-ei7-` plus W19 tests.
  - Landed verification: 746 source-based ERTs and 203 host helper tests pass
    (three expected host skips), including 23 focused EI7 transport tests; the
    v1 protocol fixture/self-rejection validator passes, production Elisp
    byte-compiles with only the two pre-existing optional Evil variable
    warnings, and generated artifacts were removed before the canonical source
    rerun.  Independent audits found and drove fixes for interrupt-grace timer
    cleanup, idle Jupyter-channel failure propagation, bounded internal setup,
    and the admitted-false/transport-event ordering race; the final delta audit
    found no P0/P1 defect.  Real relay and remote-outage smokes remain under the
    acceptance gates.

- [x] owner=terra-ei8 claimed=2026-09-01 landed=500da62 **EI8 Make status/log UI expose helper and request truth.**
  - Depends: EI7.
  - Files: `emacs-jupyter-notebook-backend.el`,
    `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook-helper.el`, `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`,
    `tests/emacs-jupyter-notebook-helper-process-tests.el`.
  - Deliverable: actual interactive status reports helper PID/state/protocol,
    active request state/age, queue length, kernel status, transport phase,
    retry countdown, last bounded error, and working cancel/restart-helper
    actions.  Helper stderr enters bounded EJN log with secrets redacted.
  - Tests: render each state, invoke each advertised action, oversized stderr,
    password/base64 canaries absent, stale session action cannot affect current.
  - Narrow run: ERT selector `^ejn-ei8-` plus IR5 status tests.
  - Landed verification: 761 source-based ERTs and 203 host helper tests pass
    (three expected host skips), including 15 focused EI8 status/log tests;
    production Elisp byte-compiles with only the two pre-existing optional Evil
    variable warnings, and generated artifacts were removed before the
    canonical source rerun.  Independent review found and drove fixes for
    process-filter redaction work, final stderr loss, retained status objects,
    stale restart/cancel identities, active-reconnect restart wedging,
    unavailable-helper actions, and redaction syntax bypasses; its final delta
    audit found no P0/P1 defect.

- [x] owner=terra-ei9 claimed=2026-09-01 landed=593e04e **EI9 Add stale artifact cleanup and local lifecycle audit.**
  - Depends: EI8.
  - Files: `emacs-jupyter-notebook-artifacts.el`,
    `emacs-jupyter-notebook-result.el`,
    `emacs-jupyter-notebook-helper.el`,
    `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-artifacts-tests.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`,
    `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: buffer/panel cleanup removes its artifact tree locally;
    kill-Emacs cleanup covers live trees; startup prunes only EJN-owned stale
    directories older than a bounded age with owner/mode/name validation.
    Helper/session/timers/process buffers are all audited for kill/mode-disable/
    supersede/failure paths.
  - Tests: ownership/path/symlink/staleness matrix; no deletion outside root;
    every lifecycle phase leak assertion; registry/remote terminator spies stay
    untouched.
  - Narrow run: ERT selector `^ejn-ei9-` plus W1/W18 leak tests.
  - Landed verification: two canonical source runs passed 801/801 ERTs and
    217/217 host helper tests (three expected host skips).  Production Elisp
    byte-compiled with only the two pre-existing optional Evil variable
    warnings; generated bytecode and Python caches were removed before the
    second source run.  Independent review drove fixes for quadratic panel
    cleanup, identity-free deletion, lease cleanup and invalidation, unsafe
    existing-parent chmod, cross-Emacs stale pruning, helper-root cache growth,
    and pending external-viewer ownership.  Its final focused EI9/EI4D run
    passed 34/34 with no remaining P0/P1 finding.

- [ ] **EI10 Add static no-hang architecture assertions.**
  - Depends: EI9.
  - Files: `tests/emacs-jupyter-notebook-helper-backend-tests.el`,
    `helper/tests/test_architecture.py`.
  - Deliverable: stripped-source assertions enforce no production
    `AsyncKernelManager`/`KernelManager`/kernel launch or general subprocess
    launch in the helper backend.  The sole subprocess exception is EI4D's
    statically fixed thumbnail-worker invocation: no shell or caller-supplied
    executable/arguments, pinned inherited file descriptors, bounded/discarded
    output, resource caps, monotonic deadline, and process-group kill are all
    asserted.  Also enforce no base64 artifact in event encoder, no `jupyter-*` call
    outside legacy file, no `sleep-for`/sync SSH in interactive Elisp, bounded
    frame/queue constants non-nil, and no production wait loop for helper I/O.
  - Tests: mutation fixtures prove each assertion detects its forbidden form
    without false-positive on comments/docstrings.
  - Narrow run: ERT selector `^ejn-ei10-` and Python architecture test.

- [ ] **EI11 Make helper selectable for local dogfood, still default legacy.**
  - Depends: EI10.
  - Files: `emacs-jupyter-notebook-vars.el`, `README.md`,
    `tests/emacs-jupyter-notebook-tests.el`.
  - Deliverable: document exact Nix/helper command and temporary backend
    selector, fail fast with actionable diagnostics when helper/dependency is
    absent, document the temporary emacs-jupyter pin, and add no implicit pip
    install/download behavior.  Helper selection must require no remote change.
  - Tests: command resolution in checkout, straight build symlink, Nix closure,
    missing command/dependency/version mismatch; README command names checked.
  - Narrow run: ERT selector `^ejn-ei11-`, full ERT, all helper unit tests.

### Phase AG - integration and removal gates

- [ ] **AG1 Run direct helper/local-kernel contract suite.**
  - Depends: HT13, EI11, TH3.
  - Files: tests only; production fixes require a new narrowly claimed row.
  - Deliverable: one integration runner covers connect, execute stream/result/
    error/image/update/clear, aux requests, stdin, interrupt, restart, close,
    reconnect, and explicit shutdown against TH2.  Assert request state/event
    order, artifact constraints, cleanup, and unchanged kernel across close.
  - Gate: 20 consecutive runs, zero failure/leak, each under 120 seconds.

- [ ] **AG2 Run Emacs/helper/local-kernel end-to-end suite.**
  - Depends: AG1.
  - Files: `tests/emacs-jupyter-notebook-helper-e2e.el`, runner only.
  - Deliverable: source buffer -> helper -> TH2 kernel -> panel path without SSH
    for cells, queueing, completion, inspect, image/external path, stdin,
    interrupt, helper kill/reconnect, restart, and shutdown.  Assert source
    text/modified flag unchanged and all resources bounded.
  - Gate: 20 consecutive batch runs under external timeout; no remote host.

- [ ] **AG3 Run outage, flood, and large-output stress gates.**
  - Depends: AG2.
  - Files: `tests/stress/*`, test docs only.
  - Deliverable: automate Global Gates 3-8 with TH1/TH3, including the 50 ms
    Emacs responsiveness canary, partial frames, malicious flood, 64 MiB
    artifact, 100-image retention, tunnel stop/restore, helper death at every
    execution boundary, and zero replay.
  - Gate: five repetitions of the full stress set; capture elapsed time and
    peak accumulator/queue/artifact metrics in test output.  Thresholds are
    assertions, not a human reading of logs.

- [ ] **AG4 Switch default to helper and complete real Doom dogfood.**
  - Depends: AG3.
  - Files: default/docs plus optional Doom E2E tests; no user dotfiles committed.
  - Deliverable: helper becomes default, old adapter remains explicit fallback
    for this gate only.  Run existing Doom E2E on an explicitly configured
    remote, then manually verify: hours-long wifi outage, laptop sleep/resume,
    busy multi-minute cell, repeated reconnect, 100+ images, rapid scrolling,
    helper kill, tunnel kill, and continued use of the same kernel.
  - Gate: record commands, helper/kernel/tunnel PIDs, observed recovery times,
    and any manual-only gaps in a dated `docs/dogfood/` report.  Remote cleanup
    happens only through explicit test-owned shutdown.

- [ ] **AG5 Remove emacs-jupyter transport and close W20.**
  - Depends: AG4 plus at least one week of normal helper-default use with no
    unresolved hang/data-loss finding.
  - Files: `emacs-jupyter-notebook-jupyter.el` (delete), backend/core/vars,
    tests, README, `AGENTS.md`, `ROADMAP.md`, package metadata.
  - Deliverable: delete legacy selector/wrapper and runtime dependency; rename
    misleading `--client`/`jupyter-*` internal state where helpful; update
    architecture docs to the helper boundary; retain MIME presentation helpers
    only if they do not pull transport into Emacs.  No compatibility aliases.
  - Gate: all global gates, full source ERT, helper unit/integration, Nix build,
    byte compile, static architecture tests, `git diff --check`, clean status,
    and manager review of every remote-termination call site.

## Manager review checklist for every integration row

- Does helper/process cleanup touch only local resources?
- Is every callback gated by buffer/session/request identity?
- Can any timer or late sentinel resurrect an old context?
- Is every byte/message/task/artifact/history collection bounded?
- Does the Emacs process filter do bounded work and defer UI dispatch?
- Can a helper response or log contain base64, password text, HMAC key, full
  connection-file contents, or Python traceback?
- Does timeout start at the correct state transition and cancel mutually with
  success?
- On ambiguity, is state `outcome-unknown` with zero replay?
- Are terminal events preserved under flow-control pressure?
- Does the test assert rendered/user-visible state, not only an internal plist?
- Are generated `.elc`, connection files, artifacts, registries, caches, and
  Python bytecode absent from the commit?

## Completion definition

W20 is complete only at `AG5`.  A helper prototype that executes a cell is not
completion.  A green mocked ERT suite without local-kernel, relay-outage, flood,
artifact, and helper-death tests is not completion.  Keeping the legacy
transport indefinitely is not completion.
