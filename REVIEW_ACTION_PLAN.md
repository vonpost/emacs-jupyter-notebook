# REVIEW_ACTION_PLAN.md

Action plan from the 2026-07-09 whole-repo review. Purpose of the repo:
a single-user Emacs environment for developing computer-vision / ML models
against **high-latency GPU remotes** with minimal friction. Findings are
ranked by how much they bite that workflow, not by abstract severity.

Legend: `[ ]` pending · `[x]` done · `[~]` deferred to a follow-up workstream.
Each item lists the defect, the file:line anchor, and the mitigation.

## Execution status (landed 2026-07-09)

All Tier 1/2/4 items below are implemented with ERT coverage; the full
source-based suite is green (425 tests, 0 unexpected, 1 pre-existing CC1
expected-failure) and byte-compile is clean bar the pre-existing evil-mode
free-variable warning.

- [x] A1 pkill double-quoting + self-exclusion
- [x] A2 sentinel context-identity guards (`--async-context-live-p`)
- [x] A3 SSH ControlMaster multiplexing (tunnel opts out)
- [x] A4 SSH ConnectTimeout (default) + BatchMode (opt-in)
- [x] A5 panel pickle-retention cap
- [x] A6 registry corrupt-backup guard
- [x] A7 hygiene: viewer socket 0600, `.gitignore`, README (tk default,
  missing commands, ProxyJump + Docker + non-login-shell notes), dead
  `use-detached` removed, `retry-fresh-kernel` docstring corrected
- [x] A8 surface the remote launch log on retrieve timeout
- [x] A9 viewer script resolution under straight.el/elpa builds

Discovered live during execution while the user debugged a fresh macOS +
Docker + straight.el host: A8 (log never surfaced), A9 (viewer script not
found through the build symlink), plus the Docker `docker run` recipe now in
the README (no `-t`, bind-mount cache dir, `--network host`, never `-d`).
The Tier 3 items remain deferred to W13.

---

## Tier 1 — bugs that bite in normal use (EXECUTE NOW)

### A1 — `clean-orphaned-kernels` / `list-remote-processes` kill/match nothing under the default config
- [x] **Defect.** `ssh.el` builds the pkill/grep pattern by wrapping an
  already-home-expanded cache dir (`$HOME/.cache/...`) in a *second*
  `shell-quote-argument`, which escapes the `$`. Verified emitted command:
  `pkill -f KernelManager.connection_file\=\$HOME/.cache/.../kernel-` — the
  remote shell keeps `$HOME` **literal**, so it never matches the kernel's
  expanded `/home/user/...` argv. The sibling `rm -f $HOME/...` half *is*
  expanded, so `C-c j w` **deletes every connection/log file but kills zero
  kernels** — GPU-holding kernels keep running and are now unfindable. Same
  root cause makes `list-remote-processes` (`C-c j q`) always empty.
  `emacs-jupyter-notebook-ssh.el:269` (`build-remote-cleanup-all`),
  `:258` (`build-remote-ps-command`).
- **Mitigation.** Build the pattern without the outer `shell-quote-argument`
  so `$HOME` stays shell-expandable (matching the per-session
  `build-remote-cleanup`, which already works), and bracket the first pattern
  char (`[K]ernelManager…`) so the running `sh -c` never matches *itself*
  (this also fixes the absolute-cache-dir self-kill, review finding SSH-M4).
- **Tests.** New assertions covering the default `~`-cache path (not just the
  absolute `/tmp/ejn` path the old tests used): the pattern must contain an
  unescaped `$HOME` and a bracketed first char, and must not contain the raw
  self-matching substring.

### A2 — W12 supersede reintroduces an async-context resurrection race
- [x] **Defect.** `--async-delete-process` calls `delete-process` without
  clearing the sentinel, and `--async-scp-sentinel` (unlike the pid-probe
  sentinel) has **no context-identity guard**. When the new W12 flow cancels
  attempt A and starts B in the same buffer, A's killed scp sentinel fires,
  takes the retry path, and `--async-put` writes the dead context A back into
  the buffer's `--async-context`, clobbering B.
  `emacs-jupyter-notebook.el:1800` (`--async-scp-sentinel`),
  `:1732` (launch sentinel), `:1456` (`--async-put`).
- **Mitigation.** Add an early `(eq emacs-jupyter-notebook--async-context
  context)` guard (via the origin buffer) to the scp and launch sentinels, so
  a superseded/cancelled attempt's late sentinel is a no-op. Mirrors the
  existing guard in the pid-probe sentinel.
- **Tests.** A cancelled/superseded context whose scp process is deleted must
  not re-arm a retry timer nor overwrite the current `--async-context`.

### A6 — a corrupt registry silently wipes all reconnect entries
- [x] **Defect.** `registry-load` returns nil on any parse error (warning
  only); the next `save-entry` upserts into nil and atomically writes a
  registry containing only the new entry — every other host's durable
  reconnect surface is gone with no backup.
  `emacs-jupyter-notebook-registry.el:24`, `:82`.
- **Mitigation.** Distinguish *corrupt* from *missing/empty* on load. Before a
  destructive save when the on-disk file is present but unparseable, rename it
  to `registry.el.corrupt-<timestamp>` and warn, so the data is recoverable
  and work still proceeds.
- **Tests.** Corrupt file + `save-entry` → a `.corrupt-*` backup exists and no
  data is silently lost; empty/missing file keeps current behavior.

### A5 — the output panel retains every figure pickle forever (memory leak)
- [x] **Defect.** `panel--entries` is append-only; re-running a cell appends a
  new entry (latest-per-cell only dedupes at render), and each keeps its
  multi-MB base64 `:mpl-pickle`. Re-running one `imshow` cell 200× stashes 200
  pickles that are never freed — Emacs heap grows unbounded in exactly the
  image-heavy CV loop this tool exists for.
  `emacs-jupyter-notebook-result.el:519`, `:603`.
- **Mitigation.** After stashing a pickle, keep the payload only on the newest
  `emacs-jupyter-notebook-panel-max-pickles` entries (new defcustom, default
  20) and nil out older ones. The PNG thumbnail and history text are
  untouched; only the heavy interactive-figure payload is bounded.
- **Tests.** Stashing N+1 pickles leaves exactly N non-nil `:mpl-pickle`
  fields, and the most recent are the ones retained.

---

## Tier 2 — high-latency friction (EXECUTE NOW)

### A3 — no SSH connection multiplexing anywhere (biggest single friction win)
- [x] **Defect.** Every launch / scp poll (up to 40) / probe / cleanup opens a
  fresh TCP+SSH+auth handshake. At 300 ms RTT — worse through a ProxyJump —
  that handshake dominates start latency. No `ControlMaster` in the repo.
- **Mitigation.** Add `-o ControlMaster=auto -o ControlPersist=<n> -o
  ControlPath=<temp>/ejn-%C` to the management/launch/scp commands via a new
  `--control-args` helper, gated by new defcustoms
  (`emacs-jupyter-notebook-ssh-control-master` default t,
  `-control-persist` default "60"). The first command establishes a master
  that subsequent ones ride, collapsing N handshakes to ~1.
  **The persistent tunnel opts OUT** (`-o ControlPath=none`) so it owns its
  own connection and the sentinel-based liveness detection keeps working.
  ProxyJump-safe: nothing here bypasses `~/.ssh/config`, and `%C` hashes the
  final host so multiplexing rides the full jump chain.
- **Tests.** ssh/scp argv include the control opts when enabled and omit them
  when disabled; the tunnel argv carries `ControlPath=none` and never a
  master.

### A8 — surface the launch log on retrieve timeout (real-host diagnostics)
- [x] **Defect.** When the remote `jupyter` fails to start (the #1 real-host
  failure — `jupyter` not on the non-interactive SSH PATH because conda/venv
  init lives in `~/.bashrc`, which `ssh host 'cmd'` does not source), the
  `nohup … &` subshell still prints a PID, so Emacs believes the launch
  succeeded and polls for a connection file that will never appear. The user
  sees `SCP failed: … kernel-<sid>.json: No such file or directory` looping to
  timeout, instead of the launch log's `jupyter: command not found`.
  Reported live during this pass on a fresh GPU host.
  `emacs-jupyter-notebook-ssh.el:185` (launch), `:1767` (retrieve-attempt
  timeout).
- **Mitigation.** On retrieve exhaustion (`--async-retrieve-attempt` hitting
  the attempt cap), fetch the remote launch log (`build-remote-cat-log`) and
  include its tail in the failure surfaced to the user / log buffer, so the
  actual cause is visible without a manual `C-c j v`. README already documents
  `:jupyter-command`; also add an explicit "non-login shell / conda" note.

### A4 — synchronous ssh with no timeout freezes Emacs on an unreachable host
- [x] **Defect.** `ssh-run-command` (management commands) and the launch/scp/
  tunnel argv omit `ConnectTimeout`/`BatchMode`, so a black-holed GPU box
  freezes the UI for the OS TCP timeout (minutes), or hangs forever if ssh
  decides to prompt.  `emacs-jupyter-notebook-ssh.el:355`, `--option-args:70`.
- **Mitigation.** Add `-o ConnectTimeout=<n>` (new defcustom, default 10) and
  `-o BatchMode=<yes|no>` (new defcustom, default yes — single-user key/agent
  auth) to `--option-args` so all ssh/scp handshakes are bounded and never
  block on a prompt. Documented as flip-off-able for password auth.
- **Tests.** argv include `ConnectTimeout`/`BatchMode` by default; disabling
  the defcustoms removes them.

---

## Tier 4 — hardening / hygiene / docs (EXECUTE NOW)

### A7 — low-risk cleanups
- [ ] `.gitignore`: add `__pycache__/` (`viewer/__pycache__/` is untracked).
- [ ] `README.md`: viewer backend default says `qt`; code defaults to `tk`
  (`vars.el:302`). Fix, and add the two omitted bound commands
  (`prune-dead-kernels`, `clear-results`), plus a short **ProxyJump note**
  (use the ssh_config Host alias as `:host`; leave `:port`/`:user`/
  `:identity-file` unset to defer to config).
- [ ] `retry-fresh-kernel` docstring says the old kernel "is left running" but
  it is intentionally killed (ROADMAP W6.4 lists it as an allowed
  terminator). Fix the docstring to match the code
  (`emacs-jupyter-notebook.el:2757`).
- [ ] Viewer unix socket: `os.chmod(path, 0o600)` after bind, so the
  pickle-load endpoint is owner-only regardless of ambient umask
  (`viewer/ejn_viewer.py:423`).
- [ ] Remove the dead `emacs-jupyter-notebook-use-detached` defcustom
  (referenced nowhere) (`vars.el:72`).

### A9 — the interactive viewer script is not found under straight.el / elpa
- [x] **Defect.** `--script-path' resolved `viewer/ejn_viewer.py' beside the
  LOADED file, which under straight.el/elpa is the byte-compiled `.elc' in a
  build directory into which only the `.el' files are symlinked — the
  `viewer/' Python tree lives only in the source repo. Result on a fresh
  install: "Viewer script not found (expected viewer/ejn_viewer.py beside the
  package)" even though the `.py' is present in the repo.
  Reported live on a fresh macOS + use-package!/straight host.
  `emacs-jupyter-notebook-viewer.el:71`.
- **Mitigation.** Resolve the script beside this file AND beside the
  `file-truename' of its `.el' source, so following the build→repo symlink
  reaches the `viewer/' tree. Works for a plain checkout and a
  straight/elpa build alike.

---

## W13 — LANDED (was deferred; see ROADMAP W13)

All of the below shipped with deterministic ERT coverage (433 tests green,
byte-compile clean).  Two extra dogfooding fixes landed alongside: the macOS
`ControlPath` length regression and the reconnect probe no longer reporting a
live kernel as dead on an ssh/infra failure.

- [x] **H2 — parallel reconnects.** The tunnel-dead branch in
  `--ensure-client-async` runs before the async-in-progress check, so a second
  send during reconnect spins up a duplicate context/tunnel.
  `emacs-jupyter-notebook.el:2069`.
- [x] **H3 — ghost attempt kills the live one.** `--async-connect-finalize`/
  `-timeout` guard on *phase*, not context identity; a superseded attempt's
  uncancellable connect closure can `--async-fail` the healthy new attempt.
  Same class as A2, but on the connect path. `:1878`.
- [x] **M1 — silent wedge.** After a failed start that reached the tunnel
  phase, the deferred death-sentinel re-sets `--tunnel-dead t` post-cleanup and
  `send-cell` then silently no-ops forever. `:1409`, `:1992`.
- [x] **M2 — fringe stuck "running".** Two quick sends: cell A's
  `execute_reply` is dropped by the request-id gate, so its spinner never
  finishes. `emacs-jupyter-notebook-jupyter.el:249`.
- [x] **Viewer-3 — restart re-injection race.** The formatter/watchdog
  injection runs synchronously against a kernel mid-relaunch, so figures can
  silently stop carrying the pickle payload until a full reconnect.
  `emacs-jupyter-notebook.el:2734`.
- [~] **#7 — reconnect chooser blocks** on sequential per-host liveness probes
  before showing. Needs async probing. `:1320`.
- [~] **#8 — 45 s synchronous connect** blocks Emacs (inherent to
  emacs-jupyter's synchronous client). Tunable; consider lowering the default.
- [~] **Viewer large-figure decode** runs `pickle.load` on the GUI tick;
  hundreds-of-MB figures stall hover/zoom. Move decode off the event tick.
- [~] Assorted L-items: leaked cleanup-ssh buffers, heartbeat timer surviving
  shutdown, dead `catch 'timeout` branch, one-shot completion idle timer.

---

## Verification protocol

After each change group: byte-compile clean (only the known evil-mode
free-var warning is acceptable) and the full source-based ERT suite green
(`emacs -Q --batch -L . -L tests -L <code-cells> -l tests/…-tests.el -f
ert-run-tests-batch-and-exit`). Remove any generated `.elc` before diff.
