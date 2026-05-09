# Option D (v8) — boot result report

Boot captured 2026-05-09 ~15:21 local. Full UART excerpt:
[`checkpoint/uart-logs/2026-05-09_1521-option-d-v8-baikallove.log`](../../uart-logs/2026-05-09_1521-option-d-v8-baikallove.log)
(140 KB, 2184 lines, slice from t=0 to t≈38.7s).

## Summary

Architectural pivot to BaikalLove-style legacy MSI domain + custom
`bpcie_irq_msi_compose_msg` writing the Baikal-magic tuple
(`addr_lo=0xFEE00000`, `data=irq_map_index`).  Removed
`IRQ_DOMAIN_FLAG_MSI_PARENT`, `msi_parent_ops`, `bpcie_init_dev_msi_info`,
AMDVI bus_token override.

**Result: REGRESSION — none of our MSI ops fire at all.**

## Counts (vs v7)

| Signal | v7 | **v8** | What it means |
|---|---|---|---|
| `Linux version` | 1 | 1 | one boot |
| `bpcie_create_irq_domain` | 16 (8 fns × 2 lines) | 8 (8 fns × 1 line) | per-fn domain setup ran (only 1 line/fn now since removed the FLAG_MSI_PARENT marker line) |
| `bpcie_irq_msi_compose_msg` | n/a | **0** | composer NEVER ran |
| `bpcie_msi_init` | 34 | **0** | parent-level msi_init NEVER ran |
| `bpcie_msi_write_msg` | 80 | **0** | NO MSI cap programming happened |
| `bpcie_init_dev_msi_info` | 3 | n/a (removed) | — |
| `registered virq at irq_map[X]` | n/a | **0** | irq_map never populated |
| `bpcie_handle_edge_irq` | 0 | **0** | demuxer still 0 |
| `Spurious interrupt (vector 0xef)` | 0 | **2** | NEW! MSIs firing on real LAPIC vectors with NO bound handler |
| `Command Aborted` (xhci) | 2 | 2 | xhci ENABLE_SLOT timeout |
| `mmc0 Timeout waiting` | 6 | 3 | sdhci command completion never arrives |
| `qc timeout` (ahci) | 3 | 2 | SATA IDENTIFY timeout |

## Boot timing (v8)

| Event | Time |
|---|---|
| Linux version | t=0 |
| `bpcie_probe` | 4.43s |
| `xhci_aeolia bpcie_assign_irqs` | 4.93s |
| **First `Spurious interrupt` (vec 0xef)** | **7.16s** |
| Second `Spurious interrupt` (vec 0xef) | 7.99s |
| First xhci `Command Aborted` (ENABLE_SLOT) | 14.48s |
| First `mmc0 Timeout` | 18.07s |
| Last log entry | 38.68s |

## Diagnosis

The 6.15 kernel did NOT route MSI allocations through our domain at all.
The 8 per-function MSI domains were created and `dev_set_msi_domain()` was
called for each Baikal pdev (function 14.0–14.7), but:

- `bpcie_msi_init` (our `msi_domain_ops::msi_init`) fired 0 times.
- `bpcie_irq_msi_compose_msg` (our `irq_chip::irq_compose_msi_msg`) fired
  0 times.
- `bpcie_msi_write_msg` (our `irq_chip::irq_write_msi_msg`) fired 0 times.

Children's `pci_alloc_irq_vectors` calls fell through to the **default x86
vector domain**.  That domain wrote a real LAPIC vector + dest CPU into
each child's MSI cap.  When the device fired MSI, the LAPIC delivered the
vector to a CPU that had no registered handler for it, and the kernel's
`spurious_interrupt` handler logged it twice (vector 0xef, the LAPIC
spurious vector) before the device-side TRB ring timed out.

## What this proves

In Linux 6.15.4, an MSI domain that was created via
`pci_msi_create_irq_domain()` and installed via `dev_set_msi_domain()` is
**NOT enough** to capture child-PCI MSI allocations.  The kernel requires
**either**:

(a) The domain to be marked `IRQ_DOMAIN_FLAG_MSI_PARENT` with
`msi_parent_ops::init_dev_msi_info` supplied — the modern per-device-MSI
flow that v3-v7 used, **or**

(b) The domain to participate in some legacy direct-MSI path that we
haven't found and that BaikalLove's identical code apparently relies on
(possibly tied to a kernel version skew, or to a `CONFIG_*` we don't
match).

Without (a) or (b), `pci_alloc_irq_vectors` on Baikal children invokes
`pci_msi_legacy_setup_msi_irqs` which uses the default x86 vector
domain — wrong destination, no handler bound, spurious-vector territory.

## What v8 DID prove (positive)

- The Option-B v7 architecture (`IRQ_DOMAIN_FLAG_MSI_PARENT` +
  `msi_parent_ops` + AMDVI bus_token) **was actually doing useful work** —
  it routed allocations through us correctly.  The failure of v3-v7 was
  not in routing; it was in `x86_vector_msi_compose_msg` writing a real
  LAPIC vector that the Baikal southbridge silently swallows.
- The diagnosis from `option-d-thesis.md` (Baikal southbridge does MSI
  virtualization, expects `0xFEE00000 + subfunc-index`) remains the most
  plausible architectural model.  We just additionally need (a) above to
  feed our composer in the first place.

## Plan: Option E (v9) — the correct combination

**Marry v7's MSI routing scaffolding to v8's composer fix.** Concretely:

1. Restore `IRQ_DOMAIN_FLAG_MSI_PARENT`, `msi_parent_ops`,
   `bpcie_init_dev_msi_info`, AMDVI bus_token override (all of v7).
2. Keep v8's `bpcie_irq_msi_compose_msg` (writes `addr_lo=0xFEE00000` +
   `irq_map[]`-derived index).
3. Keep v8's `irq_map[100]` field in `struct abpcie_dev` and probe-time
   `memset(-1)`.
4. Keep v8's `bpcie_msi_init` extension that populates the irq_map slot.
5. Make sure `bpcie_init_dev_msi_info` does NOT clobber
   `info->chip->irq_compose_msi_msg` — it currently doesn't, but verify
   after `msi_parent_init_dev_msi_info` returns that
   `info->chip->irq_compose_msi_msg == bpcie_irq_msi_compose_msg`.

Expected v9 signals:

- `bpcie_init_dev_msi_info` ≥ 3 (per-child init runs, like v7).
- `bpcie_msi_init` ≥ 32 (parent-level msi_init runs per virq, like v7).
- `bpcie_irq_msi_compose_msg` > 0 (composer fires for each MSI activation).
- `bpcie_msi_write_msg` shows `addr_lo=fee00000` (was `fee02000` in v7).
- `bpcie_handle_edge_irq` > 0 — the money signal.
- `Spurious interrupt` count drops back to 0 — MSIs route correctly.

## Bottom line

v8 was a half-step.  Removing the parent-flag scaffolding broke routing
faster than we could fix the composer.  v9 = v7 + composer change is the
clean combination.  Should be a small patch on top of v7 (re-add what we
just removed, keep the composer + irq_map additions).
