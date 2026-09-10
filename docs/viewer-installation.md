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

Inspection now reports each step to both `*Messages*` and the EJN log
(`C-c j L`): building, waiting for an existing build, starting the viewer,
loading images, and the final result. Nix progress is reported independently
of the kernel connection status. `M-x emacs-jupyter-notebook-inspector-status`
shows the current local viewer phase and last diagnostic without contacting
the kernel. A subsequent Inspect recovers a stale local build token or dead
viewer process; it never re-evaluates the source cell.

The automatic build deadline is `emacs-jupyter-notebook-runtime-build-timeout`
(default 600 seconds, maximum 1800). The separate 15-second viewer startup
deadline begins only after the build completes. A terminal `nix run` is a
separate operation and its progress does not establish that Emacs started a
build. The package excludes PyQtGraph's unused PyQt6 test dependency, which
otherwise pulls QtWebEngine through PyQt6's PDF support on macOS. It continues
to use PySide6; no browser engine is required by the viewer.

If a tunnel exits, the EJN transport log now includes its exit status or
signal and a bounded, redacted stderr excerpt when available. Viewer startup
failure itself does not request tunnel reconnection or terminate a kernel.

Publish a mapping of selected 2D NumPy arrays with `ejn.view`, then use
`C-c j I`, the panel's `[Inspect]` button, or `C-c j J` (evaluate-and-inspect).
The latter opens the first numerical publication from that exact execution.
Once inspected, matching publications from that source cell follow into the
open workspace without stealing focus. Other cells and workspace keys do not
replace the selection. Clear/reconnect/source retirement fences old updates.

For an existing NumPy variable, use `C-c j A` at its name or `v` in the variable
table. Emacs prompts for display axes and any remaining slice/channel indices.
Only that 2D plane goes through the existing bounded artifact path; the full
volume remains in the kernel. Generated inspection requests do not add to input
history. Unsupported dtypes, empty axes and oversized planes report an error.
Reopen the variable to choose another plane; this requires an idle kernel.
Variable names and shapes do not establish physical alignment or intensity
units. Use the viewer's explicit grid/unit declarations for comparisons, or
publish those metadata yourself with `ejn.view`.

For quantitative comparison, publish corresponding planes with their sample,
grid and intensity units:

```python
ejn.view({"reference": reference[z], "candidate": candidate[z]},
         key="comparison", sample_id=f"case-1/slice-{z}",
         grid_id="reconstruction-grid", units="intensity")
```

The viewer opens with one compact toolbar and the rest of the window devoted
to images. **Fit**, level/width and **Draw ROI** remain directly accessible.
**Compare** opens the image selectors, difference modes, pin/blink controls
and grid/unit declarations. **Options** contains **Freeze updates** and the
optional **Magnifier**. **Measurements** shows or hides ROI tools and the
statistics table without removing selections or results. Both the measurement
panel and magnifier start hidden. Pixel values, analysis messages and the
following/frozen/pinned evaluation status remain visible below the images;
hover over shortened status text to read it in full.

In **Compare**, use the Reference and Candidate selectors and choose **Signed
difference** (`candidate − reference`) or **Absolute difference**. If neither
plane declares grids or units, the checkboxes let you explicitly declare
matching grids and common units. Conflicting metadata cannot be overridden.
Differences use float64 arithmetic, preserving negative differences of
unsigned images, with a separate display range. Non-finite or overflowing
differences become unavailable pixels.

Choose the reference member in **Compare** and click **Pin reference** before
rerunning. Its immutable local snapshot remains available while the candidate follows new
publications. Hold **B** or the blink button to temporarily show the reference
in the candidate pane; release to return. Comparisons and linked readouts
require compatible sample/grid metadata. **Freeze** retains the visible
evaluation and discards incoming updates; unfreeze follows subsequent
publications. The status line identifies the visible and pinned executions.

Open **Measurements**, choose an ROI pane and click **Rectangle ROI** or
**Ellipse ROI**. Drag its body to move it and its handle to resize it. ROIs appear on corresponding
panes, including the difference. The table shows mean, population SD
(`ddof=0`), finite pixel count and excluded non-finite count for each pane.
Select a named ROI to remove it. Up to 16 ROIs are retained, including across
compatible reruns of the same sample/grid. **Draw ROI** lets you drag a new
rectangle or ellipse directly on an image (`Esc` cancels). Select an ROI to
rename it; arrow keys while the image has focus move it one pixel, or ten with
`Shift`. **Copy statistics** copies the measurement table as tab-separated text.

Measurements use original samples and source pixel centers, independently of
zoom or window/level. Rectangles include their left/top edges and exclude
right/bottom edges; ellipses include centers on their boundary. Selections
are clipped to each plane. Empty/all-non-finite selections show unavailable
statistics, and one finite pixel has SD zero. Arithmetic uses float64 with
stable block accumulation. RGB/rendered images do not offer these quantitative
controls. Difference/statistics work is debounced and runs in a bounded local
worker; it makes no requests to the kernel.

Hovering an image places linked crosshairs on corresponding panes and displays
reference, candidate and difference values at the same sample location. A
31×31 magnified patch, enabled in **Options → Magnifier**, uses original
samples with nearest-neighbor display; non-finite values remain identifiable
and out-of-image locations are unavailable.

Current controls: pinch to zoom around the pointer, two-finger scroll to pan,
mouse wheel to zoom, drag to pan, `F` to fit, hover for source pixel values,
and edit level/width. Native pinch uses Qt's macOS/Wayland gesture events;
platforms that do not deliver these events retain mouse-wheel zoom. Touchpad
scrolling uses pixel deltas when available, with an angle-delta fallback for
devices identified as touchpads. System natural-scrolling direction is retained.
Pan/zoom link only for matching, explicitly declared grids. Linked panes share
image center and magnification, including when navigating from a prediction.
Panning and resizing after navigation retain magnification; narrower panes
show less of the image rather than changing its scale. `F` fits all linked
images at a common scale. Navigation never requests new data from the remote.

After updating the package, restart Emacs and Inspect again to use the updated
viewer build; an already-running viewer still has its old code loaded. Reconnect
to the existing kernel rather than restarting it.

There is no native-device-pixel mode yet, so fit/zoom alone
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

Differences are limited to 32 MiB of float64 samples; source images, derived
displays, pending loads and analysis scratch share the viewer's 256 MiB
accounting budget, including pinned snapshots and active worker references.
Over-budget requests report an error and leave the source samples intact.

Native-pixel verification and routing ordinary PNG/JPEG outputs into this
viewer remain unfinished. PNG/JPEG originals still open with the panel's `o`.
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
The user has since confirmed a working macOS viewer window; native gesture
feel and Retina pixel fidelity still require checks on that machine.
