#!/usr/bin/env bash
# Diagnostic step 1: swap to feeRnt's known-good 5.4 Clang-14 prebuilt
# while keeping the v24b clean bootargs + initramfs.
# Confirms whether the kernel image is the variable.
set -euo pipefail

P1="${P1:-/dev/sda1}"
SRC="/home/meerzulee/Work/ps4/linux-ps4/output/feeRnt-prebuilt/bzImage_Clang"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "[x] Run as root"; exit 1; }
[[ -f "$SRC" ]] || { echo "[x] Missing $SRC"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

echo "=== BEFORE ==="
ls -la "$MNT"
echo
[[ -f "$MNT/bootargs.txt" ]] && { echo "bootargs.txt:"; cat "$MNT/bootargs.txt"; echo; }
[[ -f "$MNT/vram.txt" ]] && { echo "vram.txt:"; cat "$MNT/vram.txt"; echo; }

cp -v "$SRC" "$MNT/bzImage"

echo
echo "=== AFTER ==="
ls -la "$MNT"
sync
umount "$MNT"
rmdir "$MNT"
echo "[+] 5.4 Clang prebuilt staged. Boot and watch UART."
