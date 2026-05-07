# 01 — PS4 hardware

You can't usefully read the patches until you know what's behind each
PCI BDF. This file is the "what chip is what" map.

## The big picture

A PS4 (Slim, our target — CUH-2xxx) is essentially:

```
┌──────────────────────────┐
│  Liverpool APU           │     AMD custom SoC. CPU + GPU on one die.
│  ├─ CPU: 8× Jaguar @1.6  │     Jaguar is x86-64-v2 + AVX1. NO AVX2/BMI/FMA.
│  └─ GPU: GCN1.1 (CIK)    │     8GB GDDR5 unified.
└─────────────┬────────────┘
              │ PCIe (internal)
              │
┌─────────────▼────────────┐
│  Baikal southbridge      │     "Baikal" = revision 3 of the southbridge
│  (CUH-2xxx slim)         │     family. (Predecessors: Aeolia, Belize.)
│                          │     Sony custom silicon, undocumented.
│  Function 0x14.0  Generic root
│  Function 0x14.1  apcie    (legacy aux PCIe glue, Aeolia variant)
│  Function 0x14.4  bpcie    ← **THE most important function**
│  Function 0x14.5  RTC + power button + ICC mailbox
│  Function 0x14.7  xHCI (USB host)
│  Internal: SATA HBA (AHCI) for the 500GB internal HDD
│  Internal: SDHCI host for the WiFi/BT module
│  Internal: Marvell sky2 GbE
│  Internal: 4× 8250-compatible UARTs (MMIO via BPCIe BAR2)
└──────────────────────────┘
```

PCI vendor ID for everything Sony-side is **`0x104D`** (Sony).
The kernel doesn't recognize this vendor by default — patch
`1100-pci-msi/0001-...` adds all 24 device IDs to `pci_ids.h`.

## The Liverpool APU

| Aspect | Detail |
|---|---|
| CPU family | AMD Jaguar (Family 16h, model 41h — `M41H`) |
| ISA | x86-64-v2 + AVX1 + F16C + MOVBE + AES-NI. **No AVX2, no BMI, no FMA, no LZCNT.** |
| Cores | 8 cores in 2 clusters of 4. (Some cores reserved for OrbisOS in stock; full 8 available under Linux.) |
| GPU | AMD GCN 1.1 (Sea Islands / "CIK" in kernel speak). |
| GPU PCI ID | `0x1002:0x9920` (Liverpool), `0x1002:0x9924` (Gladius — Pro variant). |
| Memory | 8GB GDDR5, unified between CPU and GPU. |

The CPU ISA detail matters for **userspace, not the kernel**. Modern
Arch Linux (and CachyOS) ship binaries built for x86-64-v3, which
requires AVX2/BMI/FMA. The PS4 doesn't have any of those. Result:
systemd executes a `vpermd` or `bzhi` after `switch_root` and the CPU
raises `#UD` → SIGILL → `kernel panic - Attempted to kill init!`.

This is **exclusively a userspace bootstrap problem**, fixed by using
a v2-baseline rootfs (deeWaardt's "Arch — Baikal Ed." tarball, or
pre-2024 Arch). The kernel itself is fine on Jaguar — the kernel build
isn't auto-vectorized to v3.

The GPU is what `0300-gpu-liverpool/` patches add support for. In
mainline kernels Liverpool isn't a recognized chip, so amdgpu and
radeon don't bind to it without help.

## The southbridge family

Sony has shipped three southbridge revisions on PS4:

| Name | Console family | First released | Detected by |
|---|---|---|---|
| **Aeolia** | Original PS4 (CUH-1000 series) | 2013 | PCI IDs `0x908F` to `0x90A4` |
| **Belize** | PS4 Slim (CUH-1099+) and Pro early | ~2015 | `0x90C8` to `0x90CF` |
| **Baikal** | PS4 Slim (CUH-2xxx) and Pro late | ~2016 | `0x90D7` to `0x90DE` |

We are on **Baikal-B1** (revision 0x30201). The patch set tries to
support all three families simultaneously where it can; many patches
add three sibling PCI IDs and three sibling probe paths.

Each family has roughly the same logical functions, but the **register
maps differ**, the **BAR layout differs**, and the **probe order
quirks differ**. That's why the 0200-ps4-drivers patches are large —
they encode three flavors of "weird" per subsystem.

## BPCIe — the bridge function

Function 0x14.4 of the Baikal southbridge is named **BPCIe** in the
kernel patches. It's a multi-function PCIe device that fans out to:

- The **ICC mailbox** (Inter-Chip Communication — Linux↔EAP firmware).
- **4× 8250-compatible UARTs** at MMIO offsets in BAR2 (see [05-uart.md](05-uart.md)).
- Power button input (forwarded as a Linux input device).
- RTC (real-time clock) — though Linux currently uses dummy RTC stubs.

Driver: `drivers/ps4/ps4-bpcie-*` (added by patch group 0200). It's
written as an MFD-style multi-function driver: BPCIe probes, then
fans out child devices.

Critical fact: **BPCIe also parents the xHCI USB host (0x14.7) and
the AHCI SATA controller** in the bus topology. So BPCIe glue
breaking = USB and storage break too. This is why
`keep_bootcon` (which hammers the BPCIe UART register from the
printk path forever) crashes xhci_aeolia at ~57s on 5.4 — the BPCIe
bus saturates.

## Where each driver lives

| Subsystem | PCI BDF (Baikal) | Driver | Patch group |
|---|---|---|---|
| Generic root | `00:14.0` | (bridge) | — |
| apcie aux | `00:14.1` | `drivers/ps4/ps4-apcie*` | 0200 |
| BPCIe glue | `00:14.4` | `drivers/ps4/ps4-bpcie*` | 0200 |
| RTC + powerbutton + ICC | `00:14.5` | `drivers/ps4/icc/*` | 0200 |
| xHCI USB | `00:14.7` | `drivers/usb/host/xhci-aeolia.c` | 0800 |
| AHCI internal HDD | (varies) | `drivers/ata/ahci.c` + Baikal quirks | 0400 |
| SDHCI (WiFi host) | (varies) | `drivers/mmc/host/sdhci-pci-*` | 0500 |
| Marvell sky2 GbE | (varies) | `drivers/net/ethernet/marvell/sky2.c` | 0700 |
| MT7668 WiFi/BT | (SDIO child) | `drivers/net/wireless/mediatek/mt76x8/` | 0600 (5.4 only) |
| Liverpool GPU | `00:01.0` | `drivers/gpu/drm/amd/{amdgpu,radeon}/` | 0300 |
| AMD IOMMU | (in CPU) | `drivers/iommu/amd/` | 1000 |

The patch group numbers are the apply order. Group 0100 lays the x86
platform foundation (`X86_SUBARCH_PS4` etc.) so that 0200 has
something to register against. Everything else builds on top.

## Things you'll see in patches that take a moment to recognize

- **`apcie_status()`** — returns 0 once the apcie driver has finished
  enumerating its children. Other PS4 drivers `defer` until this is
  true. It's the PS4-specific "wait for southbridge to be ready" gate.
- **`bpcie_status()`** — same idea, for bpcie. It's why the UART
  driver and xHCI driver can't probe immediately at boot — they have
  to wait for the bridge function to be set up.
- **`apcie_assign_irqs()`** — PS4's custom MSI routing helper. Returns
  pre-allocated MSI vectors for the southbridge children. The standard
  `pci_alloc_irq_vectors()` doesn't work for these because the IRQ
  topology is non-standard.
- **`x86_fwspec_is_aeolia()`** (new in 6.x) — predicate that the new
  IRQ-domain machinery uses to recognize Aeolia/Baikal MSI sources.
  This abstraction didn't exist in 5.4; it had to be invented for the
  6.x port. **Suspect site for 6.x boot hangs** — see [07-failure-analysis.md](07-failure-analysis.md).

## Why none of this is documented by Sony

Because the southbridge is custom silicon that Sony never published
specs for. Every register offset, every probe sequence, every PHY
init macro in `0400-storage-ahci/0001-...patch` was reverse-engineered
by the PS4 hacking community (whitehax0r, fail0verflow, DFAUS, feeRnt,
crashniels, ArabPixel, deeWaardt). The patches are essentially a
written-down reverse-engineering result. When something looks
arbitrary, it usually IS arbitrary in the sense that "this is what
works on real silicon", not "this follows a documented standard".

Next: [02-boot-chain.md](02-boot-chain.md) — how Linux actually gets onto a PS4.
