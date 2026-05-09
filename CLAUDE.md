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

## Build hygiene — when to clean rebuild

Default to **incremental** (`./build.sh -t 6.x-baikal`, ~2 min). It works the way kbuild expects: `git checkout .` resets tracked files, `git clean -fd` removes untracked, patches re-apply, `make` recompiles only files whose mtime changed. The kernel tree's `.gitignore` keeps `*.o`/`*.ko`/`built-in.a` between runs as a build cache, which is the right behaviour 99% of the time.

**Switch to `./build.sh -t 6.x-baikal -c` (full clean, ~5 min) when:**

- A patch added/removed/edited touches a **header file** (`.h`) — kbuild's dependency tracking can miss transitive `#include` changes, leaving stale `.o` files for callers of the changed header.
- A patch changes a **`Kconfig`** or **`config/*.config`** entry — `olddefconfig` may not propagate the change through every `.o` that depends on it.
- A patch is **applied → reverted → reapplied** with the same final content but a different intermediate state (kbuild may keep `.o` from the intermediate).
- The toolchain (gcc/clang/binutils) was upgraded since the last build.
- A boot test produces behaviour that doesn't match the source — first thing to rule out is a stale cache.

`-c` deletes `src/<target>/` and `output/<target>/` outright, re-clones vanilla kernel from `BASE_REF`, applies the full patch series, and rebuilds from zero. The bzImage that comes out is bit-identical to a fresh tree's, modulo build timestamp.

For a between-test rebuild that *only* changes a `.c` file: incremental is enough.

## Iteration workflow (settled 2026-05-09)

This is the loop we run for every kernel-side experiment. Each step has a
specific actor — Claude OR user — written explicitly because mixing them up
costs reboots.

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. PROPOSE      Claude reads logs / upstream / past iterations and      │
│                 proposes a concrete next change with hypothesis +       │
│                 expected signal.  User says yes/no/redirect.            │
├─────────────────────────────────────────────────────────────────────────┤
│ 2. PATCH        Claude edits source under src/<target>/, regenerates    │
│                 the affected patches/<target>/.../<NNNN>-...patch       │
│                 from a snapshot diff, runs ./build.sh -t <target>       │
│                 (or -c for header changes — see "Build hygiene"         │
│                 above).                                                 │
├─────────────────────────────────────────────────────────────────────────┤
│ 3. STAGE        Claude waits until USB is plugged into the host, then   │
│                 sudo bash scripts/swap-bzimage.sh + verifies md5sum     │
│                 match between built bzImage and bzImage on USB.         │
│                 Drops a marker in the rolling UART log.                 │
├─────────────────────────────────────────────────────────────────────────┤
│ 4. ARM CAPTURE  User says "start" / "start log" / "start capture".      │
│                 Claude runs:                                            │
│                   scripts/dev/boot-capture.sh start <name>              │
│                 which records the byte offset of the rolling UART log  │
│                 right now.                                              │
├─────────────────────────────────────────────────────────────────────────┤
│ 5. BOOT         User physically moves USB to PS4, power-cycles the      │
│                 console, and goes through the PSFree-Enhanced gauntlet  │
│                 (see "NEVER trigger a PS4 reboot" above).               │
│                 Claude does NOT initiate this.                          │
├─────────────────────────────────────────────────────────────────────────┤
│ 6. WATCH        ps4-uart/ps4uart.py is already running in the           │
│                 background; it streams /dev/ttyUSB0 into                │
│                 ps4-uart/logs/ps4_uart_*.log.  User watches the UART    │
│                 live (or just the console).                             │
├─────────────────────────────────────────────────────────────────────────┤
│ 7. STOP         User says "stop" / "check logs" / "done".  Claude runs: │
│                   scripts/dev/boot-capture.sh stop <name>               │
│                 which slices the bytes added since step 4 into          │
│                 checkpoint/uart-logs/<DATE>_<TIME>-<name>.log,          │
│                 sanitizing non-printable bytes from serial reconnects   │
│                 to '?', and prints a quick signal-count summary         │
│                 (Linux version, bpcie_handle_edge_irq, Command          │
│                 Aborted, etc.).                                         │
├─────────────────────────────────────────────────────────────────────────┤
│ 8. ANALYZE      Claude reads the saved excerpt, writes a per-test       │
│                 report under checkpoint/docs/research/<DATE>-<name>-    │
│                 result.md, appends one paragraph each to LEARNINGS.md   │
│                 + BUILD_LOG.md.                                         │
├─────────────────────────────────────────────────────────────────────────┤
│ 9. COMMIT       Claude commits the patch + docs + saved log under one  │
│                 message that captures the result, then `git push`.      │
│                 Authored as "Meerzulee", co-authored-by Claude.        │
├─────────────────────────────────────────────────────────────────────────┤
│ 10. NEXT        User compacts the conversation when context fills up,   │
│                 may switch effort/model, and starts the next            │
│                 iteration from "PROPOSE" with the committed state as    │
│                 the new baseline.                                       │
└─────────────────────────────────────────────────────────────────────────┘
```

### Things to remember about each step

- **Step 2 (PATCH):** prefer editing source under `src/<target>/` and
  regenerating the patch from a snapshot diff (vs hand-editing the .patch
  file).  Hand-editing tends to break unified diff hunk headers when context
  shifts.  Pattern: keep `/tmp/bpcie.before-B.c` (or similar) as the snapshot
  baseline; after editing in-tree source, `diff -u --label=...` against the
  snapshot to produce the patch body.

- **Step 3 (STAGE):** the build script re-applies the patch series from
  scratch each run, which means **any direct edit to source under
  `src/<target>/` after build will be wiped on the next build**.  Always
  update the patch file as the source of truth.

- **Step 4 (ARM CAPTURE):** the marker pattern (`echo "===MARKER..." | sudo
  tee -a logs/...`) is unreliable because pyserial's buffered writes
  routinely clobber appended markers.  Use `boot-capture.sh start <name>`
  instead — it records byte offset, not text marker.

- **Step 7 (STOP):** the saved excerpt is the source of truth for the boot.
  Quote line numbers from it (e.g. "see line 1742 of `2026-05-09_1436-v7-
  baikallove.log`") in reports, not from the rolling log (which keeps growing
  and shifts line numbers).

- **Step 8 (ANALYZE):** include three things in every report — counts table
  (vs previous iteration), boot timing milestones (`first at: t=...`), and
  hypotheses for the next iteration.  See
  `checkpoint/docs/research/2026-05-09-v7-baikallove-result.md` for the
  template.

- **Step 9 (COMMIT):** commit messages should state the change AND the
  hardware result (✅/❌ per signal).  Future-Claude reading `git log` should
  be able to tell which iterations are dead ends without reading the patch.

### Naming conventions for `<name>` in steps 4/7

- `<option>-v<N>-<short-tag>` for kernel iteration tests:
  e.g. `option-b-v7-baikallove`, `option-b-v8-instrument`.
- `<feature>-<scenario>` for one-off experiments:
  e.g. `iommu-passthrough`, `nomsi-bypass-test`.
- Keep it under ~30 chars so the saved filename is readable.

## Reference paths

- `checkpoint/docs/PLAN.md` — global plan and next-session priority list
- `checkpoint/docs/LEARNINGS.md` — diagnosis history
- `checkpoint/docs/research/` — per-iteration boot reports + upstream surveys
- `checkpoint/uart-logs/` — per-test UART excerpts (saved by `boot-capture.sh stop`)
- `BUILD_LOG.md` — chronological session notes
- `scripts/dev/` — host-side dev environment.  `scripts/dev/README.md` documents
  `boot-capture.sh` (the per-test UART slicer used in steps 4/7 of the loop above).
