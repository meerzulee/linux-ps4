# Experimental Baikal polling netdevice

`psx_mts_net.c` implements a manually loaded `psx0` Ethernet netdevice for the
tested Sony104d:90d8 Baikal system and exact kernel `6.18.44-ps4-baikal`.
It is excluded from the normal target/patch series. EXP-20261017-014 passed the first bounded DHCP and bidirectional TCP test.
This remains an experimental module with an unresolved ordinary lifecycle.

The candidate incorporates the [verified PHY handoff correction](../../../docs/BAIKAL-MTS-HANDOFF.md)
after the bounded native MAC stop/normalization and before publishing DMA:
positively identify PHY0 `03a29441`, page0/BMCR1040,
accept MMD30:0147 only as0010 or0000, clear0010 to0000 once and verify observed
PHY/MAC link. It retains autonegotiation and the inherited MAC configuration
and valid hardware unicast address. Unexpected hardware/state is refused.

It uses256-slot coherent TX/RX rings, fixed coherent1536-byte bounce buffers,
one Linux queue, BQL and NAPI scheduled by a1ms timer. It does not enable
hardware interrupts: the verified native IRQ bit assignment differs from the
related STAR controller. IPv4 with untagged frames and MTU up to1500 is the
initial test scope. VLAN/checksum/segmentation offloads and address changes
are unavailable; RX checksum validation remains with the network stack.
Native RX lengths are copied without subtracting an FCS. CRC/oversize drop
bits24/25 are conservative related-STAR comparisons, rather than a separately
observed Sony error injection result. RX drops are counted by category. TX completion re-kicks pending descriptors
as observed in the native handler. Healthy positive-budget NAPI polls also
resume RX when no frame completed; the polling frequency is an experimental
adaptation of native stall handling.

## First hardware result: EXP-20261017-014

On 2026-10-17, the exact manually loaded candidate on a fresh Linux boot
obtained DHCP and transferred4194304 application bytes each way. Primary
regenerated the nonce payload and checked the downloaded bytes; the independent
peer verified the upload SHA256. The driver completed3297 TX/3039 RX packets
(12/11 full256-slot ring laps), zero reported drops/errors, and an acknowledged
normal stop. Wi-Fi SSH/default routes/DNS and the desktop process survived;
peer temporary network resources were removed. UART continuity was completed.

Tested C SHA256:27ddf3292c76400d472a6512c33ebdbabbb887dae55f474d2906faf7e2d8dc0e.
Module SHA256:7aae39e7f5d3b65668956154dd17a99c1e4391b6c23252fe2477b40e234d7936.
The inherited MMD30:0147 was0010 and became0000, with MAC04b19 before publication.
Curated record: sibling Omarchy `experiments/SESSIONS.md`, EXP-20261017-014;
private full receipts: workspace `lab/ethernet-netdev-2026-10-17/VERIFICATION.json`.

This is one fresh-boot network result, not repeatable cold-boot acceptance or
safe DMA drain/free/remove. The interface is now down with memory/code retained;
no reopen is permitted. No kernel-image, USB boot-file or normal target change
was made for the test.

## Lifetime and test boundary

Probe registers a carrier-off interface with opening disabled. A sealed
fresh-boot runner must check the exact module/configuration and explicitly
open the LIVE-only `allow_open` gate. There is one opening attempt per module
lifetime and a maximum180-second lease. This must never run on a boot with
retained diagnostic modules or DMA from an earlier experiment. Do not install
it in module-load configuration or NetworkManager auto-connect profiles.

Immediately before the first device-visible ring address, the module takes a
permanent self-reference. After publication, normal close, lease expiry,
watchdog/fault, shutdown or removal stops CPU producers/timer/NAPI, attempts
bounded native engine stops and **retains every DMA buffer, mapping, device
reference, BAR claim, netdevice and module code**. Interface reopen is refused.
No reset/recovery or force unload is supported. Full power-off ends this
experimental lifetime. The first terminal-stop entry caches status, hardware pointers and software
cursors before quiescence for attribution; it is a non-atomic observation.
A stop acknowledgement does not prove DMA drain;
ordinary Linux close/remove/quiescence compliance remains unproved. PHY
renegotiation/link monitoring after initial open is also not implemented.

The intended first acceptance experiment is one clean boot, DHCP without a
gateway or DNS, then4MiB hash-checked transfers in both directions over the
direct cable, with more than256 packets each way to exercise ring wrap. Wi-Fi
SSH and the desktop remain the recovery path. Run it only through a reviewed
host-specific runner and one coherent UART session; a build or registered
interface alone does not establish working Ethernet.

## Build and host verification

Use the exact prepared target's `.config`, `Module.symvers` and release;
the Makefile checks the accepted configuration/release. Linux x86-64 can
build natively. On macOS ARM64 use the repository's OrbStack Linux cross-build
workflow and `x86_64-linux-gnu-`; do not compile the module on Darwin.

```sh
make KDIR=/absolute/path/to/prepared/6.18-baikal CROSS_COMPILE=x86_64-linux-gnu- W=1
make host-test
make host-test-sanitize
```

Host tests cover complete DMA extent validation, ownership/completion gating,
all256 indices, EOR and repeated wrap/reuse, full-ring backpressure, RX lengths,
whole-frame flags and qualified error/VLAN filters. They exercise portable
helpers used by the driver, not the physical MAC or memory ordering on Baikal.
Host binaries/debug artifacts use temporary directories and are not shipped.

## Provenance

Original GPL-2.0-only implementation by the Linux psX project, informed by
the project's reviewed EXP012/013 GPL experiments and private native-driver
register/descriptor observations. Native firmware is not included and is not
needed to compile. Those observations distinguish source-derived behavior
from measured hardware behavior in the linked handoff finding.

The related Linux MediaTek STAR driver supplies named descriptor/register
comparisons and Linux networking API examples; it is GPL-2.0-only, authored by
MediaTek/BayLibre and Bartosz Golaszewski. It is not a drop-in Sony PCI driver:

https://github.com/gregkh/linux/blob/1efe5d048a391de3ead2804b2e7f86376c356cc5/drivers/net/ethernet/mediatek/mtk_star_emac.c

The exact pinned kernel's networking/NAPI contracts govern the Linux side:

https://github.com/gregkh/linux/blob/1efe5d048a391de3ead2804b2e7f86376c356cc5/Documentation/networking/driver.rst

https://github.com/gregkh/linux/blob/1efe5d048a391de3ead2804b2e7f86376c356cc5/Documentation/networking/napi.rst
