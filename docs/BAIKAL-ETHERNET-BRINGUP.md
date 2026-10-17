# How Baikal Ethernet was brought up

This records the path from stalled transmit to working native Ethernet on one
PS4 Slim, Baikal B1, Orbis 12.02. The first integrated kernel was
`6.18.44-ps4-baikal-mts1`. Other revisions and ordinary driver lifecycle need
their own acceptance.

## RX evidence came before working TX

The early nonce harness returned TX-completed=0 and RX-reply-matched=0.
Stop acknowledged, but that did not establish DMA drain. We retained all
published memory and code. Later inspection found peer DHCP-shaped data in
RX buffers, supporting the owner's observation that receiving had made
progress while transmitting remained stalled. This was not yet a usable
Linux network interface.

The old `sky2` experiment had also failed to establish TX. The new driver
follows Baikal's native descriptor, ownership, enable, kick and stop sequence.
Generic MediaTek STAR code supplied a comparison, not a drop-in hardware
specification. RX recycling and engine resume also needed native handling.

## What ps4-re contributed

Private kernel scans and mappings located the native Ethernet routines and
their MDIO command encoding, PHY address, MMD sequence, MAC status reads and
DMA operations. Those offsets and call relationships gave us concrete things
to measure on hardware. They did not replace hardware tests.

The Linux patch is a locally authored implementation. Firmware, PUP files,
private mappings and raw binary-derived research remain local. Borrowed Linux
and platform code retains its provenance in
[PATCH-PROVENANCE.md](PATCH-PROVENANCE.md).

## The verified missing prerequisite

| Measurement | Before correction | After correction |
| --- | --- | --- |
| PHY ID / page | `03a29441` / `0` | unchanged |
| BMCR | `1040` | unchanged |
| PHY0 MMD30 register `0147` | `0010` | `0000` |
| BMSR | `7969` | `796d` |
| MAC register `+04` | `b18` | `b19` |

The local Linux correction clears bit 4 of that MMD register. The bounded
native-source audit found shutdown/suspend writes of `0010`, but no explicit
normal-initialization zero write. Orbis had left `0010` set in the measured
handoff. EXP-20261017-012 made the narrow `0010→0000`
correction and verified readback; the native link-status bit then became set.
No forced-speed BMCR write or autonegotiation restart was required for that
result. The driver establishes the tested masked/stopped controller state
before applying the correction.

This verifies a missing link prerequisite. It does not prove that this bit
alone caused every historical TX failure: the next packet test also used a
fresh, separately retained DMA generation, so allocation/handover changes
remain a causal qualification.

## Evidence ladder

| Experiment | Observation |
| --- | --- |
| EXP-20261017-002 | Initial TX failed; stop acknowledged, memory retained |
| EXP-20261017-003/004 | Peer RX data present; TX cursor remained at base |
| EXP-20261017-009/010/011 | Native link down; exact PHY and inherited MMD state measured |
| EXP-20261017-012 | MMD clear restored native link status |
| EXP-20261017-013 | TX completion, independently captured nonce and matched RX reply |
| EXP-20261017-014 | Linux netdevice DHCP and hash-checked 4 MiB TCP each way |
| EXP-20261017-015 | Integrated kernel, modem DHCP, preferred wired IPv4 and public HTTPS |

Some alternative candidates were built but never executed. Compilation,
agent agreement and a peer's injected reply alone were not counted as packet
acceptance. Full curated results, failures and retained state are in the
sibling Omarchy `experiments/SESSIONS.md`.

## Implementation and integrated result

`psx0` retains the console's inherited MAC. It uses 256 native descriptors
per ring, checked direct/coherent 32-bit DMA extents, persistent TX bounce
buffers, BQL accounting and NAPI driven by a 1 ms timer. Ownership barriers,
native pending-TX re-kick and RX recycle/resume are explicit. A self-reference
precedes address publication; published memory, mappings and code stay retained.

The isolated target reuses all 54 baseline patches plus one MTS patch. Its
resolved configuration changes only the release name and PS4_MTS=m. A first
build inherited unrelated netfilter settings and was quarantined unexecuted;
the deployed build preserved the working baseline's NETFILTER=n.

EXP015 obtained a private IPv4 address and gateway through modem DHCP and
preferred Ethernet over Wi-Fi. Before adding the second address, we pinned the actual
SSH peer through Wi-Fi. Both independent endpoints verified 4194304-byte
transfers with SHA256:

```text
e8f6a8bd582955eec815019d624dd43033657fe89af56bff7dd999e176314d89
```

Public HTTPS returned 200 with certificate verification and the wired source.
Final TX3237/RX4417 counters had zero reported drops/errors or pending TX.
Wi-Fi routes, DNS and Hyprland survived; peer resources were removed. UART
continuity completed, and a full-slice material-fault scan found no matches.

## Why the next patch changes lifecycle

The first driver allowed one bounded activation. Normal close stopped and
retained it; changing a flag cannot establish a safe hardware restart.
Stop acknowledgment still does not prove DMA drain.

The separate mts2 candidate now keeps one hardware/DMA generation per boot.
Normal down/up synchronizes CPU packet processing, gates stack TX/RX and
continues background reclaim/recycle without resetting rings or BQL. It
removes the test lease, monitors carrier and lets NetworkManager configure IPv4.
Terminal faults and shutdown retain the irreversible stop path. Admin cycles,
cable changes and operation past the old timer limits require new acceptance;
EXP015 is not a substitute. EXP016 installed and booted the new USB kernel
and complete module tree. Modem DHCP, preferred IPv4, independent 4 MiB hashes,
public HTTPS and three NM profile cycles passed. An additional administrative
down/up retained the same DMA generation, but its helper's address-removal
guard failed; strict packet-gating acceptance remains inconclusive.

That boot also found a userspace handoff bug: NM's early UP was refused by the
closed first-open gate; reopening management after arming did not cause another
UP. The report remained healthy PROBED/allowed1/attempted0/unpublished. One
explicit first-UP while NM was blocked succeeded. Activation package0.1.1 now
performs and positively verifies that step before NM management, without
waiting for carrier/DHCP or automatically retrying uncertainty. It is installed
for the next boot; unattended startup remains pending. This orchestration fix
needed no new kernel or additional DMA generation. Full results and remaining
qualifications are in EXP016; stable support claims remain unchanged.

Private receipts: `lab/ethernet-kernel-2026-10-17/VERIFICATION.json` and earlier
workspace experiment directories. Boot and rollback contract:
[BAIKAL-MTS-KERNEL-CANDIDATE.md](BAIKAL-MTS-KERNEL-CANDIDATE.md).
