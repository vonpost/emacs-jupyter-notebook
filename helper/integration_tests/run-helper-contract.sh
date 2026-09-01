#!/usr/bin/env bash
# Run the AG1 helper/local-kernel contract serially with a per-run deadline.
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PYTHON=${PYTHON:-python3}
REPEAT=1
LIMIT=120
RUN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ejn-ag1.XXXXXX")
mkdir -p "$RUN_TMP/tmp" "$RUN_TMP/pycache"

cleanup() {
  rm -rf "$RUN_TMP"
}
trap cleanup EXIT

usage() {
  printf 'usage: %s [--repeat N]\n' "${0##*/}" >&2
  exit 2
}

while (($#)); do
  case $1 in
    --repeat)
      (($# >= 2)) || usage
      REPEAT=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

[[ $REPEAT =~ ^[1-9][0-9]*$ ]] || usage
command -v "$PYTHON" >/dev/null 2>&1 || { printf 'AG1: Python not found: %s\n' "$PYTHON" >&2; exit 1; }

if command -v timeout >/dev/null 2>&1; then
  TIMEOUT=$(command -v timeout)
elif command -v gtimeout >/dev/null 2>&1; then
  TIMEOUT=$(command -v gtimeout)
else
  printf 'AG1: GNU timeout or gtimeout is required\n' >&2
  exit 1
fi

for ((run = 1; run <= REPEAT; run++)); do
  started=$SECONDS
  printf 'AG1 run %d/%d\n' "$run" "$REPEAT"
  "$TIMEOUT" --foreground --kill-after=5s "${LIMIT}s" env \
    PYTHONPATH="$ROOT/helper:$ROOT/helper/integration_tests${PYTHONPATH:+:$PYTHONPATH}" \
    PYTHONPYCACHEPREFIX="$RUN_TMP/pycache" \
    TMPDIR="$RUN_TMP/tmp" \
    "$PYTHON" -m unittest -v test_helper_contract.HelperProtocolContractTests.test_direct_protocol_contract
  elapsed=$((SECONDS - started))
  ((elapsed < LIMIT)) || { printf 'AG1: run %d exceeded %ds\n' "$run" "$LIMIT" >&2; exit 1; }
  printf 'AG1 run %d/%d passed in %ds\n' "$run" "$REPEAT" "$elapsed"
done
