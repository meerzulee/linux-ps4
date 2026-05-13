# deepseek+v99_tx_gate.md — 2026-05-13

## Primary theory: status ring must have valid DMA addresses for TX completion

v91 enabled the Yukon-2 status unit (BAR+0xe80 = STAT_OP_ON) but never
programmed STAT_LIST_ADDR_LO/HI (BAR+0xe88/0xe8c). The status unit is "on"
with no DMA buffer → TX completions can't be written to memory → TX engine
either never starts (hardware interlock) or runs but silently drops
completions. RX may bypass this path entirely (Baikal RX goes via descriptor
OWN bits + direct IRQ, not through the status ring). Evidence:

- BAR+0x03c stationary (HW never reads TX ring base)
- All TX descriptors pristine after 47 xmits (OWN never set by HW)
- BAR+0x040 (RX cursor) advances 0x10/RX-pkt → RX engine uses descriptor-path
  completion, not status ring
- v90/v90b proved full msk_init_hw replay destructive (BAR+0x014/0x00c/0x0f04
  clobbered MAC state) — but v90 status ring DMA might have been correct

## Minimal safe status ring DMA (avoid v90 destructive writes)

Allocate 2KB DMA buffer, program ONLY the four non-destructive registers
that msk_init_hw writes for the status ring:

```c
#define MTS_STAT_LAST_IDX 0xe84
#define MTS_STAT_ADDR_LO  0xe88
#define MTS_STAT_ADDR_HI  0xe8c
#define MTS_STAT_CTRL     0xe80

/* Allocate tiny status ring (64 entries × 4 bytes = 256 bytes, padded) */
void *stat_virt = dmam_alloc_coherent(dev, 256, &stat_dma, GFP_KERNEL);
memset(stat_virt, 0, 256);

/* Program addresses — write lo+hi with same 32-bit value (v97 pattern) */
writel(lower_32_bits(stat_dma), bar + MTS_STAT_ADDR_LO);
writel(lower_32_bits(stat_dma), bar + MTS_STAT_ADDR_HI);

/* Set last index = 63 (0-indexed, 64 entries) */
writel(63, bar + MTS_STAT_LAST_IDX);

/* Status unit already OP_ON from v91 — if not, add 1,2,8 sequence */
writel(1, bar + MTS_STAT_CTRL); udelay(10);
writel(2, bar + MTS_STAT_CTRL); udelay(10);
writel(8, bar + MTS_STAT_CTRL); mdelay(1);
```

**Risk:** Low. These four registers at offsets 0xe80-0xe8c are within the
Yukon-2 status-block range. msk_init_hw writes ~20 additional registers
in this range (0xe98/0xeac/0xead/0xed0/0xec0/0xec8/0xeb8/0xed8/0xe18/0xe08).
v90 hang came from BAR+0x014=0 (MAC addr clobber) and BAR+0x00c=0 (MAC_CTRL2
clobber) in msk_init_hw, NOT from the status ring registers. The status
ring block alone should be safe.

## Alternative: TX arbiter enable (Yukon-2 TXA_CTRL at BAR+0x0a00)

msk_init_hw enables TX arbitration:
```c
sky2_write8(hw, SK_REG(i, TXA_CTRL), TXA_ENA_ARB);
```
SK_REG(0, 0x0a00) = BAR+0x0a00. If Baikal inherits Yukon-2 TX arbiter
gating, TX fetches are blocked until this enable.

Live test (risk: medium — BAR+0x0a00 untested on Baikal):
```bash
# Read then set bit 0 at BAR+0x0a00 (TX arbiter enable)
sudo python3 -c "
import mmap,os,struct
fd=os.open('/sys/bus/pci/devices/0000:00:14.1/resource0',os.O_RDWR)
b=mmap.mmap(fd,4096)
v=struct.unpack('<B',b[0xa00:0xa01])[0]
print(f'BAR+0x0a00 = 0x{v:02x}')
b[0xa00]=struct.pack('B',v|1)
print(f'BAR+0x0a00 -> 0x{v|1:02x}')
b.close()
"
# Then re-kick TX engine and check descriptor OWN bit
```

## Recommend: test status ring first (7 LOC, lowest risk), then TX arbiter

--- deepseek-v41, 2026-05-13
