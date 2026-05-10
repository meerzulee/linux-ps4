#!/bin/bash
# Kexec a fresh kernel from SSH — skip the PSFree-Enhanced gauntlet.
#
# Run from /home/meerzulee/Work/ps4/linux-ps4/ on the host.
# Requires:
#   - PS4 booted with CONFIG_KEXEC=y, kexec-tools installed (both confirmed)
#   - new bzImage in output/<target>/bzImage
#   - SSH alias 'ps4' working
#
# This is the workflow:
#   1. scp the new bzImage to /tmp on PS4
#   2. mount /dev/sda1 (FAT32 PS4BOOT) to read initramfs that the running
#      Linux's bootloader (Sony OS kexec) used
#   3. kexec -l with current /proc/cmdline as bootargs
#   4. kexec -e — pivots into the new kernel
#   5. SSH session dies; wait ~30s and reconnect
#
# If the new kernel doesn't come up, you must hard-power-cycle the PS4
# and run the full PSFree gauntlet to recover.

set -e
TARGET="${1:-6.x-baikal}"
LOCAL_BZIMAGE="output/${TARGET}/bzImage"

if [ ! -f "$LOCAL_BZIMAGE" ]; then
    echo "ERROR: $LOCAL_BZIMAGE not found. Run ./build.sh -t $TARGET first."
    exit 1
fi

REMOTE_BZ="/tmp/bzImage-kexec"
echo "[+] Copying $LOCAL_BZIMAGE → ps4:$REMOTE_BZ ..."
scp "$LOCAL_BZIMAGE" ps4:"$REMOTE_BZ"

echo "[+] Local md5 vs remote md5:"
md5sum "$LOCAL_BZIMAGE"
ssh ps4 "md5sum $REMOTE_BZ"

cat <<EOF

[+] On the PS4, when ready, run:

    sudo mkdir -p /mnt/usbboot
    sudo mount -o ro /dev/sda1 /mnt/usbboot

    # show what initramfs is on USB
    ls -lh /mnt/usbboot/*.cpio.gz

    # current cmdline (used by current kernel)
    cat /proc/cmdline

    # load + execute the new kernel
    sudo kexec -l $REMOTE_BZ \\
        --initrd=/mnt/usbboot/initramfs.cpio.gz \\
        --append="\$(cat /proc/cmdline)"
    sync
    sudo kexec -e
    # ↑ session dies here. Wait ~30s, then ssh ps4 again.

[+] If the new kernel hangs, you'll have to hard-power the PS4 and
    re-run PSFree. The on-USB bzImage is whatever you last swapped
    via swap-bzimage.sh (currently the previous version), so the next
    full gauntlet boot will land on that, not the kexec'd one.
EOF
