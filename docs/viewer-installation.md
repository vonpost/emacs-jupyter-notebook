# Local viewer (W21)

The numerical viewer is a separate local application. It does not install
anything on a remote host and is not part of the headless helper runtime.

With Nix and the pinned flake:

```sh
nix build .#ejn-viewer
./result/bin/ejn-viewer --demo
```

The demo displays two asymmetric row-major NumPy planes. The application also
accepts real numerical publications from Emacs over its bounded stdio protocol.
Normally Emacs builds this separate output asynchronously on first inspection;
the manual build above is optional. To use a manually built executable, set:

```elisp
(setq emacs-jupyter-notebook-inspector-command
      '("/absolute/path/to/result/bin/ejn-viewer"))
```

The manager adds `--stdio`; do not add `--demo` to this command. Update the
bundled helper as well as the Elisp files, then reconnect to inject `ejn.view`
into the existing kernel. No remote installation or kernel restart is required.
The Doom package recipe must include `array_protocol` alongside `helper`,
`viewer`, `registry_worker` and the flake files.

Publish a mapping of selected 2D NumPy arrays with `ejn.view`, then use
`C-c j I`, the panel's `[Inspect]` button, or `C-c j J` (evaluate-and-inspect).
The latter opens the first numerical publication from that exact execution.
Ordinary evaluation does not automatically replace an open workspace.

Current controls: scroll to zoom, drag to pan, `F` to fit, hover for source
pixel values, and edit level/width. Pan/zoom link only for matching, explicitly
declared grids. There is no native-device-pixel mode yet, so fit/zoom alone
must not be taken as a validated Retina resolution test. Rendering disables
automatic downsampling; the original numerical samples remain unchanged.

## Bounds and remaining work

Publish one to four planes, at most 32 MiB per plane and 64 MiB per group
including its header, with each dimension at most 16384. Supported types are
8/16/32-bit signed/unsigned integers and 32/64-bit floats, with explicit byte
order. Unsupported dtypes or oversized planes fail rather than being silently
downcast. Slice GPU tensors **before** copying to CPU/NumPy. These limits do
not make base64 transport cheap: each selected group is transferred in full;
there is no remote slider, tiling, or incremental update protocol yet.

The viewer keeps independent, read-only in-memory snapshots, not disk copies.
Clearing output or killing the source/panel cannot invalidate a loaded image.
Snapshots are disposable on workspace close, viewer crash, or Emacs exit;
there are no snapshot files to recover or orphan-clean. The application admits
at most four workspaces against a 256 MiB accounting budget including source
and estimated display/load buffers; Qt/Python overhead is additional.

Pinned baselines, diffs/blink, magnifiers, ROI statistics, follow/freeze,
native-pixel verification, and routing ordinary PNG/JPEG outputs into this
viewer are unfinished. PNG/JPEG originals still open with the panel's `o`.
See [VIEWER_PLAN.md](../VIEWER_PLAN.md) for the full release gates.

## Verification

A non-GUI smoke check is available for packaging checks:

```sh
QT_QPA_PLATFORM=offscreen ./result/bin/ejn-viewer --smoke-test --offscreen
```

For the graphical acceptance gate, run `ejn-viewer --smoke-test` on an actual
macOS or Linux display and retain the emitted JSON evidence with the display,
scaling, hardware, and timings.

V2 has been visibly exercised on Linux (`DISPLAY=:0`, with a paint/resize/
close smoke result). macOS graphical rendering has not yet been run in this
environment; the `aarch64-darwin` derivation is evaluated by the flake and
still requires an actual macOS display run before the V2 gate is complete.
