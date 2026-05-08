# PS4 Linux Porting — Knowledge Base

Compiled 2026-05-08 from upstream community repos. Focus: porting Linux 6.15+ /
7.0 kernels to PS4 on Baikal (and Aeolia/Belize) southbridges.

Sources audited:
- https://github.com/feeRnt/ps4-linux-12xx
- https://github.com/rmuxnet/ps4-linux-12xx (fork of feeRnt)
- https://github.com/feeRnt/ps4-linux-12xx/issues/3 (Baikal 6.15.4 testing thread)

Local linux-ps4/ tree was **not** modified or referenced for this KB. Stays a
clean Baikal 5.4 reference.

---

## 1. Lineage and fork relationships

```
fail0verflow/ps4-linux  ──► codedwrench/ps4-linux  ──► feeRnt/ps4-linux-12xx ──► rmuxnet/ps4-linux-12xx
                                  (5.4.x base)             (6.15.4 leader)         (7.0 leader)
```

Other upstream contributors whose patches feed in: eeply, Ps3itaTeam, rancido,
valeryy (Baikal), mircoho, tihmstar, **crashniels** (Baikal 6.x leader), saya,
whitehax0r, **DFAUS** (5.4.247-baikal author).

Fork data (2026-05-08):

| Repo | Default branch | Forked from | Stars | Last push |
|---|---|---|---|---|
| feeRnt/ps4-linux-12xx | `6.15.4-aeolia-belize-crashniels` | codedwrench/ps4-linux | 33 | 2026-05-08 |
| rmuxnet/ps4-linux-12xx | `7.0-Stable` | feeRnt/ps4-linux-12xx | 10 | 2026-05-08 |

Compare-stats:
- feeRnt `x_exp__6.15.4-BaikalLove` vs `6.15.4-aeolia-belize-crashniels`: **105 ahead, 80 behind** (active divergent 6.15 Baikal work).
- rmuxnet `ps4-baikal-7.0-port` vs feeRnt `6.15.4-aeolia-belize-crashniels`: **76 594 ahead, 1528 behind** (mostly upstream 6.15→7.0 jump).

---

## 2. Active branches that matter

### feeRnt — current 6.15 effort
| Branch | What it is | Status |
|---|---|---|
| `6.15.4-aeolia-belize-crashniels` | Default. Stable 6.15.4 for Aeolia/Belize. Based on crashniels' 6.15 work. | Working on Aeolia/Belize. **Does NOT boot Baikal.** |
| `x_exp__6.15.4-BaikalLove` | **Active 6.15 Baikal experiment.** Last commit 2026-05-08. | Still kernel-panics (white LED) on Baikal as of 2026-05-05 testing. |
| `x_exp__6.15.4-baikal-crashniels` | Older crashniels-derived 6.15 Baikal experiment. | Reportedly worked for some testers (no USB), white-LED for others. |
| `x_exp__6.15.4-aeolia-belize-mt7668` | MT7668 WiFi work merged into main 6.15. | Already merged. |
| `x_exp__6.15.4-fam15h_power` / `-uvd-engine` / `-x86_vector_msi` | Subsystem-specific 6.15 experiments. | Reference only. |
| `x_exp__6.0/6.3/6.6/6.9/6.12/6.15.4-BaikalLove` | Stair-step Baikal porting attempts across kernel versions. | Archive of the climb 5.4 → 6.15. Useful to bisect *which* version regressed Baikal. |
| `x_exp__6.17.1-edid-oberdfr` | EDID-from-Orbis work (oberdfr's port). | For monitor blackscreen issue, not Baikal-specific. |
| `5.4.247-baikal-dfaus` | **The known-good Baikal kernel.** | Reference baseline. This is what currently works on Baikal. Mesa cap: ≤ 25.1.x. |
| `5.15.15-belize` / `5.15.189-belize` | Belize 5.15 fixed (WiFi + blackscreen). | Belize only. 5.15 broke for Baikal — start of the regression. |

### rmuxnet — current 7.0 effort
| Branch | What it is | Status |
|---|---|---|
| `7.0-Stable` | Default. Stable Aeolia/Belize 7.0 line. | Has all the 7.0 stability work; Baikal not in scope here. |
| `ps4-baikal-7.0-port` | **THE 7.0-Baikal port.** Last commit 2026-05-06. | "USB working motherfuckers" landed 2026-05-02. Still WIP. |
| `ps4-baikal-7.0-clean` | Clean 7.0 Baikal staging. | Pre-port baseline. |
| `ps4-baikal-ethernet-experiment` | sky2 Baikal GBE experimental. | Separate ethernet bringup track. |
| `rmux/baikal/bringup` | **Refactored rebased Baikal bringup**, last commit 2026-05-07. Twelve clean commits stacked on Linus 5.4.213. | Newest organized snapshot; useful as a reference series. |
| `rmux/sky2/experimental-fixes` | sky2 interrupt-storm + memory-leak fix across all southbridges. | Targets the cross-southbridge sky2 bug. |
| `rmux/uart/ps4-apcie-8250` | APCIE/8250 UART. | Useful for our ps4-uart work. |
| `rmux/icc/ps4-icc-hardening` | ICC IRQ + ioctl hardening. | Already merged into 7.0-Stable. |
| `rmux/display/ps4-bridge-*` (multiple) | Belize bridge enable / DP retrain / fixed modes / safe 60 Hz. | Display stability work for Belize. |
| `6.18.18/20/21-Strawberry*` | Older Strawberry 6.18.x lines. | Fallback / archive. |

### Branches to ignore for porting work
- `x_old__*` — heavy debug-log branches, unstable.
- `7.0-Broken` (rmuxnet) — name says it.
- `temporary_branch`, `KolliasG7/Testing` — random testing.

---

## 3. Console-model / southbridge / kernel matrix

(Combined from both READMEs, 2026-05-08.)

| Console | Variation | WiFi/BT | Best working kernel today |
|---|---|---|---|
| CUH-1216 (A/B) | Phat — Belize B0 | Marvell 88w8897 (Torus 2) | 6.15.4 / 5.15.15 |
| CUH-1215 (A/B) | Phat — Belize | Marvell 88w8897 (Torus 2) | 6.15.4 / 5.15.15 |
| CUH-1003 | Phat — Aeolia | unknown | 6.15.4 (likely no-built-in-fw variant) |
| CUH-1004A | Phat — Aeolia | Marvell 88w8797 (Torus 1) | 6.15.4 (no-built-in-fw variant required) |
| CUH-1116A | Phat — Aeolia | unknown | 6.15.4 |
| CUH-2215B | Slim — Baikal | unknown | **5.4.247 only** |
| CUH-2216A | Slim — Baikal B1 | MediaTek 7668 | **5.4.247 only** |
| CUH-2216A | Slim — Belize | MediaTek 7668 | 5.15.15 |
| CUH-7116B | Pro — Baikal B1 | unknown | **5.4.247 only** |
| CUH-7202B | Pro — Baikal | unknown | **5.4.247 only** |
| CUH-7216B | Pro — Baikal | MediaTek 7668 | **5.4.247 only** |

**Bottom line**: Baikal is stuck on 5.4.247. Every kernel above 5.4 has regressed
Baikal support. 5.15 was the first version that broke. 6.15 is what's currently
being attacked.

---

## 4. Issue #3 (feeRnt) — Baikal 6.15.4 testing thread

22 comments, opened 2026-02-19 by `vnkgdshrr`, last reply 2026-05-05.

### Established facts
- 6.15.4 default branch boots fine on Aeolia/Belize.
- 6.15.4 produces **white LED (kernel panic before initramfs)** on Baikal in every
  test reported in this thread, including the most recent
  `x_exp__6.15.4-BaikalLove` build (2026-05-05 test by `vnkgdshrr`).
- crashniels' earlier 6.15-Baikal allegedly worked for *some* testers (no USB),
  white-LED for others — i.e. results are non-deterministic across consoles.
- A USB keyboard's caps-lock toggles for a brief window after the screen blanks,
  then stops. Suggests **USB stack is alive briefly, then panics or wedges**.
- feeRnt's hypothesis: the regression is **in the 5.4 → 5.15 jump**, narrowing
  the suspect surface. `xhci-aeolia` is named as a hot spot.
- crashniels' advice: for Aeolia/Belize do **not** use `-baikal` builds. The
  click-and-power-off symptom = kexec failed (kernel never loaded at all).

### What's wanted from testers
- Baikal console + UART wires (most useful debugging path).
- Putty + GoldHEN realtime debugging klogs as the loader fires the payload
  (https://wololo.net/2023/08/26/how-to-making-ps4-homebrew-in-2023-tutorial-kind-of/).
- SSH-into-initramfs via `ip=...` bootargs, OR an `init` patch that dumps
  `dmesg > /mounted_usb/...` — though both presume initramfs is reached, which
  Baikal currently doesn't.

### Where the maintainers are now (as of 2026-05-05)
- feeRnt is iterating on `x_exp__6.15.4-BaikalLove`. Latest build (Actions run
  25365919676) panics; not finished but "sense of direction".
- rmuxnet has parallel WIP on `ps4-baikal-7.0-port`. Tester help requested for
  both tracks.

---

## 5. What rmuxnet actually changed in `ps4-baikal-7.0-port`

Top of branch (most recent first) — these are the patches stacked on top of
upstream Linux 7.0 (`028ef9c9`):

1. `usb: xhci-aeolia: Define extra_priv_size and enforce apcie IRQ assignment`
2. `ps4: Include KUnit static stub header in apcie-icc for unit testing`
3. `drm/amdgpu: Refactor PS4 display bridge to use devm allocation and export core symbols`
4. `drm/amdgpu: Enable MEC2 microcode initialization for Liverpool and Gladius ASICs`
5. `drm/amdgpu: Add defensive null pointer checks for device contexts in atombios encoders`
6. **`ps4/baikal: USB working motherfuckers`** ← landmark commit, 2026-05-02
7. `xhci-aeolia/bpcie/amdgpu: Fix Baikal USB, SATA PHY and amdgpu null deref`
8. `iommu/amd: fix PS4 Baikal coherent DMA`
9. `usb: xhci-aeolia: fix Baikal xHCI setup`
10. `usb: xhci-aeolia: fix Baikal HCD setup`
11. `usb: xhci-aeolia: restore PS4 IRQ assignment`
12. `pci/iommu: add narrowly gated PS4 quirks`
13. `drm/amdgpu: add PS4 HDMI bridge`
14. `drm/amdgpu: add Liverpool/Gladius ASIC support`
15. `net: add PS4 sky2 support`
16. `mmc: add PS4 SDHCI support`
17. `usb: add PS4 xHCI support`
18. `ata: add PS4 Baikal AHCI support`
19. `ps4: add shared Aeolia/Baikal southbridge drivers`
20. `pci/hwmon: add Sony/AMD IDs needed by PS4`
21. `x86/irq: add PS4/Baikal MSI compatibility`
22. `x86/platform: add PS4 platform support`

This series is the cleanest, most legible 7.0 Baikal stack to study — it's
organized as foundation→subsystem→bugfix layers. Use it as the reference for
porting decisions.

The cleaner, rebased equivalent on `rmux/baikal/bringup` (2026-05-07) collapses
this into 12 commits over Linus 5.4.213 — semantically the same patches, named:
`x86/ps4`, `pci/msi`, `drivers/ps4 (southbridge glue, ICC, pwrbutton+UART)`,
`drm/amdgpu Baikal`, `xhci-aeolia`, `ahci`, `sdhci-pci`, `sky2`, `pci+hwmon+iommu`,
`x86+mfd misc`, default config.

---

## 6. What feeRnt is doing in `x_exp__6.15.4-BaikalLove`

Top of branch (2026-05-08 down to 2026-04-29):

- IOMMU page-fault stack dumps + bpcie logs (debugging aid)
- xhci-aeolia: NULL `axhci->host` on `ahci_init_one` failure to dodge OOPS
- ps4-bpcie: change `desc->dev`s to `sc_dev` device for function 14.4
- ata-usb dump_stack instrumentation
- ps4-bpcie: revert reversion of Aeolia-like IRQ map for `compose_msg`
- ps4-bpcie: fix `fwpsec` naming for multi-domain MSI
- ps4-bpcie: use function 14.4 for IOMMU IR matching
- ps4-bpcie: assign `devid` in `set_desc` for `msi_alloc_info`
- iommu/amd: re-add Baikal for remap select; later removed; iterating
- ps4-bpcie: re-add simplified `msi_prepare` for `X86_IRQ_ALLOC_TYPE_PCI_MSI`
- apic/vector: remove Baikal from `x86_vector_select`; later reverted
- ps4-bpcie: properly create one MSI domain per 14.x PCI function
- platform/ps4: add southbridge selection at early-boot to calibrate timer

**Diagnosis from these commit titles:** the active fight on 6.15 Baikal is in
**MSI/IRQ routing for the bpcie southbridge functions**, plus IOMMU coherent-DMA
and xHCI setup. That matches the symptom (boot starts, USB briefly alive, panic
shortly after) — IRQ-domain misconfig on Baikal would white-LED in exactly that
window.

---

## 7. Cross-cutting issues to know about

### sky2 (gigabit ethernet)
rmuxnet's `rmux/sky2/experimental-fixes` (`45f6ad09`, 2026-05-06) addresses
"interrupt storm and memory leak on PS4" and is targeted at **all**
southbridges (Aeolia, Belize, Baikal). If our local linux-ps4/ build hits
ethernet flakiness, this is the patch to pull in.

### Display / blackscreen / EDID
- `oberdfr/kernel-ps4linux ps4-linux-v6.17.1-custom-resolution`: pulls EDID into
  Linux to handle non-1080p monitors and capture cards.
- `ps4gentoo/initramfs` + `ps4boot/ps4-linux-payloads`: alternate approach —
  loader copies Orbis-sourced EDID into initramfs.
- rmuxnet `rmux/display/ps4-belize-*` and `ps4-bridge-*` branches: bridge
  enable retry, post-enable DP retrain, safe 60 Hz fallback.

### Firmware
- SD8797 (Aeolia/Torus 1, CUH-1004A): older models historically needed a
  "no-built-in-fw" kernel variant. rmuxnet 7.0-Stable now handles it through
  the build workflow — expects `extra_firmware/mrvl/sd8797_uapsta.bin`.
- SD8897 (Belize/Torus 2): mainline blob works.
- MT7668 (newer Baikal/Belize): supported via `drivers/net/wireless/mediatek/mt76x8`
  with bundled firmware.

### Mesa cap
For 5.4.247 Baikal kernels, **Mesa must be ≤ 25.1.x** for proper GPU function
(see feeRnt issue #8). Distro choice for Baikal users is constrained.

---

## 8. Known-good debugging methodology

In order of usefulness:

1. **UART** wires soldered to the southbridge — the only way to see kernel
   output before/at the panic. Both maintainers have stated this is the
   blocker for further Baikal progress.
2. **GoldHEN klog over network** (Putty) — captures up to the kexec point
   only; useful to confirm the loader handed off cleanly.
3. **`dmesg > /mnt/...` from initramfs init script** — only works if the
   kernel reaches initramfs (Baikal currently doesn't).
4. **SSH-into-initramfs via `ip=...` bootargs** — same precondition.
5. GitHub Actions builds: feeRnt and rmuxnet both publish per-branch CI
   artefacts. Testers can grab a `bzImage` directly without local builds.

---

## 9. Pointers for our continued development

We currently have linux-ps4/ on **Baikal 5.4** (per `BUILD_LOG.md`, target
`5.4-baikal`). Strategies to consider, ordered by risk:

1. **Stay on 5.4, mainline-cleanup approach.** Pull rmuxnet's `rmux/sky2/...`
   and any 5.4-applicable stability patches. Lowest risk, smallest gains.
2. **5.4 → 5.15 bisect.** This is the regression boundary nobody's nailed
   down. Pick crashniels' 5.15 Baikal branches, find which subsystem first
   stops working. Provides intel that benefits *all* downstream porters.
3. **Pull rmuxnet `rmux/baikal/bringup` series (12 commits) onto a clean
   base** as our 6.x → 7.0 starting point. It's the most legible reference.
4. **Track feeRnt `x_exp__6.15.4-BaikalLove` and rmuxnet `ps4-baikal-7.0-port`**
   as upstreams. Both are alive (May 2026 commits). Subscribe to issue #3.
5. **Provide a tester with UART** (we have a `ps4-uart/` directory — relevant
   if we have hardware capability). Either maintainer would prioritize a
   tester who can produce serial logs.

If we *do* port forward, the IRQ/MSI domain logic on bpcie functions (function
14.x routing) is the hottest battleground — that's where feeRnt has been
churning for two weeks straight. Don't reinvent; pull or learn from his work.

---

## 10. Releases worth knowing about

### feeRnt
- `v6.15.4__crashnt-4.7` (2026-03-10) — current stable 6.15 for Aeolia/Belize
- `v6.15.4__crashnt-3` (2025-11-23) — earlier 6.15 with ZRAM/KVM/Docker/Netfilter
- `v6.15.4__wifi_blkscrn` (2025-08-30) — first 6.15 with blackscreen fix
- `v5.15.15__obsidianx-4.0` (2026-03-10) — current Belize 5.15
- `v5.4.247__neocine-1.1` (2026-03-10) — **current Baikal 5.4 release**
- `v5.4.247__baikal_mt76` (2025-09-19) — MT7668 + blackscreen for Baikal

### rmuxnet
- `7.0-April-24` (2026-04-24) — Strawberry 7.0 (Aeolia/Belize)
- `6.18.21-April-3` (2026-04-03) — older Strawberry 6.18.21

No Baikal-7.0 release exists yet.

---

## 11. Open issues snapshot (feeRnt repo)

- **#3** — Baikal 6.15.4 (the thread above), 22 comments, open.
- **#13** — "Strange sporadic flickering at initramfs/early rescueshell"
  (feeRnt, no comments yet).
- **#14** — "No blue-ray drive Baikal slim 5.4.247" (Switch-modder, 6 comments).

rmuxnet repo has no open issues.

---

## 12. Quick-reference URLs

- feeRnt repo: https://github.com/feeRnt/ps4-linux-12xx
- rmuxnet repo: https://github.com/rmuxnet/ps4-linux-12xx
- Issue #3 (Baikal 6.15): https://github.com/feeRnt/ps4-linux-12xx/issues/3
- Active 6.15-Baikal branch: https://github.com/feeRnt/ps4-linux-12xx/tree/x_exp__6.15.4-BaikalLove
- Active 7.0-Baikal branch: https://github.com/rmuxnet/ps4-linux-12xx/tree/ps4-baikal-7.0-port
- Cleanest reference series: https://github.com/rmuxnet/ps4-linux-12xx/tree/rmux/baikal/bringup
- crashniels (Baikal 6.x upstream): https://github.com/crashniels/linux
- DFAUS (Baikal 5.4.247 upstream): https://github.com/DFAUS-git/ps4-baikal-5.4.247-kernel
- codedwrench (5.4 base): https://github.com/codedwrench/ps4-linux
- Community: https://ps4linux.com/ — Discord: https://discord.gg/QtcPmzHVVm and https://discord.gg/jebUjgBu6T
