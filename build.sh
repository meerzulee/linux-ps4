#!/bin/bash
#
# PS4 Linux 6.x Baikal Kernel Build Script
# Builds kernel by applying patches on top of crashniels' base
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SCRIPT_DIR}/src/linux"
OUTPUT_DIR="${SCRIPT_DIR}/output"
PATCHES_DIR="${SCRIPT_DIR}/patches"
CONFIG_DIR="${SCRIPT_DIR}/config"

# Configuration
BASE_REPO="https://github.com/crashniels/linux.git"
BASE_BRANCH="ps4-linux-6.15.y-baikal"
CONFIG_FILE="${CONFIG_DIR}/config.baikal-b1"
SERIES_FILE="${PATCHES_DIR}/series"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

usage() {
    cat << EOF
PS4 Linux 6.x Baikal Kernel Build Script

Usage: $0 [OPTIONS]

Options:
    -c, --clean         Clean build (remove src and rebuild)
    -u, --update        Update base kernel from upstream
    -p, --patches-only  Only apply patches (don't build)
    -n, --no-patches    Build without applying patches
    -j, --jobs N        Number of parallel jobs (default: $(nproc))
    -C, --config FILE   Use specific config file
    -s, --series FILE   Use specific series file
    -h, --help          Show this help

Examples:
    $0                  # Normal build
    $0 -c               # Clean build from scratch
    $0 -u               # Update base kernel and rebuild
    $0 -j 8             # Build with 8 parallel jobs
    $0 -p               # Only apply patches, don't compile

EOF
    exit 0
}

# Parse arguments
CLEAN=false
UPDATE=false
PATCHES_ONLY=false
NO_PATCHES=false
# Use 80% of CPU cores by default
JOBS=$(($(nproc) * 80 / 100))
[ "$JOBS" -lt 1 ] && JOBS=1

while [[ $# -gt 0 ]]; do
    case $1 in
        -c|--clean) CLEAN=true; shift ;;
        -u|--update) UPDATE=true; shift ;;
        -p|--patches-only) PATCHES_ONLY=true; shift ;;
        -n|--no-patches) NO_PATCHES=true; shift ;;
        -j|--jobs) JOBS="$2"; shift 2 ;;
        -C|--config) CONFIG_FILE="$2"; shift 2 ;;
        -s|--series) SERIES_FILE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

echo ""
echo "=============================================="
echo "  PS4 Linux 6.x Baikal Kernel Builder"
echo "=============================================="
echo ""

# Clean build if requested
if [ "$CLEAN" = true ]; then
    log_step "Cleaning build directory..."
    rm -rf "${SRC_DIR}"
    rm -rf "${OUTPUT_DIR}"/*
fi

# Create output directory
mkdir -p "${OUTPUT_DIR}"

# Step 1: Clone or update base kernel
log_step "=== Step 1: Preparing base kernel ==="

if [ ! -d "${SRC_DIR}" ]; then
    log_info "Cloning base kernel from crashniels..."
    log_info "Repo: ${BASE_REPO}"
    log_info "Branch: ${BASE_BRANCH}"
    git clone --depth=50 "${BASE_REPO}" --branch "${BASE_BRANCH}" "${SRC_DIR}"
elif [ "$UPDATE" = true ]; then
    log_info "Updating base kernel..."
    cd "${SRC_DIR}"
    # Reset any local changes
    git checkout .
    git clean -fd
    git fetch origin "${BASE_BRANCH}"
    git reset --hard "origin/${BASE_BRANCH}"
    cd "${SCRIPT_DIR}"
else
    log_info "Using existing source tree at ${SRC_DIR}"
fi

# Step 2: Apply patches
log_step "=== Step 2: Applying patches ==="

cd "${SRC_DIR}"

# Reset source tree to clean state
log_info "Resetting source tree to clean state..."
git checkout . 2>/dev/null || true
git clean -fd 2>/dev/null || true

if [ "$NO_PATCHES" = false ] && [ -f "${SERIES_FILE}" ]; then
    PATCH_COUNT=0
    PATCH_FAILED=0
    PATCH_SKIPPED=0
    
    while IFS= read -r line || [ -n "$line" ]; do
        # Skip comments and empty lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        
        patch_file="${PATCHES_DIR}/${line}"
        
        if [ -f "$patch_file" ]; then
            # Check if patch is already applied
            if patch -p1 --dry-run --reverse --force --silent < "$patch_file" 2>/dev/null; then
                log_warn "Already applied, skipping: ${line}"
                ((PATCH_SKIPPED++))
                continue
            fi
            
            # Try to apply patch
            if patch -p1 --forward --silent < "$patch_file" 2>/dev/null; then
                log_info "Applied: ${line}"
                ((PATCH_COUNT++))
            else
                # Try with fuzz
                if patch -p1 --forward --fuzz=3 < "$patch_file" 2>/dev/null; then
                    log_warn "Applied with fuzz: ${line}"
                    ((PATCH_COUNT++))
                else
                    log_error "FAILED: ${line}"
                    ((PATCH_FAILED++))
                fi
            fi
        else
            log_warn "Patch file not found: ${patch_file}"
            ((PATCH_SKIPPED++))
        fi
    done < "${SERIES_FILE}"
    
    echo ""
    log_info "Patch Summary:"
    log_info "  Applied: ${PATCH_COUNT}"
    log_info "  Skipped: ${PATCH_SKIPPED}"
    if [ $PATCH_FAILED -gt 0 ]; then
        log_error "  Failed:  ${PATCH_FAILED}"
        echo ""
        log_error "Some patches failed to apply!"
        log_error "Please check the patches and fix conflicts."
        exit 1
    fi
else
    if [ "$NO_PATCHES" = true ]; then
        log_info "Patch application disabled (--no-patches)"
    else
        log_info "No series file found at ${SERIES_FILE}"
        log_info "Building base kernel without additional patches"
    fi
fi

if [ "$PATCHES_ONLY" = true ]; then
    echo ""
    log_info "Patches applied successfully!"
    log_info "Exiting (--patches-only mode)"
    exit 0
fi

# Step 3: Configure kernel
log_step "=== Step 3: Configuring kernel ==="

if [ -f "${CONFIG_FILE}" ]; then
    log_info "Using config: ${CONFIG_FILE}"
    cp "${CONFIG_FILE}" .config
elif [ -f "${SRC_DIR}/config" ]; then
    log_info "Using config from source tree"
    cp config .config
else
    log_warn "No config file found!"
    log_info "Generating default config..."
    make defconfig
fi

# Apply config fragments
if [ -d "${CONFIG_DIR}/fragments" ]; then
    for fragment in "${CONFIG_DIR}/fragments"/*.config; do
        if [ -f "$fragment" ]; then
            log_info "Merging config fragment: $(basename $fragment)"
            ./scripts/kconfig/merge_config.sh -m .config "$fragment" 2>/dev/null || \
                cat "$fragment" >> .config
        fi
    done
fi

# Resolve config dependencies
log_info "Resolving config dependencies..."
make olddefconfig

# Step 4: Build kernel
log_step "=== Step 4: Building kernel ==="
log_info "Parallel jobs: ${JOBS}"

# Compiler settings
if command -v gcc-11 &> /dev/null; then
    export CC=gcc-11
    export HOSTCC=gcc-11
    log_info "Compiler: GCC 11"
else
    log_info "Compiler: $(gcc --version | head -1)"
fi

echo ""
log_info "Building bzImage..."
make -j${JOBS} bzImage

echo ""
log_info "Building modules..."
make -j${JOBS} modules

# Step 5: Copy outputs
log_step "=== Step 5: Collecting build artifacts ==="

cp arch/x86/boot/bzImage "${OUTPUT_DIR}/"
cp .config "${OUTPUT_DIR}/config"
cp System.map "${OUTPUT_DIR}/" 2>/dev/null || true

# Get kernel version
KERNEL_VERSION=$(make kernelrelease)
echo "${KERNEL_VERSION}" > "${OUTPUT_DIR}/version.txt"

echo ""
echo "=============================================="
log_info "BUILD COMPLETE!"
echo "=============================================="
echo ""
echo "Kernel Version: ${KERNEL_VERSION}"
echo ""
echo "Output files:"
echo "  ${OUTPUT_DIR}/bzImage"
echo "  ${OUTPUT_DIR}/config"
echo "  ${OUTPUT_DIR}/version.txt"
echo ""
echo "To install modules to a directory:"
echo "  cd ${SRC_DIR}"
echo "  make INSTALL_MOD_PATH=${OUTPUT_DIR}/modules modules_install"
echo ""
echo "To test on PS4:"
echo "  1. Copy bzImage to FAT32 USB partition"
echo "  2. Add initramfs.cpio.gz and bootargs.txt"
echo "  3. Boot PS4 with Linux payload"
echo ""
