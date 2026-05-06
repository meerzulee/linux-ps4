#!/usr/bin/env bash
# Build initramfs.cpio.gz for our 5.4 kernel using mkinitcpio inside the
# Arch chroot we installed on the USB. Also rewrites bootargs.txt.
#
# Run as root: sudo bash build-initramfs-on-usb.sh
# Override device with: TARGET_DEV=/dev/sdb sudo -E bash ...

set -euo pipefail

TARGET_DEV="${TARGET_DEV:-/dev/sda}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_OUT="$PROJECT_ROOT/output/5.4-baikal"
KVER=$(cat "$KERNEL_OUT/version.txt" | tr -d '[:space:]')
MNT="/mnt/ps4root"
BOOT_MNT="$MNT/boot/ps4"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -b "$TARGET_DEV" ]] || die "$TARGET_DEV not a block device"
[[ -n "$KVER" ]] || die "Could not read kernel version from $KERNEL_OUT/version.txt"
log "Kernel version: $KVER"

# Resolve partition names
if [[ "$TARGET_DEV" == *[0-9] ]]; then
  P1="${TARGET_DEV}p1"; P2="${TARGET_DEV}p2"
else
  P1="${TARGET_DEV}1";  P2="${TARGET_DEV}2"
fi
ROOT_UUID=$(blkid -s UUID -o value "$P2")

# Mount
log "Mounting $P2 at $MNT and $P1 at $BOOT_MNT"
mkdir -p "$MNT"
mount "$P2" "$MNT"
mkdir -p "$BOOT_MNT"
mount "$P1" "$BOOT_MNT"

cleanup() {
  log "Cleaning up mounts"
  for m in "$MNT/boot/ps4" "$MNT/dev" "$MNT/proc" "$MNT/sys" "$MNT/run"; do
    mountpoint -q "$m" && umount -l "$m" || true
  done
  mountpoint -q "$MNT" && umount "$MNT" || true
  rmdir "$BOOT_MNT" 2>/dev/null || true
  rmdir "$MNT"      2>/dev/null || true
}
trap cleanup EXIT

# Verify modules dir matches our kernel
if [[ ! -d "$MNT/lib/modules/$KVER" ]]; then
  die "Modules dir $MNT/lib/modules/$KVER missing — re-run install-arch-usb.sh first"
fi

# Make sure mkinitcpio is installed in the chroot
log "Ensuring mkinitcpio is installed in chroot"
if ! arch-chroot "$MNT" /bin/bash -c 'command -v mkinitcpio' >/dev/null; then
  arch-chroot "$MNT" pacman -S --noconfirm --needed mkinitcpio
fi

# Build initramfs in chroot
log "Building initramfs for $KVER (this can take a minute)"
arch-chroot "$MNT" mkinitcpio -k "$KVER" -g "/boot/initramfs-ps4.img"

# Copy to FAT32 with the name the loader expects
log "Copying initramfs to FAT32 as initramfs.cpio.gz"
cp -v "$MNT/boot/initramfs-ps4.img" "$BOOT_MNT/initramfs.cpio.gz"

# Update bootargs.txt
log "Writing bootargs.txt"
cat > "$BOOT_MNT/bootargs.txt" <<EOF
root=UUID=$ROOT_UUID rootfstype=ext4 rw rootwait console=tty0 console=ttyS0,115200n8 panic=15 loglevel=7
EOF
log "bootargs.txt:"
cat "$BOOT_MNT/bootargs.txt"

log "FAT32 contents:"
ls -la "$BOOT_MNT"

sync
log "Done. Unplug and boot."
