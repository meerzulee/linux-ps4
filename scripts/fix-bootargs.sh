#!/usr/bin/env bash
# Audit FAT32 contents and write a clean bootargs.txt + vram.txt
# matching the v24b payload's expected layout.
set -euo pipefail

P1="${P1:-/dev/sda1}"
MNT="/mnt/ps4boot"
[[ $EUID -eq 0 ]] || { echo "[x] Run as root"; exit 1; }

mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$P1" "$MNT"

echo "=== BEFORE: contents of FAT32 ($P1) ==="
ls -la "$MNT"
echo
echo "=== Existing bootargs.txt (if any) ==="
[[ -f "$MNT/bootargs.txt" ]] && cat "$MNT/bootargs.txt" || echo "(none)"
echo
echo "=== Existing vram.txt (if any) ==="
[[ -f "$MNT/vram.txt" ]] && cat "$MNT/vram.txt" || echo "(none)"
echo

# Clean bootargs:
#  - drop root=, rootfstype=, rw, earlyprintk=serial,... (PS4 doesn't have legacy 8250)
#  - keep console=tty0 console=ttyS0 so we get HDMI + (eventually) UART output
#  - panic=15 so a panic auto-reboots after 15s instead of hanging
cat > "$MNT/bootargs.txt" <<'EOF'
console=tty0 console=ttyS0,115200n8 panic=15 loglevel=7
EOF

# Match VRAM size to the payload variant (linux-1024mb.bin = 1024)
echo "1024" > "$MNT/vram.txt"

echo "=== AFTER: contents of FAT32 ==="
ls -la "$MNT"
echo
echo "=== bootargs.txt ==="
cat "$MNT/bootargs.txt"
echo
echo "=== vram.txt ==="
cat "$MNT/vram.txt"

sync
umount "$MNT"
rmdir "$MNT"
echo "[+] Done."
