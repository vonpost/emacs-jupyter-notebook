#!/usr/bin/env bash
# Run the bounded AG3 local stress gate.
#
# Usage: tests/stress/run-ag3.sh [--repeat N] [--timeout SECONDS]
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
EMACS=${EMACS:-emacs}
CODE_CELLS_DIR=${CODE_CELLS_DIR:-"$HOME/.config/emacs/.local/straight/repos/code-cells.el"}
REPETITIONS=5
WALL_TIMEOUT=120

die() { printf 'run-ag3: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'Usage: tests/stress/run-ag3.sh [--repeat N] [--timeout SECONDS]'
  printf '%s\n' '  --repeat N       positive repetition count (default: 5)'
  printf '%s\n' '  --timeout SECONDS finite per-batch deadline, greater than 45 (default: 120)'
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
      [[ $# -ge 2 ]] || die '--timeout requires a finite positive integer'
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
[[ "$WALL_TIMEOUT" -gt 45 ]] || die 'timeout must exceed 45 seconds'

case "$(uname -s):$(uname -m)" in
  Linux:x86_64|Darwin:arm64) ;;
  *) die 'supported hosts are x86_64-linux and aarch64-darwin' ;;
esac

[[ -f "$ROOT/tests/stress/run-ag3.py" ]] || die 'AG3 supervisor is missing'
[[ -f "$ROOT/tests/stress/emacs-jupyter-notebook-stress.el" ]] || die 'AG3 ERT file is missing'
[[ -f "$CODE_CELLS_DIR/code-cells.el" ]] || die 'set CODE_CELLS_DIR to the code-cells.el directory'
if [[ "$EMACS" == */* ]]; then
  [[ -x "$EMACS" ]] || die 'EMACS is not executable'
else
  command -v "$EMACS" >/dev/null 2>&1 || die 'Emacs is unavailable'
fi
command -v nix >/dev/null 2>&1 || die 'Nix is required for AG3'

output_path=$(cd "$ROOT" && nix build --no-link --print-out-paths .#ejn-helper)
[[ -n "$output_path" && "$output_path" != *$'\n'* ]] || die 'Nix did not return exactly one helper output path'
HELPER="$output_path/bin/ejn-helper"
[[ -x "$HELPER" ]] || die 'Nix helper output has no executable'

printf 'AG3 stress (%d repeats, deadline %ss)\n' "$REPETITIONS" "$WALL_TIMEOUT"
nix develop "$ROOT" -c python "$ROOT/tests/stress/run-ag3.py" \
  --root "$ROOT" --emacs "$EMACS" --code-cells "$CODE_CELLS_DIR" \
  --helper "$HELPER" --repeat "$REPETITIONS" --timeout "$WALL_TIMEOUT"
