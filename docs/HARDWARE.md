# PS4 Slim Baikal B1 Hardware Information

## System Specifications

| Component | Details |
|-----------|---------|
| **Console** | PS4 Slim |
| **Southbridge** | Baikal B1 |
| **Southbridge ID** | 0x30201 |
| **APU** | AMD Liverpool (custom Jaguar + GCN 1.1) |
| **CPU** | 8-core AMD Jaguar x86-64 @ 1.6 GHz |
| **GPU** | AMD GCN 1.1, 18 CUs @ 800 MHz |
| **RAM** | 8 GB GDDR5 unified memory |
| **WiFi/BT** | MediaTek MT7668 |

## Southbridge Revisions

| ID | Name | Console Models |
|----|------|----------------|
| 0x01000001 | Aeolia A0 | Early dev kits |
| 0x01000100 | Aeolia A1 | CUH-10xx, CUH-11xx |
| 0x02000001 | Belize A0 | Early CUH-12xx |
| 0x02000100 | Belize B0 | CUH-12xx |
| 0x03000001 | Baikal A0 | Early Slim/Pro |
| 0x03010001 | Baikal B0 | CUH-20xx, CUH-70xx |
| **0x30201** | **Baikal B1** | **CUH-21xx, CUH-22xx, CUH-71xx, CUH-72xx** |

## WiFi/Bluetooth Chips

| Chip | Interface | Models | Driver |
|------|-----------|--------|--------|
| Marvell 88w8797 | SDIO | CUH-10xx (some) | mwifiex |
| Marvell 88w8897 | SDIO | CUH-12xx | mwifiex + quirks |
| **MediaTek MT7668** | **SDIO** | **Baikal B1** | **mt76** |

### MediaTek MT7668 Specs

- WiFi: 802.11ac dual-band (2.4 + 5 GHz)
- Bluetooth: 5.0
- Interface: SDIO
- Firmware: `mediatek/mt7668pr2h.bin`

## Hardware Identification

Once booted into Linux:

```bash
# Southbridge info
lspci | grep -i "bridge"

# WiFi chip
lspci | grep -i network
lsusb | grep -i mediatek

# SDIO devices (MT7668)
cat /sys/bus/sdio/devices/*/device  # Should show 0x7668
cat /sys/bus/sdio/devices/*/vendor  # Should show 0x037a (MediaTek)

# GPU
lspci | grep -i vga

# Storage
lsblk
```

## PS4 Settings for Linux

Before booting Linux, configure PS4:

### Video Settings
- Settings > Sound and Screen > Video Output Settings
  - Resolution: **1080p**
  - RGB Range: **Full**
  - HDR: **Off**
  - Deep Color Output: **Off**

### System Settings
- Settings > System
  - Uncheck: "Enable HDMI Device Link"
  - Uncheck: "Enable HDCP"

## Boot Arguments

### Standard

```
initrd=initramfs.cpio.gz root=/dev/sda2 rootfstype=ext4 rw
```

### Debug

```
initrd=initramfs.cpio.gz root=/dev/sda2 rootfstype=ext4 rw console=tty0 loglevel=7 debug
```

### Force Resolution

```
initrd=initramfs.cpio.gz root=/dev/sda2 rootfstype=ext4 rw video=HDMI-A-1:1920x1080@60
```

## Performance Tuning

### CPU Governor

```bash
# Performance mode
echo performance | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
```

### GPU Performance

```bash
# High performance
echo "high" | sudo tee /sys/class/drm/card0/device/power_dpm_force_performance_level
```

## Known Limitations

1. **Suspend/Resume**: Limited ACPI support
2. **Optical Drive**: Blu-ray not fully supported
3. **HDMI Audio**: May require specific configuration
4. **Fan Control**: Requires syscon driver (critical for hardware safety)
