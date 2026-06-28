# Roadmap

This file is the shared progress ledger for `emacs-jupyter-notebook`. Agents
read it before starting, claim rows they will work on, and check rows off when
they land. `AGENTS.md` covers the why and the architecture; this file covers
the what and the who.

## How to use this file

Status legend:

- `[ ]` todo — unclaimed
- `[~]` in progress — claimed by exactly one agent
- `[x]` done — landed on `master`

Protocol:

1. Before starting a row, change `[ ]` to `[~] owner=<agent-name> claimed=<YYYY-MM-DD>`.
   Commit the claim before writing any code so other agents see it.
2. Never edit a row that is in `[~]` and not owned by you. If you need to
   coordinate, append a note under the row prefixed `> note:`.
3. On completion, change `[~]` to `[x] sha=<short-sha>` referencing the merge
   commit on `master`.
4. Honor the workstream's listed file scope. If you must edit a file outside
   the scope, claim a coordination row in `## Cross-cutting changes` first.
5. Workstream order constraints are listed under each section header. Do not
   start a workstream whose dependencies are not all `[x]`.
6. The `## Design decisions` block is append-only. Do not rewrite past
   decisions; add a new dated entry that supersedes the old one and update the
   roadmap rows that depend on it.

## Design decisions

These are binding for every workstream. Update only by appending a new entry.

- **2026-06-28 / No backwards compatibility.** The package is not in external
  use. Breaking keymap, command name, or customization-variable changes are
  acceptable when the new shape is better. Do not add deprecation aliases.
- **2026-06-28 / The remote kernel outlives Emacs.** The kernel is `nohup`-ed
  on launch and must survive Emacs crashes and buffer kills. Only the explicit
  user command `emacs-jupyter-notebook-shutdown-kernel` (and the explicit
  `clean-orphaned-kernels` housekeeping command) may terminate the remote
  kernel. No automatic cleanup of the remote kernel from `kill-buffer-hook`,
  `kill-emacs-hook`, mode-disable, or async failure paths.
- **2026-06-28 / Single buffer per kernel for now.** Multi-buffer sharing of a
  single remote kernel is out of scope. Each buffer owns its own tunnel and
  client. The registry entry is keyed per session-id; a second buffer
  reconnecting to the same session is undefined behavior until a future
  workstream opens it explicitly.
- **2026-06-28 / Registry is the durable truth.** Local state (`--client`,
  `--tunnel-process`, etc.) may be torn down freely; the registry entry and
  the remote connection file may not be touched on buffer kill, mode disable,
  or Emacs exit.
- **2026-06-28 / Source buffer stays clean.** Evaluation output must not be
  rendered in the source buffer. All result presentation lives in a dedicated
  side-panel buffer. The only permitted source-side decoration is a
  fringe/margin indicator that carries no buffer text, has no
  `cursor-intangible` or `read-only` adjacency to user text, and cannot wrap
  into or be edited by the user. This rule exists because every prior
  inline-overlay approach has produced "text wraps around / jumps into the
  overlay" bugs that are not worth re-fighting.
- **2026-06-28 / Cells are the primary eval unit.** Send-cell is the primary
  evaluation command. Send-region, send-paragraph, and send-defun are
  secondary surfaces. Output in the latest-per-cell view is keyed by cell
  position (the `# %%` marker). Output produced by region/paragraph/defun is
  appended to the history-log view only and does not participate in
  latest-per-cell replacement.
- **2026-06-28 / Async is the rule, not the exception.** No code path that a
  user can hit during ordinary editing may block the UI. This includes
  completion, inspect, send-cell, reconnect, fetch-log, list-procs, and
  clean-orphans. Initial first-time start may be slow (30–90 s on
  high-latency links is acceptable) but must remain non-blocking.

## Cross-cutting changes

Use this section to claim ownership of changes that span workstream file
scopes. Format: `[ ] CC<n> <short description> — touches: <files> — for: <W?>`.

- _none yet_

---

## W1 — Lifecycle hooks & leak fixes

Depends on: nothing. Start first.

File scope:
- `emacs-jupyter-notebook.el`
- `tests/emacs-jupyter-notebook-tests.el`

Goal: Local resources (tunnel proc, stderr buffers, timers, client handle) are
released on buffer kill, mode disable, and async failure — without touching
the registry or the remote kernel.

- [x] sha=279652b W1.1 Buffer-local `kill-buffer-hook` installed by the minor mode that
      tears down the tunnel process and its stderr buffer, cancels timers,
      and drops `--client`. Must not call `--cleanup-remote-entry`, must not
      call `jupyter-shutdown`, must not delete the registry entry, must not
      delete the local connection file (it is the offline reconnect key).
- [x] sha=b093303 W1.2 On minor-mode disable, cancel any in-flight `--async-context`
      (call the cancel path without raising), clear timers, and remove the
      kill-buffer-hook from the buffer.
- [x] sha=bc37398 W1.3 Fix stderr-buffer leak: `--async-delete-process` must also kill
      the buffer stored under the process property
      `emacs-jupyter-notebook-stderr-buffer` (see ssh.el:235). Audit
      `--async-fail`, `--cleanup-current-state`, and W1.1's hook to use the
      fixed disposer.
- [x] sha=5e62394 W1.4 ERT: killing a buffer that owns an async context disposes the
      launch/scp/tunnel processes and their stderr buffers; the registry
      entry and the local connection file are still present after the kill.
- [x] sha=ea5f732 W1.5 ERT: disabling the minor mode while phase ∈ {launch, retrieve,
      tunnel, connect} resets phase, kills processes, and leaves the registry
      untouched.
- [x] sha=117f47a W1.6 ERT: a failed launch leaves zero `*emacs-jupyter-notebook-*`
      buffers behind (use `(buffer-list)` filtered by name prefix).
- [x] sha=ed5d15c W1.7 ERT: killing the buffer that owns a live client does **not** call
      the configured `…-jupyter-shutdown-function` and does **not** remove
      the registry entry.
- [x] sha=f5ff50f W1.8 Remove `--async-kill-remote-kernel`
      call and `:local-file` deletion from `--async-fail` (binding-rule
      compliance: async failure paths must not terminate the remote kernel,
      and `:local-file` is the future `:local-connection-file` reconnect key
      after `--async-connect-finalize` promotion). Update or drop the
      `--async-kill-remote-kernel` stubs in the W1.3/W1.6 tests; add a
      positive ERT asserting `--async-fail` does NOT call the kill helper.
- [x] sha=82e869a W1.9 Mode-disable also releases `--client` and `--tunnel-process` (the
      W1 GOAL lists both as local resources released on mode disable). Update
      `ejn-mode-disable-preserves-session-entry-and-client` to assert only the
      session entry is preserved; add an ERT proving the client and tunnel
      process are gone after disable.
- [x] sha=ecd9564 W1.10 Per-disposer error tolerance in buffer-local cleanup: the
      kill-buffer-hook and mode-disable wrappers wrap a chain of disposers in
      one `condition-case`. Refactor so each disposer is independently
      best-effort (`ignore-errors` per call or an `unwind-protect` chain),
      and add an ERT proving that one disposer raising still lets the
      remaining disposers run.

Acceptance: all new ERTs pass; canonical test command is green; manual
smoke: open a buffer, start a kernel, kill the buffer, reopen the file,
reconnect-remote-kernel works without restarting the remote kernel.

---

## W2 — Output panel + fringe indicator

Depends on: W1.

File scope:
- `emacs-jupyter-notebook-result.el` (substantial rewrite; this file is no
  longer about inline overlays)
- `emacs-jupyter-notebook-jupyter.el` (callbacks now drive the panel API
  instead of the overlay API)
- `emacs-jupyter-notebook.el` (eval entry-points and cell→panel wiring)
- `emacs-jupyter-notebook-vars.el` (new customization vars)
- `tests/emacs-jupyter-notebook-tests.el`

Goal: Replace inline output overlays with a dedicated side-panel buffer and
a non-interfering fringe indicator in the source buffer. The source buffer
stops carrying any output text, ending the wrap/jump-into-overlay class of
bugs for good.

Panel design contract:
- One panel buffer per source buffer, named `*ejn: <basename>*`.
- Auto-opens on the buffer's first evaluation in a side window
  (`display-buffer-in-side-window`, right side by default; configurable).
- Two views, toggled with `H` inside the panel:
  - **Latest-per-cell (default).** One section per cell, keyed by the cell's
    `# %%` marker location. Re-evaluating the same cell replaces its
    section. Sections appear in cell order.
  - **History log.** Every evaluation appends a new entry at the bottom
    with timestamp + execution count + status. Older entries stay visible
    above. Auto-scrolls to bottom on new entry.
- Entries from region/paragraph/defun eval appear only in the history-log
  view (no cell key → cannot participate in replace).
- Each entry header carries: execution count (or `*` while running),
  ISO timestamp, status (`running` / `ok` / `error`), and a button on the
  cell title (if any) that jumps to the originating cell in the source
  buffer.
- Streaming stdout/stderr writes into the active entry incrementally. Updates
  throttled to ≤ 20 Hz so a busy cell does not pin a redisplay frame.
- Images render inline in the panel using `create-image`; native zoom keys
  work (`+`/`-`/`=` for image zoom via `image-mode` minor or built-in image
  keys).
- `q` in the panel buries the window. `RET` on an entry header jumps to the
  source. `n` / `p` navigate between entries.
- Killing the source buffer kills the panel (coordinates with W1.1's hook).

Fringe indicator contract:
- One indicator per cell marker line, drawn in the left fringe (or left
  margin if fringe unavailable in the terminal).
- States: blank (never run), `►` (running), `✓N` (ok with execution count
  N, truncated to last digit if N ≥ 10), `✗` (error), `…` (queued / awaiting
  reply).
- Implementation must not insert any text into the source buffer and must
  not place `cursor-intangible` properties adjacent to user text. Use
  `'before-string` with a `(display ((margin left-margin) "..."))` property
  on a zero-width overlay anchored at the cell marker line start, or a
  fringe bitmap via `define-fringe-bitmap`. The W2 agent picks the
  implementation; the constraint is "user can edit anywhere, indicator
  never interferes".

Rows:

- [x] sha=f61cd49 W2.1 Define the panel buffer mode (`emacs-jupyter-notebook-panel-mode`,
      derived from `special-mode`) and its API:
      `ejn-panel-ensure BUFFER` returns the panel for source BUFFER,
      `ejn-panel-start-entry PANEL CELL-KEY CODE` returns an entry handle,
      `ejn-panel-append-text HANDLE TEXT &optional FACE`,
      `ejn-panel-replace-text HANDLE TEXT`,
      `ejn-panel-set-image HANDLE IMAGE-SPEC`,
      `ejn-panel-finish-entry HANDLE STATUS EXECUTION-COUNT`,
      `ejn-panel-clear-entry HANDLE`. ERT for the API in isolation
      (no kernel).
- [x] sha=2806a6b W2.2 Implement the latest-per-cell view as the default. Cell key is
      `(buffer-file-name . marker-line-start)`. Re-evaluating the same cell
      replaces its section in place. Sections render in cell order. ERT:
      two evals of the same cell leave one section; evals of two cells leave
      two sections in order.
- [x] sha=031436e W2.3 Implement the history-log view. Toggle via `H` in the panel.
      Region/paragraph/defun evals appear only here. ERT: toggle round-trip
      preserves data; region eval shows in history but not in latest-per-cell.
- [x] sha=c13f9f0 W2.4 Streaming throttle. Stream events buffer at the panel level and
      flush at most every 50 ms. ERT: 1000 small stream events produce ≤ 20
      redisplays in batch (mock by counting `ejn-panel--render` calls).
- [x] sha=d357f28 W2.5 Image rendering. PNG/JPEG inline; large images downscaled with
      `:max-width` / `:max-height` from the existing vars. Native image keys
      (`+`, `-`, `=`) work in the panel. ERT: image-bearing entry survives
      view toggle and panel kill/reopen.
- [~] owner=W2-agent claimed=2026-06-28 W2.6 Navigation keys: `q`, `RET`, `n`, `p`. ERT: `RET` on a section
      header jumps to the originating cell in the source buffer.
- [ ] W2.7 Rewrite `emacs-jupyter-notebook-jupyter--callbacks` to drive the
      panel API instead of the overlay API. Drop the inline-overlay code
      path entirely (no compat mode). Remove
      `emacs-jupyter-notebook-use-inline-overlays` and related vars from
      `-vars.el`. ERT: callbacks update the panel for stream/execute_result/
      display_data/update_display_data/error/clear_output/execute_reply/
      status messages, with no buffer-text mutation in the source.
- [ ] W2.8 Fringe/margin indicator. Per cell-marker overlay reflecting the
      latest known state for that cell (queued / running / ok-N / error /
      blank). Driven by the same callbacks that update the panel. ERT:
      indicator state transitions for queued→running→ok and →error; ERT:
      typing arbitrary text on the cell marker line does not move, delete,
      or interfere with the indicator.
- [ ] W2.9 Panel cleanup: killing the source buffer (via W1.1's hook) kills
      the panel; killing the panel alone does not affect the kernel or
      registry. ERT.
- [ ] W2.10 Customization: `emacs-jupyter-notebook-panel-side` (default
      `right`), `emacs-jupyter-notebook-panel-width` (default 80),
      `emacs-jupyter-notebook-panel-default-view` (default `latest`),
      `emacs-jupyter-notebook-panel-stream-throttle-ms` (default 50),
      `emacs-jupyter-notebook-fringe-side` (default `left-fringe`).

Acceptance: every W2 row [x] with sha; the source buffer carries no result
text; all inline-overlay code is gone; manual smoke: edit code while a long
cell runs in the panel, see streaming continue without source-buffer
disturbance; re-run a matplotlib cell, see the figure replace cleanly.

---

## W3 — Non-blocking completion

Depends on: W1. May start in parallel with W2.

File scope:
- `emacs-jupyter-notebook.el` (the completion-at-point function)
- `emacs-jupyter-notebook-jupyter.el` (adapter; already exists for complete)
- `tests/emacs-jupyter-notebook-tests.el`

Goal: Completion that never blocks the UI even on high-latency links. This
is the no.1 dealbreaker today.

Design contract:
- `completion-at-point` returns immediately with locally-cached candidates
  (possibly empty) plus a `:company-deprecated` or `:exit-function`
  arrangement that lets new candidates arrive later.
- The async request goes out only after a configurable idle delay
  (`emacs-jupyter-notebook-completion-idle 0.10` s) to avoid hammering the
  kernel during fast typing.
- When the user types another character, any in-flight request is
  invalidated: its reply is dropped on arrival, not waited on.
- The cache key is `(point . line-up-to-point)` so identical contexts in the
  same session reuse the prior reply.
- Cache eviction: LRU bounded by
  `emacs-jupyter-notebook-completion-cache-size` (default 200 entries).
- Frontend integration: must work with `corfu` (auto-update on cache fill
  via `corfu--candidates`) and `company` (via `company-idle-begin`-style
  push). Document the integration in README.

Rows:

- [ ] W3.1 Cache with bounded LRU and context-key generation. ERT for cache
      hit/miss/eviction.
- [ ] W3.2 Idle-delayed async request that can be cancelled when the
      buffer's context changes (point moves, character typed). ERT.
- [ ] W3.3 In-flight invalidation: replies for stale requests are dropped
      without rendering. ERT.
- [ ] W3.4 capf integration that never blocks. ERT proves capf returns in
      ≤ 5 ms regardless of kernel state (mock the adapter to delay 10 s and
      assert capf still returns within budget).
- [ ] W3.5 Frontend refresh trigger: on reply arrival, if the buffer's
      context still matches the request's context, push results to the
      active completion UI. ERT for corfu and company variants (mock the
      UI).
- [ ] W3.6 Document the design and frontend integration in README.

Acceptance: every W3 row [x]; the timing assertion in W3.4 passes; manual
smoke on a real link: typing `np.` shows candidates within ≤ 1 RTT and the
UI never stutters.

---

## W4 — Tunnel hardening

Depends on: W1. May start in parallel with W2 / W3.

File scope:
- `emacs-jupyter-notebook-ssh.el`
- `emacs-jupyter-notebook-jupyter.el`
- `emacs-jupyter-notebook.el` (heartbeat install + reconnect probe wiring)
- `emacs-jupyter-notebook-vars.el`
- `tests/emacs-jupyter-notebook-tests.el`

Goal: Detect tunnel and remote-kernel death proactively, surface SSH errors
with actionable hints, refuse to reconnect to a dead remote PID. Reconnect
flow stays fully non-blocking.

- [ ] W4.1 Add `-o ServerAliveInterval=15 -o ServerAliveCountMax=3` to the
      tunnel argv builder; keep `-o ExitOnForwardFailure=yes`. Customization
      `emacs-jupyter-notebook-tunnel-keepalive-interval` (default 15). ERT.
- [ ] W4.2 Replace the unanchored `[0-9]+` PID parse with a printed sentinel.
      Remote launch shell emits `EJN_PID=<pid>` on its own line; `--parse-pid`
      matches `^EJN_PID=\([0-9]+\)$`. ERT: spurious MOTD numbers do not poison
      the parse.
- [ ] W4.3 Pure SSH-stderr classifier in `-ssh.el`:
      `emacs-jupyter-notebook-ssh-classify-stderr STDERR` →
      `(:kind <symbol> :hint <string>)`. Kinds: `auth-failed`,
      `host-unreachable`, `connection-refused`, `forward-refused`,
      `host-key-changed`, `unknown`. Wired into `--async-fail` to enrich
      user-visible errors. ERT per kind with representative stderr fixtures.
- [ ] W4.4 Async dead-PID probe in reconnect path. Before scp-ing the
      connection file, run `ssh kill -0 <pid>` async; on nonzero exit, fail
      the context with kind `kernel-dead` and surface a non-modal hint
      ("Remote kernel <pid> is no longer alive. Start a new one with
      `M-x emacs-jupyter-notebook-start-remote-kernel`."). Do not auto-start;
      leave the stale registry entry intact. ERT.
- [ ] W4.5 Periodic kernel-info heartbeat. Per-buffer repeating timer
      (`emacs-jupyter-notebook-heartbeat-interval` default 20 s) calls a new
      adapter function var `…-jupyter-kernel-info-function` (analogous to
      complete/inspect). On `emacs-jupyter-notebook-heartbeat-misses-allowed`
      (default 2) consecutive failures, set `--tunnel-dead`, clear
      `--kernel-status`, force mode-line update, log via the W6 log buffer.
      Cancel in W1.1's kill-buffer-hook and on mode-disable. ERT with
      stubbed adapter.
- [ ] W4.6 ERT: heartbeat-driven death routes through `--tunnel-reconnect`
      indistinguishably from sentinel-driven death.
- [ ] W4.7 Audit and remove the sync `--retrieve-connection-file` code path.
      All retrieval must go through the async retrieve. ERT: there is no
      `sleep-for` reachable from any user-facing command.

Acceptance: every W4 row [x]; manual smoke: drop the tunnel from outside
Emacs, observe `EJN!` within `heartbeat-interval`; the rest of Emacs stays
responsive throughout.

---

## W5 — Evaluation cancellation teeth

Depends on: W1. May start in parallel with W2 / W3 / W4. Coordinates with W2
on the `--evaluate` entry point.

File scope:
- `emacs-jupyter-notebook-jupyter.el`
- `emacs-jupyter-notebook.el`
- `tests/emacs-jupyter-notebook-tests.el`

Goal: A hung kernel never blocks the user. The existing evaluation-timeout
plumbing grows teeth.

- [ ] W5.1 Track the in-flight execute request id in a buffer-local
      `--evaluation-request` plist (request id, panel entry handle, cell
      key, started-at). Set in `--evaluate`; clear on `execute_reply`.
- [ ] W5.2 `--evaluation-timer` enforces: on timeout, call
      `emacs-jupyter-notebook-jupyter-interrupt`, annotate the panel entry
      with an error face + "timed out after Ns" suffix, clear
      `--evaluation-request`, log to the W6 log buffer. ERT with stubbed
      interrupt adapter.
- [ ] W5.3 `cancel-operation` learns about in-flight evaluations: if
      `--evaluation-request` is set, interrupt and clear it; the existing
      async-context cancel branch is untouched. ERT: cancel during
      evaluation interrupts; cancel during connect does not interrupt.
- [ ] W5.4 ERT: interrupt and restart interactive commands dispatch through
      their adapter function vars (currently completely uncovered).

Acceptance: every W5 row [x]; manual smoke: start an infinite loop, hit
interrupt, panel annotates "interrupted"; start an infinite loop, wait for
timeout, panel annotates "timed out".

---

## W6 — UX surface

Depends on: W1. May start in parallel with W2 / W3 / W4 / W5.

File scope:
- `emacs-jupyter-notebook.el`
- `emacs-jupyter-notebook-vars.el`
- `tests/emacs-jupyter-notebook-tests.el`
- `README.md` (keymap table)

Goal: Predictable, discoverable surface. The package feels responsive even
when the kernel is far away.

- [ ] W6.1 Single prefix key. Customization
      `emacs-jupyter-notebook-prefix-key` defaults to `"C-c j"`. All
      commands move under it. Suggested layout (the W6 agent makes the
      final call but it must be consistent):

          C-c j c   send-cell
          C-c j j   send-cell-and-advance
          C-c j r   send-region
          C-c j SPC send-paragraph
          C-c j d   send-defun
          C-c j b   send-buffer
          C-c j s   start-remote-kernel
          C-c j R   reconnect-remote-kernel
          C-c j y   retry-fresh-kernel
          C-c j k   interrupt-kernel
          C-c j K   restart-kernel
          C-c j S   shutdown-kernel
          C-c j x   cancel-operation
          C-c j ?   status (special-mode buffer; see W6.5)
          C-c j L   log buffer (see W6.6)
          C-c j o   show-output-panel
          C-c j t   toggle-panel-view (latest ↔ history)
          C-c j .   inspect-at-point
          C-c j TAB complete-at-point (rarely needed, capf handles it)
          C-c j v   fetch-remote-log
          C-c j q   list-remote-processes
          C-c j w   clean-orphaned-kernels
          C-c j n   forward-cell
          C-c j p   backward-cell
          C-c j %   cell-edit subprefix
                    (n p a e i I d k K y P N @)
                    [old `s` / `RET` removed; use the top-level send-cell]

      ERT covers a representative sample of bindings → commands. No
      backwards-compat aliases.

- [ ] W6.2 Mode-line lighter is a function returning one of:
      `" EJN"` (no client), `" EJN…launch"`, `" EJN…retrieve"`,
      `" EJN…tunnel"`, `" EJN…connect"`, `" EJN*"` (busy),
      `" EJN!"` (tunnel dead), `" EJN✗"` (last async errored),
      `" EJN✓"` (idle and healthy). Precedence:
      tunnel-dead > async-error > async-in-progress > kernel-busy >
      healthy > no-client. ERT per branch.
- [ ] W6.3 Friendly first-evaluate. When `C-c j c` is hit with no client,
      message
      `"emacs-jupyter-notebook: starting kernel via profile <name> (C-u to choose)"`
      before the silent default-profile start. `C-u` calls
      `--read-profile-name`. ERT for both branches.
- [ ] W6.4 Confirmations on destructive commands: `shutdown-kernel`,
      `send-buffer`, `retry-fresh-kernel`, `clean-orphaned-kernels`. Single
      `y-or-n-p` each; `C-u` skips the prompt. ERT.
- [ ] W6.5 Status command renders to a `special-mode` buffer
      `*emacs-jupyter-notebook status*` with live refresh (1 s while
      visible), font-locked sections, and button widgets on the suggested
      actions (clicking a suggestion calls the command in the originating
      buffer). ERT for content + one button-click.
- [ ] W6.6 Global async log buffer `*emacs-jupyter-notebook log*`
      (append-only; ISO timestamp + buffer name + phase + message; truncated
      to `emacs-jupyter-notebook-log-max-lines` default 2000). Every
      `--async-message` and every heartbeat failure writes here. ERT.
- [ ] W6.7 `--read-host-profile` validation. Empty/whitespace re-prompts;
      whitespace-in-host errors before launching SSH. ERT.
- [ ] W6.8 `--read-registry-entry` always offers a chooser when invoked
      interactively, with the current-file entry pre-selected. ERT.
- [ ] W6.9 Update `README.md`: new keymap table, panel description,
      completion behavior, eval surfaces (cell/region/paragraph/defun),
      removal of inline overlays.

Acceptance: every W6 row [x]; README reflects the new shape; manual smoke:
cold buffer → `C-c j c` shows the explanatory message, the mode-line cycles
through phases, the status buffer auto-refreshes.

---

## W7 — Test backfill

Runs alongside every other workstream. Each workstream PR delivers its own
acceptance tests; W7 owns the gaps not naturally claimed by W1–W6.

File scope:
- `tests/emacs-jupyter-notebook-tests.el`
- `tests/emacs-jupyter-notebook-doom-e2e.el`
- `tests/run-doom-e2e.sh` (only when needed for W7.4)

Per-row dependencies:
- W7.1 depends on W4.3.
- W7.2, W7.3 have no dependencies.
- W7.4 benefits from W2 (panel) and W4.5 (heartbeat) being in.

- [ ] W7.1 ERT: launch sentinel firing on nonzero exit transitions the async
      context to phase `error` and reports the classified stderr from W4.3
      in the user-facing message.
- [ ] W7.2 ERT: `--async-retrieve` exhausts its retries → context phase
      `error`, last-error captured in the snapshot, no leaked launch/scp
      processes or temp files.
- [ ] W7.3 ERT: `cancel-operation` during tunnel phase tears down the
      tunnel process and the registry remains untouched (or removed,
      depending on `:owns-kernel`); assert both branches.
- [ ] W7.4 Doom e2e additions: after the existing image assertion, run a
      text-output cell and assert text appears in the panel; then call
      `shutdown-kernel`, kill the buffer, `find-file-noselect` again,
      `reconnect-remote-kernel`, and assert connection succeeds. Order so
      reconnect runs before any shutdown.

Hard rules: do not edit any package source from W7. If a test reveals a
real bug, file a CC row in `## Cross-cutting changes` and stop.

---

## Future workstreams (not yet scheduled)

- **Interactive image zoom for medical imaging.** Crop-and-zoom on one
  subplot mirrors the same crop on all sibling subplots in the panel. Needs
  research into Emacs image transform support + a custom matplotlib backend.
- **Multi-buffer sharing one kernel.** Registry refcount + buffer set per
  session-id + tunnel-share. Requires reconsidering W1.1's kill-buffer-hook
  to refcount instead of unconditionally tearing down.
- **Variable explorer.** `*ejn vars*` side buffer polling `user_expressions`.
  Nice-to-have only.
- **Jupyter runtime niceties beyond the W1–W7 set.** Richer MIME, stdin
  prompts polish, is-complete checks, etc.

---

## Done archive

Move rows here when they land, with sha. Keep workstream order. This keeps
the active sections short and the history auditable.

- _none yet_
