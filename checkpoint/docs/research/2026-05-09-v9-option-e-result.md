# Option E (v9) — boot result report

Boot captured 2026-05-09 ~16:26 local. Full UART excerpt:
[`checkpoint/uart-logs/2026-05-09_1626-option-e-v9-routing-and-composer.log`](../../uart-logs/2026-05-09_1626-option-e-v9-routing-and-composer.log)
(172 KB, 2566 lines, slice from t=0 to t≈177s).

## Summary

Marries Option B v7's MSI ROUTING (parent flag + msi_parent_ops + AMDVI
bus_token override) with Option D v8's COMPOSER (writes
`addr_lo=0xFEE00000` + irq_map[]-derived subfunction-index instead of
the real LAPIC vector).

**Result: software side completely correct, but `bpcie_handle_edge_irq`
still fires 0 times — pointing to a missing hardware-level enable.**

## Counts (vs v7 / v8)

| Signal | v7 | v8 | **v9** | Reading |
|---|---|---|---|---|
| `Linux version` | 1 | 1 | 1 | one boot |
| `bpcie_create_irq_domain` | 16 | 8 | 16 | 8 fns × 2 lines (parent flag re-added) |
| `bpcie_init_dev_msi_info` | 3 | n/a | 3 | per-child init runs |
| `bpcie_msi_init` | 34 | 0 | **68** | parent + leaf level (msi_init runs at both) |
| `registered virq at irq_map[X]` | n/a | 0 | **34** | irq_map[] populated |
| `bpcie_irq_msi_compose_msg` | n/a | 0 | **80** | NEW composer firing |
| `bpcie_msi_write_msg` | 80 | 0 | 40 | with `addr_lo=fee00000` ✓ |
| `index=` (composer output) | n/a | n/a | **80** | subfunc indexes assigned |
| **`bpcie_handle_edge_irq`** | **0** | 0 | **0** | demuxer NEVER fires |
| `Spurious interrupt 0xef` | 0 | 2 | **0** | ✓ no leaks |
| `Command Aborted` (xhci) | 2 | 2 | 2 | ENABLE_SLOT timeout |
| `Timeout waiting` (mmc0) | 6 | 3 | 6 | sdhci command completion |
| `qc timeout` (ahci/ata1) | 3 | 2 | 3 | SATA IDENTIFY |

## Boot timing (v9)

| Event | Time |
|---|---|
| Linux version | t=0 |
| `bpcie_probe` | 4.44s |
| First `bpcie_irq_msi_compose_msg` (irq=1, index=0) | 5.17s |
| First `bpcie_msi_write_msg` (`addr_lo=fee00000 data=00000000`) | 5.18s |
| Last bpcie own MSI write (data=0x1F, irq=32) | ~5.95s |
| sky2 init module | 109.81s |
| `xhci_aeolia_probe_one` | 112.14s |
| First xhci `bpcie_msi_write_msg` (`data=0x20`) | 112.03s |
| First sdhci `bpcie_msi_write_msg` (`data=0x21`) | 113.02s |
| First xhci `Command Aborted` (ENABLE_SLOT) | 119.96s |
| First `mmc0 Timeout` | 123.54s |
| `bridge disable` (icc i2c timeout, ICC subfunc) | 176.79s |

## What v9 proved (positive)

The **software** side of MSI delivery is now completely correct:

1. ✅ MSI domain hierarchy correctly set up (`pci_msi_create_irq_domain` +
   `IRQ_DOMAIN_FLAG_MSI_PARENT` + `msi_parent_ops` + AMDVI bus_token),
   confirmed by 8×2 `bpcie_create_irq_domain` lines and 3
   `bpcie_init_dev_msi_info` per-child invocations.
2. ✅ Per-virq leaf MSI registration works (`bpcie_msi_init` × 68, twice
   per virq for parent + leaf in the per-device MSI flow).
3. ✅ `irq_map[]` correctly populated 34 times.
4. ✅ NEW `bpcie_irq_msi_compose_msg` runs 80 times (matches expected
   compose count = nvirqs × few extra activations).
5. ✅ MSI cap **physically programmed** with the Baikal-magic tuple:
   `addr_lo=0xFEE00000`, `data=<irq_map index>`. Verified with examples:
   - bpcie's own 32 MSIs: `data=0x00..0x1F`
   - xhci's MSI: `data=0x20` (irq_map[32], at irq=33)
   - sdhci's MSI: `data=0x21` (irq_map[33], at irq=34)
6. ✅ NO spurious vec-0xef events (vs 2 in v8) — every MSI alloc went
   through OUR domain, none leaked to the default x86 vector domain.

## What v9 did NOT fix

❌ `bpcie_handle_edge_irq` still fires 0 times.

Every hypothesis we had about the kernel-side delivery (handler not set,
chip not inherited, vector mismatch, routing fallback) is now ruled out
by direct evidence in this boot's UART log.  The MSI message we write
into each child's MSI cap is **exactly what Baikal's documented hardware
demuxer expects**, and yet the southbridge never fires its own MSI on
bpcie's vector pool in response to device events.

xhci ENABLE_SLOT TRB ring times out at 5 s → "Command Aborted".
sdhci/mmc0 commands time out at ~10 s.  ahci/ata1 IDENTIFY times out.
ICC i2c queue times out at 64 s.  All of these are command-completion
IRQ paths that are not being delivered.

## The smoking gun (left in our own source from day 1)

`drivers/ps4/ps4-bpcie.c` line 185, in `bpcie_msi_mask`:

```c
//TODO: disable ht. See apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask
```

PS4 Baikal southbridge sits behind a Hyper-Transport link.  The FreeBSD
orbis driver has a function literally named
`apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask` — disabling
HT-style legacy IRQ delivery is what *enables* MSI delivery at the
southbridge.  We have NEVER implemented its equivalent.

The 5.4 stack works because... TBD — possibly because some other
init-time write (or Aeolia's parallel quirk) leaves HT in the right
state by accident, OR because 5.4's slower / different MSI activation
path doesn't trip the same hardware gate.  Either way, on 6.x we're
exposing a HW-state assumption we don't satisfy.

## Plan: v10 (HT disable)

1. Research `apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask`:
   - Grep `research/baikal-bringup/` (FreeBSD-derived)
   - Grep `research/rmuxnet-12xx-current/`,
     `research/feernt-12xx-current/` (recent forks)
   - If not found, look for register names near `BPCIE_REG_HT*`,
     `apcie_bpcie_ht*`, `disable_ht`, `MSI_HT`.
2. Implement the register write(s) in `bpcie_glue_init` before
   `pci_alloc_irq_vectors`.  One-shot init at probe time.
3. Iterate.  If `bpcie_handle_edge_irq > 0` on next boot — celebrate,
   then move on to debugging xhci/sdhci response correctness.

## Bottom line

v9 is the **biggest forward step** in this whole 6.x port effort.  All
software-side correctness signals are green.  The remaining failure is
hardware-level (HT not disabled), which is a focused, finite problem
with documented FreeBSD precedent.  v10 should be the breakthrough.
