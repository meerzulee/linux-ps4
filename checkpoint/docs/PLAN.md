# PS4 Linux — Global plan

## Where we landed (end of 2026-05-08)

| Component | Status |
|---|---|
| **5.4 prebuilt** (feeRnt Clang-14) | ✅ Boots, KDE, WiFi, SSH |
| **5.4 our build** (Clang 22 + bpcie-uart patch + mt76 `=y`) | ✅ Boots, KDE, WiFi, SSH. Build pipeline fully validated. |
| **6.x our build** with proper bootargs (`keep_bootcon`, no `console=ttyS0`) | ✅ **Boots to userspace `/init` at 7.28 s** (1753 lines of UART). All 8 PS4 PCI funcs detected. amdgpu KMS, ALSA, SDHCI, sky2, xhci-aeolia drivers all init. **Hangs in initramfs** at 17 s on `LABEL=psxitarch: Can't lookup blockdev` — PS4 storage drivers stuck in deferred-probe limbo because `bpcie_probe` aborts (see breakthrough below). |
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

Now that we know the real blocker is `bpcie_probe` aborting on UART registration failure, the cheap path is well-defined.

### 1. (highest leverage, ~5 LOC) Make `bpcie_uart_init` failure non-fatal

In `drivers/ps4/ps4-bpcie.c::bpcie_probe`, change:

```c
if ((ret = bpcie_uart_init(sc)) < 0)
    goto remove_glue;
```

to:

```c
if (bpcie_uart_init(sc) < 0)
    sc_warn("bpcie: UART init failed, continuing without serial console\n");
```

Rationale: UART is a debug aid; `serial_line[i] = -1` initialization in `bpcie_uart_init` already supports the "never registered" case in remove/suspend/resume paths. ICC (which is critical) doesn't depend on UART. With this change, the entire PS4 child-driver tree becomes probe-able, and we get to see the next failure mode — likely something in xhci-aeolia or amdgpu, but at least it's progress past `LABEL=psxitarch`.

Drop in as `patches/6.x-baikal/0200-ps4-drivers/0004-ps4-bpcie-make-uart-failure-non-fatal.patch`. Rebuild via `research/build/` or `linux-ps4/build.sh -t 6.x-baikal`. ~10 min round trip.

### 2. Re-enable `0003-ps4-bpcie-uart-set-port-type.patch` and re-test

Now that bootargs aren't poisoned, the patch's earlier "triple-fault at kexec" might have been chained from the broken cmdline. Re-enable in `patches/6.x-baikal/series`, rebuild, boot. If it works, we get UART on `ttySN` *and* a successful bpcie probe.

If it still triple-faults, apply the option-1 workaround and re-test — that proves the triple-fault is independent of bootargs.

### 3. Test sky2 storm fix once boot reaches userspace

`patches/6.x-baikal/0700-network-sky2/0002-sky2-rmuxnet-storm-fix.patch.candidate` is staged. Once we get past `LABEL=psxitarch`, we can validate whether ethernet is actually fixed by it. Drop into `0700-network-sky2/0002-…`, rebuild.

### 4. (after #1 succeeds) Find the next hang

With `initcall_debug` + `keep_bootcon`, the next failure mode will be visible in the UART log. Could be xhci-aeolia probe failure (rmuxnet's "USB working motherfuckers" patches in `patches/rmuxnet-7.0-baikal/` may apply), amdgpu setup, or something deeper. Whatever it is, we'll have UART for it.

### Older items (still relevant, lower priority now)

- (was #6) Real ttyS4 transmit fix in bpcie-uart — this is the same patch as #2 above but for 5.4 too. Now that we understand the cascade, it's clearer that the patch matters for *probe* success, not just for UART output.
- (was #5) Layer patches one-by-one onto vanilla 6.15.4 — useful if #1 doesn't reveal the next clear hang.
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
