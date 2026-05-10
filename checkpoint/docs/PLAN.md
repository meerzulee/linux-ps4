# PS4 Linux — Global plan

## Where we landed (end of 2026-05-10) — **post-v62**

🎉 **Major breakthroughs since 2026-05-08:**

| Component | Status |
|---|---|
| **v40 IRQ 9 ACPI fix** | ✅ shipped — root-cause for all the ATOM mutex / display issues. PS4's `null_legacy_pic` left IRQ 9 desc unallocated; ACPI SCI install failed; ATOM BIOS calls failed. Fix: pre-allocate IRQ 9 desc in `arch_initcall`. |
| **v60 HDMI working** (`abe29da`, tag `v60-hdmi-working`) | ✅ shipped — preserve firmware-trained DP TX state on Liverpool. PS4 firmware leaves the GPU's UNIPHYA DP transmitter trained with non-default per-lane swing/preemph values; standard DPMS_OFF/ON via `setup_dig_transmitter(DISABLE/ENABLE)` tears that down and the kernel has no working retrainer for the fake-DP MN864729 bridge. Fix: skip both DISABLE and ENABLE on Liverpool/Gladius DP encoders during modeset. **Display lights up.** |
| **v62 WiFi + SSH** (`b02d1c6`, tag `v62-wifi-ssh`) | ✅ shipped — added `rtw88_8822bu` driver to 6.x build for USB TP-Link Archer T3U Plus (RTL8822BU). Boots into psxitarch via `bootargs/6.x-rootfs-psxitarch.txt`. Modules + Liverpool firmware installed in psxitarch via mount-and-rsync. SSH from host works. |
| **`bpcie_handle_edge_irq` shared-vector dispatch** | ✅ Was actually fine — the May-8 "demuxer never fires" diagnosis turned out to be a misread. Boot reaches userspace cleanly with the current patch series including 0005-shared-vector-demux-bypass + the Option E composer. xhci enumerates, USB devices visible (we used a USB stick to boot the rootfs). |
| **Built-in Marvell ethernet (sky2 on Baikal)** | ❌ documented dead-end — see [`research/2026-05-10-sky2-baikal-not-yukon.md`](research/2026-05-10-sky2-baikal-not-yukon.md). Not actually a Yukon-2 chip. PCI class is `0x088001` ("System peripheral"). 38 non-zero registers in BAR0 at offsets that don't match Yukon-2. **Multi-week RE project**, parked. |
| **MT7668 internal WiFi+BT in 6.x** | 🚧 WIP — vendor tree imported as `patches/6.x-baikal/0500-network-mt7668/0001-mt76x8-vendor-tree-import.patch`. Build infrastructure parses but produces no .o files (vendor's `MTK_COMBO_CHIP` indirection + 2.6-era kbuild assumptions). Estimated remaining: 2-3 days of Makefile rework + 5.4-to-6.x API porting. See [`study/08-mt7668-port-todo.md`](study/08-mt7668-port-todo.md). |

## Current focus (next session)

1. **🎯 NEXT: Dump Orbis kernel — RE foundation track**
    Why: Orbis has working drivers for the hardware blocks we can't drive yet on Linux (Baikal ethernet, fan/thermal, HDD timing). Mining the dump gives us register definitions, init sequences, and the actual chip family identifications. **Single biggest unlock** for stmmac/DWMAC1000 ethernet port and various smaller mysteries.
    Steps:
    - Identify the right dumper payload for our jailbreak FW level
    - Boot via PSFree → dumper.bin instead of linux-1024mb.bin
    - Save kernel blob to USB → pull to host
    - Open in Ghidra (free), find `if_msk`/`if_dwc_eth_qos` ethernet driver, fan/hwmon, HDD timing code
    - Cross-reference with mainline `stmmac` source to write Baikal-specific binding
    - Doc findings in `checkpoint/docs/research/orbis-kernel/`
    Output: a research directory with annotated register defs + init traces. Drives the next several patches.

2. **Stmmac/DWMAC1000 port (post-dump)** — once we have Orbis register definitions, port the existing mainline `stmmac` driver. sky2 path proven dead (v69 MDIO scan, [`research/2026-05-11-sky2-phy-dead-end-mdio-proven.md`](research/2026-05-11-sky2-phy-dead-end-mdio-proven.md)). Bottleneck for ethernet.

3. **Phase-2 cleanup** — GitHub Actions CI/CD, Releases on tag, issue/PR templates, AUR PKGBUILDs.

4. **Multi-version target framework** — easier to add `7.x-baikal` once 7.0 ships.

5. **Upstream the v60 patch** — first upstream candidate. See [CONTRIBUTING.md](../../CONTRIBUTING.md#upstreaming).

6. **Ultrawide 21:9 support** — user has a 2560×1080 / 3440×1440 monitor. PS4 HDMI 1.4 caps at ~4.95 Gbps so UWHD (2560×1080@60, 185 MHz pixclk) should work; UWQHD (3440×1440@60, 313 MHz pixclk) is borderline against Liverpool PLL's ~300 MHz limit. Path: generate widescreen EDID, swap `drm.edid_firmware=`, possibly relax 1080p VIC hardcode in `ps4_bridge.c`. Low-priority.

7. **AHCI DMA boundary fix → unlock BD drive + internal HDD** — `ahci 0000:00:14.2: probe with driver ahci failed with error -12 (-ENOMEM)`. Root cause is `PS4_AHCI_DMA_BOUNDARY = 0xB7FFFFFF` which is not power-of-2; modern SWIOTLB `BUG_ON(!is_power_of_2(boundary_size))` returns -ENOMEM. Rmuxnet's fix (per his BAIKAL_DEVLOG): change to `0x7FFFFFFF` (power-of-2 aligned). Adds ~10 lines to `patches/6.x-baikal/0400-storage-ahci/`. Once fixed: BD drive enumerates as `sr0` — can read BD-R/CD/DVD data discs; commercial BD movies need libbluray+AACS; writing depends on drive model (Pro=yes, Slim/Phat=read-only typical). Internal HDD also visible (kept disabled via libata.force=1.00:disable due to Sony-encrypted partitions). Low-priority.

8. **macOS-on-PS4 — long-term research track** — possible technically (AMD x86_64 Jaguar + GCN 1.1 GPU was supported in macOS 10.13-10.15 era). Practical ceiling: High Sierra/Mojave. Modern macOS (Big Sur+) drops AVX2-less CPUs; Apple Silicon (12+) is ARM-only dead end. Approach: OpenCore bootloader with AMD_Vanilla patches + custom KEXTs for each PS4 chip (southbridge demux, MN864729 bridge, ethernet, ICC). **Reuses Orbis kernel dump findings** — same RE outputs feed both Linux drivers and macOS KEXTs. Order: finish Linux first as forcing function (better debug tools), then translate driver knowledge into KEXTs.

9. **Recovery-kexec image** — minimal 50MB busybox+ssh kernel that boots in ~5s, usable as safety net when the main image breaks. Eliminates a PSFree gauntlet on most iteration failures. Build as a sibling target `recovery-baikal.env`.

10. **MT7668 6.x port — DONE in v67** (historical link).

## Older state (kept as historical reference)

The bisection saga that took 6.x from "boots to systemd, screen dark" to v60-HDMI-works is documented in:

- [`research/2026-05-10-v60-skip-tx-enable-result.md`](research/2026-05-10-v60-skip-tx-enable-result.md) — the canonical v60 write-up with the full v45 → v60 narrative
- [`research/2026-05-10-v58-step-by-step-probe-result.md`](research/2026-05-10-v58-step-by-step-probe-result.md) — the localizer that pinpointed the killer step
- [`research/2026-05-10-v55-bridge-cq-chunks-result.md`](research/2026-05-10-v55-bridge-cq-chunks-result.md) — the chunk-split insight that reframed the problem
- Per-iteration v45..v60 result reports in `research/`

The 2026-05-08 PLAN content below predates this work — its "active blockers" (xhci slot-ID timeout, USB enumeration, AHCI -ENOMEM) are all resolved.

---

## Where we landed (end of 2026-05-08) — **historical, pre-v40**

| Component | Status |
|---|---|
| **5.4 prebuilt** (feeRnt Clang-14) | ✅ Boots, KDE, WiFi, SSH |
| **5.4 our build** (Clang 22 + bpcie-uart patch + mt76 `=y`) | ✅ Boots, KDE, WiFi, SSH. Build pipeline fully validated. |
| **6.x our build** with proper bootargs (`keep_bootcon`, no `console=ttyS0`) | ✅ **Boots to userspace `/init` at 7.28 s** (1753 lines of UART). All 8 PS4 PCI funcs detected. amdgpu KMS, ALSA, SDHCI, sky2, xhci-aeolia drivers all init. **Hangs in initramfs** at 17 s on `LABEL=psxitarch: Can't lookup blockdev` — PS4 storage drivers stuck in deferred-probe limbo because `bpcie_probe` aborts (see breakthrough below). |
| **6.x with `0004-ps4-bpcie-make-uart-failure-non-fatal.patch`** | ✅ **bpcie cascade fixed.** New patch fires (`UART init failed (-5); continuing without serial console`). bpcie_probe returns 0. xhci-aeolia probes fully — Belize SATA PHY init, 4 USB buses registered, Blu-ray AHCI claims 6 Gbps. sdhci-pci finds mmc0 ADMA. ICC pwrbutton init runs. Boot reaches `/init` at 54.95 s, but **3 new blockers** prevent rootfs lookup: (1) xhci `Error while assigning device slot ID: Command Aborted` — USB device enumeration fails, no /dev/sdX; (2) ahci 0000:00:14.2 (HDD AHCI) `probe failed -12` (-ENOMEM) at 10.7 s; (3) mmc0 timeout waiting for hardware cmd interrupt. Capture: `checkpoint/docs/uart-boot-2026-05-08-6x-bpcie-non-fatal.log` (2256 lines). |
| **6.x with iommu coherent-DMA + xhci settle delays + IRQ via apcie + imod/retry** (boots #5–#10) | ⏸ Same `Command Aborted` after every iteration. d5e2c79b iommu fix DID unblock amdgpu probe and the inline-AHCI SATA link (3 Gbps) but **none** of the four xHCI patches (0005–0007 + 0006 IRQ routing) moved the slot-ID failure. Each boot: 4 USB buses register, root hubs detected, then 5 s TRB_RING_TIMEOUT → Command Aborted on first ENABLE_SLOT. AHCI 0000:00:14.2 still `-ENOMEM`. `bpcie_assign_irqs(3) → returning 1` is the smoking gun: nvec=1 single-vector mode with broken demuxer (see breakthrough below). |
| **6.x with `0005-ps4-bpcie-shared-vector-demux-bypass.patch`** | 🎯 **Root cause patch — bpcie demuxer in shared-vector mode never dispatches.** When IOMMU-IR is disabled (production case on Baikal), bpcie_assign_irqs() forces nvec=1 and the hwirq is OR'd with 0x1F. `bpcie_handle_edge_irq` then tries to demux to children at `initial_hwirq + i` — but those virqs don't exist (only the shared parent at `initial_hwirq | 0x1F` does). Every xHCI command-completion MSI is swallowed → 5 s timeout → Command Aborted. Fix: detect shared-vector mode (bottom 5 bits == 0x1F) and run `handle_edge_irq(desc)` on the parent directly — works exactly like IRQF_SHARED everywhere else. **0005 alone insufficient — root cause was deeper, see Option B saga below.** |
| **6.x with Option A** (`0006-skip-bpcie-msi-domain-on-6x`) | ⏸ Children fall through to default x86 vector domain → MSIs delivered as `Spurious interrupt (vector 0xef)`. Confirmed root cause is Linux 6.2 PCI MSI rework. Option A disabled in series 2026-05-09 in favor of Option B. |
| **6.x with Option B v1–v6** (`0007-bpcie-option-b-msi-parent`) | 🛠 In progress 2026-05-09. v1-v5 modernized the MSI domain infrastructure (parent flag + parent_ops + dev_set_msi_domain install + AMDVI bus_token + MULTI_PCI_MSI flag). All MSI caps correctly programmed with real vectors, bpcie_msi_init/write_msg fire, boot reaches `/init` at 7s, xhci/sdhci/ahci all probe. **But: `bpcie_handle_edge_irq` (the demuxer) fires 0 times in v5 AND v6** — every Baikal subfunc (xhci/sdhci/ahci/even bpcie ICC) times out on completion interrupts. v6 attempted to override `info->handler = bpcie_handle_edge_irq` in `init_dev_msi_info` but override didn't propagate to leaf, AND amdgpu (at slot 1, NOT under bpcie) regressed with fence timeouts + illegal reg access — suggesting the AMDVI bus_token trick is corrupting x86_vector's allocation state for non-Baikal devices too. Architectural conclusion: 6.x's per-device MSI model splits each Baikal pdev into its own domain → bpcie's subfunc demuxer can't resolve siblings. Next: either force legacy PCI MSI path (remove parent flag, remove parent_ops) or use single shared bpcie domain across all 8 funcs (closer to 5.4 model). See LEARNINGS.md "Option B v6". |
| **6.x our build** with old bootargs (`console=ttyS0`) | ⏸ Looked like a hang at 0.66 s, was actually just printk going to a phantom legacy 8250. Kernel was alive the whole time. |
| **6.x our build** with `0003-ps4-bpcie-uart-set-port-type.patch` enabled | ❌ Triple-faults at kexec (originally), but that triple-fault probably co-occurred with broken bootargs. **Worth retrying on the new clean cmdline.** |
| **UART late boot via `ttySN`** | ❌ Still broken on 6.x — bpcie_uart_init's `serial8250_register_8250_port` returns -EIO, which abandons the entire bpcie probe. (Earlycon via MMIO works fine, that's how we get UART output.) |

## 🎯 Breakthrough (2026-05-08, ~21:50)

**`keep_bootcon` does NOT crash on 6.x with proper bootargs.** The previous "hard hang" diagnosis was wrong — what was actually happening:

1. Old bootargs included `console=ttyS0,115200n8`. After `bootconsole disabled` at ~0.66 s, all printk went to a phantom legacy 8250 at I/O `0x3F8`. Kernel was running silently.
2. Without `keep_bootcon`, the bootconsole gets de-registered, MMIO direct writes stop. Combined with the phantom `ttyS0`, both sinks are dead.
3. `keep_bootcon` keeps the MMIO bootconsole alive; **with the phantom `console=ttyS0` removed**, kernel printk continues to UART through the entire boot.

**Working bootargs (this is the diagnostic profile, with `initcall_debug`):**

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 keep_bootcon initcall_debug 8250.nr_uarts=0 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

**Real blocker is now: `bpcie_probe` aborts.** Lines 1284–1286 of the latest UART log:

```
baikal_pcie 0000:00:14.4: Failed to register serial port 0
baikal_pcie 0000:00:14.4: bpcie glue remove
baikal_pcie 0000:00:14.4: probe with driver baikal_pcie failed with error -5
```

`bpcie_uart_init` calls `serial8250_register_8250_port` for the BPCIe UARTs; on 6.x the autoconfig rejects the port (no `port.type` set, so registration fails). The probe path treats this as fatal and tears the whole southbridge down. **Every PS4 driver that gates on `apcie_status() == 1` then defers forever** — amdgpu, xhci-aeolia, ahci, sky2 — and the rootfs partition (`LABEL=psxitarch` on USB ext4) never appears because the USB stack is offline.

**Fixed-since-this-morning facts:**

- Our build pipeline (`research/build/`) reproducibly compiles a working 6.x kernel outside `linux-ps4/`.
- `X86_SUBARCH_PS4` early-setup hook fires.
- EMC timer calibration works (TSC = 1.594 GHz, matches `PS4_DEFAULT_TSC_FREQ`).
- All 8 Baikal PCI functions detected with correct device IDs (`0x104d:0x90d7..0x90de`).
- Per-function MSI domains created via `bpcie_create_irq_domain` for funcs 14.0–14.7.
- HDMI audio (HD-Audio Generic at `0xe4840000`) present in ALSA list.
- IOMMU disable from loader confirmed (matches our investigation finding F1 in `checkpoint/docs/research/gap-analysis-vs-our-tree.md`).

## Key facts known about hardware/quirks

- **PS4 Jaguar APU** — x86-64-v2 + AVX1 only. No AVX2/BMI/FMA/LZCNT. Modern Arch (v3) binaries SIGILL → "Attempted to kill init!" panic. Use deeWaardt's tarball.
- **BPCIe BAR2** — `0xC8800000`. UART0 = `0xC890E000` (user's cable), UART1 = `0xC890F000`.
- **`/proc/tty/driver/serial`** with our patch shows `uart:16550A` for both UARTs (vs `unknown` without). Registration succeeds, but writes don't transmit (8250 driver state mismatch).
- **`keep_bootcon`** — crashes xhci_aeolia at ~57 s on **5.4** (BPCIe bus overload from earlycon writes once xhci is up). On **6.x** with `console=ttyS0` removed, **safe** and revealed kernel boots cleanly to userspace. Use it for diagnostics on 6.x; avoid on 5.4 once xhci is alive.
- **`earlyprintk=serial,ttyS0,...`** — poison; targets non-existent legacy 8250 at `0x3F8`. Same trap exists for `console=ttyS0,...` if the BPCIe UART hasn't registered a real ttySN — printk silently drops.
- **ArabPixel v24b unified payload** — required for FW 12.02. Old per-firmware payloads triple-fault.
- **Ethernet over Baikal sky2** — broken; LAN doesn't bring up usable interface. Use WiFi only.

## Iteration loop (when SSH is up)

```
# Edit kernel src or config
./build.sh -t 6.x-baikal              # ~3 min incremental, ~8 min clean (-c)
scp output/6.x-baikal/bzImage ps4:/tmp/
ssh ps4 'sudo mount /dev/sda1 /mnt/ps4boot &&
         sudo cp /tmp/bzImage /mnt/ps4boot/bzImage &&
         sync && sudo umount /mnt/ps4boot &&
         sudo systemctl reboot'
# (re-launch linux-1024mb.bin via PSFree)
```

## Next-session priority list

Updated 2026-05-08 after the `0004-ps4-bpcie-make-uart-failure-non-fatal.patch` boot. bpcie cascade is fixed; new blockers are USB enumeration, AHCI ENOMEM, and SDHCI command timeouts.

### 1. (highest leverage) Cherry-pick rmuxnet's USB/IOMMU patches

The `Command Aborted` error on xhci device-slot allocation is exactly what rmuxnet's "USB working motherfuckers" line of work targeted. Eight relevant patches are already extracted in `patches/rmuxnet-7.0-baikal/`:

- `f6cf0e0d-ps4-baikal-usb-working-motherfuckers.patch` (the headline)
- `02fcd65e-usb-xhci-aeolia-fix-baikal-xhci-setup.patch`
- `dcf8b509-usb-xhci-aeolia-fix-baikal-hcd-setup.patch`
- `df50a074-usb-xhci-aeolia-restore-ps4-irq-assignment.patch`
- `8f2f907b-usb-xhci-aeolia-define-extra_priv_size-and-enforce-apcie-irq.patch`
- `7ce79497-xhci-aeolia-bpcie-amdgpu-fix-baikal-usb-sata-phy-null-deref.patch`
- `c30160e0-pci-iommu-add-narrowly-gated-ps4-quirks.patch`
- `d5e2c79b-iommu-amd-fix-ps4-baikal-coherent-dma.patch` (likely fixes the AHCI -12 ENOMEM too)

These were extracted from rmuxnet's 7.0 line and may need rebasing onto 6.15. Plan: try direct apply first, rebase the failures one by one. Stage as `patches/6.x-baikal/0800-usb-aeolia/0003-…` and `1000-iommu/0002-…` when clean.

### 2. Test sky2 storm fix once USB rootfs is up

`patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate` is staged. Once we have working storage and Linux boots to a usable shell, we can validate whether ethernet is actually fixed by it.

### 3. Re-enable `0003-ps4-bpcie-uart-set-port-type.patch` and re-test

With bootargs no longer poisoned, the patch's earlier "triple-fault at kexec" might have been chained from the broken cmdline. Re-enable in `patches/6.x-baikal/series`, rebuild, boot. If it works on top of #1, we get UART on `ttySN` *and* successful USB enumeration.

### 4. SDHCI eMMC timeout (low priority)

`mmc0: Timeout waiting for hardware cmd interrupt` at 18 s + 28 s. Could be a Baikal SDHCI quirk we're missing, or this CUH model just has no eMMC populated. Not blocking USB-rooted boot.

### Older items (still relevant, lower priority now)

- Layer patches one-by-one onto vanilla 6.15.4 — useful if #1's cherry-picks don't apply cleanly and we need a control.
- Build crashniels' kernel as-is — control if our derivative goes off the rails.
- (was #2) Build crashniels' kernel as-is — useful as a control if our derivative goes off the rails again.

## Files to consult next session

- `checkpoint/docs/LEARNINGS.md` — full diagnosis history
- `checkpoint/docs/PLAN.md` — this file
- `checkpoint/docs/uart-boot-capture-ttyS0E000.log` — reference UART boot
- `BUILD_LOG.md` — chronological session notes
- `patches/6.x-baikal/series` — the disabled `0003-ps4-bpcie-uart-set-port-type.patch` reminds us not to re-enable for 6.x
- `scripts/` — every helper, named by purpose

## Recovery / known-good state

USB after 2026-05-08 session:
- `bzImage` = 6.x from `research/build/` (boots to `/init`, hangs on storage)
- `bzImage-prev` = previous active before the install-to-usb.sh swap
- `bzImage-stable` = bootstrapped from the earlier active (last-known-good fallback)
- `bzImage-6x-research-20260508-2111` = labeled copy of `research/build` kernel
- `bzImage-5.4-feeRnt` = known-working prebuilt
- `bzImage-5.4-ours` = our self-built 5.4 with bpcie-uart patch (boots, KDE, WiFi, SSH)

`bootargs.txt` currently:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 keep_bootcon initcall_debug 8250.nr_uarts=0 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

`bootargs.txt.prev` saved by `update-bootargs.sh` if you need the old one back.

To return to working 5.4 baseline: `sudo bash scripts/rollback-to-our-5.4.sh` while USB is on host. Or use `sudo bash scripts/dev/rollback-kernel.sh` to swap `bzImage` ← `bzImage-stable`.

To re-stage outputs onto USB:
```
sudo bash scripts/swap-bzimage.sh output/6.x-baikal/bzImage           # kernel
sudo bash scripts/dev/update-bootargs.sh 6.x-diagnostic                # bootargs profile
```

`scripts/dev/update-bootargs.sh --list` shows all bootargs profiles in `bootargs/`.

## Current commits

- `5136404` Unlock UART via earlycon at correct BPCIe MMIO
- `15fc24a` Remove stale config/config.baikal-b1
- `8916fee` Boot Linux on Baikal PS4 end-to-end + project checkpoint

Pending changes to commit at end of this session:
- New patches: `patches/5.4-baikal/0200-ps4-drivers/0002-ps4-bpcie-uart-set-port-type.patch`
- Series file updates (5.4 + 6.x)
- Config update (mt76 family `=y`)
- New scripts (`load-6x-no-uart-patch.sh`, `rollback-*.sh`, `bootargs-*.sh`, etc.)
- Updated checkpoint (bzImage with patches, refreshed SHA256SUMS, this PLAN.md, BUILD_LOG.md entry)
