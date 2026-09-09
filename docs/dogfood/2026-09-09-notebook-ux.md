# Notebook and numerical review UX

CC15–CC18 implement the seven requested improvements: direct variable-plane
viewing; pinned/followed/frozen comparisons; source-following output navigation;
a live metadata dashboard; informative output headers; direct ROI gestures and
linked pixel inspection; and contextual Inspect/action menus.

## Verification

- Canonical source-only `tests/run-local-tests.sh`: **1032 ERT**, **4 array
  protocol**, **248 helper**, **25 registry worker** and **12 stress harness**
  tests passed. Byte compilation produced only the existing Evil visual-marker
  free-variable warnings; `.elc` files were removed before the final source run.
- `PYTHONPATH=viewer:array_protocol QT_QPA_PLATFORM=offscreen python
  -X faulthandler -m unittest discover -s viewer -p 'test_*.py' -v`:
  **96 tests, 95 passed, 1 optional matplotlib-dependent test skipped**.
  Coverage includes pin/unpin, sample mismatch, unsigned differences,
  preserved camera/levels/ROIs, drag/rename/nudge/copy, exact linked samples,
  bounded magnifier copies, compact layout, pending updates during gestures,
  memory admission, repeated Qt cleanup and closed-workspace follow suppression.
- Real disposable local kernels: **2 integration tests passed** using
  `python -m unittest discover -s helper/integration_tests -p 'test_variable*.py'`.
  The metadata request emitted no outputs or values. A selected/transposed
  plane of a 4D array arrived as exactly **5×4 uint16 samples / 40 raw bytes**,
  with independently calculated values, unchanged source array and input
  history, no publisher scratch bindings, and cleaned-up clients/readers.
- Isolated installed Evil smoke: source normal-state Tab and `C-c j i/a/A`,
  unaffected insert-state Tab, panel normal-state Tab/i/a and variable-table
  g/RET/q/i/a resolve to the intended commands.
- Actual Linux Qt **xcb**, device pixel ratio **1.0**: opened reference and
  candidate, pinned evaluation 1, accepted evaluation 2, created two named
  ROIs, observed **3 image panes / 6 statistics rows**, exercised blink/copy,
  and verified Freeze rejected evaluation 3. The window manager constrained
  the window to **860×440**; the corrected layout retained **180 px** of image
  area and visible/scrollable statistics at y=361–431. The optional magnifier
  correctly hid in that compact window. Full magnifier layout and exact
  patches were verified with the offscreen Qt interaction suite. The final
  screenshot was visually inspected; this is not a Retina/native-pixel test.
- Pinned Nix builds/checks passed: `.#default`, `.#ejn-viewer`,
  `.#checks.x86_64-linux.ejn-helper`, `.#checks.x86_64-linux.ejn-viewer`.
  `tests/test-viewer-packaging.sh` passed its offline Darwin dependency check
  without QtWebEngine/PyQt6.

Independent review identified and fixed mixed raster/numerical Inspect routing,
automatic updates replacing an explicit pending Inspect, closed workspaces
reopening on the next publication, pane-expansion admission and stale pixel
readouts. Real display review identified the compact-layout issue. Conservative
render reservations were retained after review of deferred Qt object lifetimes.

## Interaction and limits

`C-c j a` shows contextual actions and shortcuts. `C-c j V` opens the live
variable table; `v` views its selected NumPy array, `f` favorites it and `F`
filters favorites. `C-c j A` views a source identifier. Axis and slice/channel
indices are selected in Emacs minibuffers; there is no remote viewer slider
or neighboring-plane prefetch. Reads require an idle kernel and each explicit
selection transfers only its chosen plane. Variable names/shapes do not
declare physical alignment or intensity units.

Source text stays clean. Followed output/viewer updates never take focus.
Scrolling output pauses source following; `f` resumes. Frozen viewers discard
incoming updates and resume on subsequent publications. Closing a workspace
stops automatic reopening; explicit Inspect can reopen it. A pinned snapshot
is local and immutable, and does not promise access to unfetched old slices.

Existing v1 dtype/plane/group bounds and the **256 MiB** viewer accounting
budget remain unchanged, including pins, pending updates, workers and render
buffers. Over-budget updates may be rejected; Qt/Python overhead is additional.
New controls have not been exercised on an actual macOS display. Full W21
platform/native-pixel acceptance, remote sliders and legacy viewer removal
remain separate roadmap work.
