#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EMACS=${EMACS:-emacs}
PYTHON=${PYTHON:-python3}
TIMEOUT=${EJN_TEST_TIMEOUT:-30}
RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ejn-local-tests.XXXXXX")
RUN_TMPDIR="$RUN_TMP/tmp"
RUN_PYCACHE="$RUN_TMP/pycache"
mkdir -p "$RUN_TMPDIR" "$RUN_PYCACHE"

cleanup() { rm -rf "$RUN_TMP"; }
trap cleanup EXIT

die() { printf 'run-local-tests: %s\n' "$*" >&2; exit 1; }

command -v "$EMACS" >/dev/null 2>&1 || die "Emacs executable not found: $EMACS"

if [[ -n ${TIMEOUT_CMD:-} ]]; then
  TIMEOUT_BIN=$TIMEOUT_CMD
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=$(command -v timeout)
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=$(command -v gtimeout)
else
  die "external timeout command is required (install GNU timeout or gtimeout, or set TIMEOUT_CMD)"
fi

if [[ -z ${CODE_CELLS_DIR:-} ]]; then
  home_dir=${HOME:-}
  for candidate in \
    "$home_dir/.config/emacs/.local/straight/repos/code-cells.el" \
    "$home_dir/.config/emacs/straight/repos/code-cells.el" \
    "$home_dir/.emacs.d/.local/straight/repos/code-cells.el" \
    "$home_dir/.emacs.d/straight/repos/code-cells.el" \
    "$home_dir/.config/doom/.local/straight/repos/code-cells.el"; do
    if [[ -f "$candidate/code-cells.el" ]]; then
      CODE_CELLS_DIR=$candidate
      break
    fi
  done
fi

if [[ ! -f "${CODE_CELLS_DIR:-}/code-cells.el" ]]; then
  die "cannot resolve CODE_CELLS_DIR; set it to the code-cells.el directory"
fi

run_with_deadline() {
  "$TIMEOUT_BIN" --foreground --kill-after=5s "$TIMEOUT" "$@"
}

if [[ ${1:-} == --self-test-stale-elc ]]; then
  selftest="$RUN_TMP/stale-elc"
  mkdir -p "$selftest/tests"
  cp "$ROOT/tests/run-local-tests.el" "$selftest/tests/run-local-tests.el"
  : > "$selftest/emacs-jupyter-notebook.elc"
  stdout="$selftest/stdout"
  stderr="$selftest/stderr"
  if run_with_deadline "$EMACS" -Q --batch -L "$selftest/tests" -l "$selftest/tests/run-local-tests.el" \
      >"$stdout" 2>"$stderr"; then
    die "stale .elc self-test unexpectedly passed"
  fi
  grep -q "Refusing source-only tests" "$stderr" \
    || { sed -n '1,80p' "$stderr" >&2; die "stale .elc failure was not clear"; }
  printf 'stale .elc preflight self-test passed\n'
  exit 0
fi

run_with_deadline env TMPDIR="$RUN_TMPDIR" PYTHONPYCACHEPREFIX="$RUN_PYCACHE" \
  CODE_CELLS_DIR="$CODE_CELLS_DIR" \
  "$EMACS" -Q --batch -L "$ROOT" -L "$ROOT/tests" -L "$CODE_CELLS_DIR" \
  -l "$ROOT/tests/run-local-tests.el" -f ert-run-tests-batch-and-exit

if [[ -d "$ROOT/helper/tests" ]]; then
  run_with_deadline env TMPDIR="$RUN_TMPDIR" PYTHONPATH="$ROOT/helper" \
    PYTHONPYCACHEPREFIX="$RUN_PYCACHE" \
    "$PYTHON" -m unittest discover -s "$ROOT/helper/tests" -p 'test_*.py'
fi

run_with_deadline env TMPDIR="$RUN_TMPDIR" PYTHONPYCACHEPREFIX="$RUN_PYCACHE" \
  "$PYTHON" "$ROOT/tests/stress/test_run_ag3.py"
