# Bootargs reference

Canonical kernel command-line strings for each scenario, as plain text
files. Used by `scripts/dev/update-bootargs.sh` to install onto the PS4
USB.

## Files

| File | When to use |
|---|---|
| [`5.4-normal.txt`](5.4-normal.txt) | Normal boot of our 5.4-baikal kernel. UART via earlycon at 0xC890E000, then handed off to fbcon. `console=ttyS0` is included because BPCIe UART driver registers ttyS0 successfully on 5.4. |
| [`6.x-diagnostic.txt`](6.x-diagnostic.txt) | The current 6.x-baikal target. Uses `keep_bootcon` to keep MMIO UART alive past tty0 takeover, drops `console=ttyS0` (phantom on 6.x), zeroes `8250.nr_uarts` to skip phantom slot allocation, adds `initcall_debug` for cause-of-hang isolation. **This is what got us to `/init` on 2026-05-08.** |
| [`6.x-bypass-systemd.txt`](6.x-bypass-systemd.txt) | Same as `6.x-diagnostic.txt` plus `init=/bin/sh` — drops into a busybox shell instead of running systemd. Use when you want to find which userspace service hangs the boot. |
| [`6.x-nomsi.txt`](6.x-nomsi.txt) | `6.x-diagnostic` + `pci=nomsi`. Forces legacy line-based IRQ instead of MSI for every PCI device. Use to confirm whether xHCI Command Aborted is caused by the bpcie MSI domain bypass (Linux 6.2 rework). If USB enumeration succeeds with this, MSI path is conclusively the whole issue. Slower than MSI in production but a clean diagnostic step. |

## Why a separate directory

Until now bootargs were embedded in shell scripts (`scripts/bootargs-debug-shell.sh`, `scripts/bootargs-with-keep-bootcon.sh`, etc.) — fine for one-shot use but invisible from a code-search perspective. Pulling them out as plain files makes the cmdline strings:

- diff-able (we can see exactly what changed between profiles)
- copy-pasteable into `bootargs.txt` on USB without quoting issues
- linkable from PLAN.md / LEARNINGS.md / breakthrough notes
- versionable independently of the scripts that install them

## Updating

To install one of these onto the PS4 USB, plug it into your host and run:

```sh
sudo bash scripts/dev/update-bootargs.sh                    # default: 6.x-diagnostic
sudo bash scripts/dev/update-bootargs.sh 5.4-normal
sudo bash scripts/dev/update-bootargs.sh 6.x-bypass-systemd
```

The script saves the previous `bootargs.txt` as `bootargs.txt.prev`
before writing the new one, so a one-shot rollback is just:

```sh
sudo bash scripts/dev/update-bootargs.sh --revert
```

## Background

See `checkpoint/docs/LEARNINGS.md` "bootargs cheat sheet" for the
*why* behind every flag. Especially:

- `console=ttyS0,...` is poisonous on 6.x (phantom legacy 8250 at I/O `0x3F8`).
- `keep_bootcon` is bad on 5.4 (crashes xhci_aeolia at 57 s) but **fine and necessary on 6.x**.
- `8250.nr_uarts=0` skips phantom slot allocation entirely.
- `earlyprintk=...` is permanently poisonous on PS4. Don't use.
- `panic=15` would auto-reboot before we could read the death message; always `panic=0` during debug.
