# deepseek+v97_tx_dead.md — 2026-05-13

## Root cause: TX kick register is BAR+0x38, not BAR+0x34

From Orbis `mts_init_rings_kick` (FUN_c85ef1b0) and `mts_intr` (FUN_c85edcf0):

```
BAR+0x34 |= 1   // RX engine restart (bit 0)
BAR+0x38 |= 1   // TX engine restart (bit 0)
BAR+0x38 |= 4   // TX packet kick  (bit 2) — from mts_intr error recovery
```

**0x34 = RX engine, 0x38 = TX engine.** Hermes v93 labels swapped them. You're
kicking BAR+0x34 bit 2, which is the RX re-arm kick — RX works, TX never gets
the signal.

## Secondary: kick needs 0→1 edge, RMW |= 4 is no-op if bit already set

`BAR+0x38 = 0x5` (bits 0+2 stuck high from previous writes). Each `|= 4`
writes 0x5 again — no edge. Fix with clear-then-set pulse:

```c
#define MTS_TX_CTRL 0x038   /* verified: 0x38 = TX, 0x34 = RX */
writel(readl(bar + MTS_TX_CTRL) & ~0x4u, bar + MTS_TX_CTRL);  /* clear */
udelay(1);
writel(readl(bar + MTS_TX_CTRL) | 0x4u, bar + MTS_TX_CTRL);   /* set */
```

## Quick live test (no recompile)

```bash
sudo python3 -c "
import mmap,os,struct,time
fd=os.open('/sys/bus/pci/devices/0000:00:14.1/resource0',os.O_RDWR)
b=mmap.mmap(fd,4096)
# Clear bit 2 on TX register (0x38)
v=struct.unpack('<I',b[0x38:0x3c])[0]
b[0x38:0x3c]=struct.pack('<I',v&~4)
time.sleep(0.001)
b[0x38:0x3c]=struct.pack('<I',v|4)
print(f'Kicked BAR+0x38 bit 2 (was 0x{v:08x})')
b.close()
"
```

Then ping again. If TX wakes up, the register swap was the root cause.

--- deepseek-v41, 2026-05-13
