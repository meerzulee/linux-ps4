# 05 — UART debugging on PS4

UART is the **only** debug channel that survives once the kernel
takes over from the loader. HDMI works for graphical output but
isn't reliable when fbcon hasn't initialized or when the GPU driver
hangs (which is exactly when you want logs). SSH only works after
userspace boots. UART is what fills the gap.

This file explains: where the UARTs are physically, how Linux talks
to them, why the standard `console=ttyS0` doesn't work without help,
and what `earlycon` does differently.

## The hardware

The PS4 Baikal southbridge has **4× 8250-compatible UARTs** mapped
into MMIO via BAR2 of the BPCIe glue function (`00:14.4`). Per
`drivers/ps4/baikal.h`:

| Index | MMIO offset | Address (BAR2 = `0xC8800000`) | Linux ttyS\* |
|---|---|---|---|
| 0 | `0x10E000` | **`0xC890E000`** | (would be ttyS4) |
| 1 | `0x10F000` | `0xC890F000` | (would be ttyS5) |
| 2 | `0x110000` | `0xC8910000` | unused |
| 3 | `0x111000` | `0xC8911000` | unused |

The `ps4-bpcie-uart` driver registers UARTs 0 and 1 as numbered
`ttyS4` and `ttyS5` (because ttyS0–ttyS3 are reserved for legacy
8250 ports at I/O 0x3F8/0x2F8/etc., which the PS4 doesn't have but
the kernel still scaffolds slots for).

UART parameters:

```
uartclk  = 58.5 MHz
regshift = 2          ← each register is 4 bytes apart, not 1
iotype   = UPIO_MEM32 ← reads/writes are 32-bit, not 8-bit
flags    = UPF_SHARE_IRQ
baud     = 115200
```

`regshift=2` and `MMIO32` together mean that the standard 16550
register layout (DLAB, IER, IIR, LCR, MCR, LSR, MSR at offsets 0–6)
is **expanded to 32-bit slots**. So writing a byte to LCR involves
writing a 32-bit dword at MMIO offset `LCR << 2 = 12`, with the high
3 bytes typically zero. Standard 8250 driver knows about this layout
once you tell it `iotype=UPIO_MEM32` and `regshift=2`.

## Which UART is your cable on?

This is the gotcha that ate hours.

The Linux driver registers UART **1** (`0xC890F000`) as ttyS4. That's
arbitrary — UART 0 vs UART 1 is just an array index. The kernel
doesn't know which one a physical cable is wired to.

The user's UART cable is on **UART 0** (`0xC890E000`). We discovered
this empirically: wrote sentinel bytes via `/dev/mem` to both
addresses (`checkpoint/docs/uartprobe.py`); only `0xC890E000`
produced output on the cable.

So:
- **Earlycon target**: `0xC890E000` (what the cable hears).
- **Linux ttyS line that maps to that**: there isn't one in the
  default registration; the driver chose UART1. We get UART0 only
  via earlycon's raw MMIO writes.

Possible future fix: re-order the UART registration in
`drivers/ps4/ps4-bpcie-uart.c` so UART0 → ttyS4 and UART1 → ttyS5.
That would let you `cat /dev/ttyS4` and see live output. Not done
yet because the registered ttyS doesn't actually transmit anyway
(see "Why ttyS4 transmit is broken" below).

## Why `console=ttyS0` doesn't work without earlycon

This is the key trap. With cmdline `console=ttyS0,115200`:

1. Kernel registers `console=ttyS0`, expects a `ttyS0` device to
   exist. There's a phantom legacy 8250 placeholder, registered with
   `port.type = PORT_UNKNOWN`.
2. `port.type = PORT_UNKNOWN` is fatal in 8250 console code: the
   layer refuses all reads and writes. `EIO` on every operation.
3. Result: kernel printk has no working console output. **Silent
   boot.**

Even after `ps4-bpcie-uart` registers UART0/UART1 as ttyS4/ttyS5,
the same problem happens: the driver registers them with
`port.type` unset → `PORT_UNKNOWN` → 8250 layer refuses I/O.

**Fix that works on 5.4** (`patches/5.4-baikal/0200-ps4-drivers/0002-ps4-bpcie-uart-set-port-type.patch`):

```c
uart.port.flags = UPF_SHARE_IRQ | UPF_FIXED_TYPE;
uart.port.iotype = UPIO_MEM32;
uart.port.regshift = 2;
uart.port.type = PORT_16550A;     // ← key
```

`UPF_FIXED_TYPE` tells the autoconfig layer "I know what this is,
don't probe me", and `PORT_16550A` is the type. With this patch,
`/proc/tty/driver/serial` shows `uart:16550A` for both UARTs and
the registration is sane.

**Fix breaks 6.x**: same patch causes a triple-fault at kexec, before
any kernel output. The 8250 internals changed and `UPF_FIXED_TYPE`
+ MMIO32 + regshift=2 + PORT_16550A no longer compose correctly.
**Currently disabled in `patches/6.x-baikal/series`.** Investigation
needed.

## Why ttyS4 transmit is still broken even with the patch

With the patch on 5.4: registration succeeds. Reads work (you can
read characters typed into the cable). **Writes don't deliver.**
`tx_counter` in `/proc/tty/driver/serial` stays at 0 even after
1000+ bytes written to `/dev/ttyS4`.

Hypothesis: the FIFO setup or buffer pointers aren't being
initialized properly. The 8250 driver's `serial8250_tx_chars()` is
queueing bytes into the TX buffer, but the buffer isn't being
flushed to the hardware UART's TX FIFO.

Things to try (`PLAN.md` step 6):

- `port.type = PORT_8250` (simpler driver path, no FIFO).
- Drop `UPF_FIXED_TYPE`, let autoconfig run, see what it detects.
- `port.fifosize = 16` and `UART_CAP_FIFO`.
- Inspect 8250 autoconfig source and find what it writes to detect
  capabilities; replicate manually.

This is research for "phase F" once the 6.x port is alive.

## Earlycon — the workaround that actually transmits

`earlycon` is a kernel feature that bypasses the regular tty / 8250
driver layer entirely. The cmdline:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8
```

Tells the kernel: "for early printk, write directly to MMIO at
`0xC890E000` using 32-bit writes, configured for 115200 baud, 8N1."

This works because:

1. It happens **very early** in boot, before any drivers init.
2. It doesn't go through the 8250 driver's port-type checks.
3. It writes a byte by setting up DLL/DLM, then writing each
   character to the THR (transmit holding register), then polling
   LSR for "transmit empty" before the next byte. Pure 16550 dance,
   no driver state machine.

Earlycon **does transmit reliably** on the BPCIe UART. That's how
we get those ~120 lines of UART output before the hang.

### Caveat: `mmio32` byte spacing

Each character written via earlycon is a 32-bit dword. The high 3
bytes are zero-filled. So if you log raw, you see:

```
H \0 \0 \0 e \0 \0 \0 l \0 \0 \0 ...
```

`uartprobe.py` and most serial terminals strip the NULs and show
"Hello". If your tool doesn't, you'll see "weird spacing". Cosmetic.

### Earlycon retires when the regular console takes over

Once `console=tty0` registers (HDMI fbcon, ~1s into boot), the
kernel prints `bootconsole [uart8250] disabled` and stops sending
UART. If the regular UART driver were working, output would
continue there; it isn't, so output goes silent.

You can extend earlycon's life with `keep_bootcon` cmdline flag —
**but don't**:

> `keep_bootcon` causes the BPCIe glue to overload with constant
> earlycon writes, the xhci_aeolia controller (also behind 14.4)
> loses its mind at ~57s, USB rootfs disappears, ext4 errors,
> systemd cascades. **Don't use keep_bootcon on this hardware.**

So the practical UART window is ~0–1s of boot. Past that, HDMI
fbcon. After fbcon, SSH (if it gets that far).

## The full stable bootargs

Documented in `LEARNINGS.md`, `BUILD_LOG.md`, and on the USB:

```
earlycon=uart8250,mmio32,0xC890E000,115200n8 \
  console=tty0 console=ttyS0,115200n8 \
  8250.nr_uarts=8 \
  panic=0 \
  loglevel=8 ignore_loglevel printk.devkmsg=on
```

Breakdown:

| Arg | Why |
|---|---|
| `earlycon=uart8250,mmio32,0xC890E000,115200n8` | Direct MMIO writes to UART0; earliest possible UART output. |
| `console=tty0` | HDMI fbcon as primary console once it initializes. Critical for visibility during the UART silent window. |
| `console=ttyS0,115200n8` | Late-boot UART (kept in case the in-kernel driver ever transmits). Currently inert because of the broken-transmit issue. |
| `8250.nr_uarts=8` | Reserve 8 ttySN slots so PS4-registered ones (ttyS4, ttyS5) don't collide with phantoms. |
| `panic=0` | Halt on panic instead of auto-rebooting. Lets us read the death message. |
| `loglevel=8 ignore_loglevel` | Maximum verbosity — every printk line, including DEBUG. |
| `printk.devkmsg=on` | Userspace can read /dev/kmsg and write to it (useful for diagnostic injection). |

## What NOT to put in cmdline

- `earlyprintk=serial,ttyS0,115200` — **POISON**. Targets legacy
  8250 at I/O port `0x3F8`, which doesn't exist on PS4. Kernel
  hangs immediately on first early-print attempt. Always strip
  this. We had it for a long time and it masked actual bugs.
- `keep_bootcon` — overloads BPCIe bus, crashes xhci_aeolia at
  ~57s.
- `panic=15` (or anything > 0) — auto-reboot before you can read
  the panic. Use `panic=0` always for debug.

## UART silence post-kexec — different problem

Before kexec, the FreeBSD-side persistent-UART payload (Cthulhu /
Sleirsgoevy) hooks the FreeBSD UART driver and our `ps4uart.py`
sees firmware logs. The moment we kexec into Linux, those FreeBSD
hooks are gone — Linux owns the page tables and the BPCIe device.

Linux's earlycon picks up almost immediately, so the UART silence
is **brief** (microseconds, not seconds). But it's why we can't
"continuously log" through the kexec transition; expect a tiny gap.

If our earlycon doesn't kick in, the gap becomes "UART silent
forever". That's how we know the kernel triple-faulted before
parsing cmdline — silent UART past kexec means the kernel never
got far enough to enable earlycon. (The 6.x bpcie-uart triple-fault
shows exactly this signature.)

## Reference UART boot capture

`checkpoint/docs/uart-boot-capture-ttyS0E000.log` is a real ~135-line
capture of a working 5.4 boot:

- `Linux version 5.4.247-neocine-1.1...` — earlycon active.
- BIOS-e820 memory map.
- ACPI table parsing.
- CPU bring-up (8 Jaguar cores).
- Memory init.
- IRQ subsystem.
- `bootconsole [uart8250] disabled` — handover to fbcon.
- (UART silent past this point.)

If a 6.x test produces fewer than ~120 lines before silence, compare
against this capture to spot where 6.x diverged.

Next: [06-iteration-loop.md](06-iteration-loop.md) — the dev tools, when to use each.
