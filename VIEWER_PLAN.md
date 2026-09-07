# W21 — Slice-based PyQtGraph comparison viewer

Status: implementation started, 2026-09-06. See claimed rows below.
This is the execution ledger for the viewer replacement agreed with the user.
`ROADMAP.md` remains the project index; `HELPER_TRANSPORT_PLAN.md` describes
the existing helper boundary that this work must preserve.

User priority update (2026-09-06): the existing interactive viewer is already
broken for the user's workflows. Ship and switch to an experimental replacement
early; macOS graphical sign-off and complete comparison/ROI polish must not
block the first usable source-to-viewer path. Fidelity, bounded work, source
cleanliness and kernel-lifetime constraints remain binding. V5/V6 and isolated
V7 components may proceed together under the ownership assignments below;
full acceptance checkboxes still require their recorded tests.

## Outcome and release scope

Evaluate a local source cell against a remote kernel and inspect selected
full-resolution slices in one persistent local comparison window. Keep a
previous evaluation pinned while the candidate updates, without losing the
sample, crop, window/level, or measurement ROIs.

The first release includes:

- A local PyQtGraph application with a pinned Qt binding, replacing the
  matplotlib-pickle viewer on macOS and Linux.
- Explicit publication of selected 2D arrays; whole volumes stay remote.
- Named side-by-side panes, linked zoom/pan and cursor, and magnified views
  of the same selected region beneath the context images.
- Local window level/width, signed and absolute differences, and blink
  comparison between compatible images.
- A pinned previous evaluation and an updating candidate.
- Multiple named rectangular and elliptical measurement ROIs, with mean,
  population standard deviation, and pixel counts for each compatible pane.
- One inspect action from source or panel, plus evaluate-and-inspect and
  explicit follow/freeze behavior.

The user has Nix on both macOS and Linux and authorized its use for this
viewer. Nix is the supported local build/distribution path: provide a pinned
viewer package and app for the existing `aarch64-darwin` and `x86_64-linux`
targets. Keep the GUI output separate from the helper/registry runtime so
ordinary kernel work does not require building or loading Qt. No local/remote
matplotlib version matching is required by the replacement.

This is a general image/array inspection tool, with CT as an acceptance
workload. It does not require DICOM or napari. Arbitrary matplotlib artist
interaction is not a replacement goal; ordinary plot PNG/JPEG outputs remain
inspectable as rendered images. Lazy volume browsing, huge-plane tiling,
polygon ROIs, and durable review collections follow the first release.

## Interaction and data contract

### Explicit slice publication

Python surface (publisher and automatic capability-gated setup implemented):

```python
ejn.view(
    {"reference": reference[z], "prediction": prediction[z]},
    key="reconstruction",
    sample_id=f"{case_id}/slice-{z}",
)
```

`key` names a comparison workspace within the owning source session;
`sample_id` names the example and slice. Identity also includes kernel/session
generation, execution, publication version, and per-output/member IDs.
Variable names, output ordinals, and Jupyter display IDs alone cannot identify
immutable snapshots. Region output remains history-only in Emacs even when
explicitly inspected externally.

Inject the publisher in memory during acknowledged kernel setup, without
silently overwriting a user-owned `ejn` binding. Emit explicit display MIME;
do not depend on a per-type formatter that the inline backend can erase.
Require no remote installation, GUI, service, or files. Start with numeric
NumPy planes in environments already using NumPy and with ordinary image
artifacts. Missing array support reports a capability error without failing
ordinary kernel use. Do not import/install heavy tensor frameworks on setup.
Document slicing GPU tensors before CPU conversion; any convenience adapter
must extract the slice before materializing or copying data.

The user selects a 2D slice before publication. Preserve numeric values with
explicit shape, dtype, byte order, axes, and optional spacing, origin,
orientation, and units. Define supported dtypes and RGB/RGBA semantics in V1.
Reject object arrays and executable serialization; never use pickle-enabled
array loading. No silent float downcast, 8-bit conversion, or whole-volume
materialization. Check bounds before contiguous copies and serialization.
Compression is optional and lossless, with independent decoded-size limits.

A comparison group has finite member-count, per-plane, encoded, decoded, and
aggregate byte budgets. Shape multiplication and decompression must be
validated before allocation. Replace a group atomically or show it as
incomplete; never pair a fresh prediction with an unintended stale reference.

### Keep inspection local

| Action | Network behavior |
| --- | --- |
| Initial comparison | Transfer selected planes together as one logical publication |
| Zoom, pan, window/level, ROI movement and statistics | No requests after planes are cached |
| Difference and blink | Compute/display from compatible local planes |
| Rerun candidate | Transfer new outputs; reuse the pinned local baseline |
| Review a retained evaluation | Reuse its local snapshot |
| Select an uncached remote slice | Later V12 feature; bounded, coalesced request |

One 2048 x 2048 uint16 plane is 8 MiB before compression; float32 is 16 MiB.
Avoid serial metadata/data round trips and unconditional preview-then-full
transfers. Full-resolution selected planes are the first-release default;
oversized planes fail clearly at the documented limit.

All Jupyter traffic stays in the supervised local helper. Emacs receives
bounded descriptors/thumbnails, never numerical bytes or base64. Heavy
decode/hash/write work stays off the helper event loop. The viewer loads
local artifacts; loading and expensive statistics stay off the Qt GUI thread.
Neither a new remote service nor another Jupyter client is introduced.

### Fidelity and correspondence

- Provide fit and native-pixel modes, visible zoom/interpolation state, and
  tested device-pixel mapping on Retina and Linux displays. Exact inspection
  disables smoothing/downsampling. Retain samples independently of overviews.
- Window/level changes presentation only. Shared settings remain fixed across
  reruns unless explicitly changed. Pixel readout and measurements use source
  samples. Do not label normalized data as HU without calibration metadata.
- Equal shapes or relative crops do not establish anatomical alignment. Link
  declared corresponding grids; use a documented spatial mapping when metadata
  is available. Show missing/incompatible correspondence and allow independent
  inspection. Automatic registration/resampling is outside the first release.
- Differences require compatible sample, grid, and units. Promote arithmetic
  before subtraction to avoid unsigned wraparound; define numeric precision
  and non-finite behavior. Show subtraction order and difference units.
- Raster outputs are labeled rendered images. Their channel values are not
  recoverable CT intensities; full-size figure PNGs may already be resampled.

### ROI measurement rules

Support multiple named rectangles and ellipses. Define membership by source
pixel-center inclusion, deterministic edge inclusion, and clipping to plane
bounds. Do not compute statistics from resampled GUI ROI extraction or from
the magnified display. Link measurement geometry only on compatible grids.

For each ROI and eligible reference/candidate/difference plane, display mean,
population SD (`ddof=0`), finite pixel count, and excluded non-finite count.
Empty/all-non-finite selections show unavailable statistics; one finite pixel
has SD zero. Use stable accumulation and document supported precision. Define
per-channel RGB statistics or explicitly disable them, never mix channels.

Debounce updates and bound worker jobs/temporary allocations. Discard stale
statistics by publication and ROI generation. Window/level, colormap, zoom,
and interpolation must not change results. Preserve ROIs for the same
compatible sample/slice across evaluations.

### Snapshots, focus, and lifecycle

Pinning copies or promotes selected artifacts into a separately owned, bounded
local viewer snapshot store. Panel clear/kill and ordinary artifact eviction
must not delete live viewer snapshots. Define ownership transfer/leases and
startup orphan cleanup explicitly; existing panel-owned leases alone are not
sufficient. Byte/count budgets include pinned data; decline a new pin or ask
for unpinning when full, without silently evicting a baseline.

Active unpinned candidates also hold a bounded viewer lease or independent
copy throughout loading, display, and ROI worker use. Release them on
replacement/close only after consumers finish; settle pending leases on
handoff cancellation. Pinning changes retention policy, not the requirement
that a displayed artifact remain alive independently of the panel.

An old snapshot contains fetched slices only. Never imply access to unfetched
slices of an old volume, and never retain whole remote volumes automatically.
First-release snapshots may be disposable at Emacs exit; persistence is V14.

Use separate workspace namespaces for different source sessions even if one
local process serves them. This does not introduce shared kernels. Follow
updates an explicitly selected cell/workspace; freeze stops visible replacement
without stopping execution. Inspect targets the exact output; evaluate-and-
inspect tracks its execution after point moves. Ordinary eval does not steal
focus. Provide return-to-source and cached inspection while disconnected/busy.

Viewer close/crash releases local resources only; remote kernel, registry,
and connection metadata remain untouched. Emacs exit reaps the viewer.
Reconnect/restart invalidates remote handles without relabeling cached data
as fresh. Never replay user code to reconstruct missing output.

## Milestones and execution ledger

### Navigation follow-up — 2026-09-07 (CC11)

`ee4a974` replaced separate X/Y links with guarded, bidirectional center/scale updates.
Each pane derives its visible bounds from its own geometry; pan and resize
after navigation preserve magnification, including on prediction-originated
input. Resize notifications expose only the settled camera, not ViewBox's
intermediate aspect correction. Compatible snapshot replacement retains the
camera; incompatible grids remain independent. Closing/replacing a workspace
disconnects its navigation groups. The pixel readout cannot expand the window.

Native macOS/Wayland pinch zooms around the pointer. Two-finger wheel events
pan with Qt's supplied direction; identified touchpads without pixel deltas
use angle deltas for pan. Ordinary mouse wheels still zoom, and left drag
still pans. All operations use the already-loaded numerical samples locally.

Regression evidence: the old default layout emits scales 0.40853 → 0.43642 →
0.40853 in one pan; the new test checks every intermediate notification.
Old code also fails the pinch and trackpad-pan tests. The viewer suite passes
37 tests with PyQtGraph 0.14.0 / Qt 6.11.1 in an isolated wheel environment;
15 workspace tests pass with 2× logical scaling and on the actual Linux X11
display. Linux paint/zoom/fit/resize/reopen smoke passes. These are source/GUI
checks, not a new Nix package build or a physical macOS gesture sign-off.
Canonical source verification remains 974 ERT, 4 codec, 236 helper (3 optional
dependency skips), 25 registry and 12 stress tests. V7 remains partial for the
other features in its row. The previously reported Nix build-output limit is
separate unfinished work, not addressed by this navigation change.

### macOS startup follow-up — 2026-09-07

`dd53c22` lands the CC9/CC10 changes below. CC9 adds explicit viewer phase
messages, per-waiter Nix progress independent
of the kernel bootstrap context, a local `inspector-status` command, stale
waiter/dead-process recovery on the next Inspect, and bounded SSH exit details.
The cold-start regression activates the real panel card, holds a test Nix
process across repeated inspection, then exercises framed startup/load ACKs.
It verifies one build, visible progress, artifact cleanup, unchanged source,
and no transport reconnection. This closes diagnostic gaps but does not claim
the original Mac tunnel-exit cause has been reproduced.

CC10 removes PyQtGraph's unused PyQt6 build/test input. In pinned Nixpkgs,
PyQt6's default PDF support pulls QtWebEngine even on Darwin. The viewer still
uses PySide6; no GUI binding or image implementation changes. The recursive
Darwin derivation graph now excludes both PyQt6 and QtWebEngine; restoring the
old input reproduces their presence. `bash tests/test-viewer-packaging.sh`
guards this without compiling Darwin packages. Actual macOS build/GUI
acceptance remains under V2; a Linux package-check attempt was unable to
complete its uncached dependency builds, so it is not counted as a pass.

Source-based verification: 974 ERT, 4 codec, 236 helper (3 optional-dependency
skips), 25 registry, and 12 stress tests. Byte compilation has only the two
pre-existing optional Evil-variable warnings; generated bytecode was removed
before the canonical source test run.

### Experimental slice-path checkpoint — 2026-09-06

The source-to-viewer numerical path landed in `ba8280d`. `C-c j I` and numerical
panel cards inspect a retained output; `C-c j J` tracks the first numerical
publication from the exact execution after point moves. Capability-gated,
acknowledged setup injects `ejn.view` without remote files or installations.
The separate Nix viewer starts asynchronously over bounded framed stdio.

The helper validates/spools lossless groups off its event loop. Emacs handles
only bounded metadata, with per-output identities and handoff leases. The
viewer verifies and copies selected groups into read-only **memory**, not a
disk snapshot store: there are no snapshot files to orphan-clean. Loaded
images outlive panel/source cleanup, and EOF reaps only the local viewer.
The four-workspace/256 MiB admission accounting includes retained samples and
estimated load/render buffers, but is not a process RSS guarantee.

The initial GUI has named row-major panes, compatible linked zoom/pan, fit,
pixel readout and window level/width. V5-V7 remain partial: ordinary raster
output selection, follow/freeze, return-to-source, linked cursors/magnifiers,
native-device-pixel mode and full responsiveness evidence remain open.
V8/V9 (pinned baseline/diffs/ROIs) have not been implemented. The legacy path
still exists under its old explicit command/panel `v`; it is not a fallback
from the new keys. V10 deletion is still open.

Evidence: canonical source-only tests pass (957 ERT, 4 codec, 236 helper,
25 registry, 12 stress). The separate Nix viewer check passes 26 GUI/snapshot/
IPC tests. Opt-in real local-kernel→helper→viewer and Emacs→packaged-viewer
integrations pass; the latter passes with both offscreen Qt and the actual
Linux display and verifies snapshot survival and unchanged source bytes.
Linux demo paint/zoom/resize/reopen checks also pass; actual macOS/Retina
rendering and native-resolution acceptance remain open. See
`docs/viewer-installation.md` for usage and current transfer limits.

Use `ROADMAP.md`'s claim/done protocol. This document's creation does not claim
implementation. Read `AGENTS.md`, `LEARNINGS.md`, both existing plans, and this
file before implementation. New paths are proposed boundaries to finalize in
V1. Claim one bounded row and coordinate shared files; historical W8/W20 rows
remain historical. A row's checkboxes mean landed work, not proposed design.

### M1 — Contracts and an actual working window

- [x] sha=60c2297 **V1 Specify numerical publication and viewer contracts.** Depends:
  W20 complete. Files: this plan, new `docs/viewer-protocol.md`,
  `docs/helper-protocol-v1.md`, `HELPER_TRANSPORT_PLAN.md`. Define API,
  dtypes, identities, group completion, snapshot ownership, ACK/error states,
  and all count/byte/deadline limits. Record helper protocol version/capability
  changes; existing v1's image/pickle contract cannot implicitly admit arrays.
  Gate: contract vectors, explicit budget table, and architecture review.
- [~] owner=nix_viewer_research claimed=2026-09-06 **V2 Package and prove the PyQtGraph window.** Depends: V1.
  Files: new viewer GUI/application modules and graphical tests, local package
  metadata, `flake.nix`, `flake.lock` if needed, installation docs. Add
  `.#ejn-viewer` package/app with PyQtGraph, one Qt binding, and the required
  platform plugins/resources pinned and wrapped together. Keep it separate
  from `.#default`'s headless runtime; enable its tests under flake checks
  rather than running development suites during first-use installation.
  Use a normal Qt event loop and test-owned numerical planes. Gate: visibly
  painted window, resize, zoom, close/reopen on actual macOS and Linux
  displays, with versions, hardware, scaling and timings recorded. Offscreen
  tests or Darwin derivation evaluation cannot satisfy the macOS gate.
  Per the user priority update, macOS evidence is a release-verification item,
  not a prerequisite for experimental V6 integration or switching commands.
  Implementation: `8856a65` provides the Nix package and demo shell; Linux
  build/offscreen checks pass. Actual macOS graphical acceptance remains open.

### M2 — Slice publication and source-to-viewer integration

- [x] sha=8856a65 **V3 Publish bounded planes from a real kernel.** Depends: V1.
  Files: new viewer publisher module and `viewer/test_publisher_kernel.py`,
  core Elisp setup and focused tests. Inject via acknowledged serialized
  setup; explicit MIME emission. V3 supplies and tests the bounded setup-code
  provider; production queue/capability wiring belongs to V6 after V4's
  helper admission (no premature injection or circular V3/V4 dependency).
  Gate: test-owned local ipykernel with inline
  matplotlib active, import-and-publish in one cell, selected-slice-only
  fixtures, dtype/shape fidelity, namespace conflict, dependency failure,
  restart/reconnect setup and rejection before expensive materialization.
  Verification: seven publisher tests including a real local ipykernel with
  inline matplotlib, reinjection/restart and unavailable dependencies; exact
  Emacs-generated setup also executed twice in a local kernel. Source-only
  regression: 913 ERT, 224 helper, 25 registry and 12 stress tests passed.
- [x] sha=ba8280d **V4 Admit numerical artifacts through the helper.** Depends: V3.
  Files: helper outputs/artifacts/requests/dispatcher and new numerical
  validation module, helper unit/integration tests, Elisp helper protocol and
  focused protocol tests. Implement V1's negotiated contract and bounded
  workers. Gate: malformed lengths/dtypes/shapes, decompression expansion,
  group truncation, worker failure, heartbeat/credit pressure, and no array
  bytes in helper stdout descriptors. Do not raise hard limits implicitly.
  Verification: 12 focused numerical helper tests cover strict manifests,
  immutable publication cleanup, credit/cancellation/retirement and ping while
  the sole worker is blocked. The real local kernel→helper→viewer test proves
  big-endian/strided selected-plane fidelity and kernel survival after local
  helper/viewer closure. Codec, helper, viewer and headless runtime Nix outputs
  and their selected package checks build successfully. V1 admits no compressed
  encoding, so decompression expansion is rejected rather than implemented.
- [~] owner=root claimed=2026-09-06 **V5 Establish per-output identity and snapshot ownership.** Depends:
  V4. Files: Elisp events/result/artifacts, new local snapshot-store module,
  focused panel/artifact tests. Bind each preview/original/array to its exact
  member and publication; replace the single-figure-per-execution assumption.
  Gate: multi-image cells, interleaved updates, clear-output, independent
  snapshot retention on panel kill, orphan cleanup, finite budgets, stale
  generations, and unchanged source bytes/modification state.
- [~] owner=root claimed=2026-09-06 **V6 Wire inspect and evaluate-and-inspect.** Depends: V2, V5.
  Files: viewer manager/core/vars Elisp, viewer IPC module, focused ERT/process
  tests, `emacs-jupyter-notebook-runtime.el` and runtime tests. Reuse the
  bounded asynchronous Nix bootstrap pattern for the separate viewer output:
  deduplicate builds, show progress/errors, honor cancellation and custom
  viewer commands, and start the viewer-ready deadline after build success.
  Never block Emacs on a build. Bounded async supervision and descriptor
  handoff; exact selection, pending/error state, follow/freeze, focus and
  return-to-source commands.
  Gate: raster and numeric outputs, moving cells during execution, late ACKs,
  incomplete groups, two isolated workspaces, viewer failure and cancellation
  without kernel termination or replay.

### M3 — Comparison and measurements, required for the first release

- [~] owner=root claimed=2026-09-06 **V7 Build side-by-side and linked magnified views.** Depends: V6.
  Files: viewer layout/image/interaction modules and tests. Named panes,
  compatible linked/independent crop/cursor, fit/native scale, interpolation,
  local window level/width. Gate: asymmetric orientation fixtures, Retina and
  Linux scale checks, incompatible grids, zero cached-interaction requests.
- [ ] **V8 Add pinned baselines, differences and blink.** Depends: V7.
  Files: viewer comparison/cache modules and tests, viewer manager and
  snapshot tests. Immutable pin/unpin, atomic candidate updates, preserved
  sample/crop/settings, local signed/absolute difference. Gate: mutation
  cannot alter old snapshots, unsigned subtraction, mismatched sample/grid/
  units, non-finite handling, cache pressure, panel eviction and viewer crash.
- [ ] **V9 Add linked measurement ROIs and statistics.** Depends: V8.
  Files: viewer ROI/statistics modules and tests. Named rectangles/ellipses,
  per-pane mean/population-SD/counts, geometry persistence. Gate: independently
  hand-calculated masks/results, edge/clipped/empty/single-pixel/non-finite
  cases, difference measurements, display invariance, bounded jobs and stale
  result rejection during ROI movement and candidate replacement.

### M4 — Cutover and release verification

- [ ] **V10 Remove the matplotlib-pickle viewer.** Depends: experimental V6.
  The user explicitly permits early replacement before V9/macOS acceptance.
  Files: legacy viewer/formatter and tests,
  core/events/result/vars/viewer Elisp, helper pickle MIME branches/tests,
  README and package metadata. Delete obsolete backend switching, pickle
  emission/loading, settings and commands; no aliases or fallback selector.
  Retain ordinary raster display. Update tests asserting the old automatic
  closing of prior figures. Gate: no production figure-pickle path, coherent
  keymap/docs and a packaged runtime usable from a clean local environment.
- [ ] **V11 Verify the complete editing/review loop.** Depends: V10.
  Files: focused ERT/helper/viewer tests, `tests/stress/`, new
  `docs/dogfood/w21-viewer.md`. Run the matrix below, record measured evidence,
  perform manager review and remediate before marking complete. No GUI
  correctness claims based only on mocked/offscreen tests.

### M5 — Later extensions, outside the first-release gate

- [ ] **V12 Add on-demand remote slice selection.** Depends: V11 and a
  reviewed handle/fetch contract. Files: publisher/helper routing/protocol,
  viewer navigation/cache, core execution queue and focused tests. Register
  bounded metadata/handles without copying volumes. Define axes/channels,
  explicit handle lifetime/release and mutation/version invalidation.
  Coalesce unsent slider requests, prioritize the final selection, fence late
  replies, cache by version and bound optional neighboring-slice prefetch.
  Fetch through the existing serial execution discipline: new reads may wait
  behind training; cached images remain interactive. No background service,
  concurrent busy-kernel-read promise, interrupt or replay. Gate: local delay/
  busy-kernel simulation, scrubbing, stale handles and no full-volume transfer
  or promise of unfetched historical slices.
- [ ] **V13 Add bounded overview/exact-crop transfer for huge planes.**
  Depends: V12. Files: publisher/helper artifacts, viewer cache/rendering,
  protocol and stress tests. Distinguish overview/exact data and cache crops
  with immutable spatial/version identity. Full-ROI statistics require all
  native samples or remain unavailable, never silently use the overview.
  Gate: crop changes under latency, finite cache pressure and exact fidelity.
- [ ] **V14 Add durable review collections and exports.** Depends: V11.
  Files: new local review-store module/tests, viewer and README. Explicitly
  save selected planes, ROIs, settings, notes and run provenance outside
  source files and the kernel registry, with finite storage and explicit
  removal. Measurement exports and polygon ROIs get separately claimed
  subrows. Gate: restart recovery, missing sources, validated schema,
  exact measurements and separation of saved data from disposable caches.

V2 and V3 may proceed in parallel after V1 with disjoint file ownership.
V7-V9 are sequential. V12 and V14 may proceed independently after release
with coordination for shared viewer files.

## Release acceptance matrix

| Concern | Required evidence |
| --- | --- |
| Fidelity | Supported dtype/value round trips; orientation and sharp pixel fixtures; native-scale Retina/Linux rendering; no hidden lossy conversion |
| Transfer size | Large remote array yields only requested planes; bounded encoding/temporary allocations; no whole-tensor CPU conversion |
| Comparison | Two evaluations, pinned baseline, linked magnification/window settings, differences and incompatible-grid handling |
| ROIs | Known rectangle/ellipse masks, mean/population-SD/counts, display invariance and stale-result protection |
| Responsiveness | Measure Emacs timer/typing and Qt input latency during loading, transfers, candidate updates and ROI movement |
| Latency | Locally simulate 250 ms and 1 s round-trip delays plus restricted bandwidth; cached controls issue zero remote requests |
| Lifetimes | Panel clear/kill, viewer close/crash, helper loss and Emacs exit respect snapshot ownership and finite budgets |
| Integrity | Source bytes/modified flag unchanged; identity-fenced callbacks; no registry deletion, remote kill or user-code replay |
| Platforms | Actual macOS and Linux graphical runs including repeated first paint/resize/reopen; record versions and display scaling |

V1/V2 must set numerical responsiveness and memory budgets on named reference
hardware before integration; V11 reports results against them. Generated
non-sensitive fixtures are required; user CT data is optional dogfood evidence.

At cutover run `tests/run-local-tests.sh`, test-owned real-kernel publisher/
helper integration, dedicated viewer unit/GUI suites, package checks, byte
compilation, and `git diff --check`. Delete generated `.elc` files and rerun
the canonical source ERT after compilation. Normal ERT remains independent
of Qt, SSH, Jupyter installations and real remote hosts. Separate optional
GUI/local-kernel suites report skips rather than counting them as passes.

## Completion

The first release is complete only when V1-V11 are landed with evidence,
including ROI measurements and real macOS rendering. V12-V14 are later work,
not prerequisites for replacing the broken viewer. The durable kernel,
clean source files, and bounded helper architecture remain intact.
