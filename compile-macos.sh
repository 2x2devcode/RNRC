#!/usr/bin/env bash
# compile-macos.sh — Build RNRC macOS CLI + GUI on the local Mac
# Requires macOS + Xcode CLT + Homebrew. Produces:
#   release/macos/RNRCd
#   release/macos/RNRC-Qt.app
#
# Usage:
#   ./compile-macos.sh
#   BUILD_CLI=0 ./compile-macos.sh          # GUI only
#   BUILD_GUI=0 ./compile-macos.sh          # CLI only
#   USE_UPNP=- ./compile-macos.sh           # disable miniupnpc
#   MACOSX_DEPLOYMENT_TARGET=11.0 ./compile-macos.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

JOBS="${JOBS:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 2)}"
RELEASE_DIR="$ROOT/release/macos"
LOG_DIR="${LOG_DIR:-$RELEASE_DIR/logs}"
BUILD_STAMP="${BUILD_STAMP:-$(date +%Y%m%d-%H%M%S)}"
LOG_FILE="${LOG_FILE:-$LOG_DIR/compile-macos-${BUILD_STAMP}.log}"
ERRORS_FILE="${ERRORS_FILE:-$LOG_DIR/compile-macos-${BUILD_STAMP}.errors.txt}"
BUILD_GUI="${BUILD_GUI:-1}"
BUILD_CLI="${BUILD_CLI:-1}"
USE_UPNP="${USE_UPNP:--}"
USE_QRCODE="${USE_QRCODE:-0}"
DEPLOY_APP="${DEPLOY_APP:-1}"
MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-10.15}"

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

need_cmd() { command -v "$1" >/dev/null 2>&1; }

verify_file() {
    local f="$1" msg="${2:-missing file: $1}"
    [[ -e "$f" ]] || die "$msg"
}

write_error_extract() {
    local src="${1:-$LOG_FILE}"
    local dest="${2:-$ERRORS_FILE}"
    [[ -f "$src" ]] || return 0
    mkdir -p "$(dirname "$dest")"
    {
        echo "=== RNRC macOS build — error extract ==="
        echo "Generated: $(date -Is)"
        echo "Source log: $src"
        echo
        echo "--- matching lines (error / undefined / make fail) ---"
        grep -nE \
            'error:|undefined reference|ld:|fatal error:|cannot find -l|^\[.*\] ERROR:|make(\[[0-9]+\])?: \*\*\*' \
            "$src" 2>/dev/null | tail -n 200 || echo "(no matching error lines found)"
        echo
        echo "--- last 80 lines of full log ---"
        tail -n 80 "$src" 2>/dev/null || true
    } > "$dest"
}

setup_logging() {
    mkdir -p "$LOG_DIR" "$RELEASE_DIR"
    : > "$LOG_FILE"
    ln -sfn "$(basename "$LOG_FILE")" "$LOG_DIR/compile-macos-latest.log"
    ln -sfn "$(basename "$ERRORS_FILE")" "$LOG_DIR/compile-macos-latest.errors.txt"
    {
        echo "================================================================"
        echo " RNRC compile-macos.sh"
        echo " Started:     $(date -Is)"
        echo " Log file:    $LOG_FILE"
        echo " Errors file: $ERRORS_FILE"
        echo " ROOT:        $ROOT"
        echo " JOBS:        $JOBS"
        echo " BUILD_CLI:   $BUILD_CLI"
        echo " BUILD_GUI:   $BUILD_GUI"
        echo " USE_UPNP:    $USE_UPNP"
        echo " DEPLOY_APP:  $DEPLOY_APP"
        echo " Deploy tgt:  $MACOSX_DEPLOYMENT_TARGET"
        echo " Host:        $(uname -a 2>/dev/null || true)"
        echo " Arch:        $(uname -m 2>/dev/null || true)"
        echo "================================================================"
        echo
    } | tee -a "$LOG_FILE"
}

check_macos() {
    [[ "$(uname -s)" == "Darwin" ]] || die "This script must run on macOS (Darwin). For Windows use ./compile-windows.sh on Ubuntu."
    if ! xcode-select -p >/dev/null 2>&1; then
        die "Xcode Command Line Tools missing. Install with: xcode-select --install"
    fi
    log "macOS $(sw_vers -productVersion 2>/dev/null || echo '?') ($(uname -m))"
}

find_brew() {
    if [[ -n "${HOMEBREW_PREFIX:-}" && -x "${HOMEBREW_PREFIX}/bin/brew" ]]; then
        echo "${HOMEBREW_PREFIX}/bin/brew"
        return 0
    fi
    if [[ -x /opt/homebrew/bin/brew ]]; then
        echo /opt/homebrew/bin/brew
        return 0
    fi
    if [[ -x /usr/local/bin/brew ]]; then
        echo /usr/local/bin/brew
        return 0
    fi
    if need_cmd brew; then
        command -v brew
        return 0
    fi
    return 1
}

ensure_homebrew() {
    if BREW="$(find_brew)"; then
        export HOMEBREW_PREFIX="$("$BREW" --prefix)"
        export PATH="$HOMEBREW_PREFIX/bin:$PATH"
        log "Homebrew: $BREW (prefix=$HOMEBREW_PREFIX)"
        return 0
    fi
    die "Homebrew not found. Install from https://brew.sh then re-run."
}

brew_pkg_installed() {
    "$BREW" list --versions "$1" >/dev/null 2>&1
}

install_brew_deps() {
    local pkgs=(
        boost
        openssl@3
        berkeley-db@4
        qt@5
        pkg-config
    )
    if [[ "$USE_UPNP" != "-" ]]; then
        pkgs+=(miniupnpc)
    fi
    if [[ "$USE_QRCODE" == "1" ]]; then
        pkgs+=(qrencode)
    fi

    local missing=()
    local p
    for p in "${pkgs[@]}"; do
        if brew_pkg_installed "$p"; then
            log "brew package present: $p"
        else
            missing+=("$p")
        fi
    done
    if ((${#missing[@]})); then
        log "Installing Homebrew packages: ${missing[*]}"
        "$BREW" install "${missing[@]}"
    else
        log "All required Homebrew packages already installed."
    fi
}

brew_prefix() {
    "$BREW" --prefix "$1" 2>/dev/null
}

detect_boost_suffix() {
    local libdir="$1"
    if compgen -G "$libdir/libboost_system-mt.*" >/dev/null; then
        echo "-mt"
    elif compgen -G "$libdir/libboost_system.*" >/dev/null; then
        echo ""
    else
        die "Could not find libboost_system in $libdir"
    fi
}

detect_bdb_suffix() {
    local libdir="$1"
    if compgen -G "$libdir/libdb_cxx-4.8.*" >/dev/null; then
        echo "-4.8"
    elif compgen -G "$libdir/libdb_cxx.*" >/dev/null; then
        echo ""
    else
        die "Could not find libdb_cxx in $libdir (install berkeley-db@4)"
    fi
}

detect_bdb_include() {
    local prefix="$1"
    if [[ -d "$prefix/include/db48" ]]; then
        echo "$prefix/include/db48"
    elif [[ -f "$prefix/include/db_cxx.h" || -f "$prefix/include/db.h" ]]; then
        echo "$prefix/include"
    else
        die "Berkeley DB headers not found under $prefix/include"
    fi
}

resolve_paths() {
    OPENSSL_PREFIX="$(brew_prefix openssl@3)" || die "openssl@3 prefix missing"
    BOOST_PREFIX="$(brew_prefix boost)" || die "boost prefix missing"
    BDB_PREFIX="$(brew_prefix berkeley-db@4)" || die "berkeley-db@4 prefix missing"
    QT_PREFIX="$(brew_prefix qt@5)" || die "qt@5 prefix missing"

    OPENSSL_INCLUDE="$OPENSSL_PREFIX/include"
    OPENSSL_LIB="$OPENSSL_PREFIX/lib"
    BOOST_INCLUDE="$BOOST_PREFIX/include"
    BOOST_LIB="$BOOST_PREFIX/lib"
    BDB_INCLUDE="$(detect_bdb_include "$BDB_PREFIX")"
    BDB_LIB="$BDB_PREFIX/lib"
    BOOST_LIB_SUFFIX="$(detect_boost_suffix "$BOOST_LIB")"
    BDB_LIB_SUFFIX="$(detect_bdb_suffix "$BDB_LIB")"

    export PATH="$QT_PREFIX/bin:$PATH"
    need_cmd qmake || die "qmake not found (qt@5). PATH=$PATH"

    verify_file "$OPENSSL_INCLUDE/openssl/ssl.h" "OpenSSL headers"
    verify_file "$BOOST_INCLUDE/boost/version.hpp" "Boost headers"
    verify_file "$BDB_INCLUDE/db_cxx.h" "Berkeley DB C++ header (db_cxx.h)"

    log "OpenSSL:  $OPENSSL_PREFIX"
    log "Boost:    $BOOST_PREFIX (suffix='${BOOST_LIB_SUFFIX}')"
    log "BDB:      $BDB_PREFIX (include=$BDB_INCLUDE suffix='${BDB_LIB_SUFFIX}')"
    log "Qt5:      $QT_PREFIX (qmake=$(command -v qmake))"
    log "qmake:    $(qmake -query QT_VERSION 2>/dev/null || true)"
}

build_cli() {
    if [[ "$BUILD_CLI" != "1" ]]; then
        log "Skipping CLI (BUILD_CLI=$BUILD_CLI)"
        return 0
    fi

    log "Building macOS CLI (RNRCd) with makefile.osx"
    local stage_log="$LOG_DIR/cli-${BUILD_STAMP}.log"
    ln -sfn "$(basename "$stage_log")" "$LOG_DIR/cli-latest.log"

    local upnp_val="-"
    local extra_inc=()
    local extra_lib=()
    if [[ "$USE_UPNP" != "-" ]]; then
        local mini_prefix
        mini_prefix="$(brew_prefix miniupnpc)" || die "miniupnpc missing (brew install miniupnpc) or set USE_UPNP=-"
        upnp_val="$USE_UPNP"
        extra_inc+=(-I"${mini_prefix}/include")
        extra_lib+=(-L"${mini_prefix}/lib")
    fi

    set +e
    (
        cd "$ROOT/src"
        make -f makefile.osx clean || true
        rm -f leveldb/libleveldb.a leveldb/libmemenv.a
        make -C leveldb clean || true
        make -f makefile.osx -j"$JOBS" \
            RELEASE=1 \
            USE_UPNP="$upnp_val" \
            MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
            OPENSSL_INCLUDE_PATH="$OPENSSL_INCLUDE" \
            OPENSSL_LIB_PATH="$OPENSSL_LIB" \
            BOOST_INCLUDE_PATH="$BOOST_INCLUDE" \
            BOOST_LIB_PATH="$BOOST_LIB" \
            BOOST_LIB_SUFFIX="$BOOST_LIB_SUFFIX" \
            BDB_INCLUDE_PATH="$BDB_INCLUDE" \
            BDB_LIB_PATH="$BDB_LIB" \
            BDB_LIB_SUFFIX="$BDB_LIB_SUFFIX" \
            INCLUDEPATHS="-I${ROOT}/src -I${ROOT}/src/obj -I${OPENSSL_INCLUDE} -I${BDB_INCLUDE} -I${BOOST_INCLUDE} ${extra_inc[*]+${extra_inc[*]}}" \
            LIBPATHS="-L${OPENSSL_LIB} -L${BDB_LIB} -L${BOOST_LIB} ${extra_lib[*]+${extra_lib[*]}}"
    ) 2>&1 | tee "$stage_log"
    local rc=${PIPESTATUS[0]}
    set -e
    if [[ "$rc" -ne 0 ]]; then
        write_error_extract "$stage_log" "$ERRORS_FILE"
        die "macOS CLI build failed (exit $rc) — see $stage_log"
    fi

    verify_file "$ROOT/src/RNRCd" "CLI binary not produced (src/RNRCd)"
    mkdir -p "$RELEASE_DIR"
    cp -f "$ROOT/src/RNRCd" "$RELEASE_DIR/RNRCd"
    chmod +x "$RELEASE_DIR/RNRCd"
    strip "$RELEASE_DIR/RNRCd" 2>/dev/null || true
    file "$RELEASE_DIR/RNRCd" || true
    log "CLI artifact: $RELEASE_DIR/RNRCd"
}

build_gui() {
    if [[ "$BUILD_GUI" != "1" ]]; then
        log "Skipping GUI (BUILD_GUI=$BUILD_GUI)"
        return 0
    fi

    log "Building macOS GUI (RNRC-Qt.app)"
    local bdir="$ROOT/build-macos-qt"
    rm -rf "$bdir"
    mkdir -p "$bdir"
    cd "$bdir"

    # Clean native leveldb so qmake rebuilds for this tree
    rm -f "$ROOT/src/leveldb/libleveldb.a" "$ROOT/src/leveldb/libmemenv.a"
    make -C "$ROOT/src/leveldb" clean >/dev/null 2>&1 || true

    local host_lrelease
    host_lrelease="$(command -v lrelease || command -v lrelease-qt5 || true)"
    if [[ -z "$host_lrelease" && -x "$QT_PREFIX/bin/lrelease" ]]; then
        host_lrelease="$QT_PREFIX/bin/lrelease"
    fi
    [[ -n "$host_lrelease" ]] || die "lrelease missing (qt@5 tools)"
    log "Using lrelease: $host_lrelease"

    local qmake_args=(
        "RELEASE=1"
        "USE_UPNP=${USE_UPNP}"
        "USE_QRCODE=${USE_QRCODE}"
        "USE_DBUS=0"
        "BOOST_INCLUDE_PATH=${BOOST_INCLUDE}"
        "BOOST_LIB_PATH=${BOOST_LIB}"
        "BOOST_LIB_SUFFIX=${BOOST_LIB_SUFFIX}"
        "BOOST_THREAD_LIB_SUFFIX=${BOOST_LIB_SUFFIX}"
        "BDB_INCLUDE_PATH=${BDB_INCLUDE}"
        "BDB_LIB_PATH=${BDB_LIB}"
        "BDB_LIB_SUFFIX=${BDB_LIB_SUFFIX}"
        "OPENSSL_INCLUDE_PATH=${OPENSSL_INCLUDE}"
        "OPENSSL_LIB_PATH=${OPENSSL_LIB}"
        "QMAKE_MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET}"
        "QMAKE_CXXFLAGS+=-std=c++17"
        "QMAKE_LRELEASE=${host_lrelease}"
    )

    if [[ "$USE_QRCODE" == "1" ]]; then
        local qr_prefix
        qr_prefix="$(brew_prefix qrencode)" || die "qrencode missing"
        qmake_args+=(
            "QRENCODE_INCLUDE_PATH=${qr_prefix}/include"
            "QRENCODE_LIB_PATH=${qr_prefix}/lib"
        )
    fi

    log "Running qmake ${qmake_args[*]}"
    qmake "${qmake_args[@]}" "$ROOT/RNRC-qt.pro"

    local makelog="$LOG_DIR/gui-${BUILD_STAMP}.log"
    ln -sfn "$(basename "$makelog")" "$LOG_DIR/gui-latest.log"
    local bdir_log="$bdir/build.log"
    log "GUI stage log: $makelog"

    set +e
    make -j"$JOBS" 2>&1 | tee "$makelog" | tee "$bdir_log"
    local make_rc=${PIPESTATUS[0]}
    set -e
    if [[ "$make_rc" -ne 0 ]]; then
        write_error_extract "$makelog" "$ERRORS_FILE"
        grep -nE 'error:|undefined reference|ld:|fatal error:' "$makelog" | tail -n 80 >&2 || true
        die "macOS GUI build failed — see $makelog"
    fi

    local app=""
    app="$(find "$bdir" "$ROOT" -maxdepth 3 -name 'RNRC-Qt.app' -type d 2>/dev/null | head -1 || true)"
    [[ -n "$app" ]] || app="$(find "$bdir" "$ROOT" -maxdepth 3 -name 'RNRC-qt.app' -type d 2>/dev/null | head -1 || true)"
    [[ -n "$app" ]] || die "RNRC-Qt.app not produced"

    mkdir -p "$RELEASE_DIR"
    rm -rf "$RELEASE_DIR/RNRC-Qt.app"
    cp -R "$app" "$RELEASE_DIR/RNRC-Qt.app"

    if [[ "$DEPLOY_APP" == "1" ]]; then
        local macdeploy=""
        if need_cmd macdeployqt; then
            macdeploy="$(command -v macdeployqt)"
        elif [[ -x "$QT_PREFIX/bin/macdeployqt" ]]; then
            macdeploy="$QT_PREFIX/bin/macdeployqt"
        fi
        if [[ -n "$macdeploy" ]]; then
            log "Bundling Qt frameworks with macdeployqt"
            set +e
            "$macdeploy" "$RELEASE_DIR/RNRC-Qt.app" -always-overwrite 2>&1 | tee -a "$makelog"
            local dep_rc=${PIPESTATUS[0]}
            set -e
            if [[ "$dep_rc" -ne 0 ]]; then
                warn "macdeployqt failed (exit $dep_rc); .app left without bundled frameworks"
            fi
        else
            warn "macdeployqt not found; .app may need Qt frameworks on the target Mac"
        fi
    fi

    file "$RELEASE_DIR/RNRC-Qt.app/Contents/MacOS/"* 2>/dev/null || true
    log "GUI artifact: $RELEASE_DIR/RNRC-Qt.app"
}

main() {
    check_macos
    ensure_homebrew
    install_brew_deps
    resolve_paths
    mkdir -p "$RELEASE_DIR" "$LOG_DIR"

    build_cli
    build_gui

    log "Done. Artifacts in ${RELEASE_DIR}:"
    ls -la "$RELEASE_DIR"
    if [[ "$BUILD_CLI" == "1" ]]; then
        verify_file "$RELEASE_DIR/RNRCd" "CLI artifact missing"
    fi
    if [[ "$BUILD_GUI" == "1" ]]; then
        verify_file "$RELEASE_DIR/RNRC-Qt.app" "GUI artifact missing"
    fi
    log "macOS build completed successfully."
    log "Full build log: $LOG_FILE"
    log "Latest symlink:  $LOG_DIR/compile-macos-latest.log"
    echo
    echo "Notes:"
    echo "  - No Apple Developer account is required to build or run locally."
    echo "  - First launch may need: right-click RNRC-Qt.app → Open (Gatekeeper)."
    echo "  - Notarized distribution requires Apple Developer Program (\$99/year)."
}

run_with_log() {
    setup_logging
    local status_file
    status_file="$(mktemp)"
    set +e
    (
        set -euo pipefail
        main "$@"
        echo 0 > "$status_file"
    ) 2>&1 | tee -a "$LOG_FILE"
    local tee_rc=${PIPESTATUS[0]}
    set -e
    local main_rc=1
    if [[ -f "$status_file" ]]; then
        main_rc="$(cat "$status_file" 2>/dev/null || echo 1)"
    fi
    rm -f "$status_file"
    if [[ "$main_rc" != "0" || "$tee_rc" -ne 0 ]]; then
        write_error_extract "$LOG_FILE" "$ERRORS_FILE"
        exit 1
    fi
}

run_with_log "$@"
