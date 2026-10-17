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

## Provenance and embedded firmware

The regular and MTS configurations explicitly embed device firmware through
`CONFIG_EXTRA_FIRMWARE`. In particular, the tested MTS2 bzImage contains the
ten files below. They are pre-existing repository inputs, not Sony PUP or
system-kernel files. The previous blanket statement that every file came from
linux-firmware was not backed by a per-file source and notice ledger.

The kernel and original Linux patches use their stated GPL licenses. That
does not grant a GPL license to firmware. Firmware redistribution notices
must be established separately before a new public binary release. The
current source update adds no new firmware blobs.

| Embedded path | Bytes | SHA256 |
| --- | ---: | --- |
| `mediatek/mt7668pr2h.bin` | 170990 | `465ed634c61b46b34bb21240736f33d3d347fefec7cbfbd1cb6e63334aec4cc9` |
| `EEPROM_MT7668.bin` | 1024 | `d3ecac0fde5b66fab282cd97f43c04d77bf4fd6abdbd9c35c5d3d40e2f1f035a` |
| `EEPROM_MT7668_e1.bin` | 1024 | `a042c6ceb77ae4a0c367e5e5522cbf21f767936b8799a781096e1e72684d957c` |
| `mt7668_patch_e1_hdr.bin` | 152302 | `519083ebb8318d9cfc8eaaaa7470d1a266c8f32275df3c62e3619d6c07f97389` |
| `mt7668_patch_e2_hdr.bin` | 178782 | `05a619651517ee481ccfa3ed2cd11bd33f497967802233e6f81085036e0ec9d5` |
| `TxPwrLimit_MT76x8.dat` | 19064 | `49fa3e52b26fe49b837187c91765550e32cd6540ea2e09343274245d6630062a` |
| `wifi.cfg` | 889 | `828d7d18607c78513a71719f919340a7c91ee8ef68080ad7270a65dd661abbbd` |
| `WIFI_RAM_CODE2_SDIO_MT7668.bin` | 51816 | `35faff6a613fefcbe33a6f6d8df885be76c546f9e78ba8ab93056a816ad87254` |
| `WIFI_RAM_CODE2_USB_MT7668.bin` | 55880 | `b6c6b63f021168a327a0600119a416c4f5f5198820a3267b54a1259c19da0baf` |
| `WIFI_RAM_CODE_MT7668.bin` | 463080 | `977724f3eef0e6f27567a6684bf616b884b82fe948bde0a436ea546a1f9c83ee` |

The public linux-firmware source is:

https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git/

Consult its `WHENCE` and file-specific license notices for matching upstream
artifacts; do not assume the same license covers a differently sourced or
modified blob. `mediatek/mt7668pr2h.bin` exactly matches linux-firmware commit
`5bc5868b7ee5a243abdd73cfcd3bbf7166f4f42f` (tag `20250211`). Its
[`LICENCE.mediatek`](https://kernel.googlesource.com/pub/scm/linux/kernel/git/firmware/linux-firmware.git/+/5bc5868b7ee5a243abdd73cfcd3bbf7166f4f42f/LICENCE.mediatek)
allows distribution for MediaTek devices but excludes bundling it as part of
the Linux kernel. Therefore the public tester target sets
`CONFIG_EXTRA_FIRMWARE=""` and loads firmware separately. The notice's SHA256 is
`a90d3f66704d85889945fec5525ea77622549da83aced1aac99828383f8f1805`.

The other nine embedded inputs exactly match
[`feeRnt/ps4-linux-12xx/extra_firmware` at `1fdfbd9a4c5690602893f6d5f65e154c6d9ba711`](https://github.com/feeRnt/ps4-linux-12xx/tree/1fdfbd9a4c5690602893f6d5f65e154c6d9ba711/extra_firmware).
No firmware-specific redistribution notice was found there. A generic kernel
COPYING file or a neighboring driver's GPL/BSD header does not establish their
firmware license. These inputs are excluded from new release assets pending
resolution. Historical binaries remain outside the new tester release.

GitHub source archives exclude historical firmware, payloads and binary/log
checkpoints using `.gitattributes`. The custom corresponding-source release
asset contains the complete patched Linux source, its config and build inputs,
and excludes staged firmware.
