#!/bin/bash
#
# Complete PS4 Linux USB Setup Script
# Formats USB, creates Arch rootfs, and copies boot files
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
OUTPUT_DIR="${PROJECT_DIR}/output"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${BLUE}[====]${NC} $1"; }

DEVICE="${1:-}"
ROOTFS_LABEL="psxitarch"

if [ -z "$DEVICE" ]; then
    echo "Usage: $0 <device>"
    echo ""
    echo "Available devices:"
    lsblk -d -o NAME,SIZE,MODEL,TRAN | grep -E "usb|^NAME"
    exit 1
fi

echo ""
echo "=============================================="
echo "  PS4 Linux Complete USB Setup"
echo "=============================================="
echo ""
echo "Device: $DEVICE"
echo ""

# Confirm
log_warn "This will ERASE ALL DATA on $DEVICE!"
read -p "Type 'YES' to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 0
fi

# Step 1: Format USB
log_step "Step 1: Formatting USB drive..."
"${SCRIPT_DIR}/prepare-usb.sh" "$DEVICE"

# Determine partition names
if [ -b "${DEVICE}1" ]; then
    BOOT_PART="${DEVICE}1"
    ROOT_PART="${DEVICE}2"
elif [ -b "${DEVICE}p1" ]; then
    BOOT_PART="${DEVICE}p1"
    ROOT_PART="${DEVICE}p2"
fi

# Step 2: Mount partitions
log_step "Step 2: Mounting partitions..."
sudo mkdir -p /mnt/ps4boot /mnt/ps4root
sudo mount "$BOOT_PART" /mnt/ps4boot
sudo mount "$ROOT_PART" /mnt/ps4root

# Step 3: Download initramfs if needed
log_step "Step 3: Checking initramfs..."
if [ ! -f "${OUTPUT_DIR}/initramfs.cpio.gz" ] || [ $(stat -c%s "${OUTPUT_DIR}/initramfs.cpio.gz" 2>/dev/null || echo 0) -lt 1000 ]; then
    log_info "Downloading initramfs from whitehax0r..."
    curl -L -o "${OUTPUT_DIR}/initramfs.cpio.gz" \
        "https://github.com/whitehax0r/ArchLinux-PS4v2/raw/main/initramfs.cpio.gz"
fi

# Step 4: Check for rootfs or create one
log_step "Step 4: Preparing rootfs..."
if [ -f "${OUTPUT_DIR}/ps4linux.tar.xz" ]; then
    log_info "Using existing rootfs: ${OUTPUT_DIR}/ps4linux.tar.xz"
    ROOTFS_ARCHIVE="${OUTPUT_DIR}/ps4linux.tar.xz"
else
    log_info "Creating Arch Linux rootfs with Docker..."
    "${SCRIPT_DIR}/create-archlinux-rootfs.sh"
    ROOTFS_ARCHIVE="${OUTPUT_DIR}/ps4linux.tar.xz"
fi

# Step 5: Extract rootfs
log_step "Step 5: Extracting rootfs to USB (this takes a while)..."
sudo tar -xJpf "$ROOTFS_ARCHIVE" -C /mnt/ps4root

# Step 6: Copy boot files
log_step "Step 6: Copying boot files..."
if [ -f "${OUTPUT_DIR}/bzImage" ]; then
    sudo cp "${OUTPUT_DIR}/bzImage" /mnt/ps4boot/
    log_info "Copied bzImage"
else
    log_warn "bzImage not found - build kernel first with ./build.sh"
fi

sudo cp "${OUTPUT_DIR}/initramfs.cpio.gz" /mnt/ps4boot/
log_info "Copied initramfs.cpio.gz"

# Step 7: Create bootargs.txt
log_step "Step 7: Creating bootargs.txt..."
cat << EOF | sudo tee /mnt/ps4boot/bootargs.txt
initrd=initramfs.cpio.gz root=/dev/sda2 rootfstype=ext4 rw
EOF

# Step 8: Copy firmware
log_step "Step 8: Copying firmware files..."
sudo mkdir -p /mnt/ps4root/lib/firmware
if [ -d "${PROJECT_DIR}/firmware/mediatek" ]; then
    sudo cp -r "${PROJECT_DIR}/firmware/mediatek" /mnt/ps4root/lib/firmware/
    log_info "Copied MediaTek firmware"
fi
if [ -d "${PROJECT_DIR}/firmware/mrvl" ]; then
    sudo cp -r "${PROJECT_DIR}/firmware/mrvl" /mnt/ps4root/lib/firmware/
    log_info "Copied Marvell firmware"
fi

# Step 9: Sync and unmount
log_step "Step 9: Syncing and unmounting..."
sync
sudo umount /mnt/ps4boot
sudo umount /mnt/ps4root

echo ""
echo "=============================================="
log_info "USB SETUP COMPLETE!"
echo "=============================================="
echo ""
echo "USB Drive: $DEVICE"
echo "  Boot:   $BOOT_PART (FAT32)"
echo "  Rootfs: $ROOT_PART (EXT4, label: $ROOTFS_LABEL)"
echo ""
echo "Boot files:"
echo "  - bzImage (kernel)"
echo "  - initramfs.cpio.gz"
echo "  - bootargs.txt"
echo ""
echo "Credentials (if using Docker-created rootfs):"
echo "  User: ps4 / ps4"
echo "  Root: root / root"
echo ""
echo "Next steps:"
echo "  1. Build the kernel if not done: ./build.sh"
echo "  2. Copy bzImage to USB boot partition"
echo "  3. Plug USB into PS4"
echo "  4. Run PS4 exploit with Linux payload"
echo ""
