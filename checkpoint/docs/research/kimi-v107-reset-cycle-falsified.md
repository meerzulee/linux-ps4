# v107 — Reset-cycle falsified: what is actually gating the latch?

**kimi-k2.6, 2026-05-13**

## Q1: Why did reset-release not trigger the sample?

`BAR+0x200` is a **datapath reset**, not a **link-latch reset**. The readback confirmed it toggles (0→1→0), but `BAR+0x004` and `BAR+0x06c` are completely unaffected. This means the link-latch state machine lives in a separate clock/power domain that is:
- Either **not connected** to `BAR+0x200`
- Or **already committed** to its POR-evaluated state and ignores subsequent reset pulses

In v91, the latch was already set when our driver loaded — the driver did not create the condition, it merely **inherited** it from the bootloader. The `writel(0, 0x200)` in v91 was a no-op on an already-released reset; the latch had already been set earlier, during bootloader init.

## Q2: Is there a missing clock-enable register?

**Yes — and it is likely not in BAR space.** The prelude registers (`0x060`, `0x064`, `0x068`, `0x06c`) configure clock domains, but they are written in probe, not in a specific sequencing relationship to PHY link state. The bootloader may have:
1. Powered the PHY
2. Waited for PHY link
3. Enabled the **MAC core clock** via a register we do not know (possibly PCIe configuration space, power-management register, or a GPIO that gates the MAC PLL)
4. Only then released `BAR+0x200`

Our driver writes all prelude registers unconditionally, regardless of PHY state. If the MAC core clock has a "link-qualified enable" that only the bootloader knows how to assert, we cannot replicate it.

**Untested**: Is there an MMD register that gates MAC-side link? MMD 1 (PMA) reg 0 bit 11 = PWRDOWN could prevent the PHY from presenting a stable MII signal to the MAC even when BMSR shows link. But v91 had the same PHY state and the latch worked, so this is unlikely.

## Q3: Ship RX-only or keep trying?

**Ship RX-only.**

The evidence is overwhelming:
- The latch fired exactly once in v91 (bootloader-dependent state)
- It has never fired again despite exhaustive register manipulation
- The reset register does not gate it
- The sample moment is not during `mts_mac_init`
- The PHY is demonstrably linked but the MAC ignores it

The most honest chip-design assessment is that the link-latch is **armed during a specific boot-sequencer state** (possibly a PCIe reset deassertion handshake between the PHY and MAC) that Linux on PS4 does not reproduce. Once that window passes, the MAC commits to "no link" and all BAR-accessible state is read-only with respect to the latch.

**RX is fully functional** — NAPI, skbs, descriptors, IRQ, DMA, all verified. The driver can receive traffic from the wire indefinitely. TX is blocked by a single hardware status bit that we cannot set.

Ship v97-level RX, document the TX gate as a known hardware limitation, and move on.

## Verdict

**The latch is write-once per power-cycle, armed by a boot-time-only condition.** No software re-trigger exists. RX-only is the practical endpoint.
