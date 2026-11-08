#!/usr/bin/env bash
#
# Copy downloaded CI artifacts back into their platform packages, ready for
# `pnpm -r publish`.
#
#   gh run download <run-id> -D .artifacts
#   ./scripts/assemble.sh .artifacts
#
# `gh run download` lays artifacts out as `.artifacts/<artifact-name>/<files>`,
# and the workflow names each one `search-tools-<target>`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-}"
[ -n "$SRC" ] || { echo "usage: $0 <dir-with-downloaded-artifacts>" >&2; exit 2; }
[ -d "$SRC" ] || { echo "error: $SRC is not a directory" >&2; exit 1; }

echo "==> assembling from $SRC"
for d in "$SRC"/search-tools-*/; do
  [ -d "$d" ] || continue
  target="${d%/}"
  target="${target##*search-tools-}"
  dest="$ROOT/packages/search-tools-$target/bin"
  mkdir -p "$dest"
  cp "$d"* "$dest/"
  chmod +x "$dest"/* 2>/dev/null || true
  echo "  search-tools-$target/bin: $(ls "$dest" | tr '\n' ' ')"
done

# The six packages publish together, so a missing platform would ship a main
# package whose optionalDependency resolves to nothing on that platform.
echo "==> verification"
for target in linux-x64 linux-arm64 darwin-arm64 darwin-x64 win32-x64; do
  dest="$ROOT/packages/search-tools-$target/bin"
  [ -n "$(ls -A "$dest" 2>/dev/null)" ] \
    || { echo "error: packages/search-tools-$target/bin is missing or empty" >&2; exit 1; }
done
echo "  all five platforms present"
