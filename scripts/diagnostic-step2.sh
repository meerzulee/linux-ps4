#!/usr/bin/env bash
# Diagnostic step 2: verbose bootargs + freeze-on-panic so we can read the
# death screen. Keeps feeRnt 5.4 Clang bzImage + initramfs.
set -euo pipefail

P1="${P1:-/dev/sda1}"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "[x] Run as root"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

cat > "$MNT/bootargs.txt" <<'EOF'
console=tty0 console=ttyS0,115200n8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
EOF

echo "=== bootargs.txt ==="
cat "$MNT/bootargs.txt"
echo
echo "=== FAT32 contents ==="
ls -la "$MNT"

sync
umount "$MNT"
rmdir "$MNT"
echo "[+] Verbose / freeze-on-panic bootargs written."
