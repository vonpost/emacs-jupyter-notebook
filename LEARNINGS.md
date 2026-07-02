# Learnings

Concrete things this codebase taught us while landing W1–W7. Read this
before starting a workstream that touches the async pipeline, the Jupyter
adapter, the panel, or the display layer. Each item is written so a future
agent (Claude, opencode, or human) can act on it directly.

Cross-references file paths and (workstream/row) that surfaced the lesson.

---

## Async lifecycle

### 1. Callbacks arrive after everything you cared about

By the time an `execute_reply`, `status=idle`, `complete_reply`, or
`kernel_info_reply` arrives, any of the following may already be true:

- The user hit cancel-operation.
- The evaluation timer fired.
- The tunnel died.
- The minor mode is disabled.
- The buffer was killed.
- A newer request superseded this one.

**Rule:** every Jupyter callback must correlate itself with the request
that spawned it before mutating buffer-local state. Thread a `request-id`
through the closure and drop the callback body when the buffer-local
"currently expected request-id" no longer matches.

Concrete precedent: **W5.5** — the unconditional `--evaluation-timer` /
`--evaluation-request` clearing in `execute_reply` and `status=idle`
callbacks let stale replies cancel the timer for a newer hung
evaluation. Fix pattern in `emacs-jupyter-notebook-jupyter.el`
`--callbacks` (search for "W5.5" comments).

### 2. `--async-context` at `:phase 'done` is a hazard

The async context stays populated after a successful connect. Code that
dispatches on "is there a context?" instead of `--async-in-progress-p`
takes the wrong branch during a live evaluation.

**Rule:** for "should I act on the in-flight operation?" always call
`emacs-jupyter-notebook--async-in-progress-p`, never test
`emacs-jupyter-notebook--async-context` directly.

Precedent: **W5.5(a)**. `cancel-operation` used raw `--async-context`
and never interrupted the kernel after a successful connect.

### 3. Async failure paths must not touch durable state

`--async-fail` is called from sentinel callbacks, timer callbacks, and
error branches all over the async pipeline. It runs on many code paths
you did not audit. **Failure paths release LOCAL resources only.** They
must NEVER:

- Call `jupyter-shutdown`.
- Call `--cleanup-remote-entry`.
- Call `--remove-registry-entry`.
- Call `--async-kill-remote-kernel`.
- Delete the local connection file (`:local-file` becomes
  `:local-connection-file` — the offline reconnect key).

Precedent: **W1.8**. The original `--async-fail` did all of the above,
which meant any sentinel-driven failure silently terminated the remote
kernel. This is why the binding rule "remote kernel outlives Emacs"
exists.

### 4. `--ensure-client-async` fallback is a hidden violation site

When reconnect fails, the fallback path used to remove the registry
entry and start a fresh kernel with the default profile. Both actions
were binding-rule violations. **Rule:** on any failed reconnect, surface
the error to the caller's `error-callback` and stop. Don't remove, don't
restart. The user picks the next move.

Precedent: **W4.8(a)** — `emacs-jupyter-notebook.el`
`--ensure-client-async` `t` branch.

### 5. Static grep for `sleep-for` in source

Sync SSH primitives keep creeping back in through dead-code paths.
`--connect-entry` was dead but still contained `--wait-for-tunnel` and
`--retrieve-connection-file`, both of which called `sleep-for`. If
anything ever routed through `--connect-entry`, the UI froze.

**Rule:** the ERT
`ejn-w7.5-source-files-do-not-depend-on-tramp`-style static assertion
is worth its weight. See `ejn-w4.7-no-sleep-for-in-source-files`. Never
delete either of these tests.

### 6. Late timeouts need mutual cancellation

The W5 evaluation timeout arms a timer AND sends a request. Whichever
completes first must cancel the other:

- If the reply arrives first → cancel the timeout timer.
- If the timeout fires first → interrupt the kernel and drop the reply
  when it arrives (via the request-id correlation check).

Precedent: **W4.8(c)** for heartbeat timeout timer + **W5.5** for
execute request-id correlation. Both patterns follow the same shape:
per-attempt token; cancellation checks the token before acting.

---

## Kernel / tunnel semantics

### 7. The remote kernel is durable; the tunnel is not

Design must treat them as separate lifetimes:

- **Kernel**: `nohup`'d on launch. Survives Emacs crash, buffer kill,
  network drop. Only three commands may terminate it —
  `shutdown-kernel`, `clean-orphaned-kernels`, `retry-fresh-kernel`
  (added by the 2026-07-01 design decision after W6.10).
- **Tunnel**: SSH child process. Dies with Emacs. Local resource.
  Freely torn down and rebuilt.

Practical consequence: buffer-kill, mode-disable, and async-failure
paths dispose the tunnel and never touch the kernel.

### 8. Sentinel-based tunnel detection is insufficient alone

An SSH connection can appear alive to the process sentinel while being
completely non-responsive (silent NAT timeout, half-broken TCP,
firewalled path). You need three layers:

- SSH `ServerAliveInterval=15 ServerAliveCountMax=3` — TCP-level
  keepalive on the tunnel argv. Kills the tunnel when the transport
  silently breaks.
- Process sentinel — reacts when the SSH process exits.
- **Per-buffer kernel-info heartbeat** — a `run-with-timer` that sends
  `kernel_info_request` every N seconds; N consecutive misses set
  `--tunnel-dead`.

All three are needed. Sentinel alone misses silent breaks;
`ExitOnForwardFailure` doesn't help mid-session; keepalives can miss
edge cases.

Precedent: **W4.1** (keepalives) + **W4.5** (heartbeat) + `--install-tunnel-sentinel` (from W1's earlier machinery).

### 9. PID parsing needs a sentinel line

The remote shell's stdout starts with SSH banners, MOTD, login
messages, and login-shell output — all of which contain numbers. A
regex like `[0-9]+` picked up whatever came first.

**Pattern:** the remote launch shell emits `EJN_PID=<pid>` on its own
line; the parser matches `^EJN_PID=\([0-9]+\)$` (anchored). This is
what makes the dead-PID probe from W4.4 reliable.

Precedent: **W4.2** — see `--parse-pid` in `emacs-jupyter-notebook.el`
and the corresponding `printf 'EJN_PID=%%s\\n' "$!"` in
`emacs-jupyter-notebook-ssh.el:ssh-build-remote-launch`.

### 10. Classify SSH stderr before surfacing to the user

Six recognizable failure kinds cover ~all real-world SSH errors:
`auth-failed`, `host-unreachable`, `connection-refused`,
`forward-refused`, `host-key-changed`, `unknown`. Every one benefits
from a specific hint (check identity, DNS, firewall, host key change,
etc.). The classifier is a pure function that pattern-matches stderr
text — put it in `-ssh.el` and wire it into `--async-fail`'s
`display-warning` path.

Precedent: **W4.3** — `emacs-jupyter-notebook-ssh-classify-stderr`.

### 11. Dead-PID probe before reconnect

Reconnect flows that only try to reconstruct the tunnel + client fail
with a slow `kernel_info` timeout when the remote kernel is actually
gone. A cheap `kill -0 <pid>` probe over SSH catches this in one round
trip and surfaces a "kernel is dead; start fresh" hint instead of a
generic timeout. The probe must NOT auto-start a fresh kernel.

Precedent: **W4.4** — `--async-probe-pid-alive`.

---

## Registry as source of truth

### 12. Which state is durable, which is disposable

- **Durable** (survives Emacs restart): registry entry, remote
  connection file, remote kernel.
- **Disposable** (torn down freely): `--client`, `--tunnel-process`,
  `--session-entry` (buffer-local copy), completion cache, evaluation
  timer, heartbeat timer, panel entries.

Any code that mutates durable state has to justify it against the
binding rule. `kill-buffer-hook` releases everything in the disposable
column and touches nothing in the durable column.

### 13. Registry write ordering matters

The registry entry is written in `--async-connect-finalize` BEFORE the
final client-state-set. If failure happens between the write and the
set, the registry has an entry for a session with no live client.
That's actually fine — the next reconnect will find it and reuse it.
The failure mode we care about is _losing_ data after it's promoted;
that's why `--async-fail` no longer deletes `:local-file` post-W1.8.

### 14. Corrupt registry file must not crash the package

The registry file can be edited, truncated, or corrupted. Loading it
must return `nil` with a warning rather than raising. See
`registry-load` — the `condition-case` wrapper is not optional.

Precedent: `ejn-w7.5-registry-load-corrupt-file-returns-nil-with-warning`.

---

## Display: source buffer stays clean

### 15. Inline overlays in the source buffer are a losing fight

Every attempt (`before-string`, `after-string`, `cursor-intangible`,
`read-only`, various display properties) produces a class of "text
jumps into / wraps around / merges with the overlay" bugs. The commit
history before W2 has half a dozen "fix cursor near overlay" commits
that never fully worked.

**Rule:** presentation lives in a dedicated side-panel buffer. The
source buffer gets ONE decoration only — a fringe/margin indicator
that carries no buffer text, has no `cursor-intangible` or
`read-only` adjacency to user text, and cannot wrap.

Precedent: **W2** (the whole workstream).

### 16. Fringe display specs are picky

- `(left-fringe BITMAP-SYMBOL)` — needs a real fringe bitmap defined
  via `define-fringe-bitmap`. Passing a string here silently renders
  nothing.
- `((margin left-margin) STRING)` — the correct margin-display form.
  Note the double-nesting: `(margin SIDE)` is a single spec.
- To make margin content visible, the buffer's `left-margin-width`
  must be non-zero (buffer-local; also refresh via
  `set-window-buffer` on any open windows).

Precedent: **W2.12** — the original W2 shipped `((left-fringe "✓N"))`
which is silently invalid. The indicator never rendered until the fix.

### 17. Test the display property structure, not just the state model

If you have a state-transition test that asserts
`(fringe-state cell-key) → 'ok` you may pass while the actual overlay
is invisible. Assert both the state AND
`(get-text-property 0 'display before-string)` shape.

Precedent: `ejn-w2.12-indicator-display-uses-margin-syntax`.

### 18. Cell keys must be stable across buffer edits

`(cons buffer-file-name marker-position)` is a numeric snapshot.
Inserting text above the cell shifts the marker and the "same cell"
gets a different key. Latest-per-cell replacement silently breaks.

**Pattern:** allocate a stable integer ID at first observation, keep
an `id → marker` hash-table, and look up the current line-start
against every stored marker's `marker-position` to find the ID. The
cell key becomes `(cons buffer-file-name ID)` — `equal` across edits
because ID doesn't change.

Precedent: **W2.11** — `--cell-key-for` in `-result.el`.

### 19. Panel state should live on the source buffer, not the panel

The panel is a view; the state is the truth. If panel state lives on
the panel buffer, killing the panel throws away the history — the
W2.5 "image survives panel kill/reopen" contract can't be honored.

We DEFERRED this in W2 (still panel-buffer-local); worth noting for a
future workstream. When the refactor happens, `--entries`,
`--next-id`, and the render scheduler move to the source buffer's
`defvar-local`s.

---

## Non-blocking completion

### 20. capf return time is the load-bearing property

Frontends (corfu, company, completion-in-region) call
`completion-at-point-functions` as part of `post-command-hook`. If your
capf blocks for more than a few milliseconds, editing stutters. The
W3.4 ERT — `capf must return in <5ms even when the adapter is
`(sleep-for 10)` — is the acceptance bar.

**Pattern:** capf checks a bounded LRU cache and returns immediately.
The cache key is `(point . line-up-to-point)`. Cache miss → schedule
an idle-timer'd async request; return `nil`. When the reply lands, the
next keystroke retriggers capf, which now finds cached candidates.

Precedent: **W3.1-W3.4** in `emacs-jupyter-notebook.el` completion
section.

### 21. Refresh-the-popup-programmatically is a trap

Corfu has no cross-version stable API to force a re-fetch of capf
candidates from a live popup. The original W3.5 called `corfu--exhibit`
which redisplays state but doesn't refresh. The clean answer is: don't
try. The next user keystroke naturally re-triggers capf and the popup
sees the cache. Company DOES expose `company-manual-begin`; use it
when no popup is open.

Precedent: **W3.7(c)**.

### 22. In-flight invalidation checks the current context

Point moves and buffer edits between "request sent" and "reply
arrives" mean the reply's `key` may no longer match the buffer's
current capf context. Cache the reply only when the current context
still matches the request's key. Otherwise drop; the stale-context
cache write is a subtle correctness bug.

Precedent: **W3.7(b)**.

### 23. Buffer-local vars in timer closures need explicit capture

`run-with-timer` fires in whatever buffer is current at fire time, not
the buffer that armed the timer. Always:

```elisp
(let ((buffer (current-buffer)))
  (run-with-timer
   ... nil
   (lambda ()
     (when (buffer-live-p buffer)
       (with-current-buffer buffer
         ...)))))
```

Precedent: **W3.7(a)** — completion idle timer fired in wrong buffer
and mutated the wrong `--completion-pending-key`.

---

## Adapter pattern for emacs-jupyter

### 24. Function-var indirection is the mockability seam

Every call into `emacs-jupyter` routes through a `defvar`:

```
emacs-jupyter-notebook-jupyter-connect-function
emacs-jupyter-notebook-jupyter-connect-async-function
emacs-jupyter-notebook-jupyter-evaluate-function
emacs-jupyter-notebook-jupyter-interrupt-function
emacs-jupyter-notebook-jupyter-restart-function
emacs-jupyter-notebook-jupyter-shutdown-function
emacs-jupyter-notebook-jupyter-complete-function
emacs-jupyter-notebook-jupyter-inspect-function
emacs-jupyter-notebook-jupyter-is-complete-function
emacs-jupyter-notebook-jupyter-kernel-info-function  ; added in W4.5
```

Tests `cl-letf` the var, not the underlying `jupyter-*` function.
Anyone adding new adapter surfaces MUST follow this pattern. Direct
calls to `jupyter-*` from `emacs-jupyter-notebook.el` are a design
regression.

### 25. Callbacks per Jupyter message type

`--callbacks BUFFER ENTRY-HANDLE [CLIENT REQUEST-ID]` returns an alist
keyed by Jupyter message-type string:
`input_request, clear_output, stream, execute_result, display_data,
update_display_data, error, execute_reply, status`. Each callback
takes one `msg` argument.

Two conventions worth preserving:

- Every callback body is wrapped in `condition-case nil ... (error nil)`
  so a bad callback can't wedge the whole subscription.
- Callbacks that mutate buffer-local state check
  `(buffer-live-p buffer)` and `(with-current-buffer buffer ...)` even
  though they were subscribed on that buffer — the buffer may have
  been killed between subscribe and dispatch.

---

## Test discipline

### 26. Adapter var stubs are the primary mocking tool

Never `require 'jupyter` from a unit test. The dependency is real at
runtime but the test loads `-jupyter.el` which only `require`s
`emacs-jupyter` lazily via `--ensure`. Stubbing the adapter vars means
tests run in a few seconds without any Jupyter installation.

### 27. `cl-letf` around internal helpers can hide bugs

The classic anti-pattern: a test stubs `--async-kill-remote-kernel` to
verify a leak assertion, but the real bug is that
`--async-kill-remote-kernel` is called AT ALL from that path. The stub
masks the binding-rule violation.

**Pattern:** when a test needs to stub a helper to isolate the
assertion, ALSO assert-not-called on the same helper. If the stub
existed to prevent side effects, the fact that it was called at all
is worth an explicit `should-not`.

Precedent: **W1.8** required removing the `--async-kill-remote-kernel`
stubs from W1.3/W1.6 tests and adding a positive
"did-not-call" assertion.

### 28. `:expected-result :failed` markers must be scoped narrowly

A single `:expected-result :failed` on a big test hides regressions on
the assertions that ARE working. If test T has 5 asserts and one is
known-broken, split T into T-happy (asserts 1-4) and T-known-broken
(assert 5, xfailed). Regressions in 1-4 will now surface.

Precedent: **W7.6(a)** — the W7.2 test had this exact shape and
covered up potential regressions in retry counting.

### 29. Static scans must strip comments and docstrings

Text scans of source files (like the no-TRAMP check) that regex the
raw bytes will false-positive on any reasonable prose mentioning the
forbidden term. Strip Emacs-Lisp line comments (`;...\n`) and string
literals before scanning. See `--strip-lisp-comments-and-strings` in
the tests for a reusable implementation.

Precedent: **W7.6(b)**.

### 30. Batch-mode UI testing

The panel buffer, mode-line function, and status buffer can all be
tested in batch mode: construct the buffer, insert content via the
API, and query the resulting text or overlay properties. No display
required. The exception is anything that depends on a live window
(margin width, scroll position), which needs a mock frame.

---

## Emacs elisp footguns

### 31. `defvar-local` for anything read from timer/hook callbacks

Every buffer-local variable declared with plain `defvar` and set with
`setq-local` behaves differently from `defvar-local` when a function
is called on a fresh buffer. Use `defvar-local` for anything that has
a buffer-local semantic — it forces the correct default and ensures
`kill-local-variable` cleans it up.

### 32. `add-hook` symmetric to `remove-hook`

Every `add-hook` in mode-enable needs the matching `remove-hook` in
mode-disable. `kill-buffer-hook` needs `t` for buffer-local. Missing
this leaves the hook fired on unrelated buffers after mode-disable.

### 33. Timer buffer capture (again, because it bites hard)

Every `run-with-timer`, `run-at-time`, `run-with-idle-timer` lambda
needs `(let ((buffer (current-buffer))) ... (with-current-buffer
buffer ...))`. Two independent sites had this bug (W3.7, W4.8);
assume every new timer has it until proven otherwise.

### 34. `condition-case` granularity

One big `condition-case` around a chain of disposers hides errors and
skips downstream cleanup. Wrap each disposer independently in
`ignore-errors` (or a per-call `condition-case`). The final
state-clearing `setq` at the bottom always runs.

Precedent: **W1.10**.

### capf return shape ≠ `completion-in-region` arg list

`completion-at-point-functions` return `(START END COLLECTION . PROPS)`
where PROPS is a plist including `:exclusive`, `:annotation-function`,
`:company-doc-buffer`, etc. That's a valid list — the plist keys are
just the 4th+ elements. `completion-in-region`, however, accepts only
3-4 positional args (`START END COLLECTION [PREDICATE]`), so passing
the full capf list via `(apply #'completion-in-region result)` throws
"wrong number of arguments (5)". Strip the metadata via `(seq-take
result 3)` before applying. Bit us on `complete-at-point`; test
`ejn-complete-at-point-strips-capf-metadata-before-calling-completion-in-region`.

### IPython display formatters get wiped by the matplotlib inline backend

If you inject a custom IPython display formatter for a type via
`formatters[mime].for_type(...)` / `for_type_by_name(...)`, matplotlib's
**inline backend reconfigures IPython's display formatters on the first
plot** and clears per-type registrations. After that, `BaseFormatter`
falls back to `print_method='__repr__'`, so your custom MIME silently
carries the object's `repr()` instead of your intended payload — no
error, just wrong data downstream. Proven live: the registration is
present (`deferred_printers` has 1 entry) right up until the first
`plt.subplots()`, then it's `0`.

**Fix:** don't use the display-formatter registry for this. Patch a
`_repr_mimebundle_` method onto the *class* (e.g.
`matplotlib.figure.Figure._repr_mimebundle_`) — a class method is not
touched by the inline reconfiguration, chains cleanly to any existing
bundle, and always runs. Patch eagerly when the module is importable and
re-assert via a `pre_run_cell` event hook for late imports.

**The QC lesson (this shipped a broken W8):** a formatter/display snippet
MUST be tested against a real `ipykernel` **with the inline backend
active** — not a bare `IPython.core.interactiveshell.InteractiveShell`,
which is the one environment where the broken approach works. Mocking the
MIME payload in ERTs and running the snippet in a plain shell both gave
false greens. The regression guard is `viewer/test_formatter_kernel.py`:
it spins a real kernel via `jupyter_client`, injects the snippet, runs the
single-cell import+plot+return worst case, and asserts the emitted MIME
base64-decodes and unpickles. Any kernel-side "emit a custom MIME"
feature needs a test at that altitude.

### Evil visual state deactivates the region before command dispatch

`(interactive "r")` reads `region-beginning` / `region-end` at
dispatch time. Evil's visual state sometimes leaves the region
inactive by the time the interactive form runs (e.g. when a command
was bound in a non-visual keymap and Evil switches back to normal
state before executing), and the interactive form raises "The mark
is not set now, so there is no region". Evil exposes
`evil-visual-beginning` / `evil-visual-end` markers that survive the
state exit; prefer those in the interactive form, then fall back to
`use-region-p`. See `--region-bounds` and tests
`ejn-send-region-bounds-uses-evil-visual-markers` /
`-uses-standard-region` / `-signals-when-no-region`.

### 35. `plist-put` is destructive on some plists

`plist-put` may return a modified list that shares structure with the
input; may also return a different list. Always use the return value
and reassign: `(setq context (plist-put context :key value))`. Never
rely on the input being modified in place.

---

## Working with subagents on this codebase

### 36. Every workstream needs a review + remediation pass

Zero exceptions across W1-W7. Every workstream had at least one real
bug the reviewer caught (typically CRITICAL or HIGH). Budget for this
up front — the pattern is:

1. Fire Claude subagent (worktree isolation) to implement.
2. When it reports done, verify the diff + run tests.
3. Run opencode as reviewer with a strict prompt referencing the row
   contracts and binding rules.
4. Address findings in a `Wn.k+1` remediation row (usually
   in-the-worktree, not another subagent).
5. Re-run opencode after remediation to verify.
6. Merge.

Skipping step 3 leaves latent bugs. The reviewer catches things a
same-context implementer is invested in not seeing.

### 37. Sandbox surprises

Subagents in `isolation: "worktree"` sometimes cannot write files —
the harness sandbox blocks paths outside the worktree, and edit/write
tools can silently fail. Fallback: I take over the worktree directly
(cd + edit + commit). This worked for W1 remediation, W2 fixup, W4
takeover, and W5-W7 remediation passes.

### 38. Opencode is cheap and effective as a reviewer

Configure it in `.opencode/opencode.jsonc`:

```jsonc
{
  "agent": {
    "build": {
      "model": "openai/gpt-5.5",
      "variant": "xhigh"
    }
  }
}
```

The `build` agent is what `opencode run "..."` uses. Higher-tier
models catch more subtle bugs (e.g., gpt-5.5-xhigh flagged the W7.6
xfail granularity issue that a lower-tier reviewer missed).

Two review-prompt patterns worked well:

- "Confirm each of these prior findings is now RESOLVED /
  NOT-RESOLVED / DEFERRED-WITH-DOC with file:line justification."
  Fast pass on a remediation pass.
- "Check for hard-rule violations, contract slippage per row, race
  conditions. Bullet list prefixed CRITICAL/HIGH/MEDIUM/LOW. Skip
  looks-good. Under N words." Fresh review of a new diff.

### 39. Don't `find -delete` .elc files

The harness prohibits `find ... -delete`. Stale `.elc` files rarely
matter inside a fresh worktree; skip the cleanup and re-run tests
directly. If you must, `rm *.elc tests/*.elc` works from a specific
directory.

### 40. Elisp inside a tool-call string

When I wrote elisp code inside my own Write/Edit tool calls, I
sometimes escaped quotes JSON-style (`\"`, `\\n`) — those characters
end up in the file as literal `\"` and break the parse. Elisp string
literals inside tool calls need the OUTER escape only.
`Write(content: "(message \"hi\")")` writes `(message "hi")` — the
`\"` is only for the JSON transport, not the elisp.

Precedent: bit me twice writing tests during W7.6 remediation.

---

## What we deferred and why

Recorded here so a future workstream doesn't rediscover the trade-off.

- **Multi-buffer sharing of a single kernel.** Design decision
  2026-06-28. Requires registry refcount + kill-buffer-hook rework.
  Out of scope until user demand exists.
- **Panel state survives panel kill/reopen (W2.5 contract).** Needs
  panel state relocated to source buffer defvar-locals. Substantial
  refactor of `-result.el`.
- **Interactive image zoom for medical imaging.** Requires custom
  matplotlib backend + Emacs image transform. Documented in ROADMAP
  future workstreams.
- **W6 log buffer wiring for W5 timeout messages.** W5.2 currently
  emits `message` as a stand-in; W6.6 shipped a log buffer but the W5
  timeout path was not retro-wired. Small follow-up.
- **CC1 SCP retry buffer leak.** Documented in ROADMAP cross-cutting.
  The W7.2 leak assertion is `:expected-result :failed` pending the
  fix. One-line fix in `--async-retrieve-attempt`.

---

## When in doubt

Two questions to check any new async / kernel code against:

1. **What happens if this callback arrives 30 seconds late in a killed
   buffer with a superseded request-id?** If the answer is not
   "silently drops without side effects," you have a bug.
2. **What happens if this code path fires when the tunnel is silently
   broken but the SSH process still appears alive?** If the answer is
   not "the heartbeat catches it within N seconds and sets
   `--tunnel-dead`," you're relying on the sentinel alone and should
   fix that.
