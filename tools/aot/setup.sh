#!/usr/bin/env bash
# Fetch suppify at aot/suppify.pin into build/aot/suppify, build spinel at the
# commit that suppify pins (its spinel.pin) into build/aot/spinel, and fetch
# picoruby-multicore at aot/multicore.pin into build/aot/picoruby-multicore.
# Skips whichever is already at its pin. Takes a few minutes the first time.
#
#   tools/aot/setup.sh
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEST="$ROOT/build/aot"
SUPPIFY_REPO=${SUPPIFY_REPO:-https://github.com/bash0C7/suppify.git}
SPINEL_REPO=${SPINEL_REPO:-https://github.com/matz/spinel.git}
MULTICORE_REPO=${MULTICORE_REPO:-https://github.com/bash0C7/picoruby-multicore.git}
mkdir -p "$DEST"

fetch_at() {   # <repo> <sha> <dir>
  local repo=$1 sha=$2 dir=$3
  if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" = "$sha" ]; then return 0; fi
  rm -rf "$dir"
  git init -q "$dir"
  git -C "$dir" fetch -q --depth 1 "$repo" "$sha"
  git -C "$dir" checkout -q --detach FETCH_HEAD
}

SUPPIFY_PIN=$(tr -d '[:space:]' < "$ROOT/aot/suppify.pin")
fetch_at "$SUPPIFY_REPO" "$SUPPIFY_PIN" "$DEST/suppify"
SPINEL_PIN=$(tr -d '[:space:]' < "$DEST/suppify/spinel.pin")
if [ "$(git -C "$DEST/spinel" rev-parse HEAD 2>/dev/null || true)" != "$SPINEL_PIN" ] || [ ! -x "$DEST/spinel/bin/spinel" ]; then
  fetch_at "$SPINEL_REPO" "$SPINEL_PIN" "$DEST/spinel"
  make -C "$DEST/spinel" deps
  make -C "$DEST/spinel" -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu)"
fi
MULTICORE_PIN=$(tr -d '[:space:]' < "$ROOT/aot/multicore.pin")
fetch_at "$MULTICORE_REPO" "$MULTICORE_PIN" "$DEST/picoruby-multicore"
# The host build of picoruby-multicore links its own fake kernel table; the
# generated picoruby-kernel_registry provides the real one, so the host VM gets
# a copy without the fakes.
rm -rf "$DEST/picoruby-multicore-host"
cp -R "$DEST/picoruby-multicore" "$DEST/picoruby-multicore-host"
rm -rf "$DEST/picoruby-multicore-host/.git"
sed -i.bak 's# test/support/fake_kernels.c##' "$DEST/picoruby-multicore-host/mrbgem.rake"
rm -f "$DEST/picoruby-multicore-host/mrbgem.rake.bak"
grep -q fake_kernels "$DEST/picoruby-multicore-host/mrbgem.rake" && { echo "could not drop the fake kernels" >&2; exit 3; }
echo "suppify $SUPPIFY_PIN, spinel $SPINEL_PIN, picoruby-multicore $MULTICORE_PIN"
