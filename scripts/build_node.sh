#!/bin/bash
#
# Build nodejs (termux) for Android and pack it into the libnode.so /
# libnode.zip.so JNI layout used by YTDLnis.
#
# RUN THIS FROM THE ROOT OF A termux-packages CHECKOUT, INSIDE the docker
# container (start it with ./scripts/run-docker.sh, then run ./build_node.sh).
#
# Output:  ./output/jniLibs/<android-abi>/{libnode.so,libnode.zip.so,manifest.json}

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

PKGS=("nodejs" "npm") # termux packages to build (npm is separate)
BIN_NAME="node"        # produced executable at usr/bin/<BIN_NAME>
LIB_PREFIX="libnode" # -> libnode.so (binary) + libnode.zip.so (usr/ tree)

USE_ANDROID_ABI_NAMES=true
OUTPUT_BASE_DIR="${PWD}/output"
JNI_DIR="${OUTPUT_BASE_DIR}/jniLibs"
WORK="${OUTPUT_BASE_DIR}/_work"

#################################################################

log()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[1;33m! %s\033[0m\n' "$*" >&2; }
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

# Workaround: codeberg regenerated foot's 1.27.0 archive, drifting its sha256.
# If ncurses is pulled into the tree it fetches foot's tarball for terminfo, so
# the stale checksum in x11-packages/foot/build.sh breaks the build. Correct it.
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

########################  PHASE 1 - build per arch  ########################
if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1 -> skipping Phase 1, reusing existing .debs in output/<arch>/"
fi
for ARCH in "${ARCHITECTURES[@]}"; do
    if [ "$SKIP_BUILD" = "1" ]; then continue; fi
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    for PKG in "${PKGS[@]}"; do
        log "Building $PKG for: $ARCH"
        ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "$PKG" \
            || die "build failed for $PKG ($ARCH)"

        find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \
            \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) \
            -exec mv -t "$OUTPUT_DIR/" {} + 2>/dev/null || true
    done

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

    # --- npm verification -------------------------------------------------
    # npm ships bundled inside the nodejs package itself (usr/lib/node_modules/npm),
    # which the zdirs loop below already sweeps up via "usr/lib". This just makes
    # sure it's actually there instead of silently shipping a node-only bundle,
    # and fixes exec bits that dpkg-deb extraction can drop.
    NPM_CLI_REL="lib/node_modules/npm/bin/npm-cli.js"
    NPX_CLI_REL="lib/node_modules/npm/bin/npx-cli.js"
    NPM_CLI_ABS="${USR}/${NPM_CLI_REL}"
    NPX_CLI_ABS="${USR}/${NPX_CLI_REL}"

    [ -f "$NPM_CLI_ABS" ] || die "npm-cli.js not found for $ARCH (expected usr/${NPM_CLI_REL}). nodejs 25.3.0-1+ ships npm as a separate 'npm' package -- check that packages/npm/*.deb was actually built and staged in ${OUTPUT_BASE_DIR}/${ARCH}/ (look for a build failure for PKGS=npm above, or a missing packages/npm/build.sh in this checkout)."

    chmod +x "$NPM_CLI_ABS" 2>/dev/null || true
    [ -f "$NPX_CLI_ABS" ] && chmod +x "$NPX_CLI_ABS" 2>/dev/null || true

    NPM_VERSION="$(grep -m1 '"version"' "${USR}/lib/node_modules/npm/package.json" 2>/dev/null | sed -E 's/.*"version": *"([^"]+)".*/\1/')"
    info "npm ${NPM_VERSION:-unknown} found at usr/${NPM_CLI_REL}"

    if $USE_ANDROID_ABI_NAMES; then OUT_NAME="$(android_abi "$ARCH")"; else OUT_NAME="$ARCH"; fi
    dest="${JNI_DIR}/${OUT_NAME}"
    mkdir -p "$dest"

    # The executable (run directly from jniLibs by the app).
    cp "${USR}/bin/${BIN_NAME}" "${dest}/${LIB_PREFIX}.so"

    # The shared tree the binary dlopens: lib + etc + share (ICU data, npm, etc).
    # usr/bin is skipped to avoid duplicating the (large) binary copied above --
    # npm's usr/bin/npm shell shim wouldn't be exec-able on Android anyway
    # (no shebang support); invoke npm-cli.js via node directly instead, see
    # manifest.json / the usage note printed at the end.
    tmp_zip="${WORK}/${LIB_PREFIX}.zip"
    rm -f "$tmp_zip"
    zdirs=()
    for d in lib etc share; do [ -d "${USR}/${d}" ] && zdirs+=("usr/${d}"); done
    ( cd "$FILES_DIR" && zip --symlinks -qr "$tmp_zip" "${zdirs[@]}" )
    mv "$tmp_zip" "${dest}/${LIB_PREFIX}.zip.so"

    # Manifest: tells the app exactly what to spawn to run npm, since the
    # paths live inside libnode.zip.so and aren't otherwise discoverable.
    cat > "${dest}/manifest.json" <<EOF
{
  "abi": "${OUT_NAME}",
  "node_binary": "${LIB_PREFIX}.so",
  "bundle_zip": "${LIB_PREFIX}.zip.so",
  "npm_version": "${NPM_VERSION:-unknown}",
  "npm_cli": "usr/${NPM_CLI_REL}",
  "npx_cli": "usr/${NPX_CLI_REL}",
  "node_modules_prefix": "usr/lib/node_modules"
}
EOF

    info "wrote ${dest}/{${LIB_PREFIX}.so,${LIB_PREFIX}.zip.so,manifest.json}"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    if $USE_ANDROID_ABI_NAMES; then n="$(android_abi "$ARCH")"; else n="$ARCH"; fi
    info "$n : $(ls -1 "${JNI_DIR}/${n}" 2>/dev/null | tr '\n' ' ')"
done

cat <<'EOF'

===============================================================================
 Running npm from your Android app
===============================================================================
libnode.zip.so must be unzipped to app-writable storage first (e.g. your
app's filesDir). Then, instead of exec-ing usr/bin/npm (won't work on
Android -- no shebang support), spawn the node binary directly with
npm-cli.js as the first argument:

    <filesDir>/libnode.so \
        <unzipped>/usr/lib/node_modules/npm/bin/npm-cli.js \
        install <package>

Required environment variables (npm defaults try to write into
/data/data/com.termux/..., which won't exist / won't be writable):

    HOME=<app-writable-dir>
    PREFIX=<unzipped>/usr
    NPM_CONFIG_PREFIX=<app-writable-dir>/.npm-global
    NPM_CONFIG_CACHE=<app-writable-dir>/.npm-cache
    TMPDIR=<app-writable-dir>/tmp

Caveat: this only gets you pure-JS packages. Any npm package with native
addons (node-gyp build step) needs a C/C++ cross-compiler toolchain on-device
to install, which this pipeline does not provide.
===============================================================================
EOF