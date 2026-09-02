#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EMACS=${EMACS:-emacs}
EMACSCLIENT=${EMACSCLIENT:-emacsclient}
DOOM_INIT_DIRECTORY=${DOOM_INIT_DIRECTORY:-"$HOME/.config/emacs"}
if [[ "${EJN_DOOM_E2E_SERVER+x}" == x ]]; then
  printf 'EJN_DOOM_E2E_SERVER is unsupported: the Doom E2E always owns a fresh server name\n' >&2
  exit 2
fi
SHELL_TIMEOUT=${EJN_DOOM_E2E_SHELL_TIMEOUT:-240}
if ! [[ "$SHELL_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || (( SHELL_TIMEOUT > 900 )); then
  printf 'EJN_DOOM_E2E_SHELL_TIMEOUT must be an integer from 1 through 900\n' >&2
  exit 2
fi
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ejn-doom-e2e.XXXXXXXXXXXX")
OWNERSHIP_TOKEN=${RUN_DIR##*/}
SERVER_NAME="ejn-doom-e2e-${OWNERSHIP_TOKEN}"
LOG_FILE="$RUN_DIR/daemon.log"
PROGRESS_FILE="$RUN_DIR/progress.log"
DAEMON_PID=

export EJN_DOOM_E2E_PROGRESS_FILE="$PROGRESS_FILE"

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
  local command
  command=$(ps -p "$DAEMON_PID" -ww -o command= 2>/dev/null) || return 1
  [[ -n "$command" ]] || return 1

  if [[ -r "/proc/$DAEMON_PID/cmdline" ]]; then
    local -a argv=()
    local argument
    while IFS= read -r -d '' argument; do
      argv+=("$argument")
    done < "/proc/$DAEMON_PID/cmdline"
    local daemon_seen= init_seen=
    for ((index = 0; index < ${#argv[@]}; index++)); do
      case "${argv[index]}" in
        "--daemon=$SERVER_NAME") daemon_seen=1 ;;
        --init-directory=*)
          [[ "${argv[index]#--init-directory=}" == "$DOOM_INIT_DIRECTORY" ]] && init_seen=1
          ;;
        --init-directory)
          (( index + 1 < ${#argv[@]} )) &&
            [[ "${argv[index + 1]}" == "$DOOM_INIT_DIRECTORY" ]] && init_seen=1
          ;;
      esac
    done
    [[ -n "$daemon_seen" && -n "$init_seen" ]]
  else
    # BSD ps has no NUL argv view.  The exact server flag and the exact init
    # directory are still both required before touching a daemon by name.
    [[ " $command " == *" --daemon=$SERVER_NAME "* ]] &&
      ([[ " $command " == *" --init-directory $DOOM_INIT_DIRECTORY "* ]] ||
       [[ " $command " == *" --init-directory=$DOOM_INIT_DIRECTORY "* ]])
  fi
}

capture_owned_daemon_pid() {
  local seconds=${1:-5}
  local deadline=$((SECONDS + seconds))
  local candidate=
  while (( SECONDS <= deadline )); do
    candidate=$(run_bounded 1 "$EMACSCLIENT" -s "$SERVER_NAME" --eval '(emacs-pid)' \
      2>/dev/null) || candidate=
    if [[ "$candidate" =~ ^[1-9][0-9]*$ ]]; then
      DAEMON_PID=$candidate
      if daemon_owned; then
        return 0
      fi
      # A server reply paired with a mismatched argv is ambiguous ownership,
      # never a reason to keep polling or to signal the reported PID later.
      DAEMON_PID=
      return 2
    fi
    sleep 0.1
  done
  return 1
}

preflight_server_absent() {
  local status=0
  run_bounded 3 "$EMACSCLIENT" -s "$SERVER_NAME" --eval '(emacs-pid)' \
    >/dev/null 2>&1 || status=$?
  case "$status" in
    1)
      # emacsclient's documented missing-server outcome.  Every other failure
      # is ambiguous (including the outer timeout) and must not be treated as
      # proof that a server name is free.
      return 0
      ;;
    0)
      printf 'Refusing Doom E2E: generated server name is already live: %s\n' \
        "$SERVER_NAME" >&2
      return 1
      ;;
    *)
      printf 'Refusing Doom E2E: server absence preflight was ambiguous (status %s)\n' \
        "$status" >&2
      return 2
      ;;
  esac
}

cleanup() {
  if daemon_owned; then
    # Recheck ownership inside the addressed server as well.  If the socket
    # name is replaced after daemon_owned, this expression cannot kill the
    # replacement daemon.
    local graceful=
    graceful=$(run_bounded 10 "$EMACSCLIENT" -s "$SERVER_NAME" --eval \
      "(if (= (emacs-pid) $DAEMON_PID)
           (progn (run-at-time 0 nil #'kill-emacs) 'ejn-owned)
         'ejn-refused)" 2>/dev/null) || true
    if [[ "$graceful" == "ejn-owned" ]]; then
      for _ in {1..20}; do
        kill -0 "$DAEMON_PID" >/dev/null 2>&1 || break
        sleep 0.1
      done
    fi
    if daemon_owned; then
      kill -TERM "$DAEMON_PID" >/dev/null 2>&1 || true
      for _ in {1..20}; do
        kill -0 "$DAEMON_PID" >/dev/null 2>&1 || break
        sleep 0.1
      done
      if daemon_owned; then
        kill -KILL "$DAEMON_PID" >/dev/null 2>&1 || true
      fi
    elif kill -0 "$DAEMON_PID" >/dev/null 2>&1; then
      printf 'Doom E2E refused signal cleanup: PID/cmdline ownership changed (%s)\n' \
        "$DAEMON_PID" >&2
    fi
  elif [[ -n "$DAEMON_PID" ]]; then
    printf 'Doom E2E refused daemon cleanup: PID/cmdline ownership changed (%s)\n' \
      "$DAEMON_PID" >&2
  fi
  rm -rf "$RUN_DIR"
}

trap cleanup EXIT

# The server name contains fresh mktemp entropy and ownership token.  Refuse
# any existing, timed-out, or otherwise ambiguous response before launch.
if ! preflight_server_absent; then
  exit 2
fi

if ! run_bounded "$SHELL_TIMEOUT" "$EMACS" --init-directory "$DOOM_INIT_DIRECTORY" --daemon="$SERVER_NAME" \
  >"$LOG_FILE" 2>&1; then
  # `emacs --daemon' may have forked just before its bounded launcher was
  # terminated.  Recover only a server whose PID and exact argv prove that it
  # belongs to this run, so the EXIT trap can retire it without name-only kill.
  capture_owned_daemon_pid 5 || true
  printf 'Failed to start isolated Doom Emacs daemon. Log follows:\n' >&2
  sed -n '1,200p' "$LOG_FILE" >&2
  exit 1
fi

if ! capture_owned_daemon_pid 10; then
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
