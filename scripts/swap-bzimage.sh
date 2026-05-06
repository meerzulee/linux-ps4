#!/usr/bin/env bash
# Swap the bzImage on a mounted (or to-be-mounted) PS4BOOT FAT32 partition.
# Usage: sudo bash swap-bzimage.sh <path-to-bzImage>
set -euo pipefail

SRC="${1:?Usage: sudo bash swap-bzimage.sh <path-to-bzImage>}"
TARGET_DEV="${TARGET_DEV:-/dev/sda1}"
MNT="/mnt/ps4boot"

[[ -f "$SRC" ]] || { echo "[x] Missing source: $SRC"; exit 1; }
[[ $EUID -eq 0 ]] || { echo "[x] Run as root"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$TARGET_DEV" "$MNT"

cp -v "$SRC" "$MNT/bzImage"
ls -la "$MNT"
sync
umount "$MNT"
rmdir "$MNT"
echo "[+] Swapped: $(basename "$SRC")"
