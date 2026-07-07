# AGENTS.md

## Project Goal

Build an Emacs extension for working with Jupyter kernels running on remote systems from local source files.

The extension should let users edit ordinary local source files, evaluate code cells against a remote Jupyter kernel, display rich outputs inline in Emacs, and reconnect to kernels after Emacs restarts.

## Hard Constraints

- Do not use TRAMP.
- Do not use `jupyter-tramp`.
- Do not open remote files through Emacs remote file handlers.
- Do not make kernel lifetime depend on Emacs lifetime.
- Do not write execution results into source files.
- Keep source files normal and clean.

Remote interaction must happen through external processes such as `ssh`, `scp`, `rsync`, or equivalent command invocations. Emacs should talk to Jupyter over local forwarded ports.

## Architecture

Use `emacs-jupyter` for Jupyter protocol/client behavior, MIME rendering helpers, and kernel messaging where practical.

Use `code-cells` style cell markers for source buffers. Python v1 should support `# %%` cells.

Use overlays or dedicated result buffers for outputs. Results must be attached to buffer positions without modifying the visited source file.

Remote kernel management should work like this:

1. Emacs starts an external SSH command.
2. The remote side launches a Jupyter kernelspec in a detached way.
3. The remote side writes or reports a Jupyter connection file.
4. Emacs retrieves connection metadata without TRAMP.
5. Emacs starts local SSH port forwards for the Jupyter channels.
6. `emacs-jupyter` connects to `127.0.0.1` using the rewritten local ports.

## Reconnect Model

Reconnect must not depend on `detached.el`.

Maintain a local registry under `user-emacs-directory` containing enough metadata to reconnect:

- profile name
- remote host
- remote cwd
- kernelspec
- remote connection file path
- remote pid if known
- creation time
- last known tunnel ports
- display name or session id

`detached.el` may be used as an optional launch/logging adapter, but the registry is the durable source of truth.

## Expected User Features

Provide commands for:

- enabling the minor mode
- starting a remote kernel
- reconnecting to an existing remote kernel
- evaluating current cell
- evaluating region
- evaluating buffer
- interrupting kernel
- restarting kernel
- shutting down kernel
- clearing result overlays

The first implementation target is Python. Design the language mapping so more Jupyter kernels can be added later.

## Customization

Expose user options for:

- remote profiles
- default profile
- SSH command and options
- remote working directory
- remote cache directory
- default kernelspec
- whether to use `detached.el` when available
- registry file path
- result display sizing
- image display sizing

## Testing Expectations

Add ERT tests for behavior that does not require a real remote host:

- cell boundary detection
- registry serialization/deserialization
- connection plist port rewriting
- SSH command construction
- result overlay creation and cleanup
- guarantee that evaluation and result rendering do not mutate source text

For remote behavior, structure code so SSH/process execution can be mocked.

## Agent Workflow

- Prefer delegating bounded research, test design, failure fixing, and review tasks to subagents.
- Tell subagents whether they may edit files or only inspect the tree.
- Keep subagent prompts focused on one concern, such as registry behavior, SSH command construction, or emacs-jupyter adapter integration.
- Avoid assigning parallel editing tasks to the same file. If unavoidable, inspect the combined result carefully before running tests.
- Ask subagents to report verification commands run, files changed, and remaining risks.
- Treat subagent results as input for manager review, not as automatically final. Re-read the changed code and check for syntax, style, and integration issues.
- Prefer manager/critic behavior for broad changes: delegate bounded implementation or review, then integrate, verify, and decide.
- Do not ask subagents to use or require a real remote host for normal unit tests.
- Keep deterministic ERT tests independent of `emacs-jupyter`, Jupyter itself, SSH connectivity, and remote hosts.
- Use `mother` or `mother.lan` only for optional remote smoke tests when explicitly useful.
- After byte-compilation checks, remove generated `.elc` files before status/diff review.
- Re-run the canonical source-based local ERT command after deleting stale byte-code artifacts, because stale `.elc` files can hide source changes.
- Do not commit generated artifacts such as `.elc` files, transient connection JSON files, local registry files, or `.opencode/` tooling data.
- Before committing, inspect status, diff, and recent log; stage only intended project files.

## Learnings

Read `LEARNINGS.md` before starting any workstream that touches the async
pipeline, the Jupyter adapter, the panel, or the display layer. It captures
concrete lessons (with file:line and workstream-row references) from
landing W1–W7, and answers common footguns before you have to hit them.

## Binding Design Rules

These rules supersede anything older in this document. The full and current
list lives under `## Design decisions` in `ROADMAP.md`; the entries below are
the load-bearing constraints every agent must respect.

- No backwards compatibility. The package is not in external use; prefer the
  better shape over a compat shim. Do not add deprecation aliases.
- The remote kernel outlives Emacs. Only the explicit user commands
  `emacs-jupyter-notebook-shutdown-kernel`,
  `emacs-jupyter-notebook-clean-orphaned-kernels`, and
  `emacs-jupyter-notebook-retry-fresh-kernel` may terminate it.
  `retry-fresh-kernel` is included because its whole purpose is to replace
  the current kernel with a fresh one; it is an explicit user gesture
  guarded by `y-or-n-p` (W6.4). No automatic cleanup from
  `kill-buffer-hook`, `kill-emacs-hook`, mode-disable, or async failure
  paths. W11 exception (user-approved): each kernel also carries an
  injected in-memory idle watchdog that self-reaps the kernel after
  `emacs-jupyter-notebook-kernel-idle-timeout` of inactivity (never while
  busy). `emacs-jupyter-notebook-prune-dead-kernels` only removes registry
  entries for confirmed-dead kernels and never kills a live one.
- Single buffer per kernel for now. Multi-buffer sharing of a single remote
  kernel is out of scope until explicitly opened by a future workstream.
- The registry is the durable truth. Local state may be freely torn down; the
  registry entry and the remote connection file must not be touched on buffer
  kill, mode disable, or Emacs exit.
- The source buffer stays clean. Evaluation output is rendered in a dedicated
  side-panel buffer, not in the source. The only permitted source-side
  decoration is a fringe/margin indicator that carries no buffer text, has no
  `cursor-intangible` or `read-only` adjacency to user text, and cannot
  interfere with editing. Inline result overlays are removed.
- Cells are the primary eval unit; region/paragraph/defun are secondary.
  Latest-per-cell output replacement is keyed by cell marker position. Output
  produced by region/paragraph/defun goes only to the history-log view.
- Async is the rule, not the exception. No code path a user can hit during
  ordinary editing may block the UI. Initial first-time start may be slow on
  high-latency links but must remain non-blocking.

## Roadmap

The active work plan is tracked in `ROADMAP.md` as six workstreams (W1–W6)
with a claim/done protocol so multiple agents can land changes in parallel
without colliding. Read `ROADMAP.md` before starting any task. The bootstrap
phase (initial async start, reconnect, SSH tunnels, SCP retrieval, registry
persistence, connection-file rewriting, file-associated sessions, cell
evaluation, overlay rendering) is complete; everything else lives in
`ROADMAP.md`.

Jupyter runtime niceties (richer MIME rendering beyond text and PNG/JPEG,
runtime completion polish, inspect-at-point polish, code-completeness checks,
stdin prompts polish, watch values via `user_expressions`) remain a future
workstream after W1–W6 are done.
