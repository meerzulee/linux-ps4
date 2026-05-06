#!/usr/bin/env bash
# Active bzImage ← our 6.x build (with bpcie-uart port.type fix).
# Restore earlycon in bootargs so we have UART for early boot regardless
# of whether console=ttyS4 actually transmits on this hardware.
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
echo "bootargs:"
cat "$MNT/bootargs.txt" 2>/dev/null

# Save current active as backup if not already saved
if [[ -f "$MNT/bzImage" ]] && ! cmp -s "$MNT/bzImage" "$MNT/bzImage-prev" 2>/dev/null; then
  cp -v "$MNT/bzImage" "$MNT/bzImage-prev"
fi

# Active = 6.x
cp -v "$SRC" "$MNT/bzImage"

# Refresh 5.4 backup just in case
if [[ ! -f "$MNT/bzImage-5.4-feeRnt" ]]; then
  cp -v /home/meerzulee/Work/ps4/linux-ps4/output/feeRnt-prebuilt/bzImage_Clang "$MNT/bzImage-5.4-feeRnt"
fi
if [[ ! -f "$MNT/bzImage-5.4-ours" ]] || ! cmp -s "$MNT/bzImage-5.4-ours" /home/meerzulee/Work/ps4/linux-ps4/output/5.4-baikal/bzImage; then
  cp -v /home/meerzulee/Work/ps4/linux-ps4/output/5.4-baikal/bzImage "$MNT/bzImage-5.4-ours"
fi

# Bootargs: earlycon + console=tty0 + console=ttyS4 (try both — earlycon
# we know works, ttyS4 might work post-patch)
cat > "$MNT/bootargs.txt" <<'EOF'
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS4,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
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
echo "[+] 6.x staged with earlycon. Backups on USB:"
echo "    bzImage-5.4-feeRnt   ← rollback to known-working"
echo "    bzImage-5.4-ours     ← our self-built 5.4 (boots, WiFi, SSH)"
echo "    bzImage-prev         ← whatever was active before this swap"
