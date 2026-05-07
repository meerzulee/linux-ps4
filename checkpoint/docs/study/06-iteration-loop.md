# 06 — The iteration loop and dev tools

The hardest part of this project is **not** writing kernel patches —
it's testing them. Every kernel test risks burning a PSFree
jailbreak chain (~60% success, 1–15 min depending on luck), so the
dev tools in `scripts/dev/` exist to extract maximum information per
chain.

This file describes each tool, when to reach for it, and the cost
model.

## The four states the PS4 can be in

| State | What it means | What you can do |
|---|---|---|
| **Unbooted** | PS4 powered off. | Power on, jailbreak, boot Linux (full chain). |
| **Booted, SSH-up** | Linux running, ssh works on `ps4@192.168.50.125`. | Anything: kexec-test, swap kernel, mark-good. |
| **Booted, SSH-dead** | Kernel loaded but hung — SSH timeout, HDMI may show some output. | Recover via power-cycle + USB rollback. |
| **Triple-faulted** | Kernel never started — PS4 returned to firmware in ms. | Power-cycle (PS4 may already be back at OrbisOS). |

Every tool below is built around minimizing the cost of moving
between these states.

## The tools, in order of use

### 1. `scripts/dev/test-kernel.sh` — stage a new kernel for next boot

```sh
bash scripts/dev/test-kernel.sh <new-bzImage> [label]
```

What it does:

1. SSH to PS4 (must be in "Booted, SSH-up" state).
2. Mount `/dev/sda1` on PS4 at `/mnt/ps4boot`.
3. Save current `bzImage` → `bzImage-prev` (auto-rollback target).
4. Bootstrap `bzImage-stable` if missing (one-time copy of current).
5. Copy the new bzImage in as the active `bzImage`.
6. Sync, unmount, **stop**.
7. Print a message: "USB updated, ready for next boot — power-cycle
   the PS4 when you're ready."

What it does NOT do:

- **It does not reboot the PS4.** This is a hard rule (see
  `CLAUDE.md`). The user power-cycles when they're ready.
- It does not wait for the new kernel to come back.

Cost on success (kernel boots): **1 jailbreak chain** (the user
power-cycles + PSFree).
Cost on failure (kernel hangs): **1 chain to discover the failure +
1 chain to recover** (after `rollback-kernel.sh`). 2 chains total.

### 2. `scripts/dev/wait-for-ssh.sh` — confirm new kernel booted

```sh
bash scripts/dev/wait-for-ssh.sh
```

After `test-kernel.sh` and after you power-cycle and re-launch the
payload, run this to poll SSH for up to 5 minutes. Exit 0 = new
kernel is alive. Exit 1 = timeout, probably hung — go to
`rollback-kernel.sh`.

This is a **separate script** intentionally — `test-kernel.sh`
doesn't auto-reboot, so the wait phase is decoupled.

### 3. `scripts/dev/mark-good.sh` — promote current kernel to fallback

```sh
bash scripts/dev/mark-good.sh
```

Run after a new kernel has been validated (boots, ssh works, no
regressions). Copies the active `bzImage` over `bzImage-stable`.
Future failed tests roll back to this version.

The convention:

| File on USB | Role |
|---|---|
| `bzImage` | Currently active boot kernel. |
| `bzImage-stable` | Last-known-good fallback. Rollback target. Set by `mark-good.sh`. |
| `bzImage-prev` | Whatever was active before the last `test-kernel.sh` run. Auto-saved every test. |
| `bzImage-5.4-feeRnt` | Specific named backup of feeRnt's prebuilt 5.4. |
| `bzImage-5.4-ours` | Our self-built 5.4 with bpcie-uart patch. |
| `bzImage-6.x-ours` | Our self-built 6.x. |

Always `mark-good.sh` after a successful test you want as the new
floor. Otherwise a single failed test wipes your progress.

### 4. `scripts/dev/rollback-kernel.sh` — recover from a hung kernel

Run on **host** (not PS4 — PS4 is dead) with USB plugged in:

```sh
sudo bash scripts/dev/rollback-kernel.sh           # to bzImage-stable (default)
sudo bash scripts/dev/rollback-kernel.sh --to-prev # to bzImage-prev
```

What it does:

1. Mounts USB FAT32.
2. Copies `bzImage-{stable|prev}` over `bzImage`.
3. Syncs, unmounts.
4. Prints recovery instructions.

Cost: **1 chain to recover** (you replug USB into PS4, jailbreak,
boot the rolled-back kernel).

`bzImage-stable` is the safe choice if you don't trust `bzImage-prev`.
`--to-prev` is useful if you tested kernel A → it works, then tested
kernel B → it hangs, and you want to go back to kernel A (which is
in `bzImage-prev`) rather than the older `bzImage-stable`.

### 5. `scripts/dev/kexec-test.sh` — the chain-saver

```sh
bash scripts/dev/kexec-test.sh <bzImage> \
  [--cmdline "<extra args>"] \
  [--initrd <path>]
```

What it does:

1. SSH to PS4 (must be SSH-up).
2. SCP the new bzImage to `/tmp/test-bzImage`.
3. SCP the initramfs to `/tmp/test-initrd` (defaulting to
   `checkpoint/boot/initramfs.cpio.gz` is recommended).
4. Read `/proc/cmdline` from PS4, strip `BOOT_IMAGE=`, append
   `--cmdline` extras.
5. `kexec -l` the new kernel into RAM.
6. `systemctl kexec` (or `nohup kexec -e &`) — running kernel jumps
   to new kernel.
7. SSH drops. Wait up to 180s for SSH to return on the new kernel.

Cost on success: **0 chains.** This is the killer feature: you can
iterate on a new kernel as long as it doesn't hang. Each successful
kexec brings up a fresh boot of the new kernel, you SSH in, you
verify, you kexec again with another build.

Cost on failure: **1 chain to discover + 1 chain to recover = 2
chains**, same as `test-kernel.sh`. (kexec failure leaves the PS4
in an indeterminate state; assume worst-case full recovery needed.)

**Important quirk**: `init=/bin/sh` in `--cmdline` will skip systemd,
which means **no SSH will come up** even on a successful boot. You
need to read UART/HDMI to know the result. The script will time out
and report "kexec FAILED" — which is wrong; the kernel may be alive
at a shell prompt. Use `init=/bin/sh` only if you have UART monitor
and can read the screen.

### 6. `build.sh` — kernel build

```sh
./build.sh -t 6.x-baikal       # incremental build (~3 min)
./build.sh -t 6.x-baikal -c    # clean build (~8 min)
./build.sh -t 5.4-baikal       # build the 5.4 baseline
```

What it does:

1. Reads `targets/<target>.env` — base repo URL, ref, config path,
   compiler.
2. Clones the base into `src/<target>/` (or reuses).
3. Resets to the base ref, applies all patches in
   `patches/<target>/series` order.
4. Copies config from `config/<target>.config` to `src/<target>/.config`,
   runs `make olddefconfig`.
5. Builds bzImage with the configured compiler.
6. Copies output to `output/<target>/{bzImage,config,System.map,version.txt}`.

After build, `output/<target>/bzImage` is what you pass to
`test-kernel.sh` or `kexec-test.sh`.

## The decision tree

```
Want to test a kernel change.
│
├── Is PS4 currently SSH-up?
│   ├── YES → Use kexec-test.sh. (0 chains on success, 2 on failure.)
│   └── NO  → Use test-kernel.sh, then power-cycle, then wait-for-ssh.sh.
│              (1 chain on success, 2 on failure.)
│
├── Did the kernel come up?
│   ├── YES, ssh works → mark-good.sh to make it the new floor.
│   └── NO            → rollback-kernel.sh, replug USB, jailbreak again.
```

## Cost-amortized strategies

When you have one good chain to spend:

- **Single shot**: power-cycle, jailbreak, run our 5.4 (the working
  one), test ONE thing, done. Cost: 1 chain regardless of test
  outcome.
- **Multi-shot (best with kexec-test)**: power-cycle, jailbreak,
  boot known-good 5.4. Now you have an SSH session. From this
  session:
  - kexec-test variant 1 of 6.x → if it hangs, you spent the chain.
    If it boots, you can keep iterating from the new state, OR
    kexec back to known-good and try variant 2.
  - To make this useful, **`bzImage-stable` should be a known-good
    kernel**, and you should keep `kexec-test.sh` reloads pointed
    at debug builds. The 5.4 acts as a "shell host" for testing
    6.x candidates.

Realistically, the per-session chain budget is ~3–5 chains before
the user gets frustrated. So pick experiments that have a high
information yield per chain.

## Highest-yield experiments

Per-chain information:

- **`init=/bin/sh` + UART photo**: tells you if userspace is even
  started.
- **`initcall_debug` + HDMI photo**: tells you exactly which
  initcall was running when the kernel hung. **Single most
  informative experiment for the current 6.x failure.**
- **Kconfig disable of suspect drivers** (DRM_RADEON=n,
  DRM_AMDGPU=n, IOMMU off): isolates which subsystem is the cause.

Per-chain low-yield (avoid):

- "Try with this random cmdline tweak" — without a hypothesis, you
  burn chains for noise.
- Repeated re-tests of the same build hoping for different result —
  PS4 is deterministic; if it hung once, it'll hang again.

## Tools that don't exist yet but should

- **`enable-uart-late.sh`**: an in-Linux script that hot-rewires
  ttyS4 with the right port.type so post-fbcon UART starts working.
  (Currently impossible because the 8250 driver doesn't expose a
  knob to retype a registered port.)
- **`bisect-patches.sh`**: applies patches one-at-a-time and runs a
  test build for each. Each iteration costs build time only, not
  chains, but the test phase per applied set still needs a chain.
- **`crashniels-build.sh`**: builds crashniels' tree as-is, no
  slicing, as a control. If their tree boots and ours doesn't, our
  patch slicing introduced a regression.

Suggested next: write `bisect-patches.sh` since the build cost is
~3 min and identifying which patch group breaks 6.x is the highest-
information question.

Next: [07-failure-analysis.md](07-failure-analysis.md) — what we know about the 6.x hang
and which experiments to run.
