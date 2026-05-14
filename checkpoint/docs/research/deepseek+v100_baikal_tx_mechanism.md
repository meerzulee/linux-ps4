# deepseek+v100_baikal_tx_mechanism.md — 2026-05-13

## Yukon-2 prefetch unit does not exist on Baikal (confirmed)

v91 BAR+0xe80 OP_ON writes were no-ops.  Registers 0xe00–0xeff all dead.

## Orbis post-mts_mac_init BAR writes — mts_attach audit

`mts_attach` (`0xffffffffc85ec030`) calls `mts_mac_init`, then does ONLY
FreeBSD newbus operations (sysctl_ctx_init, bus_generic_attach, bus_setup_intr).
**No BAR writes in the 0x05c–0x300 range after mts_mac_init.**  The next BAR
writes happen in `mts_ifup` → `mts_init_rings_kick` (0x3c/0x44/0x40/0x48/0x34/0x38/0x54).

## Missing TX state-machine trigger: BAR+0x138 = 2→1

`msk_init_hw` (`0xffffffffc8511d50`) writes 2 then 1 to **BAR+0x138**:

```
out(BAR+0x138, 2);   // set bit 1?
out(BAR+0x138, 1);   // set bit 0, clear bit 1?
```

This is a paired-write state-machine trigger (same pattern as BAR+0xf04 GPIO
reset: 1→2, BAR+0xf10: 1→2, BAR+0x158: 2→1).  **We never touch 0x138.**
BAR+0x138 is outside our RE doc and not in the parent prelude we copied.

`msk_init_hw` does this write RIGHT AFTER reading the switch chip ID (PHY reg
2/3 check) — it's part of the "chip recognised, enable internals" sequence.
On Baikal this could be the **TX-engine gate enable**.

### Live test (no reboot)

```bash
sudo python3 -c "
import mmap,os,struct,time
f=os.open('/sys/bus/pci/devices/0000:00:14.1/resource0',os.O_RDWR)
b=mmap.mmap(f,4096)
v=struct.unpack('<I',b[0x138:0x13c])[0]
print(f'BAR+0x138 pre  = 0x{v:08x}')
b[0x138:0x13c]=struct.pack('<I',2)
time.sleep(0.01)
b[0x138:0x13c]=struct.pack('<I',1)
print(f'BAR+0x138 post = 0x{struct.unpack(\"<I\",b[0x138:0x13c])[0]:08x}')
b.close()
print('Done. Kick TX engine and test ping.')
"
```

## Bit 18 storm: hardware in persistent error state, NOT blocking TX

4M bit-18 counts in histogram are from BAR+0x50 readl capturing bit 18 as
pending DURING other IRQs (bit 6 RX_AVAIL etc).  Bit 18 IS masked by our
0x7bbffe mask → cannot fire IRQs alone.  W1C-ack in ISR clears it but HW
re-asserts immediately — this means the MAC's internal "secondary state"
signal is stuck active.  This is a symptom of incomplete MAC init (missing
state-machine triggers like 0x138), NOT a TX blocker itself.

Orbis handles bit-18-only by disabling the MAC (BAR+0x204=0) — destructive,
not a recovery.  Do NOT replicate.

--- deepseek-v41, 2026-05-13
