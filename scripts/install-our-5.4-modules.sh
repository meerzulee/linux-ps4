#!/usr/bin/env bash
# Install the 5.4 kernel modules we built (5.4.247-neocine-1.1-dirty)
# into the deeWaardt rootfs on /dev/sda2 so modprobe can find them.
set -euo pipefail

P2="${P2:-/dev/sda2}"
MNT="/mnt/ps4root"
SRC="/home/meerzulee/Work/ps4/linux-ps4/src/5.4-baikal"

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -b "$P2" ]] || { echo "$P2 not a block device"; exit 1; }
[[ -d "$SRC" ]] || { echo "Missing $SRC"; exit 1; }

KVER=$(cat /home/meerzulee/Work/ps4/linux-ps4/output/5.4-baikal/version.txt | tr -d '[:space:]')
echo "Installing modules for kernel $KVER"

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P2" "$MNT"

echo "=== before: /lib/modules ==="
ls "$MNT/lib/modules" 2>/dev/null || echo "(none yet)"

# modules_install populates $MNT/lib/modules/<KVER>/ and runs depmod
make -C "$SRC" INSTALL_MOD_PATH="$MNT" INSTALL_MOD_STRIP=1 modules_install 2>&1 | tail -20

echo
echo "=== after: /lib/modules ==="
ls "$MNT/lib/modules"
echo
echo "=== mt76 modules installed ==="
find "$MNT/lib/modules/$KVER/kernel/drivers/net/wireless/mediatek" -name "*.ko*" 2>/dev/null | head -20
echo
echo "=== bluetooth modules installed (mt7668 BT side) ==="
find "$MNT/lib/modules/$KVER/kernel/drivers/bluetooth" -name "*.ko*" 2>/dev/null | head -10
echo
echo "=== depmod for KVER ==="
depmod -b "$MNT" -a "$KVER" && echo "depmod ok"

sync
umount "$MNT"
rmdir "$MNT"
echo "[+] Modules installed."
