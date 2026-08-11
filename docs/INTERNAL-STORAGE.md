# PS4 internal storage: what is different

Snapshot date: 2026-08-10

## Short answer

External Linux storage is conventional: the loader reads boot assets from a
FAT filesystem and Linux mounts a directly addressable ext4 root filesystem.

The established internal-storage flow is layered:

```text
Baikal AHCI/SATA
  -> Sony disk partition (commonly partition 27, older fallback 13)
  -> AES-XTS decryption using this console's EAP HDD key
  -> Sony UFS2 filesystem
  -> Linux ext4 image stored under the Sony user/home area
  -> loop device
  -> Linux root filesystem
```

Therefore “the HDD appears in `lsblk`” proves only the first layer.

## Reference implementation inspected

The concrete flow below comes from
[`danyboy666/ps4-retrobox` at `6c79062adbe1691707ac3c1ed7baa1f3118734f8`](https://github.com/danyboy666/ps4-retrobox/tree/6c79062adbe1691707ac3c1ed7baa1f3118734f8).
It is documentation of an existing method, not code we should copy unchanged.

Its initramfs:

1. waits for `/dev/sda` for up to 15 seconds;
2. tries `/dev/sd?27`, then `/dev/sd?13` with `cryptsetup`;
3. has a partition-27 fallback using byte skip `111669149696`;
4. opens the mapper as `ps4hdd`;
5. mounts it as UFS2 at `/ps4hdd`;
6. finds a `*.img` file under `/ps4hdd/home/`;
7. attaches the image to a loop device and mounts the ext4 root.

Its installer creates an ext filesystem inside an image file; it does not
repartition the physical PS4 disk into a normal Linux layout. From Orbis, boot
assets are conventionally under `/data/linux/boot/`, while the distro archive
is staged through `/user/system/boot/` and the resulting image lives in the
decrypted user/home filesystem.

## Why it is risky

- The EAP HDD key is per-console secret material. It must be extracted from
  the owner's console, never committed, logged, bundled, or redistributed.
  A maintained extractor reference is [EAPDumper](https://github.com/seregonwar/EAPDumper).
- Device globs such as `/dev/sd?27` are nondeterministic when USB disks are
  present. Selecting the wrong disk can destroy data.
- Waiting for `/dev/sda` does not prove that the intended Sony partition is
  ready or belongs to the internal disk.
- UFS2 write support and unexpected power loss create a real recovery risk.
- Encryption parameters, XTS IV/offset behavior, firmware layout, and partition
  numbering must all match the exact console and firmware.
- A kernel SATA, MSI, or DMA bug below the filesystem layer can corrupt data.

## Policy for this project

Internal storage remains **read-only research** until the 6.18 external-root
kernel passes the complete hardware gate repeatedly.

The first probe must:

1. identify the internal device from a stable PCI/sysfs path, not `/dev/sdX`;
2. record the partition table, sizes, UUIDs, and signatures without writes;
3. require an explicit Baikal internal-AHCI identity;
4. read the EAP key from an operator-supplied, permission-restricted path;
5. open the encrypted layer read-only;
6. mount UFS2 read-only with no recovery writes;
7. verify the expected directory and image signatures;
8. detach every layer cleanly on failure.

Any installer must add explicit target confirmation, backups, free-space
validation, interruption recovery, and a tested uninstall path. Until those
exist, use an external USB root filesystem.

## Kernel requirements

The 6.18 config retains AHCI/SATA, device mapper and crypt target, UFS, loop,
and ext4 support. The Baikal patch path additionally handles the PS4 AHCI BAR,
southbridge IRQ routing, DMA boundary, and SATA PHY setup. Those are necessary,
but they do not make the userspace workflow safe by themselves.
