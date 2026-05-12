# PS4 Baikal GBE — kthread create sites & SMI clock-gating hypothesis
**Agent:** kimi-k2.6 (OpenCode)  
**Date:** 2026-05-12  
**Ghidra program:** `orbis-12.02.elf` (project `orbis-ps4-dump`)

---

## Lead finding: gbe:phy_ctrl is a *continuous* PHY-polling kthread, and its absence kills MDC

The SMI MDC clock does not stay alive from register state alone.  Orbis's `gbe:phy_ctrl` kthread performs **active SMI MDIO reads every few seconds** in its main loop.  When Linux sky2 (or a bare standalone driver) stops touching the PHY after `ifup`, the SMI engine's internal clock gating shuts MDC down.  This is the structural reason restoring BAR-visible register state never recovers SMI after sky2 breaks it.

---

## Q1 — kthread create sites & thread bodies

### Where are they created?

**Create function:** `FUN_ffffffffc85ef4b0` (source path `if_mts.c:0x1365`).  
This is the ifnet-allocation / port-attach helper for the child `PORT_A` device.  It calls FreeBSD's `kproc_create` (Ghidra name `FUN_ffffffffc856f870`) twice:

```c
// at ffffffffc85ef76d  (DATA ref to c85f0190)
FUN_ffffffffc856f870(FUN_ffffffffc85f0190, lVar4, 0, 0, 0, "SceGbeMtsCtrl");

// at ffffffffc85ef799  (DATA ref to c85f0480)
if (*(int *)(lVar4 + 0x30e0) == 0) {
    FUN_ffffffffc856f870(FUN_ffffffffc85f0480, lVar4, 0, 0, 0, "SceGbeMtsPhyCtrl");
}
```

**Both kthreads are created at attach time**, long before `mts_ifup` (c85ec940) resumes them.  The handles are stored at:
- `softc + 0x3150` → `gbe:ctrl`
- `softc + 0x31a0` → `gbe:phy_ctrl`

The mutexes initialized in `mts_attach` (c85ec030) are at `softc + 0x3158` and `softc + 0x31a8`.

### gbe:ctrl body — `FUN_ffffffffc85f0190` ("SceGbeMtsCtrl")

Entry: `0xffffffffc85f0190`, end: `0xffffffffc85f047d`.

Main loop (condensed from decompile):
1. Save `curthread` → `softc + 0x3150`.
2. Call `FUN_ffffffffc8570730("SceGbeMtsCtrl", 0x44, 0x200, 0)` — likely sets thread priority.
3. **Wait** on state variable at `softc + 0x3178` (mutex `softc + 0x3158`).
4. If state bit `0x10000` set: call `mts_init_rings_kick` + `mts_link_change`.
5. If state bit `0x2` set: call `FUN_ffffffffc85f2250(uVar3)` (L2 switch reset helper), then **clear bit 0x1000 in BAR+0x54 IRQ mask** (line `0x11ff` in source).
6. If state bit `0x20000` set: call `FUN_ffffffffc85704d0()` and exit loop.

The `0x2` handler toggles the IRQ mask — this is the path that disables the MAC-level IRQ block when the link is brought down.  It does **not** touch SMI directly.

### gbe:phy_ctrl body — `FUN_ffffffffc85f0480` ("SceGbeMtsPhyCtrl")

Entry: `0xffffffffc85f0480`, end: `0xffffffffc85f090f`.

This is the critical thread for the MDC hypothesis.  Main loop:
1. Save `curthread` → `softc + 0x31a0`.
2. Call `FUN_ffffffffc8570730("SceGbeMtsPhyCtrl", 0x44, 0x200, 0)`.
3. **Wait** on state variable at `softc + 0x31c8` (mutex `softc + 0x31a8`).
4. If state bit `0x10000` set: re-init PHY state.
5. **If state bit `0x100` set** — the normal "keep alive" path:
   - Read C45 register `0xa2001e` (MMD 0x1e, vendor page) twice.
   - If link-down (`local_46 < 0` and `sc->event_phy_ctrl` bit not set):
     - Loop up to 70 times (with 100 ms sleep):
       - **Read C22 reg 1 (BMSR)** via `mts_smi_cl22_read`.
       - Check `BMSR_LSTATUS` (bit 2).
       - If still down after timeout:
         - Toggle bit 9 in **reg 9** (1000BASE-T control, `MII_CTRL1000`) via `mts_smi_cl22_write`.
         - Read **reg 0** (BMCR), then write `BMCR |= 0x1200` (restart AN + enable AN).
6. **If state bit `0x1` set** — link-check path:
   - Read **BAR+0x04** (link status).
   - If bit 0 clear (link down):
     - Read **reg 9** and **reg 4** (ANLPAR).
     - Write reg 9 with 1000BASE-T bit 9 set.
     - Write reg 0 with `0x1200` (restart AN).
7. If state bit `0x20000` set: exit.

**Key observation:** Even when link is already up, this thread **repeatedly reads BMSR (reg 1) and vendor C45 registers** via SMI.  The C22 read at `mts_smi_cl22_read` arms the SMI controller (`0x8000` then `0x4000|...`), polls the DONE bit, and fetches data.  **Every iteration exercises the full SMI handshake**, which keeps the MDC clock domain from gating off.

---

## Q2 — caller of `baikal_gbe_attach` (FUN_c8511100)

`baikal_gbe_attach` is **not called directly** from visible code; it lives in a FreeBSD `device_method_t` vtable at binary offset `0x71b9d0` (unallocated_2 segment).  The vtable contains the QWORD `0xffffffffc8511100` at that offset.

The attach function itself (decompiled at `0xffffffffc8511100`) does the following **before** creating the child `PORT_A`:
1. Allocates parent softc via `FUN_ffffffffc8602ac0`.
2. Initializes mutexes: `"network driver"`, `"gbe:ctrl"`, `"gbe:phy"`, `"gbe:rmu"`.
3. Reads PCI config space for MSI count via `FUN_ffffffffc9dfe9f0` dispatch.
4. Reads **BAR+0x11b** for chip ID byte; expects `0xBD` (this is the Yukon-2 chip-ID register).
5. Reads **BAR+0x11a** for revision (top nibble = rev).
6. If chip ID == `0xBD`, reads PHY OUI at MDIO addr 0 (Marvell switch detection).
7. Allocates a 4 KB status DMA ring.
8. Calls `msk_init_hw(plVar6)` — the full Yukon-2 HW init sequence (see below).
9. Adds child device `"PORT_A"` via `device_add_child`.
10. Calls `bus_generic_attach` → this eventually triggers the child attach (`FUN_ffffffffc85ef4b0`), which creates the kthreads.

**Nothing in baikal_gbe_attach explicitly "enables" a MAC clock or PHY power-domain bit** before attach.  The clock/power state is established by `msk_init_hw` and by the parent PCI bridge's standard BAR mapping + MSI setup.  There is no hidden GPIO or vendor-specific PCI config write that Linux is missing.

---

## Q3 — BAR+0x04/08/0c/10 bit decode (brief)

From `mts_link_change` (`0xffffffffc85eeb90`) and `mts_mac_init` (`0xffffffffc85ecb60`), the fields are:

| Offset | Field | Bits | Meaning |
|---|---|---|---|
| `0x04` | `LINK_STATUS` | 0 | Link up/down |
| | | 2-3 | Speed: `00`=10M, `01`=100M, `10`=1000M |
| | | 4 | Full duplex |
| | | 6 | Flow control active |
| | | 8 | Aux state (used in switch mode) |
| `0x08` | `MAC_CTRL1` | — | OR'd with `0x07597C00` in init |
| `0x0c` | `MAC_CTRL2` | 7 | Cleared during init |
| `0x10` | `MAC_CTRL3` | — | Mask `0xFFFFFF6E`, OR `0x81` |

No "MDIO clock enable" or "MDC source select" bit was found in manipulations of `0x04`–`0x10`.  The SMI clock appears to be gated by **transaction activity** rather than a static enable bit.  This supports the kthread hypothesis: continuous PHY reads are the "clock keepalive".

---

## Disagreement with prior analysis

The v82 decision doc states: *"The damage from sky2's interface-up writes appears one-way: once SMI goes stuck, restoring the BAR-visible register state doesn't recover."*

**I agree with the observation but disagree with the implied mechanism.**  It's not that the writes are "one-way damaging."  Rather, Orbis's architecture relies on a **continuous kthread** to keep the SMI state machine exercised.  Linux's sky2 (and any naive standalone driver) sets up the MAC once and then stops polling the PHY until the link timer fires — but by then MDC has already gated off.  Restoring registers doesn't help because the clock domain needs active transactions to wake up.

The kimi/glm theory that "sky2's Yukon-2 writes collide with Baikal's MAC control region" is directionally correct but the **root cause is the missing kthread**, not a specific register collision.

---

## Recommended next experiment on hardware

Add a **kernel workqueue or kthread** to the standalone `ps4_mts.c` driver that runs every 1–2 seconds and performs a single SMI C22 read of PHY register 1 (BMSR).  No state machine needed for the first test — just a raw `mts_smi_cl22_read(phy_addr, 1, &val)` loop.

**If MDC stays alive and returns real BMSR values (e.g., `0x7949`) for >5 minutes**, the kthread-keepalive hypothesis is confirmed.  Then replicate the full `gbe:phy_ctrl` state machine (BMSR poll + AN restart on timeout) for robust link bring-up.

**If it still dies**, the problem is deeper (e.g., MSI delivery pattern, DMA coherency, or a missing `msk_init_hw` step), and we should pivot to comparing `msk_init_hw` with Linux `sky2_reset` (Q4).

---

## Ghidra anchors for verification

| Function | Address | Source file (inferred) |
|---|---|---|
| kthread create site | `0xffffffffc85ef4b0` | `if_mts.c:0x1365` |
| `kproc_create` (FreeBSD) | `0xffffffffc856f870` | — |
| `gbe:ctrl` body | `0xffffffffc85f0190` | `if_mts.c:0x11ea` |
| `gbe:phy_ctrl` body | `0xffffffffc85f0480` | `if_mts.c:0x84f` |
| `mts_link_change` | `0xffffffffc85eeb90` | `if_mts.c` |
| `baikal_gbe_attach` | `0xffffffffc8511100` | `if_msk.c` |
| `msk_init_hw` | `0xffffffffc8511d50` | `if_msk.c:0xc9a` |
| `mts_ifup` | `0xffffffffc85ec940` | `if_mts.c:0x12e4` |
| `mts_attach` | `0xffffffffc85ec030` | `if_mts.c` |
