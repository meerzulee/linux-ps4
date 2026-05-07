#!/usr/bin/env bash
# Kexec a new bzImage on the running PS4 over SSH — no USB swap, no power cycle.
#
# Cost model:
#   * If new kernel BOOTS, you've spent zero PSFree chains for a real-hardware test.
#   * If it HANGS / PANICS, the PS4 is dead — full power-cycle + rollback to recover.
#   * 5.4 must already be running and SSH-reachable.
#
# This script ONLY touches in-RAM kernel state. The USB FAT32's `bzImage` is
# untouched — kexec testing never promotes anything. To make a kexec-validated
# kernel the persistent boot kernel, run `test-kernel.sh` afterwards.
#
# Usage:
#   kexec-test.sh <bzImage> [--cmdline "<extra args>"] [--initrd <path>]
#
# Examples:
#   # Boot 6.x straight to a shell, GPU drivers off, max verbosity
#   bash scripts/dev/kexec-test.sh src/6.x-baikal/arch/x86/boot/bzImage \
#     --cmdline "init=/bin/sh modprobe.blacklist=radeon,amdgpu nofb"
#
#   # Same but with our better-initramfs
#   bash scripts/dev/kexec-test.sh src/6.x-baikal/arch/x86/boot/bzImage \
#     --initrd dist/initramfs.cpio.gz \
#     --cmdline "init=/bin/sh modprobe.blacklist=radeon,amdgpu"
set -euo pipefail

PS4_HOST="${PS4_HOST:-ps4}"
PS4_IP="${PS4_IP:-192.168.50.125}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-180}"

bz=""
extra=""
initrd=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cmdline) extra="$2"; shift 2;;
    --initrd)  initrd="$2"; shift 2;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    -*) echo "[x] Unknown option: $1" >&2; exit 1;;
    *) bz="$1"; shift;;
  esac
done

[[ -n "$bz" && -f "$bz" ]] || { echo "Usage: $0 <bzImage> [--cmdline ...] [--initrd ...]" >&2; exit 1; }
[[ -z "$initrd" || -f "$initrd" ]] || { echo "[x] initrd not found: $initrd" >&2; exit 1; }

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

log "Pre-flight: SSH to $PS4_HOST"
ssh -o ConnectTimeout=5 -o BatchMode=yes "$PS4_HOST" 'true' \
  || die "Can't SSH to $PS4_HOST. Need a live 5.4 session before kexec."

log "Pre-flight: kexec-tools on PS4"
ssh "$PS4_HOST" 'command -v kexec >/dev/null 2>&1' \
  || die "kexec not installed. On PS4: sudo pacman -S kexec-tools"

old_uname=$(ssh "$PS4_HOST" 'uname -r')
old_cmdline=$(ssh "$PS4_HOST" 'cat /proc/cmdline')
# Drop bootloader-injected BOOT_IMAGE — kexec doesn't want it.
base_cmdline=$(echo "$old_cmdline" | sed -E 's/(^| )BOOT_IMAGE=\S+//')
# Strip leading whitespace.
base_cmdline="${base_cmdline#"${base_cmdline%%[![:space:]]*}"}"

cmdline="$base_cmdline${extra:+ $extra}"

log "Current kernel : $old_uname"
log "Inherited cmdline:"
echo "    $base_cmdline"
[[ -n "$extra" ]] && { log "Extra cmdline added:"; echo "    $extra"; }

log "scp $bz → ps4:/tmp/test-bzImage ($(stat -c %s "$bz") bytes)"
scp -q "$bz" "$PS4_HOST":/tmp/test-bzImage

initrd_arg=""
if [[ -n "$initrd" ]]; then
  log "scp $initrd → ps4:/tmp/test-initrd ($(stat -c %s "$initrd") bytes)"
  scp -q "$initrd" "$PS4_HOST":/tmp/test-initrd
  initrd_arg='--initrd=/tmp/test-initrd'
fi

log "kexec -l (loading new kernel image into RAM)"
ssh "$PS4_HOST" "sudo kexec -l /tmp/test-bzImage $initrd_arg --command-line=$(printf %q "$cmdline")" \
  || die "kexec -l failed. Image rejected — check kexec output above."

ok "Kernel staged in RAM. Firing kexec — SSH will drop."
warn "If new kernel hangs: power-cycle PS4, plug USB into host, run rollback-kernel.sh."
sleep 2

# kexec -e from a logged-in shell yanks SSH out from under itself; use systemctl
# kexec which orchestrates a clean shutdown of services first. Fall back to a
# detached `kexec -e` if systemd isn't cooperating.
ssh -o ServerAliveInterval=2 "$PS4_HOST" \
  'sudo systemctl kexec || sudo nohup kexec -e </dev/null >/dev/null 2>&1 &' \
  || true

echo
log "Polling SSH on $PS4_IP (timeout ${WAIT_TIMEOUT}s)…"
start=$(date +%s); attempt=0
# Wait at least 8s before believing any SSH success — old 5.4 may still be alive
# during shutdown phase before kexec actually fires.
sleep 8

while true; do
  attempt=$((attempt+1))
  if ssh -o ConnectTimeout=4 -o BatchMode=yes "$PS4_HOST" 'true' 2>/dev/null; then
    new_uname=$(ssh -o ConnectTimeout=4 "$PS4_HOST" 'uname -r' 2>/dev/null || echo unknown)
    new_uptime=$(ssh -o ConnectTimeout=4 "$PS4_HOST" 'uptime' 2>/dev/null || echo unknown)
    fresh=0
    echo "$new_uptime" | grep -qE 'up.{1,3}(min|sec|[0-5]:[0-9][0-9],)' && fresh=1
    if [[ "$new_uname" != "$old_uname" || $fresh -eq 1 ]]; then
      elapsed=$(($(date +%s) - start))
      ok "New kernel live after ${elapsed}s"
      echo "    kernel: $new_uname"
      echo "    uptime: $new_uptime"
      echo
      log "USB FAT32 was NOT modified. To persist this kernel, run test-kernel.sh."
      exit 0
    fi
  fi
  elapsed=$(($(date +%s) - start))
  if (( elapsed >= WAIT_TIMEOUT )); then
    warn "Timed out after ${elapsed}s — new kernel didn't come up on SSH."
    cat <<EOF

[!] Kexec FAILED. Check UART log for late-init messages.
Recovery:
  1. Hold PS4 power button ~7s.
  2. Plug USB into host.
  3. sudo bash scripts/dev/rollback-kernel.sh
  4. Replug USB → re-launch payload via PSFree.
EOF
    exit 1
  fi
  (( attempt % 6 == 0 )) && log "still waiting (${elapsed}s)"
  sleep 5
done
