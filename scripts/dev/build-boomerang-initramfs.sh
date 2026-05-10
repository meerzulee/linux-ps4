#!/usr/bin/env bash
# Build a diagnostic "boomerang" initramfs for 6.x experiments.
#
# Flow:
#   5.4 known-good Linux -> kexec 6.x + this initramfs
#   if 6.x reaches /init: save logs, then kexec back to known-good 5.4
#
# This does NOT make early kernel hangs recoverable. If 6.x dies before /init,
# manual power-cycle + PSFree relaunch is still required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="${WORK:-/tmp/ps4-boomerang-initramfs}"
OUT="${OUT:-$ROOT/output/boomerang-initramfs.cpio.gz}"
USB_ROOT_DEV="${USB_ROOT_DEV:-/dev/sda2}"
USB_ROOT_MNT="${USB_ROOT_MNT:-/mnt/ps4root-inspect}"

BUSYBOX_SRC="${BUSYBOX_SRC:-}"
KEXEC_SRC="${KEXEC_SRC:-}"
FALLBACK_BZ="${FALLBACK_BZ:-$ROOT/output/5.4-baikal/bzImage}"
FALLBACK_INITRD="${FALLBACK_INITRD:-$ROOT/checkpoint/boot/initramfs.cpio.gz}"
FALLBACK_CMDLINE="${FALLBACK_CMDLINE:-earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on}"

log() { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$FALLBACK_BZ" ]] || die "Missing fallback 5.4 bzImage: $FALLBACK_BZ"
[[ -f "$FALLBACK_INITRD" ]] || die "Missing fallback 5.4 initrd: $FALLBACK_INITRD"

rm -rf "$WORK"
mkdir -p "$WORK"/{bin,sbin,usr/bin,usr/lib,usr/lib64,lib,lib64,proc,sys,dev,run,mnt/root,tmp}

# Prefer the known static busybox from the existing checkpoint initramfs.
if [[ -z "$BUSYBOX_SRC" ]]; then
  CHECK="$ROOT/checkpoint/boot/initramfs.cpio.gz"
  if [[ -f "$CHECK" ]]; then
    log "Extracting static busybox from checkpoint initramfs"
    TMP_EXTRACT="$(mktemp -d)"
    (cd "$TMP_EXTRACT" && gzip -dc "$CHECK" | cpio -id --quiet 'bin/busybox' './bin/busybox' 2>/dev/null || true)
    if [[ -x "$TMP_EXTRACT/bin/busybox" ]]; then
      BUSYBOX_SRC="$TMP_EXTRACT/bin/busybox"
    fi
  fi
fi

if [[ -z "$BUSYBOX_SRC" && -x /usr/bin/busybox ]]; then
  BUSYBOX_SRC=/usr/bin/busybox
fi
[[ -n "$BUSYBOX_SRC" && -x "$BUSYBOX_SRC" ]] || die "No busybox found. Set BUSYBOX_SRC=/path/to/static/busybox"
cp "$BUSYBOX_SRC" "$WORK/bin/busybox"
chmod +x "$WORK/bin/busybox"

# Busybox applets we need.
for cmd in sh mount umount sleep cat echo dmesg mkdir cp ls find grep cut sed basename dirname sync date uname tee mknod switch_root poweroff reboot; do
  ln -sf busybox "$WORK/bin/$cmd"
done
ln -sf ../bin/busybox "$WORK/sbin/mdev"

# Get kexec from PS4 USB rootfs or explicit KEXEC_SRC. It is dynamically linked,
# so copy exactly the libs reported by ldd in the rootfs.
MOUNTED=0
cleanup_mount() {
  if [[ "$MOUNTED" == 1 ]]; then
    sudo umount "$USB_ROOT_MNT" 2>/dev/null || true
  fi
}
trap cleanup_mount EXIT

if [[ -z "$KEXEC_SRC" ]]; then
  [[ -b "$USB_ROOT_DEV" ]] || die "$USB_ROOT_DEV not found. Plug PS4 USB in or set KEXEC_SRC to a kexec binary."
  sudo mkdir -p "$USB_ROOT_MNT"
  if ! findmnt -rno TARGET "$USB_ROOT_MNT" >/dev/null 2>&1; then
    log "Mounting PS4 rootfs read-only at $USB_ROOT_MNT to copy kexec"
    sudo mount -o ro "$USB_ROOT_DEV" "$USB_ROOT_MNT"
    MOUNTED=1
  fi
  KEXEC_SRC="$USB_ROOT_MNT/usr/bin/kexec"
fi
[[ -x "$KEXEC_SRC" ]] || die "Missing kexec binary: $KEXEC_SRC"
cp "$KEXEC_SRC" "$WORK/usr/bin/kexec"
chmod +x "$WORK/usr/bin/kexec"
ln -sf ../usr/bin/kexec "$WORK/sbin/kexec"

# Copy kexec runtime loader/libs from USB rootfs if available.
if [[ "$KEXEC_SRC" == "$USB_ROOT_MNT"/* ]]; then
  log "Copying kexec dynamic libraries from PS4 rootfs"
  for lib in \
    /usr/lib/libzstd.so.1 \
    /usr/lib/libz.so.1 \
    /usr/lib/libc.so.6 \
    /usr/lib64/ld-linux-x86-64.so.2; do
    [[ -e "$USB_ROOT_MNT$lib" ]] || die "Missing library in rootfs: $lib"
    mkdir -p "$WORK$(dirname "$lib")"
    cp -aL "$USB_ROOT_MNT$lib" "$WORK$lib"
  done
  # Some binaries ask for /lib64/ld-linux-x86-64.so.2, and without an
  # ld.so.cache the dynamic loader may not search /usr/lib in initramfs.
  ln -sf /usr/lib64/ld-linux-x86-64.so.2 "$WORK/lib64/ld-linux-x86-64.so.2"
  ln -sf /usr/lib/libzstd.so.1 "$WORK/lib/libzstd.so.1"
  ln -sf /usr/lib/libz.so.1 "$WORK/lib/libz.so.1"
  ln -sf /usr/lib/libc.so.6 "$WORK/lib/libc.so.6"
else
  log "KEXEC_SRC is external; copying host ldd dependencies (best effort)"
  ldd "$KEXEC_SRC" | awk '/=> \/|^\s*\// {print $(NF-1)}' | while read -r lib; do
    [[ -e "$lib" ]] || continue
    mkdir -p "$WORK$(dirname "$lib")"
    cp -a "$lib" "$WORK$lib"
  done
fi

cp "$FALLBACK_BZ" "$WORK/bzImage-5.4"
cp "$FALLBACK_INITRD" "$WORK/initramfs-5.4.cpio.gz"
printf '%s\n' "$FALLBACK_CMDLINE" > "$WORK/fallback-cmdline.txt"

cat > "$WORK/init" <<'INIT'
#!/bin/sh
PATH=/bin:/sbin:/usr/bin:/usr/sbin
LD_LIBRARY_PATH=/lib:/usr/lib:/lib64:/usr/lib64
export PATH LD_LIBRARY_PATH

LOG=/run/boomerang.log
mkdir -p /run /tmp /mnt/root

say() {
  echo "[boomerang] $*" | tee -a "$LOG"
  echo "[boomerang] $*" > /dev/kmsg 2>/dev/null || true
}

mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || mount -t tmpfs tmpfs /dev 2>/dev/null || true
[ -c /dev/console ] || mknod /dev/console c 5 1 2>/dev/null || true
[ -c /dev/kmsg ] || mknod /dev/kmsg c 1 11 2>/dev/null || true

say "Linux 6 reached boomerang initramfs"
say "uname: $(uname -a 2>/dev/null)"
say "cmdline: $(cat /proc/cmdline 2>/dev/null)"
say "date: $(date 2>/dev/null || true)"

say "saving dmesg snapshot"
dmesg > /run/dmesg-6x.txt 2>/dev/null || true
cat /proc/interrupts > /run/interrupts-6x.txt 2>/dev/null || true
cat /proc/iomem > /run/iomem-6x.txt 2>/dev/null || true
ls -la /dev > /run/dev-list-6x.txt 2>/dev/null || true

# Try to persist logs if USB/rootfs devices are alive. This is best-effort only;
# the primary goal is returning to 5.4.
PERSISTED=0
sleep 3
for dev in /dev/disk/by-label/psxitarch /dev/sda2 /dev/sdb2 /dev/nvme0n1p2; do
  if [ -e "$dev" ]; then
    say "trying to mount log target $dev"
    if mount -o rw "$dev" /mnt/root 2>/run/mount.err; then
      TS=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)
      DEST=/mnt/root/var/log/ps4-boomerang/$TS
      mkdir -p "$DEST"
      cp -a /run/boomerang.log /run/dmesg-6x.txt /run/interrupts-6x.txt /run/iomem-6x.txt /run/dev-list-6x.txt "$DEST" 2>/dev/null || true
      sync
      umount /mnt/root 2>/dev/null || true
      PERSISTED=1
      say "logs persisted to rootfs var/log/ps4-boomerang/$TS"
      break
    else
      say "mount failed for $dev: $(cat /run/mount.err 2>/dev/null)"
    fi
  fi
done
[ "$PERSISTED" = 1 ] || say "could not persist logs; will still try to return to 5.4"

if grep -qw boomerang_no_return /proc/cmdline 2>/dev/null; then
  say "boomerang_no_return set; dropping to shell"
  exec /bin/sh
fi

say "loading fallback 5.4 via kexec"
CMDLINE=$(cat /fallback-cmdline.txt)
/usr/bin/kexec -l /bzImage-5.4 --initrd=/initramfs-5.4.cpio.gz --command-line="$CMDLINE" >>"$LOG" 2>&1
RC=$?
if [ "$RC" != 0 ]; then
  say "kexec -l fallback failed rc=$RC; dropping to shell"
  exec /bin/sh
fi

say "kexec fallback loaded; returning to 5.4 in 5 seconds"
sync
sleep 5
/usr/bin/kexec -e

say "kexec -e returned unexpectedly; dropping to shell"
exec /bin/sh
INIT
chmod +x "$WORK/init"

mkdir -p "$(dirname "$OUT")"
log "Creating $OUT"
(
  cd "$WORK"
  find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "$OUT"
)

ok "Built $OUT"
ls -lh "$OUT"
sha256sum "$OUT"
log "Contents summary:"
(
  cd "$WORK"
  find . -maxdepth 3 -type f -o -type l | sort | sed 's#^./#  #'
)
