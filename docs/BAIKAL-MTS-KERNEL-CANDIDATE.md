# Baikal MTS kernel candidate

`6.18-baikal-mts` integrates the experimental native Baikal Ethernet driver
as an in-tree module, `psx_mts_net.ko`. Its release is
`6.18.44-ps4-baikal-mts1`. This development candidate passed its first
bounded modem-network test in EXP-20261017-015. It does not promote Ethernet
support in the stable target.

The series reuses all 54 stable patches in their existing order and adds
`0700-network-mts/0001-net-ps4-add-experimental-polled-baikal-mts.patch`.
The resolved configuration differs from the working baseline only by the
release suffix and `CONFIG_PS4_MTS=m`. The new target deliberately omits
the inherited UFW fragment to preserve the baseline's `CONFIG_NETFILTER=n`.

The driver comes from the local EXP-20261017-014 implementation, which passed
DHCP and hash-checked 4 MiB TCP transfers in both directions on one Baikal B1
console. Integration changes only the compiled release guard and the fixed
lease from 180 to 900 seconds. The source remains a polled, single-open
experiment. There is no PCI module alias, automatic load, automatic network
activation, safe reopen or post-publication unload. After normal close,
module code and all published DMA allocations remain retained until power-off.
A stop acknowledgment does not prove DMA drain.

## Development USB override

The partitioned development initramfs has no kernel modules or release check.
Its existing boot arguments, initramfs and VRAM file can remain byte-identical
while testing a candidate kernel. Install the **whole matching module tree**
side by side under `/usr/lib/modules/6.18.44-ps4-baikal-mts1/`, then run depmod
for that release. Preserve the working kernel's module tree for Wi-Fi recovery
after rollback.

The loader searches independently for each of `bzImage`, `initramfs.cpio.gz`,
`bootargs.txt` and `vram.txt`, preferring USB files over console-internal files.
Provide all four at the FAT root and remove other boot USB media. Record a
complete candidate hash manifest even when only `bzImage` changes.

This is an intentional, experiment-scoped exception to the packaged boot-set
match rule. Leave the installed launcher, console-internal boot files and
existing `release.json` intact; that original metadata does not describe the
candidate override. Keep separate candidate metadata and complete backups of
the original four files plus `release.json`, both off-device and in a unique
FAT recovery directory. Verify stable disk/partition identities, free space,
all input hashes, the committed files and the final read-only FAT mount.
Do not run an initial installation or filesystem-formatting tool on this
populated system.

If the candidate cannot boot, fully shut down the console, move the unmounted
USB to the development host, and restore all four original FAT-root files
from the verified backup. Verify their hashes before another boot. The old
internal kernel cannot rescue a visible, incompatible USB override.

## Combined hardware gate

EXP-20261017-015 completed installation, a fresh boot, explicit gated driver
activation, modem DHCP, Ethernet-preferred IPv4 routing, hash-checked 4 MiB
LAN transfers in both directions, public HTTPS with normal certificate
validation, and cleanup. Preserve Wi-Fi, UART, the SSH peer's
explicit Wi-Fi host route, and the original DNS file. Restore the owned wired
default route before closing the driver. Any fault ends the attempt; never
rearm, reopen, unload or force cleanup after publication.

Record actual results in the sibling Omarchy experiment ledger. A successful
single boot or transfer remains first-pass evidence rather than repeatable
support or a throughput, interrupt, suspend, reset or teardown qualification.

The modem assigned a private IPv4 address and gateway for 86400 seconds.
The preferred IPv4 route used `psx0`, while an explicit Wi-Fi host route kept
the existing SSH session reachable. Both 4194304-byte LAN transfers matched
SHA256 `e8f6a8bd582955eec815019d624dd43033657fe89af56bff7dd999e176314d89`.
The public HTTPS request returned HTTP 200 with successful certificate
validation and the wired source address. Final counters were TX3237/RX4417,
with zero reported drops/errors or pending TX. Normal close acknowledged stop;
the interface was then down with all published DMA and module code retained.
Original Wi-Fi routing, DNS and Hyprland were preserved; the peer's temporary
listener/rule were removed. UART continuity completed, with no material fatal
signature found in the captured slice. This does not make the driver ready for
continuous networking or safe same-boot reopen/unload.

## Continuous successor: mts2

`6.18-baikal-mts2` builds `6.18.44-ps4-baikal-mts2` from the same baseline
and a separate ordered continuous-driver patch. It removes the fixed test
lease and keeps one hardware/DMA generation across normal administrative
down/up. CPU packet processing is joined during transitions; background
reclaim/recycle continues while administrative delivery/admission is gated.
Native carrier is sampled every 250 ms. Terminal faults still stop and retain
the instance irreversibly; safe unload, hardware reset and DMA drain remain
unqualified.

EXP-20261017-016 installed the full matching module tree beside both earlier
releases and verified every packaged file. Only USB bzImage changed; all five
current/recovery boot hashes and the final read-only mount were checked.
The earlier mts1 boot set is backed up on both development hosts. The resolved
config changes only LOCALVERSION and PS4_MTS=m relative to the accepted baseline.
Driver W=1 compilation and the full kernel build passed.

The separately reviewed `omarchy-ps4-ethernet` package supplies a pinned,
explicitly gated boot service and an owned NetworkManager DHCP profile with
the inherited MAC, IPv4 route metric100 and IPv6 disabled. The service is
conditioned on the exact mts2 release and was enabled without starting it on
the retained mts1 boot. It does not change the installed Omarchy launcher PKG.
The private local package was installed using a sealed per-command signature
configuration after its exact SHA256 was checked; the system pacman policy
was verified unchanged.

The fresh mts2 boot succeeded. The initial service handoff left a healthy,
armed but never-attempted interface DOWN: NM did not retry its early
gate-closed UP. One explicit first link-UP while NM was blocked succeeded;
NM then obtained modem DHCP and default metric100. Hash-checked 4 MiB each
way, public HTTPS and three ordinary profile reconnects passed. Package0.1.1
adds that first-UP step and verifies publication before NM handoff. It is
installed for future boots; its unattended startup is still pending.

An additional explicit admin-down/up kept the same DMA generation and no
driver fault. The private helper's no-address guard failed because setting
unmanaged preserved the IP; strict packet-gating acceptance is inconclusive.
The halted helper state is retained. A separately checked owned-profile UP
restored normal networking; the corrected future helper was not rerun.
The healthy generation survived beyond900 seconds; further verified HTTPS,
wired SSH and completed UART continuity passed. Ethernet remains enabled and
preferred, Wi-Fi recovery kept, with the temporary host route removed. Cable
recovery remains pending. EXP016 is DEGRADED overall; the previous EXP015 pass
does not qualify these lifecycle
changes. Private receipts remain in the workspace and are not required to
compile this kernel. The companion Omarchy activation package and detailed
distro integration are maintained separately and have not been published as
part of this kernel update. A kernel-only clone does not provide automatic
Ethernet activation. See [the boot guide](RELEASE-6.18.44-MTS2.md).
