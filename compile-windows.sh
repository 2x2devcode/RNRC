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
LOG_DIR="${LOG_DIR:-$RELEASE_DIR/logs}"
BUILD_STAMP="${BUILD_STAMP:-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/compile-windows-${BUILD_STAMP}.log}"
ERRORS_FILE="${ERRORS_FILE:-$LOG_DIR/compile-windows-${BUILD_STAMP}.errors.txt}"
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

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log()  { printf '\n[%s] ==> %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(ts)" "$*" >&2; }
die()  {
    printf '[%s] ERROR: %s\n' "$(ts)" "$*" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '[%s] ERROR: %s\n' "$(ts)" "$*" >> "$LOG_FILE" 2>/dev/null || true
        printf '[%s] Full build log: %s\n' "$(ts)" "$LOG_FILE" >&2
        printf '[%s] Error extract:  %s\n' "$(ts)" "${ERRORS_FILE:-}" >&2
    fi
    exit 1
}

# Append a short "what failed" section to the log + errors file.
write_error_extract() {
    local src="${1:-$LOG_FILE}"
    local dest="${2:-$ERRORS_FILE}"
    [[ -f "$src" ]] || return 0
    mkdir -p "$(dirname "$dest")"
    {
        echo "=== RNRC Windows build — error extract ==="
        echo "Generated: $(date -Is)"
        echo "Source log: $src"
        echo
        echo "--- matching lines (error / undefined reference / make fail) ---"
        grep -nE \
            'error:|undefined reference|collect2:|fatal error:|^\[.*\] ERROR:|gmake: \*\*\*|make(\[[0-9]+\])?: \*\*\*|ERROR: Feature' \
            "$src" 2>/dev/null | tail -n 200 || echo "(no matching error lines found)"
        echo
        echo "--- last 80 lines of full log ---"
        tail -n 80 "$src" 2>/dev/null || true
    } > "$dest"
}

setup_logging() {
    mkdir -p "$LOG_DIR" "$RELEASE_DIR"
    : > "$LOG_FILE"
    ln -sfn "$(basename "$LOG_FILE")" "$LOG_DIR/compile-windows-latest.log"
    ln -sfn "$(basename "$ERRORS_FILE")" "$LOG_DIR/compile-windows-latest.errors.txt"
    {
        echo "================================================================"
        echo " RNRC compile-windows.sh"
        echo " Started:     $(date -Is)"
        echo " Log file:    $LOG_FILE"
        echo " Errors file: $ERRORS_FILE"
        echo " ROOT:        $ROOT"
        echo " TARGET:      $TARGET"
        echo " DEPS:        $DEPS"
        echo " JOBS:        $JOBS"
        echo " BUILD_GUI:   $BUILD_GUI"
        echo " Host:        $(uname -a 2>/dev/null || true)"
        if [[ -f /etc/os-release ]]; then
            # shellcheck source=/dev/null
            . /etc/os-release
            echo " OS:          ${PRETTY_NAME:-unknown}"
        fi
        echo "================================================================"
        echo
    } | tee -a "$LOG_FILE"
}

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

# Qt 5.15.2 (and some later 5.15.x) break on GCC 11+ because <limits> is no
# longer pulled in transitively. Without it, specializing std::numeric_limits
# yields: "'numeric_limits' is not a class template" in qfloat16.h / qendian.h.
qtbase_has_limits_patch() {
    local src="$1"
    local f="$src/src/corelib/global/qfloat16.h"
    [[ -f "$f" ]] && grep -qE '^[[:space:]]*#include[[:space:]]*<limits>' "$f"
}

patch_qtbase_for_gcc11() {
    local src="$1"
    local patch_file="$ROOT/patches/qtbase-5.15.2-gcc11-limits.diff"
    local f

    if qtbase_has_limits_patch "$src"; then
        log "Qt GCC 11+ <limits> patch already present in $src"
        return 0
    fi

    log "Applying GCC 11+ Qt patches (#include <limits>) under $src"

    if [[ -f "$patch_file" ]]; then
        # Prefer the checked-in unified diff (reliable across sed versions).
        if (cd "$src" && patch -p1 --forward --batch < "$patch_file"); then
            log "Applied $patch_file"
        else
            warn "patch(1) failed or already applied; falling back to sed"
        fi
    fi

    ensure_include_limits() {
        local file="$1"
        local after="${2:-}"
        [[ -f "$file" ]] || return 0
        if grep -qE '^[[:space:]]*#include[[:space:]]*<limits>' "$file"; then
            return 0
        fi
        if [[ -n "$after" ]] && grep -qF "$after" "$file"; then
            # Insert on the line after the first match of $after
            awk -v after="$after" '
                !done && index($0, after) { print; print "#include <limits>"; done=1; next }
                { print }
            ' "$file" > "${file}.rnrc.tmp" && mv "${file}.rnrc.tmp" "$file"
        elif grep -q '#include <QtCore/qmetatype.h>' "$file"; then
            sed -i '/#include <QtCore\/qmetatype.h>/a #include <limits>' "$file"
        elif grep -q '#include <QtCore/qglobal.h>' "$file"; then
            sed -i '/#include <QtCore\/qglobal.h>/a #include <limits>' "$file"
        elif grep -q '#include <array>' "$file"; then
            sed -i '/#include <array>/a #include <limits>' "$file"
        elif grep -q '#include <QtCore/qbytearray.h>' "$file"; then
            sed -i '/#include <QtCore\/qbytearray.h>/a #include <limits>' "$file"
        else
            sed -i '0,/#include /s//#include <limits>\n&/' "$file"
        fi
        grep -qE '^[[:space:]]*#include[[:space:]]*<limits>' "$file" \
            || die "Failed to patch $file with #include <limits>"
        log "  patched $(basename "$file")"
    }

    ensure_include_limits "$src/src/corelib/global/qfloat16.h" '#include <QtCore/qmetatype.h>'
    ensure_include_limits "$src/src/corelib/global/qendian.h" '#include <QtCore/qglobal.h>'
    ensure_include_limits "$src/src/corelib/text/qbytearraymatcher.h" '#include <QtCore/qbytearray.h>'
    ensure_include_limits "$src/src/corelib/tools/qoffsetstringarray_p.h" '#include <array>'

    qtbase_has_limits_patch "$src" \
        || die "qfloat16.h still missing #include <limits> after patch — aborting Qt build"
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
    # Drop any incomplete prior install so a failed GCC11 build cannot be reused
    rm -rf "$DEPS/qt" "$marker"
    tar xf "$qt_tb"
    patch_qtbase_for_gcc11 "$SRC_DEPS/qtbase-everywhere-src-${QT_VER}"
    mkdir -p qt-build
    cd qt-build

    # Minimal static Qt for wallet GUI (widgets + network).
    # On Windows use Schannel for Qt Network SSL — do NOT use -openssl-linked.
    # Wallet crypto still links OpenSSL separately via RNRC-qt.pro (-lssl -lcrypto).
    # OPENSSL_PREFIX alone fails Qt's libs.openssl test for static mingw + OpenSSL 3.
    local qt_ssl_args=()
    if [[ "${QT_USE_OPENSSL:-0}" == "1" ]]; then
        [[ -f "$DEPS/include/openssl/ssl.h" ]] || die "OpenSSL headers missing under $DEPS/include"
        [[ -f "$DEPS/lib/libssl.a" && -f "$DEPS/lib/libcrypto.a" ]] || die "OpenSSL static libs missing under $DEPS/lib"
        qt_ssl_args=(
            -openssl-linked
            "OPENSSL_INCDIR=$DEPS/include"
            "OPENSSL_LIBDIR=$DEPS/lib"
            "OPENSSL_LIBS=-lssl -lcrypto -lcrypt32 -lws2_32 -lgdi32 -luser32 -ladvapi32"
        )
        log "Configuring Qt with linked OpenSSL from $DEPS"
    else
        qt_ssl_args=(-schannel -no-openssl)
        log "Configuring Qt with Windows Schannel (set QT_USE_OPENSSL=1 to link OpenSSL into Qt)"
    fi

    local qt_log="$LOG_DIR/qt-${BUILD_STAMP}.log"
    ln -sfn "$(basename "$qt_log")" "$LOG_DIR/qt-latest.log"
    log "Qt stage log: $qt_log"

    set +e
    {
        "../qtbase-everywhere-src-${QT_VER}/configure" \
            -prefix "$DEPS/qt" \
            -release -static -opensource -confirm-license \
            -xplatform win32-g++ \
            -device-option "CROSS_COMPILE=${TARGET}-" \
            -nomake examples -nomake tests \
            -no-opengl -no-cups -no-pch -no-dbus -no-icu \
            -no-feature-sql -no-feature-testlib \
            -qt-zlib -qt-libpng -qt-libjpeg -qt-freetype -qt-pcre -qt-harfbuzz \
            "${qt_ssl_args[@]}" \
            -I "$DEPS/include" -L "$DEPS/lib" \
            -verbose
    } 2>&1 | tee "$qt_log"
    local conf_rc=${PIPESTATUS[0]}
    set -e
    if [[ "$conf_rc" -ne 0 ]]; then
        write_error_extract "$qt_log" "$ERRORS_FILE"
        die "Qt configure failed (exit $conf_rc) — see $qt_log and $LOG_FILE"
    fi

    # Fail early with a clear message if openssl was requested but not detected
    if [[ "${QT_USE_OPENSSL:-0}" == "1" && -f config.summary ]]; then
        if ! grep -E '[[:space:]]OpenSSL[[:space:].]+yes' config.summary >/dev/null; then
            warn "Qt config.summary SSL lines:"
            grep -E 'OpenSSL|Schannel' config.summary || true
            write_error_extract "$qt_log" "$ERRORS_FILE"
            die "Qt failed to detect OpenSSL (libs.openssl). Use QT_USE_OPENSSL=0 (Schannel) or fix DEPS OpenSSL."
        fi
    fi

    set +e
    make -j"$JOBS" 2>&1 | tee -a "$qt_log"
    local make_rc=${PIPESTATUS[0]}
    set -e
    if [[ "$make_rc" -ne 0 ]]; then
        write_error_extract "$qt_log" "$ERRORS_FILE"
        die "Qt make failed (exit $make_rc) — see $qt_log and $LOG_FILE"
    fi

    set +e
    make install 2>&1 | tee -a "$qt_log"
    local inst_rc=${PIPESTATUS[0]}
    set -e
    if [[ "$inst_rc" -ne 0 ]]; then
        write_error_extract "$qt_log" "$ERRORS_FILE"
        die "Qt make install failed (exit $inst_rc) — see $qt_log and $LOG_FILE"
    fi

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
    local stage_log="$LOG_DIR/cli-${BUILD_STAMP}.log"
    ln -sfn "$(basename "$stage_log")" "$LOG_DIR/cli-latest.log"
    log "CLI stage log: $stage_log"

    set +e
    (
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
    ) 2>&1 | tee "$stage_log"
    local rc=${PIPESTATUS[0]}
    set -e
    if [[ "$rc" -ne 0 ]]; then
        write_error_extract "$stage_log" "$ERRORS_FILE"
        die "CLI build failed (exit $rc) — see $stage_log and $LOG_FILE"
    fi

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

    local makelog="$LOG_DIR/gui-${BUILD_STAMP}.log"
    ln -sfn "$(basename "$makelog")" "$LOG_DIR/gui-latest.log"
    # Keep a copy next to the qmake build tree as well
    local bdir_log="$bdir/build.log"
    log "GUI stage log: $makelog"

    set +e
    make -j"$JOBS" 2>&1 | tee "$makelog" | tee "$bdir_log"
    local make_rc=${PIPESTATUS[0]}
    set -e
    if [[ "$make_rc" -ne 0 ]]; then
        warn "GUI make failed (exit $make_rc). Extracting errors..."
        write_error_extract "$makelog" "$ERRORS_FILE"
        # Also print a short summary to the console
        grep -nE 'error:|undefined reference|collect2:|fatal error:' "$makelog" | tail -n 80 >&2 || true
        die "Windows GUI build failed — see $makelog and $LOG_FILE"
    fi

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
    mkdir -p "$DEPS"/{include,lib,src} "$RELEASE_DIR" "$LOG_DIR"

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
    log "Full build log: $LOG_FILE"
    log "Latest symlink:  $LOG_DIR/compile-windows-latest.log"
}

# Entry point: capture the entire run in a timestamped log file.
run_with_log() {
    setup_logging
    local status_file
    status_file="$(mktemp)"
    set +e
    (
        # set -e inside the subshell so failures in main abort it
        set -euo pipefail
        main "$@"
        echo 0 > "$status_file"
    ) 2>&1 | tee -a "$LOG_FILE"
    # If main died via `exit` (die), the status file may be missing
    local rc
    if [[ -f "$status_file" ]]; then
        rc="$(cat "$status_file")"
    else
        rc=1
    fi
    rm -f "$status_file"
    set -e

    if [[ "$rc" -ne 0 ]]; then
        write_error_extract "$LOG_FILE" "$ERRORS_FILE"
        {
            echo
            echo "================================================================"
            echo " Build FAILED at $(date -Is) (exit $rc)"
            echo " Full log:      $LOG_FILE"
            echo " Error extract: $ERRORS_FILE"
            echo " Latest log:    $LOG_DIR/compile-windows-latest.log"
            echo " Latest errors: $LOG_DIR/compile-windows-latest.errors.txt"
            echo "================================================================"
        } | tee -a "$LOG_FILE"
        exit "$rc"
    fi

    {
        echo
        echo "================================================================"
        echo " Build SUCCEEDED at $(date -Is)"
        echo " Full log:   $LOG_FILE"
        echo " Latest log: $LOG_DIR/compile-windows-latest.log"
        echo "================================================================"
    } | tee -a "$LOG_FILE"
}

run_with_log "$@"
