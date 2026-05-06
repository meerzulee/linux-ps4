#!/usr/bin/env bash
# Active bzImage ← our self-built 5.4 (the one that boots + WiFi).
# Restore earlycon in bootargs.
set -euo pipefail

P1="${P1:-/dev/sda1}"
SRC="/home/meerzulee/Work/ps4/linux-ps4/output/5.4-baikal/bzImage"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"
echo "=== before ==="
ls -la "$MNT"

cp -v "$SRC" "$MNT/bzImage"

# Restore the bootargs known to work end-to-end with our 5.4.
cat > "$MNT/bootargs.txt" <<'EOF'
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
EOF

echo
echo "=== after ==="
ls -la "$MNT"
echo "bootargs:"
cat "$MNT/bootargs.txt"
sync
umount "$MNT"
rmdir "$MNT"
echo
echo "[+] Active = our self-built 5.4 (boots, WiFi works, SSH works)."
