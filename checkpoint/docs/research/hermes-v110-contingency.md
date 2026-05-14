# hermes / gpt-5.5 — 2026-05-13

v110 contingency plan only. Do not build yet.

## A) probe ret=-5: softc_ptr high bit clear

Predicted notification:
`BAR0 probe ret=-5 copyout=-5 softc=0x00000000???????? res=0x0 kva=0x0 mmio=0x0 probe=00000000 00000000`

v111 fix:
- Stop using the KASLR-derived absolute BSS offset as the only locator.
- Add a kernel-side signature scan around `.data/.bss` for a plausible MTS softc pointer: high-half pointer whose `softc+0x3068` is high-half and whose resource `+0x10` is high-half.
- Keep `0x32f34938` as fast path, but fall back to scanning `kbase + 0x30000000..0x34000000` for candidates and validate before probing BAR.

## B) probe ret=-6: softc_ptr OK, softc+0x3068 garbage

Predicted notification:
`BAR0 probe ret=-6 copyout=-6 softc=0xffff... res=0x00000000???????? kva=0x0 mmio=0x0 probe=00000000 00000000`

v111 fix:
- Treat the located softc as wrong/stale; validate known softc fields before trusting `+0x3068`.
- Check `softc+0x30d6` MAC address bytes for sane nonzero Sony/locally-administered MAC and `softc+0x3090` device pointer high-half.
- If validation fails, scan for alternate softc candidates by looking for the live MAC bytes near `+0x30d6`, then verify `candidate+0x3068` resource chain.

## C) probe ret=-7: bar0_res OK, +0x10 not kernel-half

Predicted notification:
`BAR0 probe ret=-7 copyout=-7 softc=0xffff... res=0xffff... kva=0x00000000???????? mmio=0x1 probe=00000000 00000000`

v111 fix:
- Resource pointer is likely real, but FreeBSD resource layout/handle offset assumption is wrong.
- Try candidate handle offsets in order: `+0x18`, `+0x20`, `+0x28`, then `+0x08` only if it is not the MMIO flag on this object.
- For each high-half candidate, do only the 16-byte volatile probe and require BAR+0x04 to look like MTS status (`0xbxx` / bitfields), then dump.

## D) probe ret=-8: four dwords all 0xffffffff

Predicted notification:
`BAR0 probe ret=-8 copyout=-8 softc=0xffff... res=0xffff... kva=0xffff... mmio=0x1 probe=ffffffff ffffffff`

v111 fix:
- KVA is mapped but the access path may be wrong width/context, or the handle is not the child BAR0 window.
- Add read-width variants: u8/u16/u32, and also try offsets `bar0_kva + 0x1000/0x2000` in case handle points to a parent/window base.
- If still all-ones, stop MMIO reads from rendezvous and instead dump the resource object plus nearby bus tags/handles for offline layout decoding.

## E) probe ret=0 but first 16 bytes differ from Linux v97 expectations

Predicted notification:
`BAR0 probe ret=0 copyout=0 softc=0xffff... res=0xffff... kva=0xffff... mmio=0x1 probe=<nonzero non-ffff bytes>`

v111 fix:
- No fix needed if bytes are plausible MMIO; this is success even if not identical to Linux v97.
- Expected Orbis BAR+0x04 should be close to `0x00000b19` rather than Linux broken `0x00000b18`; BAR+0x00 may differ because it is the SMI command/data register.
- Let v110 proceed to full 4KB dump; compare snapshot offline and do not iterate payload unless full dump fails.

## F) PS4 panics again with spinlock timeout

Predicted notification:
- Screen likely remains stuck on `Walking MTS softc and probing BAR0 first 16 bytes...` or `BAR0 16-byte probe OK; dumping full 4KB...`, then ICC Fatal shutdown.

v111 fix:
- Delete BAR MMIO reads from the sys_kexec/smp_rendezvous path entirely.
- Use kpayload only to discover and copy out the three pointers/resource metadata, then return; do the BAR read from a normal Orbis kernel thread/context if we can spawn one, or implement a tiny installed syscall/hook that runs outside rendezvous.
- If no safe non-rendezvous execution path is available, abandon live BAR MMIO from payload and pivot to Orbis driver-assisted IOCTL/sysctl reads or Ghidra-derived software-state dump instead.
