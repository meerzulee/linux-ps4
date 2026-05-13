#!/usr/bin/env bash
# hotswap-mts.sh — fast iteration loop for the ps4_mts driver.
#
# Edit src/6.x-baikal/drivers/net/ethernet/sony/ps4_mts.c, then run this
# script.  It rebuilds ONLY the module (~10s), scp's to the PS4 at /tmp,
# rmmod + insmod, then tails the freshly-cleared dmesg ring buffer.
#
# Total per-iteration: ~30 sec instead of ~15 min for a full reboot
# through the PSFree-Enhanced gauntlet.
#
# Prerequisites (set up by v113 + v114):
#   - CONFIG_PS4_MTS=m in config/6.x-baikal.config
#   - mts_remove() does the quiesce dance (v113)
#   - sky2 guard uses IS_ENABLED, not #ifndef (v114)
#   - module already installed at /lib/modules/$(uname -r)/.../ps4_mts.ko
#     on PS4 rootfs (only needed for first boot — after that we drop the
#     fresh .ko into /tmp and load directly from there)
#   - SSH alias 'ps4' working
#
# Usage:
#   ./scripts/dev/hotswap-mts.sh                # rebuild + swap + tail
#   ./scripts/dev/hotswap-mts.sh --skip-build   # use existing .ko (after
#                                                   manual edit on PS4)
#   ./scripts/dev/hotswap-mts.sh --no-tail      # skip dmesg tail (faster
#                                                   when running back-to-back)

set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="${REPO}/src/6.x-baikal"
KO_PATH="${SRC}/drivers/net/ethernet/sony/ps4_mts.ko"
REMOTE_KO="/tmp/ps4_mts.ko"

SKIP_BUILD=false
NO_TAIL=false
for arg in "$@"; do
    case "$arg" in
        --skip-build) SKIP_BUILD=true ;;
        --no-tail)    NO_TAIL=true ;;
        -h|--help)
            sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "[!] Unknown arg: $arg" >&2; exit 2 ;;
    esac
done

# ------------------------------------------------------------------------
# Step 1: rebuild module (skip with --skip-build)
# ------------------------------------------------------------------------
if [[ "$SKIP_BUILD" == "true" ]]; then
    echo "[~] Skipping build (using existing $KO_PATH)"
    [[ -f "$KO_PATH" ]] || { echo "[x] No .ko at $KO_PATH"; exit 1; }
else
    echo "[+] Rebuilding ps4_mts.ko..."
    cd "$SRC"
    # `make M=...` builds JUST the module against the running kernel's
    # symbol table.  ~5-10 seconds for a small source edit.
    if ! make M=drivers/net/ethernet/sony modules 2>&1 | tail -3; then
        echo "[x] Module build failed"
        exit 1
    fi
fi

KO_MD5="$(md5sum "$KO_PATH" | awk '{print $1}')"
KO_SIZE="$(stat -c %s "$KO_PATH")"
echo "[+] Local .ko: ${KO_SIZE} bytes, md5=${KO_MD5}"

# ------------------------------------------------------------------------
# Step 2: scp to PS4
# ------------------------------------------------------------------------
echo "[+] scp $KO_PATH → ps4:${REMOTE_KO}"
scp -q "$KO_PATH" ps4:"$REMOTE_KO"

# ------------------------------------------------------------------------
# Step 3: rmmod + insmod + verify on PS4
# ------------------------------------------------------------------------
ssh ps4 "bash -s" <<REMOTE
set -e

# Quiesce the interface to give the driver a graceful exit.
sudo ip link set enp0s20f1 down 2>/dev/null || true

# Remove the current module.  rmmod will refuse if anything is holding
# refs; that should be rare now that the interface is down.
if lsmod | grep -q '^ps4_mts'; then
    sudo rmmod ps4_mts
fi

# Verify cleanup.
if grep -q ps4_mts /proc/interrupts; then
    echo "[!] WARNING: stray IRQ entry still in /proc/interrupts after rmmod"
fi
if [[ -e /sys/bus/pci/devices/0000:00:14.1/driver ]]; then
    echo "[!] WARNING: PCI device still bound to a driver after rmmod"
    ls -la /sys/bus/pci/devices/0000:00:14.1/driver
fi

# Clear dmesg ring so post-insmod log is uncluttered.
sudo dmesg -C

# Load the freshly-built .ko.
echo "[~] Loading $REMOTE_KO..."
sudo insmod $REMOTE_KO

# Verify probe ran cleanly.
sleep 1
if ! lsmod | grep -q '^ps4_mts'; then
    echo "[x] insmod ran but module not in lsmod"
    sudo dmesg | tail -20
    exit 1
fi
if ! readlink /sys/bus/pci/devices/0000:00:14.1/driver 2>/dev/null | grep -q ps4_mts; then
    echo "[x] Module loaded but didn't bind to PCI device"
    sudo dmesg | tail -20
    exit 1
fi

echo "[+] ps4_mts re-loaded and bound to 0000:00:14.1"
REMOTE

# ------------------------------------------------------------------------
# Step 4: tail dmesg (skip with --no-tail)
# ------------------------------------------------------------------------
if [[ "$NO_TAIL" != "true" ]]; then
    echo
    echo "=== dmesg after insmod ==="
    ssh ps4 'sudo dmesg | tail -40'
fi

echo
echo "[+] Hotswap complete. Bring interface up with:"
echo "    ssh ps4 'sudo ip link set enp0s20f1 up'"
