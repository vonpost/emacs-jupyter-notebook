# EJN numerical slice and viewer contract 1

W21 V1, 2026-09-06. This contract defines the new numerical path. It does not
enable it in production until V3-V6 implement publication, admission and UI.

## Versions and boundaries

The helper's existing frame/envelope version remains 1. Add the negotiated
`array-group-v1` hello capability before enabling numerical publication on
connect. A missing capability disables the numerical path with a clear
message; no fallback serialization. No existing frame/artifact limit is
raised. A numerical group is one additional supported MIME/artifact type:
`application/x-ejn-array-group`. Its content format has its own version 1.
Hello capabilities are a vector of at most 32 distinct nonempty printable
ASCII tokens, each at most 64 characters. Unknown well-formed tokens are
retained for feature negotiation; absence is not inferred from a version.

The remote publisher emits a single base64 string under this MIME through
IPython `display(..., raw=True)`, with a short `text/plain` summary. It does
not emit duplicate plane PNGs or a matplotlib pickle. The helper validates
and spools the group in its bounded artifact worker. Only a JSON artifact descriptor
and bounded manifest summary cross helper stdout; the array bytes never do.

The local viewer is a separate PySide6/PyQtGraph process, launched as
`ejn-viewer --stdio` from the pinned Nix output. It has no Jupyter,
SSH, remote-file, kernel-lifecycle, or arbitrary-code-execution interface.

## Numerical group file

Bytes: ASCII `EJNARR01` (8 bytes), unsigned big-endian 32-bit JSON header
length, that many UTF-8 header bytes, followed by concatenated C-order raw
plane bytes. No compression in version 1: bounded planes avoid codec and
decompression complexity. A later compression capability must keep decoded
limits and fidelity unchanged. Reject duplicate JSON keys, NaN/Infinity
metadata, unknown required shapes/types, trailing data and truncated files.

Header object:

```json
{
  "v": 1,
  "key": "reconstruction",
  "sample_id": "case-17/slice-120",
  "publication_id": "9c3d574d90f64715a5d7168eb722df93",
  "planes": [
    {
      "id": "0", "name": "reference", "shape": [512, 512],
      "dtype": "<u2", "offset": 0, "nbytes": 524288,
      "grid_id": "aligned", "units": "HU"
    }
  ]
}
```

`publication_id` is a fresh 32-character lowercase hex UUID per publish.
The trusted local execution/session generation is attached by the helper /
Emacs ledger; remote-provided fields cannot override that identity. IDs are
unique within a group. `key`, `sample_id`, `id`, `name`, `grid_id` and `units`
are bounded strings; empty optional grid/units mean unspecified, not HU.

Plane shape is `[rows, columns]`; an explicit scalar volume has shape
`[axis0, axis1, axis2]` in source dimension order. A rank-three member never
means RGB. The viewer selects a two-dimensional view from retained local
samples; it does not request further kernel data. Uncalibrated plane coordinates
have zero-based row/column indices and origin at the upper left.
Integer index `(row,col)` identifies a sample;
its display pixel center is `(col+0.5,row+0.5)`. Raw bytes preserve dtype and
byte order; supported dtype strings are `|u1`, `|i1`, `<u2`, `>u2`, `<i2`,
`>i2`, `<u4`, `>u4`, `<i4`, `>i4`, `<f2`, `>f2`, `<f4`, `>f4`, `<f8`, `>f8`.
No bool, object, structured, complex or int64/uint64 arrays in v1;
reject unsupported types explicitly, without automatic casts.
Masked arrays are rejected because v1 has no mask payload; their hidden
backing values must never silently become measurement samples.

Offsets start at zero and are exactly contiguous in plane order, with no
overlap, holes or unused tail. `nbytes == product(shape) * dtype.itemsize`.
The final file length must equal 12 + header length + sum(nbytes).
The aggregate ceiling includes framing/header bytes: two exactly 32 MiB
planes (or four 2048x2048 float32 planes) do not fit one 64 MiB group. Reject
that group before copying; callers publish fewer/smaller selected planes.
Optional `spacing` has one finite positive number per source axis; `origin`
has one finite number per axis and names the center of sample index zero.
`direction` is a flattened nonsingular row-major 2x2 or 3x3 matrix according
to member rank. The publisher emits identity directions for axis-aligned grids.
`spatial_units` is a separate optional bounded string (e.g. `mm`), never
the intensity `units`. All four spatial fields are present together or all
absent. Absent metadata matches absent metadata only and does not imply mm.
With explicit spatial metadata, common sample/grid identity and spatial units
link physical navigation even across different shapes, spacing and origins.
Pixel-edge coordinate `(x,y)` maps to `(origin_col + (x-.5)*spacing_col,
origin_row + (y-.5)*spacing_row)`. Volume slices project the two retained
source axes and record their physical slice coordinate. Differences require
identical sample lattices and slice positions; no automatic resampling occurs.
Equal-shaped planes without a nonempty common grid_id remain unlinked until
the user explicitly declares correspondence locally.

## Publisher API

`ejn.view(planes, *, key="default", sample_id, grid_id=None, units=None,
spacing=None, origin=None, spatial_units="mm")`
accepts an insertion-ordered mapping of 1-4 names to NumPy arrays or exact
PyTorch Tensor/Parameter instances, each a 2D plane or explicit 3D crop.
`grid_id` declares a common coordinate frame within the same sample, in pixels
or the supplied spatial units; `units` names source intensity units. Both apply to the group
members. `spacing` and `origin` accept a shared axis-order vector or a mapping
from every published member name to its vector. Spacing is strictly positive;
origin defaults to zero and requires spacing when supplied. `spatial_units`
applies only when spacing is present and is independent of intensity `units`.
The publisher requires nonempty sample_id and names. It generates IDs,
validates all members and aggregate sizes before copies, then copies only
the selected planes or crops into the binary group. Non-contiguous/negative-stride
views are supported and copied in C order without changing values.

Tensor metadata and all byte budgets are validated before detached CPU copies.
Crop/slice before calling; `view_variable` selects a plane before conversion.
Float16 retains its wire dtype; bfloat16 widens losslessly to float32, with
the wider storage counted against limits. Sparse, nested, quantized, meta,
complex and arbitrary tensor subclasses are rejected. No tensor framework
is imported by setup. Conversion follows PyTorch's documented
[detached CPU conversion semantics](https://docs.pytorch.org/docs/stable/generated/torch.Tensor.numpy.html).
No retaining remote arrays after publication. Publisher installation uses a
marked namespace and is idempotent; user-owned `ejn` causes a capability/setup
diagnostic, not namespace replacement. NumPy/IPython are imported lazily.
The injected code must be self-contained and not load files on the remote.

## Fixed resource ceilings

| Resource | Ceiling / policy |
| --- | --- |
| Group file, including header | 67,108,864 bytes (existing artifact ceiling) |
| One plane or cropped volume | 33,554,432 raw bytes |
| Member dimensions | Two or three axes, each 1..16,384; product constrained by byte ceiling |
| Members / JSON header | 4 / 16,384 UTF-8 bytes |
| Identifiers, names, units | 128 UTF-8 bytes each; no control characters |
| Base64 group | `4 * ceil(group_bytes / 3)`; existing encoded artifact ceiling |
| Pending helper artifact work | Existing one-job and aggregate-byte bounds |
| Viewer descriptor/frame | 65,536 JSON payload bytes, 4-byte BE length prefix |
| Open viewer connections / pending loads | 1 / 1 plus one coalesced pending descriptor |
| Viewer read/write per event-loop tick | 65,540 bytes; parsing/dispatch deferred |
| Viewer header/partial-frame deadline | 5 seconds |
| Viewer ready / load ACK deadline | 10 / 30 seconds, excluding Nix build time |
| Viewer-owned snapshot disk (future disk-backed storage) | 512 MiB total; at most 16 groups |
| Active workspaces / visible planes | 4 / 4 per active workspace |
| In-memory source arrays | 2 GiB by default, configurable 256 MiB–1 TiB; evict inactive unpinned views first |
| ROI definitions / worker queue | 16 per workspace / one active + latest pending |
| ROI temporary working set | 32 MiB; scan large ROIs in bounded row blocks |
| Viewer idle exit | 900 seconds with no visible windows or pending requests |

The one active load and one coalesced pending descriptor are global, not
multiplied per workspace. Frozen pending snapshots are separately bounded by
the workspace count and global snapshot budgets. Reserve disk for staging
copies and installed snapshots together before copying. Memory reservations
include all workspaces, outstanding workers and conversion/difference buffers.
The experimental implementation uses independently owned read-only memory
snapshots only: no disk copies, pins or frozen pending snapshots exist yet.
It limits workspaces to four and accounts retained source samples plus
estimated load/render buffers against the launch-time budget (2 GiB unless
`--memory-budget-mib` says otherwise). This is application admission
accounting, not a guarantee about Qt/Python process RSS. Disk reservations
and orphan cleanup apply only if disk-backed snapshots are implemented.

Pinned snapshots count against budgets. Refuse admission/pinning when their
retention prevents fitting the next group; never silently unpin. Account for
candidate/baseline, difference planes, display conversion buffers, loading
and worker references before allocating. Data budgets are not a total RSS
promise: report Qt/rendering overhead separately. All limits can be lowered;
raising them requires updating this contract and stress evidence. The
aggregate memory budget is the user-configured exception: it only changes how
much bounded work can coexist, while per-artifact, per-plane, raster and
finding limits stay fixed.

Responsiveness acceptance targets after startup on recorded reference
hardware: Emacs timer delay p95 below 50 ms, max below 200 ms during bounded
transfer; Qt input callback delay p95 below 50 ms, max below 200 ms during
loading/ROI work; cached ROI result within 250 ms after pointer release for
2048x2048 fixtures. Measure with a 10 ms probe over at least 100 candidate
updates and record native build, CPU, display scale and percentiles. These
are implementation gates, not measurements already achieved.

## Viewer IPC and ownership

### Helper event descriptor

Numerical MIME selection is exclusive: if present, admit that group alone,
not via the existing non-pickle/image selection logic. Any accompanying
image/pickle payload is ignored. Advertise `array-group-v1` only when helper
admission is implemented; enable publisher setup only after that advertised
capability is observed. No new execute operations are needed for publication.

The existing display event envelope carries:

```json
{"data":{"application/x-ejn-array-group":{
  "path":"/private/helper/artifact", "bytes":524500,
  "sha256":"<64 lowercase hex>", "manifest":{"v":1,"key":"reconstruction",
  "sample_id":"case-17/slice-120","publication_id":"<32 lowercase hex>",
  "planes":["<validated plane objects as above>"]}
}}}
```

The example size/hash/planes are schematic. Real manifests contain the exact
validated header objects. No OS file descriptor is passed over stdout.
Root and file identity come from local capability ownership checks; remote
data never supplies them. The entire descriptor stays below 32 KiB. Unknown
header/plane fields are rejected in content version 1; future fields need a
content-version/capability decision. Viewer IPC rejects unknown operations
and required-field types; optional envelope extension fields may be ignored.

### Local control channel

Reuse length-prefixed bounded JSON over the Emacs-owned stdin/stdout pipes,
independently versioned as viewer v1. Diagnostics use stderr only. This local
pipe replaces the originally proposed socket; EOF revokes the entire epoch
and exits the viewer. No socket discovery or reconnect/resend is required.
Request: `{"v":1,"id":"r-1","op":"open","params":{...}}`.
Operations: `hello`, `open`, `cancel`, `focus`, `close_workspace`, `ping`, `close`,
and the optional negotiated `findings-v1` operations `findings`, `capture`
and `findings_org`.
Replies have the same id, `ok` boolean and bounded `result` or
`error:{code,message}`. Error message maximum: 512 UTF-8 bytes; no arbitrary
tracebacks or data payloads. Invalid/oversized/partial frames close the local
connection without affecting any kernel. No evaluation operation exists.

`open` includes workspace/session-generation/execution identity, artifact
root/path/device/inode/size/SHA-256, and explicit `focus` boolean. Validate
private root ownership and regular-file/no-symlink confinement against pinned
identities before opening. Hash/copy in a worker from the verified open file
descriptor. Install an independently owned snapshot atomically, validate
group contents, and send `open` success only once a viewer-owned snapshot is
installed (as visible candidate, or as the latest pending candidate while
frozen) and its source lease can be released. The reply reports `visible`
or `pending`. Only one frozen pending group per workspace is retained and
counts against all memory/disk/group limits. Pending loads are coalesced
per target; superseded callers receive a terminal error and release leases.
Do not trust remote-provided path/session metadata.

Typed `open.params` contains `workspace` (bounded opaque string), `generation`
(nonnegative safe integer), `execution` (bounded string), `kind` (`array-group`
or `raster`), `artifact` (root, path, root_device, root_inode, device, inode,
size, sha256), and `focus` (boolean). Identity integers are nonnegative JSON
safe integers; root/path each have a 4096 UTF-8 byte ceiling. The numerical
manifest is read from the verified file, not trusted from caller summaries.
For raster kind also require `mime` (`image/png` or `image/jpeg`); decode
in a bounded worker with a 16,777,216-pixel ceiling. Raster RGB/RGBA displays
retain channel appearance but numerical ROI/difference functions are disabled
and labeled unavailable for rendered images in the first release. Native
resolution raster viewing is not evidence of original array fidelity.

CC37 adds optional `open.params.context`: a JSON object of at most 24,576
encoded UTF-8 bytes, independently copied into the immutable snapshot.
The source-side execution trail supplies `version`, `source`, `scope`,
`truncated`, `target_id`, `target_missing`, and ordered `entries`. Each entry
records its ID, exact submitted/reserved code, SHA-256, omission flag,
cell/origin, queue/submission/finish times, outcome, kernel session and
execution count. The `kernel_identity` object records the session ID, remote
PID, Docker container ID when applicable, and a source-local confirmed-restart
epoch; reconnecting to the same kernel does not increment that epoch.
Missing code is null with `code_omitted=true`; it is never
silently shortened. This context is frozen before viewer startup/queueing.
Display-id updates use the producing execution's handle, even when rendered
on an older panel entry. No helper/Jupyter protocol or frame limit changes.

`findings` takes an empty params object and opens the local saved collection;
success returns `state: "visible"`. `capture` takes an exact `workspace` ID
and immediately freezes that workspace's current painted panes before any
note prompt or subsequent publication. It never starts a kernel, opens a new
publication or captures a different workspace. Acceptance returns
`state: "saving"`; disk completion/errors are reported in the viewer. One
bounded local findings IO job handles atomic persistence and review.
Saved findings own their image, lossless displayed planes, view/ROI settings
and each pane's source context independently of disposable snapshots. Limits:
128 MiB selected samples per capture, 16,777,216 image pixels, 1,000 findings /
2 GiB per collection. Explicit deletion only.

Capture, saved-note edits and removal automatically regenerate `findings.org`
after the durable mutation, in the same single worker job. The document is
ready before successful operation completion, without another IPC request.
Overview failure is reported separately: the committed finding or note stays
saved, removal stays completed, and protected edited Org content remains
untouched. Automatic generation reserves an additional 64 MiB during capture;
note edits and removal reserve 64 MiB for the combined job. No UI callback
performs generation and no additional worker queue is introduced.

`findings_org` takes an empty params object and generates a bounded local
`findings.org` index in the findings directory. It replies only after atomic
generation completes, with `path` (absolute local filename), `count` and
`skipped`. The existing findings worker owns the operation; busy and failed
requests return stable error codes and are never replayed automatically.
The document is bounded to 8 MiB and uses relative preview/image/JSON/NumPy
links, escaped plaintext context excerpts and no executable source blocks.
Existing generated content is replaced only when its recorded body hash
still matches; edited content is preserved. Emacs validates a bounded regular
local file before opening, disables file-local evaluation, and defers display
until the requesting buffer owns input. Each finding owns a derived
`overview.png` of at most 800×600 pixels, separately from its full image and
120×80 browser thumbnail. Emacs displays at most eight visible previews and
releases decoded offscreen images while scrolling. No full saved array is
loaded by opening the overview.

`cancel` names an open request ID. Revocation is recorded before worker
completion can install its result; every completion checks connection epoch,
request liveness and workspace generation. On timeout the manager closes the
connection, revoking that epoch's unfinished requests before releasing source
leases. Open file descriptors/independent copies may finish cleanup but cannot
install after revocation. A cancellation after success is reported as already
completed, not claimed to undo a displayed result. No automatic resend after
an ambiguous handoff; a new explicit inspect uses a new request ID.

The panel's artifact owner holds its lease until success, rejection,
cancellation or timeout. The viewer snapshot store independently owns all
displayed candidates and pinned baselines until consumers finish. Closing a
panel does not retire a displayed snapshot. Viewer/Emacs exit removes local
disposable snapshots only. Namespace snapshots per viewer process; startup
orphan cleanup must not delete another live viewer's files.

Candidate selection and ROI jobs use immutable publication generation.
Out-of-order completion cannot replace a newer candidate or statistics.
Ordinary publication never focuses a window. Explicit inspect can focus it.
Freeze retains the visible candidate while recording a bounded latest pending
candidate; unfreeze adopts that candidate without replaying remote code.

## Measurement and comparison semantics

Rectangular ROIs are axis-aligned with half-open pixel-center bounds
`x <= col+0.5 < x+w`, `y <= row+0.5 < y+h`. Ellipses include centers with
`((cx-x-w/2)/(w/2))^2 + ((cy-y-h/2)/(h/2))^2 <= 1` and positive w/h.
Clip membership to the source grid. Geometry is float64; use original plane
values with stable float64 accumulation, population variance, finite and
excluded counts. Empty/all-non-finite results are unavailable, single-pixel
SD is zero. Display normalization never enters this computation.

Differences use float64 arithmetic, candidate minus reference, with optional
absolute value. Invalid operands yield excluded/non-finite difference pixels.
V1 supported integer types are exactly representable in float64. Floating
subtraction/accumulation follow float64 precision; never promise exact real
arithmetic. Nonempty matching units and declared identical grid/sample are
required for automatic numeric comparison; user confirmation of common
unspecified units is a local explicit declaration, not a hidden assumption.

Contract fixtures live in `tests/fixtures/viewer-contract-v1.json`: small
complete binary examples plus rejection vectors. V3/V4/viewer tests consume
the same fixtures and additionally test real local-kernel MIME publication.
