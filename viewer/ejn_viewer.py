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
    """

    def __init__(self, axes):
        self.axes = list(axes)
        self._busy = False

    def on_lim_changed(self, changed_ax):
        """Copy CHANGED_AX's limits onto every sibling; return those siblings.

        A re-entrant call (while a propagation is in flight) is a no-op that
        returns ``[]`` -- this is the recursion guard.
        """
        if self._busy:
            return []
        self._busy = True
        propagated = []
        try:
            xlim = changed_ax.get_xlim()
            ylim = changed_ax.get_ylim()
            for ax in self.axes:
                if ax is changed_ax:
                    continue
                ax.set_xlim(xlim, emit=False)
                ax.set_ylim(ylim, emit=False)
                propagated.append(ax)
        finally:
            self._busy = False
        return propagated


# --------------------------------------------------------------------------
# GUI logic (matplotlib required)
# --------------------------------------------------------------------------

def _select_backend(preferred):
    """Select QtAgg/TkAgg (preferring PREFERRED) and return the chosen name."""
    import matplotlib

    order = ["QtAgg", "TkAgg"] if preferred == "qt" else ["TkAgg", "QtAgg"]
    for backend in order:
        try:
            matplotlib.use(backend, force=True)
            return backend
        except Exception:
            continue
    return matplotlib.get_backend()


def _reattach_canvas(fig):
    """Give an unpickled, canvas-less FIG a live GUI canvas/manager.

    Recipe: create a throwaway pyplot figure to obtain a real backend manager,
    then point that manager's canvas at FIG (and FIG's canvas back at it).  The
    dummy figure object is discarded; its window now hosts FIG.
    """
    import matplotlib.pyplot as plt

    dummy = plt.figure()
    manager = dummy.canvas.manager
    manager.canvas.figure = fig
    fig.set_canvas(manager.canvas)
    try:
        fig.number = dummy.number
        from matplotlib._pylab_helpers import Gcf

        Gcf.figs[dummy.number] = manager
    except Exception:
        pass
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
        _reattach_canvas(fig)
        _install_enhancements(fig)
        fig.canvas.draw_idle()
        try:
            fig.canvas.manager.show()
        except Exception:
            pass
        plt.show(block=False)
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


def _any_real_figures_open():
    """Return True when a real (non-anchor) figure window is open."""
    import matplotlib.pyplot as plt

    # The hidden anchor figure that hosts the socket timer always counts 1.
    return len(plt.get_fignums()) > 1


def run(socket_path, backend_pref, idle_timeout):
    """Bind SOCKET_PATH and run the GUI loop, opening figures as paths arrive."""
    _select_backend(backend_pref)
    import matplotlib.pyplot as plt

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
                    line = line.strip()
                    if line:
                        state["last_activity"] = time.time()
                        open_figure(line.decode("utf-8", "replace"))
                state["clients"][conn] = buf
            else:
                leftover = buf.strip()
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
            if idle_for > idle_timeout and not _any_real_figures_open():
                _shutdown(server, socket_path)
                return False
        return True

    anchor = plt.figure("ejn-viewer")
    try:
        anchor.canvas.manager.set_window_title("ejn viewer (socket host)")
    except Exception:
        pass
    _hide_window(anchor)

    timer = anchor.canvas.new_timer(interval=50)
    timer.add_callback(pump)
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

    a = FakeAx(xl=(5, 10), yl=(2, 8))
    b = FakeAx()
    c = FakeAx()
    group = LinkGroup([a, b, c])
    propagated = group.on_lim_changed(a)
    check("link-siblings", set(id(x) for x in propagated) == set([id(b), id(c)]))
    check("link-not-self", a not in propagated)
    check("link-copies", b.xl == (5, 10) and b.yl == (2, 8))
    check("link-emit-false", all(call[2] is False for call in b.calls))
    check("link-no-self-mutation", a.calls == [])

    # Recursion guard: a re-entrant call is a no-op returning [].
    group._busy = True
    check("link-guard", group.on_lim_changed(a) == [])
    group._busy = False

    total = 21
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
