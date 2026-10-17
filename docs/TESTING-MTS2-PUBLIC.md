# Public MTS2 kernel: advanced tester instructions

This experimental **PS4 Baikal B1** build is for testers who already have a
working Linux boot chain, a compatible root filesystem/initramfs, recovery
access and a UART logger. It is not a PS5 kernel or a universal PS4 installer.
The release is `6.18.44-ps4-baikal-mts2-public1`.
The kernel is distribution independent: Omarchy and the author's setup are
optional. Your distribution still needs compatible PS4 userspace, firmware
and boot support; see [Booting Linux on PS4](BOOTING.md).

The original MTS2 build passed IPv4 DHCP, wired routing, independent 4 MiB
transfers in both directions, public HTTPS, three NetworkManager reconnects
and traffic beyond 900 seconds on one console. That evidence belongs to the
original build. This public rebuild disables embedded firmware and has its
own kernel/configuration/module identities. Cable recovery, repeated cold
boots, strict administrative packet gating and this rebuild need acceptance.
See [the original evidence and limits](RELEASE-6.18.44-MTS2.md).

## Inputs and firmware

Use the matching release assets: `bzImage`, the complete matching module
archive, `config`, `ethernet-candidate.json`, boot-argument examples and checksums.
Full corresponding GPL source accompanies the release. Obtain release assets
from the repository's Releases page:

https://github.com/meerzulee/linux-ps4/releases

Verify the complete downloaded set before installing anything:

```sh
sha256sum -c SHA256SUMS
```

The public target sets `CONFIG_EXTRA_FIRMWARE=""`; its kernel contains no
embedded device-firmware payload. Supply required, lawfully obtained firmware
through your root filesystem **and compatible initramfs**. Drivers built into
the kernel may request firmware before the root filesystem is available;
this matters especially for built-in MediaTek Wi-Fi and firmware-selected
display EDID. A file present only on the root filesystem may be too late.
See [the firmware inventory](../firmware/README.md). The Ethernet implementation
does not contain Sony system firmware or proprietary driver code.

Choose your boot arguments explicitly. `bootargs-generic.example.txt` is an
example for a generic ext4 USB root labelled `PS4LINUX`; adapt it to your
loader, initramfs and root filesystem. `bootargs-omarchy.txt` is the separately
tested Omarchy profile for a FAT boot partition and ext4 root labelled
`OMARCHY-PS4`, with a compatible existing Omarchy initramfs. No default
`bootargs.txt` is selected for you. Neither profile supplies a loader,
initramfs or root filesystem, and no launcher PKG is installed. Keep internal
SATA disabled for this external-media test.

## Install a matching kernel/module pair

Back up the whole current boot set and preserve the complete old module tree
on another machine. Keep a tested recovery boot set. Install the **whole** new
module tree side by side; never replace the old release directory. On a
merged-/usr root filesystem, `/lib/modules` resolves to `/usr/lib/modules`, as
used below. Other layouts must install the tree where that distribution's
kmod expects it. Inspect archive paths before extracting a verified archive:

```sh
release=6.18.44-ps4-baikal-mts2-public1
tar --zstd -tf "modules-$release.tar.zst"
if [ -e "/usr/lib/modules/$release" ] || [ -L "/usr/lib/modules/$release" ]; then
  printf 'STOP: the new release already exists; preserve it and inspect.\n' >&2
else
  sudo tar --zstd --extract --file "modules-$release.tar.zst" --directory / --no-same-owner &&
    sudo depmod -a "$release"
fi
```

The archive must contain only the new `lib/modules/$release/` tree and its
parent directories. Do not proceed if the existing-release check fails.
Replace only the USB boot files required by your established boot procedure,
keeping the compatible initramfs, boot arguments and VRAM setting together.
Do not overwrite console-internal boot files or install a new launcher PKG
for this kernel test. A downloaded kernel alone does not update its modules.

Fully power off before the fresh test boot, particularly after an earlier
Ethernet experiment. Start continuous UART capture and one bounded experiment
session before changing boot files or starting that boot. Keep recovery Wi-Fi
or a local console available. Confirm:

```sh
uname -r
# 6.18.44-ps4-baikal-mts2-public1
```

## Optional NetworkManager activation

The kernel/driver has no NetworkManager or Omarchy dependency. This optional
standalone helper supports NetworkManager; other network managers need an
equivalent reviewed activation path respecting the same first-open gate and
positive-publication checks. Do not let another manager race a manual open.
No unpublished Omarchy package is required.

The helper needs `/usr/bin/python3`, kmod, iproute2 and NetworkManager. It
resolves `modprobe`, `modinfo`, `ip` and `nmcli` only through trusted,
root-controlled `/usr/bin`, `/usr/sbin`, `/bin` and `/sbin` paths; it supports
root-owned merged-/usr and kmod multicall symlinks. Its module check currently
uses the canonical `/usr/lib/modules` layout. It creates only its named
`PS4EthernetPublic.nmconnection` profile: DHCPv4, route metric 100, MTU 1500,
IPv6 disabled, inherited permanent MAC preserved. It does not enable startup.

Install the reviewed helper and matching release activation manifest in
root-owned locations. The helper checks every manifest/script ancestor for
root ownership and absence of group/other write permissions, so it refuses a
manifest left in an ordinary user's writable checkout or Downloads folder.

```sh
# From the directory containing the downloaded release assets:
sudo install -Dm755 ./activate-mts2-public /usr/local/sbin/activate-mts2-public
sudo install -Dm600 ethernet-candidate.json /root/mts2-public/ethernet-candidate.json
sudo /usr/local/sbin/activate-mts2-public --activate \
  --manifest /root/mts2-public/ethernet-candidate.json
```

Invoke it **once per boot**. Before publication it verifies the running kernel
configuration, installed/loaded module identity, Baikal glue binding, PCI/DMA
guards and inherited MAC. It blocks NetworkManager ownership/autoconnect,
checks that no competing automatic Ethernet profile can claim `psx0`, loads
its owned profile, arms the gate, performs exactly one explicit interface UP,
then checks positive publication, permanent pin, PHY/MAC contract and all four
non-overlapping DMA extents. Only then does it hand `psx0` to NetworkManager.
Carrier and DHCP remain asynchronous; activation can succeed while unplugged.

If it refuses a competing profile, inspect that profile yourself; the helper
does not disable or rewrite unrelated connections. If any command fails or
its outcome is uncertain, stop and preserve the report/UART. The attempt
marker prevents a second activation in that boot. Do not unload, reset, clear
driver overrides, rearm, or load old experiment modules. Published code,
memory and mappings remain retained until power-off; a stop acknowledgement
does not prove DMA drain. A fatal terminal fault requires a fresh power-off
and boot, rather than another UP attempt.

The helper is MIT-licensed, derived from Omarchy PS4's
`activate-baikal-ethernet`; its source contains the original copyright and
full permission notice. Kernel driver code remains GPL-2.0-only.

## Show that packets use Ethernet

```sh
# Optional, when using the NetworkManager helper:
nmcli device status
# Independent of the selected network manager:
ip -4 address show dev psx0
ip -4 route get 1.1.1.1
ip -s link show dev psx0
sudo cat /sys/module/psx_mts_net/parameters/report
curl --interface psx0 --noproxy '*' --fail --max-time 30 https://example.com/ -o /dev/null
ip -s link show dev psx0
```

The route result should name `psx0` for preferred wired IPv4 routing. The
interface-bound HTTPS request proves that request used Ethernet even if
recovery Wi-Fi remains connected. TX/RX counters should advance. The cached
driver report should show `continuous=1`, `lease_seconds=0`, `state=3`,
`published=self_pinned=engine_live=poll_enabled=1`, `admin_up=1`, carrier when
connected, and no error/terminal fault. Link state or an IP address alone is
not proof of bidirectional traffic.

For acceptance, record kernel/config/module hashes, console/southbridge model,
loader/initramfs identity, UART session continuity, DHCP/routing, independent
hash-checked transfers both ways, operation beyond 900 seconds, administrative
down/up, and cable recovery. Compare DMA addresses and the permanent reference
across cycles: they must not gain another generation. Ordinary DOWN closes
stack admission while the same engine continues completion/discard polling;
it does not physically power off the port or revoke already submitted TX.
Keep these observations distinct from untested unload, reset, suspend,
hot-remove, VLAN, bridge/promiscuous or wider-console support. Redact private
network identifiers and raw logs before posting a public report.
