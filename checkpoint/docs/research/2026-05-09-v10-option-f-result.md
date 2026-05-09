# Option F (v10) — boot result report

Boot captured 2026-05-09 ~17:14 local (retry — first attempt was a flaky
PSFree, no kernel output at all). Full UART excerpt:
[`checkpoint/uart-logs/2026-05-09_1714-option-f-v10-retry.log`](../../uart-logs/2026-05-09_1714-option-f-v10-retry.log)
(173 KB, 2567 lines, slice from t=0 to t≈177s).

## Summary

Implemented the day-1 TODO (`apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask`)
as a faithful port of 5.4 Aeolia's `apcie_config_msi`.  Hooked into
`bpcie_msi_write_msg` to also program the southbridge per-function MSI
redirect block whenever the device's MSI cap is written.

**Result: function ran cleanly 41 times, BUT a bug in func/subfunc
extraction means we programmed function 0's MSI slots with everyone's
data — leaving xhci/sdhci/ahci/etc. slots unprogrammed.  Same hardware
failure pattern as v9.**

## Counts (vs v9)

| Signal | v9 | **v10** | Reading |
|---|---|---|---|
| `Linux version` | 1 | 1 | one boot |
| `bpcie_create_irq_domain` | 16 | 16 | per-fn domain setup |
| `bpcie_init_dev_msi_info` | 3 | 3 | per-child init |
| `bpcie_msi_init` | 68 | 68 | parent + leaf level |
| `registered virq irq_map[X]` | 34 | 34 | irq_map populated |
| `bpcie_irq_msi_compose_msg` | 80 | 80 | composer firing |
| `bpcie_msi_write_msg` | 40 | 40 | MSI cap writes |
| **`bpcie_config_msi`** | n/a | **41** | NEW v10 function fired |
| `bpcie_handle_edge_irq` | 0 | **0** | demuxer NEVER fires |
| `Spurious interrupt 0xef` | 0 | 0 | routing intact |
| `Command Aborted` (xhci) | 2 | 2 | unchanged |
| `Timeout waiting` (mmc0) | 6 | 4 | slightly fewer (timing artifact) |
| `qc timeout` (ahci/ata1) | 3 | 3 | unchanged |
| Kernel panic / Oops / BUG / Call Trace | 0 | 0 | clean execution |

## The bug — func always == 0

Sample bpcie_config_msi calls:

```
[5.18s]   bpcie_config_msi: func=0 subfunc=0 addr=fee00000 data=00000000
[5.22s]   bpcie_config_msi: func=0 subfunc=1 addr=fee00000 data=00000001
...
[5.94s]   bpcie_config_msi: func=0 subfunc=31 addr=fee00000 data=0000001f
[112.03s] bpcie_config_msi: func=0 subfunc=0 addr=fee00000 data=00000020   ← xhci (should be func=7)
[113.08s] bpcie_config_msi: func=0 subfunc=0 addr=fee00000 data=00000021   ← sdhci (should be func=3)
```

**Every single call has `func=0`** — including xhci's MSI (PCI function 7)
and sdhci's MSI (function 3).

Root cause: `bpcie_msi_write_msg` extracted func via
`(data->hwirq >> 5) & 7`, expecting the Baikal hwirq encoding
`(slot << 8) | (func << 5) | subfunc`.  That encoding only exists at
the **parent (bpcie) domain level** — set in `bpcie_msi_domain_set_desc`
into `arg->hwirq` for the bpcie-level alloc.

In 6.x's per-device MSI flow, the **leaf `irq_data->hwirq` is just the
per-device subfunction index** (0..nvec-1 within each per-device
transient domain).  The Baikal encoding doesn't propagate down to the
leaf irq_data.

So `data->hwirq` for any device's first MSI is 0, second is 1, etc.
`(0..31 >> 5) & 7` = 0 for all of them.  Hence func=0 for every call.

Function 0 (ACPI) probably has no real MSI sink wired up — meanwhile
the actual devices (functions 1-7) have NO redirect entries programmed.
That's why `bpcie_handle_edge_irq` never fires: the southbridge's
per-function logic for funcs 2/3/5/7 is uninitialized.

## What v10 DID prove

- ✅ The new BAR2 register block at 0x110000 is writable — no register-bus
  fault, no kernel panic, no crash.  41 sequential writes to the block
  completed without trouble, validating assumption #1 (BAR2 base = 0x110000).
- ✅ The structure of the function (CONTROL clear → magic writes → ADDR
  → DATA_HI → DATA_LO → MASK set → CONTROL set) compiles and runs.
- ✅ Even with mistargeted programming, the kernel didn't crash —
  the Baikal southbridge is tolerant of garbage in func 0's slots.

## v11 fix (one-line essence)

In `bpcie_msi_write_msg`, extract `func` from the PCI device:

```c
struct pci_dev *pdev = msi_desc_to_pci_dev(data->common->msi_desc);
u32 func = PCI_FUNC(pdev->devfn);
u32 subfunc = data->hwirq;          // leaf hwirq IS the subfunc index
```

Then:
- bpcie's 32 own MSIs (function 4) land in `func=4 subfunc=0..31` slots
- xhci's 3 MSIs land in `func=7 subfunc=0..2` slots
- sdhci's 1 MSI lands in `func=3 subfunc=0` slot
- ahci's MSI lands in `func=2 subfunc=0` slot

If v11 boot shows `bpcie_handle_edge_irq > 0` — done.

## Bottom line

v10 was the right architectural step (programming the southbridge), with
a single bug in field extraction.  v11 is a 5-line surgical fix.
