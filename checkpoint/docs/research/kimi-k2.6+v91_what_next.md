# v91 — what's left? Brutal assessment after software exhaustion

**kimi-k2.6, 2026-05-13**

## Executive summary (read this first)

After 8 patch iterations (v82→v89 + v90/v90b reverted), PHY-level link is fully healthy but MAC BAR+0x04 bit 0 will not latch. Every standard software approach has been tested and failed. The remaining conceptual space is:

1. **One missing register gate in `mts_ifup`** (BAR+0x1c8 bit 6 clear) that our driver may skip — **moderate probability**.
2. **A hardware-level PCS/RGMII timing issue** that no software init sequence can fix — **high probability**.
3. **A destructive `msk_init_hw` write** that we can't replay, but whose absence leaves the MAC in a non-link-ready state — **moderate probability**.
4. **TX traffic required** for MAC to latch — **low probability** (no supporting evidence in Orbis or mainline).
5. **Partner incompatibility** — **very low probability** (PHY AN is perfect).

If the missing `mts_ifup` gate doesn't fix it, the honest answer is: **phase 3 TX-traffic test, then hardware swap, then accept that the MAC silicon has a requirement we haven't identified and pivot to `sky2` or `stmmac` porting.**

---

## Q1 — Linux driver analogs for "MAC link detector won't latch"

I searched `drivers/net/ethernet/` in the 6.x-baikal tree for PCS-sync, link-latch, and chicken-and-egg patterns. Results:

### Relevant patterns found

| Driver | Pattern | Relevance to us |
|---|---|---|
| `tg3.c` | `MAC_STATUS_PCS_SYNCED` (bit 0) must be set before `current_link_up = true` | PCS sync is a **MAC-level** gate for link reporting. If PCS is not synced, MAC won't report link even if PHY AN is done. |
| `ixgbe_x550.c` | "Link status is latching low, and can only be used to detect link drop, not current status without back-to-back reads" | This is **PHY-level** BMSR latch-low behavior. Our driver already implements double-read (v85). |
| `natsemi.c` | "The link status field is latched: it remains low after a temporary link failure until it's read. We need the current link status, thus read twice." | Again **PHY-level**. Not our problem. |
| `sun/cassini.c`, `sun/sungem.c` | "The link status bit latches on zero, so you must read it twice in such a case to see a transition to the link being up." | **PHY-level** latch-low. |
| `cavium/thunder_bgx.c` | "Receive link is latching low. Force it high and verify it." | **MAC-level** latch-low, but this is a specific Cavium SPU_STATUS1_RCV_LNK bit that can be forced high by software. Our BAR+0x04 bit 0 is **read-only** (hardware-driven). |

### Bottom line for Q1

**No Linux driver shows a "MAC link bit is read-only, PHY is healthy, but MAC won't latch" pattern with a known software fix.** The closest is `tg3.c`'s `PCS_SYNCED` requirement, which tells us that MAC-level link reporting can be gated by PCS synchronization independent of PHY AN state. If the Baikal MAC's PCS is not locking onto the RGMII signals, BAR+0x04 bit 0 will stay 0 forever regardless of PHY health.

The `tg3` pattern is the most relevant conceptual model: **PCS sync is a separate subsystem from PHY AN.**

---

## Q2 — Phase 3 "MAC needs traffic" minimum work

### Hypothesis
The MAC's link detector requires seeing valid RX symbols (or a TX management frame) before it will assert link status.

### Evidence for
- BAR+0x118 is an auto-incrementing counter, proving the MAC IS receiving symbols from the PHY.
- `mts_init_rings_kick` sets up descriptors and starts engines, but we do this manually.

### Evidence against
- Orbis `mts_link_change` reads BAR+0x04 directly; there is no "wait for first packet" logic.
- `mts_init_rings_kick` does not send a dummy frame; it just allocates descriptors.
- No mainline driver requires TX traffic before link-up.

### Minimum LOC to test
If you still want to test this, the absolute minimum is:

1. **Descriptor format**: Orbis RX desc = 16 bytes: `status/owner (4) | length (4) | buffer_addr (8)`. Owner bit = `0x80000000` (MAC owns). TX desc = 16 bytes: `control (4) | length (4) | buffer_addr (8)`. Control = `0x80000600` for a simple frame.
2. **Buffer allocation**: Single 4 KB DMA-coherent buffer for RX, one for TX. Orbis allocates 4 KB rings with 0x1000 byte alignment.
3. **TX kick**: Write buffer address into TX descriptor slot 0, set control = `0x80000600`, set length = 64. Write descriptor base to BAR+0x40. Set BAR+0x38 |= 1.
4. **Frame content**: A 64-byte Ethernet frame with ethertype 0xFA42 (MT7531 management) and payload for opcode 0x800B. Or we can just send a standard broadcast frame — if the hypothesis is "any traffic", the content doesn't matter.
5. **Completion wait**: Poll BAR+0x38 or descriptor owner bit for ~10 ms.
6. **Read BAR+0x04**.

**Estimated LOC**: ~80 lines of C (descriptor struct, buffer alloc, DMA sync, frame build, kick, poll).

**Probability of success**: **< 10%**. The MAC is already receiving symbols (BAR+0x118 counter). There is no Orbis evidence that TX traffic gates link.

---

## Q3 — Hardware variable space (cable / switch / MT7531 incompatibility)

### Known facts
- PHY-level AN is perfect: BMSR=0x7969, LP=0xc5e1, 1000BT_STAT=0x3c00, no Remote Fault.
- MT7531 is a switch IC used in many routers (TP-Link Archer, Xiaomi, etc.).
- The PHY is inside the MT7531; we are talking to it via the MAC's SMI controller.

### Could a different partner help?
- **Unlikely.** The PHY reports AN complete and both receivers OK. The MAC link bit is the only thing missing. A different switch would not change the MAC's internal link-detection logic.
- The only scenario where a different partner helps: if the current partner's RGMII drive strength / timing is marginal, and a different device has tighter timing. But we already applied RGMII TX/RX delay (v89). The PHY-level handshake is solid.

### Known MT7531 issues
- MT7531 has a known erratum where the per-port PHY may not come up if the core PLL is not enabled. We enabled it in v86.
- Mainline `mtk-ge.c` and `mt7530.c` do extensive vendor-specific init. Our v88+v89 patches applied the key ones (DSP defaults, SlvDPSready, RGMII delay).
- No known erratum about "PHY healthy but MAC link bit stuck" in public datasheets.

**Verdict**: Swapping hardware is worth one test if you have a different GbE device handy, but **probability < 5%**.

---

## Q4 — Did we miss any Orbis function?

### Functions we have decompiled

| Function | Address | Role |
|---|---|---|
| `baikal_gbe_attach` | `0xc8511100` | Baikal-specific attach. Calls `msk_init_hw`, creates `gbe:ctrl` kthread, registers `mts_intr`. **Does NOT call `mts_mac_init`.** |
| `msk_init_hw` | `0xc8511d50` | 400+ lines of register writes. Probed in v90/v90b — **destructive to replay**. |
| `mts_mac_init` | `0xc85ecb60` | PHY init + MAC register config. Called from `mts_ifup` (and also from generic `mts_attach`). |
| `mts_init_rings_kick` | `0xc85ef1b0` | Ring setup, engine start. Gates on BAR+0x1c8 bit 6. |
| `mts_ifup` | `0xc85ec940` | Interface up handler. **Clears BAR+0x1c8 bit 6**, calls `mts_mac_init`, then `mts_init_rings_kick`, then resumes kthreads. |
| `mts_link_change` | `0xc85eeb90` | Read-only on BAR+0x04. |
| `FUN_c85131d0` | `0xc85131d0` | Prelude called from `msk_init_hw`. Does Baikal-specific BAR+0x60/0x64/0x68/0x6c writes. |

### Critical finding: `mts_ifup` semantics

Ghidra decompile of `mts_ifup` (`0xc85ec940`) reveals a register write we have **never performed**:

```c
puVar1 = (uint *)(**(long **)(lVar4 + 0x30a0) + 0x1c8);
*puVar1 = *puVar1 & 0xffffffbf;   // CLEAR bit 6 of BAR+0x1c8
mts_mac_init(lVar4);
mts_init_rings_kick(...);
// ... resume gbe:ctrl, gbe:phy_ctrl
```

And `mts_init_rings_kick` (`0xc85ef1b0`) begins with:

```c
if ((*(byte *)(lVar1 + 0x1c8) & 0x40) != 0) {
    return;   // If bit 6 is SET, skip ALL ring setup
}
// ... ring setup ...
*(uint *)(lVar1 + 0x1c8) = *(uint *)(lVar1 + 0x1c8) & 0xfffffbbf | 0x40;
// At end: clear bit 8, SET bit 6
```

**This is a gate.** `mts_ifup` must clear bit 6 before ring init, or `mts_init_rings_kick` returns early. Even if our driver does its own ring setup (not calling Orbis's function), the fact that Orbis explicitly gates ring init on this bit suggests **BAR+0x1c8 bit 6 controls some MAC-internal state**.

### Did we miss `mts_ifup`?

**Yes, partially.** Our `ps4_mts_open` (Linux `ndo_open`) is the analog of `mts_ifup`, but:
- It may not clear BAR+0x1c8 bit 6.
- It may not call `mts_mac_init` at open time (we might call it at probe time).
- It may not resume kthreads with the same scheduling parameters (`0x10000`, `0x10100`).

In Orbis:
- **Attach** (`baikal_gbe_attach`): `msk_init_hw` only.
- **Open** (`mts_ifup`): `mts_mac_init` + BAR+0x1c8 clear + ring init + kthread resume.

In our driver, we might be calling `mts_mac_init` at probe time and skipping the `mts_ifup` register writes. **This is the single largest unexplored software gap.**

### Other missed functions

- `mts_intr` (interrupt handler): We decompiled it in earlier rounds. It does error recovery but no link-latching magic.
- `gbe:ctrl` / `gbe:phy_ctrl` kthreads: These poll BMSR and manage AN restart. They do not write to BAR registers that would affect link latching.
- `FUN_c85133d0`: Called from `msk_init_hw`. We haven't decompiled it. But since `msk_init_hw` is destructive to replay, its callees are likely also dangerous.

**Verdict**: The only significant un-explored territory is **`mts_ifup` and its BAR+0x1c8 bit 6 clear**. Everything else is either already covered or proven irrelevant.

---

## Q5 — BAR+0x09c "PKT_ENGINE_CTRL"

### What we know

- Our driver defines it as `MTS_PKT_ENGINE_CTRL` at offset `0x09c`.
- **Orbis `mts_mac_init` does NOT write to 0x09c.**
- **Orbis `msk_init_hw` does NOT write to 0x09c.** (Verified by disassembly grep — offsets are 0x158, 0x160, 0x4, 0x138, 0xe08, 0xe18, 0xe80, 0xe88, 0xe8c, 0xe84, 0xe98, 0xeac, 0xead, 0xed0, 0xec0, 0xec8, 0xeb8, 0xed8, 0xf04, 0xf22, 0xf2c, 0xf30, 0xf80, 0xf20, 0xf70.)
- **Orbis `mts_init_rings_kick` does NOT write to 0x09c.**
- **Orbis `mts_ifup` does NOT write to 0x09c.**

So **0x09c is left at hardware default** in Orbis.

### The userspace observation

Writing `BAR+0x09c = 0xff` changed `linkreg` speed reporting from 1000M to 100M. This means 0x09c controls some aspect of **MAC's interpretation of PHY state** (speed/duplex muxing), but it does not gate the link bit directly.

### Orbis init value

The prompt states Orbis init value is `0x6f`. Since no init function writes it, `0x6f` is the **hardware reset default**.

### Bit decode (inferred from behavior)

| Bit | Value in 0x6f | Effect observed |
|---|---|---|
| 0 | 1 | Unknown |
| 1 | 1 | Unknown |
| 2 | 1 | Unknown |
| 3 | 0 | Unknown |
| 4 | 1 | Unknown |
| 5 | 1 | Unknown |
| 6 | 1 | Toggled during error recovery (per `orbis-mts-driver-RE.md`) |
| 7 | 0 | Unknown |

When userspace wrote `0xff`, speed field in `linkreg` flipped from 1000M to 100M. This suggests bits [5:0] control a **speed selection mux** that overrides or masks the PHY-reported speed. The MAC may read 0x09c to decide how to interpret the MII/RGMII receive data, and if misconfigured, it may reject the PHY's speed indication — which could in theory prevent link latching if the MAC thinks the speed is invalid.

**However**: we are NOT writing to 0x09c, so it should be at its default `0x6f` — the same as Orbis. Therefore, **0x09c is unlikely to be the root cause** unless our hardware default differs from Orbis's (e.g., because `msk_init_hw` sets some related register that changes the effective default).

---

## Brutal verdict: what's actually left to try

### High-probability remaining software gap

1. **Implement `mts_ifup` faithfully in `ps4_mts_open`:**
   - Call `mts_mac_init` at open time (not probe time).
   - **Clear BAR+0x1c8 bit 6** before ring init.
   - After ring init, ensure bit 6 is set (or let `mts_init_rings_kick` set it).
   - Resume kthreads with Orbis-like scheduling.
   - **Estimated effort**: 1 patch iteration.
   - **Probability of fixing link**: **30-40%**. This is the last coherent software hypothesis.

### Medium-probability hardware-level issues

2. **PCS sync failure due to RGMII timing mismatch:**
   - We applied RGMII delay (v89), but the MAC's PCS may need a specific delay value or phase alignment.
   - The `tg3.c` model suggests PCS sync is independent of PHY AN.
   - If PCS doesn't lock, BAR+0x04 bit 0 stays 0 forever.
   - **No software fix known** without adjusting analog delay registers (which may not exist in this MAC).
   - **Probability**: **40%**.

3. **Missing `msk_init_hw` side effect:**
   - `msk_init_hw` does ~400 lines of writes, many to offsets >0xe00.
   - We can't replay it (destructive), but some of those writes may configure the MAC's clock domain, FIFO thresholds, or PCS parameters.
   - If the MAC requires these to be present before link can latch, we are stuck.
   - **Probability**: **30%**.

### Low-probability long shots

4. **TX traffic hypothesis (phase 3):**
   - Build a minimal TX descriptor, send one frame.
   - **Probability**: **< 10%**.

5. **Hardware swap (different cable / switch):**
   - Easy to try if hardware is available.
   - **Probability**: **< 5%**.

6. **BAR+0x09c manipulation:**
   - Try writing `0x6f` explicitly, or try `0x00`, `0xff`.
   - Low risk, but no theoretical basis.
   - **Probability**: **< 5%**.

### The nuclear option

If the `mts_ifup` gate doesn't work, the honest assessment is:

> **The Baikal MAC has a hardware requirement that is satisfied by `msk_init_hw` but not by `mts_mac_init`. Since `msk_init_hw` is destructive to replay, we cannot satisfy this requirement in software without understanding every one of its ~400 register writes. The practical path forward is to abandon the Orbis-derived `ps4_mts` driver and port `stmmac` (Synopsis DesignWare GMAC, which Baikal resembles) or fix `sky2` with a Baikal quirk table.**

This was the `v82-decision.md` recommendation. We have spent 9 iterations proving it was probably correct.

---

## Recommended next step

**One more iteration: v91 — implement `mts_ifup` faithfully.**

Patch `ps4_mts_open` to:
1. `mts_mac_init(dev)` (move from probe to open, or call again at open).
2. Read BAR+0x1c8, clear bit 6, write back.
3. Ring init (keep our existing setup).
4. Set BAR+0x1c8 |= 0x40 (set bit 6) after ring init.
5. Start kthreads.

If this fails, **stop iterating on register writes**. The remaining gap is either in `msk_init_hw` (unreplayable) or a hardware-level PCS issue.

---

## Cited Ghidra addresses

| Function | Address | Key finding |
|---|---|---|
| `mts_ifup` | `0xc85ec940` | `BAR+0x1c8 &= ~0x40` before ring init |
| `mts_init_rings_kick` | `0xc85ef1b0` | Early return if `BAR+0x1c8 & 0x40`; sets bit 6 at end |
| `mts_mac_init` | `0xc85ecb60` | No writes to `0x09c`, `0x208`, `0x210` |
| `msk_init_hw` | `0xc8511d50` | No writes to `0x09c`; ~400 lines of init |
| `baikal_gbe_attach` | `0xc8511100` | Calls `msk_init_hw` but NOT `mts_mac_init` at attach |
| `mts_link_change` | `0xc85eeb90` | Read-only on `BAR+0x04` |
| `FUN_c85131d0` | `0xc85131d0` | Prelude: Baikal-specific `BAR+0x60/0x64/0x68/0x6c` writes |
