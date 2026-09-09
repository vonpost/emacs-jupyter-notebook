# Emacs responsiveness review — 2026-09-09

The reported incident starts after local Nix bootstrap, before a successful
kernel connection. The registered kernel is dead. Both M-x and M-: become
unresponsive; repeated C-g recovers editing. The exact incident is not yet
attributed: a backtrace from the affected Emacs is needed. Live kernel output,
variable inspection and kernel completion do not explain a session that has
never connected.

The user subsequently reported a stack containing `completing-read-default`,
`read-extended-command-1` and Vertico's advice. Disabling Vertico did not fix
the incident. An isolated, healthy terminal Emacs running Vertico produced
the same stack shape while normally awaiting M-x input: the anonymous lambda
can be the completion-table argument, not an executing frame. This trace does
not identify a blocking EJN or Vertico function.

The review covered runtime bootstrap, registry and SSH lifecycle callbacks,
helper framing and writes, completion and prompt delivery, variable Eldoc,
cell tracking, panel rendering, native preview scaling and artifact cleanup.
No remote host was needed for the regressions.

## Findings and fixes

| Risk | Trigger and consequence | Fix |
| --- | --- | --- |
| Input from an asynchronous callback | Registry selection, dead-kernel recovery or missing-host input can enter a prompt after startup, while another minibuffer owns input. | Defer the interaction until the originating buffer is selected and the minibuffer is free. Recheck operation identity. Remove the pending prompt before reading, so quitting cannot repeat it. |
| Late completion and array selection | A completion reply can invoke Consult/Company in a different window; metadata replies can prompt for axes from inside a helper drain. | Cache completion immediately but defer foreground presentation; drop a stale popup. Explicit array selectors use the same guarded prompt scheduler. Kernel stdin also waits for its source buffer. |
| Blocking local writes | `process-send-string` waits for a non-reading child, even when the caller is an otherwise asynchronous timer. Other timers may run while keyboard dispatch remains blocked. | A 50 ms write watchdog retires only the local process on a stalled or interrupted partial write. Reentrant writes cannot interleave frames. Registry attempt deadlines are armed before delivery. No ambiguous bytes are replayed. |
| Broken decoder yield | Two legal large frames cross the per-turn byte budget; `cl-return` in an ordinary `while` makes an invalid nonlocal exit. | Express the yield in the loop condition and resume the partial frame normally. Helper drain/decode/stderr continuations use a positive delay. Protocol limits are unchanged. |
| Growing work on source navigation | Following output created identities for every cell merely visited and repeatedly rescanned unchanged cells. | Source following only looks up existing identities; unchanged cell bounds are cached. Above 1 MiB of source characters, automatic following and edited-label rescans are skipped. Explicit commands and exact boundary-deletion retirement remain available. |
| Unbounded automatic identifier inspection | A long token is scanned/copied, or a cold syntax parser walks a large source, before rejecting an oversized variable name. | Bound the name scan before parsing/copying and skip automatic name detection above 1 MiB of source characters. Explicit named inspection remains available. |
| Excessive native image work | Repeated zoom increases native dimensions and synchronous image slice rows without a limit. | Bound scaled preview dimensions and slice counts at both zoom and native presentation boundaries. Full resolution remains available through the external viewer. |
| Expensive output redisplay | A long retained output line repeatedly wraps and runs bidirectional layout during window/minibuffer resizing. | Truncate panel lines and disable bidirectional paragraph analysis in the output panel. Retained text is unchanged. |
| Synchronous startup cleanup | An accumulation of stale artifact directories causes directory enumeration, inode checks and deletion on Emacs's UI thread. | Run the existing capability-checked cleanup in one local batch Emacs child with a hard watchdog. |

The focused tests are in `tests/emacs-jupyter-notebook-*-hang-tests.el`.
Existing interaction tests now select their source window and wait for deferred
presentation, matching the production ownership requirement. The stalled-writer
regressions use real non-reading local children and an independent fallback
deadline; a timer heartbeat alone would miss this class of keyboard blockage.

## Capturing the reported incident

Enable `(setq debug-on-quit t)` before reproducing the hang, then press C-g.
If the minibuffer itself is unusable, evaluate the setting with C-x C-e from
an ordinary buffer, preferably scratch. In Evil, use insert or Emacs state.
If repeated C-g dismisses the debugger window, evaluate
`(pop-to-buffer "*Backtrace*")` the same way and retain the stack starting at
`Debugger entered`. Turn off the diagnostic afterwards with
`(setq debug-on-quit nil)`.

These fixes bound identified package work. They cannot guarantee that unrelated
Emacs packages, native redisplay, the operating system, or a stalled filesystem
never blocks. In particular, normal local file metadata operations still run
in Emacs, and evaluated-cell edit tracking scales with tracked source cells.

## Verification

- Strict byte compilation of all project Elisp passed, with warnings treated
  as errors. Two missing declarations for optional Evil markers were added.
  Generated `.elc` files were deleted before the final source-based run.
- `EJN_TEST_TIMEOUT=60 tests/run-local-tests.sh`: 1067/1067 ERT passed;
  array protocol 4/4, helper 248 tests with 4 optional dependency skips,
  registry 25/25, and stress-fixture unit tests 12/12 passed.
- Four existing AG3 subprocess stress tests passed: credited output flood,
  every-phase process exits, late ping and hostile helper framing. The flood
  delivered 14,916 events, two pings and 117 independent timer ticks, with
  bounded queues/raw buffers. A 10 ms continuation experiment failed the
  existing ping-latency gate; the shipped 1 ms continuation passed.
- Real local child-pruning smoke removed an isolated stale artifact tree and
  retired its process/watchdog. Three agents reviewed disjoint areas and the
  shared prompt/write changes; the manager reviewed the combined diff.

The AG3 subset used existing fixture subprocesses, without a real kernel or
remote host:

```sh
timeout 40 env EJN_AG3_METRICS=/tmp/ejn-transport-stress-final.json \
  emacs -Q --batch -L . -L tests -L tests/stress -L "$CODE_CELLS_DIR" \
  -l tests/stress/emacs-jupyter-notebook-stress.el \
  -l tests/stress/emacs-jupyter-notebook-lifecycle-stress.el \
  --eval '(setq ejn-ag3--started-at (float-time))' \
  --eval '(ert-run-tests-batch-and-exit "ejn-ag3-\\(credited\\|lifecycle\\|th1\\)")'
```

This was a focused diagnostic run, not the full five-repeat AG3 release gate.
No Nix rebuild or remote-kernel operation was performed for this review.
