# hermes / gpt-5.5 — 2026-05-13

Concrete answer: yes, the parent-BAR `0xf04: 1 -> 2` retry can be live-tested without a rebuild, but only as a bounded, readback-logged poke against PCI function `0000:00:14.0` BAR0, not the ethernet child `0000:00:14.1` BAR0. It is not risk-free: it may transiently reset the MT7531/switch-side glue and drop ethernet, but based on Orbis `FUN_ffffffffc85131d0` it is not a host reset / power-off sequence.

## Q1 — parent device, BAR, and safe live sequence

Parent/aggregate device from our UART PCI enumeration:

- `0000:00:14.0` = `[104d:90d7]`, class `0x088000`
- BAR0 = `mem 0xfdf8000000-0xfdf9ffffff` (32 MiB)
- BAR2 = `io 0x1000-0x13ff`
- ethernet child is `0000:00:14.1` = `[104d:90d8]`, BAR0 `0xc2000000-0xc2000fff`

Citations: repeated in UART logs, e.g. `checkpoint/uart-logs/2026-05-13_1925-v104-empty-rings.log:533-536` and `2026-05-12_2008-v77b-mts-kexec.log:260-263`.

Confirm live on the PS4 before touching anything:

```sh
lspci -s 00:14.0 -vv
lspci -s 00:14.1 -vv
printf 'parent resource0: '; sed -n '1p' /sys/bus/pci/devices/0000:00:14.0/resource
printf 'child  resource0: '; sed -n '1p' /sys/bus/pci/devices/0000:00:14.1/resource
```

Use a tiny `/tmp/parent_f04_retry.py` style mmap script against `/sys/bus/pci/devices/0000:00:14.0/resource0`. Map one page, read/log `0xf04`, `0xf10`, `0x120`, `0x11c`, and child status `00:14.1/resource0` offsets `0x004`, `0x06c`, `0x050`, `0x1c8` before and after.

Safe sequence I would run:

```text
1. ip link set enp0s20f1 down        # stop TX/RX engine if netdev exists
2. read parent 0xf04/0xf10/0x120/0x11c and child 0x004/0x06c/0x050/0x1c8
3. parent BAR0+0xf10 = 1
4. parent BAR0+0xf10 = 2
5. parent BAR0+0xf04 = 1
6. sleep 12 ms                       # Orbis uses udelay(12000)
7. parent BAR0+0xf04 = 2
8. sleep 500 ms                      # our existing replay used the recovery delay
9. read the same parent+child registers
10. optional: ip link set enp0s20f1 up, wait 1-2 s, read child 0x004/0x06c again
```

Do not loop indefinitely. Do at most 3 retries, each followed by 500 ms recovery and a child status read. Stop immediately if the parent BAR readbacks turn into all-ones/all-zeroes or if unrelated PCI devices start logging AER/MMIO errors. Do not write the rest of the parent prelude live (`0x60/64/68/6c/120/11c/158`) unless `0xf04` alone produces a promising change, because those offsets overlap broader Baikal/BPCIe glue and are higher blast-radius on the parent BAR than on child BAR.

Why this is grounded: Orbis helper `FUN_ffffffffc85131d0(param_1, 1)` writes `0xf10=1`, `0xf10=2`, `0xf04=1`, waits 12 ms, then `0xf04=2` before child MAC init. See local decompile `/tmp/v90_FUN_ffffffffc85131d0_5131d0.c:23-54`. Our standalone driver copied this shape at `src/6.x-baikal/drivers/net/ethernet/sony/ps4_mts.c:443-449`, but against the child mapping; this test answers whether the missing target is really the 14.0 parent mapping.

## Q2 — if parent `0xf04` still does not latch bit 0

Final remaining diagnostic write before shipping RX-only: set the Orbis DA/filter accept bits on the child MAC and the skipped frame-config word, then check whether the hardware link latch changes:

```text
child BAR+0x1c8: old -> old | 0xc0000000
child BAR+0x030: 0x00010100
read child BAR+0x004 and BAR+0x06c
```

Reason: GLM's already-falsified bit-6 idea was a no-op because child `0x1c8` was `0x00a00000`; however the Orbis `mts_mac_init` path can also leave `0x1c8` as `0xc0a00000` after its DA filter path, setting bits 30+31. Those high bits are still untested live. If they do not make `BAR+0x04[0]` or `BAR+0x06c[9]` move, I would stop chasing TX and ship RX-only.

## Q3 — parent state beyond `0xf04` that distinguishes Orbis

The one parent offset we likely never tested on the actual parent BAR is `BAR+0xf10`. In Orbis it is not optional decoration: `FUN_ffffffffc85131d0` pulses `0xf10 1 -> 2` immediately before the `0xf04 1 -> 2` reset. If `0xf10` selects/arms the downstream L2-switch reset domain, doing only `0xf04` on either the child BAR or an unarmed parent domain could be a no-op.

So the parent-state delta is:

```text
Orbis post-init on parent: 0xf10 has seen 1->2, then 0xf04 has seen 1->2 with 12 ms spacing.
Our post-init: child BAR has seen copied prelude; parent BAR likely has not seen 0xf10/0xf04 at all.
```

A secondary parent-state delta is `0x120=1` plus `0x11c &= 0xf8ff` after the reset in the same Orbis helper, but I would not live-poke those on parent until the safer `0xf10/0xf04` pulse is falsified. The single offset I would name as “never wrote on the parent” is `parent BAR+0xf10`; the smallest real Orbis retry must include both `0xf10` and `0xf04`.

Recommended next experiment on hardware: run one live parent-BAR retry consisting only of `00:14.0 BAR0+0xf10 1->2`, then `00:14.0 BAR0+0xf04 1`, 12 ms, `0xf04 2`, 500 ms, while logging child `0x004/0x06c`; if no latch, do the final child `0x1c8|=0xc0000000` + `0x030=0x10100` diagnostic and then ship RX-only.
