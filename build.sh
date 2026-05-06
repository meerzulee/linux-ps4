#!/bin/bash
#
# PS4 Linux Baikal Kernel Build Script
#
# Multi-target: each target lives in targets/<name>.env and defines the
# kernel base, branch/tag, config, and patch series. Build with:
#
#   ./build.sh                 # default target (5.4-baikal)
#   ./build.sh -t 6.x-baikal   # alternate target
#
# See README.md and BUILD_LOG.md for details.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    -t, --target NAME   Target to build (default: 5.4-baikal)
                        Available: ${available}
    -c, --clean         Clean build (remove src and rebuild)
    -u, --update        Update base kernel from upstream
    -p, --patches-only  Only apply patches (don't build)
    -n, --no-patches    Build without applying patches
    -j, --jobs N        Number of parallel jobs (default: 80% of cores)
    -h, --help          Show this help

Examples:
    $0                          # build default (5.4-baikal)
    $0 -t 6.x-baikal            # build 6.x-baikal
    $0 -t 5.4-baikal -c         # clean rebuild of 5.4 target
    $0 -t 5.4-baikal -j 8       # 8 parallel jobs

EOF
    exit 0
}

# Defaults
TARGET="5.4-baikal"
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
SRC_DIR="${SCRIPT_DIR}/src/${TARGET_NAME}"
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
    rm -rf "${OUTPUT_DIR}"
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
            log_warn "Patch file not found: ${line}"
            PATCH_SKIPPED=$((PATCH_SKIPPED + 1))
            continue
        fi

        if patch -p1 --dry-run --reverse --force --silent \
            < "${patch_file}" >/dev/null 2>&1; then
            log_warn "Already applied, skipping: ${line}"
            PATCH_SKIPPED=$((PATCH_SKIPPED + 1))
            continue
        fi

        if patch -p1 --forward --silent < "${patch_file}" 2>/dev/null; then
            log_info "Applied: ${line}"
            PATCH_COUNT=$((PATCH_COUNT + 1))
        elif patch -p1 --forward --fuzz=3 < "${patch_file}" 2>/dev/null; then
            log_warn "Applied with fuzz: ${line}"
            PATCH_COUNT=$((PATCH_COUNT + 1))
        else
            log_error "FAILED: ${line}"
            PATCH_FAILED=$((PATCH_FAILED + 1))
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

# Step 3: configure
log_step "=== Step 3: Configuring kernel ==="
if [ -f "${CONFIG_FILE}" ]; then
    log_info "Using config: ${CONFIG_FILE#${SCRIPT_DIR}/}"
    cp "${CONFIG_FILE}" .config
else
    log_warn "Config not found, falling back to defconfig"
    make defconfig
fi

# Apply fragments
if [ -d "${SCRIPT_DIR}/config/fragments" ]; then
    for fragment in "${SCRIPT_DIR}/config/fragments"/*.config; do
        [ -f "${fragment}" ] || continue
        log_info "Merging fragment: $(basename "${fragment}")"
        ./scripts/kconfig/merge_config.sh -m .config "${fragment}" 2>/dev/null \
            || cat "${fragment}" >> .config
    done
fi

log_info "Resolving config dependencies..."
make olddefconfig

# Step 4: build
log_step "=== Step 4: Building kernel ==="

MAKE_ARGS=("-j${JOBS}")
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
cp System.map "${OUTPUT_DIR}/" 2>/dev/null || true

KERNEL_VERSION=$(make kernelrelease)
echo "${KERNEL_VERSION}" > "${OUTPUT_DIR}/version.txt"

echo ""
echo "=============================================================="
log_info "BUILD COMPLETE  —  ${TARGET_NAME}"
echo "=============================================================="
echo "  Kernel version: ${KERNEL_VERSION}"
echo "  Outputs in:     output/${TARGET_NAME}/"
echo "    bzImage"
echo "    config"
echo "    version.txt"
echo ""
echo "Install modules with:"
echo "  cd src/${TARGET_NAME} && make INSTALL_MOD_PATH=../../output/${TARGET_NAME}/modules modules_install"
echo ""
