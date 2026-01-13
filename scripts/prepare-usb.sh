#!/bin/bash
#
# Prepare USB drive for PS4 Linux
# Creates FAT32 boot partition + EXT4 rootfs partition
#

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."

# Default values
BOOT_SIZE="100M"  # 100MB for boot partition (plenty of room)
ROOTFS_LABEL="psxitarch"

usage() {
    cat << EOF
Prepare USB drive for PS4 Linux

Usage: $0 <device> [options]

Arguments:
    device          USB device (e.g., /dev/sdb) - BE CAREFUL!

Options:
    -b, --boot-size SIZE    Boot partition size (default: 100M)
    -l, --label LABEL       Rootfs partition label (default: psxitarch)
    -h, --help              Show this help

Example:
    $0 /dev/sdb
    $0 /dev/sdb -b 200M -l ps4linux

WARNING: This will ERASE ALL DATA on the specified device!

EOF
    exit 1
}

# Parse arguments
DEVICE=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -b|--boot-size) BOOT_SIZE="$2"; shift 2 ;;
        -l|--label) ROOTFS_LABEL="$2"; shift 2 ;;
        -h|--help) usage ;;
        -*) log_error "Unknown option: $1"; usage ;;
        *) DEVICE="$1"; shift ;;
    esac
done

if [ -z "$DEVICE" ]; then
    log_error "No device specified!"
    echo ""
    echo "Available block devices:"
    lsblk -d -o NAME,SIZE,MODEL | grep -v "loop\|sr"
    echo ""
    usage
fi

# Safety checks
if [ ! -b "$DEVICE" ]; then
    log_error "$DEVICE is not a block device!"
    exit 1
fi

# Check if it's an NVMe drive (likely system drive)
if [[ "$DEVICE" == *"nvme"* ]]; then
    log_error "Refusing to format $DEVICE - NVMe drives are likely system drives!"
    exit 1
fi

# Check if device is USB (safe to format)
DEVICE_NAME=$(basename "$DEVICE")
TRANSPORT=$(lsblk -d -o TRAN "$DEVICE" 2>/dev/null | tail -1)
if [[ "$TRANSPORT" != "usb" ]]; then
    log_warn "Device $DEVICE does not appear to be USB (transport: $TRANSPORT)"
    read -p "Are you SURE you want to format this device? Type 'FORCE' to continue: " force_confirm
    if [ "$force_confirm" != "FORCE" ]; then
        log_info "Aborted."
        exit 0
    fi
fi

# Check if device is mounted
if mount | grep -q "$DEVICE"; then
    log_warn "Device $DEVICE has mounted partitions. Unmounting..."
    for part in $(mount | grep "$DEVICE" | awk '{print $1}'); do
        sudo umount "$part" || true
    done
fi

echo ""
echo "=============================================="
echo "  PS4 Linux USB Drive Preparation"
echo "=============================================="
echo ""
echo "Device:     $DEVICE"
echo "Boot size:  $BOOT_SIZE"
echo "Label:      $ROOTFS_LABEL"
echo ""
lsblk "$DEVICE"
echo ""

log_warn "This will ERASE ALL DATA on $DEVICE!"
read -p "Are you sure? Type 'YES' to continue: " confirm
if [ "$confirm" != "YES" ]; then
    log_info "Aborted."
    exit 0
fi

# Step 1: Create partition table
log_info "Creating msdos partition table..."
sudo parted -s "$DEVICE" mklabel msdos

# Step 2: Create boot partition (FAT32)
log_info "Creating boot partition (${BOOT_SIZE}, FAT32)..."
sudo parted -s "$DEVICE" mkpart primary fat32 1MiB "$BOOT_SIZE"
sudo parted -s "$DEVICE" set 1 boot on

# Step 3: Create rootfs partition (EXT4)
log_info "Creating rootfs partition (remaining space, EXT4)..."
sudo parted -s "$DEVICE" mkpart primary ext4 "$BOOT_SIZE" 100%

# Wait for kernel to recognize partitions
sleep 2
sudo partprobe "$DEVICE"
sleep 1

# Determine partition names (handles both /dev/sdX1 and /dev/sdXp1 formats)
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

# Step 4: Format partitions
log_info "Formatting boot partition as FAT32..."
sudo mkfs.vfat -F 32 -n "PS4BOOT" "$BOOT_PART"

log_info "Formatting rootfs partition as EXT4..."
sudo mkfs.ext4 -L "$ROOTFS_LABEL" "$ROOT_PART"

echo ""
log_info "USB drive prepared successfully!"
echo ""
lsblk "$DEVICE"
echo ""
echo "Partitions:"
echo "  Boot (FAT32):  $BOOT_PART"
echo "  Rootfs (EXT4): $ROOT_PART (label: $ROOTFS_LABEL)"
echo ""
echo "Next steps:"
echo "  1. Mount the partitions:"
echo "     sudo mkdir -p /mnt/ps4boot /mnt/ps4root"
echo "     sudo mount $BOOT_PART /mnt/ps4boot"
echo "     sudo mount $ROOT_PART /mnt/ps4root"
echo ""
echo "  2. Copy boot files:"
echo "     sudo cp ${PROJECT_DIR}/output/bzImage /mnt/ps4boot/"
echo "     sudo cp <initramfs.cpio.gz> /mnt/ps4boot/"
echo "     # Create bootargs.txt with boot parameters"
echo ""
echo "  3. Extract rootfs:"
echo "     sudo tar -xvJpf <archlinux.tar.xz> -C /mnt/ps4root"
echo ""
echo "  4. Unmount:"
echo "     sudo umount /mnt/ps4boot /mnt/ps4root"
echo ""
