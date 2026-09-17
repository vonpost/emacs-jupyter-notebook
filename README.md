# emacs-jupyter-notebook

Edit normal local source files and run `# %%` cells on a persistent remote Jupyter kernel.

This gives the useful parts of Jupyter notebooks: cells, rich inline output, kernel state, completion, inspect, interrupts, restarts, and reconnects. It avoids the bad parts: no `.ipynb` JSON, no hidden source/output merge conflicts, no browser editor, and no results written into source files.

## Why

The source file stays an ordinary Python file. Your normal Emacs, Git, LSP, linting, formatting, search, and review workflows keep working.

The kernel can live on another machine. Emacs starts or reconnects to it through external `ssh`/`scp` commands and local port forwards. It does not use TRAMP, and the kernel does not die just because Emacs exits.

## Doom Emacs Installation

Add the package and its bundled runtime sources to `packages.el`:

```elisp
(package! code-cells)
(package! emacs-jupyter-notebook
  :recipe (:host github
           :repo "vonpost/emacs-jupyter-notebook"
           :files ("*.el" "viewer" "helper" "registry_worker" "array_protocol"
                   "flake.nix" "flake.lock")))
```

Then configure and enable it from `config.el`:

```elisp
(use-package! emacs-jupyter-notebook
  :hook (python-mode . emacs-jupyter-notebook-mode)
  :init
  (setq emacs-jupyter-notebook-default-profile "workstation"
        emacs-jupyter-notebook-remote-profiles
        '(("workstation"
           :host "user@example.org"
           :remote-cwd "~/project"
           :kernelspec "python3"))))
```

Run `doom sync` after changing `packages.el`.  There is no separate helper
installation step.  On the first start, reconnect, or send that needs the
local runtime, EJN finds Nix and builds the repository's pinned `.#default`
closure in a background process.  The mode line shows `EJN…build`; `C-c j x`
cancels the caller.  Multiple EJN buffers share one build.

Sampled Nix progress also appears in `*Messages*` and the bounded EJN log
(`C-c j L`).  Doom's default modeline hides ordinary minor-mode lighters, so
it will not show `EJN…build` unless your modeline is configured to render
`minor-mode-alist`; use `*Messages*`, `C-c j L`, or `C-c j ?` as the portable
progress indicators.

The flake supports `x86_64-linux` and `aarch64-darwin`.  GUI Emacs does not
always inherit the login shell's PATH on macOS, so EJN also checks the standard
Nix profile and Homebrew locations directly.  A first build may download
substitutes, but Emacs remains responsive and subsequent builds reuse the Nix
store.

The automatic `.#default` runtime build does not run the development test
suites.  Maintainers run those explicitly with `nix flake check`.

## Basic Use

Write Python cells with `# %%` markers:

```python
# %% setup
import numpy as np

# %% work
np.arange(5) ** 2
```

Enable the mode in a Python buffer:

```elisp
M-x emacs-jupyter-notebook-mode
```

Enabling the mode again is safe. If `code-cells-mode` was already enabled,
EJN preserves it when notebook mode is disabled.

Send the current cell:

```elisp
C-c j c
```

If no kernel is connected, the first send announces which profile it will use ("starting kernel via profile <name> (C-u to choose)") and then launches that kernel asynchronously. The send queues; output streams into the side panel as soon as the kernel connects. `C-u C-c j c` prompts for a profile to start with instead.

The source buffer remembers the profile selected by `start-remote-kernel` or a prefixed
cell evaluation, including when startup fails. Later cell, region, and buffer
evaluations retry that profile. The global default applies until you make a
choice in that buffer; an existing registered session still reconnects to its
recorded kernel.

## Minimal Configuration

```elisp
(require 'emacs-jupyter-notebook)

(setq emacs-jupyter-notebook-default-profile "workstation")

(setq emacs-jupyter-notebook-remote-profiles
      '(("workstation"
         :host "user@example.org"
         :remote-cwd "~/project"
         :kernelspec "python3")))
```

Profiles default to `:launcher direct`: EJN launches the kernel directly on
the SSH host. You can spell out `:launcher direct`, but ordinary profiles need
no launcher setting. `:launcher docker` instead creates a dedicated detached
container on the SSH host.

Kernel resolution uses structured `:python-command` argv, never a shell command
string. The command runs in the selected launch environment. Its argv must
accept appended `-c SCRIPT ARG...` Python arguments and
run Python with `jupyter_client` available; direct Python, `uv run ... python`,
and `nix shell ... -c python` have this shape.  Shell activation command
strings are unsupported.  The command is used only to resolve the selected
kernelspec. The resolved absolute kernel argv launches in the same environment.
For `direct`, a wrapper such as Nix does not become the persisted kernel PID.

```elisp
:python-command
'("nix" "shell" "--impure" "--expr"
  "with import <nixpkgs> {}; python3.withPackages (ps: with ps; [ jupyter ipykernel numpy matplotlib ])"
  "-c" "python")
```

The resolver returns a one-entry kernelspec document and records the exact
absolute connection-file path in `spec.metadata.ejn_connection_file`, bound
to the opaque start session in `ejn_session_id`.  Emacs validates both before
launching or retrieving anything.  Legacy `:jupyter-command` values are
rejected rather than interpreted.

### Docker kernels

Use `:launcher docker` and an image that already contains Python,
`jupyter_client`, and the selected kernelspec (usually `ipykernel`). For example:

```elisp
(setq emacs-jupyter-notebook-remote-profiles
      '(("gpu"
         :host "user@gpu-host"
         :launcher docker
         :docker-image "my/image"
         :docker-options ("--gpus" "all" "--ipc=host"
                          "-v" "/pluto:/pluto:shared"
                          "-v" "local2:/local2")
         :remote-cwd "/pluto"
         :python-command ("python")
         :kernelspec "python3")))
```

`:python-command` names Python inside the image; do not put `docker run` there.
`:remote-cwd` is the working directory inside the container. The cache directory
is on the SSH host, and EJN mounts a private session directory at the same
absolute path in the container so connection metadata remains retrievable.

Initial support requires a Linux SSH host with a local Docker Engine at
`/var/run/docker.sock`, accessible to the SSH user. Pull the image on that host
before starting EJN. EJN pins its image ID, uses host networking, and runs the
container as the SSH user's numeric UID/GID. The image must permit that user
to execute Python and access your mounted working directory. EJN supplies the
entrypoint directly; image entrypoint scripts are not used for activation.

EJN controls container names, ownership labels, detachment, networking, and
cleanup; omit `-it`, `-d`, `--rm`, `--name`, and `--restart` from
`:docker-options`. Unsupported or conflicting flags fail before launch.
Volumes such as `local2:/local2` are named Docker volumes; use
`/local2:/local2` instead if you mean a host directory.

Each kernel has its own detached container, which survives Emacs exit, mode
disable, and SSH loss. Reconnect finds the same registered container. Explicit
shutdown, restart, and retry-fresh operate on the exact registered container;
the idle watchdog still ends an inactive kernel. Broad orphan cleanup is not
supported for Docker profiles; use the session's shutdown or retry-fresh
command. A Docker daemon or SSH failure is treated as unknown liveness and
does not authorize replacing the container.

### Local helper transport

The supervised local Python helper is the only Jupyter transport.  Its
protocol-mode command can be configured before loading the package:

```elisp
(setq emacs-jupyter-notebook-helper-command
      '("ejn-helper" "--protocol"))
```

The helper is local only; it does not install anything on a remote host or
change the remote kernel.  Its executable is resolved independently of
`default-directory`, first through `exec-path`, the most recently built Nix
store closure, and then the package checkout/build layout.  When either bundled
executable is missing, EJN asynchronously runs a single bounded
`nix build --no-link --print-out-paths .#default` from the physical package
source.  It resumes the original command only after both executables resolve.
Build failure, excessive output, and timeout release every waiter so the next
invocation can retry instead of remaining wedged.

Build failures include the complete bounded stderr after its pipe closes.  To
reproduce a build manually with uncapped terminal output, change to the package
directory containing `flake.nix` (for Straight, usually
`~/.config/emacs/.local/straight/repos/emacs-jupyter-notebook`) and run:

```sh
nix --extra-experimental-features 'nix-command flakes' \
  build --no-link --print-out-paths --print-build-logs --show-trace '.#default'
```

Custom commands remain valid and are never silently replaced or built.  An
absolute checkout path remains independent of a source buffer's
`default-directory`:

```elisp
(setq emacs-jupyter-notebook-helper-command
      '("/absolute/path/to/emacs-jupyter-notebook/result/bin/ejn-helper"
        "--protocol"))
```

An absolute Nix store closure path is valid as well:

```elisp
(setq emacs-jupyter-notebook-helper-command
      '("/nix/store/...-ejn-helper-0.1.0/bin/ejn-helper" "--protocol"))
```

Set `emacs-jupyter-notebook-auto-build-runtime` to nil to disable automatic
Nix builds.  `emacs-jupyter-notebook-runtime-build-timeout` (600 seconds by
default) and `emacs-jupyter-notebook-runtime-build-output-max-bytes` bound the
local child.  EJN never runs `pip install`, provisions the remote host, or
falls back to a compatibility transport.

### ProxyJump / ssh config

`ssh` and `scp` read your `~/.ssh/config`, and this package never bypasses it (no `-F none`, no `ProxyCommand` override). ProxyJump therefore works transparently: set the profile `:host` to the **`Host` alias** from your ssh config (not a raw IP) so its `ProxyJump`/`HostName`/`User`/`IdentityFile`/`Port` all apply, and leave `:port`/`:user`/`:identity-file` **unset** in the profile (those emit `-p`/`user@`/`-i`, which override the config). Connection multiplexing (on by default, `emacs-jupyter-notebook-ssh-control-master`) reuses one connection across the whole jump chain, so a ProxyJump setup is where it pays off most.

## Keymap

Commands live under `emacs-jupyter-notebook-prefix-key` (default `C-c j`).
Evil normal-state `TAB` also folds the current cell's output. The prefix is read
once at load time; rebind by setting the variable before loading the package,
or bind `emacs-jupyter-notebook-prefix-map` under your own prefix.

### Top-level commands

| Key | Command |
| --- | --- |
| `C-c j c` | `send-cell` |
| `C-c j j` | `send-cell-and-advance` |
| `C-c j r` | `send-region` |
| `C-c j SPC` | `send-paragraph` |
| `C-c j d` | `send-defun` |
| `C-c j b` | `send-buffer` (confirms; `C-u` skips) |
| `C-c j s` | `start-remote-kernel` |
| `C-c j R` | `reconnect-remote-kernel` |
| `C-c j y` | `retry-fresh-kernel` (confirms; `C-u` skips) |
| `C-c j k` | `interrupt-kernel` |
| `C-c j K` | `restart-kernel` |
| `C-c j S` | `shutdown-kernel` (confirms; `C-u` skips) |
| `C-c j x` | `cancel-operation` |
| `C-c j z` | `cancel-queued-execution` (removes the newest unsent request) |
| `C-c j ?` | `status` (live-refreshing special-mode buffer) |
| `C-c j L` | `show-log-buffer` |
| `C-c j o` | `show-output-panel` |
| `C-c j t` | `toggle-panel-view` (latest ↔ history) |
| `C-c j h` | `toggle-cell-output` (hide/show the current cell's output) |
| `C-c j i` | `inspect` (context-sensitive variable, documentation or output inspection) |
| `C-c j a` | `actions` (contextual menu with keyboard shortcuts) |
| `C-c j A` | `view-variable` (open a NumPy array plane without writing viewer code) |
| `C-c j V` | `list-variables` (kernel variable table) |
| `C-c j I` | `inspect-images` (inspect the current cell's numerical publication) |
| `C-c j J` | `evaluate-and-inspect` (evaluate and open that execution's first numerical publication) |
| `C-c j .` | `inspect-at-point` |
| `C-c j TAB` | `complete-at-point` (capf usually handles it) |
| `C-c j v` | `fetch-remote-log` |
| `C-c j q` | `list-remote-processes` |
| `C-c j w` | `clean-orphaned-kernels` (confirms; `C-u` skips) |
| `C-c j P` | `prune-dead-kernels` (drops registry entries for confirmed-dead kernels) |
| `C-c j l` | `clear-results` |
| `C-c j n` | `forward-cell` |
| `C-c j p` | `backward-cell` |

### Cell-edit subprefix (`C-c j %`)

| Key | Command |
| --- | --- |
| `n` | `forward-cell` |
| `p` | `backward-cell` |
| `a` | `beginning-of-cell` |
| `e` | `end-of-cell` |
| `i` | `insert-cell-below` |
| `I` | `insert-cell-above` |
| `d` | `delete-cell` |
| `k` | `kill-cell` |
| `K` | `clear-cell` |
| `y` | `duplicate-cell` |
| `P` | `move-cell-up` |
| `N` | `move-cell-down` |
| `@` | `code-cells-mark-cell` |

## Send commands

`send-cell` is the primary unit. It sends the current `# %%` cell and posts output into the cell's section of the side panel, replacing any prior section for that cell. `send-cell-and-advance` does the same and then moves point to the next cell.

The secondary surfaces — `send-region`, `send-paragraph`, `send-defun`, `send-buffer` — have no cell key. Their output flows only into the panel's history-log view; they do not participate in latest-per-cell replacement. `send-paragraph` uses `mark-paragraph` semantics. `send-defun` uses `beginning-of-defun` / `end-of-defun`. `send-buffer` asks for confirmation because it commonly involves a lot of code.

## Output panel

Deleting a source cell removes its output from both panel views and releases
its local artifacts. Late replies cannot recreate the deleted entry. Inserting
text above a cell or moving it with the cell commands preserves its identity.
Undoing a deletion does not restore discarded output; evaluate the cell again.

Press `TAB` in Evil normal state in the source buffer to hide/show that cell's
output. In the output pane, `TAB` toggles the entry at point, including in Evil
normal and motion states. `C-c j h` provides the same source command without
Evil. A header remains visible while output is hidden; incoming output and
later evaluations retain the visibility setting. This does not change source
text or insert-state indentation.

Headers show the `# %%` title, execution duration, and whether the source was
edited since that execution. Folded outputs retain a compact image/line count
or the last error. The pane follows the source cell without taking keyboard
focus. Scrolling in the pane pauses following; move to another source cell or
press `f` in the pane to resume. Region and other non-cell evaluations reveal
their history entry automatically. Press `i` to inspect the selected output
and `a` for the panel's action menu.

Evaluation output never appears in the source buffer. A separate read-only
buffer (`*ejn: <buffer>*`) opens in an ordinary window on the first evaluation.
You can split, resize, move, maximize, or switch buffers in that window using
normal Emacs commands. Redisplaying output reuses its existing window without
resetting its size or placement. New output windows open to the right by
default; `emacs-jupyter-notebook-panel-side` and
`emacs-jupyter-notebook-panel-width` control initial placement and width, and
`display-buffer-alist` can override them. Moving through source cells only
tracks an already visible panel; closing its window leaves it closed. If a
display rule errors during evaluation, EJN reports it in `*Messages*` and
tries its default placement so the display error does not cancel execution.
The panel has two views:

- **Latest-per-cell** (default): one section per cell, indexed by cell marker. Re-running the same cell replaces its section in place.
- **History log**: every evaluation, including region/paragraph/defun, appended in time order with timestamp, execution count, and status.

Image originals are kept in private disposable local files instead of the Emacs Lisp heap. The newest `emacs-jupyter-notebook-panel-max-inline-images` images in the current view render as bounded previews; older figures remain lightweight placeholders, which keeps Emacs's native image cache from growing with the full history. Press `o` anywhere on an image entry to open the original with the platform viewer. The files and cached image specs are released when the panel is killed.

Sliced line-height rendering remains available through `emacs-jupyter-notebook-panel-slice-images`. It is disabled by default and applies only to the bounded inline-preview set. When enabled, row counts come from the helper-validated preview dimensions; panel rendering never calls `image-size` across retained history.

Toggle the view inside the panel with `H`, or globally with `C-c j t`. `q` buries the panel. `RET` anywhere in an entry jumps to its originating cell. `n` / `p` step between entries. A cell's text and figures interleave in arrival order, like a notebook — printing and plotting in the same cell shows both. Inline previews use zoom keys (`+`, `-`, `=`). `o` opens any stored PNG/JPEG image externally; `v` remains the matplotlib-pickle interactive viewer command (see below). Under evil (Doom/Spacemacs) the panel uses emacs state so all of these single-key commands work as listed.

## Numerical slice viewer (experimental)

To open an existing NumPy array, use `C-c j A` on its name or `v` on its row in
the variable browser. For multidimensional arrays, minibuffer selectors choose
the row/column axes and an index for each remaining axis, including channels.
Only the selected plane is transferred. Inspection uses generated, history-free
code; it never edits or re-evaluates the source cell.

To publish several related planes together from a NumPy-equipped Python kernel:

```python
# %% inspect reconstruction
ejn.view(
    {"reference": reference[z], "prediction": prediction[z]},
    key="reconstruction",
    sample_id=f"{case_id}/slice-{z}",
    grid_id="aligned-reconstruction",  # declare correspondence, not just equal shapes
    units="HU",                      # only if values are calibrated HU
)
```

EJN injects `ejn` in memory during connection setup. Reconnect after updating
the package; no kernel restart or remote viewer installation is needed. A
pre-existing user-owned `ejn` binding is not overwritten.

Use `C-c j J` to evaluate and inspect, or `C-c j I` to inspect the latest
numerical output for the current cell. Each numerical output also has an
`[Inspect]` button in the panel. Moving point while evaluation runs does not
change the evaluate-and-inspect target.

After inspecting a cell's publication, subsequent publications with the same
cell/workspace identity update the viewer without taking focus. Pin the
reference before rerunning to compare the saved evaluation against the latest
candidate. Freeze keeps the current display; unfreeze follows subsequent
publications. Compatible updates preserve zoom, display levels and ROIs.

The separate local PyQtGraph window displays up to four named planes with
zoom/pan, `F` to fit, pixel-value readout, and window level/width controls.
Declared compatible grids share zoom/pan. Values and byte order are retained
losslessly; whole volumes stay remote. After loading, these controls need no
network requests. Clearing the panel does not delete the displayed snapshot.

The viewer builds asynchronously from the pinned `.#ejn-viewer` Nix output on
first use. It adds no Qt dependency to ordinary kernel work. See
[viewer setup and limits](docs/viewer-installation.md) for manual setup and
verification.

The viewer includes signed/absolute differences, hold-to-blink comparison,
linked sample readout and magnification, rectangular/elliptical ROI
mean/population SD, and line intensity profiles. Choose **Draw ROI → Draw line**
and drag across an edge to overlay profiles from matching images. Move the
line or its A/B endpoints to update the plot. ROIs can be named and retained
across compatible reruns; area statistics can be copied as measurements.
See [viewer controls](docs/viewer-installation.md) for shortcuts and numerical
limits. Native-device-pixel mode and full macOS acceptance remain tracked in
[the viewer roadmap](VIEWER_PLAN.md).

## Legacy matplotlib viewer (pending removal)

The old opt-in pickle viewer is still present while its removal is tracked in
V10. It is not used by `C-c j I` or `C-c j J`, and is not a fallback for the
new numerical viewer. The following describes only that legacy path.

Medical-imaging and array-heavy work needs a real interactive figure — pixel-value-under-cursor readout, zoom/pan, and linked-subplot crop — not just a static PNG thumbnail. `emacs-jupyter-notebook` provides one **without installing anything on any remote**.

### How it works (zero per-remote install)

The remote kernel stays completely headless (inline / Agg). On connect (and again after `restart-kernel`) EJN sends a silent, in-memory IPython display-formatter setup request with `store_history` off; it creates no panel entry and writes nothing to the remote filesystem. Each displayed `matplotlib.figure.Figure` then carries the custom pickle MIME alongside its normal image. The local helper decodes both MIME payloads outside Emacs, enforces byte/pixel limits, and publishes identity-bound local artifact descriptors. Base64 image and pickle strings never enter the Emacs Lisp heap. There is no per-remote provisioning.

Emacs renders only the helper's bounded canonical preview and retains the original-image and pickle descriptors on the panel entry. The legacy `open-figure-interactive` command, or `v` on a panel plot entry, hands the confined pickle descriptor to a persistent **local** viewer process over a Unix-domain socket. The viewer verifies the pinned artifact, unpickles the figure in its own process, reattaches a GUI canvas, installs the enhancements, and shows the window:

- **Hover readout**: over an `imshow` image the coordinate readout shows integer `row`/`col` and the pixel `value` under the cursor.
- **Linked zoom/pan**: zooming or panning one `imshow` subplot crops all sibling `imshow` subplots to the same limits.

If a pickle ever fails to load (for example a matplotlib version mismatch), the viewer prints a clear message and the PNG thumbnail in the panel is unaffected.

### One-time LOCAL setup (never on the remotes)

The viewer runs on the **local workstation** running Emacs and is **GUI-Emacs-only** (it needs a windowing system). The remote never gains any GUI dependency. You need, locally:

- a Python with **matplotlib** and a GUI backend (**Qt** or **Tk**), and
- ideally that local matplotlib **matched to your remote kernels' version**. Figures travel as pickles, and matplotlib figure pickles are not guaranteed to load across versions. Matching both ends is the most reliable configuration. **Cross-version loading is now best-effort:** the viewer installs a compatibility shim for the common `Grouper._ordering` mismatch (matplotlib ≥3.8), so a slightly-older remote often still loads locally. If a pickle still fails, the viewer keeps the panel PNG thumbnail and prints a message naming the local matplotlib version so you know what to match.

The local viewer is **Emacs-owned**: it is spawned lazily on first use, reused across figures, and reaped on `kill-emacs-hook` — the deliberate inverse of the remote-kernel rule (the remote kernel outlives Emacs; the local viewer does not). It also self-exits after an idle timeout so a hard Emacs crash cannot orphan it forever.

### Customization

| Variable | Default | Meaning |
| --- | --- | --- |
| `emacs-jupyter-notebook-local-python-command` | `"python3"` | Local Python that runs the viewer (absolute path or a command on `exec-path`). Must have matplotlib + a GUI backend, version-matched to the remote. |
| `emacs-jupyter-notebook-viewer-backend` | `tk` | Preferred GUI backend: `tk` (TkAgg), `qt` (QtAgg), or `macosx` (native Cocoa); falls back through the others automatically. On macOS the native Cocoa backend is always tried first regardless of this setting. |
| `emacs-jupyter-notebook-viewer-idle-timeout` | `900` | Seconds the viewer stays alive with no open figures before self-exiting (0 disables). |
| `emacs-jupyter-notebook-viewer-auto-open` | `nil` | When non-nil, pop the interactive window automatically for every inline figure instead of on demand. |

A small fringe/margin indicator next to each cell marker reflects the cell's most recent state: blank (never run), `►` (running), `✓N` (ok with execution count `N`), `✗` (error), `…` (queued). The indicator is overlay-only and never modifies source text.

When an SSH tunnel drops, EJN keeps the running cell and queued cells in the
live local helper session. Reconnection restores output to the same panel
entry. Queued cells run in order after the original execution finishes,
including when it finished during the outage. EJN never reruns that execution.
Execution deadlines pause while the tunnel is disconnected.

Jupyter does not retain a replayable output stream: output sent during the
outage may be missing, which the panel records explicitly. If the execution's
reply was also lost, EJN checks that the run ended and displays `completed`
with a neutral `✓`; this does not claim that the code succeeded. A helper crash
or Emacs restart still loses the in-memory execution queue. Update the local
helper together with the Elisp to use tunnel recovery.

The persistent tunnel uses its own SSH connection, including when global or
profile SSH options enable multiplexing. Short setup and management commands
can still share EJN's master connection. In `ssh -vvv` output,
`mux_client_read_packet_timeout: read header failed: Broken pipe` describes
the local multiplexing socket and can appear at normal session exit. Check
the following line: `Received exit status from master 0` is successful,
whereas `Control master terminated unexpectedly` indicates lost master
ownership. The debug line alone does not identify a proxy or server failure.
See [OpenSSH's mux client implementation](https://github.com/openssh/openssh-portable/blob/master/mux.c).

For a terminal comparison using EJN's default keepalive policy, run
`ssh -vvv -S none -o ServerAliveInterval=15 -o ServerAliveCountMax=3 HOST`.
Three unanswered probes disconnect in about 45 seconds. A ProxyJump uses a
separate SSH process with its own host configuration, so target-host options
do not by themselves disable multiplexing on the jump host.

## Status buffer (`C-c j ?`)

`status` opens `*emacs-jupyter-notebook status*` in a derivative of `special-mode`. While the buffer is visible it refreshes once per second; when buried the refresh timer cancels itself. Suggested actions appear as clickable buttons that switch to the originating source buffer and invoke the suggested command (`start-remote-kernel`, `reconnect-remote-kernel`, `retry-fresh-kernel`, `cancel-operation`, `send-cell`, depending on engine state).

## Log buffer (`C-c j L`)

A global append-only log buffer, `*emacs-jupyter-notebook log*`, records every async progress message and every heartbeat miss / death. Lines are `ISO-TIMESTAMP  <buffer-name>  [PHASE]  MESSAGE`. The buffer is truncated from the front to `emacs-jupyter-notebook-log-max-lines` (default 2000) after every append so it stays bounded over long sessions. Open it with `C-c j L`.

## Mode-line lighter

The mode-line lighter encodes the engine state at a glance. From highest precedence to lowest:

| Lighter | Meaning |
| --- | --- |
| ` EJN!` | tunnel flagged dead by the heartbeat or sentinel |
| ` EJN✗` | the most recent async operation finished in `error` |
| ` EJN…build` | first-use local Nix runtime build in flight |
| ` EJN…launch` | async kernel launch in flight |
| ` EJN…retrieve` | async connection-file retrieve in flight |
| ` EJN…tunnel` | async SSH tunnel coming up |
| ` EJN…connect` | async Jupyter client connect in flight |
| ` EJN*` | the kernel is busy executing a request |
| ` EJN✓` | client connected and the kernel is idle |
| ` EJN` | no client and nothing in flight |

## Variable inspection

With the notebook mode enabled and a Python kernel connected, pause on a
variable name to see its type, array shape and dtype in Eldoc's echo area:
`image: numpy.ndarray  shape=(128, 64)  dtype=float32`. The variable must
already exist in the kernel. No `.shape` source cell or array transfer is
needed. `C-c j i` inspects the identifier at point and falls back to kernel
documentation when no runtime variable exists. `C-c j .` explicitly requests
documentation. `C-c j a` opens a contextual action menu with shortcuts.

`C-c j V` opens the variable table. It refreshes after executions and highlights
changed shapes/dtypes. While busy or reconnecting, it retains the last metadata
with a stale label. Use `g` to refresh, `RET`/`i` to inspect, `v` to view an array,
`f` to favorite a variable, `F` to show only favorites, `a` for actions, and `q`
to close; these keys also work under Doom/Evil. Favorites can have persistent
defaults through `emacs-jupyter-notebook-variable-favorites`. The list is bounded
to 200 public variables. Requests skip busy kernels and expire asynchronously.

NumPy arrays (including subclasses), ordinary PyTorch tensors and memoryviews
expose shapes/dtypes without copying samples. Other objects show their type;
custom properties and representations are not called. Only simple names are
looked up automatically, excluding comments, strings and attribute expressions.
Set `emacs-jupyter-notebook-variable-eldoc` to nil to disable automatic lookup;
`emacs-jupyter-notebook-variable-cache-seconds` and
`emacs-jupyter-notebook-variable-list-limit` control its bounded cache/list.
Update the local helper together with the Elisp and reconnect to use this new
metadata operation.

## Completion

Completion runs against the remote kernel through `completion-at-point` and is designed never to block the UI, even when the remote link is slow.

How it works:

- The capf returns immediately from whatever is in a buffer-local LRU cache. Even if the kernel is on the other side of a 500 ms link, the capf hot path stays in the single-millisecond range.
- After the user pauses typing for `emacs-jupyter-notebook-completion-idle` seconds (default `0.10`), an async `complete_request` is sent to the kernel.
- A new keystroke invalidates any in-flight request. When the stale reply finally arrives, it is dropped on arrival — never rendered, never blocking.
- The cache key is `(point . line-up-to-point)`, so identical contexts in the same buffer reuse the prior reply without a round trip.
- The cache is bounded by `emacs-jupyter-notebook-completion-cache-size` (default 200) with LRU eviction.

Frontend integration:

- **Vanilla `completion-at-point`** works out of the box. The capf returns cached candidates; the next call after a reply arrives sees the fresh cache.
- **Corfu / Vertico / Consult**: when `completion-in-region-mode` is active the package does not try to force the popup to re-fetch candidates programmatically (no cross-version API does this reliably). The next user keystroke re-invokes capf, which finds the now-cached candidates and updates the popup. In practice the lag is invisible because the reply usually arrives in less than one keystroke.
- **Company**: when `company-mode` is on and no popup is open, the reply path kicks `company-manual-begin` so the popup picks up the fresh candidates.
- **Cape** and similar capf composers: just include `emacs-jupyter-notebook-completion-at-point` in your `completion-at-point-functions` (the minor mode does this for you).

Late replies only open completion UI while the source buffer is still selected
and no minibuffer is active. Reconnect, missing-host, array-axis and kernel-input
prompts wait for their originating buffer, so background work cannot take over
M-x or a file picker. Quitting a deferred prompt retires that interaction.

See the [responsiveness review](docs/hang-review-2026-09-09.md) for tested hang
scenarios and instructions for capturing a backtrace when the minibuffer itself
is unresponsive.

Tuning:

- `emacs-jupyter-notebook-completion-idle` — seconds of typing pause before an async request fires. Lower values feel snappier; higher values hammer the kernel less during fast typing.
- `emacs-jupyter-notebook-completion-cache-size` — maximum number of cached replies per buffer.

## Reconnect

Sessions are recorded in a local registry under `user-emacs-directory`. Reopening Emacs and visiting a previously-used file lets you reconnect to the still-running remote kernel via `C-c j R`. The chooser always appears, with the entry for the current file pre-selected as the default — press RET to accept it or pick another.

Evaluating a cell also reconnects its recorded session when needed and keeps
the cell queued until the connection is ready. Starting a kernel checks the
existing session instead of requiring a separate reconnect command. If the
registered kernel is confirmed gone, EJN offers a fresh start on the same
profile; accepting continues the original queued evaluation. An unreachable
host is reported as a connection failure and does not trigger replacement.

The remote kernel outlives Emacs. Closing the buffer, disabling the mode, and
Emacs exit leave it running so a future session can reconnect. Explicit
shutdown/restart commands and the idle watchdog control its lifetime.

The idle watchdog defaults to **12 hours** without activity
(`emacs-jupyter-notebook-kernel-idle-timeout`, 43200 seconds). It never expires
a busy kernel; set the option to `0` to disable idle expiry. An explicitly
configured timeout takes precedence over the default.

### Automatic recovery after a drop

When the transport dies — the SSH tunnel exits, or the heartbeat misses its kernel-info replies — the buffer schedules an **automatic reconnect** and retries in the background with exponential backoff (starting at `emacs-jupyter-notebook-reconnect-initial-delay`, doubling, capped at `emacs-jupyter-notebook-reconnect-max-delay`). This is transport-only recovery: it rebuilds the tunnel and the client against the durable registry entry. It never starts a remote kernel and never terminates one. So when your laptop loses Wi-Fi for a while and regains it, the tunnel typically re-forms by itself; the mode line shows ` EJN!` while dead and the attempt/next-retry countdown is visible in `C-c j ?`.

The loop stops on its own in three cases:

- **Success** — the transport is restored and the kernel answers (or is confirmed busy executing a long cell; the client attaches and sends queue behind the running cell).
- **Confirmed-dead kernel** — a probe reaches the host and finds the registered PID is gone (for example, the idle watchdog reaped it after `emacs-jupyter-notebook-kernel-idle-timeout`). The registry entry is kept; start a fresh kernel explicitly.
- **Confirmed-mismatch kernel** — the PID is alive but belongs to a *different* process (PID reuse after a long outage). This is reported distinctly from "dead" and also stops the loop.

If the host simply cannot be reached, that is treated as *transient*: the loop keeps retrying with backoff rather than declaring the kernel dead. Set `emacs-jupyter-notebook-auto-reconnect` to nil to disable background recovery entirely and only ever reconnect through an explicit command.

### Explicit reconnect is the escape hatch

`C-c j R` (or `reconnect-remote-kernel`) is an authoritative local reset: it tears down the stale local client and tunnel and rebuilds them against the chosen registry entry, without touching the remote kernel. If a previous connection attempt is wedged in the background, an explicit reconnect supersedes it silently (no second prompt) — you never need to cancel-by-hand first. A wedged *start* attempt still asks before being superseded, because its remote launch may already have started a kernel that must remain recorded for recovery.

Before reconnecting, Emacs probes the remote PID **with identity**: it confirms the live process is really this session's kernel (its command line carries the session's connection file), not a reused PID. Every reconnect phase is bounded — each one-shot SSH/SCP process by `emacs-jupyter-notebook-ssh-process-timeout` and the whole attempt by `emacs-jupyter-notebook-connection-attempt-timeout` — so a reconnect can stall neither on a dead ControlMaster nor on an interactive SSH prompt (`BatchMode=yes` is on by default for this reason).

If an interactive reconnect, start, or evaluation confirms the registered
kernel is gone, Emacs offers to start a fresh kernel on the same profile right
there (one `y-or-n-p`). Existing code that was already sent to a kernel is never
replayed automatically.
