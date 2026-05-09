# Upstream bpcie MSI shape — index across rmuxnet & feeRnt PS4 forks

Survey date: 2026-05-09. Captured to triangulate the right shape for our
6.15 Baikal MSI domain modernization (after our v1-v6 attempts).

## All branches/tags found

### rmuxnet/ps4-linux-12xx
6.x branches (most relevant): `6.18.18-Strawberry`, `6.18.20-Strawberry`,
`6.18.20-Strawberry-Main`, `6.18.21-HotPlug`, `6.18.21-NoDrmDbg`,
`6.18.21-Strawberry`, `6.18.21-Strawberry-GpuWork`, `7.0-Broken`,
`7.0-Clean`, `7.0-Clean-commit-cleanup-20260424`, `7.0-Stable`,
`ps4-baikal-7.0-clean`, `ps4-baikal-7.0-port`. Also: `rmux/baikal/bringup`
(5.4-based, what we have locally).

### feeRnt/ps4-linux-12xx
6.x branches: `6.15.4-aeolia-belize-crashniels`, `6.18.8-aeolia-belize`,
`6.18.18-Strawberry`, **`x_exp__6.15.4-x86_vector_msi`** (literally names
our problem!), `x_exp__6.15.4-baikal-crashniels`,
**`x_exp__6.15.4-BaikalLove`** (most evolved Baikal-specific 6.15 work),
`x_exp__6.15.4-fam15h_power`, `x_exp__6.15.4-uvd-engine`,
`x_exp__6.0/6.3/6.6/6.9/6.12-BaikalLove`, `x_exp__6.17.1-edid-oberdfr`.

Tags `v6.15.4*` shared across both repos.

## bpcie.c availability per branch

| Branch | drivers/ps4/ps4-bpcie.c | Notes |
|---|---|---|
| feeRnt:`x_exp__6.15.4-BaikalLove` | ✅ 873 lines | Most evolved — engineering notes in comments |
| feeRnt:`x_exp__6.15.4-baikal-crashniels` | ✅ 669 lines | crashniels base + minor mods |
| feeRnt:`x_exp__6.15.4-x86_vector_msi` | ❌ (404) | Branch focuses on x86_vector code, not Baikal driver |
| feeRnt:`6.15.4-aeolia-belize-crashniels` | ❌ (404) | Aeolia/Belize only — no Baikal driver |
| feeRnt:`6.18.8-aeolia-belize` | ❌ (404) | Same |
| rmuxnet:`ps4-baikal-7.0-port` | ✅ 650 lines | Cleaner (~simpler) |
| rmuxnet:`7.0-Stable` | ❌ (404) | No baikal driver in tree |
| rmuxnet:`7.0-Clean` | ❌ (404) | Same |
| rmuxnet:`6.18.21-Strawberry` | ❌ (404) | Same |

## MSI shape comparison (6.x branches with bpcie.c)

| Aspect | feeRnt BaikalLove | feeRnt baikal-crashniels | rmuxnet ps4-baikal-7.0-port | **Our v6** |
|---|---|---|---|---|
| Domain create API | **`pci_msi_create_irq_domain`** | `msi_create_irq_domain` | `msi_create_irq_domain` | `msi_create_irq_domain` |
| `dev_set_msi_domain` install | ✅ (with comment "missing in 6.15-baikal; seems important") | ❌ | ❌ | ✅ |
| `IRQ_DOMAIN_FLAG_MSI_PARENT` | ❌ | ❌ | ❌ | ✅ |
| `msi_parent_ops` | ❌ | ❌ | ❌ | ✅ |
| `bus_token` | default (forced to `DOMAIN_BUS_PCI_MSI` by `pci_msi_create_irq_domain`) | default | default | `DOMAIN_BUS_AMDVI` ⚠ hack |
| `bpcie_msi_prepare` body | sets `arg->type = X86_IRQ_ALLOC_TYPE_PCI_MSI` + `init_irq_alloc_info` | sets `arg->type` | sets `arg->type` | **`memset(arg, 0)`** ⚠ |
| `info.handler_name = "edge"` | ✅ ("Seems important now") | ❌ | ❌ | ❌ |
| Parent fwspec lookup (for IR) | ✅ | ✅ | ❌ | ✅ |
| Per-function or per-domain | per-function (8 domains) | per-function | per-function | per-function |

## Key takeaway

**feeRnt's `BaikalLove` shape is the most carefully-debugged 6.15 Baikal MSI
implementation we can find, and the engineering-notes comments in the source
literally describe our exact diagnosis path** (e.g. `dev_set_msi_domain` is
missing in crashniels 6.15-baikal; need `pci_msi_create_irq_domain` not
`msi_create_irq_domain` because the latter "lacks a few info flags";
`handler_name = "edge"` "Seems important now"; etc.).

**v7 shape derived from BaikalLove:**

1. Switch from `msi_create_irq_domain` → **`pci_msi_create_irq_domain`**
   (this gives us `MSI_FLAG_ACTIVATE_EARLY`, `MSI_FLAG_FREE_MSI_DESCS`,
   `MSI_FLAG_DEV_SYSFS`, `IRQCHIP_ONESHOT_SAFE`, AND
   `bus_token = DOMAIN_BUS_PCI_MSI` automatically).

2. **Remove** `IRQ_DOMAIN_FLAG_MSI_PARENT` + `msi_parent_ops` setting
   (not needed — pci_msi_create_irq_domain doesn't use them).

3. **Remove** `irq_domain_update_bus_token(domain, DOMAIN_BUS_AMDVI)`
   (the hack that probably caused amdgpu regression — pci_msi_create_irq_domain
   sets PCI_MSI for us).

4. **Keep** `dev_set_msi_domain(&pdev->dev, d)` install (BaikalLove confirms
   this is the missing piece).

5. **Fix** `bpcie_msi_prepare` to set `arg->type = X86_IRQ_ALLOC_TYPE_PCI_MSI`
   (not zero arg).

6. **Add** `.handler_name = "edge"` to `bpcie_msi_domain_info` (BaikalLove
   says "seems important now" — likely needed in 6.x kernel where unnamed
   handlers behave differently).

This is essentially **"modernized 5.4 model"**: keep the 5.4 architecture
(per-function bpcie domain, hardware demuxer) but use the 6.x kernel APIs
that properly handle PCI MSI flags + activation.
