#!/usr/bin/env bash
# Roll the active bzImage back to feeRnt's known-working prebuilt.
# Keeps both backups on USB for future swap-in-place over SSH.
set -euo pipefail

P1="${P1:-/dev/sda1}"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

echo "=== before ==="
ls -la "$MNT"

if [[ ! -f "$MNT/bzImage-5.4-feeRnt" ]]; then
  echo "[!] No backup on USB — copying from project tree"
  cp -v /home/meerzulee/Work/ps4/linux-ps4/output/feeRnt-prebuilt/bzImage_Clang "$MNT/bzImage-5.4-feeRnt"
fi

# Save whatever's currently active as bzImage-prev (in case we want it back)
if [[ -f "$MNT/bzImage" ]] && ! cmp -s "$MNT/bzImage" "$MNT/bzImage-5.4-feeRnt"; then
  cp -v "$MNT/bzImage" "$MNT/bzImage-prev"
fi

cp -v "$MNT/bzImage-5.4-feeRnt" "$MNT/bzImage"

echo
echo "=== after ==="
ls -la "$MNT"

sync
umount "$MNT"
rmdir "$MNT"
echo
echo "[+] feeRnt 5.4 prebuilt is the active boot. Modules from our self-built kernel"
echo "    remain installed in the rootfs (they're version-tagged so they coexist)."
