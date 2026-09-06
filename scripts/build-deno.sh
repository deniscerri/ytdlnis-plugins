#!/bin/bash
#
# Build deno (termux) for Android and pack it into the libdeno.so /
# libdeno.zip.so JNI layout used by YTDLnis.
#
# Output:  ./output/jniLibs/<android-abi>/{libdeno.so,libdeno.zip.so}
#
set -euo pipefail
shopt -s nullglob

############################  CONFIG  ############################

ALL_ARCHES=("aarch64" "x86_64")
SKIP_BUILD="${SKIP_BUILD:-0}"

PKG="deno"
BIN_NAME="deno"
LIB_PREFIX="libdeno"

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
    for t in zip dpkg-deb llvm-strip; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found on PATH."
    done
}

########################  PHASE 0  ########################
check_prereqs
mkdir -p "$WORK" "$JNI_DIR"

sed -i 's/4e6131cc859ec6a36569f1978cf3617cc3836a681d13d228ded1b4885dab7770/9b9568ec5a9ff728f49c77d73644e7691fe386956e2d9acbdef0fc590e5828c8/' x11-packages/foot/build.sh 2>/dev/null || true

if [ "$#" -gt 0 ]; then
    ARCHITECTURES=("$@")
    for a in "${ARCHITECTURES[@]}"; do
        in_list "$a" "${ALL_ARCHES[@]}" || die "unknown/unsupported arch '$a' for deno (valid: ${ALL_ARCHES[*]})"
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

########################  PHASE 2 - merge & optimize JNI zip  ########################
for ARCH in "${ARCHITECTURES[@]}"; do
    log "Packaging JNI libs for: $ARCH"
    EX="${WORK}/extract-${ARCH}"
    rm -rf "$EX"; mkdir -p "$EX"

    # 1. Unpack non-static .deb packages
    for deb in "${OUTPUT_BASE_DIR}/${ARCH}"/*_"${ARCH}".deb \
               "${OUTPUT_BASE_DIR}/${ARCH}"/*_all.deb; do
        base="$(basename "$deb")"
        case "$base" in
            *-static_*.deb|*-dev_*.deb) continue ;;
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

    # 2. Aggressive Cleanup of Non-Essential Files
    info "Pruning unnecessary files and assets..."
    rm -rf "${USR}/share/doc" \
           "${USR}/share/man" \
           "${USR}/share/info" \
           "${USR}/share/locale" \
           "${USR}/share/gtk-doc" \
           "${USR}/include" \
           "${USR}/lib/pkgconfig" \
           "${USR}/lib/cmake"
           
    # Remove all development archives (.a files) accidentally packed in non-static packages
    find "${USR}" -type f -name "*.a" -delete

    # 3. Strip Symbols from Binaries and Dynamic Libraries (.so files)
    info "Stripping symbols from executable and shared objects..."
    llvm-strip --strip-unneeded "${USR}/bin/${BIN_NAME}" 2>/dev/null || strip --strip-unneeded "${USR}/bin/${BIN_NAME}" 2>/dev/null || true
    
    find "${USR}/lib" -type f -name "*.so*" -exec \
        sh -c 'llvm-strip --strip-unneeded "$1" 2>/dev/null || strip --strip-unneeded "$1" 2>/dev/null || true' _ {} \;

    # 4. Copy stripped executable to target
    cp "${USR}/bin/${BIN_NAME}" "${dest}/${LIB_PREFIX}.so"

    # 5. Pack into maximum-compression ZIP archive
    tmp_zip="${WORK}/${LIB_PREFIX}.zip"
    rm -f "$tmp_zip"
    zdirs=()
    for d in lib etc share; do [ -d "${USR}/${d}" ] && zdirs+=("usr/${d}"); done

    info "Compressing runtime environment with maximum zip compression (-9)..."
    ( cd "$FILES_DIR" && zip -9 --symlinks -qr "$tmp_zip" "${zdirs[@]}" )
    mv "$tmp_zip" "${dest}/${LIB_PREFIX}.zip.so"

    info "wrote ${dest}/{${LIB_PREFIX}.so,${LIB_PREFIX}.zip.so}"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    if $USE_ANDROID_ABI_NAMES; then n="$(android_abi "$ARCH")"; else n="$ARCH"; fi
    info "$n : $(ls -1 "${JNI_DIR}/${n}" 2>/dev/null | tr '\n' ' ')"
done