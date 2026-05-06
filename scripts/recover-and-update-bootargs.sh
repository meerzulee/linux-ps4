#!/usr/bin/env bash
# Post-xhci-crash recovery: fsck the rootfs ext4 and tighten bootargs to
# avoid bus-overload from keep_bootcon. Keeps earlycon at the corrected
# UART0 address so we still get early-boot UART logs.
set -euo pipefail

P1="${P1:-/dev/sda1}"
P2="${P2:-/dev/sda2}"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

echo "=== ext4 superblock state (before) ==="
dumpe2fs -h "$P2" 2>/dev/null | grep -iE 'state|errors|mount count|filesystem.{0,5}features' | head -8

echo
echo "=== fsck (force, automatic repair) ==="
e2fsck -fy "$P2" || true

echo
echo "=== ext4 superblock state (after) ==="
dumpe2fs -h "$P2" 2>/dev/null | grep -iE 'state|errors|mount count' | head -5

echo
echo "=== updating FAT32 bootargs ==="
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

echo "Old bootargs:"
cat "$MNT/bootargs.txt" 2>/dev/null || echo "(missing)"
echo

# Removed: keep_bootcon (suspected cause of BPCIe bus overload → xhci_aeolia death)
# Kept: earlycon (still gives us early kernel boot UART logs until tty0 registers)
cat > "$MNT/bootargs.txt" <<'EOF'
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
EOF
echo "New bootargs:"
cat "$MNT/bootargs.txt"

echo
echo "=== FAT32 contents ==="
ls -la "$MNT"

sync
umount "$MNT"
rmdir "$MNT" 2>/dev/null || true
echo
echo "[+] Recovery complete. USB ready to replug into PS4."
