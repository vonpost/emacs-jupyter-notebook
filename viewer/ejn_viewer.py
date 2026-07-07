#!/usr/bin/env python3
"""ejn_viewer.py -- local persistent interactive matplotlib viewer (W8).

Part of emacs-jupyter-notebook.  Runs on the LOCAL workstation (never on any
remote).  Emacs spawns one persistent instance and hands it newline-delimited
pickle file paths over a unix-domain socket.  For each path the viewer:

  * unpickles a matplotlib.figure.Figure (produced headless on the remote,
    transported as base64 pickle alongside the inline PNG),
  * reattaches a live GUI canvas (the unpickled figure arrives canvas-less),
  * installs a per-imshow ``format_coord`` override showing integer row/col
    and the pixel value under the cursor,
  * links zoom/pan across all imshow subplots of the figure (a zoom on one
    subplot crops its siblings), and
  * shows the window.

The socket is serviced by a matplotlib canvas timer, NOT a blocking accept
loop, so the GUI event loop stays responsive.  The process self-exits after
an idle timeout so a hard Emacs crash cannot orphan it forever.

The pure, non-GUI logic (``image_rowcol``, ``format_coord_text``,
``LinkGroup``) is unit-tested headlessly via ``python3 ejn_viewer.py
--selfcheck`` -- it imports no GUI backend.  The GUI parts (window opening,
live hover, linked zoom) are verified manually.
"""

import argparse
import math
import os
import pickle
import socket
import sys
import time


# --------------------------------------------------------------------------
# Pure, headless-testable logic (no matplotlib import required)
# --------------------------------------------------------------------------

def image_rowcol(extent, shape, x, y, origin="upper"):
    """Map data coords (X, Y) to integer (row, col) of an imshow image.

    EXTENT is ``(left, right, bottom, top)`` as returned by
    ``AxesImage.get_extent()``.  SHAPE is ``(nrows, ncols[, ...])``.  ORIGIN
    is the image origin (``"upper"`` or ``"lower"``); it decides which extent
    edge array-row 0 maps to.  Returns ``(row, col)`` or ``None`` when
    (X, Y) falls outside the image.
    """
    left, right, bottom, top = extent
    nrows, ncols = shape[0], shape[1]
    if right == left or bottom == top or nrows == 0 or ncols == 0:
        return None
    col = int(math.floor((x - left) / (right - left) * ncols))
    # Array row 0 sits at the ``top`` edge for origin='upper' and at the
    # ``bottom`` edge for origin='lower'.  Either way this yields the natural
    # "data y == row index" mapping for the default imshow extent.
    if origin == "lower":
        row = int(math.floor((y - bottom) / (top - bottom) * nrows))
    else:
        row = int(math.floor((y - top) / (bottom - top) * nrows))
    if 0 <= row < nrows and 0 <= col < ncols:
        return (row, col)
    return None


def _format_value(value):
    """Return a compact human string for a pixel VALUE (scalar or vector)."""
    try:
        f = float(value)
    except (TypeError, ValueError):
        return str(value)
    if math.isfinite(f) and f == int(f):
        return str(int(f))
    return "%.6g" % f


def format_coord_text(extent, shape, get_value, x, y, origin="upper"):
    """Return the hover readout string for data coords (X, Y).

    GET_VALUE is a callable ``(row, col) -> value_or_None``.  When (X, Y) is
    inside the image the readout is ``row=R col=C value=V``; outside it falls
    back to a plain ``x=.. y=..`` readout.
    """
    rc = image_rowcol(extent, shape, x, y, origin=origin)
    if rc is None:
        return "x=%.4g y=%.4g" % (x, y)
    row, col = rc
    try:
        value = get_value(row, col)
    except Exception:
        value = None
    if value is None:
        return "row=%d col=%d x=%.4g y=%.4g" % (row, col, x, y)
    return "row=%d col=%d value=%s" % (row, col, _format_value(value))


class LinkGroup(object):
    """Propagate axis limits across a group of axes with a recursion guard.

    Wiring each axis' ``xlim_changed`` / ``ylim_changed`` callback to
    ``on_lim_changed`` makes a zoom/pan on any member crop every sibling.
    ``set_xlim(..., emit=False)`` plus the ``_busy`` guard prevent the
    callback storm / infinite recursion that naive linking causes.

    Propagation is RELATIVE, not absolute: each axis' full (base) data
    limits are captured at construction, and a change is mapped to the same
    *fraction* of every sibling's OWN base range.  This matters when the
    subplots hold images of DIFFERENT matrix sizes (hence different
    extents): copying absolute data limits would crop a 100-row sibling to a
    64-row axis' range, and -- worse -- the toolbar Home/reset fires this
    callback per axis, so an absolute copy made every subplot inherit the
    last-reset axis' extent (displayed at the wrong matrix size).  With
    relative mapping a zoom to "the top-left quarter of A" becomes the
    top-left quarter of each sibling, and a reset (A back to its full base ->
    fraction 0..1) returns every sibling to ITS OWN full base.
    """

    def __init__(self, axes):
        self.axes = list(axes)
        self._busy = False
        # Base (full) limits per axis, keyed by id(); the fraction reference
        # and the reset target.  Captured now, before any user zoom, so it is
        # the original extent-derived view (== the toolbar's Home view).
        self._base = {}
        for ax in self.axes:
            self._base[id(ax)] = (ax.get_xlim(), ax.get_ylim())

    @staticmethod
    def _fractions(base, cur):
        """Return CUR as (lo, hi) fractions of the BASE (b0, b1) range."""
        b0, b1 = base
        span = b1 - b0
        if span == 0:
            return (0.0, 1.0)
        return ((cur[0] - b0) / span, (cur[1] - b0) / span)

    @staticmethod
    def _apply(base, frac):
        """Map FRAC (lo, hi) back onto the BASE (b0, b1) range."""
        b0, b1 = base
        span = b1 - b0
        return (b0 + frac[0] * span, b0 + frac[1] * span)

    def on_lim_changed(self, changed_ax):
        """Crop every sibling to CHANGED_AX's RELATIVE view; return them.

        A re-entrant call (while a propagation is in flight) is a no-op that
        returns ``[]`` -- this is the recursion guard.
        """
        if self._busy:
            return []
        src_base = self._base.get(id(changed_ax))
        if src_base is None:
            return []
        self._busy = True
        propagated = []
        try:
            fx = self._fractions(src_base[0], changed_ax.get_xlim())
            fy = self._fractions(src_base[1], changed_ax.get_ylim())
            for ax in self.axes:
                if ax is changed_ax:
                    continue
                base = self._base.get(id(ax))
                if base is None:
                    continue
                ax.set_xlim(self._apply(base[0], fx), emit=False)
                ax.set_ylim(self._apply(base[1], fy), emit=False)
                propagated.append(ax)
        finally:
            self._busy = False
        return propagated


# --------------------------------------------------------------------------
# GUI logic (matplotlib required)
# --------------------------------------------------------------------------

def _select_backend(preferred):
    """Select and VALIDATE a GUI backend, preferring PREFERRED.

    ``matplotlib.use(name)`` succeeds even when the underlying GUI bindings
    (PyQt/PySide, tkinter) are absent -- the ImportError only surfaces later
    at first ``pyplot.figure()``.  So each candidate is validated here by
    actually creating and closing a throwaway figure; only a backend that
    survives that is returned, otherwise the next candidate is tried.
    """
    import matplotlib

    order = ["QtAgg", "TkAgg"] if preferred == "qt" else ["TkAgg", "QtAgg"]
    last_exc = None
    for backend in order:
        try:
            matplotlib.use(backend, force=True)
            import matplotlib.pyplot as plt

            fig = plt.figure()
            plt.close(fig)
            return backend
        except Exception as exc:
            last_exc = exc
            continue
    # W8.7(b): no GUI backend validated.  Do NOT return the current
    # (non-interactive) backend and let run() crash later at plt.figure();
    # exit now with a distinct code + message so the Emacs manager can
    # surface a friendly "no Qt/Tk backend" failure from the stderr tail.
    sys.stderr.write(
        "ejn_viewer: no working GUI backend "
        "(tried %s; last error: %s)\n" % (", ".join(order), last_exc))
    sys.stderr.flush()
    sys.exit(3)


def _reattach_canvas(fig):
    """Bind ONE live GUI manager (canvas + toolbar) to the unpickled FIG.

    A figure that was managed by pyplot on the remote pickles with the
    ``restore_to_pylab`` flag, so ``pickle.load`` alone already reconstructs a
    real GUI manager for FIG under the active backend.  When that happened we
    MUST reuse it: the old recipe created a *second*, throwaway canvas and
    repointed it at FIG, which is exactly what split the toolbar + mouse events
    (bound to the first canvas/window) from the rendered figure (drawn on the
    second canvas/window).

    If no manager was restored (headless pickle), bind a fresh one to this
    exact figure via matplotlib's real API -- ``new_figure_manager_given_figure``
    -- so canvas, toolbar and figure are one manager/window.  A last-resort
    dummy-steal fallback keeps a window appearing if that private API ever
    changes.
    """
    import matplotlib.pyplot as plt
    from matplotlib._pylab_helpers import Gcf

    # (1) Reuse a manager the unpickle already built for THIS figure.
    #
    # restore_to_pylab normally ALSO registers that manager in Gcf.  Do not
    # gate reuse on Gcf membership, though: if we ever find a manager that
    # owns FIG but is somehow unregistered, register it and reuse it rather
    # than fall through and build a SECOND manager/window for the same figure
    # -- that second window is exactly the split this function exists to fix,
    # and the Gcf-blind cleanup in open_figure could never reap the orphan.
    mgr = getattr(fig.canvas, "manager", None)
    if (mgr is not None
            and getattr(mgr, "canvas", None) is not None
            and mgr.canvas.figure is fig):
        if mgr not in Gcf.figs.values():
            try:
                Gcf._set_new_active_manager(mgr)
            except Exception:
                pass
        return mgr

    # (2) Bind a fresh GUI manager directly to the existing figure.
    allnums = plt.get_fignums()
    num = (max(allnums) + 1) if allnums else 1
    try:
        get_mod = getattr(plt, "_get_backend_mod", None)
        backend_mod = get_mod() if get_mod is not None else plt._backend_mod
        manager = backend_mod.new_figure_manager_given_figure(num, fig)
        Gcf._set_new_active_manager(manager)
        return manager
    except Exception:
        # (3) Legacy dummy-steal fallback (kept only for resilience if the
        # private new_figure_manager_given_figure API ever changes).  Reuse a
        # freshly-managed figure's live canvas for FIG.
        #
        # Deliberately do NOT assign ``fig.number`` -- that setter is
        # deprecated in matplotlib 3.10 and raises in 3.12, and it is
        # unnecessary: ``plt.figure()`` already registered MANAGER in Gcf under
        # its own num, and both ``plt.close(fig)`` and open_figure's cleanup
        # match a figure by canvas identity (``manager.canvas.figure is fig``),
        # never by ``fig.number``.  Setting it bought nothing and was the one
        # 3.12-fatal call in this file.
        dummy = plt.figure()
        manager = dummy.canvas.manager
        manager.canvas.figure = fig
        fig.set_canvas(manager.canvas)
        return manager


def _install_enhancements(fig):
    """Install format_coord + linked zoom on FIG's imshow axes.

    Returns the list of imshow axes wired up.
    """
    imshow_axes = []
    for ax in fig.get_axes():
        images = ax.get_images()
        if not images:
            continue
        imshow_axes.append(ax)
        im = images[-1]
        arr = im.get_array()
        extent = im.get_extent()
        origin = getattr(im, "origin", "upper") or "upper"
        shape = getattr(arr, "shape", (0, 0))

        def _make_format_coord(extent, shape, arr, origin):
            def get_value(row, col):
                try:
                    return arr[row, col]
                except Exception:
                    return None

            def format_coord(x, y):
                return format_coord_text(extent, shape, get_value, x, y,
                                         origin=origin)

            return format_coord

        ax.format_coord = _make_format_coord(extent, shape, arr, origin)

    if len(imshow_axes) > 1:
        group = LinkGroup(imshow_axes)
        for ax in imshow_axes:
            ax.callbacks.connect("xlim_changed", group.on_lim_changed)
            ax.callbacks.connect("ylim_changed", group.on_lim_changed)
        # Keep a reference alive on the figure so the group is not GC'd.
        fig._ejn_link_group = group
    return imshow_axes


def open_figure(path):
    """Unpickle the figure at PATH, enhance it, and show it non-blocking.

    Deletes PATH afterwards.  Prints a clear message and returns ``None`` on
    unpickle/show failure so the caller keeps servicing the socket.
    """
    import matplotlib.pyplot as plt

    from matplotlib._pylab_helpers import Gcf

    fig = None
    try:
        with open(path, "rb") as handle:
            fig = pickle.load(handle)
    except Exception as exc:
        sys.stderr.write("ejn_viewer: failed to unpickle %s: %s\n" % (path, exc))
        sys.stderr.flush()
        _unlink(path)
        return None

    try:
        manager = _reattach_canvas(fig)
        _install_enhancements(fig)

        # Replace any previously-shown figure so re-running a cell (or opening
        # a figure repeatedly) does not pile up windows -- matches the panel's
        # latest-per-cell behaviour.  Close every managed figure EXCEPT the one
        # we just bound and any tagged anchor (the Qt socket-timer host).  Note
        # unpickling itself may already have registered MANAGER, so this must
        # run after the reattach, keyed on the surviving manager -- not before.
        keep_num = getattr(manager, "num", None)
        for num in list(plt.get_fignums()):
            if num == keep_num:
                continue
            other = Gcf.figs.get(num)
            if other is None or other is manager:
                continue
            if getattr(other.canvas.figure, "_ejn_is_anchor", False):
                continue
            try:
                plt.close(other.canvas.figure)
            except Exception:
                pass

        fig.canvas.draw_idle()
        try:
            manager.show()
        except Exception:
            pass
    except Exception as exc:
        sys.stderr.write("ejn_viewer: failed to display figure: %s\n" % exc)
        sys.stderr.flush()
        fig = None
    finally:
        _unlink(path)
    return fig


def _unlink(path):
    try:
        os.unlink(path)
    except OSError:
        pass


def _real_figure_count():
    """Number of real (non-anchor) figure windows currently open."""
    import matplotlib.pyplot as plt
    from matplotlib._pylab_helpers import Gcf

    count = 0
    for num in plt.get_fignums():
        mgr = Gcf.figs.get(num)
        if mgr is None:
            continue
        if getattr(mgr.canvas.figure, "_ejn_is_anchor", False):
            continue
        count += 1
    return count


def run(socket_path, backend_pref, idle_timeout):
    """Bind SOCKET_PATH and run the GUI loop, opening figures as paths arrive.

    The socket is serviced by a periodic pump driven by the GUI event loop, so
    the process stays responsive AND keeps that loop alive even when no figure
    window is open.  For the Tk backend the host is a dedicated *hidden*
    ``tkinter.Tk()`` root (created before any figure) so there is no blank
    anchor window and figure windows remain fully interactive; for other
    backends (Qt) a hidden matplotlib anchor figure hosts a canvas timer.
    """
    backend = _select_backend(backend_pref)

    try:
        os.unlink(socket_path)
    except FileNotFoundError:
        pass
    except OSError:
        pass

    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(8)
    server.setblocking(False)

    state = {"clients": {}, "last_activity": time.time()}

    def pump():
        """Service the socket once.  Return False to request GUI-loop exit."""
        # Accept any pending connections.
        while True:
            try:
                conn, _ = server.accept()
            except (BlockingIOError, OSError):
                break
            conn.setblocking(False)
            state["clients"][conn] = b""

        # Drain readable clients, opening a figure per complete line.
        for conn in list(state["clients"]):
            buf = state["clients"][conn]
            try:
                chunk = conn.recv(65536)
            except BlockingIOError:
                continue
            except OSError:
                state["clients"].pop(conn, None)
                continue
            if chunk:
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    # W8.7(f): the framing delimiter is the newline only.
                    # Do NOT `.strip()` — a temp path with legitimate
                    # leading/trailing spaces must survive intact.
                    line = line.rstrip(b"\r")
                    if line:
                        state["last_activity"] = time.time()
                        open_figure(line.decode("utf-8", "replace"))
                state["clients"][conn] = buf
            else:
                leftover = buf.rstrip(b"\r\n")
                if leftover:
                    state["last_activity"] = time.time()
                    open_figure(leftover.decode("utf-8", "replace"))
                try:
                    conn.close()
                finally:
                    state["clients"].pop(conn, None)

        # Idle self-exit: no traffic and no windows for the whole timeout.
        if idle_timeout and idle_timeout > 0:
            idle_for = time.time() - state["last_activity"]
            if idle_for > idle_timeout and _real_figure_count() == 0:
                return False
        return True

    if backend == "TkAgg":
        return _run_tk_host(pump, server, socket_path)
    return _run_mpl_host(pump, server, socket_path)


def _run_tk_host(pump, server, socket_path):
    """Drive PUMP from a hidden ``tkinter.Tk()`` root's event loop.

    The root is created (and withdrawn) BEFORE any figure so it becomes the
    default root while staying invisible.  matplotlib's Tk backend opens each
    figure as its own top-level Tk window; the shared Tcl notifier that this
    root's ``mainloop`` runs dispatches events to every one of them, so the
    figure windows remain fully interactive.  Because the root is withdrawn and
    is never a matplotlib manager, no blank window appears and figure-counting
    stays clean.
    """
    import tkinter as tk

    root = tk.Tk()
    root.withdraw()

    tick_state = {"logged_error": False}

    def tick():
        try:
            keep_going = pump()
        except Exception as exc:
            # Keep the loop alive across a transient hiccup, but surface the
            # cause once: pump() also owns the idle self-exit check, so a
            # persistent throw would otherwise wedge a silent, never-exiting
            # process.  One stderr line lets the Emacs manager report it.
            keep_going = True
            if not tick_state["logged_error"]:
                tick_state["logged_error"] = True
                sys.stderr.write(
                    "ejn_viewer: pump error (loop continues): %s\n" % exc)
                sys.stderr.flush()
        if keep_going:
            root.after(50, tick)
        else:
            try:
                root.quit()
            except Exception:
                pass

    root.after(50, tick)
    try:
        root.mainloop()
    finally:
        _shutdown(server, socket_path)
        try:
            root.destroy()
        except Exception:
            pass
    return 0


def _run_mpl_host(pump, server, socket_path):
    """Fallback host for non-Tk backends: a hidden anchor figure + canvas timer.

    The anchor is a real (tagged, hidden) matplotlib figure whose canvas timer
    drives PUMP; ``plt.show()`` runs the backend mainloop.
    """
    import matplotlib.pyplot as plt

    anchor = plt.figure("ejn-viewer")
    anchor._ejn_is_anchor = True
    try:
        anchor.canvas.manager.set_window_title("ejn viewer (socket host)")
    except Exception:
        pass
    _hide_window(anchor)

    hidden = {"done": False}

    def pump_and_hide():
        # `plt.show()` un-hides every managed figure once, including the anchor
        # withdrawn above; re-hide it once after the loop is running.
        if not hidden["done"]:
            _hide_window(anchor)
            hidden["done"] = True
        if pump() is False:
            _shutdown(server, socket_path)
            try:
                plt.close("all")
            except Exception:
                pass

    timer = anchor.canvas.new_timer(interval=50)
    timer.add_callback(pump_and_hide)
    timer.start()
    try:
        plt.show()
    finally:
        _shutdown(server, socket_path)
    return 0


def _hide_window(fig):
    """Best-effort hide of the anchor figure window (backend dependent)."""
    try:
        window = fig.canvas.manager.window
    except Exception:
        return
    for method in ("withdraw", "hide", "showMinimized"):
        try:
            getattr(window, method)()
            return
        except Exception:
            continue


def _shutdown(server, socket_path):
    try:
        server.close()
    except Exception:
        pass
    _unlink(socket_path)
    try:
        import matplotlib.pyplot as plt

        plt.close("all")
    except Exception:
        pass


# --------------------------------------------------------------------------
# Headless self-check (no GUI backend)
# --------------------------------------------------------------------------

def _selfcheck():
    failures = []

    def check(name, cond):
        if not cond:
            failures.append(name)

    # Default imshow extent, origin='upper', 3 rows x 4 cols.
    ext_u = (-0.5, 3.5, 2.5, -0.5)
    shape = (3, 4)
    check("upper-00", image_rowcol(ext_u, shape, 0.0, 0.0, "upper") == (0, 0))
    check("upper-23", image_rowcol(ext_u, shape, 3.0, 2.0, "upper") == (2, 3))
    check("upper-mid", image_rowcol(ext_u, shape, 1.0, 1.0, "upper") == (1, 1))
    check("upper-out-hi", image_rowcol(ext_u, shape, 10.0, 10.0, "upper") is None)
    check("upper-out-lo", image_rowcol(ext_u, shape, -5.0, 0.0, "upper") is None)

    # Default imshow extent, origin='lower'.
    ext_l = (-0.5, 3.5, -0.5, 2.5)
    check("lower-00", image_rowcol(ext_l, shape, 0.0, 0.0, "lower") == (0, 0))
    check("lower-20", image_rowcol(ext_l, shape, 0.0, 2.0, "lower") == (2, 0))
    check("lower-23", image_rowcol(ext_l, shape, 3.0, 2.0, "lower") == (2, 3))

    # Degenerate extent -> None.
    check("degenerate", image_rowcol((0, 0, 0, 0), shape, 0.0, 0.0) is None)

    # format_coord_text.
    def gv(row, col):
        return 42

    check("fmt-value", format_coord_text(ext_u, shape, gv, 1.0, 1.0, "upper")
          == "row=1 col=1 value=42")
    check("fmt-float",
          format_coord_text(ext_u, shape, lambda r, c: 3.5, 1.0, 1.0, "upper")
          == "row=1 col=1 value=3.5")
    check("fmt-outside",
          format_coord_text(ext_u, shape, gv, 99.0, 99.0, "upper").startswith("x="))
    check("fmt-none",
          "row=1 col=1" in
          format_coord_text(ext_u, shape, lambda r, c: None, 1.0, 1.0, "upper"))

    # LinkGroup with duck-typed fake axes.
    class FakeAx(object):
        def __init__(self, xl=(0, 1), yl=(0, 1)):
            self.xl = xl
            self.yl = yl
            self.calls = []

        def get_xlim(self):
            return self.xl

        def get_ylim(self):
            return self.yl

        def set_xlim(self, lim, emit=True):
            self.calls.append(("x", lim, emit))
            self.xl = lim

        def set_ylim(self, lim, emit=True):
            self.calls.append(("y", lim, emit))
            self.yl = lim

    # Linked zoom across subplots of DIFFERENT matrix sizes (the bug):
    # `a' spans 0..64 (a 64-wide/high image), `b' spans 0..100 (a 100-wide/
    # high image), y inverted for origin='upper'.  Propagation must be
    # RELATIVE to each axis' own base, and a reset must return each sibling
    # to ITS OWN base -- not inherit the reset axis' extent.
    a = FakeAx(xl=(0.0, 64.0), yl=(64.0, 0.0))
    b = FakeAx(xl=(0.0, 100.0), yl=(100.0, 0.0))
    group = LinkGroup([a, b])                 # captures per-axis base here
    # Zoom `a' to its top-left quarter: cols 0..16, rows 0..16 of 64.
    a.xl = (0.0, 16.0)
    a.yl = (16.0, 0.0)
    propagated = group.on_lim_changed(a)
    check("link-siblings", propagated == [b])
    check("link-not-self", a not in propagated)
    # `b' must crop to the SAME RELATIVE region of ITS base: 0..25 of 100.
    check("link-relative-x", b.xl == (0.0, 25.0))
    check("link-relative-y", b.yl == (25.0, 0.0))
    check("link-emit-false", all(call[2] is False for call in b.calls))
    check("link-no-self-mutation", a.calls == [])
    # Reset `a' to its full base -> `b' must return to ITS OWN full base
    # (0..100), NOT to `a''s 0..64.  This is the zoom-then-reset bug.
    b.calls = []
    a.xl = (0.0, 64.0)
    a.yl = (64.0, 0.0)
    group.on_lim_changed(a)
    check("link-reset-own-base-x", b.xl == (0.0, 100.0))
    check("link-reset-own-base-y", b.yl == (100.0, 0.0))

    # Recursion guard: a re-entrant call is a no-op returning [].
    group._busy = True
    check("link-guard", group.on_lim_changed(a) == [])
    group._busy = False

    total = 22
    if failures:
        sys.stderr.write("SELFCHECK FAILED (%d/%d): %s\n"
                         % (len(failures), total, ", ".join(failures)))
        return 1
    sys.stdout.write("SELFCHECK OK (%d checks passed)\n" % total)
    return 0


def _parse_args(argv):
    parser = argparse.ArgumentParser(description="emacs-jupyter-notebook local "
                                                 "interactive matplotlib viewer")
    parser.add_argument("--socket", help="unix-domain socket path to listen on")
    parser.add_argument("--backend", default="qt", choices=["qt", "tk"],
                        help="preferred GUI backend")
    parser.add_argument("--idle-timeout", type=int, default=900,
                        help="seconds of idleness before self-exit (0 disables)")
    parser.add_argument("--selfcheck", action="store_true",
                        help="run the headless non-GUI self-check and exit")
    return parser.parse_args(argv)


def main(argv=None):
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    if args.selfcheck:
        return _selfcheck()
    if not args.socket:
        sys.stderr.write("ejn_viewer: --socket is required\n")
        return 2
    return run(args.socket, args.backend, args.idle_timeout)


if __name__ == "__main__":
    sys.exit(main())
