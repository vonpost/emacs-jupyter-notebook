#!/usr/bin/env python3
"""GUI regression guard for ejn_viewer's local matplotlib viewer.

This exercises the REAL Tk backend on a REAL display and asserts, without
needing eyes, that opening a figure produces exactly ONE fully-interactive
window (rendered figure + navigation toolbar + linked ``format_coord`` hover
readout) with no blank anchor window, and that re-opening replaces it.

It is a durable regression guard for the "figure split across windows" bug:
unpickling a pyplot-managed figure already reconstructs a GUI manager, and the
old ``_reattach_canvas`` created a *second* canvas and rebound the figure to it,
splitting the toolbar/events from the render.

The GUI dependencies (a working ``$DISPLAY`` plus matplotlib + tkinter) live
only in the nix shell, so this SKIPS cleanly (exit 0) when either is absent.
Run it under the viewer's nix closure:

  DISPLAY=:0 nix shell --impure --expr 'with import <nixpkgs> {}; \
    python3.withPackages (ps: with ps; [ numpy matplotlib tkinter ])' \
    -c python3 viewer/test_viewer_gui.py
"""

import os
import pickle
import sys
import tempfile


def _skip(reason):
    sys.stdout.write("SKIP: %s\n" % reason)
    return 0


def main():
    if not os.environ.get("DISPLAY"):
        return _skip("no $DISPLAY (GUI test requires a real X display)")
    try:
        import matplotlib  # noqa: F401
        import numpy  # noqa: F401
        import tkinter  # noqa: F401
    except Exception as exc:  # pragma: no cover - depends on environment
        return _skip("GUI deps unavailable: %s" % exc)

    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

    import matplotlib
    import numpy as np

    # --- build a remote-style pickle: subplots(1,3) of imshow under Agg ----
    def make_pickle(seed):
        matplotlib.use("Agg", force=True)
        import matplotlib.pyplot as plt
        fig, axes = plt.subplots(1, 3)
        for i, ax in enumerate(axes):
            ax.imshow(np.arange(12).reshape(3, 4) + seed * 100 + i)
        blob = pickle.dumps(fig)
        plt.close("all")
        fd, path = tempfile.mkstemp(suffix=".pkl", prefix="ejn_gui_")
        with os.fdopen(fd, "wb") as handle:
            handle.write(blob)
        return path

    path1 = make_pickle(0)
    path2 = make_pickle(1)

    import ejn_viewer

    # Select and validate the Tk backend exactly as the viewer does.
    backend = ejn_viewer._select_backend("tk")
    import matplotlib.pyplot as plt
    from matplotlib._pylab_helpers import Gcf

    results = []

    def check(name, cond):
        results.append((name, bool(cond)))
        sys.stdout.write("%s: %s\n" % ("PASS" if cond else "FAIL", name))

    check("backend-is-tk", backend == "TkAgg")

    # Mimic run()'s host: a hidden Tk root created BEFORE any figure.
    import tkinter as tk
    host = tk.Tk()
    host.withdraw()

    def non_anchor_managers():
        out = []
        for num in plt.get_fignums():
            mgr = Gcf.figs.get(num)
            if mgr is None:
                continue
            if getattr(mgr.canvas.figure, "_ejn_is_anchor", False):
                continue
            out.append(mgr)
        return out

    def pump_gui(win):
        for _ in range(6):
            try:
                host.update_idletasks()
                host.update()
            except Exception:
                pass
            try:
                win.update_idletasks()
                win.update()
            except Exception:
                pass

    # ---- open the first figure ------------------------------------------
    fig = ejn_viewer.open_figure(path1)
    check("open-returned-figure", fig is not None)

    mgrs = non_anchor_managers()
    check("exactly-one-manager", len(mgrs) == 1)
    manager = mgrs[0] if mgrs else None

    win1 = None
    if manager is not None:
        win1 = manager.window
        pump_gui(win1)
        check("manager-has-toolbar", getattr(manager, "toolbar", None) is not None)
        check("canvas-figure-is-fig", manager.canvas.figure is fig)

        axes = fig.get_axes()
        check("three-axes", len(axes) == 3)
        readouts = []
        for ax in axes:
            try:
                readouts.append(ax.format_coord(1.0, 1.0))
            except Exception as exc:
                readouts.append("ERR:%s" % exc)
        check("format_coord-row-col-all-axes",
              len(readouts) == 3
              and all("row=" in r and "col=" in r for r in readouts))

        # Exactly one mapped/visible figure window; host root not visible.
        mapped = 0
        for m in non_anchor_managers():
            try:
                if m.window.winfo_ismapped():
                    mapped += 1
            except Exception:
                pass
        check("one-visible-figure-window", mapped == 1)
        try:
            host_state = host.state()
        except Exception:
            host_state = "unknown"
        check("host-root-not-visible",
              host_state == "withdrawn" and not host.winfo_ismapped())

        # Zoom proof: render + toolbar share one canvas, LinkGroup crops siblings.
        zoom_ok = True
        try:
            axes[0].set_xlim((-0.5, 1.5))
            axes[0].set_ylim((1.5, -0.5))
            manager.canvas.draw()
            x0 = axes[0].get_xlim()
            y0 = axes[0].get_ylim()
            for sib in axes[1:]:
                if (abs(sib.get_xlim()[0] - x0[0]) > 1e-6
                        or abs(sib.get_xlim()[1] - x0[1]) > 1e-6
                        or abs(sib.get_ylim()[0] - y0[0]) > 1e-6
                        or abs(sib.get_ylim()[1] - y0[1]) > 1e-6):
                    zoom_ok = False
        except Exception as exc:
            sys.stdout.write("zoom exception: %s\n" % exc)
            zoom_ok = False
        check("zoom-links-siblings-no-exception", zoom_ok)
    else:
        for name in ("manager-has-toolbar", "canvas-figure-is-fig",
                     "three-axes", "format_coord-row-col-all-axes",
                     "one-visible-figure-window", "host-root-not-visible",
                     "zoom-links-siblings-no-exception"):
            check(name, False)

    # ---- open a SECOND figure: it must REPLACE the first -----------------
    fig2 = ejn_viewer.open_figure(path2)
    check("second-open-returned-figure", fig2 is not None)
    mgrs2 = non_anchor_managers()
    check("still-exactly-one-manager", len(mgrs2) == 1)
    check("second-figure-is-different", fig2 is not fig)
    if win1 is not None:
        try:
            first_dead = not win1.winfo_exists()
        except Exception:
            first_dead = True
        check("first-window-closed", first_dead)
    else:
        check("first-window-closed", False)
    if mgrs2:
        pump_gui(mgrs2[0].window)
        check("second-canvas-figure-is-fig2", mgrs2[0].canvas.figure is fig2)
    else:
        check("second-canvas-figure-is-fig2", False)

    # ---- cleanup: leave no windows on the user's screen ------------------
    try:
        plt.close("all")
    except Exception:
        pass
    try:
        host.destroy()
    except Exception:
        pass
    for p in (path1, path2):
        try:
            os.unlink(p)
        except OSError:
            pass

    failed = [n for n, ok in results if not ok]
    total = len(results)
    if failed:
        sys.stdout.write("\nGUI TEST FAILED (%d/%d): %s\n"
                         % (len(failed), total, ", ".join(failed)))
        return 1
    sys.stdout.write("\nGUI TEST OK (%d/%d assertions passed)\n" % (total, total))
    return 0


if __name__ == "__main__":
    sys.exit(main())
