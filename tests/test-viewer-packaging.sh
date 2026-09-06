#!/usr/bin/env bash
set -euo pipefail

# Evaluate (without building) the Darwin viewer derivation and inspect its
# complete store reference graph.  pyqtgraph's upstream Nix expression has a
# build-only PyQt6 input, whose default PDF support pulls QtWebEngine; the
# viewer uses PySide6 instead and must not retain that browser stack.
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cache=${XDG_CACHE_HOME:-/tmp}/ejn-nix-cache
drv=$(XDG_CACHE_HOME="$cache" nix --offline eval --raw \
  "$root#packages.aarch64-darwin.ejn-viewer.drvPath")
refs=$(nix-store -qR "$drv")
if grep -Eiq 'qtwebengine|pyqt6' <<<"$refs"; then
    echo "Darwin viewer graph unexpectedly contains QtWebEngine/PyQt6:" >&2
    grep -Ei 'qtwebengine|pyqt6' <<<"$refs" >&2
    exit 1
fi
echo "Darwin viewer derivation has no QtWebEngine or PyQt6 references: $drv"
