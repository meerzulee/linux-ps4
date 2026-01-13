# PS4 Linux Firmware Files

This directory contains firmware files required for PS4 hardware.

## Download Firmware

Run the download script:

```bash
../scripts/download-firmware.sh
```

## Required Firmware

### MediaTek MT7668 (Baikal B1)

For PS4 Slim/Pro with Baikal B1 southbridge:

| File | Path | Description |
|------|------|-------------|
| `mt7668pr2h.bin` | `mediatek/` | WiFi + Bluetooth firmware |

### Marvell (Reference)

For older PS4 models (included for reference):

| File | Path | Description |
|------|------|-------------|
| `sd8897_uapsta.bin` | `mrvl/` | Marvell 88w8897 (CUH-12xx) |
| `sd8797_uapsta.bin` | `mrvl/` | Marvell 88w8797 (older models) |

## Installation

### Option 1: System Installation

```bash
sudo cp -r mediatek/ /lib/firmware/
sudo cp -r mrvl/ /lib/firmware/
```

### Option 2: Embed in Initramfs

Copy firmware files to your initramfs under `/lib/firmware/`.

### Option 3: Build into Kernel

Set in kernel config:

```
CONFIG_EXTRA_FIRMWARE="mediatek/mt7668pr2h.bin"
CONFIG_EXTRA_FIRMWARE_DIR="/path/to/firmware"
```

## Sources

All firmware files are from the official Linux firmware repository:
https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/

## License

Firmware files have their own licenses. Check the linux-firmware repository
for specific licensing terms.
