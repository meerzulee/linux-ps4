#!/usr/bin/env bash
# Phase E debug bootargs — bypass systemd with init=/bin/sh, log every
# initcall. Without keep_bootcon (which seemed to cause hard hang earlier).
#
# Expected on HDMI/UART:
#   - If kernel reaches userspace, we see /bin/sh prompt on HDMI
#   - If kernel hangs in late init, last initcall_debug line tells us
#     which subsystem hung
set -euo pipefail
P1="${P1:-/dev/sda1}"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "Run as root"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

echo "=== old bootargs ==="
cat "$MNT/bootargs.txt"
echo "=== bzImage active (verify it's our 6.x without uart patch) ==="
sha256sum "$MNT/bzImage" /home/meerzulee/Work/ps4/linux-ps4/output/6.x-baikal/bzImage

# init=/bin/sh: skip systemd, drop straight to a shell on HDMI tty0
# initcall_debug: log every initcall so we see exactly where it hangs
cat > "$MNT/bootargs.txt" <<'EOF'
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on initcall_debug init=/bin/sh
EOF

echo
echo "=== new bootargs ==="
cat "$MNT/bootargs.txt"
sync
umount "$MNT"
rmdir "$MNT"
echo
echo "[+] init=/bin/sh + initcall_debug. UART captures early; HDMI shows the rest."
echo "    Photo the LAST visible line on HDMI when it hangs/freezes."
