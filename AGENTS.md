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
- Ask subagents to report verification commands run, files changed, and remaining risks.
- Do not ask subagents to use or require a real remote host for normal unit tests.
- Keep deterministic ERT tests independent of `emacs-jupyter`, Jupyter itself, SSH connectivity, and remote hosts.
- Use `mother` or `mother.lan` only for optional remote smoke tests when explicitly useful.
- Do not commit generated artifacts such as `.elc` files, transient connection JSON files, local registry files, or `.opencode/` tooling data.
- Before committing, inspect status, diff, and recent log; stage only intended project files.
