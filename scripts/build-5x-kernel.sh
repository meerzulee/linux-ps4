#!/bin/bash
#
# Build Linux 5.x kernels for PS4 (requires -std=gnu11 for modern GCC)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
OUTPUT_DIR="${PROJECT_DIR}/output"

# Default to whitehax0r 5.4 kernel
KERNEL_DIR="${1:-${PROJECT_DIR}/tmp/whitehax0r-5.4-baikal}"
JOBS="${2:-12}"

if [ ! -d "${KERNEL_DIR}" ]; then
    echo "ERROR: Kernel directory not found: ${KERNEL_DIR}"
    echo "Usage: $0 [kernel_dir] [jobs]"
    exit 1
fi

echo "=============================================="
echo "  PS4 Linux 5.x Kernel Builder"
echo "=============================================="
echo ""
echo "Kernel: ${KERNEL_DIR}"
echo "Jobs: ${JOBS}"
echo ""

cd "${KERNEL_DIR}"

# Check for config file
if [ -f "config" ] && [ ! -f ".config" ]; then
    echo "Copying config file..."
    cp config .config
fi

if [ ! -f ".config" ]; then
    echo "ERROR: No .config found!"
    exit 1
fi

# Disable built-in firmware (causes issues)
sed -i 's/CONFIG_EXTRA_FIRMWARE=.*/CONFIG_EXTRA_FIRMWARE=""/' .config
sed -i 's/CONFIG_EXTRA_FIRMWARE_DIR=.*/CONFIG_EXTRA_FIRMWARE_DIR=""/' .config

# Update config
make olddefconfig

# Build with gnu11 standard (required for GCC 14+)
echo ""
echo "Building bzImage with -std=gnu11..."
make CC="gcc -std=gnu11" -j${JOBS} bzImage

# Copy output
KERNEL_VERSION=$(make kernelrelease)
cp arch/x86/boot/bzImage "${OUTPUT_DIR}/bzImage-${KERNEL_VERSION}"

echo ""
echo "=============================================="
echo "BUILD COMPLETE!"
echo "=============================================="
echo ""
echo "Kernel: ${KERNEL_VERSION}"
echo "Output: ${OUTPUT_DIR}/bzImage-${KERNEL_VERSION}"
echo ""
