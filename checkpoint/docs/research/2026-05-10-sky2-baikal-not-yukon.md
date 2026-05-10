# sky2 on Baikal — diagnosis: not a Yukon-2

**Date:** 2026-05-10
**Method:** hot-test from SSH against running 6.x kernel (no kernel rebuild)
**Probe script:** `scripts/dev/sky2-probe.py` (saved alongside this doc)
**Verdict:** Sony's Baikal GbE (`PCI 104d:90d8`) is not a Marvell Yukon-2.
sky2 driver cannot be made to work via PCI-quirk patches — would require
a from-scratch driver port for the actual MAC architecture.

---

## What we found

PCI device summary:

```
00:14.1 System peripheral [0880]: Sony Corporation Baikal Ethernet Controller [104d:90d8]
        Subsystem: Sony [104d:90df]
        Class 0x088001 (System peripheral, prog-if 1)  ← NOT Ethernet (0x020000)
        BAR 0: 4 KB at 0xc2000000
        Capabilities: PCIe Endpoint, MSI Maskable+, Power Management
        LnkSta: Speed 5GT/s, Width x4
```

Live BAR0 dump (no init, after sky2 probe failed and unbound):

```
[0x0000] 79498100 00000000 0f597c00 03b0030c
[0x0010] 00000085 00002ccc 44570b3a 0003202d
[0x0020] 00000000 00000000 00000000 0000ff00
[0x0030] 00010100 00000000 00000000 10000400
[0x0040] 10004e30 10000000 10004000 00000000
[0x0050] 00000002 00001018 00000000 00100020
[0x0060] 00000000 a0000200 00000000 00000000
[0x0070] 00014000 00002277 00000000 017d7840
[0x0080] 000002bb 00000000 00000000 00000000
[0x0090] 00000000 00000000 00000002 0000006f
[0x00a0] 00000000 00000000 00000000 00000009
[0x00b0] 001f03ff 001fffff 00000000 00000000
[0x00c0..0x10f] all zeros
[0x0110] 00000040  ← decreases over reads (0x40→0x2f→0x25→0x00) — counter
[0x01c8] 00a00000
```

38 non-zero u32s found across the 4 KB BAR. None at offsets where sky2's
B2_CHIP_ID (0x011b) lives.

## What we ruled out

| Hypothesis | Test | Result |
|---|---|---|
| Aeolia init magic (0x60/0x64/0x68/0x6c writes) wakes Baikal too | Wrote those values, then `B0_CTST=CS_RST_CLR`, then re-read | **Zero effect** — every register identical before/after |
| `B2_CHIP_ID` at 0x011b just needs `CS_RST_CLR` | Wrote `0x02` to 0x004, re-read 0x011b | Still 0x00 |
| Maybe chip_id is at a shifted offset | Scanned full BAR, looked for `0xb3..0xbe` (Yukon range) at any byte offset | None found |
| Maybe the BAR is power-gated and needs a PCI command-register tweak | PCI command already had Mem+, Status had no errors | Already accessible, not a power issue |
| Other PS4 Linux trees solved this | Surveyed whitehax0r, noob404yt, baikal-bringup, crashniels, feeRnt, rmuxnet | Every tree comments out Baikal PCI ID. rmuxnet's "experimental" branch (`846b0b28`) just enables the ID + reuses Aeolia init. No tree has working sky2 on Baikal |

## Why this isn't tractable as a sky2 patch

Sky2 is a Marvell Yukon-2 driver. Its register layout assumes:
- `B2_CHIP_ID` at offset 0x11b is the first byte of a Yukon-2 chip family ID
- B0_CTST/B2_MAC_CFG/B2_PMD_TYP at 0x004/0x11c/0x11d
- 16 KB MMIO region with TX/RX descriptor blocks at known offsets
- Specific reset sequence (CS_RST_SET/CLR, ASF disable, GMAC link reset)
- Marvell PHY at addr 0/1 reachable via SMI registers

Baikal's MAC has none of those. Class code says it's not even an
Ethernet device per PCI's taxonomy. Whatever it is, it has its own
register layout (the 38 non-zero offsets above), its own init protocol
(presumably via PS4 ICC firmware commands), and its own descriptor
format.

## To do this properly would require

1. **Identify the MAC architecture** — is it a Sony custom design? A
   FreeBSD bxe/fxp derivative? A licensed soft-MAC? Need PS4 OS source
   or hardware spec.
2. **Map the 38 non-zero registers to functions** — dump while traffic
   is running on PS4 OS, see which change. Need PS4-side instrumentation
   or hardware analyzer.
3. **Find the ICC init sequence** — PS4 firmware likely sends ICC
   command(s) to power up / configure the MAC before the OS can use it.
   Compare boot-time ICC traffic on PS4 OS vs Linux.
4. **Implement TX/RX rings against unknown hardware** — DMA descriptor
   format, ring management, interrupt handling.
5. **PHY support** — the link partner negotiation, MII registers.

Estimated effort: weeks to months. No upstream reference. Single-person
RE project.

## Recommendation: park indefinitely

Given:
- WiFi is already working via rtw88_8822bu + USB TP-Link (commit `abe29da`+v62)
- SSH access from host is functional
- mt7668 internal WiFi is a much smaller port (~1 day per
  `checkpoint/docs/study/08-mt7668-port-todo.md`)

Sky2 on Baikal is not the right place to spend effort. Document and
move on.

## What's saved for the future

- This doc
- `scripts/dev/sky2-probe.py` — userspace BAR0 prober. Run as root with
  `python3 sky2-probe.py {dump,scan-nonzero,aeolia-init,reset,compare}`.
  Reusable for any future PS4 GbE work (or for similar RE on other
  obscure PCI devices on PS4 hardware).

If anyone in the future picks this up, they should start by:
1. Comparing this BAR dump to a PS4 OS `freebsd kgdb` session memory
   dump of the same address range during normal network traffic
2. Looking at the Sony BSD source in any leaked PS4 OS material
3. Reverse-engineering the ICC commands related to Baikal GbE
