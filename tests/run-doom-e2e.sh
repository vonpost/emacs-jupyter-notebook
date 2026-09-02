#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EMACS=${EMACS:-emacs}
EMACSCLIENT=${EMACSCLIENT:-emacsclient}
DOOM_INIT_DIRECTORY=${DOOM_INIT_DIRECTORY:-"$HOME/.config/emacs"}
SERVER_NAME=${EJN_DOOM_E2E_SERVER:-"ejn-doom-e2e-$$"}
LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/ejn-doom-e2e.XXXXXX.log")
PROGRESS_FILE=$(mktemp "${TMPDIR:-/tmp}/ejn-doom-e2e.XXXXXX.progress")
SHELL_TIMEOUT=${EJN_DOOM_E2E_SHELL_TIMEOUT:-240}
DAEMON_PID=

export EJN_DOOM_E2E_PROGRESS_FILE="$PROGRESS_FILE"

if ! [[ "$SHELL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || (( SHELL_TIMEOUT > 900 )); then
  printf 'EJN_DOOM_E2E_SHELL_TIMEOUT must be an integer from 1 through 900\n' >&2
  exit 2
fi

run_bounded() {
  local limit=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=10s "${limit}s" "$@"
    return
  fi

  "$@" &
  local child=$!
  (
    sleep "$limit"
    kill -TERM "$child" >/dev/null 2>&1 || true
    sleep 10
    kill -KILL "$child" >/dev/null 2>&1 || true
  ) &
  local watchdog=$!
  local status=0
  wait "$child" || status=$?
  kill "$watchdog" >/dev/null 2>&1 || true
  wait "$watchdog" >/dev/null 2>&1 || true
  return "$status"
}

daemon_owned() {
  [[ "$DAEMON_PID" =~ ^[1-9][0-9]*$ ]] || return 1
  ps -p "$DAEMON_PID" -o command= 2>/dev/null |
    grep -F -- "--daemon=$SERVER_NAME" >/dev/null
}

cleanup() {
  if ! run_bounded 10 "$EMACSCLIENT" -s "$SERVER_NAME" --eval '(kill-emacs)' \
    >/dev/null 2>&1; then
    if daemon_owned; then
      kill -TERM "$DAEMON_PID" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        kill -0 "$DAEMON_PID" >/dev/null 2>&1 || break
        sleep 0.1
      done
      if daemon_owned; then
        kill -KILL "$DAEMON_PID" >/dev/null 2>&1 || true
      fi
    fi
  fi
  rm -f "$LOG_FILE" "$PROGRESS_FILE"
}

trap cleanup EXIT

if ! run_bounded "$SHELL_TIMEOUT" "$EMACS" --init-directory "$DOOM_INIT_DIRECTORY" --daemon="$SERVER_NAME" \
  >"$LOG_FILE" 2>&1; then
  printf 'Failed to start isolated Doom Emacs daemon. Log follows:\n' >&2
  sed -n '1,200p' "$LOG_FILE" >&2
  exit 1
fi

if ! DAEMON_PID=$(run_bounded 10 "$EMACSCLIENT" -s "$SERVER_NAME" --eval '(emacs-pid)'); then
  printf 'Failed to read the isolated Doom daemon PID. Log follows:\n' >&2
  sed -n '1,200p' "$LOG_FILE" >&2
  exit 1
fi
if ! daemon_owned; then
  printf 'Refusing Doom E2E without an identity-checked isolated daemon PID: %s\n' \
    "$DAEMON_PID" >&2
  exit 1
fi

if ! run_bounded "$SHELL_TIMEOUT" "$EMACSCLIENT" -s "$SERVER_NAME" --eval \
  "(progn
     (setq debug-on-error t)
     (load-file \"$ROOT/tests/emacs-jupyter-notebook-doom-e2e.el\")
     (ejn-doom-e2e-run))"; then
  printf 'Last entered Doom E2E phases:\n' >&2
  sed -n '1,240p' "$PROGRESS_FILE" >&2
  printf 'Doom E2E emacsclient evaluation failed. Log follows:\n' >&2
  sed -n '1,240p' "$LOG_FILE" >&2
  exit 1
fi
