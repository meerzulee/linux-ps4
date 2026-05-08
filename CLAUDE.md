# PS4 Linux project — Claude rules

## NEVER trigger a PS4 reboot

**Do not run `systemctl reboot`, `reboot`, `shutdown -r`, etc. on the PS4 over SSH.**

Reason: PS4's "reboot" is actually a power-off. Linux on PS4 doesn't go through a normal boot loader — it's loaded by a payload after a successful PSFree-Enhanced jailbreak. The full chain to get back to Linux on each cycle is:

1. Press power button on the PS4 to wake it
2. Open browser → PSFree-Enhanced
3. Trigger the jailbreak (~60% success rate; failures cost time)
4. Open Payload Guest → load `linux-1024mb.bin`
5. Hope the kernel boots

Every reboot costs the user this whole gauntlet. Triggering a reboot without their explicit "yes do it now" is a real cost — they have to be physically present at the console and time-budgeted.

**Workflow rule.** Stage everything: scp, mount, swap, sync, unmount. Then **stop and tell the user explicitly**: "USB updated, ready for next boot — power-cycle the PS4 when you're ready and I'll watch for SSH return." Let the user kick off the reboot.

This applies to:
- `scripts/dev/test-kernel.sh` and any future test runner
- Inline `ssh ps4 'systemctl reboot'` invocations
- Any script that says "reboot now"

The dev environment's safety net (`bzImage-stable`, `rollback-kernel.sh`) is for **when a previous boot crashed** — it doesn't avoid the cost of the reboot itself.

## Naming convention on the PS4 USB FAT32

| File | Meaning |
|---|---|
| `bzImage` | currently active boot kernel |
| `bzImage-stable` | last-known-good fallback (set via `mark-good.sh`) |
| `bzImage-prev` | what was active before the last test (auto-saved by `test-kernel.sh`) |
| `bzImage-5.4-feeRnt`, `bzImage-5.4-ours`, `bzImage-6.x-ours` | named backups of specific builds |

`rollback-kernel.sh` (run on host with USB plugged in) restores `bzImage` from `bzImage-stable` by default.

## Other settled things

- Use **deeWaardt's Baikal Arch tarball** for the rootfs. Pacstrap from CachyOS/modern Arch produces v3 binaries that SIGILL on PS4 Jaguar (no AVX2). Documented in `checkpoint/docs/LEARNINGS.md`.
- `keep_bootcon` rules: **don't use on 5.4** (crashes xhci_aeolia ~57 s); **DO use on 6.x for diagnosis** with `console=ttyS0` removed and `8250.nr_uarts=0`. Revised 2026-05-08 — see `checkpoint/docs/LEARNINGS.md` ("`keep_bootcon`: nuanced").
- Don't use `earlyprintk=serial,ttyS0,...` — targets nonexistent legacy 8250 at I/O 0x3F8.
- Use ArabPixel **v24b** unified payload (not the per-firmware ones).

## Reference paths

- `checkpoint/docs/PLAN.md` — global plan and next-session priority list
- `checkpoint/docs/LEARNINGS.md` — diagnosis history
- `BUILD_LOG.md` — chronological session notes
- `scripts/dev/` — host-side dev environment (test-kernel, mark-good, rollback-kernel)
