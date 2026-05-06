#!/usr/bin/env bash
# Phase E debug bootargs — add `keep_bootcon` so earlycon stays alive past
# fbcon takeover. Used to capture what 6.x does after ~0.66 s.
#
# DANGER on 5.4: with `keep_bootcon`, xhci_aeolia crashes at ~57 s due to
# BPCIe bus overload. For 6.x we expect the late-init hang to happen
# WELL before 57 s, so keep_bootcon is safe for the diagnostic window.
set -euo pipefail
P1="${P1:-/dev/sda1}"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

echo "=== old bootargs ==="
cat "$MNT/bootargs.txt"

cat > "$MNT/bootargs.txt" <<'EOF'
earlycon=uart8250,mmio32,0xC890E000,115200n8 keep_bootcon console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
EOF

echo
echo "=== new bootargs (with keep_bootcon) ==="
cat "$MNT/bootargs.txt"
sync
umount "$MNT"
rmdir "$MNT"
echo
echo "[+] keep_bootcon enabled. UART will keep streaming past fbcon takeover."
