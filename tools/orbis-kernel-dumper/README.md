# orbis-kernel-dumper

Port-9020 PS4 payload that dumps the running Orbis kernel to USB.
Built for **FW 12.02 via PSFree-Enhanced**, but works on any FW the
vendored SDK supports (5.00 → 13.50).

The dumped `kernel.elf` is the input for the RE work in
[`checkpoint/docs/research/orbis-kernel/`](../../checkpoint/docs/research/orbis-kernel/),
primarily to find PS4-specific UVD/VCE power-on sequences (v71 work) and
the Synopsys DWMAC1000 ethernet driver layout (v69 follow-up).

## Build

```
cd tools/orbis-kernel-dumper
make
# → orbis-kernel-dumper.bin
```

The first build also compiles the vendored SDK
(`vendor/ps4-payload-sdk/libPS4`) into `libPS4.a`; later builds reuse it.
Run `make sdk-clean` if you change SDK source or want a clean rebuild
end to end.

Prereqs: `gcc`, `make`, `binutils` (i.e. host `build-essential` /
`base-devel`). No PS4 toolchain or cross-compiler is required — the
SDK assembles a PS4 ELF directly from host x86_64 gcc with PIC + custom
linker script.

## Use

1. Copy `orbis-kernel-dumper.bin` to your PS4 USB drive (FAT32 or exFAT)
   alongside `linux-1024mb.bin`. The USB does **not** need to be
   reformatted or repartitioned — the dumper writes into a new
   `orbis-dump/` subdirectory.
2. Boot **PSFree-Enhanced** in the PS4 browser (your existing chain:
   WebKit → Lapse → port-9020 Payload Loader).
3. From the Payload Guest UI, load `orbis-kernel-dumper.bin` instead of
   `linux-1024mb.bin`.
4. PS4 will show a sequence of notifications:
   - `Orbis kernel dumper starting (FW 12.02, kbase=0x…)` — kbase resolved
   - `Waiting for USB device…`
   - `Kernel size: NN MB. Starting dump…`
   - `Dumping kernel to USB0: 10%` (every 10% up to 100%)
   - `Done. kernel.elf written to USB0/orbis-dump/1202/`
   - `Power off the PS4 and pull the USB to retrieve.`
5. Power off the PS4 (the dumper doesn't shut down for you).
6. Pull the USB. On the host:
   ```
   cp /run/media/$USER/PS4BOOT/orbis-dump/1202/kernel.elf \
      checkpoint/docs/research/orbis-kernel/orbis-12.02.elf
   ```
7. The ELF is ~70–90 MB. Open in Ghidra (free), set the base to whatever
   `kbase` was reported in the boot notification (ASLR makes it different
   each run).

## Output layout on USB

```
/mnt/usb0/
├── linux-1024mb.bin            ← your existing Linux payload (untouched)
├── linux-2048mb.bin
├── bzImage, initramfs.cpio.gz   ← your existing Linux boot files
└── orbis-dump/                  ← created by this dumper
    └── 1202/                    ← FW version subdir
        └── kernel.elf
```

## What it does (logical view)

1. `jailbreak()` — escape FreeBSD sandbox via ucred + prison0 patches
   (SDK uses K1202 offsets from `fw_defines.h`).
2. `get_kernel_base()` — kexec into kernel mode, read IDT entry for
   xfast_syscall, subtract `K1202_XFAST_SYSCALL=0x1C0` to get kbase.
   Returns kbase to userspace via SDK copyout.
3. Walk the kernel's ELF program-header table to compute total in-memory
   size (typically 70–90 MB).
4. Open `/mnt/usbN/orbis-dump/<FW>/kernel.elf` for writing.
5. Loop in 4 KB chunks: `get_memory_dump(kbase + off, buf, PAGE_SIZE)`
   then `write(fd, buf, PAGE_SIZE)`. Each `get_memory_dump` re-enters
   kernel mode via kexec to do the copyout (slow but reliable).
6. Notify every 10%; final notification when complete.

The ELF includes `.text`, `.rodata`, `.data`, `.bss` and any post-load
allocations the kernel made into its program-header-described regions.
That's enough for Ghidra to find symbols, function boundaries, and most
register-table constants.

## Acknowledgements

- **Scene-Collective** for [`ps4-kernel-dumper`](https://github.com/Scene-Collective/ps4-kernel-dumper)
  (commit `42fce7e`) — most of the kernel-dump loop logic comes from
  their `source/main.c`. We adapted the output paths, notification
  cadence, and a few quality-of-life touches.
- **Scene-Collective** for the [`ps4-payload-sdk`](https://github.com/Scene-Collective/ps4-payload-sdk)
  (commit `2847f1f`) — `libPS4` does all the heavy lifting (FW-aware
  kbase resolution, syscall stubs, USB-mount discovery, jailbreak).
- **egycnq's [LUA-Lapse](https://github.com/egycnq/LUA-Lapse)** — its
  `lapse.lua:1649` table is what we used to verify the SDK's K1202_*
  values are the right ones for FW 12.02 before committing to the port.
- **abc** for the Lapse kernel exploit that makes 12.02 access possible
  in the first place.

## Known limitations / future work

- **kernel.elf is from a live, running kernel.** Some kernel-allocated
  pages may be partially-written/inconsistent at dump time. For RE it's
  fine; for byte-perfect comparison across boots, not so much.
- **No live PCI register snapshot yet.** A v2 of this payload would also
  mmap the Liverpool GPU's BAR0 and snapshot UVD/VCE register values
  while the dumper is running — that's the actual data we need for v71's
  power-on sequence. Deferred until we've RE'd which BAR offsets Orbis
  uses (the static kernel.elf will tell us).
- **No DTB/ACPI tables.** Sony's PS4 doesn't ship a DT/ACPI in the
  conventional Linux sense; device discovery is mostly hardcoded in the
  kernel. We get this from kernel.elf anyway.
