# PS4 Linux Boot — Working Checkpoint

**Status as of 2026-05-06:** Linux successfully boots on PS4 Slim Baikal (CUH-2xxx, FW 12.020). systemd reaches SSH-reachable state on the host at `192.168.50.125`.

## What's in this folder

```
checkpoint/
├── boot/             # files for the FAT32 partition on USB (sda1)
│   ├── bzImage              # feeRnt 5.4.247-neocine-1.1, Clang-14 prebuilt
│   ├── initramfs.cpio.gz    # better-initramfs External HDD variant (DionKill)
│   ├── bootargs.txt         # tested-working kernel cmdline (earlycon at 0xC890E000)
│   ├── vram.txt             # 1024 — matches the 1024 MB payload
│   └── config_kernel        # kernel .config feeRnt's bzImage was built with
├── payload/          # files for /data/payloads/ on the PS4 (via FTP/2121)
│   ├── linux-1024mb.bin     # ArabPixel v24b unified Linux loader, 1 GB VRAM
│   └── linux-2048mb.bin     # ArabPixel v24b, 2 GB VRAM (post-install variant)
├── screenshots/      # death-screen photos from earlier failed attempts (kept for reference)
└── SHA256SUMS        # hashes of every known-good blob above
```

The rootfs tarball (deeWaardt's "Arch - Baikal Ed.", ~2.17 GB compressed) is **not committed** here — see `rootfs/README.md` for the link and integrity details.

## Hardware

| | |
|---|---|
| Console | PS4 Slim, Baikal B1 (CUH-2xxx) |
| CPU | Jaguar APU, 8c, **AVX1 only** (no AVX2 / FMA / BMI*) ≈ x86-64-v2 |
| Firmware | 12.020 (release_branches/release_12.020) |
| GoldHEN / payload host | PSFree-Enhanced, Payload Guest |

## Reproducible boot procedure

### 1. Partition the USB

```
sda1   2 GiB    FAT32   (label optional, "PS4BOOT" works)
sda2   rest     ext4    label = "psxitarch"   (exact label matters — better-initramfs mounts by label)
```

(See `scripts/install-arch-usb.sh` for the original create-partitions step. The `e2label` and `mkfs.fat` flags need to be exactly as documented; `psxitarch` is hardcoded into better-initramfs's `/init`.)

### 2. Drop the boot files on FAT32

Copy `checkpoint/boot/*` to the **root** of the FAT32 partition. Final layout:

```
PS4BOOT/
├── bzImage
├── initramfs.cpio.gz
├── bootargs.txt
└── vram.txt
```

### 3. Install rootfs onto ext4

Wipe `sda2` (label MUST be `psxitarch`) and untar the **deeWaardt Baikal-built Arch tarball** onto it:

```
sudo bash scripts/install-deewaardt-rootfs.sh
```

(The tarball must be at `~/Downloads/ps4linux.tar.xz`. See `checkpoint/rootfs/README.md` for source.)

> **Critical: do NOT use `pacstrap` from a modern Arch/CachyOS host.** Their packages are built for `x86-64-v3` (require AVX2), which the PS4 Jaguar CPU lacks → systemd SIGILLs immediately, kernel panics with `Attempted to kill init! exitcode=0x0000000b`. Use only the deeWaardt tarball or another v2-baseline build. See `docs/LEARNINGS.md`.

### 4. Drop the payload onto the PS4

Upload `checkpoint/payload/linux-1024mb.bin` to the PS4's `/data/payloads/` (FTP, port 2121, anonymous):

```
curl -u anonymous: -T checkpoint/payload/linux-1024mb.bin \
  "ftp://<PS4-IP>:2121/data/payloads/"
```

Use `1024mb` for first install / first boot. After confirmed working, you can switch to `linux-2048mb.bin` for more VRAM.

### 5. Boot

1. PS4 → exploit chain (PSFree-Enhanced → GoldHEN), then Payload Guest
2. Select `linux-1024mb.bin`
3. Wait for PS4 to shut down then boot Linux

Expected on screen:
- Verbose kernel boot logs (we set `console=tty0`)
- `better-initramfs ${ver}. Linux kernel ${kernelver}.`
- 10-second sleep
- `Switching root to /newroot and executing /sbin/init`
- systemd colored output, eventually login

PS4 will get a DHCP lease on your LAN — ssh in as `ps4`/`ps4`.

## What's NOT in this checkpoint (yet)

- A repository-built bzImage. Our self-built 5.4 (Clang 22) and 6.x (GCC 15) bzImages **fail to boot** on this PS4 even though they compile cleanly. We don't know yet whether the issue is toolchain-related, config-related, or something else. For now we use feeRnt's prebuilt as the working baseline. Investigation deferred — see `9000-todo`.
- Kernel modules. The deeWaardt rootfs ships no `/lib/modules/`; for now we boot off built-in drivers only. WiFi (mt7668) won't work without modules. Wired LAN doesn't work on Baikal at all (per the tutorial).
- A solid story for our 6.x port. The 6.x patch series builds and looks clean but `kexec` triple-faulted with our build (and possibly with v24b payload — to retest now that the loader works for the 5.4 prebuilt).

## Provenance

- **Kernel** — `feeRnt/ps4-linux-12xx`, release `v5.4.247__neocine-1.1`, asset `bzImage_Clang`. Built with LLVM-14 per the release notes.
- **Initramfs** — `DionKill/ps4-linux-tutorial`, file `PS4 Linux/initramfs.zip`, variant `External HDD`. better-initramfs upstream: bitbucket.org/piotrkarbowski/better-initramfs (2021 vintage).
- **Payload** — `ArabPixel/ps4-linux-payloads`, release `v24b`. Unified, runtime southbridge detection by @rmuxnet. Replaces the per-firmware/per-southbridge format from the v23 era.
- **Rootfs** — deeWaardt's "Arch - Baikal Ed." tarball, MEGA link in DionKill tutorial's distros table. Mesa pinned at 25.1 (the Baikal libdrm cap).

All hashes recorded in `SHA256SUMS`.
