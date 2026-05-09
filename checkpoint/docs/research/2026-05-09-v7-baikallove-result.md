# Option B v7 (BaikalLove insights) — boot result report

Boot captured 2026-05-09 ~14:36 local. Full UART excerpt:
[`checkpoint/uart-logs/2026-05-09_1436-v7-baikallove.log`](../../uart-logs/2026-05-09_1436-v7-baikallove.log)
(174 KB, 2563 lines, slice from t=0 to t≈177s).

## Summary

Three minimal targeted changes lifted from feeRnt's `x_exp__6.15.4-BaikalLove`
branch:

1. `msi_create_irq_domain` → `pci_msi_create_irq_domain` (auto-sets
   `MSI_FLAG_ACTIVATE_EARLY`, `MSI_FLAG_FREE_MSI_DESCS`, `MSI_FLAG_DEV_SYSFS`,
   `IRQCHIP_ONESHOT_SAFE`, sets `bus_token = DOMAIN_BUS_PCI_MSI`, runs
   `pci_msi_domain_update_dom_ops/chip_ops` to fill PCI defaults).
2. `bpcie_msi_prepare`: `init_irq_alloc_info(arg, NULL)` +
   `arg->type = X86_IRQ_ALLOC_TYPE_PCI_MSI` (was `memset(arg, 0)` — wiped the
   type field x86's vector allocator needs).
3. `bpcie_msi_domain_info`: add `.handler_name = "edge"` (BaikalLove note:
   "Seems important now" in 6.x).

Result on hardware (boot #9, 2026-05-09 14:17 build):

## Counts (vs v5/v6)

| Signal | v5 | v6 | **v7** | What it means |
|---|---|---|---|---|
| `Linux version` | 1 | 1 | 1 | one boot |
| `bpcie_create_irq_domain` (`marked … MSI parent`) | 8 | 8 | 8 (×2 lines = 16) | per-function domain setup runs |
| `bpcie_init_dev_msi_info` | n/a | 3 | 3 | parent_ops::init_dev_msi_info called per child needing MSI |
| `bpcie_msi_init` | 32 | 34 | 34 | parent-level msi_init fires for each virq |
| `bpcie_msi_write_msg` | many | many | 80 | MSI-cap programming runs |
| **`bpcie_handle_edge_irq`** | **0** | **0** | **0** | demuxer NEVER fires |
| `Spurious interrupt (vector 0xef)` | 0 | 0 | 0 | no MSI lands as spurious |
| `Command Aborted` (xhci) | 2 | 2+ | 2 | xhci ENABLE_SLOT TRB timeout |
| `Timeout waiting for hardware cmd` (mmc0) | many | many | 6 | sdhci command completion never arrives |
| `qc timeout` (ahci/ata1) | 3 | 3 | 3 | SATA IDENTIFY timeout |
| `[drm] fence fallback timer expired` | n/a | yes | **0** | **v7 fixed v6's amdgpu regression** |

## Boot timing (v7)

| Event | Time |
|---|---|
| Linux version | t=0 |
| `bpcie_probe` | 4.43s |
| First `bpcie_msi_write_msg` (placeholder, vector 0xef) | 4.93s |
| `xhci_aeolia_init` deferred-probe trigger | 109.91s |
| `xhci_aeolia_probe_one` | 112.14s |
| First xhci `bpcie_msi_write_msg` real activation (`addr_lo=fee02000 data=0x20`) | 112.03s |
| `ata1: SATA link up 3.0 Gbps` | 112.55s |
| `sdhci-pci controller found` | 113.0s |
| `amdgpu detected ip block` | 114.65s |
| **First `Command Aborted`** (xhci ENABLE_SLOT) | 119.96s |
| **First `mmc0: Timeout waiting`** | 123.54s |
| Last log entry | 176.79s |

xhci probe completed (4 USB buses up, root hubs found, USB stick connect detected
on `usb1-port1`), SATA link came up, amdgpu detected IP blocks. Then:
ENABLE_SLOT TRB ring timed out → Command Aborted; mmc0 commands timed out;
ata1 IDENTIFY timed out. The kernel keeps running but every device under
bpcie sits in a command-completion-IRQ-never-arrives loop.

## What v7 changed for the better

- ✅ **amdgpu fence regression introduced in v6 is gone.** v6's
  `DOMAIN_BUS_AMDVI` bus_token override (still present in v7 in the same
  spot, since pci_msi_create_irq_domain sets `DOMAIN_BUS_PCI_MSI` and we then
  override) doesn't seem to be what caused v6's `[drm] Fence fallback timer
  expired on ring gfx`. v7 boots amdgpu cleanly — the fix that mattered
  was `pci_msi_create_irq_domain`'s addition of `MSI_FLAG_ACTIVATE_EARLY`
  + correct chip_ops, which the modern PCI MSI core relies on for non-Baikal
  devices to get correctly-activated MSI messages.

- ✅ **Cleaner MSI message path.** `pci_msi_create_irq_domain` runs
  `pci_msi_domain_update_chip_ops` which sets `chip->irq_mask = pci_msi_mask_irq`
  and `chip->irq_unmask = pci_msi_unmask_irq` automatically — closer to
  what the kernel expects.

## What v7 did NOT fix

- ❌ **`bpcie_handle_edge_irq` still fires 0 times.**  The fundamental
  blocker since v3 is unchanged.  Across v3/v4/v5/v6/v7 we have
  comprehensively confirmed:
  - MSI vectors are correctly allocated by x86_vector_domain.
  - MSI messages are correctly programmed in each device's MSI cap
    (`addr_lo=fee0X000 data=0x20` on the right CPU for each device).
  - `bpcie_msi_init` fires at the parent level for each virq.
  - `bpcie_init_dev_msi_info` fires for each child PCI dev that wants MSI.
  - **But `bpcie_handle_edge_irq` is never invoked at runtime.**

  Either:
  - **(A)** the leaf irq_data's handler is not actually
    `bpcie_handle_edge_irq` despite us setting `info->handler` —
    something in 6.x's per-device child domain setup silently overrides
    it.
  - **(B)** the hardware MSI fires but to a different vector/CPU than
    we expect, landing somewhere we don't have a printk.
  - **(C)** the hardware MSI doesn't fire at all — Baikal southbridge
    needs an additional gate register written to enable MSI delivery
    that we're not setting.

## Concrete next-step diagnostics for v8

Before more architectural changes, instrument to prove which of (A)/(B)/(C)
above is actually happening:

1. **Add `pr_info` at the top of `handle_edge_irq` itself** (the kernel's
   default that x86 installs) — gated on Baikal hwirq encoding —
   to prove whether it's running INSTEAD of bpcie_handle_edge_irq.  If yes,
   we have (A).
2. **Add `pr_info` after `__irq_set_handler(virq, info->handler, ...)`**
   in `msi_domain_ops_init` (or wherever the leaf handler is installed)
   to log what got set as the leaf handler.  If it's not
   bpcie_handle_edge_irq even though we set info->handler, that confirms (A).
3. **Read `/proc/interrupts`** equivalent state by dumping `desc->irq_count`
   for our virqs — does the LAPIC actually deliver?  If counts are 0,
   we have (C); if non-zero but our handler doesn't run, we have (A).

(3) requires either a debugfs hook, an /proc/interrupts dump in initramfs, or a
new ad-hoc `pr_info_ratelimited("vector hit") in the leaf chip's irq_eoi`.

## Other changes worth investigating

- The kernel-level `irq_chip_compose_msi_msg(data, msg)` walks chip
  hierarchy looking for `irq_compose_msi_msg`.  Our `bpcie_msi_controller`
  has `.irq_compose_msi_msg = x86_vector_msi_compose_msg` with comment
  "this seems kinda wrong".  In a 3-level hierarchy
  (leaf → bpcie → x86_vector), `irqd_cfg(bpcie_data)` walks
  `data->parent_data->chip_data` which IS x86_vector level chip_data
  (apicd / irq_cfg).  This SHOULD work.  But `bpcie_msi_init` sets
  `bpcie_data->chip_data = (void *)sc` — so if the leaf level's
  compose_msg walks one level UP to bpcie, it reads sc (not irq_cfg).
  Hypothesis worth testing: the hierarchy walk for compose_msg lands
  at the wrong level on our 3-level setup.

## Bottom line

v7 is a forward step (amdgpu regression fixed, cleaner code, lifted one bug —
the `memset(arg, 0)` — that was always wrong).  But the IRQ DELIVERY problem
is independent of which create-domain API is used, which bus_token we pick,
and whether we provide msi_parent_ops or not.  The handler we set on the leaf
isn't running.  v8 must instrument to prove which of (A)/(B)/(C) above is the
truth before we change more code.
