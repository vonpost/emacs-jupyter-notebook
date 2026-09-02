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
OUTPUT_MAX_BYTES=${EJN_DOOM_E2E_OUTPUT_MAX_BYTES:-1048576}
if ! [[ "$OUTPUT_MAX_BYTES" =~ ^[1-9][0-9]*$ ]] ||
  (( OUTPUT_MAX_BYTES < 65536 || OUTPUT_MAX_BYTES > 8388608 )); then
  printf 'EJN_DOOM_E2E_OUTPUT_MAX_BYTES must be an integer from 65536 through 8388608\n' >&2
  exit 2
fi
# POSIX specifies `ulimit -f' in 512-byte blocks.  It is inherited by every
# child of the private session, including the daemon after its initial fork.
OUTPUT_MAX_BLOCKS=$(( (OUTPUT_MAX_BYTES + 511) / 512 ))
RUN_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ejn-doom-e2e.XXXXXXXXXXXX")
OWNERSHIP_TOKEN=${RUN_DIR##*/}
SERVER_NAME="ejn-doom-e2e-${OWNERSHIP_TOKEN}"
LOG_FILE="$RUN_DIR/daemon.log"
PROGRESS_FILE="$RUN_DIR/progress.log"
EVIDENCE_DIR="$RUN_DIR/evidence"
CLIENT_OUT="$RUN_DIR/emacsclient.stdout"
CLIENT_ERR="$RUN_DIR/emacsclient.stderr"
DAEMON_PID=
RUN_SUCCEEDED=0

export EJN_DOOM_E2E_PROGRESS_FILE="$PROGRESS_FILE"
export EJN_DOOM_E2E_EVIDENCE_DIR="$EVIDENCE_DIR"
mkdir -p -- "$EVIDENCE_DIR"
: >"$LOG_FILE"
: >"$PROGRESS_FILE"

start_private_session() {
  # A timeout must address an owned process tree, not only the immediate
  # emacsclient/Emacs PID.  `setsid' is present on Nix Linux; the POSIX Perl
  # fallback covers stock macOS.  Refuse to run without one rather than leave
  # a child tree that the cleanup contract cannot prove it reaped.
  if command -v setsid >/dev/null 2>&1; then
    exec setsid "$@"
  elif command -v perl >/dev/null 2>&1; then
    exec perl -MPOSIX=setsid -e 'setsid() >= 0 or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' -- "$@"
  fi
  printf 'Doom E2E requires setsid or perl with POSIX::setsid for process-tree cleanup\n' >&2
  exit 125
}

private_session_leader_p() {
  local pid=$1 sid
  sid=$(ps -p "$pid" -o sid= 2>/dev/null | tr -d '[:space:]') || return 1
  [[ "$sid" == "$pid" ]]
}

terminate_private_tree() {
  local signal=$1 pid=$2
  if ! private_session_leader_p "$pid"; then
    printf 'Doom E2E refused process-tree signal: child %s is not its private session leader\n' \
      "$pid" >&2
    return 1
  fi
  kill "-$signal" -- "-$pid" >/dev/null 2>&1
}

wait_for_pid_exit() {
  local pid=$1 seconds=$2
  local deadline=$((SECONDS + seconds))
  while kill -0 "$pid" >/dev/null 2>&1 && (( SECONDS < deadline )); do
    sleep 0.1
  done
  ! kill -0 "$pid" >/dev/null 2>&1
}

run_bounded() {
  local limit=$1
  local stdout_file=$2
  local stderr_file=$3
  shift 3
  if ! [[ "$limit" =~ ^[1-9][0-9]*$ ]] || (( limit > 900 )); then
    printf 'Doom E2E internal error: invalid process deadline %s\n' "$limit" >&2
    return 125
  fi
  (
    ulimit -f "$OUTPUT_MAX_BLOCKS"
    start_private_session "$@"
  ) >"$stdout_file" 2>"$stderr_file" &
  local child=$!
  local deadline=$((SECONDS + limit))
  local status=0 timed_out=0
  while kill -0 "$child" >/dev/null 2>&1 && (( SECONDS < deadline )); do
    sleep 0.1
  done
  if kill -0 "$child" >/dev/null 2>&1; then
    timed_out=1
    printf 'Doom E2E process deadline expired after %ss (PID %s)\n' \
      "$limit" "$child" >>"$stderr_file"
    if ! terminate_private_tree TERM "$child"; then
      # This should be unreachable after `start_private_session'.  Still
      # bound the caller if a platform reports a contradictory SID: signal
      # only the child we created, retain evidence, and fail the run rather
      # than wait forever or signal an unproven process group.
      kill -TERM "$child" >/dev/null 2>&1 || true
    fi
    if ! wait_for_pid_exit "$child" 10; then
      if ! terminate_private_tree KILL "$child"; then
        kill -KILL "$child" >/dev/null 2>&1 || true
      fi
      wait_for_pid_exit "$child" 2 || true
    fi
  fi
  if kill -0 "$child" >/dev/null 2>&1; then
    printf 'Doom E2E could not reap bounded child PID %s; retaining evidence\n' \
      "$child" >>"$stderr_file"
    return 125
  fi
  wait "$child" || status=$?
  if (( timed_out )) && (( status == 0 )); then
    status=124
  fi
  return "$status"
}

capture_file_prefix() {
  local file=$1 bytes=${2:-65536}
  [[ -f "$file" ]] || return 0
  head -c "$bytes" "$file"
}

capture_file_tail() {
  local file=$1 bytes=${2:-65536}
  [[ -f "$file" ]] || return 0
  tail -c "$bytes" "$file"
}

capture_scalar() {
  local file=$1 value
  value=$(head -c 256 "$file" 2>/dev/null || true)
  value=${value//$'\n'/}
  value=${value//$'\r'/}
  printf '%s' "$value"
}

show_diagnostic() {
  local label=$1 file=$2
  [[ -s "$file" ]] || return 0
  printf '%s (tail, capped):\n' "$label" >&2
  capture_file_tail "$file" >&2
  printf '\n' >&2
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
  local candidate= probe_out="$RUN_DIR/daemon-pid.stdout" probe_err="$RUN_DIR/daemon-pid.stderr"
  while (( SECONDS <= deadline )); do
    : >"$probe_out"
    : >"$probe_err"
    run_bounded 1 "$probe_out" "$probe_err" "$EMACSCLIENT" -s "$SERVER_NAME" \
      --eval '(emacs-pid)' || true
    candidate=$(capture_scalar "$probe_out")
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
  local status=0 out="$RUN_DIR/server-absence.stdout" err="$RUN_DIR/server-absence.stderr"
  : >"$out"
  : >"$err"
  run_bounded 3 "$out" "$err" "$EMACSCLIENT" -s "$SERVER_NAME" \
    --eval '(emacs-pid)' || status=$?
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
  local exit_status=$?
  local daemon_reaped=1
  trap - EXIT
  set +e
  if daemon_owned; then
    # Recheck ownership inside the addressed server as well.  If the socket
    # name is replaced after daemon_owned, this expression cannot kill the
    # replacement daemon.
    local graceful= graceful_out="$RUN_DIR/daemon-shutdown.stdout" graceful_err="$RUN_DIR/daemon-shutdown.stderr"
    : >"$graceful_out"
    : >"$graceful_err"
    run_bounded 10 "$graceful_out" "$graceful_err" "$EMACSCLIENT" -s "$SERVER_NAME" --eval \
      "(if (= (emacs-pid) $DAEMON_PID)
           (progn (run-at-time 0 nil #'kill-emacs) 'ejn-owned)
         'ejn-refused)" || true
    graceful=$(capture_scalar "$graceful_out")
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
        wait_for_pid_exit "$DAEMON_PID" 2 || true
      fi
    elif kill -0 "$DAEMON_PID" >/dev/null 2>&1; then
      printf 'Doom E2E refused signal cleanup: PID/cmdline ownership changed (%s)\n' \
        "$DAEMON_PID" >&2
    fi
  elif [[ -n "$DAEMON_PID" ]]; then
    printf 'Doom E2E refused daemon cleanup: PID/cmdline ownership changed (%s)\n' \
      "$DAEMON_PID" >&2
  fi
  if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" >/dev/null 2>&1; then
    daemon_reaped=0
  fi
  if (( RUN_SUCCEEDED )) && (( daemon_reaped )); then
    # This is the only destructive local cleanup.  It receives the same
    # session/process-tree deadline as Emacs and emacsclient, so a mounted or
    # pathological evidence directory cannot hang the caller after success.
    run_bounded 10 /dev/null "$RUN_DIR/remove.stderr" rm -rf -- "$RUN_DIR" ||
      printf 'Doom E2E succeeded but bounded run-directory removal failed: %s\n' "$RUN_DIR" >&2
  else
    printf 'Doom E2E retained bounded diagnostics/evidence: %s\n' "$RUN_DIR" >&2
  fi
  exit "$exit_status"
}

trap cleanup EXIT

# The server name contains fresh mktemp entropy and ownership token.  Refuse
# any existing, timed-out, or otherwise ambiguous response before launch.
if ! preflight_server_absent; then
  exit 2
fi

if ! run_bounded "$SHELL_TIMEOUT" "$LOG_FILE" "$RUN_DIR/daemon.stderr" \
  "$EMACS" --init-directory "$DOOM_INIT_DIRECTORY" --daemon="$SERVER_NAME"; then
  # `emacs --daemon' may have forked just before its bounded launcher was
  # terminated.  Recover only a server whose PID and exact argv prove that it
  # belongs to this run, so the EXIT trap can retire it without name-only kill.
  capture_owned_daemon_pid 5 || true
  printf 'Failed to start isolated Doom Emacs daemon. Log follows:\n' >&2
  show_diagnostic 'Doom daemon stdout' "$LOG_FILE"
  show_diagnostic 'Doom daemon stderr' "$RUN_DIR/daemon.stderr"
  exit 1
fi

if ! capture_owned_daemon_pid 10; then
  printf 'Failed to read the isolated Doom daemon PID. Log follows:\n' >&2
  show_diagnostic 'Doom daemon stdout' "$LOG_FILE"
  show_diagnostic 'Doom daemon stderr' "$RUN_DIR/daemon.stderr"
  exit 1
fi
if ! daemon_owned; then
  printf 'Refusing Doom E2E without an identity-checked isolated daemon PID: %s\n' \
    "$DAEMON_PID" >&2
  exit 1
fi

if ! run_bounded "$SHELL_TIMEOUT" "$CLIENT_OUT" "$CLIENT_ERR" "$EMACSCLIENT" -s "$SERVER_NAME" --eval \
  "(progn
     (setq debug-on-error t)
     (load-file \"$ROOT/tests/emacs-jupyter-notebook-doom-e2e.el\")
     (ejn-doom-e2e-run))"; then
  printf 'Last entered Doom E2E phases:\n' >&2
  show_diagnostic 'Doom E2E progress' "$PROGRESS_FILE"
  show_diagnostic 'Doom E2E emacsclient stdout' "$CLIENT_OUT"
  show_diagnostic 'Doom E2E emacsclient stderr' "$CLIENT_ERR"
  show_diagnostic 'Doom daemon stdout' "$LOG_FILE"
  show_diagnostic 'Doom daemon stderr' "$RUN_DIR/daemon.stderr"
  exit 1
fi

capture_file_prefix "$CLIENT_OUT"
if [[ -s "$CLIENT_ERR" ]]; then
  show_diagnostic 'Doom E2E emacsclient stderr' "$CLIENT_ERR"
fi
RUN_SUCCEEDED=1
