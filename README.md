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

## Useful Commands

| Key | Command |
| --- | --- |
| `C-c C-c` | evaluate current cell |
| `C-c C-r` | evaluate region |
| `C-c C-b` | evaluate buffer |
| `C-c C-o` | open full output as real text |
| `C-c C-t` | collapse/expand inline output |
| `C-c C-j` | evaluate cell and advance |
| `C-c %` | cell commands: next/previous, insert, delete, duplicate, move |
| `C-c TAB` | complete at point |
| `C-c C-d` | inspect at point |
| `C-c C-k` | interrupt kernel |
| `C-c C-s` | start remote kernel |
| `C-c C-n` | reconnect remote kernel |
| `C-c C-l` | clear results |

## Notes

Inline results are overlays, not file edits. Large output is truncated inline; use `C-c C-o` for the full copyable output buffer.

Sessions are recorded in a local registry under `user-emacs-directory`, so reopening Emacs can reconnect to existing remote kernels.
