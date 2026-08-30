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
- `restart`
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

`close` is local-only.  `restart` and `shutdown` are permitted only after the
explicit corresponding EJN user command.  Their exact protocol implementation
must be proven by `HT12` against a local kernel launched by the same `jupyter
kernel` parent shape used remotely; no agent guesses these semantics.

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
   not rematerialize base64 or recreate retired files.
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
HT6 -> HT7 -> HT8 -> HT9 -> HT10 -> HT11 -> HT12 -> HT13

HT1 -> ET1 -> ET2 -> ET3
HT1 -> TH1
HT2 -> TH2 -> TH3

IR5 + HT7 + ET3 -> EI1 -> EI1R -> EI2 -> EI3 -> EI4 -> EI4V -> EI5
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
| Terra - high | `IR1`, `IR2`, `IR3`, `IR3S`, `IR4`, `IR5`, `HT4`, `HT5`, `HT6`, `HT7`, `HT8`, `HT9`, `HT11`, `HT12`, `HT13`, `ET2`, `ET3`, `TH3`, `EI1`, `EI1R`, `EI2`, `EI3`, `EI4`, `EI4V`, `EI5`, `EI6`, `EI7`, `EI8`, `EI9`, `AG1`, `AG2`, `AG3`, `AG5` | Shared state, async ordering, backpressure, secrets/artifacts, kernel lifecycle, reconnect, or integration gates |
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

- [~] owner=terra-ir3 claimed=2026-08-30 **IR3 Bound total panel history and artifact disk use.**
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

- [ ] **IR3S Make streamed text accumulation amortized instead of quadratic.**
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

- [ ] **IR4 Remove synchronous management SSH from ordinary UI paths.**
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

- [ ] **IR5 Make automatic reconnect retry ownership and status truthful.**
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

- [~] owner=terra-ht4 claimed=2026-08-30 **HT4 Implement credited event queue and stream coalescer.**
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

- [ ] **HT6 Add protocol dispatcher using a fake Jupyter backend.**
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

- [ ] **HT7 Attach `AsyncKernelClient` without owning kernel lifecycle.**
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

- [ ] **HT8 Correlate all Jupyter channels and execution terminal ordering.**
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

- [ ] **HT9 Normalize bounded stream, error, result, display, and artifact events.**
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

- [ ] **HT10 Implement bounded auxiliary requests.**
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

- [ ] **HT11 Implement stdin request/reply safely.**
  - Depends: HT10.
  - Files: `helper/ejn_helper/jupyter_backend.py`,
    `helper/tests/test_stdin.py`, `helper/integration_tests/test_stdin.py`.
  - Deliverable: correlate input request to execution, expose prompt/password
    boolean with bounded prompt text, accept one reply, clear password values
    after send where Python permits, and handle cancel/timeout/helper close.
    Password values never enter logs or error payloads.
  - Tests: ordinary input, password-shaped input with log capture, duplicate and
    stale reply, execution cancel while prompting, and helper close.
  - Narrow run: stdin unit/integration modules.

- [ ] **HT12 Prove and implement interrupt/restart/shutdown semantics.**
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

- [ ] **HT13 Complete helper main loop, signals, and fault containment.**
  - Depends: HT12.
  - Files: `helper/ejn_helper/__main__.py`,
    `helper/ejn_helper/runtime.py`, `helper/tests/test_runtime.py`.
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

- [ ] **ET1 Implement pure unibyte frame codec.**
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

- [ ] **ET2 Supervise helper process and handshake without blocking Emacs.**
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

- [ ] **ET3 Add bounded event drain, credit replenishment, requests, and deadlines.**
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

- [~] owner=luna-th1 claimed=2026-08-30 **TH1 Build a deterministic fake helper executable for ERT.**
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

- [ ] **TH2 Build a test-owned local kernel fixture matching production launch.**
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

- [ ] **TH3 Build five-channel stoppable TCP relay fault harness.**
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

- [ ] **EI1 Introduce the narrow async backend contract and temporary selector.**
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

- [ ] **EI1R Extract one backend-neutral normalized event reducer.**
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

- [ ] **EI2 Connect/finalize through the helper backend.**
  - Depends: EI1R, HT13.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: create artifact directory, start helper, handshake, connect to
    rewritten local connection file, bounded kernel-info verify, retain current
    remote-PID busy fallback, then finalize.  Any failure releases helper,
    tunnel, timers, and local artifacts without durable mutation.  Attempt
    identity gates every callback.
  - Tests: fake helper success; helper/tunnel/PID result permutations; timeout
    at each phase; A superseded by B; busy PID fallback; confirmed dead;
    registry untouched on every failure.
  - Narrow run: ERT selector `^ejn-ei2-` plus W13/W15/W19 selectors.

- [ ] **EI3 Replace singleton evaluation state with serialized request ledger.**
  - Depends: EI2.
  - Files: `emacs-jupyter-notebook.el`,
    `emacs-jupyter-notebook-result.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: buffer-local hash ledger plus FIFO queue and one active user
    execution.  Enqueue creates panel/fringe running/queued state but sends only
    when no active execution.  Timeout arms on `dispatched`; terminal advances
    queue.  Cancel queued removes without interrupt; cancel active sends one
    interrupt.  All callbacks correlate request and entry generation.
    Code over `EJN_MAX_CODE_BYTES` is rejected before JSON serialization and
    never creates a misleading running entry.
  - Tests: A/B ordering, B has no timer before dispatch, A terminal dispatches
    B once, cancel A/B, same-cell and different-cell reruns, late A events,
    buffer kill, source edits preserving cell keys, and no source mutation.
  - Narrow run: ERT selector `^ejn-ei3-` plus W5/W13 evaluation tests.

- [ ] **EI4 Route normalized text/display/artifact events to the panel.**
  - Depends: EI3, HT9.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook-result.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: translate helper stream/error/result/clear/display/update/
    truncation envelopes into EI1R's reducer without re-decoding images.  Add a
    panel API accepting an already-published confined image file plus
    MIME/hash/size.  Validate path and size before display.  Entry retirement
    deletes file exactly once.
  - Tests: every event, artifact escape/symlink/replacement, clear wait/update,
    retired/late event, repeated deletion, unsupported/truncated marker,
    image-cache flush, and 100 artifacts respecting IR3 budgets.
  - Narrow run: ERT selector `^ejn-ei4-` plus all panel tests.

- [ ] **EI4V Move matplotlib viewer payloads to confined pickle files.**
  - Depends: EI4.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook-result.el`,
    `emacs-jupyter-notebook-viewer.el`, `viewer/ejn_viewer.py`,
    `viewer/test_viewer_gui.py`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: panel entries retain pickle artifact metadata/path, never
    base64.  The local viewer accepts a file-path request, validates the file is
    regular, owner-only, and confined beneath the EJN artifact root.  Pickle
    load/figure reconstruction moves off the viewer GUI event tick into one
    bounded worker.  Panel pickle count/byte eviction deletes retired files,
    and an already-open viewer receives its own safe lifetime/reference
    behavior rather than racing deletion.
  - Tests: base64 canary absent from panel, Elisp process payload, and viewer
    logs; path traversal/symlink/mode/owner rejection; retirement while viewer
    request is pending; pickle budget; valid figure round trip using a
    test-owned local file.  No GUI is required for security/protocol tests.
  - Narrow run: ERT selector `^ejn-ei4v-` and viewer Python tests.

- [ ] **EI5 Route completion, inspect, is-complete, heartbeat, and stdin.**
  - Depends: EI4V, HT10, HT11.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook.el`,
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

- [ ] **EI6 Route explicit interrupt/restart/shutdown correctly.**
  - Depends: EI5, HT12.
  - Files: `emacs-jupyter-notebook-helper-backend.el`,
    `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: interrupt affects active request; restart waits asynchronously
    for helper-confirmed restart then reinjects formatter/watchdog; shutdown is
    the only route to helper shutdown op and removes durable entry only after
    confirmed terminal result.  Close/reconnect/failure cannot dispatch either
    restart or shutdown.
  - Tests: fake event ordering/timeouts/late success; static call-site audit;
    restart reinjection once; shutdown failure preserves registry; close and
    helper crash assert no terminating op.
  - Narrow run: ERT selector `^ejn-ei6-` plus W1/W5/W11 lifecycle tests.

- [ ] **EI7 Mark ambiguous work outcome-unknown and reconnect without replay.**
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

- [ ] **EI8 Make status/log UI expose helper and request truth.**
  - Depends: EI7.
  - Files: `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: actual interactive status reports helper PID/state/protocol,
    active request state/age, queue length, kernel status, transport phase,
    retry countdown, last bounded error, and working cancel/restart-helper
    actions.  Helper stderr enters bounded EJN log with secrets redacted.
  - Tests: render each state, invoke each advertised action, oversized stderr,
    password/base64 canaries absent, stale session action cannot affect current.
  - Narrow run: ERT selector `^ejn-ei8-` plus IR5 status tests.

- [ ] **EI9 Add stale artifact cleanup and local lifecycle audit.**
  - Depends: EI8.
  - Files: `emacs-jupyter-notebook-result.el`,
    `emacs-jupyter-notebook-helper.el`, `emacs-jupyter-notebook.el`,
    `tests/emacs-jupyter-notebook-helper-backend-tests.el`.
  - Deliverable: buffer/panel cleanup removes its artifact tree locally;
    kill-Emacs cleanup covers live trees; startup prunes only EJN-owned stale
    directories older than a bounded age with owner/mode/name validation.
    Helper/session/timers/process buffers are all audited for kill/mode-disable/
    supersede/failure paths.
  - Tests: ownership/path/symlink/staleness matrix; no deletion outside root;
    every lifecycle phase leak assertion; registry/remote terminator spies stay
    untouched.
  - Narrow run: ERT selector `^ejn-ei9-` plus W1/W18 leak tests.

- [ ] **EI10 Add static no-hang architecture assertions.**
  - Depends: EI9.
  - Files: `tests/emacs-jupyter-notebook-helper-backend-tests.el`,
    `helper/tests/test_architecture.py`.
  - Deliverable: stripped-source assertions enforce no production
    `AsyncKernelManager`/`KernelManager`/kernel launch/subprocess launch in
    helper backend, no base64 artifact in event encoder, no `jupyter-*` call
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
