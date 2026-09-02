#!/usr/bin/env bash
# Run AG2's local helper E2E gate.
#
# Usage: tests/run-helper-e2e.sh [--repeat N] [--timeout SECONDS]
# `--repeat 1` is the focused gate; `--repeat 20` is the serial stability
# gate.  The Python supervisor owns each deadline and cleanup, so this script
# deliberately does not require host GNU `timeout` (macOS ships none).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EMACS=${EMACS:-emacs}
REPETITIONS=${EJN_E2E_REPETITIONS:-1}
WALL_TIMEOUT=${EJN_E2E_TIMEOUT:-120}
CODE_CELLS_DIR=${CODE_CELLS_DIR:-"$HOME/.config/emacs/.local/straight/repos/code-cells.el"}

die() { printf 'run-helper-e2e: %s\n' "$*" >&2; exit 1; }
usage() {
  sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
}
positive_integer() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeat)
      [[ $# -ge 2 ]] || die '--repeat requires a positive integer'
      REPETITIONS=$2
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || die '--timeout requires a positive integer'
      WALL_TIMEOUT=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1" ;;
  esac
done

positive_integer "$REPETITIONS" || die 'repeat count must be a positive integer'
positive_integer "$WALL_TIMEOUT" || die 'timeout must be a positive integer'
[[ "$WALL_TIMEOUT" -gt 50 ]] || die 'timeout must exceed 50 seconds for startup and cleanup'
[[ -f "$CODE_CELLS_DIR/code-cells.el" ]] || die 'set CODE_CELLS_DIR to the code-cells.el directory'
command -v nix >/dev/null 2>&1 || die 'Nix is required for the local helper E2E gate'

output_path=$(cd "$ROOT" && nix build --no-link --print-out-paths .#ejn-helper)
[[ -n "$output_path" && "$output_path" != *$'\n'* ]] || die 'Nix did not return exactly one helper output path'
HELPER="${output_path}/bin/ejn-helper"
[[ -x "$HELPER" ]] || die 'Nix helper output has no executable'

for ((attempt = 1; attempt <= REPETITIONS; attempt++)); do
  started=$(date +%s)
  printf 'AG2 E2E batch %d/%d (deadline %ss)\n' "$attempt" "$REPETITIONS" "$WALL_TIMEOUT"
  if nix develop "$ROOT" -c python "$ROOT/tests/run-helper-e2e.py" \
      --root "$ROOT" --emacs "$EMACS" --code-cells "$CODE_CELLS_DIR" --helper "$HELPER" \
      --timeout "$WALL_TIMEOUT"; then
    status=0
  else
    status=$?
  fi
  finished=$(date +%s)
  if [[ "$status" -eq 0 ]]; then
    printf 'AG2 E2E batch %d/%d passed in %ss\n' "$attempt" "$REPETITIONS" "$((finished - started))"
  else
    printf 'AG2 E2E batch %d/%d failed in %ss (status %s)\n' \
      "$attempt" "$REPETITIONS" "$((finished - started))" "$status" >&2
    exit "$status"
  fi
done
