#!/usr/bin/env bash
# Recover from a hung kernel test. Run on the HOST with USB plugged in.
#
# Usage:
#   sudo bash scripts/dev/rollback-kernel.sh           # restore bzImage-stable
#   sudo bash scripts/dev/rollback-kernel.sh --to-prev # restore bzImage-prev
set -euo pipefail

USB_DEV="${USB_DEV:-/dev/sda1}"
MNT="/mnt/ps4boot"
target="stable"
[[ "${1:-}" == "--to-prev" ]] && target="prev"

[[ $EUID -eq 0 ]] || { echo "Run as root: sudo bash $0"; exit 1; }
[[ -b "$USB_DEV" ]] || { echo "$USB_DEV not a block device — is the USB plugged in?"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$USB_DEV" "$MNT"

src="$MNT/bzImage-${target}"
[[ -f "$src" ]] || { umount "$MNT"; rmdir "$MNT"; echo "[x] No $src on USB to roll back to."; exit 1; }

echo "=== Before rollback ==="
ls -la "$MNT" | grep -E 'bzImage'
echo
echo "=== Rolling bzImage ← bzImage-${target} ==="
cp -v "$src" "$MNT/bzImage"
[[ -f "$MNT/.last-test" ]] && cat "$MNT/.last-test" >&2
echo
echo "=== After rollback ==="
ls -la "$MNT" | grep -E 'bzImage'
sync
umount "$MNT"
rmdir "$MNT"
echo
echo "[+] Done. Replug USB into PS4 → load linux-1024mb.bin via PSFree."
