#!/bin/bash
#
# Build nodejs (termux) for Android and pack it into the libnode.so /
# libnode.zip.so JNI layout used by YTDLnis.
#
# RUN THIS FROM THE ROOT OF A termux-packages CHECKOUT, INSIDE the docker
# container (start it with ./scripts/run-docker.sh, then run ./build_node.sh).
#
# Output:  ./output/jniLibs/<android-abi>/{libnode.so,libnode.zip.so}
#
# Phase 2 unpacks EVERY runtime .deb the build staged (nodejs + its whole
# dependency closure: libc++, openssl, c-ares, libicu, libsqlite, zlib, libffi,
# ...), excluding only "-static" dev packages -- so the bundle is self-contained.
#
set -euo pipefail
shopt -s nullglob

#
# USAGE (termux arch names):
#   ./build_node.sh                      # all four arches
#   ./build_node.sh aarch64              # one arch (one CI job)
#   SKIP_BUILD=1 ./build_node.sh aarch64 # skip Phase 1, just re-pack existing .debs
#
############################  CONFIG  ############################

ALL_ARCHES=("aarch64" "arm" "i686" "x86_64")
SKIP_BUILD="${SKIP_BUILD:-0}"

PKG="nodejs"         # termux package to build
BIN_NAME="node"      # produced executable at usr/bin/<BIN_NAME>
LIB_PREFIX="libnode" # -> libnode.so (binary) + libnode.zip.so (usr/ tree)

USE_ANDROID_ABI_NAMES=true
OUTPUT_BASE_DIR="${PWD}/output"
JNI_DIR="${OUTPUT_BASE_DIR}/jniLibs"
WORK="${OUTPUT_BASE_DIR}/_work"

#################################################################

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

in_list() { local x="$1"; shift; local e; for e in "$@"; do [ "$e" = "$x" ] && return 0; done; return 1; }

android_abi() {
    case "$1" in
        aarch64) echo "arm64-v8a" ;;
        arm)     echo "armeabi-v7a" ;;
        i686)    echo "x86" ;;
        x86_64)  echo "x86_64" ;;
        *)       echo "$1" ;;
    esac
}

check_prereqs() {
    [ -x ./build-package.sh ] || die "build-package.sh not found. Run this from the termux-packages root."
    for t in zip dpkg-deb; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found on PATH."
    done
}

########################  PHASE 0  ########################
check_prereqs
mkdir -p "$WORK" "$JNI_DIR"

if [ "$#" -gt 0 ]; then
    ARCHITECTURES=("$@")
    for a in "${ARCHITECTURES[@]}"; do
        in_list "$a" "${ALL_ARCHES[@]}" || die "unknown arch '$a' (valid: ${ALL_ARCHES[*]})"
    done
else
    ARCHITECTURES=("${ALL_ARCHES[@]}")
fi
log "Target arches: ${ARCHITECTURES[*]}   (SKIP_BUILD=${SKIP_BUILD})"

########################  PHASE 1 - build per arch  ########################
if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1 -> skipping Phase 1, reusing existing .debs in output/<arch>/"
fi
for ARCH in "${ARCHITECTURES[@]}"; do
    if [ "$SKIP_BUILD" = "1" ]; then continue; fi
    log "Building $PKG for: $ARCH"
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "$PKG" \
        || die "build failed for $ARCH"

    find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \
        \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) \
        -exec mv -t "$OUTPUT_DIR/" {} + 2>/dev/null || true

    info "done: $ARCH"
done

########################  PHASE 2 - merge into JNI zip per arch  ########################
for ARCH in "${ARCHITECTURES[@]}"; do
    log "Packaging JNI libs for: $ARCH"
    EX="${WORK}/extract-${ARCH}"
    rm -rf "$EX"; mkdir -p "$EX"

    # Unpack ALL of this arch's runtime .debs (+ "_all"), excluding "-static".
    for deb in "${OUTPUT_BASE_DIR}/${ARCH}"/*_"${ARCH}".deb \
               "${OUTPUT_BASE_DIR}/${ARCH}"/*_all.deb; do
        base="$(basename "$deb")"
        case "$base" in
            *-static_*.deb) continue ;;
        esac
        info "unpack $base"
        dpkg-deb -x "$deb" "$EX"
    done

    FILES_DIR="${EX}/data/data/com.termux/files"
    USR="${FILES_DIR}/usr"
    [ -f "${USR}/bin/${BIN_NAME}" ] || die "usr/bin/${BIN_NAME} not found for $ARCH (build incomplete)"

    if $USE_ANDROID_ABI_NAMES; then OUT_NAME="$(android_abi "$ARCH")"; else OUT_NAME="$ARCH"; fi
    dest="${JNI_DIR}/${OUT_NAME}"
    mkdir -p "$dest"

    # The executable (run directly from jniLibs by the app).
    cp "${USR}/bin/${BIN_NAME}" "${dest}/${LIB_PREFIX}.so"

    # The shared tree the binary dlopens: lib + etc + share (ICU data etc.).
    # usr/bin is skipped to avoid duplicating the (large) binary copied above.
    tmp_zip="${WORK}/${LIB_PREFIX}.zip"
    rm -f "$tmp_zip"
    zdirs=()
    for d in lib etc share; do [ -d "${USR}/${d}" ] && zdirs+=("usr/${d}"); done
    ( cd "$FILES_DIR" && zip --symlinks -qr "$tmp_zip" "${zdirs[@]}" )
    mv "$tmp_zip" "${dest}/${LIB_PREFIX}.zip.so"

    info "wrote ${dest}/{${LIB_PREFIX}.so,${LIB_PREFIX}.zip.so}"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    if $USE_ANDROID_ABI_NAMES; then n="$(android_abi "$ARCH")"; else n="$ARCH"; fi
    info "$n : $(ls -1 "${JNI_DIR}/${n}" 2>/dev/null | tr '\n' ' ')"
done
