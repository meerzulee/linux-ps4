# v40 Test Protocol — Wake Up Edition

Read this in the morning. Quick steps to test the v40 candidate fix.

## What v40 does

Pre-allocates IRQ 9 descriptor at arch_initcall so ACPI's SCI handler
install can succeed. Without this, on PS4:
- legacy_pic = null_legacy_pic → no IRQ descs allocated
- ACPI request_irq(9) fails → mutex init terminates
- ATOM BIOS broken → amdgpu PLL garbage → blank HDMI

## Expected outcome

If v40 works, `dmesg` should show:
```
ps4: pre-allocated IRQ 9 desc for ACPI SCI (virq=9)
```

And **NOT** show:
```
ACPI: OSL: SCI (IRQ9) allocation failed
ACPI Error: AE_BAD_PARAMETER ... could not acquire Mutex [ACPI_MTX_Tables]
```

If the chain is fixed, `amdgpu_atombios_crtc_adjust_pll` will return a
real clock value (not 0). Then `dce_v8_0_crtc_mode_set` runs the full
ATOM BIOS PLL programming. Bridge locks. **HDMI displays.**

## Steps

1. Plug USB into host.

2. Check current state:
   ```
   md5sum output/6.x-baikal/bzImage
   # Should be: 745691cad182023d6bf93f1b4157f345
   ```

3. Stage:
   ```
   sudo bash scripts/swap-bzimage.sh output/6.x-baikal/bzImage
   sudo bash scripts/dev/update-bootargs.sh 6.x-edid-1920x1080
   ```

4. Arm capture:
   ```
   bash scripts/dev/boot-capture.sh start v40-irq9-desc-fix
   ```

5. Move USB to PS4. Power-cycle. Go through PSFree-Enhanced + Payload
   Guest gauntlet.

6. Watch monitor as kernel boots. Wait at least 30s after lightdm
   would normally start (~3-4 min total boot time).

7. Stop capture:
   ```
   bash scripts/dev/boot-capture.sh stop v40-irq9-desc-fix
   ```

8. Check log for the markers above:
   ```
   grep -i "pre-allocated IRQ 9\|SCI.*alloc\|MTX_Tables\|ATOM returned" \
     checkpoint/uart-logs/2026-05-10*v40*
   ```

## If it works

Commit + push, update memory with success status, celebrate.

## If it doesn't work

Possibilities ranked:
1. **Patch didn't fire** — check `is_ps4` value at arch_initcall time
2. **Some other ACPI mutex still NULL** — different root cause
3. **ACPI mutex works but ATOM BIOS still broken for other reason**
4. **Display works but you didn't wait long enough** — try again, wait
   60+ seconds at lightdm time

If patch didn't fire:
```
grep "ps4: pre-allocated\|ps4: failed" <log>
```
If neither appears, `is_ps4` was false. arch_initcall ran before
`x86_ps4_early_setup` ran (impossible per init order) OR something
else cleared is_ps4. Move the alloc to subsys_initcall instead.

If patch fired but mutex still broken:
- Look for new ACPI errors in log
- Maybe the mutex init order has another issue

## Path forward if v40 doesn't work

Try the defensive NULL-check (saved as `.candidate`):
```
mv patches/6.x-baikal/0150-acpi/0002-acpi-irq-null-check-gsi-domain-id.patch.candidate \
   patches/6.x-baikal/0150-acpi/0002-acpi-irq-null-check-gsi-domain-id.patch
# Add to series
# Rebuild + test
```

If still doesn't work, the answer might involve fixing ACPI table
fixup pre-kexec to add IOAPIC entries. That's payload-level work
(modify linux-1024mb.bin).

## State at end of overnight session

- 5.4-baikal: visually confirmed working with HDMI ✓
- 6.x v37: spurious vector eliminated, real IRQ delivery, brief RGB at /init
- 6.x v40 (THIS): candidate fix for the actual root cause, untested
- bzImage built: `output/6.x-baikal/bzImage` (md5 `745691cad...`)

Memory files updated:
- `~/.claude/projects/.../memory/ps4_6x_v40_root_cause_fix.md` — full details
- `~/.claude/projects/.../memory/ps4_5x_baseline_works.md` — 5.4 ref
- `~/.claude/projects/.../memory/MEMORY.md` — index
- `CLAUDE.md` — has v40 section at top

GitHub: https://github.com/meerzulee/linux-ps4 (latest commit `9746685`)
