# Output controls, variable metadata and viewer measurements

CC12–CC14 implement source-cell output retirement/folding, Python variable
shape/type/dtype inspection, and local numerical differences/ROI statistics.
They retain the supervised helper, clean source files and durable remote kernel.

## Verification

- Canonical source-only local command: `tests/run-local-tests.sh`, with the
  available NumPy/Pillow Python environment selected using `PYTHON`.
  **1003 ERT, 4 array-protocol, 246 helper, 25 registry-worker and 12 stress
  harness tests passed.** Byte compilation completed with only the existing
  Evil visual-marker free-variable warnings. Generated `.elc` files were
  deleted before this canonical run.
- Real test-owned local Jupyter kernel: `PYTHONPATH=helper:array_protocol:helper/integration_tests
  python -m unittest discover -s helper/integration_tests -p test_variables.py -v`.
  **1 passed:** NumPy arrays/subclasses, scalar/empty shapes, no overridden
  property calls, no metadata output events, no added execution history and
  no helper names written to the kernel namespace. Used the pinned Nix
  development environment with NumPy available on the local test path.
- Viewer: `PYTHONPATH=viewer:array_protocol QT_QPA_PLATFORM=offscreen
  python -X faulthandler -m unittest discover -s viewer -p 'test_*.py'`.
  **73 tests, 72 passed, 1 skipped** (optional publisher real-kernel plot
  check requires matplotlib). The flake's exact viewer check module list
  passed **58/58**, and the implementation's ROI lifecycle suite passed eight
  repeated runs after reproducing and fixing a Qt handle-disposal crash.
- Installed Evil, isolated `emacs -Q`: verified source normal-state `TAB`
  and `<tab>`, unaffected insert-state Tab, panel normal-state Tab, and
  variable table normal-state `g`/`RET`/`q`.
- Real Linux GUI: Qt **xcb**, device pixel ratio **1.0**, NumPy **2.5.3**,
  PySide6 **6.11.1**, PyQtGraph **0.14.0**. Opened synthetic reference/candidate
  arrays, selected signed difference, created a rectangle and ellipse,
  observed **3 painted panes and 6 measurement rows**, captured and inspected
  the window, then closed it. Results were available at the scheduled
  observation after **0.356 s**; this is not a measured first-paint benchmark.
- `tests/test-viewer-packaging.sh` passed: the recursively inspected Darwin
  viewer derivation contains no QtWebEngine/PyQt6 dependency.
- `nix build --no-link .#default .#ejn-viewer` passed for the updated local
  helper/runtime and viewer packages.
- The built viewer's `--smoke-test --offscreen` passed paint, resize, zoom,
  fit, close and reopen checks using packaged NumPy 2.4.4/PyQtGraph 0.14.0.
- `nix build --no-link .#checks.x86_64-linux.ejn-viewer
  .#checks.x86_64-linux.ejn-helper` passed, including the tests against the
  exact pinned package dependencies.

Independent review caught and remediated Evil table key shadowing and SD
precision loss for adjacent values near `1e16` and `1e308`. Numerical fixtures
now cover these in single and multiple accumulation blocks, plus unsigned
subtraction, non-finite/empty/single-pixel selections, clipped rectangles,
ellipses, mismatched grids/units and stale worker results.

## Limits

Deletion retires local output permanently; undo restores source text only.
Metadata queries wait for an idle Python kernel and do not retrieve values.
Differences require corresponding grids, samples and units; absent grid/unit
metadata requires an explicit viewer declaration. The existing v1 scalar
dtypes remain unchanged, with a 32 MiB float64 difference ceiling and a shared
256 MiB viewer accounting budget. Up to 16 ROIs use original samples with
population SD and explicit non-finite counts.

New controls have not been exercised on an actual macOS display. Pinned
previous evaluations, blink, magnifiers and the full W21 platform/Retina
release gates remain separate work.
