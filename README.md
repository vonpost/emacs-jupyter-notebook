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

Evaluate the current cell:

```elisp
C-c C-c
```

If no kernel is connected, evaluation starts or reconnects to one using the default profile.

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

## Core Commands

| Key | Command |
| --- | --- |
| `C-c C-c` | evaluate current cell |
| `C-c C-r` | evaluate region |
| `C-c C-j` | evaluate cell and advance |
| `C-c C-k` | interrupt kernel |
| `C-c C-s` | start remote kernel |
| `C-c C-n` | reconnect remote kernel |
| `C-c C-/` | show engine/session status |
| `C-c C-l` | clear results |

Less common but useful commands remain keybound: `C-c C-b` evaluates the full buffer, `C-c C-o` opens full output as text, `C-c C-t` toggles output, `C-c TAB` completes, `C-c C-d` inspects, and `C-c %` opens the cell command prefix.

Recovery and diagnostics are intentionally secondary: `C-c C-y` retries with a fresh kernel, `C-c C-v` fetches the remote log, `C-c C-q` lists remote processes, and `C-c C-w` cleans orphaned remote kernels.

## Completion

Completion runs against the remote kernel through `completion-at-point` and is designed never to block the UI, even when the remote link is slow.

How it works:

- The capf returns immediately from whatever is in a buffer-local LRU cache. Even if the kernel is on the other side of a 500ms link, the capf hot path stays in the single-millisecond range.
- After the user pauses typing for `emacs-jupyter-notebook-completion-idle` seconds (default `0.10`), an async `complete_request` is sent to the kernel.
- A new keystroke invalidates any in-flight request. When the stale reply finally arrives, it is dropped on arrival — never rendered, never blocking.
- The cache key is `(point . line-up-to-point)`, so identical contexts in the same buffer reuse the prior reply without a round trip.
- The cache is bounded by `emacs-jupyter-notebook-completion-cache-size` (default 200) with LRU eviction.

Frontend integration:

- **Vanilla `completion-at-point`** works out of the box. The capf returns cached candidates; the next call after a reply arrives sees the fresh cache.
- **Corfu**: when `corfu-mode` is on, the reply path calls `corfu--exhibit` (inside a `completion-in-region` session) or `corfu--auto-complete-deferred` to refresh the popup immediately as candidates land.
- **Company**: when `company-mode` is on, the reply path kicks `company-manual-begin` (or `company-idle-begin` on older versions) so the popup picks up the fresh candidates.
- **Cape** and similar capf composers: just include `emacs-jupyter-notebook-completion-at-point` in your `completion-at-point-functions` (the minor mode does this for you).

Tuning:

- `emacs-jupyter-notebook-completion-idle` — seconds of typing pause before an async request fires. Lower values feel snappier; higher values hammer the kernel less during fast typing.
- `emacs-jupyter-notebook-completion-cache-size` — maximum number of cached replies per buffer.

## Notes

Inline results are overlays, not file edits. Large output is truncated inline; use `C-c C-o` for the full copyable output buffer.

Sessions are recorded in a local registry under `user-emacs-directory`, so reopening Emacs can reconnect to existing remote kernels.
