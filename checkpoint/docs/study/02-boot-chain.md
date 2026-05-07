# 02 — How Linux gets onto a PS4

The path from "PS4 powered on" to "Linux shell over SSH" is six
distinct stages. Each one can fail in its own way, and each one
costs you time when it does. Read this once, then refer back when a
test fails — the failure mode usually tells you which stage broke.

## The six stages

```
1. Power on        → PS4 boots to Sony OrbisOS firmware (FreeBSD-derived).
2. Browser exploit → Open browser, navigate to PSFree-Enhanced.
3. Kernel exploit  → JS payload in browser pwns the Sony kernel. ~60% success.
4. Payload host    → "Payload Guest" / "GoldHEN FTP" is now listening on TCP 9020/2121.
5. Loader payload  → Send `linux-1024mb.bin` (ArabPixel v24b). Loader does kexec into bzImage.
6. Linux init      → Embedded initramfs mounts /dev/sda2, switch_root, systemd up.
```

Failure at any stage means you have to power-cycle and start over from
stage 1. **There is no rollback short of physical power cycle.**

## Stage 1 — Sony OrbisOS

Nothing for us to do. The PS4 boots its stock firmware. We're on
firmware **12.020** (also called 12.02), the last firmware Sony
shipped, frozen because we can't update without losing the exploit
chain.

## Stage 2 — Browser exploit (PSFree)

The PS4's built-in WebKit-based browser has a publicly known JIT
type-confusion bug. PSFree-Enhanced is a JS payload that uses this
bug to gain arbitrary read/write inside the WebKit process.

You navigate the PS4 browser to the PSFree page (typically self-hosted
on your LAN, or a cached page on USB). The JS runs and you see a
series of progress messages.

This stage is **deterministic** — it works essentially every time as
long as the firmware version matches. It takes 5–15 seconds.

## Stage 3 — Kernel exploit

PSFree-Enhanced then chains to a kernel-level exploit (a sandbox
escape, a UAF in some IPC path — exact bug varies by version) to
gain ring-0 read/write inside the FreeBSD kernel.

**This stage is the lottery.** Success rate is roughly 60% per
attempt. On failure, the PS4 will either:

- Show a "failed, retry" message → you can retry without rebooting.
- Hang the browser → you have to close it and restart.
- Hang the system entirely → power-cycle (back to stage 1).

This is why every kernel test costs an unpredictable amount of time.
A "lucky" run is 1–2 minutes. An "unlucky" sequence of 3–4 failed
jailbreaks can eat 15+ minutes.

## Stage 4 — Payload host

After a successful kernel exploit, PSFree leaves a TCP listener
running. There are two common variants:

- **Payload Guest** — TCP port 9020, takes a raw `.bin` file.
- **GoldHEN FTP** — TCP port 2121, file upload via FTP protocol.

We use Payload Guest. Whatever is listening, the protocol is "send
me a binary blob, I'll execute it as ring-0 code".

## Stage 5 — Loader payload (ArabPixel v24b)

`linux-1024mb.bin` is a ~284KB file that, when executed by the PS4
kernel, does the heavy lifting:

1. **Allocates 1024MB** of GPU VRAM as Linux RAM (the "1024" in the
   name; there are 1280/2048/4096 variants for higher VRAM splits).
2. **Reads bzImage, initramfs, bootargs from USB**. It checks (in
   priority order): `/mnt/usb0/`, `/mnt/usb1/`, `/data/linux/boot/`,
   `/user/system/boot/`. First match wins.
3. **Patches Sony firmware quirks** — disables IOMMU on Baikal,
   patches PCI config space to expose hidden devices, etc.
4. **kexec into bzImage**. From here, control transfers to Linux.

Why "v24b" specifically: earlier per-firmware payloads
(`payload-1200-2gb-baikal.bin` and friends) triple-fault every kexec
on Baikal because they didn't disable IOMMU correctly. v24b (rmuxnet's
unified rewrite) auto-detects southbridge family at runtime and
applies the right patches. Use v24b unless you have a specific
reason not to.

USB layout we settled on (`/mnt/usb0/`):

```
/mnt/usb0/
├── linux-1024mb.bin     # the payload itself
├── bzImage              # active boot kernel (touched by test-kernel.sh)
├── bzImage-stable       # last-known-good fallback (set by mark-good.sh)
├── bzImage-prev         # previous active (auto-saved by test-kernel.sh)
├── bzImage-5.4-feeRnt   # specific named backup
├── initramfs.cpio.gz    # better-initramfs External HDD variant
├── bootargs.txt         # kernel cmdline
└── vram.txt             # VRAM size override (optional)
```

`bootargs.txt` content:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 console=tty0 console=ttyS0,115200n8 8250.nr_uarts=8 panic=0 loglevel=8 ignore_loglevel printk.devkmsg=on
```

(See [05-uart.md](05-uart.md) for the breakdown of each arg.)

## Stage 6 — Linux init

The kernel decompresses, runs early init, finds the embedded
initramfs (the v24b payload concatenated `initramfs.cpio.gz` to the
kernel image at load time, so from the kernel's perspective it
appears as an `initrd` it was given). The initramfs:

1. Mounts `/proc`, `/sys`, `/dev`.
2. Probes USB and SATA. Waits for `/dev/disk/by-label/psxitarch` to
   appear (10s timeout — that's the better-initramfs default).
3. Mounts that as `/mnt/root` (it's `/dev/sda2`, ext4).
4. `switch_root /mnt/root /sbin/init`.

`/sbin/init` is systemd. From here it's a normal Arch userspace,
except the rootfs binaries are v2-baseline (not v3) — that's
deeWaardt's "Arch — Baikal Ed." tarball, not stock Arch.

systemd brings up:

- WiFi (`iwd` connects to a saved network → ip up on `wlp0s14`).
- SSH (`sshd` listens on 22 of the WiFi IP).
- Display manager (`sddm` → KDE on HDMI).

When SSH responds: boot succeeded. Total time from kexec to ssh-up:
~30s on a working build.

## Why "reboot" is destructive

When you `systemctl reboot` from inside Linux on PS4, what happens:

1. Linux kernel calls the standard reboot syscall.
2. Linux's reboot path on x86 ends up writing to ACPI sleep state /
   keyboard controller / triple-fault / EFI runtime, depending on
   `reboot=` cmdline.
3. **None of these get back to a Linux-bootable state.** The PS4
   firmware's secure-loader takes over and re-initializes hardware
   for OrbisOS.
4. From the user's perspective: PS4 powers off (or returns to OrbisOS
   home screen). They have to redo stages 1–5.

There's no "boot loader" in the PC sense. Linux on PS4 is loaded by a
JS payload running inside a browser exploit; it's not a thing the
firmware knows how to find on its own. Every Linux session is a
single-shot.

This is why **CLAUDE.md hard-rules `systemctl reboot`** — every
unauthorized reboot costs the user a full PSFree chain.

## Where kexec-from-Linux helps

If 5.4 is running and SSH-reachable, you can use Linux's own kexec to
load a new kernel **without going through the firmware path**:

```
sudo kexec -l /tmp/new-bzImage --initrd=/tmp/initramfs --command-line="..."
sudo systemctl kexec    # or: sudo kexec -e
```

Linux tears down its own state and jumps to the new kernel. You stay
inside Linux-land — no FreeBSD, no firmware, no PSFree.

**If the new kernel boots**, you keep your jailbreak chain intact and
can iterate again. **If it doesn't**, you're dead like any other
failed boot — power-cycle, full chain.

`scripts/dev/kexec-test.sh` automates this. See [06-iteration-loop.md](06-iteration-loop.md).

## Summary cost model

| Outcome | Stages re-spent |
|---|---|
| Linux up, ssh works, but I want to test a new kernel via test-kernel.sh + reboot | 1–5 (full chain, plus stage 3 lottery) |
| Linux up, kexec-test new kernel, it boots | 0 (stayed inside Linux) |
| Linux up, kexec-test new kernel, it hangs | 1–5 (kexec failure means hardware reset path) |
| 5.4 boots, want WiFi/SSH | 0 (already there if 5.4 is the active kernel) |
| 6.x boots cleanly | 0 (it's a new Linux session, but no firmware roundtrip needed if kexec'd) |

**The whole point of the dev loop in `scripts/dev/`** is to maximize
the work you can do per stage-3 lottery success. That's why we
have `mark-good.sh` (so a failed test rolls back without manual USB
work), `bzImage-stable` (so the recovery path is mechanical), and
`kexec-test.sh` (so successful tests don't cost a chain at all).

Next: [03-patches-5.4.md](03-patches-5.4.md) — what's in the 5.4 patch set.
