#!/bin/bash
#
# Build ffmpeg (termux, currently 8.1.x) for Android and pack it into the
# libffmpeg.so / libffprobe.so / libffmpeg.zip.so JNI layout used by YTDLnis.
#
# RUN THIS FROM THE ROOT OF A termux-packages CHECKOUT, INSIDE the docker
# container (start it with ./scripts/run-docker.sh, then run ./build_ffmpeg.sh).
#
# Output:  ./output/jniLibs/<android-abi>/{libffmpeg.so,libffprobe.so,libffmpeg.zip.so}
#
# Phase 3 unpacks EVERY runtime .deb the build staged (ffmpeg + its whole
# dependency closure: libav*, fontconfig, freetype, harfbuzz, libxml2, libexpat,
# libc++, ...), excluding only "-static" dev packages. That is what keeps the
# bundle self-contained -- the missing-libexpat.so.1 class of failure cannot
# happen when the entire closure is shipped.
#
set -euo pipefail
shopt -s nullglob

#
# USAGE (termux arch names):
#   ./build_ffmpeg.sh                      # all four arches
#   ./build_ffmpeg.sh aarch64              # one arch (one CI job)
#   SKIP_BUILD=1 ./build_ffmpeg.sh aarch64 # skip Phase 1, just re-pack existing .debs
#
############################  CONFIG  ############################

ALL_ARCHES=("aarch64" "arm" "i686" "x86_64")
SKIP_BUILD="${SKIP_BUILD:-0}"

# The termux package to build (pulls its whole dependency tree).
FFMPEG_PKG="ffmpeg"

# Name jniLibs folders with Android ABI names.
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

########################  PHASE 1 - build ffmpeg per arch  ########################
if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1 -> skipping Phase 1, reusing existing .debs in output/<arch>/"
fi
for ARCH in "${ARCHITECTURES[@]}"; do
    if [ "$SKIP_BUILD" = "1" ]; then continue; fi
    log "Building ffmpeg for: $ARCH"
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "$FFMPEG_PKG" \
        || die "build failed for $ARCH"

    # Defensive: pull in only THIS arch's (or "_all") debs that landed one dir up.
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
    got_ffmpeg=false
    for deb in "${OUTPUT_BASE_DIR}/${ARCH}"/*_"${ARCH}".deb \
               "${OUTPUT_BASE_DIR}/${ARCH}"/*_all.deb; do
        base="$(basename "$deb")"
        case "$base" in
            *-static_*.deb) continue ;;
        esac
        info "unpack $base"
        dpkg-deb -x "$deb" "$EX"
        case "$base" in ffmpeg_*) got_ffmpeg=true ;; esac
    done
    $got_ffmpeg || die "ffmpeg .deb not found for ${ARCH} (build incomplete)"

    FILES_DIR="${EX}/data/data/com.termux/files"
    USR="${FILES_DIR}/usr"
    [ -d "$USR" ] || die "unexpected extraction layout for $ARCH"

    # If fontconfig is present its libexpat dep MUST be too, else ffmpeg won't link.
    if compgen -G "${USR}/lib/libfontconfig.so*" >/dev/null \
       && ! compgen -G "${USR}/lib/libexpat.so*" >/dev/null; then
        info "WARNING: libfontconfig present but libexpat missing -> ffmpeg will fail to link."
    fi

    [ -f "${USR}/bin/ffmpeg" ]  || die "usr/bin/ffmpeg not found for $ARCH"
    [ -f "${USR}/bin/ffprobe" ] || die "usr/bin/ffprobe not found for $ARCH"

    if $USE_ANDROID_ABI_NAMES; then OUT_NAME="$(android_abi "$ARCH")"; else OUT_NAME="$ARCH"; fi
    dest="${JNI_DIR}/${OUT_NAME}"
    mkdir -p "$dest"

    # The two executables (run directly from jniLibs by the app).
    cp "${USR}/bin/ffmpeg"  "${dest}/libffmpeg.so"
    cp "${USR}/bin/ffprobe" "${dest}/libffprobe.so"

    # The shared tree both binaries dlopen: lib (libav*/deps), etc (fontconfig
    # config), share (fontconfig/data). Skip usr/bin to avoid duplicating the
    # ~50MB binaries we already copied out above.
    tmp_zip="${WORK}/libffmpeg.zip"
    rm -f "$tmp_zip"
    zdirs=()
    for d in lib etc share; do [ -d "${USR}/${d}" ] && zdirs+=("usr/${d}"); done
    ( cd "$FILES_DIR" && zip --symlinks -qr "$tmp_zip" "${zdirs[@]}" )
    mv "$tmp_zip" "${dest}/libffmpeg.zip.so"

    info "wrote ${dest}/{libffmpeg.so,libffprobe.so,libffmpeg.zip.so}"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    if $USE_ANDROID_ABI_NAMES; then n="$(android_abi "$ARCH")"; else n="$ARCH"; fi
    info "$n : $(ls -1 "${JNI_DIR}/${n}" 2>/dev/null | tr '\n' ' ')"
done
