# emacs-jupyter-notebook

Edit normal local source files and run `# %%` cells on a persistent remote Jupyter kernel.

This gives the useful parts of Jupyter notebooks: cells, rich inline output, kernel state, completion, inspect, interrupts, restarts, and reconnects. It avoids the bad parts: no `.ipynb` JSON, no hidden source/output merge conflicts, no browser editor, and no results written into source files.

## Why

The source file stays an ordinary Python file. Your normal Emacs, Git, LSP, linting, formatting, search, and review workflows keep working.

The kernel can live on another machine. Emacs starts or reconnects to it through external `ssh`/`scp` commands and local port forwards. It does not use TRAMP, and the kernel does not die just because Emacs exits.

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

Send the current cell:

```elisp
C-c j c
```

If no kernel is connected, the first send announces which profile it will use ("starting kernel via profile <name> (C-u to choose)") and then launches that kernel asynchronously. The send queues; output streams into the side panel as soon as the kernel connects. `C-u C-c j c` prompts for a profile to start with instead.

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

If `jupyter` is not directly on the remote `PATH`, set `:jupyter-command` in the profile.

## Keymap

All commands live under a single prefix, `emacs-jupyter-notebook-prefix-key` (default `C-c j`). The prefix is read once at load time; rebind by `setq`-ing the var before loading the package, or by binding `emacs-jupyter-notebook-prefix-map` under your own prefix.

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
| `C-c j ?` | `status` (live-refreshing special-mode buffer) |
| `C-c j L` | `show-log-buffer` |
| `C-c j o` | `show-output-panel` |
| `C-c j t` | `toggle-panel-view` (latest ↔ history) |
| `C-c j I` | `open-figure-interactive` (open the current cell's figure in the local viewer) |
| `C-c j .` | `inspect-at-point` |
| `C-c j TAB` | `complete-at-point` (capf usually handles it) |
| `C-c j v` | `fetch-remote-log` |
| `C-c j q` | `list-remote-processes` |
| `C-c j w` | `clean-orphaned-kernels` (confirms; `C-u` skips) |
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

Evaluation output never appears in the source buffer. A dedicated side panel (`*ejn: <buffer>*`) opens on the first evaluation and renders results there. The panel has two views:

- **Latest-per-cell** (default): one section per cell, indexed by cell marker. Re-running the same cell replaces its section in place.
- **History log**: every evaluation, including region/paragraph/defun, appended in time order with timestamp, execution count, and status.

Toggle the view inside the panel with `H`, or globally with `C-c j t`. `q` buries the panel. `RET` on an entry header jumps to its originating cell. `n` / `p` step between entries. Images render inline with native zoom keys (`+`, `-`, `=`). `v` on a plot entry opens that figure in the interactive local viewer (see below).

## Interactive matplotlib viewer

Medical-imaging and array-heavy work needs a real interactive figure — pixel-value-under-cursor readout, zoom/pan, and linked-subplot crop — not just a static PNG thumbnail. `emacs-jupyter-notebook` provides one **without installing anything on any remote**.

### How it works (zero per-remote install)

The remote kernel stays completely headless (inline / Agg). On connect (and again after `restart-kernel`) Emacs injects a small, in-memory IPython display formatter into the running kernel session — a silent `execute_request` with `store_history` off that creates no panel entry and writes **nothing** to the remote filesystem. From then on, every inline-displayed `matplotlib.figure.Figure` automatically carries a custom MIME payload, `application/x-ejn-mpl-pickle` (base64 of `pickle.dumps(fig)`), **alongside** the normal `image/png`. The registration is lazy (it does not force a matplotlib import until a figure is actually displayed) and idempotent. Everything it needs — IPython, matplotlib, `pickle`/`base64` — is already present on any Python Jupyter kernel that can plot. There is no `pip install` and no per-remote provisioning: add a new remote and the feature just works.

Emacs keeps rendering the PNG thumbnail in the panel exactly as before and stashes the pickle on the panel entry. When you open a figure interactively (`C-c j I` on a cell, or `v` on a panel plot entry), Emacs decodes the pickle to a local temp file and hands the path to a persistent **local** viewer process over a unix-domain socket. The viewer unpickles the figure, reattaches a GUI canvas, installs the enhancements, and shows the window:

- **Hover readout**: over an `imshow` image the coordinate readout shows integer `row`/`col` and the pixel `value` under the cursor.
- **Linked zoom/pan**: zooming or panning one `imshow` subplot crops all sibling `imshow` subplots to the same limits.

If a pickle ever fails to load (for example a matplotlib version mismatch), the viewer prints a clear message and the PNG thumbnail in the panel is unaffected.

### One-time LOCAL setup (never on the remotes)

The viewer runs on the **local workstation** running Emacs and is **GUI-Emacs-only** (it needs a windowing system). The remote never gains any GUI dependency. You need, locally:

- a Python with **matplotlib** and a GUI backend (**Qt** or **Tk**), and
- that local matplotlib **pinned to the same version as your remote kernels**. Figures travel as pickles, and matplotlib figure pickles are not guaranteed to load across versions. Same-version on both ends is the supported configuration (the package is single-user by design).

The local viewer is **Emacs-owned**: it is spawned lazily on first use, reused across figures, and reaped on `kill-emacs-hook` — the deliberate inverse of the remote-kernel rule (the remote kernel outlives Emacs; the local viewer does not). It also self-exits after an idle timeout so a hard Emacs crash cannot orphan it forever.

### Customization

| Variable | Default | Meaning |
| --- | --- | --- |
| `emacs-jupyter-notebook-local-python-command` | `"python3"` | Local Python that runs the viewer (absolute path or a command on `exec-path`). Must have matplotlib + a GUI backend, version-matched to the remote. |
| `emacs-jupyter-notebook-viewer-backend` | `qt` | Preferred GUI backend, `qt` (QtAgg) or `tk` (TkAgg); falls back to the other automatically. |
| `emacs-jupyter-notebook-viewer-idle-timeout` | `900` | Seconds the viewer stays alive with no open figures before self-exiting (0 disables). |
| `emacs-jupyter-notebook-viewer-auto-open` | `nil` | When non-nil, pop the interactive window automatically for every inline figure instead of on demand. |

A small fringe/margin indicator next to each cell marker reflects the cell's most recent state: blank (never run), `►` (running), `✓N` (ok with execution count `N`), `✗` (error), `…` (queued). The indicator is overlay-only and never modifies source text.

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
| ` EJN…launch` | async kernel launch in flight |
| ` EJN…retrieve` | async connection-file retrieve in flight |
| ` EJN…tunnel` | async SSH tunnel coming up |
| ` EJN…connect` | async Jupyter client connect in flight |
| ` EJN*` | the kernel is busy executing a request |
| ` EJN✓` | client connected and the kernel is idle |
| ` EJN` | no client and nothing in flight |

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

Tuning:

- `emacs-jupyter-notebook-completion-idle` — seconds of typing pause before an async request fires. Lower values feel snappier; higher values hammer the kernel less during fast typing.
- `emacs-jupyter-notebook-completion-cache-size` — maximum number of cached replies per buffer.

## Reconnect

Sessions are recorded in a local registry under `user-emacs-directory`. Reopening Emacs and visiting a previously-used file lets you reconnect to the still-running remote kernel via `C-c j R`. The chooser always appears, with the entry for the current file pre-selected as the default — press RET to accept it or pick another.

The remote kernel outlives Emacs. Only the explicit commands `shutdown-kernel` and `clean-orphaned-kernels` terminate it; closing the buffer, disabling the mode, and Emacs exit all leave the remote kernel running so a future session can reconnect.
