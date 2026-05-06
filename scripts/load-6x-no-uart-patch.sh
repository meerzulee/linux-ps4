#!/usr/bin/env bash
# Active bzImage ← our 6.x build (rebuilt WITHOUT the bpcie-uart patch,
# for the A/B test). Bootargs keep earlycon for early-boot UART.
set -euo pipefail

P1="${P1:-/dev/sda1}"
SRC="/home/meerzulee/Work/ps4/linux-ps4/output/6.x-baikal/bzImage"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -f "$SRC" ]] || { echo "Missing $SRC"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

echo "=== before ==="
ls -la "$MNT"

cp -v "$SRC" "$MNT/bzImage"

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
echo "[+] Active = our 6.x WITHOUT bpcie-uart patch."
echo "    Backups on USB still: bzImage-5.4-feeRnt, bzImage-5.4-ours, bzImage-prev"
