#!/bin/bash
#
# Create minimal initramfs for testing PS4 Linux boot
# This just mounts root and executes init - no busybox needed
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_DIR="${SCRIPT_DIR}/../output"
WORK_DIR="/tmp/ps4-initramfs"

echo "Creating minimal PS4 initramfs..."

# Clean and create work directory
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"/{bin,sbin,etc,proc,sys,dev,mnt/root,lib,lib64}

# Create minimal init script
cat > "${WORK_DIR}/init" << 'INITEOF'
#!/bin/sh

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev

echo "==================================="
echo "PS4 Linux 6.x - Initramfs Loaded!"
echo "==================================="
echo ""

# Parse kernel command line
ROOT_DEV=""
DEBUG_NET=""
for param in $(cat /proc/cmdline); do
    case "$param" in
        root=*)
            ROOT_DEV="${param#root=}"
            ;;
        debug_net=*)
            DEBUG_NET="${param#debug_net=}"
            ;;
    esac
done

echo "Kernel cmdline: $(cat /proc/cmdline)"
echo "Root device: ${ROOT_DEV}"
echo ""

# Wait for USB to settle
echo "Waiting for USB devices..."
sleep 3

# Try to set up networking for debug
echo "Setting up debug network..."
if [ -n "${DEBUG_NET}" ]; then
    # Load USB ethernet driver
    modprobe r8152 2>/dev/null || echo "r8152 module not found (may be built-in)"
    sleep 2
    
    # Find ethernet interface
    for iface in eth0 enp0s0 $(ls /sys/class/net/ | grep -v lo); do
        if [ -d "/sys/class/net/${iface}" ]; then
            echo "Configuring ${iface} with IP ${DEBUG_NET}..."
            ip addr add ${DEBUG_NET}/24 dev ${iface} 2>/dev/null
            ip link set ${iface} up 2>/dev/null
            break
        fi
    done
    
    echo "Network interfaces:"
    ip addr 2>/dev/null || echo "ip command failed"
fi

# List available block devices
echo "Available block devices:"
ls -la /dev/sd* 2>/dev/null || echo "No /dev/sd* devices found"
echo ""

if [ -n "${ROOT_DEV}" ] && [ -e "${ROOT_DEV}" ]; then
    echo "Mounting root filesystem ${ROOT_DEV}..."
    mount -o rw "${ROOT_DEV}" /mnt/root
    
    if [ -x /mnt/root/sbin/init ]; then
        echo "Switching to real root..."
        exec switch_root /mnt/root /sbin/init
    elif [ -x /mnt/root/lib/systemd/systemd ]; then
        echo "Switching to systemd..."
        exec switch_root /mnt/root /lib/systemd/systemd
    else
        echo "ERROR: No init found in root filesystem!"
        echo "Dropping to shell..."
    fi
else
    echo "ERROR: Root device not found or not specified!"
    echo "Dropping to shell..."
fi

# Emergency shell
echo ""
echo "Starting emergency shell..."
exec /bin/sh
INITEOF

chmod +x "${WORK_DIR}/init"

# Copy busybox (static) if available, otherwise use system binaries
if command -v busybox &> /dev/null && file $(which busybox) | grep -q "statically linked"; then
    echo "Using static busybox..."
    cp $(which busybox) "${WORK_DIR}/bin/"
    # Create symlinks for essential commands
    for cmd in sh mount umount switch_root sleep cat ls echo; do
        ln -s busybox "${WORK_DIR}/bin/${cmd}"
    done
else
    echo "Downloading static busybox..."
    curl -L -o "${WORK_DIR}/bin/busybox" \
        "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" || {
        echo "ERROR: Could not download busybox!"
        echo "Please install static busybox or download manually"
        exit 1
    }
    chmod +x "${WORK_DIR}/bin/busybox"
    
    # Create symlinks (including networking tools)
    for cmd in sh mount umount switch_root sleep cat ls echo mkdir mknod ip ifconfig modprobe insmod dmesg grep; do
        ln -s busybox "${WORK_DIR}/bin/${cmd}"
    done
fi

# Create /sbin symlinks too
ln -s ../bin/busybox "${WORK_DIR}/sbin/modprobe"
ln -s ../bin/busybox "${WORK_DIR}/sbin/insmod"

# Create the cpio archive
echo "Creating initramfs archive..."
cd "${WORK_DIR}"
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > "${OUTPUT_DIR}/initramfs-minimal.cpio.gz"

echo ""
echo "Created: ${OUTPUT_DIR}/initramfs-minimal.cpio.gz"
echo "Size: $(du -h "${OUTPUT_DIR}/initramfs-minimal.cpio.gz" | cut -f1)"
echo ""
echo "To use: copy initramfs-minimal.cpio.gz to USB as initramfs.cpio.gz"
echo "This will show boot messages and help diagnose where it fails"
