# Capability tests

Tested system: PS4 Slim, Baikal B1 southbridge, firmware 12.02, Linux
`6.18.44-ps4-baikal`, external USB root.

Each row needs evidence from the same released kernel. `Working` means the
test passed; device enumeration alone is not enough.

| Area | Passive check | Functional check | State |
|---|---|---|---|
| CPU | all eight logical CPUs online; no cpufreq policy | two-second pinned load on every core; 60.5→61.0°C; no warning | Working smoke test |
| Memory | 6.8 GiB usable; no swap | bounded allocation test | Partial |
| GPU display | amdgpu bound; connector and mode visible | stable XFCE session at 1080p60 | Working |
| GPU acceleration | amdgpu, render node, radeonsi and direct rendering | `glxgears`: 59.17 FPS for eight seconds; no new warning | Working smoke test |
| Vulkan | RADV exposes the GPU and Vulkan 1.3 | `vkcube` rendered for eight seconds; no new warning | Working smoke test |
| External USB root | device, filesystem and mount options | bounded file read/write on the Linux partition | Working |
| Internal SATA | controller and disk enumerate | read-only health and timeout inspection | Degraded |
| Internal Wi-Fi | MT7668 driver and firmware loaded | association, DHCP and bounded network transfer | Working |
| Built-in Ethernet | driver and carrier state | DHCP and bounded transfer | Not working |
| HDMI audio | HDA, ALSA and PipeWire enumerate; direct PCM accepts stereo | five-second playback produced no audible sound | Partial |
| USB | Aeolia xHCI exposes four buses | external root, keyboard and mouse are active | Working |
| Bluetooth | MT7668 `hci0` and firmware are present | start BlueZ, bounded scan and DualShock 4 pairing | Partial |
| Temperature | `k10temp` exposes a credible value | 60.25→61.0°C across short GPU and CPU tests | Partial |
| Fan control | no fan RPM or PWM interface is visible | blocked | Not exposed |
| Shutdown | power-off path is exposed | clean shutdown with UART capture | Pending |
| Suspend/resume | `/sys/power/state` and `mem_sleep` are absent | blocked | Not supported |

## Experimental Ethernet update — 2026-10-17

A manually loaded [Baikal MTS polling module](../experiments/baikal-mts/netdev/README.md)
passed DHCP and4MiB TCP transfers in each direction in EXP-20261017-014, with
3297 TX/3039 RX packets, zero reported drops/errors and completed UART continuity.
This is one fresh-boot prototype result. The table above describes the standard
kernel artifact, which does not include this module. Repeated operation, IRQ,
link recovery and safe DMA teardown remain pending.

EXP-20261017-015 then passed the same bidirectional transfer gate plus modem
DHCP, preferred IPv4 default routing and certificate-verified public HTTPS on
the isolated `6.18.44-ps4-baikal-mts1` in-tree module candidate. Wi-Fi SSH,
DNS and the desktop recovered unchanged; UART continuity completed. See
[the candidate record](BAIKAL-MTS-KERNEL-CANDIDATE.md). Continuous operation,
ordinary reopen/unload and lifecycle acceptance remain separate gates.

The continuous `6.18.44-ps4-baikal-mts2` successor now has EXP016 transport
and three ordinary NM profile reconnect passes on that console. One explicit
administrative down/up reused the same DMA generation with no driver fault,
but a test-helper guard failed because NM preserved its address when made
unmanaged; strict packet-gating proof remains inconclusive. The first userspace
startup handoff required an explicit first link-UP, now implemented in the
installed activation package0.1.1. Further verified HTTPS after900seconds,
wired SSH and completed UART continuity passed, with the same DMA/refcount.
Automatic startup with that package and cable recovery remain pending;
EXP016 is DEGRADED overall, with no standard-target support promotion.

## Order

1. Run `scripts/dev/capability-report.sh` over SSH.
2. Confirm temperature and fan visibility before any sustained CPU or GPU load.
3. Test CPU and memory.
4. Test OpenGL, then Vulkan.
5. Test audio, USB and Bluetooth with human confirmation.
6. Test shutdown and suspend last, with a bounded UART capture.

Internal storage remains read-only throughout this process. One subsystem is
tested at a time, and kernel warnings are captured immediately after each test.
