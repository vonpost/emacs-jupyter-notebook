#!/usr/bin/env bash
# Optional real Docker/SSH/Jupyter lifecycle test; never part of local ERT.
# Required: EJN_DOCKER_TEST_HOST, EJN_DOCKER_TEST_IMAGE, EJN_DOCKER_TEST_RUNTIME.
# The image must already exist on the host. Runtime needs bin/ejn-helper and
# bin/ejn-registry-worker. This runner performs no Nix build or Docker pull.
# Optional: EJN_DOCKER_TEST_CWD (/tmp), EJN_DOCKER_TEST_PYTHON (python3),
# EJN_DOCKER_TEST_OPTIONS_JSON and EJN_DOCKER_TEST_SSH_OPTIONS_JSON (argv arrays),
# CODE_CELLS_DIR, EMACS, TIMEOUT_CMD, EJN_DOCKER_TEST_TIMEOUT (600 seconds).
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
EMACS=${EMACS:-emacs}
die() { printf 'run-docker-e2e: %s\n' "$*" >&2; exit 1; }

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi
[[ $# -eq 0 ]] || die 'unexpected argument; use --help'
[[ -n ${EJN_DOCKER_TEST_HOST:-} ]] || die 'set EJN_DOCKER_TEST_HOST explicitly'
[[ -n ${EJN_DOCKER_TEST_IMAGE:-} ]] || die 'set EJN_DOCKER_TEST_IMAGE to a pre-pulled image'
[[ -n ${EJN_DOCKER_TEST_RUNTIME:-} ]] || die 'set EJN_DOCKER_TEST_RUNTIME to the local runtime directory'
[[ -x "$EJN_DOCKER_TEST_RUNTIME/bin/ejn-helper" ]] || die 'runtime has no executable bin/ejn-helper'
[[ -x "$EJN_DOCKER_TEST_RUNTIME/bin/ejn-registry-worker" ]] || die 'runtime has no executable bin/ejn-registry-worker'
command -v "$EMACS" >/dev/null 2>&1 || die "Emacs executable not found: $EMACS"
command -v ssh >/dev/null 2>&1 || die 'ssh is required'
command -v scp >/dev/null 2>&1 || die 'scp is required'

if [[ -z ${CODE_CELLS_DIR:-} ]]; then
  for candidate in \
    "$HOME/.config/emacs/.local/straight/repos/code-cells.el" \
    "$HOME/.emacs.d/.local/straight/repos/code-cells.el"; do
    if [[ -f "$candidate/code-cells.el" ]]; then CODE_CELLS_DIR=$candidate; break; fi
  done
fi
[[ -f "${CODE_CELLS_DIR:-}/code-cells.el" ]] || die 'set CODE_CELLS_DIR to the code-cells.el directory'
if [[ -n ${TIMEOUT_CMD:-} ]]; then
  TIMEOUT_BIN=$TIMEOUT_CMD
elif command -v timeout >/dev/null 2>&1; then
  TIMEOUT_BIN=$(command -v timeout)
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT_BIN=$(command -v gtimeout)
else
  die 'GNU timeout or gtimeout is required (or set TIMEOUT_CMD)'
fi
WALL_TIMEOUT=${EJN_DOCKER_TEST_TIMEOUT:-600}
case "$WALL_TIMEOUT" in ''|*[!0-9]*) die 'timeout must be an integer';; esac
[[ "$WALL_TIMEOUT" -ge 400 && "$WALL_TIMEOUT" -le 900 ]] || die 'timeout must be between 400 and 900 seconds'

EJN_DOCKER_TEST_ARTIFACT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ejn-docker-e2e.XXXXXX")
export EJN_DOCKER_TEST_ARTIFACT_DIR
printf 'Docker E2E diagnostics and recovery registry: %s\n' "$EJN_DOCKER_TEST_ARTIFACT_DIR"
printf 'Only the uniquely identified test kernel/container will be cleaned up.\n'
cd "$ROOT"
"$TIMEOUT_BIN" --foreground --kill-after=10s "$WALL_TIMEOUT" \
  "$EMACS" -Q --batch -L "$ROOT" -L "$ROOT/tests" -L "$CODE_CELLS_DIR" \
  --eval '(when (directory-files default-directory nil "\\.elc$") (error "Remove stale project .elc files before this source-only test"))' \
  -l "$ROOT/tests/emacs-jupyter-notebook-docker-remote-tests.el" \
  --eval '(ert-run-tests-batch-and-exit "^ejn-docker-remote-real-launch-heartbeats-reconnect$")' \
  2>&1 | tee "$EJN_DOCKER_TEST_ARTIFACT_DIR/run.log"
