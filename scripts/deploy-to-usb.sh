#!/bin/bash
#
# PS4 Linux - Deploy to USB Drive
# Build #4 - 2026-03-16
#
# This script:
# 1. Formats USB (1GB FAT32 boot + rest EXT4)
# 2. Copies boot files (bzImage, initramfs, bootargs)
# 3. Extracts Arch Linux rootfs
# 4. Installs kernel modules + firmware
# 5. Sets up /etc/hosts for the rootfs
#
# Usage: sudo ./deploy-to-usb.sh /dev/sdX
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
OUTPUT_DIR="${PROJECT_DIR}/output"
ATTEMPT_DIR="${OUTPUT_DIR}/attempt-004-2026-03-16"

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

if [ -z "$DEVICE" ]; then
    echo "PS4 Linux USB Deployment Script - Build #4"
    echo ""
    echo "Usage: sudo $0 <device>"
    echo ""
    echo "Example: sudo $0 /dev/sdb"
    echo ""
    echo "This will ERASE ALL DATA on the device and install:"
    echo "  Partition 1: 1GB FAT32 (boot) - kernel, initramfs, bootargs"
    echo "  Partition 2: Rest EXT4 (rootfs) - Arch Linux + XFCE4"
    echo ""
    echo "Required files in ${ATTEMPT_DIR}/:"
    echo "  bzImage, initramfs.cpio.gz, bootargs.txt"
    echo "Required files in ${OUTPUT_DIR}/:"
    echo "  ps4linux.tar.xz (rootfs)"
    echo ""
    exit 1
fi

# Verify required files exist
for f in "${ATTEMPT_DIR}/bzImage" "${ATTEMPT_DIR}/initramfs.cpio.gz" "${ATTEMPT_DIR}/bootargs.txt" "${OUTPUT_DIR}/ps4linux.tar.xz"; do
    if [ ! -f "$f" ]; then
        log_error "Missing required file: $f"
        exit 1
    fi
done

echo ""
echo "=============================================="
echo "  PS4 Linux USB Deployment - Build #4"
echo "  2026-03-16"
echo "=============================================="
echo ""
echo "Device: $DEVICE"
echo "Kernel: $(cat ${ATTEMPT_DIR}/version.txt 2>/dev/null || echo 'unknown')"
echo ""

# Safety
if [ ! -b "$DEVICE" ]; then
    log_error "$DEVICE is not a block device!"
    exit 1
fi

log_warn "This will ERASE ALL DATA on $DEVICE!"
read -p "Type 'YES' to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 0
fi

# Step 1: Partition
log_step "Step 1/7: Partitioning USB drive..."
# Unmount if mounted
for part in $(mount | grep "$DEVICE" | awk '{print $1}'); do
    umount "$part" 2>/dev/null || true
done

parted -s "$DEVICE" mklabel msdos
parted -s "$DEVICE" mkpart primary fat32 1MiB 1GiB
parted -s "$DEVICE" set 1 boot on
parted -s "$DEVICE" mkpart primary ext4 1GiB 100%
sleep 2
partprobe "$DEVICE" 2>/dev/null || true
sleep 1

# Determine partition names
if [ -b "${DEVICE}1" ]; then
    BOOT_PART="${DEVICE}1"
    ROOT_PART="${DEVICE}2"
elif [ -b "${DEVICE}p1" ]; then
    BOOT_PART="${DEVICE}p1"
    ROOT_PART="${DEVICE}p2"
else
    log_error "Cannot find partitions!"
    exit 1
fi

# Step 2: Format
log_step "Step 2/7: Formatting partitions..."
mkfs.vfat -F 32 -n "PS4BOOT" "$BOOT_PART"
mkfs.ext4 -L "psxitarch" -F "$ROOT_PART"

# Step 3: Mount
log_step "Step 3/7: Mounting partitions..."
mkdir -p /mnt/ps4boot /mnt/ps4root
mount "$BOOT_PART" /mnt/ps4boot
mount "$ROOT_PART" /mnt/ps4root

# Step 4: Copy boot files
log_step "Step 4/7: Copying boot files to FAT32..."
cp "${ATTEMPT_DIR}/bzImage" /mnt/ps4boot/
cp "${ATTEMPT_DIR}/initramfs.cpio.gz" /mnt/ps4boot/
cp "${ATTEMPT_DIR}/bootargs.txt" /mnt/ps4boot/
# Also copy minimal bootargs for later
cp "${ATTEMPT_DIR}/bootargs-minimal.txt" /mnt/ps4boot/ 2>/dev/null || true
log_info "Boot files: $(ls /mnt/ps4boot/)"

# Step 5: Extract rootfs
log_step "Step 5/7: Extracting Arch Linux rootfs (this takes a while)..."
tar -xJpf "${OUTPUT_DIR}/ps4linux.tar.xz" -C /mnt/ps4root/
log_info "Rootfs extracted"

# Step 6: Install modules + firmware
log_step "Step 6/7: Installing kernel modules and firmware..."
if [ -f "${ATTEMPT_DIR}/modules-firmware-overlay.tar.xz" ]; then
    tar -xJpf "${ATTEMPT_DIR}/modules-firmware-overlay.tar.xz" -C /mnt/ps4root/
    log_info "Modules and firmware installed"
else
    log_warn "No modules overlay found, skipping"
fi

# Set up /etc/hosts in rootfs (Docker couldn't do this during build)
echo "127.0.0.1 localhost" > /mnt/ps4root/etc/hosts
echo "127.0.1.1 ps4-linux" >> /mnt/ps4root/etc/hosts
echo "::1 localhost" >> /mnt/ps4root/etc/hosts

# Step 7: Sync and unmount
log_step "Step 7/7: Syncing and unmounting..."
sync
umount /mnt/ps4boot
umount /mnt/ps4root

echo ""
echo "=============================================="
log_info "DEPLOYMENT COMPLETE!"
echo "=============================================="
echo ""
echo "USB Drive: $DEVICE"
echo "  Boot (FAT32):  $BOOT_PART (1GB)"
echo "  Rootfs (EXT4): $ROOT_PART"
echo ""
echo "Boot files:"
echo "  bzImage - Kernel 6.15.4"
echo "  initramfs.cpio.gz - Custom initramfs with UART debug"
echo "  bootargs.txt - Debug boot (UART + HDMI + initcall_debug)"
echo "  bootargs-minimal.txt - Normal boot (swap when stable)"
echo ""
echo "Credentials:"
echo "  User: ps4 / ps4"
echo "  Root: root / root"
echo ""
echo "UART Debug: Connect serial terminal at 115200 8N1"
echo ""
echo "Next steps:"
echo "  1. Plug USB into PS4"
echo "  2. Connect UART serial adapter"
echo "  3. Run exploit with ps4-payload-guest"
echo "  4. Watch UART output for boot log"
echo ""
