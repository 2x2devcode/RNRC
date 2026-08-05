#!/usr/bin/env bash
# compile-windows.sh — Cross-compile RNRC Windows CLI + GUI from Ubuntu 22.04
# Installs host + Qt (mingw) dependencies, then builds BOTH:
#   release/windows/RNRCd.exe
#   release/windows/RNRC-qt.exe
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
USE_UPNP="${USE_UPNP:--}"
MXE_PREFIX="${MXE_PREFIX:-/usr/lib/mxe}"
QT_VER="${QT_VER:-5.15.2}"

OPENSSL_VER="${OPENSSL_VER:-3.0.13}"
BOOST_VER="${BOOST_VER:-1.82.0}"
BOOST_VER_U="${BOOST_VER//./_}"
BDB_VER="4.8.30"
MINIUPNPC_VER="${MINIUPNPC_VER:-2.2.6}"
ZLIB_VER="${ZLIB_VER:-1.3.1}"

# MXE target triple used by apt packages / qmake wrappers
if [[ "$TARGET_ARCH" == "x86_64" ]]; then
    MXE_TARGET="x86_64-w64-mingw32.static"
    MXE_APT_ARCH="x86-64"
else
    MXE_TARGET="i686-w64-mingw32.static"
    MXE_APT_ARCH="i686"
fi

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
            warn "Non-Ubuntu host; package names may differ."
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
        log "Required apt packages already present (${#pkgs[@]} checked)."
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

install_host_packages() {
    local mingw_pkg_arch="$TARGET_ARCH"
    [[ "$TARGET_ARCH" == "x86_64" ]] && mingw_pkg_arch="x86-64"

    local pkgs=(
        # CLI + general build
        build-essential curl wget git ca-certificates
        autoconf automake libtool pkg-config cmake unzip zip
        python3 python3-pip
        mingw-w64
        "g++-mingw-w64-${mingw_pkg_arch}"
        "gcc-mingw-w64-${mingw_pkg_arch}"
        # GUI / Qt cross-build host tools
        gperf bison flex
        libgl1-mesa-dev libglu1-mesa-dev
        libfontconfig1-dev libfreetype6-dev
        libx11-dev libxext-dev libxfixes-dev libxi-dev libxrender-dev
        libxcb1-dev libxkbcommon-dev libxkbcommon-x11-dev
        software-properties-common lsb-release gnupg apt-transport-https
    )
    if need_cmd apt-get; then
        apt_install "${pkgs[@]}"
    else
        die "apt-get not found; this script targets Ubuntu 22.04."
    fi
}

# ---------- dependency builds (CLI) ----------

build_zlib() {
    local marker="$DEPS/.zlib.ok"
    [[ -f "$marker" ]] && { log "zlib already built"; return 0; }
    mkdir -p "$SRC_DEPS"
    cd "$SRC_DEPS"
    download "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" "zlib-${ZLIB_VER}.tar.gz" \
        || download "https://zlib.net/zlib-${ZLIB_VER}.tar.gz" "zlib-${ZLIB_VER}.tar.gz"
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
        --prefix="$DEPS" --libdir=lib --openssldir="$DEPS/ssl"
    make -j"$JOBS"
    make install_sw
    if [[ -f "$DEPS/lib64/libssl.a" && ! -f "$DEPS/lib/libssl.a" ]]; then
        mkdir -p "$DEPS/lib"
        cp -a "$DEPS/lib64/"*.a "$DEPS/lib/" 2>/dev/null || true
    fi
    verify_file "$DEPS/lib/libssl.a" "OpenSSL install did not produce libssl.a"
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
    make install_lib install_include || {
        mkdir -p "$DEPS/lib" "$DEPS/include"
        cp .libs/libdb*.a "$DEPS/lib/" 2>/dev/null || cp libdb*.a "$DEPS/lib/"
        cp ../src/db.h ../src/db_cxx.h "$DEPS/include/"
        cp -a ../src/dbinc "$DEPS/include/" 2>/dev/null || true
    }
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
    if [[ -d include ]]; then
        cp -a include/*.h "$DEPS/include/miniupnpc/" 2>/dev/null || true
        cp -a include/miniupnpc/*.h "$DEPS/include/miniupnpc/" 2>/dev/null || true
    fi
    find . -path '*/miniupnpc/*.h' -exec cp {} "$DEPS/include/miniupnpc/" \;
    cp *.h "$DEPS/include/miniupnpc/" 2>/dev/null || true
    verify_file "$DEPS/include/miniupnpc/miniupnpc.h" "miniupnpc headers"
    touch "$marker"
}

check_deps_links() {
    log "Verifying dependency headers and libraries under $DEPS"
    if [[ -f "$DEPS/lib64/libssl.a" && ! -f "$DEPS/lib/libssl.a" ]]; then
        mkdir -p "$DEPS/lib"
        cp -a "$DEPS/lib64/"*.a "$DEPS/lib/" 2>/dev/null || true
    fi
    verify_file "$DEPS/include/openssl/ssl.h" "OpenSSL headers"
    verify_file "$DEPS/lib/libssl.a" "OpenSSL libssl"
    verify_file "$DEPS/lib/libcrypto.a" "OpenSSL libcrypto"
    verify_file "$DEPS/include/db_cxx.h" "Berkeley DB C++ header"
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
    local base
    base="$(basename "$boost_sys" .a)"
    export BOOST_LIB_SUFFIX="${base#libboost_system}"
    log "Using BOOST_LIB_SUFFIX=${BOOST_LIB_SUFFIX}"
    if [[ -f "$DEPS/lib/libboost_thread_win32${BOOST_LIB_SUFFIX}.a" ]]; then
        export BOOST_THREAD_LIB=boost_thread_win32
        export BOOST_THREAD_LIB_SUFFIX="_win32${BOOST_LIB_SUFFIX}"
    elif [[ -f "$DEPS/lib/libboost_thread${BOOST_LIB_SUFFIX}.a" ]]; then
        export BOOST_THREAD_LIB=boost_thread
        export BOOST_THREAD_LIB_SUFFIX="${BOOST_LIB_SUFFIX}"
    else
        die "Boost thread library not found (suffix ${BOOST_LIB_SUFFIX})"
    fi
    log "Using BOOST_THREAD_LIB=${BOOST_THREAD_LIB} BOOST_THREAD_LIB_SUFFIX=${BOOST_THREAD_LIB_SUFFIX}"
}

# ---------- Qt for Windows GUI ----------

setup_mxe_apt() {
    if ! need_cmd apt-get; then
        return 1
    fi
    # shellcheck source=/dev/null
    . /etc/os-release
    local codename="${VERSION_CODENAME:-jammy}"
    # MXE may not publish every Ubuntu codename; fall back to jammy/focal
    if ! curl -fsI "https://pkg.mxe.cc/repos/apt/dists/${codename}/" >/dev/null 2>&1; then
        if curl -fsI "https://pkg.mxe.cc/repos/apt/dists/jammy/" >/dev/null 2>&1; then
            codename=jammy
        else
            codename=focal
        fi
        warn "MXE apt dist for this Ubuntu not found; using '${codename}'."
    fi

    log "Configuring MXE apt repository (dist=${codename})"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        software-properties-common lsb-release gnupg apt-transport-https ca-certificates >/dev/null

    local keyring=/usr/share/keyrings/mxe-archive-keyring.gpg
    if [[ ! -s "$keyring" ]]; then
        log "Importing MXE apt signing key"
        local tmpasc
        tmpasc="$(mktemp)"
        # Key 86B72ED9 (Tony Theodore) — also covers subkey C6BF758A33A3A276
        curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x86B72ED9" -o "$tmpasc" \
            || curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0xC6BF758A33A3A276" -o "$tmpasc" \
            || die "Could not download MXE GPG key"
        sudo gpg --batch --yes --dearmor -o "$keyring" < "$tmpasc"
        rm -f "$tmpasc"
    fi
    [[ -s "$keyring" ]] || die "MXE keyring not created"

    echo "deb [arch=amd64 signed-by=${keyring}] https://pkg.mxe.cc/repos/apt ${codename} main" \
        | sudo tee /etc/apt/sources.list.d/mxeapt.list >/dev/null

    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq || {
        warn "MXE apt update failed"
        return 1
    }
    return 0
}

install_mxe_qt() {
    log "Installing MXE Qt5 packages for GUI cross-compile (${MXE_TARGET})"
    setup_mxe_apt || return 1

    # Prefer full qt5 meta, then qtbase + qttools
    local pkgs_try=(
        "mxe-${MXE_APT_ARCH}-w64-mingw32.static-qt5"
        "mxe-${MXE_APT_ARCH}-w64-mingw32.static-qtbase"
    )
    local tools_pkg="mxe-${MXE_APT_ARCH}-w64-mingw32.static-qttools"
    local installed=0
    local pkg
    for pkg in "${pkgs_try[@]}"; do
        log "Trying apt package: $pkg"
        if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"; then
            installed=1
            break
        fi
    done
    if [[ "$installed" -ne 1 ]]; then
        warn "Could not install MXE Qt packages via apt"
        return 1
    fi
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "$tools_pkg" 2>/dev/null || true

    # Sanity-check qmake wrapper
    if [[ -x "${MXE_PREFIX}/usr/bin/${MXE_TARGET}-qmake-qt5" ]]; then
        log "MXE qmake: ${MXE_PREFIX}/usr/bin/${MXE_TARGET}-qmake-qt5"
        return 0
    fi
    if [[ -x "${MXE_PREFIX}/usr/${MXE_TARGET}/qt5/bin/qmake" ]]; then
        log "MXE qmake: ${MXE_PREFIX}/usr/${MXE_TARGET}/qt5/bin/qmake"
        return 0
    fi
    warn "MXE Qt packages installed but qmake not found under ${MXE_PREFIX}"
    return 1
}

build_qt_from_source() {
    local marker="$DEPS/.qt.ok"
    [[ -f "$marker" && -x "$DEPS/qt/bin/qmake" ]] && {
        log "Qt already built at $DEPS/qt"
        return 0
    }

    log "Building Qt ${QT_VER} (qtbase) for ${TARGET} — this can take a long time"
    mkdir -p "$SRC_DEPS"
    cd "$SRC_DEPS"

    local qt_tb="qtbase-everywhere-src-${QT_VER}.tar.xz"
    download "https://download.qt.io/archive/qt/5.15/${QT_VER}/submodules/${qt_tb}" "$qt_tb" \
        || download "https://download.qt.io/official_releases/qt/5.15/${QT_VER}/submodules/${qt_tb}" "$qt_tb" \
        || download "https://ftp.fau.de/qtproject/archive/qt/5.15/${QT_VER}/submodules/${qt_tb}" "$qt_tb"

    rm -rf "qtbase-everywhere-src-${QT_VER}" "qt-build"
    tar xf "$qt_tb"
    mkdir -p qt-build
    cd qt-build

    # Minimal static Qt for wallet GUI (widgets + network)
    "../qtbase-everywhere-src-${QT_VER}/configure" \
        -prefix "$DEPS/qt" \
        -release -static -opensource -confirm-license \
        -xplatform win32-g++ \
        -device-option "CROSS_COMPILE=${TARGET}-" \
        -nomake examples -nomake tests \
        -no-opengl -no-cups -no-pch \
        -no-feature-sql -no-feature-testlib \
        -qt-zlib -qt-libpng -qt-libjpeg -qt-freetype -qt-pcre -qt-harfbuzz \
        -skip qt3d -skip qtactiveqt -skip qtandroidextras -skip qtcanvas3d \
        -openssl-linked OPENSSL_PREFIX="$DEPS" \
        -I "$DEPS/include" -L "$DEPS/lib" \
        -verbose

    make -j"$JOBS"
    make install

    # Host lrelease: prefer system qttools if available
    if ! [[ -x "$DEPS/qt/bin/lrelease" ]]; then
        if need_cmd lrelease; then
            ln -sfn "$(command -v lrelease)" "$DEPS/qt/bin/lrelease" || true
        elif need_cmd lrelease-qt5; then
            ln -sfn "$(command -v lrelease-qt5)" "$DEPS/qt/bin/lrelease" || true
        fi
    fi

    verify_file "$DEPS/qt/bin/qmake" "Qt qmake not installed"
    touch "$marker"
}

find_mingw_qmake() {
    if [[ -n "${QT_MINGW_QMAKE:-}" && -x "${QT_MINGW_QMAKE}" ]]; then
        echo "$QT_MINGW_QMAKE"
        return 0
    fi
    local c
    for c in \
        "${MXE_PREFIX}/usr/bin/${MXE_TARGET}-qmake-qt5" \
        "${MXE_PREFIX}/usr/${MXE_TARGET}/qt5/bin/qmake" \
        "$DEPS/qt/bin/qmake" \
        "$HOME/mxe/usr/bin/${MXE_TARGET}-qmake-qt5" \
        "$HOME/mxe/usr/${MXE_TARGET}/qt5/bin/qmake"
    do
        if [[ -x "$c" ]]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

ensure_qt() {
    if [[ "$BUILD_GUI" != "1" ]]; then
        return 0
    fi
    if find_mingw_qmake >/dev/null; then
        log "Found mingw Qt qmake: $(find_mingw_qmake)"
        return 0
    fi
    log "Qt for mingw not found — installing GUI dependencies"
    if install_mxe_qt && find_mingw_qmake >/dev/null; then
        log "MXE Qt ready: $(find_mingw_qmake)"
        return 0
    fi
    warn "MXE Qt install unavailable; building qtbase from source"
    build_qt_from_source
    find_mingw_qmake >/dev/null || die "Failed to provision Qt for Windows GUI"
}

# ---------- builds ----------

build_cli() {
    log "Building Windows CLI (RNRCd.exe)"
    cd "$ROOT/src"
    make -f makefile.linux-mingw clean || true
    rm -f leveldb/libleveldb.a leveldb/libmemenv.a
    make -C leveldb clean || true
    make -f makefile.linux-mingw -j"$JOBS" \
        TARGET_PLATFORM="$TARGET_ARCH" \
        DEPSDIR="$DEPS" \
        BOOST_LIB_SUFFIX="$BOOST_LIB_SUFFIX" \
        BOOST_THREAD_LIB="$BOOST_THREAD_LIB" \
        USE_UPNP="$USE_UPNP"
    verify_file "$ROOT/src/RNRCd.exe" "CLI build failed"
    mkdir -p "$RELEASE_DIR"
    cp -f "$ROOT/src/RNRCd.exe" "$RELEASE_DIR/"
    "${TARGET}-strip" "$RELEASE_DIR/RNRCd.exe" 2>/dev/null || true
    file "$RELEASE_DIR/RNRCd.exe" || true
}

build_gui() {
    if [[ "$BUILD_GUI" != "1" ]]; then
        log "Skipping GUI (BUILD_GUI=$BUILD_GUI)"
        return 0
    fi

    local qmake_bin
    qmake_bin="$(find_mingw_qmake)" || die "mingw Qt qmake missing after ensure_qt"

    log "Building Windows GUI (RNRC-qt.exe) with $qmake_bin"
    # Ensure MXE tools are on PATH when using MXE qmake
    if [[ "$qmake_bin" == *"/mxe/"* ]]; then
        export PATH="${MXE_PREFIX}/usr/bin:${PATH}"
    fi

    cd "$ROOT"
    local bdir="$ROOT/build-win-qt"
    rm -rf "$bdir"
    mkdir -p "$bdir"
    cd "$bdir"

    # Clean native leveldb so qmake rebuilds for Windows
    rm -f "$ROOT/src/leveldb/libleveldb.a" "$ROOT/src/leveldb/libmemenv.a"
    make -C "$ROOT/src/leveldb" clean >/dev/null 2>&1 || true

    local qmake_args=(
        "USE_UPNP=-"
        "USE_QRCODE=0"
        "USE_DBUS=0"
        "RELEASE=1"
        "MINGW_THREAD_BUGFIX=0"
        "BOOST_LIB_SUFFIX=${BOOST_LIB_SUFFIX}"
        "BOOST_THREAD_LIB_SUFFIX=${BOOST_THREAD_LIB_SUFFIX}"
        "BOOST_INCLUDE_PATH=${DEPS}/include"
        "BOOST_LIB_PATH=${DEPS}/lib"
        "BDB_INCLUDE_PATH=${DEPS}/include"
        "BDB_LIB_PATH=${DEPS}/lib"
        "OPENSSL_INCLUDE_PATH=${DEPS}/include"
        "OPENSSL_LIB_PATH=${DEPS}/lib"
    )

    # When using our own Qt (not MXE wrappers), force mingw compilers
    if [[ "$qmake_bin" == "$DEPS/qt/bin/qmake" ]]; then
        qmake_args+=(
            -spec win32-g++
            "QMAKE_CC=${TARGET}-gcc"
            "QMAKE_CXX=${TARGET}-g++"
            "QMAKE_LINK=${TARGET}-g++"
            "QMAKE_LIB=${TARGET}-ar"
            "QMAKE_RANLIB=${TARGET}-ranlib"
            "QMAKE_LRELEASE=$(command -v lrelease-qt5 || command -v lrelease || echo lrelease)"
        )
    fi

    "$qmake_bin" "${qmake_args[@]}" "$ROOT/RNRC-qt.pro"
    make -j"$JOBS"

    local exe
    exe="$(find "$bdir" -name 'RNRC-qt.exe' | head -1 || true)"
    [[ -n "$exe" ]] || exe="$(find "$ROOT" -maxdepth 3 -name 'RNRC-qt.exe' | head -1 || true)"
    [[ -n "$exe" ]] || die "RNRC-qt.exe not produced"
    mkdir -p "$RELEASE_DIR"
    cp -f "$exe" "$RELEASE_DIR/"
    if need_cmd "${TARGET}-strip"; then
        "${TARGET}-strip" "$RELEASE_DIR/RNRC-qt.exe" 2>/dev/null || true
    elif [[ -x "${MXE_PREFIX}/usr/bin/${MXE_TARGET}-strip" ]]; then
        "${MXE_PREFIX}/usr/bin/${MXE_TARGET}-strip" "$RELEASE_DIR/RNRC-qt.exe" 2>/dev/null || true
    fi
    file "$RELEASE_DIR/RNRC-qt.exe" || true
}

main() {
    check_ubuntu
    install_host_packages
    setup_mingw_posix
    mkdir -p "$DEPS"/{include,lib,src} "$RELEASE_DIR"

    # Shared crypto/db deps for CLI and GUI
    build_zlib
    build_openssl
    build_bdb
    build_boost
    build_miniupnpc || warn "miniupnpc build failed (optional when USE_UPNP=-)"

    check_deps_links

    # Provision Qt BEFORE builds so both targets are guaranteed when BUILD_GUI=1
    ensure_qt

    build_cli
    build_gui

    log "Done. Artifacts in ${RELEASE_DIR}:"
    ls -la "$RELEASE_DIR"
    verify_file "$RELEASE_DIR/RNRCd.exe" "CLI artifact missing"
    if [[ "$BUILD_GUI" == "1" ]]; then
        verify_file "$RELEASE_DIR/RNRC-qt.exe" "GUI artifact missing"
    fi
    log "Windows CLI + GUI build completed successfully."
}

main "$@"
