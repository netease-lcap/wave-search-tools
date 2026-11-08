#!/usr/bin/env bash
#
# Build ugrep (+ bfs) for ONE target and drop the binaries into
# packages/search-tools-<target>/bin/.
#
#   ./scripts/build.sh linux-x64
#
# No cross-compiling, by design: a cross-built glibc binary inherits the build
# host's CPU baseline, and the resulting "+avx2" build dies with SIGILL on any
# machine older than the builder. Each target is produced on its own runner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$ROOT/vendor.lock.json"
CACHE="${WAVE_SEARCH_TOOLS_CACHE:-$ROOT/.build}"
TARGET="${1:-}"

die() { echo "error: $*" >&2; exit 1; }

[ -n "$TARGET" ] || die "usage: $0 <target>   (linux-x64 | linux-arm64 | darwin-x64 | darwin-arm64 | win32-x64)"

# ---------------------------------------------------------------------------
# 1. This host must BE the target.
# ---------------------------------------------------------------------------
case "$(uname -s)" in
  Linux) host_os=linux ;;
  Darwin) host_os=darwin ;;
  MINGW* | MSYS* | CYGWIN*) host_os=win32 ;;
  *) die "unsupported build host: $(uname -s)" ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) host_arch=x64 ;;
  aarch64 | arm64) host_arch=arm64 ;;
  *) die "unsupported build arch: $(uname -m)" ;;
esac
HOST="$host_os-$host_arch"
if [ "$HOST" != "$TARGET" ]; then
  # The one allowed cross build is between the two macOS architectures: the
  # macOS SDK ships universal stubs, so `-arch arm64` on an Intel runner links
  # against the same system libraries the binary finds at runtime. A cross
  # glibc build is a different story — it inherits the builder's CPU baseline
  # and traps on older machines, so those stay refused.
  case "$host_os:$TARGET" in
    darwin:darwin-arm64 | darwin:darwin-x64) ;;
    *) die "target $TARGET != host $HOST (this script does not cross-compile)" ;;
  esac
fi

# macOS target arch, independent of the runner's own arch.
MACOS_ARCH=""
if [ "$host_os" = "darwin" ]; then
  case "$TARGET" in
    darwin-arm64) MACOS_ARCH="-arch arm64" ;;
    darwin-x64) MACOS_ARCH="-arch x86_64" ;;
  esac
fi

OUT="$ROOT/packages/search-tools-$TARGET/bin"
mkdir -p "$OUT" "$CACHE"

# ---------------------------------------------------------------------------
# 2. Sources: reuse a local dir when given, else download + verify.
# ---------------------------------------------------------------------------
json() { node -e "const j=require(process.argv[1]);console.log(j[process.argv[2]][process.argv[3]])" "$LOCK" "$1" "$2"; }

# fetch <name> -> sets SRC_<name> to the unpacked source dir
fetch() {
  local name="$1" url sha want_sha actual
  url="$(json "$name" url)"
  sha="$(json "$name" sha256)"

  if [ -n "${WAVE_SEARCH_TOOLS_SOURCES:-}" ] && [ -d "$WAVE_SEARCH_TOOLS_SOURCES" ]; then
    for candidate in "$WAVE_SEARCH_TOOLS_SOURCES"/*"$name"* "$WAVE_SEARCH_TOOLS_SOURCES/$name"; do
      [ -d "$candidate" ] && { eval "SRC_$name=\$candidate"; echo "  using local sources: $candidate"; return; }
    done
  fi

  local tarball="$CACHE/$name.tar.gz" unpacked
  unpacked="$CACHE/$name-src"
  if [ ! -f "$tarball" ]; then
    echo "  downloading $url"
    curl -fsSL --retry 3 -o "$tarball.part" "$url" || die "download failed: $url"
    mv "$tarball.part" "$tarball"
  fi
  actual="$(sha256sum "$tarball" | cut -d' ' -f1)"
  [ "$actual" = "$sha" ] || die "$name tarball sha256 mismatch
  expected $sha
  actual   $actual
  Delete $tarball and retry; if the upstream archive really changed, update vendor.lock.json only after re-testing the binaries."

  if [ ! -d "$unpacked" ]; then
    mkdir -p "$unpacked"
    # Upstream layouts differ: ugrep wraps everything in `ugrep-<ver>/`, bfs
    # has no top-level directory at all (a blind --strip-components=1 deletes
    # bfs's Makefile/configure). Unpack flat, then lift a single wrapper dir.
    tar -xzf "$tarball" -C "$unpacked"
    if [ "$(ls -A "$unpacked" | wc -l)" -eq 1 ]; then
      local only
      only="$(ls -A "$unpacked")"
      if [ -d "$unpacked/$only" ]; then
        shopt -s dotglob nullglob
        mv "$unpacked/$only"/* "$unpacked"/
        shopt -u dotglob nullglob
        rmdir "$unpacked/$only"
      fi
    fi
  fi
  eval "SRC_$name=\$unpacked"
}

# ---------------------------------------------------------------------------
# 3. Build ugrep.
# ---------------------------------------------------------------------------
build_ugrep() {
  local src="$1" flags
  if [ "$host_os" = "win32" ]; then
    # ugrep ships a prebuilt win64/ugrep.exe inside the source tarball. Using
    # it beats compiling: no compiler on the runner, and no CPU-baseline risk.
    cp "$src/bin/win64/ugrep.exe" "$OUT/ugrep.exe"
    echo "  ugrep.exe: prebuilt (from source tarball, MSVC build)"
    return
  fi

  # Pinned CPU baseline: without these, configure enables whatever the build
  # machine supports, and the binary traps on older CPUs.
  local cpus="--disable-avx2 --disable-avx512"

  if [ "$host_os" = "linux" ]; then
    # Fully static: own libc, no dynamic loader, no glibc version floor.
    ( cd "$src" && ./configure --enable-static --with-pcre2 --with-zlib \
        --with-bzlib --with-zstd --with-brotli $cpus \
        LDFLAGS="-static" >/dev/null && make -j"$(nproc)" >/dev/null )
  else
    # macOS cannot do `-static` at all (no static libSystem, no crt0.o), so
    # `--enable-static` must NOT be passed here — configure would emit a musl
    # style static link line and die. And linking Homebrew's .dylib would bake
    # in paths that only exist on a machine with brew installed.
    #
    # So macOS links only what every Mac already has in /usr/lib: libSystem
    # plus libpcre2-8 (bundled since Big Sur for grep). Optional compression
    # backends (bz2/zstd/brotli) are simply left out — configure skips them
    # when the system has no library, and `-z` on those formats degrades to
    # "not supported" rather than breaking anything.
    # When the runner's own arch differs from the target, autoconf has to be
    # told so: it otherwise links a test program and tries to run it, which
    # fails with "cannot run C++ compiled programs".
    local cross_host="" pcre2_arg="--with-pcre2"
    if [ "$host_arch" != "${TARGET#darwin-}" ] && [ "$host_arch" = "x64" ]; then
      cross_host="--build=x86_64-apple-darwin --host=aarch64-apple-darwin"
      # ugrep picks the pcre2 header AND library from one PCRE2_HOME
      # (-I$H/include, -L$H/lib). Homebrew's library is built for the runner's
      # arch, so linking it into an arm64 binary fails and configure silently
      # disables PCRE2 — the binary then has no -P support. Hand it a home whose
      # include/ holds Homebrew's header while lib/ stays empty, so the library
      # still resolves from /usr/lib, where libpcre2-8.tbd is universal.
      local brew_pcre2
      brew_pcre2="$(brew --prefix pcre2 2>/dev/null || echo /usr/local/opt/pcre2)"
      mkdir -p "$CACHE/pcre2-cross/include" "$CACHE/pcre2-cross/lib"
      cp "$brew_pcre2/include/pcre2.h" "$CACHE/pcre2-cross/include/"
      pcre2_arg="--with-pcre2=$CACHE/pcre2-cross"
    fi
    ( cd "$src" && ./configure $cross_host $pcre2_arg --with-zlib $cpus \
        CC="${CC:-clang}" CXX="${CXX:-clang++}" \
        CFLAGS="$MACOS_ARCH" CXXFLAGS="$MACOS_ARCH" LDFLAGS="$MACOS_ARCH" >/dev/null \
      && make -j"$(sysctl -n hw.ncpu)" >/dev/null )
  fi
  cp "$src/src/ugrep" "$OUT/ugrep"
  strip "$OUT/ugrep" 2>/dev/null || true
  echo "  ugrep: $("$OUT/ugrep" --version | head -1)"
}

# ---------------------------------------------------------------------------
# 4. Build bfs. Skipped on Windows: git bash already ships a complete GNU find.
# ---------------------------------------------------------------------------
build_bfs() {
  local src="$1"
  if [ "$host_os" = "win32" ]; then
    echo "  bfs: skipped (win32 uses GNU find from git bash)"
    return
  fi
  if [ "$host_os" = "linux" ]; then
    # glibc static still dlopen()s libnss_* at runtime for getpwnam_r /
    # getgrnam_r; the link-time warnings are expected and harmless on any
    # normal glibc distro. (musl would remove them, but musl hosts are not a
    # supported target — wave's desktop app rejects musl Linux outright.)
    # LDFLAGS must reach `configure`, not `make`: bfs's Makefile picks the
    # linker flags up from the generated config.mk, so `make LDFLAGS=-static`
    # is silently ignored and produces a dynamically linked binary.
    ( cd "$src" && LDFLAGS="-static" ./configure >/dev/null && make -j"$(nproc)" >/dev/null 2>&1 )
  else
    # macOS: plain link against libSystem, which every Mac ships.
    ( cd "$src" && CFLAGS="$MACOS_ARCH" LDFLAGS="$MACOS_ARCH" ./configure >/dev/null \
      && make -j"$(sysctl -n hw.ncpu)" >/dev/null )
  fi
  cp "$src/bin/bfs" "$OUT/bfs"
  strip "$OUT/bfs" 2>/dev/null || true
  echo "  bfs: $("$OUT/bfs" --version | head -1)"
}

# ---------------------------------------------------------------------------
echo "==> building $TARGET"
fetch ugrep;  UGREP_SRC="$SRC_ugrep"
fetch bfs;    BFS_SRC="$SRC_bfs"
build_ugrep "$UGREP_SRC"
build_bfs "$BFS_SRC"

# ---------------------------------------------------------------------------
# 5. Verify what we are about to ship.
# ---------------------------------------------------------------------------
echo "==> verification"
for f in "$OUT"/*; do
  [ -f "$f" ] || continue
  echo "  $(basename "$f"): $(du -h "$f" | cut -f1)"
done
if [ "$host_os" = "linux" ]; then
  for f in "$OUT"/*; do
    [ -f "$f" ] || continue
    # `ldd` prints "not a dynamic executable" for a static binary but exits
    # non-zero, so a pipe into grep would trip `set -o pipefail` on success.
    # Match the text instead of the exit status.
    ldd_out="$(ldd "$f" 2>&1 || true)"
    case "$ldd_out" in
      *"not a dynamic executable"* | *"statically linked"*) ;;
      *) die "$(basename "$f") is dynamically linked — the static build silently fell back" ;;
    esac
  done
  echo "  all binaries are statically linked"
fi
echo "==> done: $OUT"
