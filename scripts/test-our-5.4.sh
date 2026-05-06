#!/usr/bin/env bash
# Test our self-built 5.4 bzImage with the v24b loader + correct earlycon.
# Keeps feeRnt's 5.4 prebuilt on USB as `bzImage-5.4-feeRnt` for instant fallback.
set -euo pipefail

P1="${P1:-/dev/sda1}"
OUR_5_4="${OUR_5_4:-/home/meerzulee/Work/ps4/linux-ps4/output/5.4-baikal/bzImage}"
FEERNT_5_4="${FEERNT_5_4:-/home/meerzulee/Work/ps4/linux-ps4/output/feeRnt-prebuilt/bzImage_Clang}"
MNT="/mnt/ps4boot"

[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }
[[ -f "$OUR_5_4" ]] || { echo "Missing $OUR_5_4"; exit 1; }
[[ -f "$FEERNT_5_4" ]] || { echo "Missing $FEERNT_5_4"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

echo "=== before ==="
ls -la "$MNT"

# Backup feeRnt prebuilt as fallback (idempotent if already there)
if [[ ! -f "$MNT/bzImage-5.4-feeRnt" ]]; then
  cp -v "$FEERNT_5_4" "$MNT/bzImage-5.4-feeRnt"
fi
# Also keep our 6.x for the next experiment
if [[ -f "/home/meerzulee/Work/ps4/linux-ps4/output/6.x-baikal/bzImage" ]] && [[ ! -f "$MNT/bzImage-6.x-ours" ]]; then
  cp -v /home/meerzulee/Work/ps4/linux-ps4/output/6.x-baikal/bzImage "$MNT/bzImage-6.x-ours"
fi

# Active bzImage = our self-built 5.4
cp -v "$OUR_5_4" "$MNT/bzImage"

# Same proven bootargs (no keep_bootcon)
cat > "$MNT/bootargs.txt" <<'EOF'
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
EOF

echo
echo "=== after ==="
ls -la "$MNT"
echo
echo "bootargs:"
cat "$MNT/bootargs.txt"

sync
umount "$MNT"
rmdir "$MNT"
echo
echo "[+] Staged our 5.4 bzImage as the active boot. Backups kept on USB:"
echo "    bzImage-5.4-feeRnt   (known-working, from earlier session)"
echo "    bzImage-6.x-ours     (boots through early init, hangs late)"
echo
echo "Plug USB into PS4 → load linux-1024mb.bin via PSFree."
