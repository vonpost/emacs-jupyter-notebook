#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EMACS=${EMACS:-emacs}
EMACSCLIENT=${EMACSCLIENT:-emacsclient}
DOOM_INIT_DIRECTORY=${DOOM_INIT_DIRECTORY:-"$HOME/.config/emacs"}
SERVER_NAME=${EJN_DOOM_E2E_SERVER:-"ejn-doom-e2e-$$"}
LOG_FILE=$(mktemp "${TMPDIR:-/tmp}/ejn-doom-e2e.XXXXXX.log")

cleanup() {
  "$EMACSCLIENT" -s "$SERVER_NAME" --eval '(kill-emacs)' >/dev/null 2>&1 || true
  rm -f "$LOG_FILE"
}

trap cleanup EXIT

if ! "$EMACS" --init-directory "$DOOM_INIT_DIRECTORY" --daemon="$SERVER_NAME" >"$LOG_FILE" 2>&1; then
  printf 'Failed to start Doom Emacs daemon. Log follows:\n' >&2
  sed -n '1,200p' "$LOG_FILE" >&2
  exit 1
fi

if ! "$EMACSCLIENT" -s "$SERVER_NAME" --eval \
  "(progn
     (setq debug-on-error t)
     (load-file \"$ROOT/tests/emacs-jupyter-notebook-doom-e2e.el\")
     (ejn-doom-e2e-run))"; then
  printf 'Doom E2E emacsclient evaluation failed. Log follows:\n' >&2
  sed -n '1,240p' "$LOG_FILE" >&2
  exit 1
fi
