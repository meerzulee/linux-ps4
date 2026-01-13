#!/bin/bash
#
# Download required firmware files for PS4 Linux
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW_DIR="${SCRIPT_DIR}/../firmware"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

FIRMWARE_BASE="https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/plain"

echo ""
echo "=============================================="
echo "  Download PS4 Linux Firmware"
echo "=============================================="
echo ""

mkdir -p "${FW_DIR}/mediatek"
mkdir -p "${FW_DIR}/mrvl"

# MediaTek MT7668 (for Baikal B1)
if [ ! -f "${FW_DIR}/mediatek/mt7668pr2h.bin" ]; then
    log_info "Downloading MediaTek MT7668 firmware..."
    wget -q --show-progress -O "${FW_DIR}/mediatek/mt7668pr2h.bin" \
        "${FIRMWARE_BASE}/mediatek/mt7668pr2h.bin" || \
        log_warn "Failed to download mt7668pr2h.bin"
else
    log_info "MediaTek MT7668 firmware already exists"
fi

# Marvell 88w8897 (for CUH-12xx reference)
if [ ! -f "${FW_DIR}/mrvl/sd8897_uapsta.bin" ]; then
    log_info "Downloading Marvell 88w8897 firmware..."
    wget -q --show-progress -O "${FW_DIR}/mrvl/sd8897_uapsta.bin" \
        "${FIRMWARE_BASE}/mrvl/sd8897_uapsta.bin" || \
        log_warn "Failed to download sd8897_uapsta.bin"
else
    log_info "Marvell 88w8897 firmware already exists"
fi

# Marvell 88w8797 (for older models reference)
if [ ! -f "${FW_DIR}/mrvl/sd8797_uapsta.bin" ]; then
    log_info "Downloading Marvell 88w8797 firmware..."
    wget -q --show-progress -O "${FW_DIR}/mrvl/sd8797_uapsta.bin" \
        "${FIRMWARE_BASE}/mrvl/sd8797_uapsta.bin" || \
        log_warn "Failed to download sd8797_uapsta.bin"
else
    log_info "Marvell 88w8797 firmware already exists"
fi

echo ""
log_info "Firmware files downloaded to: ${FW_DIR}"
echo ""
echo "Contents:"
find "${FW_DIR}" -type f -name "*.bin" | while read f; do
    echo "  $(basename $(dirname $f))/$(basename $f) ($(du -h "$f" | cut -f1))"
done

echo ""
echo "To install firmware to system:"
echo "  sudo cp -r ${FW_DIR}/* /lib/firmware/"
echo ""
echo "Or copy to initramfs for boot-time loading."
