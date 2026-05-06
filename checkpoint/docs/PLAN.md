# PS4 Linux — Global plan

## Where we landed (end of 2026-05-06)

| Component | Status |
|---|---|
| **5.4 prebuilt** (feeRnt Clang-14) | ✅ Boots, KDE, WiFi, SSH |
| **5.4 our build** (Clang 22 + bpcie-uart patch + mt76 `=y`) | ✅ Boots, KDE, WiFi, SSH. Build pipeline fully validated. |
| **6.x our build** without uart patch | ⏸ Reaches fbcon takeover (~0.66 s), 120 lines of UART, then hangs silently. HDMI blank, mouse/keyboard non-functional. Same as morning's test. |
| **6.x our build** with uart patch | ❌ Triple-faults at kexec, 0 UART output. Patch incompatible with 6.x's serial8250. |
| **6.x without uart patch + keep_bootcon** | ❌ Hard hang at kexec, 0 UART output. Counter-intuitive — `keep_bootcon` somehow makes it worse on 6.x. |
| **UART late boot** | ❌ ttyS4 transmit doesn't work even with our patch on 5.4 (`tx:0` after writes). bpcie-uart driver needs more work. |

## Key facts known about hardware/quirks

- **PS4 Jaguar APU** — x86-64-v2 + AVX1 only. No AVX2/BMI/FMA/LZCNT. Modern Arch (v3) binaries SIGILL → "Attempted to kill init!" panic. Use deeWaardt's tarball.
- **BPCIe BAR2** — `0xC8800000`. UART0 = `0xC890E000` (user's cable), UART1 = `0xC890F000`.
- **`/proc/tty/driver/serial`** with our patch shows `uart:16550A` for both UARTs (vs `unknown` without). Registration succeeds, but writes don't transmit (8250 driver state mismatch).
- **`keep_bootcon`** — crashes xhci_aeolia at ~57 s on 5.4 (BPCIe bus overload). On 6.x, appears to cause immediate hang. Don't use.
- **`earlyprintk=serial,ttyS0,...`** — poison; targets non-existent legacy 8250 at `0x3F8`.
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

Each row is a single experiment. Run cheapest first. Stop when one yields data; investigate, then move on.

### 1. (cheapest) Try `init=/bin/sh` to bypass systemd
- Bootargs change only, no rebuild. Script: `scripts/bootargs-debug-shell.sh`.
- If kernel reaches shell → systemd was the issue. Poke live system to find which service hangs.
- If still blank → kernel itself dies pre-init.
- ~5 min round trip.

### 2. Build crashniels' kernel **as-is** (no our patches)
- We have their tree at `tmp/crashniels-6.15`. They've shipped this configuration as supposedly-working for Baikal.
- Their `.config`: `tmp/crashniels-6.15/config` (or generate via their `make defconfig`).
- Build command:
  ```
  cd tmp/crashniels-6.15
  cp config .config && make olddefconfig
  make -j12 bzImage
  ```
- If their kernel boots → our patch derivation introduced a regression. We bisect our patches against theirs.
- If their kernel doesn't boot either → hardware/payload mismatch with crashniels too; we'd switch to a different reference.
- ~15 min.

### 3. Disable suspect drivers in 6.x config
- Edit `config/6.x-baikal.config`, set to `=n`:
  - `CONFIG_DRM_RADEON` (legacy radeon Liverpool — most suspect)
  - `CONFIG_HSA_AMD` / `CONFIG_DRM_AMDGPU_USERPTR` (amdkfd CIK quirks)
  - `CONFIG_DRM_AMDGPU` (try without amdgpu in 6.x altogether — kernel boots without GPU accel but should still run)
- Rebuild + test.
- If 6.x boots without radeon → that's the hang. Then re-enable and patch the actual issue.
- ~12 min per attempt.

### 4. `initcall_debug` + photo-by-photo
- With `bootargs-debug-shell.sh` (already adds `initcall_debug`), kernel logs every initcall to HDMI fbcon.
- If 6.x reaches fbcon takeover (it should), the next initcall lines should appear on HDMI even though UART is silent.
- Take phone photo of HDMI when it hangs. Last `initcall: <function>+0x..` line is the culprit.
- Free with experiment 1 — script already includes both flags.

### 5. Layer patches one-by-one onto vanilla 6.15.4
- Apply only `0100-x86-platform`, build, test. Then add `0200-ps4-drivers`, etc.
- Find which group's addition breaks the boot.
- Most thorough; ~30+ min.

### 6. (advanced) Real ttyS4 transmit fix in bpcie-uart
- Currently tx_counter stays 0 after writes. `keep_bootcon` is a workaround but it crashes things.
- Options to try in `patches/5.4-baikal/0200-ps4-drivers/0002-ps4-bpcie-uart-set-port-type.patch`:
  - `port.type = PORT_8250` (instead of `PORT_16550A`) — simpler driver path
  - Drop `UPF_FIXED_TYPE` and let autoconfig run — see if it succeeds with our help
  - Set `port.fifosize = 16` and `UART_CAP_FIFO`
  - Inspect 8250 autoconfig source for what causes our hardware to be flagged as `PORT_UNKNOWN` and address that root cause

## Files to consult next session

- `checkpoint/docs/LEARNINGS.md` — full diagnosis history
- `checkpoint/docs/PLAN.md` — this file
- `checkpoint/docs/uart-boot-capture-ttyS0E000.log` — reference UART boot
- `BUILD_LOG.md` — chronological session notes
- `patches/6.x-baikal/series` — the disabled `0003-ps4-bpcie-uart-set-port-type.patch` reminds us not to re-enable for 6.x
- `scripts/` — every helper, named by purpose

## Recovery / known-good state

USB right now (2026-05-07 00:50):
- `bzImage` = 6.x without uart patch, with `keep_bootcon` bootargs (= broken state, hard hang)
- `bzImage-5.4-feeRnt` = known-working prebuilt
- `bzImage-5.4-ours` = our self-built 5.4 with bpcie-uart patch (boots, KDE, WiFi, SSH)
- `bzImage-prev` = whatever was active before last swap

To return to working: `sudo bash scripts/rollback-to-our-5.4.sh` while USB is on host.

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
