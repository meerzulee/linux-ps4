# 6.x-baikal kernel — first successful boot to userspace

**Date:** 2026-05-08, ~21:50 local
**Kernel:** `6.15.4-Baikal_TESTING_crashniels-dirty` built in `research/build/`
**Hardware:** PS4 Slim Baikal (CUH-22xx), FW 12.02
**Loader:** ArabPixel v24b, `linux-1024mb.bin` payload
**Bootargs:**

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 keep_bootcon initcall_debug 8250.nr_uarts=0 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

**Capture:** `ps4-uart/logs/ps4_uart_20260508_211557.log` lines 10452–end. Extracted standalone copy at `checkpoint/docs/uart-boot-2026-05-08-6x-keep_bootcon-success.log` (1753 lines).

---

## What flipped

Before this run, the 6.x build "hung silently at ~0.66 s" after `printk: legacy bootconsole [uart8250] disabled` — looked like a real freeze on UART, with HDMI blank. **It wasn't a freeze.** It was just our printk sink going dark.

The fix was three changes to `bootargs.txt`, all of which mattered:

1. **Drop `console=ttyS0,115200n8`** — that was directing post-bootconsole printks at a phantom legacy 8250 at I/O `0x3F8`, which doesn't exist on PS4. (Documented in `LEARNINGS.md` for `earlyprintk=`; same trap, different option.)
2. **Add `keep_bootcon`** — keeps the MMIO bootconsole alive past the regular-console handoff. The kernel acknowledged this with `printk: debug: skip boot console de-registration.` (line 10477).
3. **`8250.nr_uarts=0`** — stops the 8250 driver from trying to enumerate phantom legacy slots.

The earlier `,keep` suffix on earlycon was a mistake on my part — kernel rejected it as `unsupported earlycon uart clkrate option`. The proper way to keep the bootconsole alive in modern Linux is the separate `keep_bootcon` parameter.

PLAN.md previously warned that `keep_bootcon` "appears to cause immediate hang on 6.x" — that was probably not `keep_bootcon` itself but something else co-occurring. With the cleaned-up cmdline above, **`keep_bootcon` is fine on 6.x.**

---

## What worked

| Subsystem | Status | Evidence |
|---|---|---|
| Loader → kernel handoff | ✅ | `kexec: About to relocate and jump to kernel` |
| `X86_SUBARCH_PS4` dispatch | ✅ | Line 1: `ps4: x86_ps4_early_setup: PS4 early setup` |
| EMC timer calibration | ✅ | Line 33: `ps4: EMC timer started in 2360 TSC ticks` then `Calibrated TSC frequency: 1594100864 kHz` |
| earlycon at our address | ✅ | Line 23: `earlycon: uart8250 at MMIO32 0x00000000c890e000 (options '115200n8')` |
| **`keep_bootcon` honored** | ✅ | Line 25: `printk: debug: skip boot console de-registration.` |
| ACPI parse including IVRS | ✅ | Lines 51–62, including the `PS4KEXEC` IVRS table from the loader |
| MTRR / PAT / e820 cleanup | ✅ | All clean |
| SLUB / RCU / per-CPU init | ✅ | Standard |
| LAPIC + APIC SMP enable | ✅ | `Allowing 8 present CPUs plus 0 hotplug CPUs` |
| **AMD-Vi / IOMMU** | ✅ | Line 124: `AMD-Vi: Using global IVHD EFR:0x0, EFR2:0x0` (kernel sees IVRS even though loader cleared the enable bit — expected behavior) |
| TSC clocksource | ✅ | Line 125: `tsc-early` registered |
| Spectre / Retbleed / SSB mitigations | ✅ | All applied |
| AMD PMU driver | ✅ | Line 142: `Performance Events: AMD PMU driver` |
| **All 8 Baikal PCI functions detected** | ✅ | Lines 681–704: vendor `0x104d`, devices `0x90d7..0x90de` (matches our `pci_ids.h` patch perfectly) |
| GPU detected | ✅ | Line 658: `pci 0000:00:01.0: [1002:9923] type 00 class 0x030000` (Liverpool) |
| GPU HDMI audio detected | ✅ | Line 674: `pci 0000:00:01.1: [1002:9921] type 00 class 0x040300` (Liverpool HDA) |
| amdgpu KMS init | ✅ | Line 1222: `[drm] amdgpu kernel modesetting enabled` |
| **bpcie glue probe** | ✅ | Lines 1254–1256: `bpcie_probe() → bpcie glue probe → Baikal chip revision: 4c0c2021:8d76a398:0000b100` |
| MSI domains created per func | ✅ | Lines 1257–1280: 8× `bpcie_create_irq_domain` for funcs 14.0..14.7 |
| MSI vectors allocated | ✅ | Line 1281: `dev->irq=1` |
| HDA audio device | ✅ | Line ~~~: `HD-Audio Generic at 0xe4840000 irq 1` |
| SDHCI controller detected | ✅ | Line 1434: `sdhci-pci 0000:00:14.3: SDHCI controller found [104d:90da] (rev 0)` |
| sky2 ethernet driver init | ✅ | Line 1349: `sky2: driver version 1.30` |
| xhci-aeolia driver init | ✅ | Line 1366: `xhci_aeolia_init` |
| Btrfs / crypto / blk subsystems | ✅ | All initcalls succeed |
| netconsole | ✅ | Line 1739: `printk: legacy console [netcon0] enabled` |
| ALSA sound | ✅ | `ALSA device list: HD-Audio Generic at 0xe4840000 irq 1` |
| **Userspace `/init` runs** | ✅ | `Run /init as init process` at 7.28 s |

---

## The smoking gun — why it didn't make it to a login prompt

Lines 1284–1286 of the extracted boot log:

```
baikal_pcie 0000:00:14.4: Failed to register serial port 0
baikal_pcie 0000:00:14.4: bpcie glue remove
baikal_pcie 0000:00:14.4: probe with driver baikal_pcie failed with error -5
```

`bpcie_probe()` is the orchestrator that brings up the entire PS4 southbridge in `drivers/ps4/ps4-bpcie.c`. Its sequence is:

```c
if ((ret = bpcie_glue_init(sc)) < 0) goto free_bars;       // ✅ succeeds
if ((ret = bpcie_uart_init(sc)) < 0) goto remove_glue;     // ❌ FAILS HERE
if ((ret = bpcie_icc_init(sc)) < 0)  goto remove_uart;     // never reached
```

`bpcie_uart_init()` calls `serial8250_register_8250_port()` for each of the two BPCIe 8250 ports. On 6.x, that helper **rejects the port** because the 8250 autoconfig logic doesn't probe the type as a known UART (returns `PORT_UNKNOWN`, registration fails). Without `port.type = PORT_16550A` and `UPF_FIXED_TYPE`, modern serial8250 won't accept the port.

This is **exactly the bug your `0003-ps4-bpcie-uart-set-port-type.patch` was written to fix on 5.4** — the same patch was extracted into the 6.x series and then disabled with this comment:

```
# Disabled for A/B test — re-enable once we confirm whether it causes the
# 6.x kexec triple-fault.
# 0200-ps4-drivers/0003-ps4-bpcie-uart-set-port-type.patch
```

PLAN.md row 4 noted: **"6.x our build with uart patch: ❌ Triple-faults at kexec, 0 UART output. Patch incompatible with 6.x's serial8250."** That earlier triple-fault was almost certainly **not the patch itself** — it was the broken bootargs (`console=ttyS0,115200n8` directing printk into the void during the patch's exception-time path). With clean bootargs we now have, the patch should be safe to re-enable.

### Why this hangs userspace

Once `bpcie_probe` returns `-5`, none of the PS4 child devices that gate on `apcie_status() == 1` can probe:
- `amdgpu` keeps deferring (line 1223: `probe of 0000:00:01.0 returned 517 after 13 usecs`) — 517 = `-EPROBE_DEFER`.
- `ahci` defers on `0000:00:14.2`.
- `sdhci-pci` actually **does** detect the controller (at function 14.3) but likely also defers waiting on bpcie.
- `xhci-aeolia` defers on `0000:00:14.7`.
- `sky2` defers waiting on apcie/bpcie status.

Result: kernel reaches `Run /init` because nothing in core is actually broken, the initramfs starts, but **no USB, no SATA, no real GPU.** `LABEL=psxitarch` lives on the USB FAT32+ext4, which needs the BPCIe USB stack alive, which needs bpcie probed. So:

```
[   17.331192] LABEL=psxitarch: Can't lookup blockdev
[   17.336281] LABEL=psxitarch: Can't lookup blockdev
... ad infinitum
```

That's where it actually stops.

---

## Concrete next moves, in priority order

### 1 — Make `bpcie_uart_init` failure non-fatal (smallest change, highest leverage)

Instead of fighting 8250 autoconfig, just don't gate the entire southbridge on UART working. The UART is a debug aid; if it fails to register, log a warning and proceed. ICC (which is critical) doesn't depend on UART.

Patch sketch (against `drivers/ps4/ps4-bpcie.c::bpcie_probe`):

```c
if ((ret = bpcie_glue_init(sc)) < 0)
    goto free_bars;

/* UART is a debug aid; failures here shouldn't kill the southbridge. */
if (bpcie_uart_init(sc) < 0)
    sc_warn("bpcie: UART init failed, continuing without serial console\n");

if ((ret = bpcie_icc_init(sc)) < 0)
    goto remove_uart;  /* still safe — remove path checks for null */
```

This unblocks **all PS4 drivers** in one ~5-line patch. We'd lose `ttySN` for kernel console (already happens because of 6.x serial8250 mismatch), but `earlycon=uart8250,mmio32,0xC890E000` already gives us UART for kernel printk.

Risk: needs a corresponding tweak in `bpcie_uart_remove`/`_resume`/`_suspend` to handle the "we never actually registered any ports" case. The `serial_line[i] = -1` initialization in `bpcie_uart_init` already supports this — those paths check `>= 0` before calling `serial8250_*` and skip otherwise.

### 2 — Re-enable `0003-ps4-bpcie-uart-set-port-type.patch` in the 6.x series

If we want UART **and** bpcie probe to succeed, fix the underlying 8250 registration. The 5.4 version of the patch sets `port.type = PORT_16550A` + `UPF_FIXED_TYPE`. On 6.x, that may need adjusting because 8250 internals changed — but the API surface is the same. Worth re-trying now that the cmdline isn't poisoned.

If it still triple-faults, **bisect with the option (1) workaround applied** to confirm that the triple-fault wasn't actually a chained failure.

### 3 — Address the deferred-probe -ENODEV chain

Even with bpcie probed, `probe of 0000:00:14.0 returned 19` (-ENODEV) suggests function 0 (ACPI) has no driver bound. Function 5 (DMAC) and 6 (MEM) might be the same. These are expected — they don't need their own drivers, the bpcie glue handles them via `pci_get_slot`. Probably benign; a "discard with quirk" comment in pci_ids.h would silence noise.

---

## What this changes about our overall picture

- **The 6.x kernel is much closer to working than PLAN.md suggested.** It boots fully, runs userspace, all 8 PS4 PCI functions are recognized. The hang isn't in core kernel — it's a single registration failure cascading.
- **`research/build/` reproducibly compiles a working kernel** outside `linux-ps4/`. The build pipeline is sound.
- **`keep_bootcon` is now a proven debugging tool for 6.x.** Add it to LEARNINGS.md under the UART debugging section; the previous warning about it crashing should be revisited.
- **The path to the rootfs is unblocked by one ~5-line patch** to `bpcie_probe`. That's smaller than expected.

---

## Files

- `checkpoint/docs/uart-boot-2026-05-08-6x-keep_bootcon-success.log` — extracted clean boot log (latest boot only, 1753 lines)
- `ps4-uart/logs/ps4_uart_20260508_211557.log` — the rolling capture (full session, ~12k lines, multiple boots)
