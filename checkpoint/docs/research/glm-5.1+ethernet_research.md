# Ghidra RE: gbe:ctrl and gbe:phy_ctrl kthread bodies + attach chain — glm-5.1, 2026-05-12

## Lead finding: gbe:phy_ctrl is the SMI heartbeat

The Orbis `gbe:phy_ctrl` kthread (FUN_ffffffffc85f0480, "SceGbeMtsPhyCtrl") performs periodic
SMI C22/C45 transactions on a 3-second cadence. Every iteration reads BMSR (PHY reg 1) and
decodes link/AN state. **This periodic SMI activity is what keeps the MDC clock alive.**
Without it, the SMI controller has no bus activity and enters a power-gated idle where every
read returns `0x20008000` (DONE bit set, data field = residue of WR_OP bit 0x2000).

The v80/v81 tests had sky2 as the sole driver — no equivalent periodic SMI polling thread.
That's why MDC dies ~1 min after interface-up: the only SMI transactions were sky2's link
timer (which eventually stops or gets killed by sky2's own register writes).

---

## Q1: Where are gbe:ctrl and gbe:phy_ctrl created, and what do they do?

### Creation site

Both kthreads are created in **FUN_ffffffffc85ef4b0** (the MTS network interface setup
function, called after `mts_attach` completes). The creation calls are:

```c
// At address 0xffffffffc85ef707:
FUN_ffffffffc856f870(FUN_ffffffffc85f0190, softc, 0, 0, 0, "SceGbeMtsCtrl");
// ^^^ kproc_create(gbe_ctrl_thread, softc, NULL, NULL, 0, "SceGbeMtsCtrl")

// At address 0xffffffffc85ef745:
if (softc->carrier_polling_disabled == 0) {
    FUN_ffffffffc856f870(FUN_ffffffffc85f0480, softc, 0, 0, 0, "SceGbeMtsPhyCtrl");
    // ^^^ kproc_create(gbe_phy_ctrl_thread, softc, NULL, NULL, 0, "SceGbeMtsPhyCtrl")
}
```

The thread handles are stored at `softc+0x3150` (gbe:ctrl) and `softc+0x31a0` (gbe:phy_ctrl),
written by each thread's own entry point from the GS segment (FreeBSD curthread).

FUN_ffffffffc85ef4b0 also:
- Allocates the `ifnet` structure via `if_alloc()`
- Sets up DMA tags for TX/RX rings (0xA0000 and 0x60000 bytes)
- Registers ifnet callbacks: `if_init` = FUN_c85ef7d0, `if_ioctl` = FUN_c85efdb0,
  `if_start` = FUN_c85f0130
- Calls `if_attach()` to make the interface visible to the network stack

**Neither `mts_attach` (FUN_c85ec030) nor `baikal_gbe_attach` (FUN_c8511100) create
the kthreads.** They are created in a later phase when the ifnet is being set up.

### gbe:ctrl thread body (FUN_ffffffffc85f0190, "SceGbeMtsCtrl")

Entry: stores curthread at softc+0x3150. Then:

1. **Init path**:
   - Calls `FUN_ffffffffc85f1e80(softc)` (ctrl_thread_init) which:
     - Calls `mts_init_rings_kick()` — sets up TX/RX descriptor rings
     - If `softc+0x30dc ≠ 0` (secondary MAC): sets BAR+0x80 bit 0 + PHY config
     - If `softc+0x30e0 == 0` (carrier polling enabled): calls `mts_link_change(softc)`
     - **Clears bit 12 (0x1000) of BAR+0x54** — this **disables the "RX packet ready" IRQ**
     - Clears bit 4 of `softc+0x3099`
   - If CDB (configuration database) initialized: sets up event handler table at
     softc+0x31d0..0x3210 with six handlers (FUN_c85f2520..c85f2fc0 + FUN_c85f25a0),
     registers for 0x1b6 events via `FUN_ffffffffc8726420`

2. **Main loop** (waits on cv at `softc+0x3178`, mtx at `softc+0x3158`):
   - `softc+0x3178 = 0` → `msleep(softc+0x3178, softc+0x3158, 0, "gbe_ctrl", 0)`
   - Clears event flags (`softc+0x3178 = 0`)
   - Event **0x10000**: re-initialize (calls FUN_c85f1e80 again)
   - Event **0x2**: link-change — calls FUN_c85f2250() (enables link-change interrupt),
     clears bit 4 of softc+0x3099, **clears bit 12 of BAR+0x54** again
   - Event **0x20000**: kthread park/suspend

3. **RX IRQ gating**: The gbe:ctrl thread manages the "RX packet ready" interrupt
   (BAR+0x54 bit 12) by clearing it on certain events. This means RX interrupts are
   conditionally enabled/disabled, not always-on.

### gbe:phy_ctrl thread body (FUN_ffffffffc85f0480, "SceGbeMtsPhyCtrl")

Entry: stores curthread at softc+0x31a0, sets thread name. Then:

**Main loop** (waits on cv at `softc+0x31c8`, mtx at `softc+0x31a8`):

- If no events → `msleep(softc+0x31c8, mtx, 0, "gbe_phy_ctrl", HZ*3)` (3-second timeout
  normally, `HZ*0` if in special state)
- Clears event flags

- Event **0x10000**: re-queues with event 0x100 (re-run PHY init)

- Event **0x20000**: system suspend — clears suspend flag, calls kthread_suspend_check

- Event **0x100** — PHY auto-negotiation monitoring:
  ```c
  mts_smi_cl45_read(sc, 0xa2001e, &val);  // MMD 0x1e, reg high 0xa200
  mts_smi_cl45_read(sc, 0xa2001e, &val);  // re-read for verification
  if (val < 0 && !suspended) {
      for (int i = 200; i > 0; i--) {       // up to 200 iterations
          mts_smi_cl22_read(sc, 1, &bmcr); // read BMSR
          if (bmcr & 0x4) break;             // AN complete?
          msleep(HZ/100);                    // 10ms delay
      }
      if (timeout) {                         // AN failed
          mts_smi_cl22_read(sc, 9, &ctrl);
          ctrl |= 0x200;                     // advertise 1000BT-full
          mts_smi_cl22_write(sc, 9, ctrl);
          mts_smi_cl22_read(sc, 0, &bmcr);
          mts_smi_cl22_write(sc, 0, bmcr | 0x1200); // restart AN
      }
  }
  ```

- Event **0x1** — Link-change handler:
  ```c
  link_status = readl(BAR+0x04);
  if (!(link_status & 1)) {  // link DOWN
      mts_smi_cl22_read(sc, 9, &ctrl);
      mts_smi_cl22_read(sc, 4, &aneg);
      if (!(ctrl & 0x200)) mts_smi_cl22_write(sc, 9, ctrl | 0x200);
      if (!(aneg & 0x180)) mts_smi_cl22_write(sc, 4, aneg | 0x180);
      mts_smi_cl22_read(sc, 0, &bmcr);
      mts_smi_cl22_write(sc, 0, bmcr | 0x1200);  // restart AN
      softc->link_was_down = 1;
  }
  ```

**The 3-second msleep timeout is the SMI heartbeat.** Even without link-change events,
the gbe:phy_ctrl thread wakes every 3 seconds, reads BMSR via SMI C22, and goes back
to sleep. This periodic MDC activity prevents the SMI controller from entering its
power-gated idle state.

---

## Q2: Who calls baikal_gbe_attach?

### Probe function (FUN_ffffffffc8510fb0)

The probe function at the method table entry reads PCI vendor/device IDs:
- Checks `vendor == 0x104d` (Sony)
- If `device == 0x90d8` → "Baikal GBE controller"
- If `device == 0x90c9` → another variant (Aeolia?)
- Returns `BUS_PROBE_DEFAULT` (0xffffffec = -20) on match

The probe does **no MAC clock, power-domain, or IRQ-routing setup** — just PCI config
reads and a description string write.

### Attach chain

```
PCI bus probe → baikal_gbe_probe (device_method_t at offset 0x71b9c0)
                → matches 0x104d:0x90d8
    PCI bus attach → baikal_gbe_attach (FUN_c8511100)
        → allocates softc, initializes mutexes "network driver", "gbe:ctrl",
          "gbe:phy", "gbe:phy_ctrl", sx_lock "gbe:rmu"
        → reads MAC from SBL registry
        → MSI setup (1 vector)
        → allocates status ring DMA tag/mem (4KB)
        → calls msk_init_hw(softc)
            → writes to BAR+0x004 (8), BAR+0x00C (0), BAR+0x014 (0)
            → BAR+0x158/0x160 modify (chip-specific)
            → BAR+0xF04 GPIO reset (1 then 2, with delays)
            → PHY ID check (SMI read of reg 2/3 at addr 0)
            → If Marvell OUI/match: calls msk_l2switch_vlan_init()
            → If not: "Skip VLAN config" + GPIO retry
            → Status ring init (BAR+0xE80..0xED8)
            → MAC/multicast filter setup (BAR+0x1000+)
        → creates child device "PORT_A" (or "gbe0.1"/"gbe0.2" for secondary MAC)
        → bus_generic_attach() → triggers mts_attach
            → mts_attach (FUN_c85ec030)
                → more mutexes, DMA tags, rings
                → mts_mac_init(softc) — full MAC+PHY register sequence
                → device_add_child → mts network sub-device
                → bus_generic_attach → triggers FUN_c85ef4b0
                    → creates "SceGbeMtsCtrl" kthread
                    → creates "SceGbeMtsPhyCtrl" kthread (if !carrier_polling_disabled)
                    → creates ifnet, registers with network stack
        → bus_setup_intr(irq=0x204, handler=msk_intr, softc)
```

### What msk_init_hw does that's relevant

msk_init_hw (FUN_c8511d50) writes to BAR offsets that overlap with the MTS register
space because both drivers share the same BAR0:

| BAR offset | msk_init_hw value | MTS name | Conflict? |
|---|---|---|---|
| 0x004 | 8 | LINK_STATUS | **YES** — overwrites link status |
| 0x00C | 0 | MAC_CTRL2 | **YES** — clears all MAC ctrl2 bits |
| 0x014 | 0 | MAC_ADDR0_HI | **YES** — clears MAC addr |
| 0x138 | 2, then 1 | unknown | unknown |
| 0x158 | R/M/W (mask 0xCCcccccc, then | 2/1) | Yukon GMAC reg | parent-only |
| 0x160 | R/M/W (mask 0xF33fffff) | Yukon GMAC reg | parent-only |
| 0xF04 | 1 then 2 (GPIO reset) | L2 switch GPIO | parent-only |
| 0xE80..0xED8 | status ring | parent STATUS block | parent-only |
| 0x1000+ | MAC/mcast data | parent MAC/filter | parent-only |

**BAR+0x004 write of value 8**: On Baikal, BAR+0x004 is our LINK_STATUS register
(bit 0 = link up, bits 2-3 = speed, bit 4 = duplex). Writing 8 = 0b1000 sets speed
bits to 0b10 (1000M). But more importantly, any write to this register by the parent
will overwrite whatever the child driver (mts_mac_init) has set.

**BAR+0x00C write of 0**: This clears ALL bits of MAC_CTRL2. If MAC_CTRL2 contains
an SMI clock enable or MDC source select bit, clearing it would kill SMI. However,
in mts_mac_init, the register is only "clear bit 7" (AND with ~0x80), not a full write.
So the parent's write of 0 happens first (before mts_mac_init), and mts_mac_init then
only clears bit 7 — it does NOT re-enable whatever bits the parent zeroed out.

This is a plausible SMI kill vector: if BAR+0x00C bit 7 (or any other bit) is an SMI
enable, and mts_mac_init only clears it further without setting the enable bits,
SMI would be dead after mts_mac_init but alive after the parent's init (because the
parent set different bits before clearing).

---

## Key register bits from gbe:ctrl/gbe:phy_ctrl analysis

| Register | Bit | Meaning | Source |
|---|---|---|---|
| BAR+0x54 | 12 (0x1000) | RX packet ready IRQ mask — **cleared by gbe:ctrl** to gate RX | FUN_c85f1e80, FUN_c85f0190 |
| BAR+0x54 | all other | Kept active (0x7BFFFE is the full mask set by Orbis) | mts_ifup |
| BAR+0x04 | 0 | Link up status | gbe:phy_ctrl |
| BAR+0x1c8 | 6 | MCAST_HASH_DONE — checked in gbe:ctrl init and mts_ifup | FUN_c85f0190 |
| BAR+0x34 | 1 | RX restart flag (polled until clear with 1M iterations) | FUN_c85ef020 |
| BAR+0x38 | 1 | TX restart flag (polled until clear with 1M iterations) | FUN_c85ef020 |
| BAR+0x80 | 0 | Secondary-MAC enable | FUN_c85f1e80 |

---

## The MT stop path (what Orbis does on ifdown)

FUN_ffffffffc85ec710 (mts_ifdown handler) does in sequence:

1. `kthread_suspend_check(gbe:ctrl_thread)` — enter suspend
2. `cv_signal(gbe:ctrl_cv)` — let ctrl thread finish
3. `msleep(timeout)` — wait
4. If carrier_polling_enabled: same for gbe:phy_ctrl thread
5. Check BAR+0x1c8 bit 6: if set, call FUN_c85ef020 and `mts_smi_cl45_write(sc, 0x147001e, 0x10)`
6. FUN_c85ef020 (stop_rings_quiesce) does:
   - BAR+0x54 = 0x7ffffa (disable IRQs 0 and 2)
   - BAR+0x34 = 2 → poll until bit 1 clears (RX stop)
   - BAR+0x38 = 2 → poll until bit 1 clears (TX stop)
   - Mark all TX/RX descriptors as HW-owned (0x80000000)
   - Clear bits 6 and 10 of BAR+0x1c8

The `mts_smi_cl45_write(sc, 0x147001e, 0x10)` writes value 0x10 to MMD device 0x1e,
register 0x147. This is a Realtek PHY power-down command (RTL8211 vendor-specific MMD
register for power management).

---

## Recommended next experiment on hardware

For the standalone ps4_mts.c driver (Path B from v82-decision.md), the init sequence must
include spawning a `kthread_run`-based polling thread equivalent to gbe:phy_ctrl that:

1. Every 3 seconds, reads BMSR via SMI C22 (this is the MDC heartbeat)
2. On link-change events (BAR+0x54 bit 0x4), handles AN re-advertisement
3. Does NOT clear BAR+0x54 bit 12 until RX processing is set up
4. On driver close/down, sends `SMI_CL45_write(MMD=0x1e, reg=0x147, val=0x10)` for
   PHY power-down, then quiesces TX/RX rings via BAR+0x34/0x38 writes

Without this periodic SMI thread, MDC will die regardless of any register state we
restore — the controller needs ongoing bus transactions to stay clocked.