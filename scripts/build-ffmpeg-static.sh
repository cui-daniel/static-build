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
# the apk-static guessing entirely. This is the same approach used by the
# well-known "johnvansickle" static-ffmpeg Linux builds.
#
# License: GPL (links x264/x265/aom/...). fdk-aac is intentionally NOT enabled.

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

download() {  # download URL OUTFILE
  wget -q --no-check-certificate "$1" -O "$2"
}

topdir() {  # topdir ARCHIVE -> first path component of the archive
  tar -tf "$1" | head -1 | cut -d/ -f1
}

# Generic autotools build: build_autotools NAME URL [extra configure args...]
build_autotools() {
  local name="$1" url="$2"; shift 2
  log "Building $name"
  cd "$SRC"
  download "$url" "${name}.archive"
  local dir; dir=$(topdir "${name}.archive")
  rm -rf "$dir"
  tar -xf "${name}.archive"
  cd "$dir"
  ./configure --prefix="$PREFIX" --enable-static --disable-shared "$@"
  make
  make install
}

# ---------------------------------------------------------------------------
# 1. zlib (custom configure, not autotools)
# ---------------------------------------------------------------------------
log "Building zlib"
cd "$SRC"
download "https://zlib.net/zlib-1.3.1.tar.gz" zlib.archive
zdir=$(topdir zlib.archive); rm -rf "$zdir"; tar -xf zlib.archive; cd "$zdir"
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
# 3. freetype (no harfbuzz/png/bzip2/brotli -> minimal deps)
# ---------------------------------------------------------------------------
build_autotools freetype \
  "https://download.savannah.gnu.org/releases/freetype/freetype-2.13.3.tar.xz" \
  --without-harfbuzz --without-png --without-bzip2 --without-brotli

# ---------------------------------------------------------------------------
# 4. fribidi
# ---------------------------------------------------------------------------
build_autotools fribidi \
  "https://github.com/fribidi/fribidi/releases/download/v1.0.16/fribidi-1.0.16.tar.xz"

# ---------------------------------------------------------------------------
# 5. harfbuzz (meson, glib/icu disabled to avoid the glib transitive chain)
# ---------------------------------------------------------------------------
log "Building harfbuzz"
cd "$SRC"
download "https://github.com/harfbuzz/harfbuzz/releases/download/9.0.0/harfbuzz-9.0.0.tar.xz" harfbuzz.archive
hdir=$(topdir harfbuzz.archive); rm -rf "$hdir"; tar -xf harfbuzz.archive; cd "$hdir"
meson setup build --prefix="$PREFIX" --default-library=static --strip \
  --wrap-mode=nodownload \
  -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dicu=disabled \
  -Dfreetype=enabled -Dtests=disabled -Dutilities=disabled
meson compile -C build
meson install -C build

# ---------------------------------------------------------------------------
# 6. fontconfig (needs freetype + expat)
# ---------------------------------------------------------------------------
build_autotools fontconfig \
  "https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.15.0.tar.xz" \
  --sysconfdir=/etc --localstatedir=/var

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
# 10. libtheora (needs ogg)
# ---------------------------------------------------------------------------
build_autotools libtheora \
  "https://downloads.xiph.org/releases/theora/libtheora-1.1.1.tar.bz2" \
  --disable-examples

# ---------------------------------------------------------------------------
# 11. libwebp
# ---------------------------------------------------------------------------
build_autotools libwebp \
  "https://github.com/webmproject/libwebp/releases/download/v1.4.0/libwebp-1.4.0.tar.gz" \
  --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic

# ---------------------------------------------------------------------------
# 12. opus
# ---------------------------------------------------------------------------
build_autotools opus \
  "https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz" \
  --disable-doc --disable-extra-programs

# ---------------------------------------------------------------------------
# 13. lame (mp3lame)
# ---------------------------------------------------------------------------
build_autotools lame \
  "https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz" \
  --disable-frontend --disable-analyzer --disable-gtktest

# ---------------------------------------------------------------------------
# 14. libvpx (custom configure, needs nasm)
# ---------------------------------------------------------------------------
log "Building libvpx"
cd "$SRC"
download "https://github.com/webmproject/libvpx/releases/download/v1.14.1/libvpx-1.14.1.tar.gz" libvpx.archive
vdir=$(topdir libvpx.archive); rm -rf "$vdir"; tar -xf libvpx.archive; cd "$vdir"
./configure --prefix="$PREFIX" --enable-static --disable-shared \
  --disable-examples --disable-unit-tests --enable-vp8 --enable-vp9 \
  --enable-vp9-highbitdepth --as=nasm
make
make install

# ---------------------------------------------------------------------------
# 15. x264 (snapshot, custom configure)
# ---------------------------------------------------------------------------
log "Building x264"
cd "$SRC"
download "https://download.videolan.org/pub/videolan/x264/snapshots/last_x264.tar.bz2" x264.archive
xdir=$(topdir x264.archive); rm -rf "$xdir"; tar -xf x264.archive; cd "$xdir"
./configure --prefix="$PREFIX" --enable-static --disable-cli --disable-opencl
make
make install

# ---------------------------------------------------------------------------
# 16. x265 (cmake, from source/ subdir)
# ---------------------------------------------------------------------------
log "Building x265"
cd "$SRC"
download "https://bitbucket.org/multicoreware/x265_git/downloads/x265_3.5.tar.gz" x265.archive
x2dir=$(topdir x265.archive); rm -rf "$x2dir"; tar -xf x265.archive; cd "$x2dir"
cmake -G "Unix Makefiles" -S source -B build \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_LIBNUMA=OFF
cmake --build build
cmake --install build
# x265.pc may reference -lrt, which musl does not ship separately -> strip it.
sed -i 's/ -lrt\b//g' "$PREFIX/lib/pkgconfig/x265.pc" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 17. aom (cmake; googlesource archive extracts flat)
# ---------------------------------------------------------------------------
log "Building aom"
cd "$SRC"
rm -rf aom-src; mkdir aom-src; cd aom-src
download "https://aomedia.googlesource.com/aom/+archive/v3.9.0.tar.gz" aom.archive
tar -xzf aom.archive
cmake -G "Unix Makefiles" -S . -B build \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=OFF -DCONFIG_PIC=0 \
  -DENABLE_TESTS=0 -DENABLE_EXAMPLES=0 -DENABLE_TOOLS=0
cmake --build build
cmake --install build

# ---------------------------------------------------------------------------
# 18. ffmpeg
# ---------------------------------------------------------------------------
log "Building ffmpeg ${FFMPEG_VERSION}"
cd "$SRC"
download "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" ffmpeg.archive
fdir=$(topdir ffmpeg.archive); rm -rf "$fdir"; tar -xf ffmpeg.archive; cd "$fdir"
./configure \
  --prefix="$PREFIX" \
  --disable-debug --disable-doc \
  --disable-shared --enable-static \
  --enable-gpl --enable-version3 \
  --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom \
  --enable-libmp3lame --enable-libopus --enable-libvorbis --enable-libtheora \
  --enable-libwebp --enable-libass --enable-libfreetype \
  --enable-libfontconfig --enable-libfribidi \
  --extra-cflags="-I${PREFIX}/include" \
  --extra-ldflags="-L${PREFIX}/lib -static" \
  --extra-ldexeflags="-static" \
  --extra-libs="-lpthread -lm -ldl" \
  --pkg-config-flags="--static"
make
make install

log "Build complete"
"$PREFIX/bin/ffmpeg" -version | head -20
