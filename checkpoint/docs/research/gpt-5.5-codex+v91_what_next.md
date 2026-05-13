# gpt-5.5-codex — v91 what next — 2026-05-13

Concrete finding: there is no credible remaining “one magic register” software fix. v88/v89 proved the PHY/wire side is healthy; v90/v90b proved blind Orbis/MSK replay is worse than useless because init-order-sensitive writes can hard-wedge or zero the MAC. What remains is either (1) implement enough real MTS TX/RX to prove/disprove the traffic path, (2) vary hardware, or (3) instrument/capture a working Orbis state. Everything else is likely register roulette.

## What is NOT likely to work

- More isolated BAR pokes. v89 lines 37-49 already say BAR+0x04 bit 0 is hardware-driven, 64+ random BAR writes were absorbed, master/switch reset did nothing, and BAR+0x158 did nothing. v90/v90b result lines 7-16 then showed the “more faithful Orbis replay” path is actively destructive: full v90 hung after ISR registration; minimal v90b made BAR reads return zero after BAR+0x00c=0.

- Replaying `msk_init_hw` later in Linux. The write sequence is phase/order dependent. `msk_init_hw` at `ffffffffc8511d50` can write BAR+0x00c=0 during parent bring-up; doing that after our prelude/IRQ/MAC setup kills the device. The lesson is not “try a smaller subset again”; it is “this sequence is not transplantable outside its original Orbis lifetime point.”

- Forcing link by writing BAR+0x04. Already falsified. `mts_link_change` (`ffffffffc85eeb90`) only reads BAR+0x04; Ghidra callers use it as status. Linux writes do not latch bit 0.

- More PHY tuning. v91 prompt lines 9-23 are enough: AN complete, RF=0, MS fault=0, both receivers OK, LP ability sane, all mainline MT7531 init writes applied, SMI alive. v89 lines 17-19 also falsified forced 100M full duplex. The PHY is no longer the blocker.

- Assuming “MAC needs traffic before link” is likely. Ghidra argues against it. `gbe:ctrl` body `FUN_ffffffffc85f0190` calls `FUN_ffffffffc85f1e80` first, and `FUN_ffffffffc85f1e80` calls `mts_init_rings_kick`, polls BAR+0x04, then calls `FUN_ffffffffc85f2250`/management only from that later control path. `FUN_ffffffffc85f2250` builds two 0x20-byte ethertype 0xfa42 frames with opcodes 0x800b and 0x600b, but it is not the primitive that makes initial link exist. If traffic helps in Linux, it will be because our emulation is missing an Orbis side effect, not because the designed protocol requires TX before link.

## What might still be worth trying

1. Hardware swap: highest signal per reboot.

Try a different cable and a dumb unmanaged switch / different link partner before writing more code. This is cheap and directly tests the only non-software variable left. I do not see strong public evidence from a quick external search for a specific MT7531 “AN complete + both receivers OK but MAC link pin never asserts” incompatibility, but partner quirks are common enough that this beats another blind register iteration. Expected outcomes:

- If BAR+0x04 bit 0 latches with a different partner, stop touching MAC regs and characterize the partner-dependent PHY mode.
- If it never latches across two or three partners/cables, treat the MAC-side detector or board-level signal as the problem.

2. Phase 3 minimal TX/RX: necessary eventually, but not high-probability as a link-latch fix.

This is the only remaining pure-software experiment that is not random. It should be framed as “prove the descriptor path and management frame path,” not “likely to fix BAR+0x04.” Minimum work is not 20 LOC; it is probably 200-400 LOC because descriptor ownership has to be real enough not to corrupt memory.

Ghidra anchors:
- `FUN_ffffffffc85f1890` allocates/copies a packet buffer, calls `FUN_ffffffffc85f1aa0`, then writes BAR+0x34 |= 4 and waits up to 1000 ms for `softc+0x3109` to equal sequence `softc+0x3108`.
- `FUN_ffffffffc85f1aa0` is the TX descriptor producer. Descriptor stride appears 0x18; descriptor pointer table lives at `softc+0x68 + idx*0x18`; software writes first dword with owner/control bits including 0x80000000, 0x20000000, sometimes 0x40000000; second dword is buffer DMA address; third/fourth dwords carry length/VLAN/checksum-ish fields. This is not safely guessable from sky2.
- `mts_tx_complete` (`ffffffffc85eeca0`) walks the same 0x18 entries using `softc+0x305c` and frees completed buffers.
- RX entries in `mts_rx_unwrap_one` (`ffffffffc85eed90`) are initialized with first dword `0x80000600`, DMA address in second dword, and completion is detected by first dword > `0x80000000` in `mts_rx_process` (`ffffffffc85eea10`).

Brutal expectation: Phase 3 may produce successful 0xfa42 TX/RX and still leave BAR+0x04 bit 0 down, because Orbis’s first management frame is after link detection. But if the project wants Ethernet, Phase 3 must be done anyway; it is the least-wasteful software path left.

3. Working-Orbis register capture / trace: best missing evidence, hardest operationally.

If you can capture BAR0 while Orbis has working Ethernet, do that. A dump before driver attach, after `msk_init_hw`, after `mts_mac_init`, after `mts_init_rings_kick`, and after link-up would end the guessing. Without that, unknown registers like 0x080/0x098/0x09c/0x0b0/0x0b4/0x208/0x210 are just folklore.

My read of BAR+0x09c: it is not a hidden link-enable. In Orbis `mts_intr` (`ffffffffc85edcf0`) only toggles bit 6 clear/set during packet-engine error recovery, then drains/reloads TX. v89/v90 observed 0x09c writes perturb speed fields, but that is consistent with packet-engine reset/mode disturbance, not a controlled link gate. Do not spend another boot on random 0x09c masks unless it is inside a broader descriptor-path test.

4. Deeper Ghidra territory: only side paths, not likely init blockers.

I checked the extra callees around the MTS control path. Interesting but not a missing pre-link MAC init:
- `FUN_ffffffffc85f0130`: just lock, `mts_init_rings_kick`, unlock.
- `FUN_ffffffffc85f0190`: `gbe:ctrl` body; initializes/resumes, calls `FUN_ffffffffc85f1e80`, then event loop. On event bit 2 it calls management-frame function and clears BAR+0x54 bit 0x1000.
- `FUN_ffffffffc85ef7d0`: ioctl-ish media/PHY control; touches MDIO and `mts_link_change`, not new BAR init.
- `FUN_ffffffffc85f2250`: sends 0xfa42 frames, then updates switch PHY status via MDIO reads.

So Q4’s “did we miss a function between attach and link-up?” answer is: probably no, not a MAC-register one. The missing thing is either hardware state before Linux owns the device, descriptor side effects, or physical partner/signaling.

## Recommendation

Recommended next experiment on hardware: revert to v89 baseline, then do hardware swap first (different cable + dumb switch/router port). If still no BAR+0x04 bit 0, stop register poking and either implement Phase 3 real descriptors or invest in a working-Orbis BAR trace. The clever shortcut phase is over.
