# Linux 6.x Baikal Iteration Plan

> **For Hermes:** Use systematic-debugging first. No fixes before evidence. Never auto-reboot / power-cycle the PS4.

**Goal:** Get the Linux 6.15.4 Baikal kernel from earlycon/fbcon hang to a booted userspace with SSH, then port MT7668 WiFi.

**Architecture:** Work in one-variable hardware experiments. Use the working 5.4 kernel as the staging/control environment, kexec into 6.x for fast tests, and only persist a kernel to USB after it is proven. Capture UART + HDMI evidence on every failed chain.

**Tech stack:** Linux kernel v6.15.4, PS4 Baikal southbridge, crashniels/feeRnt PS4 patch stack, `build.sh`, `kexec-test.sh`, UART earlycon, HDMI fbcon, SSH to known-good 5.4.

---

## Hard rules

1. Do not run `reboot`, `shutdown -r`, `systemctl reboot`, or anything equivalent on the PS4 unless the user explicitly says to do it now.
2. Prefer `scripts/dev/kexec-test.sh` for experimental 6.x tests. It does not modify USB FAT32.
3. Use `scripts/dev/test-kernel.sh` only after a kernel has proven itself via kexec and we want to persist it on USB.
4. Every failed kexec costs one recovery chain. Before firing kexec, make sure the test answers exactly one question.
5. Do not use `keep_bootcon` on Baikal. It is known-bad.
6. Do not use `earlyprintk=serial,ttyS0,...`. It targets nonexistent legacy I/O 0x3F8.
7. Stable debug cmdline base:
   `earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on`

---

## Current known state

- 5.4 baseline works: KDE, WiFi, SSH.
- 6.x builds cleanly but hangs before SSH.
- 6.x earlycon works until fbcon/console takeover area, then UART goes silent as expected.
- Previous `init=/bin/sh modprobe.blacklist=radeon,amdgpu nofb` test was only partly useful:
  - It proved userspace is not the main issue.
  - It did not actually disable amdgpu because `CONFIG_DRM_AMDGPU=y` is built in.
- `CONFIG_DRM_RADEON` is not set in `config/6.x-baikal.config`.
- `CONFIG_DRM_AMDGPU=y`, `CONFIG_DRM_AMDGPU_CIK=y`.
- `CONFIG_AMD_IOMMU=y`, `CONFIG_PCI_MSI=y`.
- MT7668 WiFi is not present in any 6.x reference tree; treat it as phase 2 work.

---

## Session setup checklist

Run from host:

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
```

Verify repo state before editing:

```sh
git status --short --branch
```

Verify 6.x image exists or build it:

```sh
./build.sh -t 6.x-baikal
```

Expected output artifact:

```sh
ls -lh output/6.x-baikal/bzImage
```

Verify known-good 5.4 PS4 is SSH-reachable before any kexec test:

```sh
ssh -o ConnectTimeout=5 ps4 'uname -a; cat /proc/cmdline'
```

Expected:
- SSH succeeds.
- Kernel is 5.4.x known-good, not a half-booted 6.x.

Start UART capture in a second terminal before any kexec:

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
bash scripts/dev/experiments/07-uart-capture.sh
```

---

## Phase 0 — capture a 5.4 reference dataset

**Objective:** Save a control dataset from the working 5.4 environment so each 6.x failure has something concrete to compare against.

**Files:**
- Create later if needed: `scripts/dev/experiments/00-snapshot-5.4-reference.sh`
- Reference proposal: `scripts/dev/experiments/PROPOSAL-all-in-one-harness.md`

**Manual minimum commands for now:**

```sh
TS=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p logs/ps4-diag/$TS
ssh ps4 'uname -a' > logs/ps4-diag/$TS/uname.txt
ssh ps4 'cat /proc/cmdline' > logs/ps4-diag/$TS/cmdline.txt
ssh ps4 'dmesg' > logs/ps4-diag/$TS/dmesg.txt
ssh ps4 'cat /proc/interrupts' > logs/ps4-diag/$TS/interrupts.txt
ssh ps4 'cat /proc/iomem' > logs/ps4-diag/$TS/iomem.txt
ssh ps4 'cat /proc/tty/driver/serial' > logs/ps4-diag/$TS/tty-serial.txt
ssh ps4 'lspci -nn' > logs/ps4-diag/$TS/lspci-nn.txt
ssh ps4 'lspci -tv' > logs/ps4-diag/$TS/lspci-tree.txt
ssh ps4 'sudo lspci -vvxxx' > logs/ps4-diag/$TS/lspci-vvxxx.txt
```

**Verification:**

```sh
find logs/ps4-diag/$TS -type f -size +0 -print
```

Expected: all files exist and are non-empty.

**Commit suggestion:**
Do not commit raw logs unless they are small and useful. If large, keep under `logs/` untracked.

---

## Phase 1 — identify the exact 6.x hang point

### Task 1: Run initcall_debug kexec

**Objective:** Get the final visible initcall from HDMI when 6.x hangs.

**Files:**
- Use: `scripts/dev/experiments/01-initcall-debug.sh`
- Writes no source files.

**Command:**

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
bash scripts/dev/experiments/01-initcall-debug.sh
```

**When it hangs:**
1. Do not power-cycle immediately.
2. Photograph HDMI, especially bottom 10 lines.
3. Save the UART capture file.
4. Record the last visible `initcall: <function>` line.
5. Then recover manually.

**Result format to append to `checkpoint/docs/study/07-failure-analysis.md`:**

```md
### YYYY-MM-DD — initcall_debug kexec
- Kernel: output/6.x-baikal/bzImage, sha256: <fill>
- Cmdline extras: initcall_debug ignore_loglevel debug printk.devkmsg=on
- UART: <path to capture>
- HDMI last line/photo: <describe or path>
- Outcome: hung / booted / panic
- What this tells us: <subsystem named by final initcall>
```

**Decision:**
- If the last initcall points to IOMMU/MSI/IRQ/xHCI/AHCI/sky2, go to Phase 2A.
- If it points to GPU/amdgpu/DRM/fbcon, go to Phase 2B.
- If the photo is unreadable or no new data appears, go to Phase 2C.

---

## Phase 2A — test MSI/IOMMU hypothesis

### Task 2A.1: Boot with IOMMU and interrupt remapping disabled

**Objective:** Determine whether the 6.x hang is caused by AMD IOMMU / interrupt remapping / MSI domain wiring.

**Files:**
- Use: `scripts/dev/experiments/04-iommu-off.sh`
- Inspect if confirmed: `patches/6.x-baikal/1000-iommu/0001-amd-iommu-ps4-init.patch`
- Inspect if confirmed: `patches/6.x-baikal/1100-pci-msi/0001-pci-msi-irqdomain-ps4-quirks.patch`

**Command:**

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
bash scripts/dev/experiments/04-iommu-off.sh
```

**Expected outcomes:**
- Boots to SSH: MSI/IOMMU path is confirmed as root cause. Focus on 1000/1100 patches.
- Hangs later/differently: still useful; compare last initcall and logs.
- Same hang: rank MSI/IOMMU down and go to Phase 2B/2C.

### Task 2A.2: If confirmed, inspect the 6.x MSI selector

**Objective:** Check whether `x86_fwspec_is_aeolia()` is too narrow for Baikal.

**Files:**
- `patches/6.x-baikal/1100-pci-msi/0001-pci-msi-irqdomain-ps4-quirks.patch`
- `src/6.x-baikal/arch/x86/kernel/apic/vector.c` after patches are applied
- `src/6.x-baikal/drivers/ps4/ps4-bpcie.c`

**Key code to inspect:**

```c
int x86_fwspec_is_aeolia(struct irq_fwspec *fwspec)
{
    if (is_fwnode_irqchip(fwspec->fwnode)) {
        const char *fwname = fwnode_get_name(fwspec->fwnode);
        return fwname && !strncmp(fwname, "Aeolia-MSI", 10);
    }
    return 0;
}
```

**Question:**
Does Baikal create an IRQ fwnode named `Aeolia-MSI`, or does it need a Baikal-aware predicate?

**Minimal diagnostic patch idea, not to apply until Phase 2A.1 gives evidence:**
Add `pr_info()` around fwnode name selection and MSI write path, rebuild, and kexec once.

---

## Phase 2B — test built-in amdgpu hypothesis

### Task 2B.1: Try runtime modeset disable first

**Objective:** Disable built-in amdgpu modesetting without a rebuild.

**Command:**

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
bash scripts/dev/kexec-test.sh output/6.x-baikal/bzImage \
  --initrd checkpoint/boot/initramfs.cpio.gz \
  --cmdline "amdgpu.modeset=0 video=efifb:off initcall_debug ignore_loglevel debug"
```

**Expected outcomes:**
- Boots or reaches a different hang: GPU handoff is involved.
- Same hang: GPU is less likely.

### Task 2B.2: Build a no-DRM diagnostic kernel

**Objective:** Remove built-in DRM/amdgpu completely for one diagnostic build.

**Files:**
- Modify temporarily: `config/6.x-baikal.config`
- Do not commit until result is known.

**Temporary config changes:**

```text
# CONFIG_DRM is not set
# CONFIG_DRM_AMDGPU is not set
# CONFIG_DRM_AMDGPU_CIK is not set
# CONFIG_DRM_RADEON is not set
# CONFIG_HSA_AMD is not set
```

**Build:**

```sh
cp config/6.x-baikal.config /tmp/6.x-baikal.config.before-nodrm
./build.sh -t 6.x-baikal
```

**Test:**

```sh
bash scripts/dev/kexec-test.sh output/6.x-baikal/bzImage \
  --initrd checkpoint/boot/initramfs.cpio.gz \
  --cmdline "initcall_debug ignore_loglevel debug"
```

**Restore if not keeping:**

```sh
cp /tmp/6.x-baikal.config.before-nodrm config/6.x-baikal.config
./build.sh -t 6.x-baikal
```

---

## Phase 2C — prove whether patch slicing is the bug

### Task 2C.1: Build crashniels tree as-is

**Objective:** Determine whether the patch-sliced tree differs behaviorally from crashniels' original 6.15 Baikal tree.

**Files:**
- Use: `tmp/crashniels-6.15/`
- Use script: `scripts/dev/experiments/02-build-crashniels-vanilla.sh`

**Command:**

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
bash scripts/dev/experiments/02-build-crashniels-vanilla.sh
```

**Then kexec the produced bzImage according to the script output.**

**Expected outcomes:**
- crashniels boots: our patch extraction/slicing introduced a regression.
- crashniels hangs the same: issue is inherited from the reference tree or hardware/toolchain/payload differences.
- crashniels hangs differently: compare diffs and config.

### Task 2C.2: If patch slicing is suspect, compare trees

**Objective:** Find files where `src/6.x-baikal` after patches differs from `tmp/crashniels-6.15`.

**Command:**

```sh
./build.sh -t 6.x-baikal --patches-only
rsync -a --delete \
  --exclude .git \
  tmp/crashniels-6.15/ /tmp/crashniels-tree/
rsync -a --delete \
  --exclude .git \
  src/6.x-baikal/ /tmp/ours-tree/
diff -ruN /tmp/crashniels-tree /tmp/ours-tree > /tmp/crashniels-vs-ours.diff || true
wc -l /tmp/crashniels-vs-ours.diff
```

**Expected:**
Only intentional local fixes/config/generated files should differ. Any source-code hunk in PS4, IRQ, IOMMU, xHCI, AHCI, or GPU paths is suspicious.

---

## Phase 3 — only after 6.x reaches SSH

### Task 3.1: Persist known-good 6.x kernel to USB

**Objective:** Make a kexec-proven 6.x kernel the normal boot image, with rollback intact.

**Command:**

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
bash scripts/dev/test-kernel.sh output/6.x-baikal/bzImage 6x-first-ssh
```

**Important:** This stages USB and stops. The user manually power-cycles and relaunches PSFree.

**After successful boot:**

```sh
bash scripts/dev/wait-for-ssh.sh
bash scripts/dev/mark-good.sh
```

---

## Phase 4 — MT7668 WiFi forward-port

Start only after 6.x boots to userspace.

**Objective:** Bring onboard Baikal MT7668 WiFi to Linux 6.x.

**Primary reference:**
- `checkpoint/docs/study/08-mt7668-port-todo.md`

**Source tree:**
- `tmp/feeRnt-5.4.247-baikal/drivers/net/wireless/mediatek/mt76x8/`

**Destination patch group:**
- `patches/6.x-baikal/0600-wifi-mt7668/`

**Initial approach:**
1. Copy vendor tree into `src/6.x-baikal/drivers/net/wireless/mediatek/mt76x8/`.
2. Wire Kconfig/Makefile.
3. Enable built-in config.
4. Build, fix compile errors one API family at a time.
5. Generate a patch only after compile-clean.

**Do not start this before 6.x can boot without WiFi.** Otherwise we cannot tell whether failures are base-kernel or WiFi-driver regressions.

---

## Evidence log template

Append this to `checkpoint/docs/study/07-failure-analysis.md` after every hardware test:

```md
### YYYY-MM-DD — <experiment name>
- Host commit: `<git rev-parse --short HEAD>`
- Dirty state: `<git status --short>`
- Kernel image: `<path>`
- SHA256: `<sha256sum path>`
- Build compiler: `<gcc --version first line>`
- Cmdline extras: `<exact extra args>`
- Initrd: `<path or none>`
- UART capture: `<path>`
- HDMI photo/result: `<path or description>`
- Outcome: booted SSH / hung / panic / triple-fault
- Last visible line: `<exact line>`
- Interpretation: `<what this proves or disproves>`
- Next action: `<one next experiment>`
```

---

## Recommended immediate next run

Use the boomerang initramfs first. If Linux 6 reaches `/init`, it will save logs and kexec back to known-good 5.4, avoiding another jailbreak chain.

Build/verify the boomerang initramfs:

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
sudo bash scripts/dev/build-boomerang-initramfs.sh
```

Run it from a 5.4 SSH baseline:

```sh
cd /home/meerzulee/Work/ps4/linux-ps4
bash scripts/dev/kexec-boomerang-6x.sh
```

Expected outcomes:
- SSH disappears, then returns to 5.4: Linux 6 reached initramfs and bounced back. Fetch `/var/log/ps4-boomerang/` from the PS4 rootfs.
- SSH never returns: Linux 6 died before or inside initramfs. Manual recovery is still required.

If boomerang cannot reach `/init`, fall back to HDMI/UART experiments:

```sh
bash scripts/dev/experiments/07-uart-capture.sh
# in another terminal:
bash scripts/dev/experiments/01-initcall-debug.sh
```

Do not spend the second chain until the boomerang/HDMI/UART result from the first chain is written down.
