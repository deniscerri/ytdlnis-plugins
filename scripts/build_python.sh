#!/bin/bash
#
# Build Python (latest, 3.14.x) for Android with the termux build system,
# bundle a set of Python packages into site-packages, and pack everything into
# the libpython.so / libpython.zip.so JNI layout used by YTDLnis.
#
# RUN THIS FROM THE ROOT OF A termux-packages CHECKOUT, INSIDE the docker
# container (start it with ./scripts/run-docker.sh, then run ./build_python.sh).
# It expects, in the current dir: build-package.sh and packages/ .
#
# Output goes to  ./output/jniLibs/<android-abi>/{libpython.so,libpython.zip.so}
#
# Bundled packages:
#   native, all arches : python-pycryptodomex, python-brotli   (cross-compiled)
#   native, arm64 only : python-cffi                            (cross-compiled)
#   wheel,  arm64 only : curl-cffi  (prebuilt cp313-abi3 android wheel)
#   pure-python, all   : requests certifi charset-normalizer idna urllib3
#                        websockets mutagen pycparser
#
set -euo pipefail
shopt -s nullglob

#
# USAGE (termux arch names):
#   ./build_python.sh                      # build all four arches
#   ./build_python.sh aarch64              # only arm64 (one CI job)
#   ./build_python.sh aarch64 x86_64       # a subset
#   SKIP_BUILD=1 ./build_python.sh aarch64 # skip Phase 1 (reuse existing .debs),
#                                            just re-fetch wheels + re-pack the zip
#
############################  CONFIG  ############################

# Full set of supported arches. The ones actually built are chosen from the
# command line (see PHASE 0); with no args, all of these are built.
ALL_ARCHES=("aarch64" "arm" "i686" "x86_64")

# Set to 1 (or pass SKIP_BUILD=1 in the env) to skip Phase 1 and reuse the
# .debs already in output/<arch>/ -- handy when only tweaking the packaging.
SKIP_BUILD="${SKIP_BUILD:-0}"

# Arches that additionally get cffi + curl-cffi (curl-cffi only ships an arm64
# android wheel, and cffi is its native runtime dependency).
CURL_CFFI_ARCHES=("aarch64")

# Native termux packages to build per arch (python is implied, listed for clarity).
NATIVE_PKGS=("python" "python-pycryptodomex" "python-brotli")
# Extra native package built only for the CURL_CFFI_ARCHES.
NATIVE_PKGS_CURLCFFI=("python-cffi")

# NOTE: we deliberately do NOT hand-list which .debs to bundle. Phase 3 unpacks
# EVERY runtime .deb that build-package.sh staged for the arch (python + its full
# dependency closure + the python-* extension packages), excluding only "-static"
# dev packages. This guarantees every backing library the stdlib C extensions
# dlopen is present -- libexpat (pyexpat), libsqlite (sqlite3), liblzma, libbz2,
# gdbm, libcrypt, ncurses, zstd, ... -- instead of a subset that silently drops one.

# Pure-python packages, pinned  ->  "<pypi-name>:<version>". These are fetched
# as their -none-any.whl wheels and are architecture independent.
PURE_PKGS=(
    "requests:2.34.2"
    "certifi:2026.6.17"
    "charset-normalizer:3.4.9"
    "idna:3.18"
    "urllib3:2.7.0"
    "websockets:16.1"
    "mutagen:1.48.1"
    "pycparser:2.22"     # runtime dep of cffi
)

# Prebuilt curl-cffi android wheel (arm64 / aarch64 only, abi3 -> works on 3.13+).
CURL_CFFI_VERSION="0.15.1b2"
CURL_CFFI_WHEEL="curl_cffi-${CURL_CFFI_VERSION}-cp313-abi3-android_24_arm64_v8a.whl"
CURL_CFFI_URL="https://github.com/lexiforest/curl_cffi/releases/download/v${CURL_CFFI_VERSION}/${CURL_CFFI_WHEEL}"

# Name the jniLibs folders with Android ABI names (arm64-v8a / armeabi-v7a /
# x86 / x86_64) so they can be dropped straight into the app's jniLibs.
USE_ANDROID_ABI_NAMES=true

OUTPUT_BASE_DIR="${PWD}/output"
JNI_DIR="${OUTPUT_BASE_DIR}/jniLibs"
WORK="${OUTPUT_BASE_DIR}/_work"
PURE_SITE="${WORK}/pure-site"          # shared, arch independent
CURLCFFI_SITE="${WORK}/curl-cffi-site" # arm64 only

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
    for t in curl unzip zip dpkg-deb python3 patchelf; do
        command -v "$t" >/dev/null 2>&1 || die "required tool '$t' not found on PATH."
    done
}

# The prebuilt curl-cffi wheel is an abi3 wheel built on a *different* Python
# (e.g. 3.13), so its _wrapper.abi3.so has a DT_NEEDED for libpython3.13.so.
# On Android, extensions are hard-linked against libpython, so this must point
# at the libpython we actually ship. abi3 = stable ABI, so retargeting is safe.
patch_curl_cffi_libpython() {
    local so="$1" pyver="$2"
    [ -f "$so" ] || return 0
    local cur
    cur="$(patchelf --print-needed "$so" | grep -E '^libpython3\.' | head -1 || true)"
    if [ -n "$cur" ] && [ "$cur" != "libpython${pyver}.so" ]; then
        info "patchelf: $cur -> libpython${pyver}.so  ($(basename "$so"))"
        patchelf --replace-needed "$cur" "libpython${pyver}.so" "$so"
    fi
}

# Write the python-cffi recipe into the tree if it is not already there.
ensure_cffi_recipe() {
    local dir="packages/python-cffi"
    if [ -f "$dir/build.sh" ]; then
        info "python-cffi recipe already present."
        return
    fi
    log "Creating $dir/build.sh"
    mkdir -p "$dir"
    cat > "$dir/build.sh" <<'RECIPE'
TERMUX_PKG_HOMEPAGE=https://cffi.readthedocs.io/
TERMUX_PKG_DESCRIPTION="Foreign Function Interface for Python calling C code"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="you"
TERMUX_PKG_VERSION="2.0.0"
TERMUX_PKG_SRCURL="https://files.pythonhosted.org/packages/eb/56/b1ba7935a17738ae8453301356628e8147c79dbb825bcbc73dc7401f9846/cffi-${TERMUX_PKG_VERSION}.tar.gz"
TERMUX_PKG_SHA256=44d1b5909021139fe36001ae048dbdde8214afa20200eda0f64c068cac5d5529
TERMUX_PKG_DEPENDS="python, python-pip, libffi"
TERMUX_PKG_SETUP_PYTHON=true
TERMUX_PKG_BUILD_IN_SRC=true

termux_step_pre_configure() {
	LDFLAGS+=" -Wl,--no-as-needed -lpython${TERMUX_PYTHON_VERSION}"
}

termux_step_make() {
	:
}

termux_step_make_install() {
	pip install . --prefix="$TERMUX_PREFIX" -vv --no-build-isolation --no-deps
}
RECIPE
}

# Download a wheel (from a URL) and unzip it into a site dir.
unpack_wheel_url() {
    local url="$1" site="$2"
    local file="${WORK}/$(basename "$url")"
    curl -fsSL "$url" -o "$file"
    unzip -q -o "$file" -d "$site"
}

# Resolve a PyPI "name:version" to its -none-any.whl download URL and unpack it.
fetch_pure_pkg() {
    local entry="$1" site="$2"
    local name="${entry%%:*}" ver="${entry##*:}"
    info "pure  $name==$ver"
    local url
    url="$(curl -fsSL "https://pypi.org/pypi/${name}/${ver}/json" \
        | python3 -c "import sys,json;d=json.load(sys.stdin);print(next(u['url'] for u in d['urls'] if u['filename'].endswith('-none-any.whl')))")" \
        || die "could not resolve a pure wheel for ${name}==${ver}"
    unpack_wheel_url "$url" "$site"
}

########################  PHASE 0  ########################
check_prereqs
ensure_cffi_recipe
mkdir -p "$WORK" "$JNI_DIR"

# Select arches from the command line, defaulting to all of them.
if [ "$#" -gt 0 ]; then
    ARCHITECTURES=("$@")
    for a in "${ARCHITECTURES[@]}"; do
        in_list "$a" "${ALL_ARCHES[@]}" || die "unknown arch '$a' (valid: ${ALL_ARCHES[*]})"
    done
else
    ARCHITECTURES=("${ALL_ARCHES[@]}")
fi
log "Target arches: ${ARCHITECTURES[*]}   (SKIP_BUILD=${SKIP_BUILD})"

########################  PHASE 1 - build native packages per arch  ########################
if [ "$SKIP_BUILD" = "1" ]; then
    log "SKIP_BUILD=1 -> skipping Phase 1, reusing existing .debs in output/<arch>/"
fi
for ARCH in "${ARCHITECTURES[@]}"; do
    if [ "$SKIP_BUILD" = "1" ]; then continue; fi
    log "Building native packages for: $ARCH"
    OUTPUT_DIR="${OUTPUT_BASE_DIR}/${ARCH}"
    mkdir -p "$OUTPUT_DIR"

    pkgs=("${NATIVE_PKGS[@]}")
    if in_list "$ARCH" "${CURL_CFFI_ARCHES[@]}"; then
        pkgs+=("${NATIVE_PKGS_CURLCFFI[@]}")
    fi

    info "packages: ${pkgs[*]}"
    ./build-package.sh -a "$ARCH" -o "$OUTPUT_DIR" "${pkgs[@]}" \
        || die "build failed for $ARCH"

    # Defensive: collect debs that landed one level up -- but ONLY this arch's
    # (and arch-independent "_all") so we never pull another arch's debs in here.
    find "${OUTPUT_BASE_DIR}" -maxdepth 1 -type f \
        \( -name "*_${ARCH}.deb" -o -name "*_all.deb" \) \
        -exec mv -t "$OUTPUT_DIR/" {} + 2>/dev/null || true

    info "done: $ARCH"
done

########################  PHASE 2 - fetch pure + curl-cffi wheels (once)  ########################
log "Fetching pure-python wheels"
rm -rf "$PURE_SITE"; mkdir -p "$PURE_SITE"
for entry in "${PURE_PKGS[@]}"; do
    fetch_pure_pkg "$entry" "$PURE_SITE"
done

log "Fetching curl-cffi android wheel"
rm -rf "$CURLCFFI_SITE"; mkdir -p "$CURLCFFI_SITE"
info "$CURL_CFFI_WHEEL"
unpack_wheel_url "$CURL_CFFI_URL" "$CURLCFFI_SITE"

########################  PHASE 3 - merge into JNI zip per arch  ########################
for ARCH in "${ARCHITECTURES[@]}"; do
    log "Packaging JNI libs for: $ARCH"
    EX="${WORK}/extract-${ARCH}"
    rm -rf "$EX"; mkdir -p "$EX"

    curl_cffi_here=false
    if in_list "$ARCH" "${CURL_CFFI_ARCHES[@]}"; then
        curl_cffi_here=true
    fi

    # Unpack ALL of this arch's runtime .debs (+ arch-independent "_all"),
    # excluding "-static" dev packages. Matching only "_<arch>.deb"/"_all.deb"
    # keeps a stray wrong-arch .deb from contaminating the bundle; unpacking all
    # of them (rather than a hand-picked list) guarantees python's whole runtime
    # closure -- and every stdlib backing lib -- is present.
    got_python=false
    for deb in "${OUTPUT_BASE_DIR}/${ARCH}"/*_"${ARCH}".deb \
               "${OUTPUT_BASE_DIR}/${ARCH}"/*_all.deb; do
        base="$(basename "$deb")"
        case "$base" in
            *-static_*.deb) continue ;;
        esac
        info "unpack $base"
        dpkg-deb -x "$deb" "$EX"
        case "$base" in python_*) got_python=true ;; esac
    done
    $got_python || die "python .deb not found for ${ARCH} (build incomplete)"

    # Warn loudly if a known-critical backing lib is missing.
    if ! compgen -G "${EX}/data/data/com.termux/files/usr/lib/libexpat.so*" >/dev/null; then
        info "WARNING: libexpat.so missing -> pyexpat/XML parsing will fail (Instagram, DASH). Was libexpat built?"
    fi

    PREFIX_DIR="${EX}/data/data/com.termux/files/usr"
    [ -d "$PREFIX_DIR" ] || die "unexpected extraction layout for $ARCH"

    # Detect the python x.y version dir.
    pydir=("$PREFIX_DIR"/lib/python3.*)
    [ -d "${pydir[0]}" ] || die "no python3.x lib dir found for $ARCH"
    PYVER="$(basename "${pydir[0]}" | sed 's/^python//')"
    SITE="${pydir[0]}/site-packages"
    mkdir -p "$SITE"
    info "python $PYVER  ->  site-packages"

    # Inject pure-python packages (all arches) and curl-cffi (arm64 only).
    cp -a "${PURE_SITE}/." "$SITE/"
    if $curl_cffi_here; then
        info "injecting curl-cffi (cffi is native, from python-cffi.deb)"
        cp -a "${CURLCFFI_SITE}/." "$SITE/"
        # Retarget the wheel's libpython3.13.so dependency to our libpython.
        patch_curl_cffi_libpython "$SITE/curl_cffi/_wrapper.abi3.so" "$PYVER"
    fi

    # Sanity check: the interpreter binary must exist.
    PYBIN="${PREFIX_DIR}/bin/python${PYVER}"
    [ -f "$PYBIN" ] || die "python${PYVER} binary not found for $ARCH"

    # Build the two artifacts.
    tmp_so="${WORK}/libpython.so"
    tmp_zip="${WORK}/libpython.zip"
    rm -f "$tmp_so" "$tmp_zip"
    cp "$PYBIN" "$tmp_so"
    ( cd "${EX}/data/data/com.termux/files" && zip --symlinks -qr "$tmp_zip" usr/lib usr/etc )

    if $USE_ANDROID_ABI_NAMES; then OUT_NAME="$(android_abi "$ARCH")"; else OUT_NAME="$ARCH"; fi
    dest="${JNI_DIR}/${OUT_NAME}"
    mkdir -p "$dest"
    mv "$tmp_zip" "${dest}/libpython.zip.so"
    mv "$tmp_so"  "${dest}/libpython.so"
    info "wrote ${dest}/libpython.so  and  libpython.zip.so"
done

log "All done. JNI libraries are in: ${JNI_DIR}"
for ARCH in "${ARCHITECTURES[@]}"; do
    if $USE_ANDROID_ABI_NAMES; then n="$(android_abi "$ARCH")"; else n="$ARCH"; fi
    info "$n : $(ls -1 "${JNI_DIR}/${n}" 2>/dev/null | tr '\n' ' ')"
done
