# PS4 Linux 6.x Full Build Plan - 2026-03-16

## Overview
Cross-compile Linux 6.15 kernel for PS4 Slim (Baikal B1) from Apple M5 ARM64 host.
UART debug enabled. Arch Linux rootfs with XFCE4. 128GB USB (1GB boot + ext4 rootfs).

## Current State
- Host: macOS 26.3, Apple M5 ARM64, 24GB RAM
- Docker/Orbstack: installed, Orbstack stopped
- No src/, output/, tmp/ dirs exist (clean workspace)
- Previous: Build #3 SUCCESS (6.15.4), Test #1 BLACK SCREEN (bad initramfs), Test #2 PENDING
- UART: Baikal southbridge hardware mod
- Payload: Al-Azif ps4-payload-guest

---

## Phase 0: Logging & Structure

### Create directories and tracking files
```bash
mkdir -p notes output/attempt-004-2026-03-16
```

### Create notes/THOUGHTS-2026-03-16.md
Running log of decisions, ideas, rationale. Updated throughout build.

### Create UART config fragment: config/fragments/uart.config
```
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_8250_PCI=y
CONFIG_SERIAL_8250_NR_UARTS=4
CONFIG_CONSOLE_POLL=y
```

---

## Phase 1: Build Environment

### Start Orbstack
```bash
orbctl start
```

### Create Arch Linux ARM64 container
```bash
orbctl create arch ps4-builder
```

### Install cross-compilation tools inside container
```bash
# Inside the Arch container:
pacman -Syu --noconfirm
pacman -S --noconfirm \
  base-devel \
  x86_64-linux-gnu-gcc \
  bc flex bison \
  libelf openssl \
  ncurses \
  cpio gzip xz \
  git wget curl \
  python
```

### Verify cross-compiler works
```bash
x86_64-linux-gnu-gcc --version
```

---

## Phase 2: Kernel Compilation

### Clone base kernel
```bash
git clone --depth=50 https://github.com/crashniels/linux.git \
  --branch ps4-linux-6.15.y-baikal src/linux
```

### Apply fixes
```bash
cd src/linux
# bpcie-icc pointer type fix
sed -i 's/^\tu32 addr;$/\tvoid __iomem *addr;/' drivers/ps4/ps4-bpcie-icc.c
```

### Configure kernel
```bash
cp ../../config/config.baikal-b1 .config

# Merge fragments
for f in ../../config/fragments/*.config; do
  ./scripts/kconfig/merge_config.sh -m .config "$f" || cat "$f" >> .config
done

# Resolve dependencies
make ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- olddefconfig
```

### CRITICAL: Verify fan control
```bash
grep -i "PS4_SYSCON\|PS4_FAN\|BAIKAL.*FAN" .config
# Must see at least one =y or =m
# If missing, add: CONFIG_PS4_SYSCON=y
```

### Build kernel
```bash
make ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j$(nproc) bzImage 2>&1 | tee ../../output/attempt-004-2026-03-16/build.log
make ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- -j$(nproc) modules 2>&1 | tee -a ../../output/attempt-004-2026-03-16/build.log
```

### Collect artifacts
```bash
cp arch/x86/boot/bzImage ../../output/attempt-004-2026-03-16/
cp .config ../../output/attempt-004-2026-03-16/config
cp System.map ../../output/attempt-004-2026-03-16/
make kernelrelease > ../../output/attempt-004-2026-03-16/version.txt
```

---

## Phase 3: Initramfs (UART Debug)

### Download x86_64 static busybox
```bash
curl -L -o /tmp/busybox \
  "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox"
chmod +x /tmp/busybox
```

### Create initramfs structure
```bash
WORK=/tmp/ps4-initramfs
rm -rf $WORK
mkdir -p $WORK/{bin,sbin,etc,proc,sys,dev,mnt/root,lib,lib64,tmp}
cp /tmp/busybox $WORK/bin/
for cmd in sh mount umount switch_root sleep cat ls echo mkdir mknod \
  ip ifconfig modprobe insmod dmesg grep stty; do
  ln -s busybox $WORK/bin/$cmd
done
ln -s ../bin/busybox $WORK/sbin/modprobe
ln -s ../bin/busybox $WORK/sbin/insmod
```

### Create init script with dual-console (HDMI + UART)
Key features:
- Outputs to both console=tty0 AND console=ttyS0
- Prints hardware discovery info for UART debugging
- Lists PCI devices, block devices, USB devices
- Attempts rootfs mount with detailed error reporting
- Falls back to emergency shell on either console

### Package initramfs
```bash
cd $WORK
find . -print0 | cpio --null -ov --format=newc 2>/dev/null | gzip -9 > \
  output/attempt-004-2026-03-16/initramfs.cpio.gz
```

---

## Phase 4: Arch Linux Rootfs

### Build x86_64 Arch rootfs via Docker
```bash
docker build --platform linux/amd64 -t ps4-archlinux-rootfs \
  -f output/Dockerfile.ps4arch output/
```

Dockerfile installs:
- base, linux-firmware, networkmanager
- xfce4, lightdm, mesa, vulkan-radeon
- firefox, pulseaudio, htop, git, etc.
- User ps4/ps4, root/root

### Export rootfs
```bash
docker create --platform linux/amd64 --name ps4rootfs ps4-archlinux-rootfs
docker export ps4rootfs | xz -9 -T0 > output/ps4linux.tar.xz
docker rm ps4rootfs
```

### Install kernel modules into rootfs
```bash
# Extract rootfs to temp location
mkdir -p /tmp/ps4root
tar -xJf output/ps4linux.tar.xz -C /tmp/ps4root

# Install modules
cd src/linux
make ARCH=x86_64 CROSS_COMPILE=x86_64-linux-gnu- \
  INSTALL_MOD_PATH=/tmp/ps4root modules_install

# Copy firmware
cp -r ../../firmware/mediatek /tmp/ps4root/lib/firmware/
cp -r ../../firmware/mrvl /tmp/ps4root/lib/firmware/

# Re-package
cd /tmp/ps4root
tar -cJf output/ps4linux-with-modules.tar.xz .
```

---

## Phase 5: USB Drive Setup

### Update prepare-usb.sh
Change default boot partition from 100MB to 1GB:
```bash
BOOT_SIZE="1G"  # Was "100M"
```

### Create bootargs.txt with UART debug
```
initrd=initramfs.cpio.gz root=/dev/sda2 rootfstype=ext4 rw console=tty0 console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200 loglevel=7 debug initcall_debug
```

### USB Partition Layout (128GB)
```
/dev/sda1: 1GB  FAT32, label=PS4BOOT   (boot files)
/dev/sda2: ~127GB EXT4, label=psxitarch (Arch Linux rootfs)
```

### Boot files on FAT32:
- bzImage (~10MB)
- initramfs.cpio.gz (~700KB)
- bootargs.txt

---

## Phase 6: Build Script Updates

### Modify build.sh
- Add `--cross` flag for cross-compilation
- Add `--container` flag to run inside Orbstack container
- Auto-detect host arch

### New file: config/fragments/uart.config
Serial console options for UART debugging

### New file: scripts/build-in-container.sh
Wrapper that runs build.sh inside the Orbstack Arch container

---

## Risk Checklist

- [ ] Fan control: verify CONFIG_PS4_SYSCON in kernel config
- [ ] UART: verify CONFIG_SERIAL_8250_CONSOLE=y
- [ ] initramfs: confirm x86_64 busybox binary (not ARM64)
- [ ] Rootfs: confirm --platform linux/amd64 for Docker
- [ ] Blackscreen: test with/without video= bootarg
- [ ] Modules: verify module versions match kernel version

## Output Files
```
output/attempt-004-2026-03-16/
  bzImage
  config
  build.log
  initramfs.cpio.gz
  bootargs.txt
  version.txt
  System.map
output/ps4linux.tar.xz          (rootfs without modules)
output/ps4linux-with-modules.tar.xz (rootfs with modules)
notes/THOUGHTS-2026-03-16.md    (running log)
```
