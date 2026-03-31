#!/bin/bash
#
# build.sh — Build a fully static FFmpeg with all dependencies from source.
#
# Usage:
#   ./build.sh              # build for the current OS
#   ./build.sh windows      # cross-compile for Windows (from Linux only)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Library versions (change these to update) ───────────────────────────────

X265_VERSION="4.1"
VPX_VERSION="1.16.0"
DAV1D_VERSION="1.5.3"
LAME_VERSION="3.100"
OPUS_VERSION="1.5.2"
OGG_VERSION="1.3.5"
VORBIS_VERSION="1.3.7"
FREETYPE_VERSION="2.13.3"
HARFBUZZ_VERSION="10.1.0"
FRIBIDI_VERSION="1.0.16"
LIBASS_VERSION="0.17.3"
LIBICONV_VERSION="1.17"
LIBWEBP_VERSION="1.5.0"
SVTAV1_VERSION="3.0.1"
ZLIB_VERSION="1.3.1"

# ── Platform detection ──────────────────────────────────────────────────────

HOST_OS="$(uname -s)"
HOST_ARCH="$(uname -m)"

case "$HOST_OS" in
    Darwin)                HOST_OS="macos" ;;
    Linux)                 HOST_OS="linux" ;;
    MINGW*|MSYS*|CYGWIN*) HOST_OS="windows" ;;
    *) echo "Error: Unsupported OS: $HOST_OS"; exit 1 ;;
esac

TARGET="${1:-$HOST_OS}"

case "$HOST_ARCH" in
    arm64|aarch64) ARCH="aarch64" ;;
    x86_64|amd64)  ARCH="x86_64" ;;
    *)             ARCH="$HOST_ARCH" ;;
esac

case "$HOST_OS" in
    macos) JOBS="$(sysctl -n hw.ncpu)" ;;
    *)     JOBS="$(nproc 2>/dev/null || echo 4)" ;;
esac

# ── Directories ─────────────────────────────────────────────────────────────

SRC_DIR="${SCRIPT_DIR}/deps/src"
BUILD_DIR="${SCRIPT_DIR}/deps/build/${TARGET}-${ARCH}"
PREFIX="${SCRIPT_DIR}/deps/install/${TARGET}-${ARCH}"
OUTPUT_DIR="${SCRIPT_DIR}/build_output/${TARGET}-${ARCH}"

mkdir -p "$SRC_DIR" "$BUILD_DIR" "$PREFIX" "$OUTPUT_DIR"

export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/lib64/pkgconfig"
export PATH="${PREFIX}/bin:$PATH"

# ── Cross-compilation setup ─────────────────────────────────────────────────

CROSS_PREFIX=""
CMAKE_TOOLCHAIN=""
MESON_CROSS_FILE=""
CONFIGURE_HOST=""

if [ "$TARGET" = "windows" ]; then
    if [ "$HOST_OS" != "linux" ]; then
        echo "Error: Windows cross-compilation requires a Linux host."
        exit 1
    fi
    CROSS_PREFIX="x86_64-w64-mingw32-"
    CONFIGURE_HOST="--host=x86_64-w64-mingw32"
    ARCH="x86_64"

    CMAKE_TOOLCHAIN="${BUILD_DIR}/mingw-toolchain.cmake"
    cat > "$CMAKE_TOOLCHAIN" <<TCEOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH ${PREFIX})
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TCEOF

    MESON_CROSS_FILE="${BUILD_DIR}/mingw-cross.ini"
    cat > "$MESON_CROSS_FILE" <<MCEOF
[binaries]
c = 'x86_64-w64-mingw32-gcc'
cpp = 'x86_64-w64-mingw32-g++'
ar = 'x86_64-w64-mingw32-ar'
strip = 'x86_64-w64-mingw32-strip'
windres = 'x86_64-w64-mingw32-windres'
pkgconfig = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
pkg_config_libdir = '${PREFIX}/lib/pkgconfig'
MCEOF
fi

# ── Helpers ─────────────────────────────────────────────────────────────────

log() {
    echo ""
    echo "================================================================"
    echo " $1"
    echo "================================================================"
}

download() {
    local url="$1"
    local dest="$2"
    if [ -f "$dest" ]; then
        echo ">> Already downloaded $(basename "$dest")"
        return
    fi
    echo ">> Downloading $(basename "$dest")..."
    curl -L --fail -o "$dest" "$url"
}

# ── Install build tools ────────────────────────────────────────────────────

install_build_tools() {
    log "Checking build tools"
    case "$HOST_OS" in
        macos)
            if ! command -v brew &>/dev/null; then
                echo "Error: Homebrew is required. Install from https://brew.sh"
                exit 1
            fi
            brew install --quiet \
                nasm cmake meson ninja pkg-config \
                autoconf automake libtool git \
                2>/dev/null || true
            ;;
        linux)
            sudo apt-get update -qq
            sudo apt-get install -y -qq \
                build-essential nasm yasm cmake meson ninja-build pkg-config \
                autoconf automake libtool git curl xz-utils python3
            if [ "$TARGET" = "windows" ]; then
                sudo apt-get install -y -qq mingw-w64 mingw-w64-tools
            fi
            ;;
    esac
}

# ── Dependency build functions ──────────────────────────────────────────────
#
# Build order:
#   1. ogg, lame, opus, fribidi, x264              (independent)
#   2. vorbis                                       (needs ogg)
#   3. x265, vpx, aom, dav1d                       (independent, slow)
#   4. freetype pass 1                              (without harfbuzz)
#   5. harfbuzz                                     (needs freetype)
#   6. freetype pass 2                              (with harfbuzz)
#   7. libass                                       (needs freetype, harfbuzz, fribidi)

build_x264() {
    if [ -f "${PREFIX}/lib/libx264.a" ]; then
        echo ">> x264 already built, skipping"
        return
    fi
    log "Building x264"

    local src="${SRC_DIR}/x264"
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch stable \
            https://code.videolan.org/videolan/x264.git "$src"
    fi

    cd "$src"
    make distclean 2>/dev/null || true

    local flags=(
        --prefix="$PREFIX"
        --enable-static
        --enable-pic
        --disable-shared
        --disable-cli
        --disable-opencl
    )
    if [ "$TARGET" = "windows" ]; then
        flags+=(--host=x86_64-w64-mingw32 --cross-prefix="$CROSS_PREFIX")
    fi

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
}

build_x265() {
    if [ -f "${PREFIX}/lib/libx265.a" ]; then
        echo ">> x265 already built, skipping"
        return
    fi
    log "Building x265 ${X265_VERSION} (12-bit + 10-bit + 8-bit)"

    download "https://bitbucket.org/multicoreware/x265_git/downloads/x265_${X265_VERSION}.tar.gz" \
        "${SRC_DIR}/x265_${X265_VERSION}.tar.gz"

    local src="${SRC_DIR}/x265_${X265_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/x265_${X265_VERSION}.tar.gz" -C "$SRC_DIR"

    local cmake_src="${src}/source"

    # Patch x265 CMakeLists.txt for cmake 4.x compatibility
    python3 -c "
import re, sys
p = sys.argv[1]
t = open(p).read()
t = re.sub(r'cmake_policy\(SET CMP0025 OLD\)[^\n]*\n', '', t)
t = re.sub(r'cmake_policy\(SET CMP0054 OLD\)[^\n]*\n', '', t)
t = re.sub(r'cmake_minimum_required\s*\([^)]*\)[^\n]*\n', '', t)
t = re.sub(r'^(project\s*\(x265\))', r'cmake_minimum_required(VERSION 3.10)\n\1', t, flags=re.M)
# CMP0025 OLD made AppleClang report as Clang; now we must handle it explicitly
t = t.replace(
    'if(\${CMAKE_CXX_COMPILER_ID} STREQUAL \"Clang\")',
    'if(\${CMAKE_CXX_COMPILER_ID} MATCHES \"^(Apple)?Clang\$\")')
open(p, 'w').write(t)
" "$cmake_src/CMakeLists.txt"

    local tc_flag=()
    [ -n "$CMAKE_TOOLCHAIN" ] && tc_flag=(-DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN")

    local common_flags=(
        -DCMAKE_BUILD_TYPE=Release
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON
        -DENABLE_SHARED=OFF
        -DENABLE_CLI=OFF
        ${tc_flag[@]+"${tc_flag[@]}"}
    )

    # 12-bit
    local build12="${BUILD_DIR}/x265-12bit"
    rm -rf "$build12"
    cmake -S "$cmake_src" -B "$build12" \
        "${common_flags[@]}" \
        -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=ON
    cmake --build "$build12" -j "$JOBS"

    # 10-bit
    local build10="${BUILD_DIR}/x265-10bit"
    rm -rf "$build10"
    cmake -S "$cmake_src" -B "$build10" \
        "${common_flags[@]}" \
        -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
    cmake --build "$build10" -j "$JOBS"

    # 8-bit (combined with 10-bit and 12-bit)
    local build8="${BUILD_DIR}/x265-8bit"
    rm -rf "$build8"
    mkdir -p "$build8"
    cp "$build12/libx265.a" "$build8/libx265_main12.a"
    cp "$build10/libx265.a" "$build8/libx265_main10.a"

    cmake -S "$cmake_src" -B "$build8" \
        "${common_flags[@]}" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DEXTRA_LIB="x265_main10.a;x265_main12.a" \
        -DEXTRA_LINK_FLAGS="-L${build8}" \
        -DLINKED_10BIT=ON \
        -DLINKED_12BIT=ON
    cmake --build "$build8" -j "$JOBS"
    cmake --install "$build8"

    # Merge 8-bit, 10-bit, and 12-bit into a single static library.
    # Archives have duplicate .o names, so extract into separate dirs
    # then rename to avoid collisions.
    local merged_dir="${BUILD_DIR}/x265-merged"
    rm -rf "$merged_dir"
    mkdir -p "$merged_dir"

    cd "$merged_dir"
    for lib in "${PREFIX}/lib/libx265.a" "$build8/libx265_main10.a" "$build8/libx265_main12.a"; do
        local subdir
        subdir="$(basename "$lib" .a)"
        mkdir -p "$subdir"
        cd "$subdir"
        ar x "$lib"
        # Prefix each .o with the lib name to avoid duplicates
        for f in *.o; do
            mv "$f" "${subdir}_${f}"
        done
        cd "$merged_dir"
    done

    ar cr "${PREFIX}/lib/libx265.a" */*.o
    ranlib "${PREFIX}/lib/libx265.a"
}

build_vpx() {
    if [ -f "${PREFIX}/lib/libvpx.a" ]; then
        echo ">> libvpx already built, skipping"
        return
    fi
    log "Building libvpx ${VPX_VERSION}"

    download "https://github.com/webmproject/libvpx/archive/refs/tags/v${VPX_VERSION}.tar.gz" \
        "${SRC_DIR}/libvpx-${VPX_VERSION}.tar.gz"

    local src="${SRC_DIR}/libvpx-${VPX_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/libvpx-${VPX_VERSION}.tar.gz" -C "$SRC_DIR"

    cd "$src"
    make clean 2>/dev/null || true

    local flags=(
        --prefix="$PREFIX"
        --enable-static
        --disable-shared
        --disable-examples
        --disable-tools
        --disable-unit-tests
        --disable-docs
        --enable-vp9-highbitdepth
        --enable-pic
    )
    if [ "$TARGET" = "windows" ]; then
        flags+=(--target=x86_64-win64-gcc)
        export CROSS="$CROSS_PREFIX"
    fi

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
    unset CROSS 2>/dev/null || true
}

build_aom() {
    if [ -f "${PREFIX}/lib/libaom.a" ]; then
        echo ">> libaom already built, skipping"
        return
    fi
    log "Building libaom"

    local src="${SRC_DIR}/aom"
    if [ ! -d "$src" ]; then
        git clone --depth 1 --branch main \
            https://aomedia.googlesource.com/aom "$src"
    fi

    local build_subdir="${BUILD_DIR}/aom"
    rm -rf "$build_subdir"

    local tc_flag=()
    [ -n "$CMAKE_TOOLCHAIN" ] && tc_flag=(-DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN")

    cmake -S "$src" -B "$build_subdir" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DENABLE_DOCS=0 \
        -DENABLE_EXAMPLES=0 \
        -DENABLE_TESTS=0 \
        -DENABLE_TOOLS=0 \
        ${tc_flag[@]+"${tc_flag[@]}"}
    cmake --build "$build_subdir" -j "$JOBS"
    cmake --install "$build_subdir"
}

build_webp() {
    if [ -f "${PREFIX}/lib/libwebp.a" ]; then
        echo ">> libwebp already built, skipping"
        return
    fi
    log "Building libwebp ${LIBWEBP_VERSION}"

    download "https://github.com/webmproject/libwebp/archive/refs/tags/v${LIBWEBP_VERSION}.tar.gz" \
        "${SRC_DIR}/libwebp-${LIBWEBP_VERSION}.tar.gz"

    local src="${SRC_DIR}/libwebp-${LIBWEBP_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/libwebp-${LIBWEBP_VERSION}.tar.gz" -C "$SRC_DIR"

    local build_subdir="${BUILD_DIR}/libwebp"
    rm -rf "$build_subdir"

    local tc_flag=()
    [ -n "$CMAKE_TOOLCHAIN" ] && tc_flag=(-DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN")

    cmake -S "$src" -B "$build_subdir" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DWEBP_BUILD_ANIM_UTILS=OFF \
        -DWEBP_BUILD_CWEBP=OFF \
        -DWEBP_BUILD_DWEBP=OFF \
        -DWEBP_BUILD_GIF2WEBP=OFF \
        -DWEBP_BUILD_IMG2WEBP=OFF \
        -DWEBP_BUILD_VWEBP=OFF \
        -DWEBP_BUILD_WEBPINFO=OFF \
        -DWEBP_BUILD_WEBPMUX=OFF \
        -DWEBP_BUILD_EXTRAS=OFF \
        ${tc_flag[@]+"${tc_flag[@]}"}
    cmake --build "$build_subdir" -j "$JOBS"
    cmake --install "$build_subdir"
}

build_svtav1() {
    if [ -f "${PREFIX}/lib/libSvtAv1Enc.a" ]; then
        echo ">> SVT-AV1 already built, skipping"
        return
    fi
    log "Building SVT-AV1 ${SVTAV1_VERSION}"

    download "https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v${SVTAV1_VERSION}/SVT-AV1-v${SVTAV1_VERSION}.tar.gz" \
        "${SRC_DIR}/SVT-AV1-v${SVTAV1_VERSION}.tar.gz"

    local src="${SRC_DIR}/SVT-AV1-v${SVTAV1_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/SVT-AV1-v${SVTAV1_VERSION}.tar.gz" -C "$SRC_DIR"

    local build_subdir="${BUILD_DIR}/svtav1"
    rm -rf "$build_subdir"

    local tc_flag=()
    [ -n "$CMAKE_TOOLCHAIN" ] && tc_flag=(-DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN")

    cmake -S "$src" -B "$build_subdir" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DBUILD_APPS=OFF \
        -DBUILD_DEC=OFF \
        -DBUILD_TESTING=OFF \
        ${tc_flag[@]+"${tc_flag[@]}"}
    cmake --build "$build_subdir" -j "$JOBS"
    cmake --install "$build_subdir"
}

build_dav1d() {
    if [ -f "${PREFIX}/lib/libdav1d.a" ]; then
        echo ">> dav1d already built, skipping"
        return
    fi
    log "Building dav1d ${DAV1D_VERSION}"

    download "https://code.videolan.org/videolan/dav1d/-/archive/${DAV1D_VERSION}/dav1d-${DAV1D_VERSION}.tar.bz2" \
        "${SRC_DIR}/dav1d-${DAV1D_VERSION}.tar.bz2"

    local src="${SRC_DIR}/dav1d-${DAV1D_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/dav1d-${DAV1D_VERSION}.tar.bz2" -C "$SRC_DIR"

    local build_subdir="${BUILD_DIR}/dav1d"
    rm -rf "$build_subdir"

    local cross_flag=()
    [ -n "$MESON_CROSS_FILE" ] && cross_flag=(--cross-file "$MESON_CROSS_FILE")

    meson setup "$build_subdir" "$src" \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Denable_tools=false \
        -Denable_tests=false \
        ${cross_flag[@]+"${cross_flag[@]}"}
    ninja -C "$build_subdir"
    ninja -C "$build_subdir" install
}

build_lame() {
    if [ -f "${PREFIX}/lib/libmp3lame.a" ]; then
        echo ">> lame already built, skipping"
        return
    fi
    log "Building lame ${LAME_VERSION}"

    download "https://sourceforge.net/projects/lame/files/lame/${LAME_VERSION}/lame-${LAME_VERSION}.tar.gz/download" \
        "${SRC_DIR}/lame-${LAME_VERSION}.tar.gz"

    local src="${SRC_DIR}/lame-${LAME_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/lame-${LAME_VERSION}.tar.gz" -C "$SRC_DIR"

    cd "$src"
    make distclean 2>/dev/null || true

    local flags=(
        --prefix="$PREFIX"
        --enable-static
        --disable-shared
        --disable-frontend
        --disable-decoder
        --enable-nasm
        --with-pic
    )
    [ -n "$CONFIGURE_HOST" ] && flags+=($CONFIGURE_HOST)

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
}

build_opus() {
    if [ -f "${PREFIX}/lib/libopus.a" ]; then
        echo ">> opus already built, skipping"
        return
    fi
    log "Building opus ${OPUS_VERSION}"

    download "https://downloads.xiph.org/releases/opus/opus-${OPUS_VERSION}.tar.gz" \
        "${SRC_DIR}/opus-${OPUS_VERSION}.tar.gz"

    local src="${SRC_DIR}/opus-${OPUS_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/opus-${OPUS_VERSION}.tar.gz" -C "$SRC_DIR"

    cd "$src"
    make distclean 2>/dev/null || true

    local flags=(
        --prefix="$PREFIX"
        --enable-static
        --disable-shared
        --disable-doc
        --disable-extra-programs
    )
    [ -n "$CONFIGURE_HOST" ] && flags+=($CONFIGURE_HOST)

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
}

build_zlib() {
    if [ -f "${PREFIX}/lib/libz.a" ]; then
        echo ">> zlib already built, skipping"
        return
    fi
    log "Building zlib ${ZLIB_VERSION}"

    download "https://github.com/madler/zlib/releases/download/v${ZLIB_VERSION}/zlib-${ZLIB_VERSION}.tar.gz" \
        "${SRC_DIR}/zlib-${ZLIB_VERSION}.tar.gz"

    local src="${SRC_DIR}/zlib-${ZLIB_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/zlib-${ZLIB_VERSION}.tar.gz" -C "$SRC_DIR"

    cd "$src"
    make distclean 2>/dev/null || true

    if [ "$TARGET" = "windows" ]; then
        CROSS_PREFIX="$CROSS_PREFIX" ./configure \
            --prefix="$PREFIX" \
            --static
    else
        ./configure \
            --prefix="$PREFIX" \
            --static
    fi
    make -j"$JOBS"
    make install
    # Remove any shared libs zlib may have installed
    rm -f "${PREFIX}/lib"/libz.so* "${PREFIX}/lib"/libz.dylib* 2>/dev/null || true
}

build_iconv() {
    if [ -f "${PREFIX}/lib/libiconv.a" ]; then
        echo ">> libiconv already built, skipping"
        return
    fi
    log "Building libiconv ${LIBICONV_VERSION}"

    download "https://ftp.gnu.org/pub/gnu/libiconv/libiconv-${LIBICONV_VERSION}.tar.gz" \
        "${SRC_DIR}/libiconv-${LIBICONV_VERSION}.tar.gz"

    local src="${SRC_DIR}/libiconv-${LIBICONV_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/libiconv-${LIBICONV_VERSION}.tar.gz" -C "$SRC_DIR"

    cd "$src"
    make distclean 2>/dev/null || true

    local flags=(
        --prefix="$PREFIX"
        --enable-static
        --disable-shared
        --with-pic
    )
    [ -n "$CONFIGURE_HOST" ] && flags+=($CONFIGURE_HOST)

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
    rm -f "${PREFIX}/bin/iconv"
}

build_ogg() {
    if [ -f "${PREFIX}/lib/libogg.a" ]; then
        echo ">> libogg already built, skipping"
        return
    fi
    log "Building libogg ${OGG_VERSION}"

    download "https://downloads.xiph.org/releases/ogg/libogg-${OGG_VERSION}.tar.xz" \
        "${SRC_DIR}/libogg-${OGG_VERSION}.tar.xz"

    local src="${SRC_DIR}/libogg-${OGG_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/libogg-${OGG_VERSION}.tar.xz" -C "$SRC_DIR"

    cd "$src"
    make distclean 2>/dev/null || true

    local flags=(
        --prefix="$PREFIX"
        --enable-static
        --disable-shared
    )
    [ -n "$CONFIGURE_HOST" ] && flags+=($CONFIGURE_HOST)

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
}

build_vorbis() {
    if [ -f "${PREFIX}/lib/libvorbis.a" ]; then
        echo ">> libvorbis already built, skipping"
        return
    fi
    log "Building libvorbis ${VORBIS_VERSION}"

    download "https://downloads.xiph.org/releases/vorbis/libvorbis-${VORBIS_VERSION}.tar.xz" \
        "${SRC_DIR}/libvorbis-${VORBIS_VERSION}.tar.xz"

    local src="${SRC_DIR}/libvorbis-${VORBIS_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/libvorbis-${VORBIS_VERSION}.tar.xz" -C "$SRC_DIR"

    cd "$src"
    make distclean 2>/dev/null || true

    local flags=(
        --prefix="$PREFIX"
        --enable-static
        --disable-shared
    )
    [ -n "$CONFIGURE_HOST" ] && flags+=($CONFIGURE_HOST)

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
}

build_freetype() {
    local pass="${1:-1}"
    if [ "$pass" = "2" ] && [ -f "${PREFIX}/.freetype_sandwich_done" ]; then
        echo ">> freetype (sandwich) already built, skipping"
        return
    fi
    if [ "$pass" = "1" ] && [ -f "${PREFIX}/lib/libfreetype.a" ]; then
        echo ">> freetype pass 1 already built, skipping"
        return
    fi
    log "Building freetype ${FREETYPE_VERSION} (pass ${pass})"

    download "https://download.savannah.gnu.org/releases/freetype/freetype-${FREETYPE_VERSION}.tar.xz" \
        "${SRC_DIR}/freetype-${FREETYPE_VERSION}.tar.xz"

    local src="${SRC_DIR}/freetype-${FREETYPE_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/freetype-${FREETYPE_VERSION}.tar.xz" -C "$SRC_DIR"

    local build_subdir="${BUILD_DIR}/freetype-pass${pass}"
    rm -rf "$build_subdir"

    local tc_flag=()
    [ -n "$CMAKE_TOOLCHAIN" ] && tc_flag=(-DCMAKE_TOOLCHAIN_FILE="$CMAKE_TOOLCHAIN")

    local hb_flags=(-DFT_DISABLE_HARFBUZZ=TRUE)
    if [ "$pass" = "2" ]; then
        hb_flags=(-DFT_DISABLE_HARFBUZZ=FALSE -DFT_REQUIRE_HARFBUZZ=TRUE)
    fi

    cmake -S "$src" -B "$build_subdir" \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_BROTLI=TRUE \
        -DFT_DISABLE_PNG=TRUE \
        -DFT_DISABLE_BZIP2=TRUE \
        "${hb_flags[@]}" \
        ${tc_flag[@]+"${tc_flag[@]}"}
    cmake --build "$build_subdir" -j "$JOBS"
    cmake --install "$build_subdir"
    [ "$pass" = "2" ] && touch "${PREFIX}/.freetype_sandwich_done"
}

build_harfbuzz() {
    if [ -f "${PREFIX}/lib/libharfbuzz.a" ]; then
        echo ">> harfbuzz already built, skipping"
        return
    fi
    log "Building harfbuzz ${HARFBUZZ_VERSION}"

    download "https://github.com/harfbuzz/harfbuzz/releases/download/${HARFBUZZ_VERSION}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" \
        "${SRC_DIR}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz"

    local src="${SRC_DIR}/harfbuzz-${HARFBUZZ_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/harfbuzz-${HARFBUZZ_VERSION}.tar.xz" -C "$SRC_DIR"

    local build_subdir="${BUILD_DIR}/harfbuzz"
    rm -rf "$build_subdir"

    local cross_flag=()
    [ -n "$MESON_CROSS_FILE" ] && cross_flag=(--cross-file "$MESON_CROSS_FILE")

    meson setup "$build_subdir" "$src" \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Dfreetype=enabled \
        -Dcairo=disabled \
        -Dicu=disabled \
        -Dglib=disabled \
        -Dgobject=disabled \
        -Dtests=disabled \
        -Ddocs=disabled \
        ${cross_flag[@]+"${cross_flag[@]}"}
    ninja -C "$build_subdir"
    ninja -C "$build_subdir" install
}

build_fribidi() {
    if [ -f "${PREFIX}/lib/libfribidi.a" ]; then
        echo ">> fribidi already built, skipping"
        return
    fi
    log "Building fribidi ${FRIBIDI_VERSION}"

    download "https://github.com/fribidi/fribidi/releases/download/v${FRIBIDI_VERSION}/fribidi-${FRIBIDI_VERSION}.tar.xz" \
        "${SRC_DIR}/fribidi-${FRIBIDI_VERSION}.tar.xz"

    local src="${SRC_DIR}/fribidi-${FRIBIDI_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/fribidi-${FRIBIDI_VERSION}.tar.xz" -C "$SRC_DIR"

    local build_subdir="${BUILD_DIR}/fribidi"
    rm -rf "$build_subdir"

    local cross_flag=()
    [ -n "$MESON_CROSS_FILE" ] && cross_flag=(--cross-file "$MESON_CROSS_FILE")

    meson setup "$build_subdir" "$src" \
        --prefix="$PREFIX" \
        --libdir=lib \
        --default-library=static \
        --buildtype=release \
        -Dbin=false \
        -Ddocs=false \
        -Dtests=false \
        ${cross_flag[@]+"${cross_flag[@]}"}
    ninja -C "$build_subdir"
    ninja -C "$build_subdir" install
}

build_libass() {
    if [ -f "${PREFIX}/lib/libass.a" ]; then
        echo ">> libass already built, skipping"
        return
    fi
    log "Building libass ${LIBASS_VERSION}"

    download "https://github.com/libass/libass/releases/download/${LIBASS_VERSION}/libass-${LIBASS_VERSION}.tar.xz" \
        "${SRC_DIR}/libass-${LIBASS_VERSION}.tar.xz"

    local src="${SRC_DIR}/libass-${LIBASS_VERSION}"
    [ ! -d "$src" ] && tar xf "${SRC_DIR}/libass-${LIBASS_VERSION}.tar.xz" -C "$SRC_DIR"

    cd "$src"
    make distclean 2>/dev/null || true

    local flags=(
        --prefix="$PREFIX"
        --enable-static
        --disable-shared
        --disable-fontconfig
        --disable-require-system-font-provider
    )
    [ -n "$CONFIGURE_HOST" ] && flags+=($CONFIGURE_HOST)

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
}

# ── Build FFmpeg ────────────────────────────────────────────────────────────

build_ffmpeg() {
    log "Building FFmpeg"
    cd "$SCRIPT_DIR"
    make distclean 2>/dev/null || true

    # Platform-specific linker flags (must be set before the flags array
    # because --extra-ldflags can only appear once)
    local extra_ldflags="-L${PREFIX}/lib"
    local platform_flags=()

    case "$TARGET" in
        linux)
            extra_ldflags="-L${PREFIX}/lib -static"
            platform_flags+=(
                --extra-ldexeflags="-static"
                "--extra-libs=-lpthread -lm"
            )
            ;;
        windows)
            extra_ldflags="-L${PREFIX}/lib -static"
            platform_flags+=(
                --enable-cross-compile
                --target-os=mingw32
                --arch="$ARCH"
                --cross-prefix="$CROSS_PREFIX"
            )
            ;;
    esac

    local flags=(
        --prefix="$OUTPUT_DIR"
        --extra-cflags="-I${PREFIX}/include"
        --extra-ldflags="$extra_ldflags"
        --pkg-config-flags="--static"

        --enable-static
        --disable-shared
        --enable-gpl
        --enable-version3

        # Video codecs
        --enable-libx264
        --enable-libx265
        --enable-libvpx
        --enable-libdav1d
        --enable-libsvtav1

        # Image codecs
        --enable-libwebp

        # Audio codecs (AAC uses FFmpeg built-in encoder)
        --enable-libmp3lame
        --enable-libopus
        --enable-libvorbis

        # Subtitles
        --enable-libass
        --enable-libfreetype
        --enable-libharfbuzz
        --enable-libfribidi

        # General
        --enable-zlib
        --enable-iconv
        --enable-optimizations
        --enable-runtime-cpudetect

        # Disable what a converter doesn't need
        --disable-autodetect
        --disable-ffplay
        --disable-avdevice
        --disable-indevs
        --disable-outdevs
        --disable-network
        --disable-protocols
        --enable-protocol=file
        --enable-protocol=pipe
        --disable-doc
        --disable-htmlpages
        --disable-manpages
        --disable-podpages
        --disable-txtpages
        --disable-debug

        # Disable GPU/hardware acceleration (binary must run on any machine)
        --disable-cuvid
        --disable-nvenc
        --disable-nvdec
        --disable-ffnvcodec
        --disable-vaapi
        --disable-vdpau
        --disable-videotoolbox
        --disable-audiotoolbox
        --disable-d3d11va
        --disable-d3d12va
        --disable-dxva2
        --disable-vulkan
        --disable-opencl
        --disable-v4l2-m2m
        --disable-libdrm
        --disable-amf
        --disable-cuda-llvm

        # Disable autodetected system libs we don't need
        --disable-alsa
        --disable-appkit
        --disable-avfoundation
        --disable-bzlib
        --disable-coreimage
        --disable-lzma
        --disable-metal
        --disable-mediafoundation
        --disable-schannel
        --disable-sdl2
        --disable-securetransport
        --disable-sndio
        --disable-xlib
        --disable-libxcb
        --disable-libxcb-shm
        --disable-libxcb-shape
        --disable-libxcb-xfixes

        ${platform_flags[@]+"${platform_flags[@]}"}
    )

    ./configure "${flags[@]}"
    make -j"$JOBS"
    make install
}

# ── Main ────────────────────────────────────────────────────────────────────

echo "================================================================"
echo " FFmpeg Static Build"
echo "================================================================"
echo " Target:  ${TARGET}-${ARCH}"
echo " Host:    ${HOST_OS}-${HOST_ARCH}"
echo " Deps:    ${PREFIX}"
echo " Output:  ${OUTPUT_DIR}"
echo " Jobs:    ${JOBS}"
echo "================================================================"

install_build_tools

# Phase 1: Dependencies
build_zlib
build_iconv
build_ogg
build_lame
build_opus
build_fribidi
build_x264

build_vorbis        # needs ogg

build_x265
build_vpx
build_dav1d
build_webp
build_svtav1

build_freetype 1    # without harfbuzz
build_harfbuzz      # with freetype
build_freetype 2    # rebuild with harfbuzz
build_libass        # needs freetype, harfbuzz, fribidi

# Phase 2: FFmpeg
build_ffmpeg

# ── Verify ──────────────────────────────────────────────────────────────────

log "Build complete!"

FFMPEG_BIN="${OUTPUT_DIR}/bin/ffmpeg"
[ "$TARGET" = "windows" ] && FFMPEG_BIN="${FFMPEG_BIN}.exe"

if [ -f "$FFMPEG_BIN" ]; then
    echo " ffmpeg:  ${FFMPEG_BIN}"
    echo " Size:    $(du -h "$FFMPEG_BIN" | cut -f1)"

    if [ "$TARGET" = "$HOST_OS" ]; then
        echo ""
        echo ">> Encoders:"
        "$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null \
            | grep -E "libx26[45]|libvpx|libsvtav1|libwebp|libmp3lame|libopus|libvorbis" || true

        echo ""
        echo ">> Dynamic dependencies (should be system-only on macOS, none on Linux):"
        case "$HOST_OS" in
            macos) otool -L "$FFMPEG_BIN" ;;
            linux) ldd "$FFMPEG_BIN" 2>/dev/null || echo " (fully static)" ;;
        esac
    fi
else
    echo "Error: ffmpeg binary not found at ${FFMPEG_BIN}"
    exit 1
fi

echo "================================================================"
