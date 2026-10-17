# Baikal MTS PHY handoff: first bidirectional packet proof

On 2026-10-17, EXP-20261017-012 cleared an inherited PHY link-status override and
EXP-20261017-013 passed one bidirectional diagnostic packet exchange without rebooting.
This is experimental evidence for Sony `104d:90d8` on the tested Baikal system,
PHY 0 ID `03a29441`, page 0, kernel `6.18.44-ps4-baikal` and Orbis 12.02 handoff.
It does not promote normal Ethernet support.

## Observed handoff state and correction

Native suspend/shutdown writes PHY MMD 30 register `0147` to `0010`. The Linux
handoff inherited exactly that value. BMCR was `1040`, both BMSR reads were `7969`,
and MAC PHY control/status atBAR0+04 was `b18`: reported link down, despite
the peer reporting1000/full carrier and previous receive-DMA evidence.

The tested correction changes only `0147` from `0010` to `0000`. It writes no
advertisement, autoneg restart, forced-up value `0018`, MAC mode or DMA address.
Readback became `0000`, both BMSR reads became `796d` and MAC04 became `b19`. The
peer stayed carrier1/1000/full in all 158 observations across eight seconds.
Wi-Fi SSH and the desktop remained available.

Linux's MediaTek PHY driver identifies03a29441 as MT7531 PHY:

https://github.com/torvalds/linux/blob/master/drivers/net/phy/mediatek/mtk-ge.c

A MediaTek-authored driver for different PHY IDs names bits 4/3 of MMD 30:0147
as link-status bypass/force controls. Those cross-generation names supplied
the hypothesis; the observed Baikal state transition supplies the direct
evidence here. Do not replay that other driver's initialization or firmware
download sequence.

https://lists.u-boot-project.org/pipermail/u-boot/2025-August/597321.html

## Native MDIO transport contract

These are native hardware Clause45 commands, rather than Clause22
MMD-control/data-register emulation. PHY address0 is fixed in the tested code.

| Operation | BAR0+00 command after completion-clear `8000` |
| --- | --- |
| Clause22 register read | `4000 | ((reg & 1f) << 8)` |
| MMD 30:0147 address phase | `01471e20` |
| MMD 30 data read | `00001ee0` |
| MMD 30 data write | `(value << 16) | 00001e60` |

Poll completion bit 15 until set, reject all-ones MMIO, stop on timeout and
do not issue a later phase after failure. Read data from bits 31:16; the
native extended-read path performs an additional read after completion.
The experiment used a 10 ms deadline per phase and a nominal 50 × 100 ms MAC-link
observation window, within an overall 30 s bound. Native timing and the test's
Linux scheduling are not identical contracts.

Before the setting write, the experiment freshly required the expected PHY
identity/page, BMCR/BMSR,`0147=0010`, stopped TX/RX controls, mask `7ffffa`,
closed routing gate and exact device/owner/boot state. A timeout can leave
the setting write committed; the experiment performs no automatic restore.
Reading BMSR consumes latch history; preserve both samples.

## Packet proof and limits

EXP-20261017-013 preserved the failed EXP-20261017-007 descriptor/publication/ownership/enable/
kick/poll/stop order and used separate retained buffers on the restored link.
It observed TX completion 1, the exact fresh 60-byte nonce frame at the peer,
a matching 60-byte reply in PS4 RX memory, stopack 1 and errors 0. The 176-byte
PCAP was independently checked against both reconstructed frames. Only the
target RX match establishes reply delivery; peer injection alone does not.

New DMA addresses and resetless generation replacement remain causal
confounders. The results strongly implicate the inherited override as a
missing prerequisite, without proving it was the exclusive historical TX
cause. Both experiments had completed UART continuity. Full private receipts
are in workspace `lab/ethernet-link-restore-2026-10-17/` and
`lab/ethernet-sameboot-tx-2026-10-17/`; curated records are the sibling
Omarchy `experiments/SESSIONS.md`, EXP-20261017-012 and EXP-20261017-013.

On that experimental boot, both packet modules and all old/new DMA backing,
mappings, code and references were retained until the next boot. Stop acknowledgement is not proof of transaction drain.
The four ring-register writes are sequential, not atomic; retention does
not establish mixed-generation DMA safety. Do not unload, clear the retained
override, rearm or reuse those buffers on the live experimental boot.

## Source and integration

Reviewed GPL PHY and packet experiment snapshots live in
[`experiments/baikal-mts/`](../experiments/baikal-mts/README.md). Those snapshots
are excluded from the normal build and are not a network driver; the newer
`netdev/` candidate in the same directory has a separate first network result
recorded below.
Sealed host-specific runners, binaries, raw logs and firmware remain private.
Native reference input was kernel 12.02 ELF SHA256
`55b4948df94aee193ebeb653bd40aff55b3cf09ac7741f58f3dadc239b29a0a2`;
the input is not included or needed to compile the original experimental code.

Integrate the correction inside MTS-owned PHY initialization, before DMA
publication, with identity/state checks and preservation of unrelated bits.
Unexpected identities or values need separate review. Keep the rejected
sky2 path disabled. Save a future real driver as an ordered target patch;
generated `src/` is not an authoritative change location.

## Follow-up: first Linux network-driver result

EXP-20261017-014 tested the [polling netdevice](../experiments/baikal-mts/netdev/README.md)
on a new Linux boot. It established the native stopped prerequisite before the
same PHY correction, then obtained DHCP and transferred4MiB each way with
independent SHA256 checks. TX3297/RX3039 completed, exercising12/11 full ring
laps, with zero reported drops/errors. Normal close acknowledged both engine
stop requests; all DMA/code/maps/references remain retained in the new module.
Completed UART continuity and both endpoint receipts support this limited pass.

This establishes first DHCP, unicast TCP, polling/NAPI and cyclic descriptor
reuse for the tested module. Repeatable cold boot, IRQ handling, link changes,
reset/recovery and safe DMA drain/free/remove remain unverified. The candidate
is excluded from the normal target; no release kernel support claim follows.
Curated record: sibling Omarchy `experiments/SESSIONS.md`, EXP-20261017-014.

## Follow-up: integrated kernel and modem network

EXP-20261017-015 passed on `6.18.44-ps4-baikal-mts1`, built from the isolated
`6.18-baikal-mts` target. Resolved configuration changed only LOCALVERSION
and PS4_MTS=m from the working baseline. The full matching module tree was
installed beside the old tree; only USB bzImage changed, with a complete
verified fallback preserved.

The modem assigned a private IPv4 address; IPv4 used Ethernet preferentially,
while the actual SSH peer retained a Wi-Fi host route. Hash-checked 4 MiB
each way and certificate-verified public HTTPS passed. TX3237/RX4417, zero
reported drops/errors, normal acknowledged close, preserved Wi-Fi/DNS/desktop
and completed UART continuity establish this bounded integration result.
The same MMD30:0147=0010→0000 prerequisite was observed again.

The candidate remains a 900-second, single-open polled module with published
DMA/code retained after close. That mts1 instance was left down and retained until the subsequent boot.
Continuous operation and ordinary lifecycle handling are the next code gate.
Private receipts: `lab/ethernet-kernel-2026-10-17/VERIFICATION.json` in the
workspace. Source contract: [candidate guide](BAIKAL-MTS-KERNEL-CANDIDATE.md).

## Follow-up: continuous mts2 and startup handoff

EXP016 boots `6.18.44-ps4-baikal-mts2` from the separate continuous target.
Modem DHCP, preferred wired IPv4, independent 4 MiB hashes each way, public
HTTPS and three ordinary NM profile reconnects passed with the same retained
DMA generation. An explicit administrative down/up also completed without a
driver fault; the test helper's address-removal guard failed and its strict
packet-gating result remains inconclusive. Preserve that failure rather than
counting source tests as a hardware pass.

The first boot exposed a userspace handoff gap: NM's early gate-closed UP was
refused, and opening the gate later did not cause NM to raise the interface.
The report was armed but never attempted/published. A single explicit first
link-UP while NM was blocked succeeded, then NM obtained the owned DHCP lease.
Package0.1.1 adds and positively verifies this step before returning management
to NM. It is installed; unattended startup needs a later fresh boot. No further
kernel change was required for that correction. The healthy generation later
survived beyond900seconds with further public TLS, wired SSH and completed
UART continuity; Ethernet remains preferred, Wi-Fi kept and temporary route
removed. Cable recovery remains pending and EXP016 is DEGRADED overall. Private records:
`lab/ethernet-normal-2026-10-17/`.
