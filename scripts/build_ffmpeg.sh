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
# Completeness: build-package only emits a dependency's .deb the FIRST time it
# builds it in a container; on a reused container an "already built" dep is
# skipped and no .deb is produced -> unpacking output/ alone would miss it
# (this is the libbs2b.so / libexpat.so.1 "not found" class of failure). To be
# robust we ALSO resolve ffmpeg's real DT_NEEDED closure from the live termux
# prefix (where every dep stays installed so ffmpeg could link), and then verify
# nothing is still missing before packaging.
#
set -euo pipefail
shopt -s nullglob

#
# USAGE (termux arch names):
#   ./build_ffmpeg.sh                      # all four arches
#   ./build_ffmpeg.sh aarch64              # one arch (one CI job)
#   SKIP_BUILD=1 ./build_ffmpeg.sh aarch64 # re-pack from existing debs only
#                                            (no prefix-closure resolve -- clean build recommended)
#
############################  CONFIG  ############################

ALL_ARCHES=("aarch64" "arm" "i686" "x86_64")
SKIP_BUILD="${SKIP_BUILD:-0}"

FFMPEG_PKG="ffmpeg"

USE_ANDROID_ABI_NAMES=true
OUTPUT_BASE_DIR="${PWD}/output"
JNI_DIR="${OUTPUT_BASE_DIR}/jniLibs"
WORK="${OUTPUT_BASE_DIR}/_work"

# Live termux install prefix inside the build container (all deps stay installed
# here so the target can link -- our completeness fallback source).
PREFIX_LIVE="/data/data/com.termux/files/usr"

# Libraries provided by Android at runtime (never bundled). DT_NEEDED entries for
# these are expected and must not be flagged as missing.
SYS_LIBS="libc.so libm.so libdl.so liblog.so libandroid.so libz.so libz.so.1 \
ld-android.so libEGL.so libGLESv1_CM.so libGLESv2.so libGLESv3.so libvulkan.so \
libOpenSLES.so libOpenMAXAL.so libmediandk.so libcamera2ndk.so libnativewindow.so \
libjnigraphics.so libaaudio.so libneuralnetworks.so libsync.so libnativehelper.so"

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
    for t in zip dpkg-deb patchelf find readlink; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found on PATH."
    done
}

# List DT_NEEDED entries of an ELF (empty/no-op for non-ELF files).
needed_of() { patchelf --print-needed "$1" 2>/dev/null || true; }

# Iteratively pull any unresolved DT_NEEDED libs (and their own deps) from the
# live termux prefix into the staged usr/lib. Copies the soname plus its symlink
# target so versioned chains stay intact. Only ever pulls libs that are actually
# needed, so unrelated packages in the shared prefix are never dragged in.
resolve_from_prefix() {
    local usr="$1"
    [ -d "${PREFIX_LIVE}/lib" ] || { info "live prefix not found -- skipping closure resolve"; return 0; }
    declare -A present=()
    local pass changed f n tgt added=0
    for pass in $(seq 1 30); do
        changed=0
        present=()
        while IFS= read -r f; do present["$(basename "$f")"]=1; done \
            < <(find "$usr/lib" -maxdepth 1 -name '*.so*' 2>/dev/null)
        while IFS= read -r f; do
            while IFS= read -r n; do
                [ -z "$n" ] && continue
                [ -n "${present[$n]:-}" ] && continue
                case " $SYS_LIBS " in *" $n "*) continue ;; esac
                if [ -e "${PREFIX_LIVE}/lib/$n" ]; then
                    cp -a "${PREFIX_LIVE}/lib/$n" "$usr/lib/" 2>/dev/null || true
                    tgt="$(readlink -f "${PREFIX_LIVE}/lib/$n" 2>/dev/null || true)"
                    [ -n "$tgt" ] && [ -e "$tgt" ] && cp -a "$tgt" "$usr/lib/" 2>/dev/null || true
                    present["$n"]=1; changed=1; added=$((added+1))
                    info "closure: pulled $n from live prefix"
                fi
            done < <(needed_of "$f")
        done < <({ find "$usr/lib" -maxdepth 1 -name '*.so*' 2>/dev/null; \
                   find "$usr/bin" -maxdepth 1 -type f 2>/dev/null; })
        [ "$changed" = 0 ] && break
    done
    [ "$added" -gt 0 ] && info "closure resolve added $added libraries from the live prefix"
    return 0
}

# Report any DT_NEEDED still unsatisfied (not in the bundle, not an Android
# system lib). Returns non-zero if the bundle is incomplete.
verify_closure() {
    local usr="$1"
    declare -A present=()
    local f n
    while IFS= read -r f; do present["$(basename "$f")"]=1; done \
        < <(find "$usr/lib" -maxdepth 1 -name '*.so*' 2>/dev/null)
    local missing=()
    while IFS= read -r f; do
        while IFS= read -r n; do
            [ -z "$n" ] && continue
            [ -n "${present[$n]:-}" ] && continue
            case " $SYS_LIBS " in *" $n "*) continue ;; esac
            missing+=("$n  (needed by $(basename "$f"))")
        done < <(needed_of "$f")
    done < <({ find "$usr/lib" -maxdepth 1 -name '*.so*' 2>/dev/null; \
               find "$usr/bin" -maxdepth 1 -type f 2>/dev/null; })
    if [ "${#missing[@]}" -gt 0 ]; then
        printf '\n\033[1;31m*** INCOMPLETE BUNDLE -- missing shared libraries: ***\033[0m\n' >&2
        printf '%s\n' "${missing[@]}" | sort -u >&2
        printf '\033[1;31mA dependency was not staged (dirty build container). Fix with a clean build:\n  ./scripts/run-docker.sh ./clean.sh\n  ./scripts/run-docker.sh ./build_ffmpeg.sh <arch>\n\033[0m\n' >&2
        return 1
    fi
    info "closure check OK -- all DT_NEEDED satisfied"
    return 0
}

########################  PHASE 0  ########################
check_prereqs
mkdir -p "$WORK" "$JNI_DIR"

# Workaround: codeberg regenerated foot's 1.27.0 archive, drifting its sha256.
# ncurses (pulled into ffmpeg's tree) fetches foot's tarball to build its
# terminfo, so the stale checksum in x11-packages/foot/build.sh breaks the build.
# Self-clears (no-op) once the pinned termux-packages updates the value.
sed -i 's/4e6131cc859ec6a36569f1978cf3617cc3836a681d13d228ded1b4885dab7770/9b9568ec5a9ff728f49c77d73644e7691fe386956e2d9acbdef0fc590e5828c8/' x11-packages/foot/build.sh 2>/dev/null || true

if [ "$#" -gt 0 ]; then
    ARCHITECTURES=("$@")
    for a in "${ARCHITECTURES[@]}"; do
        in_list "$a" "${ALL_ARCHES[@]}" || die "unknown arch '$a' (valid: ${ALL_ARCHES[*]})"
    done
else
    ARCHITECTURES=("${ALL_ARCHES[@]}")
fi
log "Target arches: ${ARCHITECTURES[*]}   (SKIP_BUILD=${SKIP_BUILD})"

########################  BUILD + PACKAGE (interleaved per arch)  ########################
# Interleaved so the live prefix used by resolve_from_prefix always matches the
# arch we are packaging (a later arch's build would overwrite the prefix).
incomplete=()
for ARCH in "${ARCHITECTURES[@]}"; do
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    if [ "$SKIP_BUILD" != "1" ]; then
        log "Building $FFMPEG_PKG for: $ARCH"
        ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "$FFMPEG_PKG" || die "build failed for $ARCH"
        find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \
            \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) \
            -exec mv -t "$OUTPUT_DIR/" {} + 2>/dev/null || true
    fi

    log "Packaging JNI libs for: $ARCH"
    EX="${WORK}/extract-${ARCH}"
    rm -rf "$EX"; mkdir -p "$EX"

    # Base: unpack every runtime .deb this arch produced (+ "_all"), skip -static.
    for deb in "${OUTPUT_BASE_DIR}/${ARCH}"/*_"${ARCH}".deb \
               "${OUTPUT_BASE_DIR}/${ARCH}"/*_all.deb; do
        base="$(basename "$deb")"
        case "$base" in *-static_*.deb) continue ;; esac
        info "unpack $base"
        dpkg-deb -x "$deb" "$EX"
    done

    FILES_DIR="${EX}/data/data/com.termux/files"
    USR="${FILES_DIR}/usr"
    [ -f "${USR}/bin/ffmpeg" ]  || die "usr/bin/ffmpeg not found for $ARCH (build incomplete)"
    [ -f "${USR}/bin/ffprobe" ] || die "usr/bin/ffprobe not found for $ARCH (build incomplete)"

    # Fallback: pull any deps whose .deb was skipped, straight from the live
    # prefix (only valid right after this arch was built, not under SKIP_BUILD).
    if [ "$SKIP_BUILD" != "1" ]; then
        resolve_from_prefix "$USR"
        # fontconfig config/data isn't reachable via DT_NEEDED -- copy it if present.
        for d in etc/fonts share/fontconfig share/fonts; do
            if [ -d "${PREFIX_LIVE}/${d}" ]; then
                mkdir -p "${USR}/${d%/*}"
                cp -a "${PREFIX_LIVE}/${d}" "${USR}/${d%/*}/" 2>/dev/null || true
            fi
        done
    fi

    # Verify the closure; record (don't abort the whole run) if incomplete.
    if ! verify_closure "$USR"; then
        incomplete+=("$ARCH")
    fi

    if $USE_ANDROID_ABI_NAMES; then OUT_NAME="$(android_abi "$ARCH")"; else OUT_NAME="$ARCH"; fi
    dest="${JNI_DIR}/${OUT_NAME}"
    mkdir -p "$dest"

    cp "${USR}/bin/ffmpeg"  "${dest}/libffmpeg.so"
    cp "${USR}/bin/ffprobe" "${dest}/libffprobe.so"

    # Shared tree both binaries dlopen (skip usr/bin to avoid duplicating binaries).
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

if [ "${#incomplete[@]}" -gt 0 ]; then
    die "INCOMPLETE bundle(s) for: ${incomplete[*]} -- see the missing-library list above. Do a clean build (./scripts/run-docker.sh ./clean.sh) and rebuild."
fi
