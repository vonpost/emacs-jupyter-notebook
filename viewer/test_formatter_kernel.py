#!/usr/bin/env python3
"""Real-kernel regression test for the W8 figure-pickle injection.

This is the test that a mocked ERT payload and a bare-`InteractiveShell`
check both missed: the injected snippet must emit a VALID base64
`pickle.dumps(fig)` under `application/x-ejn-mpl-pickle` -- ALONGSIDE the
inline `image/png` -- when run in a REAL ipykernel with the matplotlib
inline backend active (the environment where an IPython display-formatter
registration gets wiped on the first plot).

It spins an actual `ipykernel` via `jupyter_client`, injects the exact
snippet extracted from `emacs-jupyter-notebook.el`, runs the worst case
(import + plot + return the figure in a single cell), and asserts the
payload decodes and unpickles.

Skips (exit 0) when jupyter_client / ipykernel / matplotlib are not
available, so it never blocks environments without the deps.  Run it where
those are present (e.g. inside the viewer's nix shell) to guard the fix.
"""
import os
import queue
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
EL = os.path.join(HERE, "..", "emacs-jupyter-notebook.el")
DEFCONST = "(defconst emacs-jupyter-notebook--viewer-formatter-snippet"


def extract_snippet(path):
    """Return the elisp string value of the W8 formatter-snippet defconst."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    i = text.index(DEFCONST) + len(DEFCONST)
    i = text.index('"', i) + 1                      # opening quote of the value
    out = []
    while i < len(text):
        ch = text[i]
        if ch == "\\":
            nxt = text[i + 1]
            out.append({"n": "\n", "t": "\t", "\n": "", '"': '"', "\\": "\\"}
                       .get(nxt, nxt))
            i += 2
            continue
        if ch == '"':
            break
        out.append(ch)
        i += 1
    return "".join(out)


def main():
    try:
        from jupyter_client import KernelManager
        import matplotlib  # noqa: F401  (ensure the kernel env has it)
    except Exception as exc:  # pragma: no cover - environment guard
        print("SKIP (missing deps): %r" % (exc,))
        return 0

    snippet = extract_snippet(EL)
    km = KernelManager(kernel_name="python3")
    km.start_kernel()
    kc = km.client()
    kc.start_channels()
    kc.wait_for_ready(timeout=60)

    def run(code, silent=False):
        mid = kc.execute(code, silent=silent, store_history=False)
        data = []
        while True:
            try:
                m = kc.get_iopub_msg(timeout=40)
            except queue.Empty:
                break
            if m["parent_header"].get("msg_id") != mid:
                continue
            t = m["msg_type"]
            c = m["content"]
            if t in ("execute_result", "display_data"):
                data.append(c["data"])
            elif t == "status" and c["execution_state"] == "idle":
                break
        return data

    failures = []
    try:
        run(snippet, silent=True)  # inject at "connect" time
        # Worst case: import + plot + return the figure in ONE cell, with the
        # inline backend configuring itself mid-cell on the first plot.
        data = run(
            "import numpy as np, matplotlib.pyplot as plt\n"
            "f, a = plt.subplots(1, 3)\n"
            "[x.imshow(np.random.rand(8, 8)) for x in a]\n"
            "f")
        import base64
        import binascii
        import pickle
        K = "application/x-ejn-mpl-pickle"
        bundle = next((d for d in data if K in d), None)
        if bundle is None:
            failures.append("no display bundle carried the pickle MIME")
        else:
            if "image/png" not in bundle:
                failures.append("inline image/png missing (PNG path regressed)")
            v = bundle.get(K)
            try:
                blob = base64.b64decode(v, validate=True)
            except (binascii.Error, ValueError, TypeError):
                failures.append("payload is not valid base64 (got %r)"
                                % (v[:40] if isinstance(v, str) else type(v),))
            else:
                fig = pickle.loads(blob)
                if len(fig.axes) != 3:
                    failures.append("unpickled figure has %d axes, expected 3"
                                    % len(fig.axes))
    finally:
        km.shutdown_kernel(now=True)

    if failures:
        for f in failures:
            print("FAIL:", f)
        return 1
    print("PASS: real-kernel figure pickle payload is valid base64 + unpickles")
    return 0


if __name__ == "__main__":
    sys.exit(main())
