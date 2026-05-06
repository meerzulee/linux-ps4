#!/usr/bin/env bash
# Reconfigure USB to match the PS4 Linux community standard layout:
#   sda1 FAT32   bzImage + initramfs.cpio.gz (better-initramfs, External HDD variant)
#   sda2 ext4    label "psxitarch" (rescue shell mounts by label)
#
# Drops bootargs.txt + config from FAT32 (better-initramfs has its own cmdline).
# Relabels sda2 from ARCHROOT to psxitarch.
# Run as root: sudo bash prepare-usb-standard-layout.sh

set -euo pipefail

TARGET_DEV="${TARGET_DEV:-/dev/sda}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_OUT="$PROJECT_ROOT/output/5.4-baikal"
INITRAMFS_ZIP="/tmp/ps4-linux-tutorial/PS4 Linux/initramfs.zip"
TMP_EXTRACT=$(mktemp -d)
BOOT_MNT="/mnt/ps4boot"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -b "$TARGET_DEV" ]] || die "$TARGET_DEV not a block device"
[[ -f "$INITRAMFS_ZIP" ]] || die "Missing $INITRAMFS_ZIP — clone DionKill/ps4-linux-tutorial first"
[[ -f "$KERNEL_OUT/bzImage" ]] || die "Missing $KERNEL_OUT/bzImage"
command -v unzip >/dev/null || die "Need unzip: pacman -S --needed unzip"

# Resolve partition names
if [[ "$TARGET_DEV" == *[0-9] ]]; then
  P1="${TARGET_DEV}p1"; P2="${TARGET_DEV}p2"
else
  P1="${TARGET_DEV}1";  P2="${TARGET_DEV}2"
fi

# Make sure nothing's mounted
for p in "$P1" "$P2"; do
  if mountpoint -q "$(findmnt -no TARGET "$p" 2>/dev/null || echo /__never__)"; then
    log "Unmounting $p"
    umount "$p" || true
  fi
done

cleanup() {
  mountpoint -q "$BOOT_MNT" && umount "$BOOT_MNT" || true
  rmdir "$BOOT_MNT" 2>/dev/null || true
  rm -rf "$TMP_EXTRACT" || true
}
trap cleanup EXIT

# Extract External HDD initramfs from the zip
log "Extracting better-initramfs (External HDD) from $INITRAMFS_ZIP"
unzip -j -o "$INITRAMFS_ZIP" "initramfs/External HDD/initramfs.cpio.gz" -d "$TMP_EXTRACT"
[[ -s "$TMP_EXTRACT/initramfs.cpio.gz" ]] || die "Extraction produced empty file"
ls -la "$TMP_EXTRACT/initramfs.cpio.gz"

# Mount FAT32, refresh contents
log "Mounting $P1 (FAT32) at $BOOT_MNT"
mkdir -p "$BOOT_MNT"
mount "$P1" "$BOOT_MNT"

log "Cleaning old files from FAT32"
rm -fv "$BOOT_MNT/bootargs.txt" "$BOOT_MNT/config" "$BOOT_MNT/initramfs.cpio.gz" "$BOOT_MNT/initramfs-ps4.img"

log "Copying bzImage + initramfs.cpio.gz to FAT32"
cp -v "$KERNEL_OUT/bzImage" "$BOOT_MNT/bzImage"
cp -v "$TMP_EXTRACT/initramfs.cpio.gz" "$BOOT_MNT/initramfs.cpio.gz"

log "FAT32 contents:"
ls -la "$BOOT_MNT"

sync
umount "$BOOT_MNT"
rmdir "$BOOT_MNT"

# Relabel ext4
log "Relabeling $P2 ext4: ARCHROOT -> psxitarch"
e2label "$P2" psxitarch
NEW_LABEL=$(blkid -s LABEL -o value "$P2")
[[ "$NEW_LABEL" == "psxitarch" ]] || die "Relabel failed (got '$NEW_LABEL')"
log "ext4 label is now: $NEW_LABEL"

# Final state
log "Final partition table:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID "$TARGET_DEV"

log "Done. Boot the PS4 with the 1GB VRAM Linux payload from PSFree-Enhanced."
log "Expected outcome:"
log "  - kexec jumps into bzImage"
log "  - kernel mounts initramfs.cpio.gz, runs /init"
log "  - lands in better-initramfs rescue shell prompt"
log "  - type 'resume-boot' to pivot to the installed Arch on $P2"
