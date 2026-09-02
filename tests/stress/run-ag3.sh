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
NIX_TIMEOUT=${EJN_AG3_NIX_TIMEOUT:-180}
TERM_GRACE=${EJN_AG3_TERM_GRACE:-10}

die() { printf 'run-ag3: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'Usage: tests/stress/run-ag3.sh [--repeat N] [--timeout SECONDS]'
  printf '%s\n' '  --repeat N       positive repetition count (default: 5)'
  printf '%s\n' '  --timeout SECONDS finite per-batch deadline, greater than 45 (default: 120)'
  printf '%s\n' '  EJN_AG3_NIX_TIMEOUT bounds each nix build/develop phase (default: 180 seconds)'
  printf '%s\n' '  EJN_AG3_TERM_GRACE allows graceful Nix cleanup before SIGKILL (default: 10 seconds)'
}
positive_integer() {
  case "$1" in
    ''|*[!0-9]*|0) return 1 ;;
    *) return 0 ;;
  esac
}

group_exists() {
  kill -0 -- "-$1" >/dev/null 2>&1
}

stop_owned_group() {
  local pgid=$1
  local grace_deadline=$((SECONDS + TERM_GRACE))
  if group_exists "$pgid"; then
    kill -TERM -- "-$pgid" >/dev/null 2>&1 || true
  fi
  while group_exists "$pgid" && (( SECONDS < grace_deadline )); do
    sleep 0.1
  done
  if group_exists "$pgid"; then
    kill -KILL -- "-$pgid" >/dev/null 2>&1 || true
  fi
  while group_exists "$pgid" && (( SECONDS < grace_deadline + 2 )); do
    sleep 0.1
  done
  group_exists "$pgid" && return 1
  return 0
}

run_bounded() {
  local limit=$1
  shift
  local pid pgid deadline status=0 timed_out=0 monitor_was_enabled=0
  positive_integer "$limit" || {
    printf 'run-ag3: bounded command requires a positive integer deadline\n' >&2
    return 2
  }
  (( $# > 0 )) || {
    printf 'run-ag3: bounded command is empty\n' >&2
    return 2
  }
  [[ "$-" == *m* ]] && monitor_was_enabled=1
  # Bash job control gives this background command a fresh process group on
  # both Linux and stock macOS, without relying on a GNU-only `timeout' or
  # `setsid' executable.  Verify the expected PGID before signaling it.
  set -m
  (
    exec "$@"
  ) &
  pid=$!
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  if [[ ! "$pgid" =~ ^[1-9][0-9]*$ || "$pgid" != "$pid" ]]; then
    kill -TERM "$pid" >/dev/null 2>&1 || true
    wait "$pid" >/dev/null 2>&1 || true
    (( monitor_was_enabled )) || set +m
    printf 'run-ag3: refused bounded command without an isolated process group\n' >&2
    return 2
  fi
  deadline=$((SECONDS + limit))
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      timed_out=1
      printf 'run-ag3: command timed out after %ss; terminating owned process group %s\n' \
        "$limit" "$pgid" >&2
      stop_owned_group "$pgid" || {
        (( monitor_was_enabled )) || set +m
        printf 'run-ag3: owned process group %s survived SIGKILL\n' "$pgid" >&2
        return 2
      }
      break
    fi
    sleep 0.1
  done
  wait "$pid" || status=$?
  if group_exists "$pgid"; then
    printf 'run-ag3: command leader exited with owned descendants still running; terminating group %s\n' \
      "$pgid" >&2
    stop_owned_group "$pgid" || {
      (( monitor_was_enabled )) || set +m
      printf 'run-ag3: owned process group %s survived SIGKILL\n' "$pgid" >&2
      return 2
    }
    (( status == 0 )) && status=1
  fi
  (( monitor_was_enabled )) || set +m
  (( timed_out )) && return 124
  return "$status"
}

main() {
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
  positive_integer "$NIX_TIMEOUT" || die 'EJN_AG3_NIX_TIMEOUT must be a positive integer'
  positive_integer "$TERM_GRACE" || die 'EJN_AG3_TERM_GRACE must be a positive integer'
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

  local output_path helper status gate_timeout
  if output_path=$(cd "$ROOT" && run_bounded "$NIX_TIMEOUT" nix build --no-link --print-out-paths .#ejn-helper); then
    :
  else
    status=$?
    die "nix build failed or exceeded EJN_AG3_NIX_TIMEOUT (${NIX_TIMEOUT}s; status ${status})"
  fi
  [[ -n "$output_path" && "$output_path" != *$'\n'* ]] || die 'Nix did not return exactly one helper output path'
  helper="$output_path/bin/ejn-helper"
  [[ -x "$helper" ]] || die 'Nix helper output has no executable'

  # `nix develop -c' remains the parent of the complete supervisor.  Give its
  # environment setup the Nix allowance in addition to every advertised
  # per-batch allowance; a fixed Nix timeout would otherwise truncate a valid
  # multi-repeat gate before the Python supervisor reached its own deadlines.
  gate_timeout=$((NIX_TIMEOUT + REPETITIONS * WALL_TIMEOUT))
  printf 'AG3 stress (%d repeats, batch deadline %ss, outer gate deadline %ss)\n' \
    "$REPETITIONS" "$WALL_TIMEOUT" "$gate_timeout"
  if run_bounded "$gate_timeout" nix develop "$ROOT" -c python "$ROOT/tests/stress/run-ag3.py" \
    --root "$ROOT" --emacs "$EMACS" --code-cells "$CODE_CELLS_DIR" \
    --helper "$helper" --repeat "$REPETITIONS" --timeout "$WALL_TIMEOUT"; then
    :
  else
    status=$?
    die "nix develop / AG3 supervisor failed or exceeded its ${gate_timeout}s outer deadline (status ${status})"
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
