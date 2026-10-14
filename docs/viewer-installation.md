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

The manager adds `--stdio` and `--memory-budget-mib`, so the command must be
a viewer build that accepts both; do not add `--demo` to this command. Update the
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

Publish a mapping of selected 2D NumPy arrays or PyTorch tensors with `ejn.view`, then use
`C-c j I`, the panel's `[Inspect]` button, or `C-c j J` (evaluate-and-inspect).
The latter opens the first numerical publication from that exact execution.
Once inspected, matching publications from that source cell follow into the
open workspace without stealing focus. Other cells and workspace keys do not
replace the selection. Clear/reconnect/source retirement fences old updates.

For an existing NumPy or PyTorch variable, use `C-c j A` at its name or `v` in the variable
table. View remembers valid display axes and remaining slice/channel indices.
`C-u C-c j A` offers live arrays with completion; enter up to four names
separated by commas to view a group. `C-u C-u C-c j A` reconfigures selections
and offers explicit 3D crops. Only selected samples go through the existing
bounded artifact path; full remote volumes are never transferred implicitly.
Generated inspection requests do not add to IPython input history, but appear
in EJN's execution trail for saved context. Unsupported dtypes, empty axes and
oversized selections report an error. Reading a new selection requires an idle
kernel; opening an existing published output and reviewing saved findings do not.
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
statistics table or line profile without removing selections or results. Both
the measurement panel and magnifier start hidden. Pixel values, analysis messages and the
following/frozen/pinned evaluation status remain visible below the images;
hover over shortened status text to read it in full.

**Capture** (`Ctrl+S`, or `C-c j C` / Doom `SPC m C`) freezes the displayed
graphics and selected numerical planes before asking for an optional note.
The image includes the current axes/ROI markings and excludes transient cursor
crosshairs. Pinned and current panes retain separate execution identities and
their recorded code context. Capture uses the current display even when a
new publication or slice is pending; it never runs code or waits for a new
prediction. An in-progress save remains independent of closing its workspace.

**Findings** (`C-c j f` / `SPC m f`, or `ejn-viewer --findings`) reopens the
durable collection without a kernel. Review thumbnails, edit notes and copy
the image with its caption into an existing presentation. Findings are listed
chronologically. **Remove** deletes only explicitly selected saved findings.

`C-c j O` / Doom `SPC m O` generates and opens an Org overview in Emacs.
`M-x emacs-jupyter-notebook-findings-overview` also works without a notebook.
The generated `findings.org` sits beside the finding directories and uses
relative links: image previews, full images, context JSON and NumPy data.
Each observation has a heading and folded context. The overview uses sharp
previews up to 800×600 pixels and loads only visible images, with at most eight
decoded at a time. Offscreen previews are released as you scroll; the original
full-resolution capture remains linked separately.
Generation is explicit and atomic; a modified generated file or unsaved
overview is preserved. Use `C-x C-w` to save a separate, editable report in the
same directory, or move the whole folder to keep relative links intact.
The capture workflow requires no Org editing or slide-generation dependency.

Finding directories live under `${XDG_DATA_HOME:-~/.local/share}/ejn/findings`
with private permissions. Each contains a versioned `finding.json`, captured
PNG, overview preview, thumbnail and lossless `.npy` planes. The default/hard collection limits
are 1,000 findings and 2 GiB; saved items are never silently evicted. Context
is bounded to 24 KiB per retained source snapshot and marks missing/omitted
code explicitly. It records executions observed by EJN, not all kernel state
or a guarantee that arbitrary external dependencies can be reconstructed.

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
in the candidate pane; release to return. Difference/blink require matching
sample lattices. Linked readouts and navigation also support different sampling
densities in the same declared physical frame. **Freeze** retains the visible
evaluation and discards incoming updates; unfreeze follows subsequent
publications. The status line identifies the visible and pinned executions.

To flip between **input A**, **prediction B**, and **next prediction C**, publish
`{"input": input_image, "prediction": prediction}`. In **Compare**, select
**prediction** as Reference and pin it before changing checkpoints. Reuse the
same Python variables and publish again with the same workspace/sample.
Use the image selector or `[` / `]` to show one retained image at a time.
Compatible zoom and slice state survive flipping. Comparison views remain
available; Reference/Candidate select the pair used for differences. Apply
per-member spacing when their grids differ.
Compatible measurement statistics and line-profile curves remain available for
all retained images while a single image is selected.
In **All images**, panes have equal image areas and aligned axis gutters.
Long image names and wider coordinate labels do not make one pane wider;
the layout stays equal when resizing or returning from a single image.

Open **Measurements**, choose an ROI pane and click **Rectangle ROI** or
**Ellipse ROI**. Drag its body to move it and its handle to resize it. ROIs appear on corresponding
panes, including the difference. The table shows mean, population SD
(`ddof=0`), finite pixel count and excluded non-finite count for each pane.
Select a named ROI to remove it. Up to 16 ROIs are retained, including across
compatible reruns of the same sample/grid. **Draw ROI** lets you drag a new
line, rectangle or ellipse directly on an image (`Esc` cancels). Select an ROI to
rename it; arrow keys while the image has focus move it one pixel, or ten with
`Shift`. **Copy statistics** copies the measurement table as tab-separated text.

For edge comparisons, choose **Draw ROI → Draw line**, then drag from **A** to
**B** across an image. The measurement panel opens after release with overlaid,
color-labeled profiles for every corresponding visible image, including a
pinned reference and any displayed difference. Drag either endpoint to change
the line, or drag its body to move it. Select another named line to plot that
selection; selecting a rectangle or ellipse returns to the statistics table.
Toggle **Measurements** to recover image space while retaining the line.

Line profiles show values against distance from A, in **pixels** by default or
declared physical units (such as **mm**) when spacing is supplied, with each
curve's intensity units in its legend. Grid correspondence follows the same
rules as linked ROIs: a common sample and physical frame, or matching pixel
grids without spatial metadata. A common grid ID or an explicit **Declare
matching grids** selection is required for images whose grid IDs are absent.
No intensity normalization or unit conversion
is applied. To compare evaluations, pin the reference before rerunning the
same sample/grid; the line stays in place and the candidate profile updates.

Profiles use bilinear interpolation at evenly spaced positions along the line,
including both endpoints of the portion inside the image. Pixel centers lie
at `(column + 0.5, row + 0.5)`; outer pixel values extend to the image boundary.
Clipping retains distances from the original A endpoint. Spacing is at most
one pixel, up to **4096 samples** per curve; longer lines show a sample-limit
notice and use wider spacing. Non-finite contributing pixels leave gaps.
Only the selected line is sampled, in the existing local worker after dragging
finishes. Changing zoom, window/level or blink does not change the profile.

Measurements use original samples and source pixel centers, independently of
zoom or window/level. Rectangles include their left/top edges and exclude
right/bottom edges; ellipses include centers on their boundary. Selections
are clipped to each plane. Empty/all-non-finite selections show unavailable
statistics, and one finite pixel has SD zero. Arithmetic uses float64 with
stable block accumulation. RGB/rendered images do not offer these quantitative
controls. Difference/statistics/profile work is debounced and runs in a bounded
local worker; it makes no requests to the kernel.

Hovering an image places linked crosshairs on corresponding panes and displays
reference, candidate and difference values at the same sample location. A
patch of at most 31×31 samples, enabled in **Options → Magnifier**, uses original
samples with nearest-neighbor display; non-finite values remain identifiable
and out-of-image locations are unavailable.
With physical spacing, linked magnifiers show the same physical field of view
using each array's own samples.

To compare an upsampled axis, publish `spacing` for each member, for example
`spacing={"original": (0.2, 0.2), "upsampled": (0.1, 0.2)}` for row/column
spacing. For 3D crops use three entries in source-axis order. One tuple applies
to every member; a mapping gives each member its own tuple. Set a common
`grid_id` and `sample_id` to declare alignment. `spatial_units` defaults to
`"mm"`; optional `origin` in the same tuple/mapping form gives the physical
center of sample index zero, defaulting to zero. Crop origins must include the
crop offset in physical units. Intensity units remain a separate option.

Physical axis ticks, aspect ratio, linked zoom, cursor and ROI geometry honor
the declared spacing and origins. Each ROI is measured from that member's own
sample centers, so pixel counts can differ at different resolutions. Volume
slice controls link nearest physical positions and show the actual position.
Differences/blink report incompatible sampling until the arrays themselves
share the same lattice; the viewer performs no automatic resampling.

Current controls: pinch to zoom around the pointer, two-finger scroll to pan,
mouse wheel to zoom, drag to pan, `F` to fit, hover for source pixel values,
and edit level/width. Native pinch uses Qt's macOS/Wayland gesture events;
platforms that do not deliver these events retain mouse-wheel zoom. Touchpad
scrolling uses pixel deltas when available, with an angle-delta fallback for
devices identified as touchpads. System natural-scrolling direction is retained.
Pan/zoom link for explicitly declared pixel grids or compatible physical
frames. Linked panes share center and scale in the displayed units, including
when navigating from a prediction.
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

Publish one to four planes or explicit 3D crops, at most 32 MiB per member and 64 MiB per group
including its header, with each dimension at most 16384. Supported types are
8/16/32-bit signed/unsigned integers and 16/32/64-bit floats, with explicit byte
order. Unsupported dtypes or oversized planes fail rather than being silently
downcast. PyTorch bfloat16 is widened losslessly to float32 and counted at that
size. Slice/crop GPU tensors **before** passing them to `ejn.view`; the publisher
handles detachment and CPU conversion after validating budgets. These limits do
not make base64 transport cheap: each selected group is transferred in full;
there is no remote tiling or incremental update protocol yet. For a supplied
3D crop, the viewer's plane selector and slice slider/number browse locally.
Page Up/Down and Shift+wheel step slices. Axes are source array dimensions,
not anatomical labels; 3D always means scalar volume, never RGB. Compatible
volumes and pinned references browse together. Use a different `sample_id`
when the crop location changes, even if its shape is unchanged.

The viewer keeps independent, read-only in-memory snapshots, not disk copies.
Clearing output or killing the source/panel cannot invalidate a loaded image.
Snapshots are disposable on workspace close, viewer crash, or Emacs exit;
there are no snapshot files to recover or orphan-clean. The application admits
at most four workspaces against one accounting budget including source
and estimated display/load buffers; Qt/Python overhead is additional.

Differences are limited to 32 MiB of float64 samples; source images, derived
displays, pending loads, analysis scratch and finding capture/review share the
viewer's accounting budget, including pinned snapshots and active worker
references. Over-budget requests report an error and leave the source samples
intact. The budget is 2 GiB by default. Emacs passes
`emacs-jupyter-notebook-inspector-memory-budget` (MiB) as
`--memory-budget-mib`; the viewer accepts 256 MiB through 1 TiB and reads the
value at startup. Findings reserve memory from the saved image's recorded size
and dimensions, and captured views of loaded samples are charged once.

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
