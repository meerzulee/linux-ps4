# PS4 Linux 6.x Kernel for Baikal Southbridge

A patch-based build system for porting Linux 6.x to PlayStation 4 Slim/Pro consoles with Baikal southbridge.

## Target Hardware

| Property | Value |
|----------|-------|
| Console | PS4 Slim |
| Southbridge | Baikal B1 (0x30201) |
| WiFi/BT | MediaTek MT7668 |
| Base Kernel | crashniels 6.15.y-baikal |

## Project Structure

```
linux-ps4/
├── build.sh              # Main build script
├── Makefile              # Build targets
├── patches/              # Patch files (git tracked)
│   ├── series            # Patch application order
│   ├── 0100-southbridge/ # Platform patches
│   ├── 0200-graphics/    # Display/GPU patches
│   ├── 0300-storage/     # AHCI/HDD patches
│   ├── 0400-wifi-bt/     # WiFi/Bluetooth patches
│   ├── 0500-input/       # Controller patches
│   └── 0600-system/      # Fan/power patches
├── config/               # Kernel configs (git tracked)
│   └── fragments/        # Config fragments
├── scripts/              # Helper scripts
├── firmware/             # Firmware files
├── tmp/                  # Reference repos (gitignored)
├── src/                  # Build directory (gitignored)
└── output/               # Build artifacts (gitignored)
```

## Quick Start

### 1. Initial Setup

```bash
# Clone this repository
git clone <your-repo-url> linux-ps4
cd linux-ps4

# Make scripts executable
chmod +x build.sh scripts/*.sh

# Initialize: clone reference repos and download firmware
make init
```

### 2. Extract Patches from Reference Repos

```bash
# List commits in a reference repo
./scripts/extract-patches.sh list feeRnt-5.4.247-baikal

# Search for specific changes
./scripts/extract-patches.sh search feeRnt-5.4.247-baikal "mt7668"

# View a commit
./scripts/extract-patches.sh show feeRnt-5.4.247-baikal <commit-hash>

# Extract a commit as a patch
./scripts/extract-patches.sh extract feeRnt-5.4.247-baikal <commit-hash> 0400-wifi-bt
```

### 3. Enable Patches

Edit `patches/series` to uncomment the patches you want to apply:

```bash
# patches/series
0100-southbridge/0101-baikal-platform.patch
0400-wifi-bt/0401-mt7668-sdio-support.patch
# ...
```

### 4. Build Kernel

```bash
# Build
make build

# Or with options
./build.sh -j 8  # 8 parallel jobs
```

### 5. Test on PS4

```bash
# Copy outputs to USB drive
cp output/bzImage /path/to/usb/
cp initramfs.cpio.gz /path/to/usb/
cp bootargs.txt /path/to/usb/

# Boot PS4 with Linux payload
```

## Build Commands

| Command | Description |
|---------|-------------|
| `make` | Build kernel with patches |
| `make clean` | Clean and rebuild from scratch |
| `make update` | Update base kernel from upstream |
| `make patches-only` | Apply patches without building |
| `make clone-refs` | Clone reference repositories |
| `make firmware` | Download firmware files |
| `make init` | First-time setup |
| `make help` | Show all targets |

## Patch Workflow

### Understanding the Patch System

1. **Base Kernel**: We build on top of [crashniels' ps4-linux-6.15.y-baikal](https://github.com/crashniels/linux/tree/ps4-linux-6.15.y-baikal) which already has most PS4 patches
2. **Additional Patches**: We add Baikal B1 specific patches extracted from other repos
3. **Series File**: `patches/series` controls which patches are applied and in what order

### Reference Repositories

| Repo | Contains | Priority |
|------|----------|----------|
| `crashniels-6.15` | Base PS4 6.15 kernel | Base |
| `feeRnt-5.4.247-baikal` | MT7668 support, blackscreen fix | High |
| `whitehax0r-5.4-baikal` | Syscon, fan control | High |
| `feeRnt-5.15-belize` | WiFi SDIO fixes | Medium |
| `ps4boot-5.3-baikal` | Original Baikal patches | Reference |

### Extracting Patches

```bash
# Clone reference repos
./scripts/clone-refs.sh

# Navigate to a repo and explore
cd tmp/feeRnt-5.4.247-baikal

# Find relevant commits
git log --oneline --grep="mt7668"
git log --oneline -- drivers/net/wireless/mediatek/

# View a commit
git show abc123

# Extract as patch
git format-patch -1 abc123 -o ../../patches/0400-wifi-bt/

# Or use the helper script
cd ../..
./scripts/extract-patches.sh extract feeRnt-5.4.247-baikal abc123 0400-wifi-bt
```

## Hardware Reference

### PS4 Southbridge Types

| Southbridge | ID | Models |
|-------------|-----|--------|
| Aeolia | 0x01xxxxxx | CUH-10xx, 11xx (Fat) |
| Belize | 0x02xxxxxx | CUH-12xx (Fat) |
| **Baikal** | 0x03xxxxxx | CUH-2xxx (Slim), CUH-7xxx (Pro) |
| **Baikal B1** | **0x30201** | CUH-21xx, 22xx, 71xx, 72xx |

### WiFi Chips

| Chip | Models | Driver |
|------|--------|--------|
| Marvell 88w8797 | Older Fat | mwifiex |
| Marvell 88w8897 | CUH-12xx | mwifiex (needs SDIO quirks) |
| **MediaTek MT7668** | **Baikal B1** | **mt76** |

## Configuration

### Config Files

| File | Description |
|------|-------------|
| `config/config.baikal-b1` | Full config for Baikal B1 |
| `config/fragments/mt7668.config` | MT7668 WiFi/BT options |
| `config/fragments/debug.config` | Debug options |

### Boot Arguments

Create `bootargs.txt` on your USB drive:

```
# Standard boot
initrd=initramfs.cpio.gz root=/dev/sda2 rootfstype=ext4 rw

# Debug boot
initrd=initramfs.cpio.gz root=/dev/sda2 rootfstype=ext4 rw console=tty0 loglevel=7 debug
```

## Troubleshooting

### Build Fails

```bash
# Clean and rebuild
make clean

# Check if patches apply
./build.sh --patches-only

# Build without patches to verify base kernel
./build.sh --no-patches
```

### Patch Doesn't Apply

1. Check if patch is already in base kernel
2. Try adjusting patch context/fuzz
3. Manually apply and create new patch

### No Display / Blackscreen

1. Verify HDMI settings on PS4 (1080p, HDCP off)
2. Try adding `video=HDMI-A-1:1920x1080@60` to bootargs
3. Check if blackscreen fix patch is applied

### WiFi Not Working

1. Verify firmware is installed: `/lib/firmware/mediatek/mt7668pr2h.bin`
2. Check if MT7668 config options are enabled
3. Check dmesg: `dmesg | grep -i mt76`

## Resources

- [PS4 Dev Wiki](https://www.psdevwiki.com/ps4/)
- [PS4 Linux Tutorial](https://dionkill.github.io/ps4-linux-tutorial/)
- [PS4 Linux Discord](https://discord.gg/QtcPmzHVVm)
- [crashniels/linux](https://github.com/crashniels/linux/tree/ps4-linux-6.15.y-baikal)
- [feeRnt/ps4-linux-12xx](https://github.com/feeRnt/ps4-linux-12xx)

## License

Patches are GPL-2.0 following Linux kernel licensing.

## Credits

- crashniels - Linux 6.15 Baikal development
- feeRnt - WiFi fixes, MT7668 support, blackscreen fixes
- whitehax0r - Baikal 5.4.x kernel
- DFAUS - 5.4.247 Baikal MT7668 work
- fail0verflow - Original PS4 Linux
- PS4 Linux community
