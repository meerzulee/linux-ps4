# v133 — Orbis BAR2+0x10a030 chip-tuning RMW (FALSIFIED)

## TL;DR

Tested the "strongest remaining hypothesis" identified at the end of the
v126-v132 hunt: replicate the Ghidra-decompiled Orbis bpcie attach
read-modify-write at parent BAR2+0x10a030
(`(val & 0xfffffe07) | 0xd8`).  The RMW executed cleanly at boot,
the math matches Orbis exactly, but **the TX gate did not unlock**.
Same silent-TX failure mode as v126-v132 — `tx_cons` frozen at 0,
total_irq frozen at 1, HW refuses to fetch a single descriptor.

This closes the BAR2+0x10a030 lead.  TX silicon-gate root cause
remains unknown.

## What v133 did

Patch: `patches/6.x-baikal/0200-ps4-drivers/0099-bpcie-v133-baikal-chip-tuning-write.patch`

Adds one RMW inside `bpcie_glue_probe()` on the parent (00:14.4) BAR2
before any subfunctions probe:

```c
val = ioread32(bar2 + 0x10a030);
iowrite32((val & 0xfffffe07) | 0xd8, bar2 + 0x10a030);
```

Hypothesis: 0x10a000 sits between HPET (0x109000) and UART (0x10e000)
in parent BAR2.  Orbis programs it during bpcie attach; Linux never
touched it.  Bits 3,4,6,7 looked like a clocking/fabric tuning
parameter that could gate the host→chip DMA fetch path while leaving
chip→host RX writes unaffected (matching the v93-v98 "RX works, TX
dead" pattern).

## Boot evidence — patch executed correctly

From `checkpoint/uart-logs/2026-05-14_1556-v133-bar2-chip-tuning-dmesg.log:347`:

```
[    1.456788] baikal_pcie 0000:00:14.4: v133: BAR2+0x10a030 0x000016c9 -> 0x000016d9 (Orbis chip tuning)
```

Math verification:

```
before  = 0x000016c9 = 0001 0110 1100 1001
mask    = 0xfffffe07 = ...1111 1110 0000 0111
val&msk = 0x00001601 = 0000 0000 0001 0110 0000 0001
OR 0xd8 = 0x000016d9 = 0000 0000 0001 0110 1101 1001
                                ^^^^         (bits 3,4,6,7 set, bits 5,8 clear — matches Ghidra)
```

Matches the Orbis decompile byte-exact.

## Hardware result

| Signal | v131 (msi-mask-skip) | v133 (chip-tuning) | Change? |
|---|---|---|---|
| `bzImage` md5 | `8b4fe068…` | `b94d9f71…` | new |
| ps4_mts loaded | ✅ | ✅ | — |
| PHY link / carrier | ✅ (`linkreg=0xb18`) | ✅ (`linkreg=0xb18`) | — |
| `/sys/.../speed`,`duplex` | Invalid argument | **Invalid argument** | — |
| TX `tx_prod` advancing | yes | yes (→ 93 in 197s) | — |
| TX `tx_cons` | frozen at 0 | **frozen at 0** | — |
| TX-completion IRQs | 0 | **0** | — |
| `total_irq` counter | 1 | **1** (frozen at boot value) | — |
| `ip -s link` TX packets | 0 | **0** | — |
| `ip -s link` RX packets | 0 | **0** | — |
| `ip -s link` TX dropped | small | 5 (ring-full from initial bursts) | — |

Live readback from `checkpoint/uart-logs/2026-05-14_1556-v133-bar2-chip-tuning-dmesg.log:1490` after ~197s of uptime:

```
[  197.809249] ps4_mts 0000:00:14.1: DBG: linkreg=0x00000b18 rxkick=0x00000005 \
  txkick=0x00000008 mask=0x007beffe status=0x00000040 total_irq=1
```

Same exact register state as the start of boot, after the kernel has
queued 94 TX descriptors and waited 3+ minutes.  HW state is frozen.

## Conclusion

**Falsified.**  The BAR2+0x10a030 chip-tuning RMW is **not** the TX
gate.  v133's write is real (verified by readback in the same log
line) and matches Orbis exactly, yet behavior is bit-for-bit identical
to v126-v132 with the write absent.

The Orbis sequence at this offset is presumably load-bearing for
*something* (or it would not be in their driver), but it is not the
gate that lets host-issued TX descriptors get fetched.  Either:

1. It runs but its effect is on a downstream path the TX gate sits
   behind (and the gate is something else), or
2. It depends on additional prior state we have not replicated
   (clock domain, parent reset sequence, an earlier register write
   ordering), so the write succeeds but the bit settling does nothing.

Either way, this single-register hypothesis is exhausted.

## What this means for the search space

After v82..v133 we have now ruled out every concrete
register-level write the Ghidra-decompiled Orbis bpcie+mts attach
performs that we had not already replicated, **excluding** the
BAR2+0x2880 "Path G to switch core" write (v124 wedged the PS4 when
tried from userspace — still untested in-kernel).

Surviving hypotheses, ranked:

1. **Parent BAR2+0x2880 (Path G)** — only known Orbis programming we
   have not replicated.  Requires in-kernel implementation
   (`pci_request_regions` on 00:14.4, ioremap parent BAR2, write to
   0x2880).  Real wedge risk per v124.  See
   `checkpoint/docs/research/v126-v130-tx-gate/RESULT.md` §"Remaining
   hypothesis" for the prep notes.
2. **Ordering / timing of an existing write.**  Some Orbis-side
   ordering constraint (e.g. write A must happen before reset B clears
   in HW) that none of our static-snapshot comparisons can see.
   Hard to attack without a live JTAG / SDK trace.
3. **Unmodeled side channel.**  ICC mailbox, ACPI method, or another
   peripheral that Orbis touches en route that affects the MAC
   silicon's gate.  Lowest prior, but cannot be excluded.

## Next iteration recommendation

Move to in-kernel BAR2+0x2880 write (hypothesis 1).  Same risk profile
as v124's wedge but executed from kernel context where we can
coordinate with the parent device's `pci_request_regions` ownership.
Stage `bzImage-stable` as a clean rollback path before testing in case
PS4 wedges and we need to recover the next boot.

## Artifacts

- Patch: `patches/6.x-baikal/0200-ps4-drivers/0099-bpcie-v133-baikal-chip-tuning-write.patch`
- Full dmesg (1490 lines): `checkpoint/uart-logs/2026-05-14_1556-v133-bar2-chip-tuning-dmesg.log`
- Ethernet state snapshot: `checkpoint/uart-logs/2026-05-14_1556-v133-bar2-chip-tuning-ethstate.log`
- Source-of-truth lines: 347 (v133 RMW init), 1488-1490 (frozen state at t=197s)
- Prior context: `checkpoint/docs/research/v126-v130-tx-gate/RESULT.md` (v126-v132 hunt)
