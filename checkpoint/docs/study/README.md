# PS4 Linux — study notes

These are the "stop and learn the system" notes. Read in order; each
file is ~5–15 min and assumes the previous one. By the end you should
be able to read any patch in `patches/{5.4,6.x}-baikal/`, know which
PS4 chip it pokes at and why, and have an opinion about why 6.x is
hanging.

## Reading order

| # | File | What it covers | Why read it |
|---|------|----------------|-------------|
| 1 | [01-hardware.md](01-hardware.md) | The PS4 SoC: APU (Liverpool), southbridge family (Aeolia/Belize/Baikal), BPCIe glue, where each chip lives on the PCI bus. | Patches reference these by name constantly. Without this, the patches read like noise. |
| 2 | [02-boot-chain.md](02-boot-chain.md) | PSFree-Enhanced → ArabPixel payload → kexec → kernel → initramfs → systemd. Why "reboot" = power-off. | Explains why every test costs a jailbreak chain, and why kexec-from-Linux is a big deal. |
| 3 | [03-patches-5.4.md](03-patches-5.4.md) | Walkthrough of the 13-patch 5.4 set, group by group. This is the working baseline. | The 5.4 patches are the "what does the kernel need to know about PS4" answer. |
| 4 | [04-patches-6.x.md](04-patches-6.x.md) | Status of each 5.4 patch in the 6.x port: ported as-is, modified, deferred, or missing. Where the API changed. | Tells you what's most likely to be wrong with our 6.x build. |
| 5 | [05-uart.md](05-uart.md) | How UART debugging works on PS4: BPCIe BAR2, MMIO32+regshift=2, earlycon, ttySN. Why UART is silent post-kexec. Why `ttyS4` transmit is broken. | If you're going to debug 6.x further, UART is your only window. Know it. |
| 6 | [06-iteration-loop.md](06-iteration-loop.md) | The dev tools: `test-kernel.sh`, `mark-good.sh`, `rollback-kernel.sh`, `kexec-test.sh`, `wait-for-ssh.sh`. The cost model of each (jailbreak chains spent on failure). | Use the right tool for each test. Pick the cheapest one that gives you the answer you need. |
| 7 | [07-failure-analysis.md](07-failure-analysis.md) | What we know about the 6.x hang. Hypotheses ranked by probability. Diagnostic experiments ranked by cost. | This is where to start work next session. |

## Reference material outside this directory

- [`checkpoint/docs/PLAN.md`](../PLAN.md) — current global plan and the next-session priority list.
- [`checkpoint/docs/LEARNINGS.md`](../LEARNINGS.md) — chronological diagnosis history (what we tried, what didn't work).
- [`BUILD_LOG.md`](../../../BUILD_LOG.md) — chronological build attempts.
- [`patches/5.4-baikal/series`](../../../patches/5.4-baikal/series) and [`patches/6.x-baikal/series`](../../../patches/6.x-baikal/series) — apply order with comments explaining each group.
- [`checkpoint/docs/uart-boot-capture-ttyS0E000.log`](../uart-boot-capture-ttyS0E000.log) — a real UART boot capture, ~135 lines from earlycon to fbcon takeover.
- [`CLAUDE.md`](../../../CLAUDE.md) — project hard rules (never auto-reboot; USB naming convention; settled design choices).

## How these notes were assembled

Written 2026-05-07 after the user asked to step back from the iteration loop
and study the system end-to-end. Synthesised from:

- The patch series themselves (every `.patch` under `patches/5.4-baikal/`
  and `patches/6.x-baikal/`).
- The two configs (`config/5.4-baikal.config`, `config/6.x-baikal.config`).
- `BUILD_LOG.md`, `checkpoint/docs/PLAN.md`, `checkpoint/docs/LEARNINGS.md`.
- Live PS4 inspection over SSH (cmdline, dmesg, /proc/tty/driver/serial,
  rootfs layout).
- The dev scripts in `scripts/dev/`.

Where notes contradict reality, trust reality and update the notes.
Memory and docs go stale fast; PCI IDs and patch line numbers do not.
