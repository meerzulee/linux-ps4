# Option D thesis — Baikal southbridge does MSI virtualization

Written 2026-05-09 after re-reading v7 ps4-bpcie.c side-by-side with feeRnt's
`x_exp__6.15.4-BaikalLove` snapshot. Captures *why* v1–v7 (Option B) was
structurally wrong and what changed in v8.

## TL;DR

The PS4 Baikal southbridge does not pass child PCI-function MSI writes
through to the LAPIC. It captures the HT transaction (target address
`0xFEE00000`), decodes the `data` field as an internal subfunction-index,
accumulates the bit into the `BPCIE_ACK_READ` register, and fires ONE real
MSI on bpcie's own (function-4 Glue) vector pool. The kernel sees that one
MSI, dispatches `bpcie_handle_edge_irq`, which reads `BPCIE_ACK_READ` to
discover which subfunc fired and chains to the per-subfunc handler.

Therefore: any composer that writes a real x86 LAPIC vector + dest-CPU into
a child's MSI cap is wrong on this hardware. The southbridge silently
swallows it.

## Hardware path

```
[child PCI fn]                              [Baikal southbridge]                            [LAPIC]
   │                                                  │                                         │
   │  HT write addr=0xFEE00000  data=<subfunc_idx>    │                                         │
   ├─────────────────────────────────────────────────►│                                         │
   │                                                  │  decodes idx,                           │
   │                                                  │  sets bit in BPCIE_ACK_READ,            │
   │                                                  │  fires its OWN real MSI                 │
   │                                                  ├─ addr=feeXX000 data=<vector> ──────────►│
                                                                                                ▼
                                                                                kernel: handle_edge_irq
                                                                                            │
                                                                                            ▼
                                                                                bpcie_handle_edge_irq
                                                                                (the demuxer)
                                                                                            │
                                                                            reads BPCIE_ACK_READ,
                                                                            walks subfunc bits,
                                                                            handle_edge_irq(child_desc)
                                                                            for each set bit
                                                                                            │
                                                                                            ▼
                                                                            xhci_aeolia_irq /
                                                                            sdhci_irq / ...
```

Function 4 (Glue/bpcie itself) is the only function whose MSI cap, when
fired, the southbridge translates into a real LAPIC vector directly. All
other functions get their writes captured and re-emitted as Glue's MSI.

## Why v1–v7 silently lost every IRQ

`bpcie_msi_controller.irq_compose_msi_msg = x86_vector_msi_compose_msg`
walks up the IRQ hierarchy, calls `irqd_cfg(data)` to get the x86_vector
level's `irq_cfg`, and writes `addr_lo = 0xFEE0_0000 | (apic_id << 12)` and
`data = vector`. We saw this in every UART log: `addr_lo=fee02000 data=0x20`
— a real LAPIC vector targeting APIC ID 2.

The southbridge sees `addr=0xFEE02000`. Its decode logic expects
`0xFEE00000` exactly as a sentinel. `data=0x20` would translate to
"subfunc 32" which is out of range. The transaction is silently dropped at
the southbridge boundary.

Net result: the LAPIC never receives anything. Vector 0x20 never fires on
CPU 2. `bpcie_handle_edge_irq` never runs. Children time out.

**This is why v3/v4/v5/v6/v7 all showed `bpcie_handle_edge_irq` count = 0
despite MSI infrastructure looking healthy.** We were not on the wrong side
of a kernel bug or a missing kernel API. We were wiring up a kernel API
that the hardware is incompatible with.

## What feeRnt's BaikalLove does instead

Reading `research/upstream-bpcie-survey/feeRnt_x_exp__6.15.4-BaikalLove.c`
(28k lines, same kernel version we use):

1. Custom composer `bpcie_irq_msi_compose_msg`:
   ```c
   memset(msg, 0, sizeof(*msg));
   msg->address_hi = X86_MSI_BASE_ADDRESS_HIGH;
   msg->address_lo = 0xfee00000;       /* Baikal-magic sentinel */
   msg->data = data->irq - 1;          /* fallback */
   if (sc) {
       for (i = 0; i < 100; i++) {
           if (sc->irq_map[i] == data->irq) {
               msg->data = i;          /* internal subfunc-index */
               break;
           }
       }
   }
   ```

2. `int irq_map[100]` field in `struct bpcie_dev`, initialized to all -1
   in `bpcie_probe`.

3. `bpcie_msi_init` walks irq_map, finds first -1 slot, stores the new virq
   there. The slot index `i` becomes the subfunction-index for that virq.

4. Domain is **NOT** marked `IRQ_DOMAIN_FLAG_MSI_PARENT`. It's a legacy
   2-level (bpcie → x86_vector) MSI domain. Child PCI MSI alloc lands
   directly in this domain.

5. `dev_set_msi_domain(&pdev->dev, domain)` for each Baikal function pdev
   so child PCI MSI requests resolve to our domain.

## Why this works on 6.x

The Linux 6.2 per-device-MSI rework allows two coexisting paths:

- **MSI-parent** (new): `pci_alloc_irq_vectors` creates a transient
  per-device MSI domain that inherits from the marked parent. This is what
  Option B was trying to use. It assumes the hardware presents a normal
  x86-style MSI delivery path.

- **Legacy** (still supported): a domain that has `dev->msi_domain` set
  directly via `dev_set_msi_domain()`, no `IRQ_DOMAIN_FLAG_MSI_PARENT`. The
  kernel's PCI MSI core uses this domain as the leaf level. The chip's
  `irq_compose_msi_msg` is fully under our control.

Option D uses the legacy path. The legacy path is exactly what we need
because it lets us write Baikal-magic instead of LAPIC vectors.

## Concrete v8 changeset

(See `0007-ps4-bpcie-option-d-baikallove.patch`.)

| Change | File | Hunk |
|---|---|---|
| Add `int irq_map[100]` | `aeolia-baikal.h` | struct abpcie_dev |
| `memset(sc->irq_map, -1, …)` | `ps4-bpcie.c` | `bpcie_probe` |
| New `bpcie_irq_msi_compose_msg` | `ps4-bpcie.c` | new function |
| `irq_chip.irq_compose_msi_msg ← bpcie_irq_msi_compose_msg` | `ps4-bpcie.c` | bpcie_msi_controller |
| Populate `sc->irq_map[i] = virq` | `ps4-bpcie.c` | bpcie_msi_init |
| Drop `IRQ_DOMAIN_FLAG_MSI_PARENT`, msi_parent_ops, init_dev_msi_info, AMDVI bus_token override | `ps4-bpcie.c` | bpcie_create_irq_domain + above |
| Keep `dev_set_msi_domain` install | `ps4-bpcie.c` | bpcie_create_irq_domains (unchanged from v7) |
| Keep `pci_msi_create_irq_domain` | `ps4-bpcie.c` | bpcie_create_irq_domain (kept from v7) |

## Predictions for v8 boot

If hypothesis is correct:

- `bpcie_msi_write_msg` lines should show **`addr_lo=fee00000`**, `data=<small index>` (0..31-ish for slot 14 funcs). Was `fee02000 data=0x20` in v7.
- `bpcie_irq_msi_compose_msg` log line per MSI alloc — we'll see `irq=NN → index=NN`.
- `bpcie_msi_init: registered virq=NN at irq_map[X]` — irq_map populating slots 0..N.
- `bpcie_handle_edge_irq` count > 0 (the money signal).
- xhci ENABLE_SLOT timeout, mmc0 timeout, ata1 IDENTIFY timeout — gone or much later.

If we still see `bpcie_handle_edge_irq` = 0 after Option D:

- Hardware enable bit is missing — investigate the `TODO: disable ht` /
  `apcie_bpcie_msi_ht_disable_and_bpcie_set_msi_mask` reference in
  `bpcie_msi_mask` (line 185). v9 candidate.
- Or address-decode quirk in this exact silicon revision (compare with
  Aeolia's same-family driver).

## Reference

- `research/upstream-bpcie-survey/feeRnt_x_exp__6.15.4-BaikalLove.c`
- `research/baikal-bringup/` (FreeBSD-derived analysis)
- `research/BRINGUP_ANALYSIS.md`
