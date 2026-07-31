#!/usr/bin/env bash
#
# Static ffmpeg build for Linux amd64 (musl/Alpine, GPL).
#
# Builds every codec + text-rendering library FROM SOURCE as a static archive
# into $PREFIX, then builds a fully-statically-linked ffmpeg + ffprobe.
#
# Why from source: Alpine's apk does NOT ship static (.a) archives for all of
# these libraries (libass has no .a at all; many libs need separate -static
# subpackages that pull in fragile transitive chains). Building everything from
# source into one prefix makes the static link chain self-consistent and removes
# the apk-static guessing entirely. Same approach as the well-known
# "johnvansickle" static-ffmpeg Linux builds.
#
# License: GPL (links x264/x265/aom/...). fdk-aac is intentionally NOT enabled.
# Requires GNU tar/wget + a full build toolchain (installed by the workflow).

set -Eeuo pipefail

FFMPEG_VERSION="8.1.2"

PREFIX="/opt/ff"
SRC="/opt/src"
JOBS="$(nproc)"

mkdir -p "$PREFIX/lib/pkgconfig" "$PREFIX/include" "$SRC"

# Make every lib find the prefix's headers/static libs and each other's .pc files.
export CFLAGS="-I${PREFIX}/include -O2 -fPIC"
export CXXFLAGS="-I${PREFIX}/include -O2 -fPIC"
export LDFLAGS="-L${PREFIX}/lib"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig"
export PATH="${PREFIX}/bin:${PATH}"
export MAKEFLAGS="-j${JOBS}"

log() { printf '\n\033[1;34m========== %s ==========\033[0m\n' "$*"; }

# fetch OUTFILE URL [URL...]  -- try each mirror (with retries) until one works.
# Captures wget's actual error so a failed download says WHY (not just "failed").
fetch() {
  local out="$1"; shift
  local url i errfile
  errfile="$SRC/.wgeterr"
  for url in "$@"; do
    for i in 1 2 3 4 5; do
      if wget --no-check-certificate --tries=1 --timeout=45 \
           --user-agent="Mozilla/5.0 (static-build-ffmpeg)" \
           "$url" -O "$out" 2>"$errfile" && [ -s "$out" ]; then
        return 0
      fi
      echo "  (attempt $i for $(basename "$url") failed: $(tr '\r' '\n' < "$errfile" | grep -Ei 'error|fail|unable|refused|timed|not found|404|403|500|502|503' | tail -1))" >&2
      sleep $(( i * 3 ))
    done
    echo "  (exhausted retries on $url; trying next mirror if any)" >&2
  done
  echo "ERROR: could not download any of: $*" >&2
  return 1
}

# Fetch + extract a normal (single-root) archive into a fresh /opt/src/<name>.
# Uses --strip-components=1 so the top dir name (and any pax header) don't matter.
setup_src() {  # setup_src NAME URL [URL...]
  local name="$1"; shift
  local d="$SRC/$name"
  log "Building $name"
  rm -rf "$d"; mkdir -p "$d"
  fetch "$SRC/$name.archive" "$@"
  tar -xf "$SRC/$name.archive" -C "$d" --strip-components=1
  cd "$d"
}

# Generic autotools build: build_autotools NAME URL [extra configure args...]
build_autotools() {
  local name="$1" url="$2"; shift 2
  setup_src "$name" "$url"
  ./configure --prefix="$PREFIX" --enable-static --disable-shared "$@"
  make
  make install
}

# ---------------------------------------------------------------------------
# 1. zlib (custom configure, not autotools)
# ---------------------------------------------------------------------------
setup_src zlib "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
./configure --prefix="$PREFIX" --static
make
make install

# ---------------------------------------------------------------------------
# 2. expat (fontconfig dependency)
# ---------------------------------------------------------------------------
build_autotools expat \
  "https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.xz" \
  --without-docbook

# ---------------------------------------------------------------------------
# 3. freetype. GitHub tag archive (most reliable host) via meson; the
#    SourceForge release tarball is the fallback. Both archives ship meson.build.
#    (The GitHub git archive's top-level ./configure is only a stub; meson
#    avoids needing autogen.sh.)
# ---------------------------------------------------------------------------
setup_src freetype \
  "https://github.com/freetype/freetype/archive/refs/tags/VER-2-13-3.tar.gz" \
  "https://download.sourceforge.net/freetype/freetype-2.13.3.tar.xz"
meson setup build --prefix="$PREFIX" --default-library=static --strip \
  --wrap-mode=nodownload \
  -Dharfbuzz=disabled -Dbzip2=disabled -Dbrotli=disabled -Dpng=disabled \
  -Dzlib=enabled -Dtests=disabled
meson compile -C build
meson install -C build

# ---------------------------------------------------------------------------
# 4. fribidi
# ---------------------------------------------------------------------------
build_autotools fribidi \
  "https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz"

# ---------------------------------------------------------------------------
# 5. harfbuzz (meson; glib/icu disabled to avoid the glib transitive chain)
# ---------------------------------------------------------------------------
setup_src harfbuzz "https://github.com/harfbuzz/harfbuzz/releases/download/9.0.0/harfbuzz-9.0.0.tar.xz"
meson setup build --prefix="$PREFIX" --default-library=static --strip \
  --wrap-mode=nodownload \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled \
  -Dfreetype=enabled -Dtests=disabled -Dutilities=disabled
meson compile -C build
meson install -C build

# ---------------------------------------------------------------------------
# 6. fontconfig (needs freetype + expat). www.freedesktop.org returns HTTP 418
#    to automated clients right now, so use the Debian pool pristine upstream
#    tarball (release build, has a generated ./configure). freedesktop.org is
#    kept as a fallback in case Debian pool is unavailable.
# ---------------------------------------------------------------------------
setup_src fontconfig \
  "https://deb.debian.org/debian/pool/main/f/fontconfig/fontconfig_2.15.0.orig.tar.xz" \
  "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz"
./configure --prefix="$PREFIX" --enable-static --disable-shared \
  --sysconfdir=/etc --localstatedir=/var
make
make install

# ---------------------------------------------------------------------------
# 7. libass (needs harfbuzz + freetype + fontconfig). 0.16.x -> no libunibreak.
# ---------------------------------------------------------------------------
build_autotools libass \
  "https://github.com/libass/libass/releases/download/0.16.0/libass-0.16.0.tar.xz"

# ---------------------------------------------------------------------------
# 8. libogg
# ---------------------------------------------------------------------------
build_autotools libogg \
  "https://downloads.xiph.org/releases/ogg/libogg-1.3.5.tar.gz"

# ---------------------------------------------------------------------------
# 9. libvorbis (needs ogg)
# ---------------------------------------------------------------------------
build_autotools libvorbis \
  "https://downloads.xiph.org/releases/vorbis/libvorbis-1.3.7.tar.gz"

# ---------------------------------------------------------------------------
# 10. libtheora (needs ogg). Old; disable examples+spec (need SDL/docbook).
# ---------------------------------------------------------------------------
build_autotools libtheora \
  "https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.bz2" \
  --disable-examples --disable-spec

# ---------------------------------------------------------------------------
# 11. libwebp (webmproject storage mirror; no GitHub Releases)
# ---------------------------------------------------------------------------
build_autotools libwebp \
  "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0.tar.gz" \
  --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic

# ---------------------------------------------------------------------------
# 12. opus
# ---------------------------------------------------------------------------
build_autotools opus \
  "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz" \
  --disable-doc --disable-extra-programs

# ---------------------------------------------------------------------------
# 13. lame (mp3lame). SourceForge 403s the CI runner's IP, so use the Debian
#    pool pristine upstream tarball (release build with configure); SourceForge
#    URL kept as a fallback.
# ---------------------------------------------------------------------------
setup_src lame \
  "https://deb.debian.org/debian/pool/main/l/lame/lame_3.100.orig.tar.gz" \
  "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz"
./configure --prefix="$PREFIX" --enable-static --disable-shared \
  --disable-frontend --disable-analyzer --disable-gtktest
make
make install

# ---------------------------------------------------------------------------
# 14. libvpx (custom configure; GitHub tag archive, needs nasm)
# ---------------------------------------------------------------------------
setup_src libvpx "https://github.com/webmproject/libvpx/archive/refs/tags/v1.16.0.tar.gz"
./configure --prefix="$PREFIX" --enable-static --disable-shared \
  --disable-examples --disable-unit-tests --enable-vp8 --enable-vp9 \
  --enable-vp9-highbitdepth --as=nasm
make
make install

# ---------------------------------------------------------------------------
# 15. x264 (custom configure). code.videolan.org GitLab serves a bot-check
#    HTML page to the CI runner (its bz2 archive downloads as non-tar), so use
#    the github.com/mirror/x264 git archive (stable branch) instead; videolan
#    is kept only as a last-resort fallback.
# ---------------------------------------------------------------------------
setup_src x264 \
  "https://github.com/mirror/x264/archive/refs/heads/stable.tar.gz" \
  "https://github.com/mirror/x264/archive/refs/heads/master.tar.gz" \
  "https://code.videolan.org/videolan/x264/-/archive/stable/x264-stable.tar.bz2"
./configure --prefix="$PREFIX" --enable-static --disable-cli --disable-opencl
make
make install

# ---------------------------------------------------------------------------
# 16. x265 (cmake; bitbucket source archive, CMakeLists in source/)
# ---------------------------------------------------------------------------
setup_src x265 "https://bitbucket.org/multicoreware/x265_git/get/3.5.tar.gz"
cmake -G "Unix Makefiles" -S source -B build \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_LIBNUMA=OFF
cmake --build build
cmake --install build

# ---------------------------------------------------------------------------
# 17. aom (cmake; googlesource +archive extracts FLAT -> no strip)
# ---------------------------------------------------------------------------
log "Building aom"
ad="$SRC/aom"; rm -rf "$ad"; mkdir -p "$ad"; cd "$ad"
fetch "$SRC/aom.archive" "https://aomedia.googlesource.com/aom/+archive/v3.9.0.tar.gz"
tar -xzf "$SRC/aom.archive" -C "$ad"
cmake -G "Unix Makefiles" -S . -B build \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DCONFIG_PIC=0 \
  -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 -DENABLE_TOOLS=0
cmake --build build
cmake --install build

# ---------------------------------------------------------------------------
# 18. ffmpeg
# ---------------------------------------------------------------------------
# GitHub mirror first: ffmpeg.org frequently times out from the CI runner.
# (Both archives ship the same generated configure.)
setup_src ffmpeg \
  "https://github.com/FFmpeg/FFmpeg/archive/refs/tags/n${FFMPEG_VERSION}.tar.gz" \
  "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz"

# Static-link fixups on the generated .pc files (musl/Alpine):
#  - strip -lrt    (musl ships rt in libc; no separate librt is needed)
#  - strip -lgcc_s (Alpine ships no static libgcc_s.a, only libgcc_s.so, so
#                   ffmpeg's -static pkg-config probe fails "cannot find
#                   -lgcc_s". libgcc.a (via -lgcc) covers the symbols.
#                   Emitted mainly by x265.pc, the only C++ library here.)
for pc in "$PREFIX/lib/pkgconfig"/*.pc; do
  sed -i -e 's/ -lrt\b//g' -e 's/ -lgcc_s\b//g' "$pc" 2>/dev/null || true
done

# Diagnostic: x265's pkg-config link test is the usual static-build sticking
# point (it's a C++ lib). Print what pkg-config sees so a failure is obvious.
echo "=== x265.pc ==="; sed -n '1,20p' "$PREFIX/lib/pkgconfig/x265.pc" 2>/dev/null || echo "(no x265.pc)"
echo "=== pkg-config --static --libs x265 ==="; pkg-config --static --libs x265 2>&1 || true

# -lstdc++ is required: x265 is C++, and its static link test into ffmpeg's C
# configure probe needs the C++ runtime. musl ships -lrt/-ldl/-lm as libc stubs,
# so those resolve; -lstdc++ (from build-base's g++) is the one that must be named.
# (harfbuzz is also C++-compiled; the same -lstdc++ covers its static link test.)
#
# Text-rendering: --enable-libharfbuzz is NOT optional here. ffmpeg's drawtext
# filter hard-depends on BOTH libfreetype and libharfbuzz
# (configure: drawtext_filter_deps="libfreetype libharfbuzz"); enabling only
# libfreetype silently drops the drawtext filter from the build.
./configure \
  --prefix="$PREFIX" \
  --disable-debug --disable-doc \
  --disable-shared --enable-static \
  --enable-gpl --enable-version3 \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom \
  --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libtheora \
  --enable-libwebp --enable-libass \
  --enable-libfreetype --enable-libharfbuzz \
  --enable-libfontconfig --enable-libfribidi \
  --extra-cflags="-I${PREFIX}/include" \
  --extra-ldflags="-L${PREFIX}/lib -static" \
  --extra-ldexeflags="-static" \
  --extra-libs="-lpthread -lm -ldl -lstdc++" \
  --pkg-config-flags="--static" \
  || { echo "=== ffbuild/config.log (tail) ==="; tail -80 ffbuild/config.log 2>/dev/null; exit 1; }
make
make install

log "Build complete"
"$PREFIX/bin/ffmpeg" -version | head -20
