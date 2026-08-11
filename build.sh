#!/bin/bash
#
# PS4 Linux Baikal Kernel Build Script
#
# Multi-target: each target lives in targets/<name>.env and defines the
# kernel base, branch/tag, config, and patch series. Build with:
#
#   ./build.sh                   # default target (6.18-baikal)
#   ./build.sh -t 5.4-baikal     # recovery baseline
#
# See README.md and BUILD_LOG.md for details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_ROOT="${PS4_KERNEL_BUILD_ROOT:-${SCRIPT_DIR}}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

usage() {
    local available
    available=$(ls "${SCRIPT_DIR}/targets/"*.env 2>/dev/null | xargs -I{} basename {} .env | tr '\n' ' ')
    cat <<EOF
PS4 Linux Baikal Kernel Build Script

Usage: $0 [OPTIONS]

Options:
    -t, --target NAME   Target to build (default: 6.18-baikal)
                        Available: ${available}
    -c, --clean         Clean build (remove src and rebuild)
    -u, --update        Update base kernel from upstream
    -p, --patches-only  Only apply patches (don't build)
    -n, --no-patches    Build without applying patches
    -j, --jobs N        Number of parallel jobs (default: 80% of cores)
    -h, --help          Show this help

Examples:
    $0                          # build default (6.18-baikal)
    $0 -t 5.4-baikal -c         # clean rebuild of recovery target
    $0 -t 6.x-baikal            # build the archived 6.15 target
    $0 -j 8                     # build 6.18 with 8 jobs

EOF
    exit 0
}

# Defaults
TARGET="6.18-baikal"
CLEAN=false
UPDATE=false
PATCHES_ONLY=false
NO_PATCHES=false
JOBS=$(($(nproc) * 80 / 100))
[ "$JOBS" -lt 1 ] && JOBS=1

while [[ $# -gt 0 ]]; do
    case $1 in
        -t|--target) TARGET="$2"; shift 2 ;;
        -c|--clean) CLEAN=true; shift ;;
        -u|--update) UPDATE=true; shift ;;
        -p|--patches-only) PATCHES_ONLY=true; shift ;;
        -n|--no-patches) NO_PATCHES=true; shift ;;
        -j|--jobs) JOBS="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# Load target definition
TARGET_FILE="${SCRIPT_DIR}/targets/${TARGET}.env"
if [ ! -f "${TARGET_FILE}" ]; then
    log_error "Unknown target: ${TARGET}"
    log_error "Available targets:"
    ls "${SCRIPT_DIR}/targets/"*.env 2>/dev/null | xargs -I{} basename {} .env | sed 's/^/  /'
    exit 1
fi

# shellcheck disable=SC1090
source "${TARGET_FILE}"

# Resolve target-relative paths
SRC_DIR="${BUILD_ROOT}/src/${TARGET_NAME}"
OUTPUT_DIR="${SCRIPT_DIR}/output/${TARGET_NAME}"
CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
SERIES_FILE="${SCRIPT_DIR}/${SERIES_FILE}"
PATCHES_DIR="${SCRIPT_DIR}/${PATCHES_DIR}"

echo ""
echo "=============================================================="
echo "  PS4 Linux Baikal Kernel Build  —  target: ${TARGET_NAME}"
echo "=============================================================="
echo "  Base repo:    ${BASE_REPO}"
echo "  Base ref:     ${BASE_REF}"
echo "  Config:       ${CONFIG_FILE#${SCRIPT_DIR}/}"
echo "  Series:       ${SERIES_FILE#${SCRIPT_DIR}/}"
echo "  Source dir:   src/${TARGET_NAME}"
echo "  Output dir:   output/${TARGET_NAME}"
echo "  Parallel:     ${JOBS} jobs"
echo "=============================================================="
echo ""

if [ "$CLEAN" = true ]; then
    log_step "Cleaning build directory..."
    rm -rf "${SRC_DIR}"
    if [ "$PATCHES_ONLY" = false ]; then
        rm -rf "${OUTPUT_DIR}"
    else
        log_info "Preserving output/${TARGET_NAME} during patch-only validation"
    fi
fi

mkdir -p "${OUTPUT_DIR}"

# Step 1: prepare base kernel
log_step "=== Step 1: Preparing base kernel ==="

if [ ! -d "${SRC_DIR}" ]; then
    log_info "Cloning base kernel..."
    log_info "  Repo:  ${BASE_REPO}"
    log_info "  Ref:   ${BASE_REF}"
    log_info "  Depth: ${BASE_DEPTH}"
    git clone --depth="${BASE_DEPTH}" --branch "${BASE_REF}" \
        "${BASE_REPO}" "${SRC_DIR}"
elif [ "$UPDATE" = true ]; then
    log_info "Updating base kernel..."
    cd "${SRC_DIR}"
    git checkout . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
    git fetch --depth="${BASE_DEPTH}" origin "${BASE_REF}"
    git reset --hard "FETCH_HEAD"
    cd "${SCRIPT_DIR}"
else
    log_info "Using existing source tree at src/${TARGET_NAME}"
fi

actual_base_commit=$(git -C "${SRC_DIR}" rev-parse HEAD)
if [[ -n "${BASE_COMMIT:-}" && "${actual_base_commit}" != "${BASE_COMMIT}" ]]; then
    log_error "Base commit mismatch for ${BASE_REF}"
    log_error "Expected: ${BASE_COMMIT}"
    log_error "Actual:   ${actual_base_commit}"
    exit 1
fi

# Step 2: apply patches
log_step "=== Step 2: Applying patches ==="
cd "${SRC_DIR}"

log_info "Resetting source tree to clean state..."
git checkout . 2>/dev/null || true
git clean -fd 2>/dev/null || true

if [ "$NO_PATCHES" = false ] && [ -f "${SERIES_FILE}" ]; then
    PATCH_COUNT=0
    PATCH_FAILED=0
    PATCH_SKIPPED=0

    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue

        patch_file="${PATCHES_DIR}/${line}"

        if [ ! -f "${patch_file}" ]; then
            log_error "Patch file not found: ${line}"
            exit 1
        fi

        if git apply --reverse --check --whitespace=nowarn "${patch_file}" >/dev/null 2>&1; then
            log_warn "Already applied, skipping: ${line}"
            PATCH_SKIPPED=$((PATCH_SKIPPED + 1))
            continue
        fi

        # git-apply never performs GNU patch-style fuzzy matching. Check first
        # so a failed patch cannot leave a partially modified source tree.
        if git apply --check --whitespace=nowarn "${patch_file}" &&
           git apply --whitespace=nowarn "${patch_file}"; then
            log_info "Applied: ${line}"
            PATCH_COUNT=$((PATCH_COUNT + 1))
        else
            log_error "FAILED: ${line}"
            exit 1
        fi
    done < "${SERIES_FILE}"

    echo ""
    log_info "Patch summary: applied=${PATCH_COUNT} skipped=${PATCH_SKIPPED} failed=${PATCH_FAILED}"
    if [ ${PATCH_FAILED} -gt 0 ]; then
        log_error "Some patches failed to apply!"
        exit 1
    fi
elif [ "$NO_PATCHES" = true ]; then
    log_info "Patch application disabled (--no-patches)"
else
    log_warn "No series file at ${SERIES_FILE} — building base kernel only"
fi

if [ "$PATCHES_ONLY" = true ]; then
    log_info "Patches applied. Exiting (--patches-only)."
    exit 0
fi

# Configuration and compilation must use the same target architecture. This
# matters on Apple Silicon: an unqualified olddefconfig would resolve the x86
# config as arm64 and silently discard CONFIG_X86_PS4.
# Set LOCALVERSION explicitly so kbuild does not derive a misleading
# "-dirty" suffix from the intentionally patched source worktree.
MAKE_BASE_ARGS=("ARCH=${KERNEL_ARCH:-x86_64}" "LOCALVERSION=")
if [[ -n "${CROSS_COMPILE:-}" ]]; then
    MAKE_BASE_ARGS+=("CROSS_COMPILE=${CROSS_COMPILE}")
fi

# Step 3: configure
log_step "=== Step 3: Configuring kernel ==="
if [ -f "${CONFIG_FILE}" ]; then
    log_info "Using config: ${CONFIG_FILE#${SCRIPT_DIR}/}"
    cp "${CONFIG_FILE}" .config
else
    log_warn "Config not found, falling back to defconfig"
    make "${MAKE_BASE_ARGS[@]}" defconfig
fi

# Apply only fragments declared by this target. A release target must not pick
# up a newly added global debug fragment merely because it exists on disk.
for fragment_path in ${CONFIG_FRAGMENTS:-}; do
    fragment="${SCRIPT_DIR}/${fragment_path}"
    if [[ ! -f "${fragment}" ]]; then
        log_error "Config fragment not found: ${fragment_path}"
        exit 1
    fi
    log_info "Merging fragment: ${fragment_path}"
    ./scripts/kconfig/merge_config.sh -m .config "${fragment}"
done

log_info "Resolving config dependencies..."
make "${MAKE_BASE_ARGS[@]}" olddefconfig

# Stage firmware blobs into kernel source tree for CONFIG_EXTRA_FIRMWARE
# (kbuild expects them relative to ${CONFIG_EXTRA_FIRMWARE_DIR} which we set
# to "firmware" — same as kbuild's default, relative to kernel source root).
if [ -d "${SCRIPT_DIR}/firmware" ]; then
    log_info "Staging firmware blobs from ${SCRIPT_DIR#${HOME}/}/firmware/..."
    mkdir -p firmware
    # Copy non-doc files (skip README.md). Preserve subdirs (mediatek/, mrvl/).
    find "${SCRIPT_DIR}/firmware" -type f ! -name "README*" -print0 | while IFS= read -r -d '' src; do
        rel="${src#${SCRIPT_DIR}/firmware/}"
        dst="firmware/${rel}"
        mkdir -p "$(dirname "$dst")"
        cp -u "$src" "$dst"
    done
fi

# Step 4: build
log_step "=== Step 4: Building kernel ==="

MAKE_ARGS=("-j${JOBS}" "${MAKE_BASE_ARGS[@]}")
if [ "${COMPILER:-gcc}" = "clang" ]; then
    if ! command -v clang >/dev/null 2>&1; then
        log_error "Target requires clang but it's not installed."
        log_error "Install: sudo pacman -S clang lld llvm   (or your distro's equivalent)"
        exit 1
    fi
    log_info "Compiler: clang $(clang --version | head -1 | awk '{print $NF}')"
    MAKE_ARGS+=(LLVM=1 LLVM_IAS=1)
else
    log_info "Compiler: $(gcc --version | head -1)"
fi

log_info "Building bzImage..."
make "${MAKE_ARGS[@]}" bzImage
log_info "Building modules..."
make "${MAKE_ARGS[@]}" modules

# Step 5: collect outputs
log_step "=== Step 5: Collecting build artifacts ==="
cp arch/x86/boot/bzImage "${OUTPUT_DIR}/"
cp .config "${OUTPUT_DIR}/config"
cp System.map "${OUTPUT_DIR}/"

KERNEL_VERSION=$(make "${MAKE_BASE_ARGS[@]}" -s kernelrelease)
echo "${KERNEL_VERSION}" > "${OUTPUT_DIR}/version.txt"

MODULES_DIR="${OUTPUT_DIR}/modules"
MODULES_ARCHIVE="${OUTPUT_DIR}/modules-${KERNEL_VERSION}.tar.zst"
log_info "Installing modules into a staging directory..."
rm -rf "${MODULES_DIR}"
make "${MAKE_BASE_ARGS[@]}" \
    INSTALL_MOD_PATH="${MODULES_DIR}" \
    INSTALL_MOD_STRIP=1 \
    modules_install

# modules_install leaves build/source links pointing at the container's
# ephemeral source directory. They are useless in a runtime-only archive and
# would become misleading broken links after extraction on the PS4.
rm -f \
    "${MODULES_DIR}/lib/modules/${KERNEL_VERSION}/build" \
    "${MODULES_DIR}/lib/modules/${KERNEL_VERSION}/source"

log_info "Compressing the module tree..."
tar --zstd -C "${MODULES_DIR}" -cf "${MODULES_ARCHIVE}" lib

SERIES_SHA256=$(sha256sum "${SERIES_FILE}" | awk '{print $1}')
CONFIG_SHA256=$(sha256sum "${OUTPUT_DIR}/config" | awk '{print $1}')
PATCH_COUNT=$(grep -Ec '^[^#[:space:]].*\.patch$' "${SERIES_FILE}")
PATCHSET_SHA256=$(
    while IFS= read -r patch_name; do
        patch_sha=$(sha256sum "${PATCHES_DIR}/${patch_name}" | awk '{print $1}')
        printf '%s  %s\n' "${patch_sha}" "${patch_name}"
    done < <(grep -E '^[^#[:space:]].*\.patch$' "${SERIES_FILE}") \
        | sha256sum | awk '{print $1}'
)
cat > "${OUTPUT_DIR}/manifest.txt" <<EOF
target=${TARGET_NAME}
kernel_release=${KERNEL_VERSION}
base_repo=${BASE_REPO}
base_ref=${BASE_REF}
base_commit=${actual_base_commit}
series_sha256=${SERIES_SHA256}
patchset_sha256=${PATCHSET_SHA256}
config_sha256=${CONFIG_SHA256}
active_patch_count=${PATCH_COUNT}
compiler=$(${CROSS_COMPILE:-}gcc --version | head -1)
builder_image=${PS4_KERNEL_BUILDER_IMAGE:-unspecified}
builder_image_id=${PS4_KERNEL_BUILDER_IMAGE_ID:-unspecified}
EOF

(
    cd "${OUTPUT_DIR}"
    sha256sum \
        bzImage \
        config \
        System.map \
        "$(basename "${MODULES_ARCHIVE}")" \
        manifest.txt \
        version.txt > SHA256SUMS
)

echo ""
echo "=============================================================="
log_info "BUILD COMPLETE  —  ${TARGET_NAME}"
echo "=============================================================="
echo "  Kernel version: ${KERNEL_VERSION}"
echo "  Outputs in:     output/${TARGET_NAME}/"
echo "    bzImage"
echo "    config"
echo "    System.map"
echo "    modules-${KERNEL_VERSION}.tar.zst"
echo "    manifest.txt"
echo "    SHA256SUMS"
echo "    version.txt"
echo ""
