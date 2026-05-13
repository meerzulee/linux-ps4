# deepseek+v97_rx_dead_diagnosis.md — 2026-05-13

## Diagnosis: HW cached probe-time zero-filled descriptor ring

**Evidence:** ISR fires bit 6 (RX_AVAIL) at 0x00040040 on every ping, NAPI
finds zero completions. HW *thinks* it delivered packets but wrote them to the
stale descriptor ring from probe, not the refilled ring from ndo_open.

**Why:** Probe starts engines (BAR+0x34/0x38 |= 1, lines 1193-1200 in v93)
when rings are zero-filled. HW fetches descriptor chain: all entries OWN=0
(driver-owned) → HW enters "no free RX descriptors" state. ndo_open refills
descriptors with OWN=0 + valid buffers, rewrites BAR+0x3c/0x40/0x44/0x48, but
HW never re-fetches the ring base — its internal descriptor-fetch state
machine is stuck in "ring empty" from the probe-time scan.

## Q1 — Live userspace test

```bash
# From host with USB plugged in, mmap BAR0:
sudo python3 -c "
import mmap, os, struct
fd = os.open('/sys/bus/pci/devices/0000:00:14.1/resource0', os.O_RDWR)
bar = mmap.mmap(fd, 4096, offset=0)
# Read current PKT_ENGINE_CTRL
v = struct.unpack('<I', bar[0x09c:0x0a0])[0]
print(f'BAR+0x09c = 0x{v:08x}')
# Pulse engine reset: clear bit 6
bar[0x09c:0x0a0] = struct.pack('<I', v & ~0x40)
import time; time.sleep(0.001)
# Release reset: set bit 6
bar[0x09c:0x0a0] = struct.pack('<I', v | 0x40)
print('Packet engine reset toggled — check ping now')
bar.close()
"
```

If ping starts working after this, confirm theory and apply fix.

## Q2 — Other theories, ruled out

- **RX address alignment:** dmam_alloc_coherent returns 64-byte aligned on
  x86. Orbis uses 16-byte aligned descriptors. No issue.
- **Ring size register:** Orbis has no ring-size register — fixed 256 entries.
  No register to misprogram.
- **WRAP bit:** Correctly set on descriptor index 255 in mts_rx_alloc (line
  337-338 of v93 patch). Not the cause.
- **OWN semantics:** Verified correct — driver clears bit 31 to give to HW.
  RX refill writes `ctl_len = MTS_RX_BUF_SIZE` (OWN=0). Correct.

## Q3 — Most likely root cause and fix

Probe starts engines with zero ring → HW caches empty descriptor list →
ndo_open refills ring but HW never re-fetches. Fix: stop starting engines in
probe. Move the engine-start writes (lines 1193-1200 + 1214-1222 in ps4_mts.c)
from probe to ndo_open, AFTER ring refill. If link-up depends on engines
running (v84 finding), pre-fill ONE RX descriptor in probe just for link
detection, then do full ring init + engine restart in ndo_open.

**Minimal v97 fix (6 LOC in ndo_open, remove 8 LOC from probe):**

In ndo_open, after ring init + DMA addr writes, add engine reset pulse:
```c
/* Force HW to re-fetch descriptor ring after probe's stale zero-ring start */
writel(readl(mts->bar + MTS_PKT_ENGINE_CTRL) & ~0x40,
       mts->bar + MTS_PKT_ENGINE_CTRL);
udelay(10);
writel(readl(mts->bar + MTS_PKT_ENGINE_CTRL) | 0x40,
       mts->bar + MTS_PKT_ENGINE_CTRL);
```

Or: remove engine start from probe entirely and start ONLY in ndo_open.

--- deepseek-v41, 2026-05-13
