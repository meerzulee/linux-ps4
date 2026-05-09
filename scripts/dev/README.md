# `scripts/dev/` — host-side dev helpers

Tools that run on your host machine (the one with the USB stick plugged in
and the PS4-uart adapter connected). They are not part of the PS4 boot
chain.

## boot-capture.sh — slice a named excerpt from the rolling UART log

`ps4-uart/ps4uart.py` keeps writing every byte received from the PS4 to one
big rolling log (`ps4-uart/logs/ps4_uart_*.log`). A multi-day session can grow
that file to ~10 MB and mix in non-printable bytes from serial reconnects,
which makes `grep` unreliable. `boot-capture.sh` solves that by recording
the byte offset at the start of a test and extracting just that slice (with
non-printables sanitized to `?`) into a clean per-test file under
`checkpoint/uart-logs/`.

### Usage

```bash
# Before power-cycling the PS4:
scripts/dev/boot-capture.sh start <name>

# ... power-cycle PS4, run the boot test, wait for boot to complete or hang ...

# After the test:
scripts/dev/boot-capture.sh stop <name>
```

`<name>` is free-form (e.g. `v7-baikallove`, `iommu-passthrough-test`).
Whitespace and slashes get replaced with `_`.

### What `stop` produces

- Saves to `checkpoint/uart-logs/YYYY-MM-DD_HHMM-<name>.log`
- Strips non-printable bytes (replaces with `?`) so `grep`/`sed` work
- Prints a quick **signal summary** (counts of interesting patterns):

```
=== quick signal summary ===
  Linux version                    1
  bpcie_create_irq_domain          16
  bpcie_init_dev_msi_info          3
  bpcie_msi_init                   34
  bpcie_msi_write_msg              80
  bpcie_handle_edge_irq            0       <-- THE money signal
  Spurious interrupt               0
  Command Aborted                  2
  Timeout waiting                  6
  ...
```

### State

Per-test state lives at `/tmp/boot-capture/<name>.start` (one line: byte
offset; second line: log path). Survives across shells but vanishes on host
reboot, which is fine for one-shot tests. `stop` removes the state file
after extracting.

### Multiple captures concurrently

Each `<name>` has its own state file, so you can have several captures armed
at once if you really need to. They all share the underlying rolling log.
Most of the time you only have one running.

### Edge cases

- If the rolling log rotates between `start` and `stop` (unusual — only
  happens on long sessions), `stop` falls back to whichever log is current.
- If `stop` is called before any new bytes have arrived, it errors out
  with "No new bytes since start. Did the boot run?" — usually means you
  forgot to power-cycle, or the PS4 didn't actually emit UART output.

## Other scripts in this directory

- `update-bootargs.sh` — install a profile from `bootargs/` into
  `bootargs.txt` on the USB. See `bootargs/README.md`.
- `test-kernel.sh`, `mark-good.sh`, `rollback-kernel.sh` — manage
  `bzImage`, `bzImage-prev`, `bzImage-stable` rotation on the USB.

(See `CLAUDE.md` at the repo root for the **never auto-reboot the PS4** rule
that applies to all of these.)
