# deeWaardt Baikal Arch rootfs

Tarball is **not in this repo** (2.17 GB compressed). Source link:

- **MEGA**: https://mega.nz/file/JNkUgZLY#q-XwRcz81SLyMBE_-RIpbtRZIi2pGaH-8xCc6-uFXRI
- Listed in DionKill PS4 Linux tutorial → "Distros (that you ACTUALLY wanna use)" → "Arch - Baikal Ed.", credit deWaardt.
- Mesa 25.1 (Baikal libdrm cap; newer Mesa won't have GPU accel on 5.4 kernels).

## Local copy on this machine
`~/Downloads/ps4linux.tar.xz` (after manual MEGA download).

## Why this tarball and not pacstrap?
Because Arch has moved its baseline to `x86-64-v3` (requires AVX2/BMI/FMA/LZCNT). PS4 Jaguar APU is roughly `x86-64-v2 + AVX1` — no AVX2. A modern pacstrap'd rootfs immediately SIGILLs in systemd and panics the kernel.

deeWaardt's tarball is built for the older instruction-set baseline and stays compatible with PS4 hardware. Don't replace this with a fresh pacstrap unless you know how to pin to v2 explicitly.

## Sanity check after download
```bash
ls -lh ~/Downloads/ps4linux.tar.xz
# Expect roughly 2.17 GB (2174755144 bytes, May 2026 build)

# Quick contents check
tar -tJf ~/Downloads/ps4linux.tar.xz | head
# Expect bin, etc/, usr/lib/systemd/systemd, ...
# Expect NO /lib/modules/  (rootfs-only, no kernel)
```

## Install
```bash
sudo bash scripts/install-deewaardt-rootfs.sh
```

The script wipes `/dev/sda2`, `mkfs.ext4 -L psxitarch`, untars with `--numeric-owner --xattrs-include='*.*'`, and writes a minimal `/etc/fstab`.
