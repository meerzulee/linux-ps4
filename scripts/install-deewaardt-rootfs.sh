#!/usr/bin/env bash
# Wipe sda2 and untar deeWaardt's Baikal-compatible Arch rootfs onto it.
# Replaces the pacstrap'd Arch (which crashes due to x86-64-v3 binaries
# on PS4 Jaguar's v2-class CPU).
#
# Run as root: sudo bash install-deewaardt-rootfs.sh
set -euo pipefail

P2="${P2:-/dev/sda2}"
TARBALL="${TARBALL:-/home/meerzulee/Downloads/ps4linux.tar.xz}"
MNT="/mnt/ps4root"
LABEL="psxitarch"

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root"
[[ -b "$P2" ]] || die "$P2 not a block device"
[[ -f "$TARBALL" ]] || die "Missing $TARBALL"

# Make sure not mounted (use -S to look up by source device, not -T)
if findmnt -nS "$P2" >/dev/null 2>&1; then
  log "Unmounting $P2"
  umount "$P2" || true
fi

log "Target: $P2"
log "Tarball: $TARBALL ($(numfmt --to=iec --suffix=B $(stat -c %s "$TARBALL")))"
read -rp "Wipe $P2 and install deeWaardt rootfs? Type WIPE: " confirm
[[ "$confirm" == "WIPE" ]] || die "Aborted."

log "Wiping ext4 on $P2 (label=$LABEL)"
mkfs.ext4 -F -L "$LABEL" "$P2"

mkdir -p "$MNT"
log "Mounting $P2 at $MNT"
mount "$P2" "$MNT"

log "Extracting tarball — ~5 min, ~6-7 GB extracted"
tar -xJpf "$TARBALL" -C "$MNT" --numeric-owner --xattrs-include='*.*'
log "Extraction done"

log "Top-level rootfs layout:"
ls -la "$MNT" | head -25

log "Sanity checks:"
[[ -x "$MNT/sbin/init" || -L "$MNT/sbin/init" ]] && log "  /sbin/init present"   || log "  WARNING /sbin/init missing"
[[ -x "$MNT/usr/lib/systemd/systemd" ]]                   && log "  systemd present"     || log "  WARNING systemd missing"
[[ -d "$MNT/etc/systemd/system" ]]                        && log "  systemd config dir present"

# fstab — clear any host-leaked entries, replace with minimal set
log "Writing minimal /etc/fstab"
cat > "$MNT/etc/fstab" <<EOF
# minimal fstab for first boot
LABEL=psxitarch  /         ext4  rw,noatime  0 1
EOF

log "Final rootfs size:"
du -sh "$MNT" 2>/dev/null | head -1

sync
umount "$MNT"
rmdir "$MNT"
log "[+] Done. USB ready for boot."
