#!/usr/bin/env bash
# compile-windows.sh — Cross-compile RNRC Windows CLI + GUI from Ubuntu 22.04
# Produces: release/windows/RNRCd.exe and (when Qt is available) RNRC-qt.exe
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

TARGET_ARCH="${TARGET_ARCH:-x86_64}"   # or i686
TARGET="${TARGET_ARCH}-w64-mingw32"
DEPS="${DEPS_DIR:-$ROOT/depends/$TARGET}"
SRC_DEPS="$DEPS/src"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"
RELEASE_DIR="$ROOT/release/windows"
BUILD_GUI="${BUILD_GUI:-1}"
USE_UPNP="${USE_UPNP:-0}"

OPENSSL_VER="${OPENSSL_VER:-3.0.13}"
BOOST_VER="${BOOST_VER:-1.82.0}"
BOOST_VER_U="${BOOST_VER//./_}"
BDB_VER="4.8.30"
MINIUPNPC_VER="${MINIUPNPC_VER:-2.2.6}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || return 1
}

check_ubuntu() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        log "Host: ${PRETTY_NAME:-unknown}"
        if [[ "${ID:-}" == "ubuntu" ]]; then
            case "${VERSION_ID:-}" in
                22.04) ;;
                24.04|26.04)
                    warn "This script is tuned for Ubuntu 22.04; continuing on ${VERSION_ID}."
                    ;;
                *)
                    warn "Untested Ubuntu ${VERSION_ID:-?}; continuing anyway."
                    ;;
            esac
        else
            warn "Non-Ubuntu host; mingw package names may differ."
        fi
    fi
}

apt_install() {
    local pkgs=("$@")
    local missing=()
    local p
    for p in "${pkgs[@]}"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then
            missing+=("$p")
        fi
    done
    if ((${#missing[@]})); then
        log "Installing missing packages: ${missing[*]}"
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    else
        log "All required apt packages already installed."
    fi
}

setup_mingw_posix() {
    if need_cmd update-alternatives; then
        if [[ -x /usr/bin/${TARGET}-g++-posix ]]; then
            sudo update-alternatives --set "${TARGET}-g++" "/usr/bin/${TARGET}-g++-posix" 2>/dev/null || true
        fi
        if [[ -x /usr/bin/${TARGET}-gcc-posix ]]; then
            sudo update-alternatives --set "${TARGET}-gcc" "/usr/bin/${TARGET}-gcc-posix" 2>/dev/null || true
        fi
    fi
    need_cmd "${TARGET}-g++" || die "Missing ${TARGET}-g++ (install mingw-w64)"
    need_cmd "${TARGET}-gcc" || die "Missing ${TARGET}-gcc"
    log "Using $($TARGET-g++ --version | head -1)"
}

download() {
    local url="$1" out="$2"
    if [[ -f "$out" ]]; then
        log "Already downloaded: $out"
        return 0
    fi
    log "Downloading $url"
    if need_cmd curl; then
        curl -fL --retry 3 --retry-delay 2 -o "$out" "$url" \
            || curl -fL --retry 3 -k -o "$out" "$url"
    else
        wget -O "$out" "$url"
    fi
}

verify_file() {
    local f="$1" msg="$2"
    [[ -e "$f" ]] || die "$msg (missing: $f)"
}

build_zlib() {
    local marker="$DEPS/.zlib.ok"
    [[ -f "$marker" ]] && { log "zlib already built"; return 0; }
    mkdir -p "$SRC_DEPS"
    cd "$SRC_DEPS"
    download "https://zlib.net/zlib-${ZLIB_VER}.tar.gz" "zlib-${ZLIB_VER}.tar.gz" \
        || download "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" "zlib-${ZLIB_VER}.tar.gz"
    rm -rf "zlib-${ZLIB_VER}"
    tar xzf "zlib-${ZLIB_VER}.tar.gz"
    cd "zlib-${ZLIB_VER}"
    CC="${TARGET}-gcc" AR="${TARGET}-ar" RANLIB="${TARGET}-ranlib" \
        ./configure --static --prefix="$DEPS"
    make -j"$JOBS"
    make install
    touch "$marker"
}

build_openssl() {
    local marker="$DEPS/.openssl.ok"
    [[ -f "$marker" ]] && { log "OpenSSL already built"; return 0; }
    mkdir -p "$SRC_DEPS"
    cd "$SRC_DEPS"
    download "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" "openssl-${OPENSSL_VER}.tar.gz" \
        || download "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" "openssl-${OPENSSL_VER}.tar.gz"
    rm -rf "openssl-${OPENSSL_VER}"
    tar xzf "openssl-${OPENSSL_VER}.tar.gz"
    cd "openssl-${OPENSSL_VER}"
    local conf="mingw64"
    [[ "$TARGET_ARCH" == "i686" ]] && conf="mingw"
    ./Configure "$conf" no-shared no-tests no-module \
        --cross-compile-prefix="${TARGET}-" \
        --prefix="$DEPS" --openssldir="$DEPS/ssl"
    make -j"$JOBS"
    make install_sw
    touch "$marker"
}

build_bdb() {
    local marker="$DEPS/.bdb.ok"
    [[ -f "$marker" ]] && { log "Berkeley DB already built"; return 0; }
    mkdir -p "$SRC_DEPS"
    cd "$SRC_DEPS"
    local tarball="db-${BDB_VER}.NC.tar.gz"
    if [[ ! -f "$tarball" ]]; then
        download "https://download.oracle.com/berkeley-db/${tarball}" "$tarball" \
            || download "http://download.oracle.com/berkeley-db/${tarball}" "$tarball" \
            || download "https://github.com/bitcoin/bitcoin/raw/v0.8.6/${tarball}" "$tarball" \
            || die "Could not download Berkeley DB ${BDB_VER}.NC — place ${tarball} in $SRC_DEPS and re-run"
    fi
    rm -rf "db-${BDB_VER}.NC"
    tar xzf "$tarball"
    cd "db-${BDB_VER}.NC"
    # Atomic typedef patch for modern mingw / GCC
    if [[ -f src/dbinc/atomic.h ]]; then
        sed -i 's/__atomic_compare_exchange/__atomic_compare_exchange_db/g' src/dbinc/atomic.h || true
        sed -i 's/atomic_init/atomic_init_db/g' src/dbinc/atomic.h src/mp/mp_mvcc.c src/mp/mp_fget.c src/mutex/mut_method.c src/mutex/mut_tas.c 2>/dev/null || true
    fi
    cd build_unix
    ../dist/configure \
        --disable-replication --enable-mingw --enable-cxx \
        --disable-shared --enable-static \
        --host="$TARGET" --prefix="$DEPS" \
        CC="${TARGET}-gcc" CXX="${TARGET}-g++" \
        RANLIB="${TARGET}-ranlib" AR="${TARGET}-ar" \
        CFLAGS="-D_GNU_SOURCE" CXXFLAGS="-std=c++17"
    make -j"$JOBS" libdb_cxx.a libdb.a
    # install headers + libs manually if make install fails on docs
    make install_lib install_include || {
        mkdir -p "$DEPS/lib" "$DEPS/include"
        cp .libs/libdb*.a "$DEPS/lib/" 2>/dev/null || cp libdb*.a "$DEPS/lib/"
        cp ../src/db.h ../src/db_cxx.h "$DEPS/include/"
        cp -a ../src/dbinc "$DEPS/include/" 2>/dev/null || true
    }
    # Ensure libdb_cxx.a is present
    if [[ ! -f "$DEPS/lib/libdb_cxx.a" ]]; then
        find . -name 'libdb_cxx*.a' -exec cp {} "$DEPS/lib/libdb_cxx.a" \;
        find . -name 'libdb-*.a' -o -name 'libdb.a' | head -1 | while read -r f; do cp "$f" "$DEPS/lib/libdb.a"; done
    fi
    touch "$marker"
}

build_boost() {
    local marker="$DEPS/.boost.ok"
    [[ -f "$marker" ]] && { log "Boost already built"; return 0; }
    mkdir -p "$SRC_DEPS"
    cd "$SRC_DEPS"
    local tb="boost_${BOOST_VER_U}.tar.bz2"
    download "https://archives.boost.io/release/${BOOST_VER}/source/${tb}" "$tb" \
        || download "https://sourceforge.net/projects/boost/files/boost/${BOOST_VER}/${tb}/download" "$tb"
    rm -rf "boost_${BOOST_VER_U}"
    tar xjf "$tb"
    cd "boost_${BOOST_VER_U}"
    ./bootstrap.sh
    cat > user-config.jam <<EOF
using gcc : mingw : ${TARGET}-g++ :
    <rc>${TARGET}-windres
    <archiver>${TARGET}-ar
    <ranlib>${TARGET}-ranlib
;
EOF
    local addr=64
    [[ "$TARGET_ARCH" == "i686" ]] && addr=32
    ./b2 -q --ignore-site-config --user-config=user-config.jam \
        toolset=gcc-mingw target-os=windows \
        threadapi=win32 threading=multi \
        variant=release link=static runtime-link=static \
        address-model="$addr" --layout=tagged \
        --prefix="$DEPS" \
        --with-system --with-filesystem --with-program_options \
        --with-thread --with-chrono \
        -j"$JOBS" \
        install
    touch "$marker"
}

build_miniupnpc() {
    local marker="$DEPS/.miniupnpc.ok"
    [[ -f "$marker" ]] && { log "miniupnpc already built"; return 0; }
    mkdir -p "$SRC_DEPS"
    cd "$SRC_DEPS"
    download "https://miniupnp.tuxfamily.org/files/miniupnpc-${MINIUPNPC_VER}.tar.gz" "miniupnpc-${MINIUPNPC_VER}.tar.gz" \
        || download "https://github.com/miniupnp/miniupnp/archive/refs/tags/miniupnpc_${MINIUPNPC_VER//./_}.tar.gz" "miniupnpc-${MINIUPNPC_VER}.tar.gz"
    rm -rf "miniupnpc-${MINIUPNPC_VER}"
    tar xzf "miniupnpc-${MINIUPNPC_VER}.tar.gz"
    # tarball layout may be miniupnpc-VER or miniupnp-.../miniupnpc
    local dir
    dir="$(find . -maxdepth 2 -type d -name 'miniupnpc*' | head -1)"
    [[ -n "$dir" ]] || dir="$(find . -maxdepth 3 -type d -name 'miniupnpc' | head -1)"
    cd "$dir"
    make clean 2>/dev/null || true
    if [[ -f Makefile.mingw ]]; then
        make -f Makefile.mingw CC="${TARGET}-gcc" AR="${TARGET}-ar" libminiupnpc.a || \
        make -f Makefile.mingw CC="${TARGET}-gcc" LIB="${TARGET}-ar"
    else
        make CC="${TARGET}-gcc" AR="${TARGET}-ar" libminiupnpc.a OS=Windows_NT || true
    fi
    mkdir -p "$DEPS/include/miniupnpc" "$DEPS/lib"
    find . -name 'libminiupnpc.a' -exec cp {} "$DEPS/lib/" \;
    find . -path '*/miniupnpc/*.h' -exec cp {} "$DEPS/include/miniupnpc/" \;
    cp *.h "$DEPS/include/miniupnpc/" 2>/dev/null || true
    touch "$marker"
}

check_deps_links() {
    log "Verifying dependency headers and libraries under $DEPS"
    verify_file "$DEPS/include/openssl/ssl.h" "OpenSSL headers"
    verify_file "$DEPS/lib/libssl.a" "OpenSSL libssl"
    verify_file "$DEPS/lib/libcrypto.a" "OpenSSL libcrypto"
    verify_file "$DEPS/include/db_cxx.h" "Berkeley DB C++ header"
    # libdb_cxx may be versioned
    if [[ ! -f "$DEPS/lib/libdb_cxx.a" ]]; then
        local f
        f="$(find "$DEPS/lib" -name 'libdb_cxx*.a' | head -1 || true)"
        [[ -n "$f" ]] || die "Berkeley DB libdb_cxx.a not found"
        ln -sf "$(basename "$f")" "$DEPS/lib/libdb_cxx.a"
    fi
    verify_file "$DEPS/lib/libz.a" "zlib"
    local boost_sys
    boost_sys="$(find "$DEPS/lib" -name 'libboost_system*.a' | head -1 || true)"
    [[ -n "$boost_sys" ]] || die "Boost system library not found in $DEPS/lib"
    log "Found Boost: $(basename "$boost_sys")"
    # Detect BOOST_LIB_SUFFIX from filename: libboost_system-mt-x64.a -> -mt-x64
    local base
    base="$(basename "$boost_sys" .a)"
    export BOOST_LIB_SUFFIX="${base#libboost_system}"
    log "Using BOOST_LIB_SUFFIX=${BOOST_LIB_SUFFIX}"
}

build_cli() {
    log "Building Windows CLI (RNRCd.exe)"
    cd "$ROOT/src"
    # Clean previous native leveldb objects that would break mingw link
    make -f makefile.linux-mingw clean || true
    rm -f leveldb/libleveldb.a leveldb/libmemenv.a
    make -C leveldb clean || true
    make -f makefile.linux-mingw -j"$JOBS" \
        TARGET_PLATFORM="$TARGET_ARCH" \
        DEPSDIR="$DEPS" \
        BOOST_LIB_SUFFIX="$BOOST_LIB_SUFFIX" \
        USE_UPNP="$USE_UPNP"
    verify_file "$ROOT/src/RNRCd.exe" "CLI build failed"
    mkdir -p "$RELEASE_DIR"
    cp -f "$ROOT/src/RNRCd.exe" "$RELEASE_DIR/"
    "${TARGET}-strip" "$RELEASE_DIR/RNRCd.exe" 2>/dev/null || true
    file "$RELEASE_DIR/RNRCd.exe" || true
}

find_mingw_qmake() {
    if [[ -n "${QT_MINGW_QMAKE:-}" && -x "${QT_MINGW_QMAKE}" ]]; then
        echo "$QT_MINGW_QMAKE"
        return 0
    fi
    local c
    for c in \
        "${MXE_PREFIX:-/usr/lib/mxe}/usr/${TARGET}/qt5/bin/qmake" \
        "$DEPS/qt/bin/qmake" \
        "$HOME/mxe/usr/${TARGET}/qt5/bin/qmake"
    do
        if [[ -x "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

build_gui() {
    if [[ "$BUILD_GUI" != "1" ]]; then
        log "Skipping GUI (BUILD_GUI=$BUILD_GUI)"
        return 0
    fi
    local qmake_bin
    if ! qmake_bin="$(find_mingw_qmake)"; then
        warn "No mingw Qt qmake found — CLI was built; GUI skipped."
        warn "Install MXE Qt5 for ${TARGET}, or set QT_MINGW_QMAKE=/path/to/qmake and re-run."
        warn "See doc/build-windows.txt section 8."
        return 0
    fi
    log "Building Windows GUI with $qmake_bin"
    cd "$ROOT"
    # Out-of-tree build dir for Windows GUI
    local bdir="$ROOT/build-win-qt"
    rm -rf "$bdir"
    mkdir -p "$bdir"
    cd "$bdir"
    "$qmake_bin" -spec win32-g++ \
        "USE_UPNP=-" "USE_QRCODE=0" "RELEASE=1" \
        "BOOST_LIB_SUFFIX=${BOOST_LIB_SUFFIX}" \
        "BOOST_INCLUDE_PATH=${DEPS}/include" \
        "BOOST_LIB_PATH=${DEPS}/lib" \
        "BDB_INCLUDE_PATH=${DEPS}/include" \
        "BDB_LIB_PATH=${DEPS}/lib" \
        "OPENSSL_INCLUDE_PATH=${DEPS}/include" \
        "OPENSSL_LIB_PATH=${DEPS}/lib" \
        "QMAKE_CC=${TARGET}-gcc" \
        "QMAKE_CXX=${TARGET}-g++" \
        "QMAKE_LINK=${TARGET}-g++" \
        "QMAKE_LIB=${TARGET}-ar" \
        "QMAKE_RANLIB=${TARGET}-ranlib" \
        "$ROOT/RNRC-qt.pro"
    make -j"$JOBS"
    local exe
    exe="$(find "$bdir" "$ROOT" -maxdepth 3 -name 'RNRC-qt.exe' | head -1 || true)"
    [[ -n "$exe" ]] || die "RNRC-qt.exe not produced"
    mkdir -p "$RELEASE_DIR"
    cp -f "$exe" "$RELEASE_DIR/"
    "${TARGET}-strip" "$RELEASE_DIR/RNRC-qt.exe" 2>/dev/null || true
    file "$RELEASE_DIR/RNRC-qt.exe" || true
}

main() {
    check_ubuntu

    local mingw_pkg_arch="$TARGET_ARCH"
    # Debian/Ubuntu package names use x86-64 (hyphen), not x86_64
    [[ "$TARGET_ARCH" == "x86_64" ]] && mingw_pkg_arch="x86-64"

    local pkgs=(
        build-essential curl wget git ca-certificates
        autoconf automake libtool pkg-config cmake unzip zip
        python3
        mingw-w64
        "g++-mingw-w64-${mingw_pkg_arch}"
        "gcc-mingw-w64-${mingw_pkg_arch}"
    )
    if need_cmd apt-get; then
        apt_install "${pkgs[@]}"
    else
        warn "apt-get not found; ensure mingw-w64 toolchain is installed."
    fi

    setup_mingw_posix
    mkdir -p "$DEPS"/{include,lib,src} "$RELEASE_DIR"

    build_zlib
    build_openssl
    build_bdb
    build_boost
    if [[ "$USE_UPNP" != "-" && "$USE_UPNP" != "0" ]]; then
        build_miniupnpc
    else
        # Still build miniupnpc so optional later use works
        build_miniupnpc || warn "miniupnpc build failed (optional)"
    fi

    check_deps_links
    build_cli
    build_gui

    log "Done. Artifacts:"
    ls -la "$RELEASE_DIR"
}

main "$@"
