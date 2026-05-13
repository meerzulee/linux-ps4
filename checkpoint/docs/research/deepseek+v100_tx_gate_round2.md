# deepseek+v100_tx_gate_round2.md — 2026-05-13

## TX arbiter dead end (confirmed).  Bit 18 flood is a red herring for TX.

BAR+0x0a00 reads 0x0, rejects writes → not the gate.  The 3.6M bit-18
histogram entries are from BAR+0x50 readl picking up bit 18 as pending
DURING other IRQs (RX_AVAIL bit 6 etc).  Bit 18 IS masked in BAR+0x54
(0x7bbffe has bit 18=0) → it cannot generate IRQs alone.  The ISR only
sees bit 18 because readl returns all pending bits regardless of mask.
This is noise, not a TX blocker.

## Orbis bit-18 handler (for reference if ever needed)

From `mts_intr` (`0xffffffffc85edcf0`):
```
if ((~mask & irq_status) == 0x40000 && softc->mac_enable == 1) {
    softc->mac_enable = 0;
    writel(0, BAR + 0x204);         // disable master IRQ block
    writel(saved_mask, BAR + 0x54); // restore saved per-IRQ mask
}
```
Permanently disables the MAC on first pure-bit-18 interrupt.  Orbis
depends on gbe:ctrl thread to re-enable later.  We never hit this
because bit 18 is already masked — our `softc->mac_enable` equivalent
never toggles.  Replicating this would DISABLE the MAC (destructive).

## Live test ideas (no kernel rebuild)

**1. Pulse BAR+0x200 (master reset) after ring init:**
```bash
sudo python3 -c "
import mmap,os,struct,time
f=os.open('/sys/bus/pci/devices/0000:00:14.1/resource0',os.O_RDWR)
b=mmap.mmap(f,4096)
# Read current link state
l=struct.unpack('<I',b[0x04:0x08])[0]
print(f'linkreg=0x{l:08x}')
# Write 0 to master reset (clear), then re-enable engines
b[0x200:0x204]=struct.pack('<I',0)
time.sleep(0.01)
# Re-write BAR+0x3c/0x44 with TX ring base
b[0x3c:0x40]=b[0x3c:0x40]  # re-poke
b[0x44:0x48]=b[0x3c:0x40]  # paired
b[0x34:0x38]=struct.pack('<I',0x1)  # TX engine bit0 only
time.sleep(0.01)
b[0x34:0x38]=struct.pack('<I',0x5)  # bit0+bit2
print('Master reset + TX re-init. Ping now.')
b.close()
"
```
**Risk: may kill link** (requires re-open/re-AN).  Worth testing once.

**2. Read BAR+0x064, clear bits 1+2, restore after 10ms:**
```bash
sudo python3 -c "
import mmap,os,struct,time
f=os.open('/sys/bus/pci/devices/0000:00:14.1/resource0',os.O_RDWR)
b=mmap.mmap(f,4096)
v=struct.unpack('<I',b[0x64:0x68])[0]
print(f'BAR+0x64=0x{v:08x}')
b[0x64:0x68]=struct.pack('<I',v&~6)  # clear bits 1,2
time.sleep(0.01)
b[0x64:0x68]=struct.pack('<I',v)     # restore
print('Pulsed BAR+0x64 bits 1+2. Test ping.')
b.close()
"
```
BAR+0x064=6 (bits 1+2) — parent prelude PCIe timing reg.  Pulse might
reset TX-side clock gating if stuck.  Low risk.

## Status ring DMA still the strongest theory

Requiring kernel rebuild to alloc stat_dma buffer.  Worth doing as v100
proper — it's 6 lines in probe + 5 in ndo_open.  If TX wakes up with
valid status ring addresses, the theory is proven.

--- deepseek-v41, 2026-05-13
