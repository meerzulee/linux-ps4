# Linux 6.18 Baikal versus rmux Linux 7.0 Baikal

Snapshot: 2026-08-11

## Exact comparison points

- This repository: Linux `v6.18.44`, base commit
  `1efe5d048a391de3ead2804b2e7f86376c356cc5`, 53-patch A29 diagnostic
  series.
- rmux Baikal: branch `baikal/7.0.8-Stable`, commit
  `d8cbb8e912f59c352479f1158103e8ce7b6ca8c4`.
- rmux Aeolia/Belize: `zaebiz/7.1.7-Stable` at
  `d67b62838b413ba9ce49c61d73a314439e0cab67`; it is not the branch for this
  Baikal console.

The rmux Baikal branch head was unchanged from the prior project snapshot when
rechecked through Git on 2026-08-11. Its latest commit is the 2026-06-04 Baikal
Bluetooth merge.

## Important differences

| Area | Our 6.18.44 A29 | rmux Baikal 7.0.8 | Meaning |
|---|---|---|---|
| Distribution model | Immutable upstream LTS plus ordered patches and manifest | Full downstream kernel branch | Keep ours for auditable packaging; use rmux as the hardware reference |
| PCI resources | Requires tested `pci=nocrs` boot argument | Forces broken PS4 `_CRS` off in kernel | Equivalent goal; rmux does not depend on the operator argument |
| IOMMU | Uses `intremap=off` plus narrow 6.18 Baikal adaptations | Disables AMD IOMMU detection for family 16h Baikal | Different safety model; do not mix without an isolated boot |
| MSI/IRQ | Ports rmux MSI-parent/per-function programming but still needs BPCIE ICC polling; A28 logs `No irq handler for 0.227` | Native BPCIE MSI path gives immediate ICC replies | Our USB/root works, but IRQ parity is not complete |
| ICC | Poll fallback returns valid replies (`ret=20`) | Interrupt-driven completion | Polling is a working recovery path, not the final parity target |
| USB/xHCI | Kingston root enumerates and boots on real hardware | Reported working after Baikal MSI and IP-bit fixes | Both work for the current boot goal |
| AHCI/SATA | Current rmux-derived Baikal path is present; internal disk remains untested here | Internal HDD and BD drive reported, with a first-probe stale-MSI caveat | Test read-only only after display/recovery access |
| GPU firmware | Eight Liverpool blobs are supplied from initramfs and load successfully | GPU blobs are built into the kernel | Functionally similar for boot; provenance and redistribution remain separate |
| Bridge lifetime | A28-accepted 0034 uses a devm-managed bridge | rmux commit `3a8f6997` already used the same managed-lifetime pattern | Our implementation was independently derived from the 6.18 API, but rmux prior art must now be cited |
| EDID | Static `1920x1080.bin` exists and bootargs request it, but the PS4 connector returns a hardcoded mode before fallback firmware is consumed | Commit `5265b5b8` explicitly requests loader-provided `edid/my_edid.bin`, then tries DDC and fallback modes | This is the clearest meaningful display gap |
| Loader EDID | Present but unused by our bridge: loader v25 extracts Orbis `kern.edid` into a prepended firmware CPIO | Bridge consumes that exact loader-generated file | No new proprietary EDID blob is needed; the loader already provides the monitor's EDID |
| MN864729 sequence | Preserves firmware-trained TX by skipping destructive TX disable and enable; force-programs bridge at attach; retains added settle delays | Tracks enable state, retries video programming up to three times, removes several legacy delays, and retrains DP after bridge enable | These are competing strategies. v60 showed TX actions can destroy our lane lock, so do not bulk-copy rmux retraining |
| Mode handling | Forces preferred 1080p60/VIC 16 | Adds real EDID modes plus conservative 1080p60 and 720p60 fallbacks | Dynamic EDID is useful even if the current monitor is 1080p |
| Current HDMI result | fbcon and LightDM complete but physical display is backlight-black | rmux development log reports HDMI working on tested Baikal hardware | A29 register evidence must identify where the paths diverge |
| GPU robustness | Does not yet carry all late rmux GPU reset/clock reporting fixes | Skips ATOM ASIC init on Liverpool/Gladius reset and corrects reported clocks/VRAM type | Port after basic display, one change group at a time |
| Wi-Fi | MT7668 vendor driver and 6.18 API fixes build; hardware connection untested | MT7668 detected and driver reported working | Later XFCE acceptance item |
| Bluetooth | Generic/vendor support builds; Baikal runtime untested | Head includes Baikal Bluetooth fix `ad6107517` | Concrete later port candidate |
| Fan/LED/power/buzzer | Not yet accepted on this kernel; buzzer support absent | Fan hwmon, LED, power button, and buzzer drivers exist | Required before calling the desktop appliance-safe |
| Ethernet | Unsupported | Unsupported; DWMAC1000 BAR remapping remains open | No parity gap to chase yet |

## HDMI code findings

The rmux firmware-EDID commit is small and concrete:

- commit: `5265b5b86e7ef0098ce1c056d434f81c7639bb82`
- file: `drivers/gpu/drm/amd/amdgpu/ps4_bridge.c`
- request: `request_firmware("edid/my_edid.bin", ...)`
- parse: `drm_edid_alloc()`
- connector update: `drm_edid_connector_update()` and
  `drm_edid_connector_add_modes()`

Loader v25 already creates `lib/firmware/edid/my_edid.bin` from Orbis
`kern.edid` in `linux/ps4-kexec-common/firmware.c`. Our existing static EDID in
the initramfs is therefore not the best comparison to rmux: the meaningful
difference is that his bridge explicitly consumes the dynamically extracted
monitor EDID.

rmux's managed bridge lifetime also predates our A28 repair:

- commit: `3a8f6997c56b64321f3ced03886a2dda69835cb6`
- same core pattern: `devm_drm_bridge_alloc()`,
  `devm_drm_bridge_add()`, and a pointer global cleared during teardown

Our patch was written from the Linux 6.18 API warning and A25 hardware trace,
not copied from rmux. The newly identified equivalent implementation is still
prior art and is recorded here for transparent attribution.

## Recommended experiment order

1. Boot the already-built A29 diagnostic unchanged. It records bridge CQ time
   and `0x60f8`, `0x60f9`, `0x10f6`, and `0x7204` before and after enable.
2. If DP lane lock remains healthy and the bridge sequence completes but the
   monitor stays black, make one new 6.18 patch that ports only rmux's explicit
   `edid/my_edid.bin` consumption. Keep TX preservation and bridge programming
   unchanged for that boot.
3. If A29 shows lane lock loss, do not add EDID and retraining together.
   Compare the exact loss point with v60 first.
4. Test an independently built rmux 7.0.8 kernel as a control artifact only
   after its firmware/config/boot inputs are pinned. Do not replace our rollback
   kernel or mix its modules with the 6.18 root.
5. After HDMI is visible, port/test the rmux Bluetooth, GPU reset-reporting,
   fan/LED/power, and buzzer work in separate acceptance groups.

## Primary sources

- rmux branch:
  <https://github.com/rmuxnet/linux/tree/d8cbb8e912f59c352479f1158103e8ce7b6ca8c4>
- Baikal development log:
  <https://github.com/rmuxnet/linux/blob/d8cbb8e912f59c352479f1158103e8ce7b6ca8c4/BAIKAL_DEVLOG.md>
- firmware EDID:
  <https://github.com/rmuxnet/linux/commit/5265b5b86e7ef0098ce1c056d434f81c7639bb82>
- managed bridge implementation:
  <https://github.com/rmuxnet/linux/commit/3a8f6997c56b64321f3ced03886a2dda69835cb6>
- main Baikal GPU/display comparison:
  <https://github.com/rmuxnet/linux/commit/c9e16f3ad2591c5e35fbe1fb81f02a8e799775ac>
- Baikal MSI/platform integration:
  <https://github.com/rmuxnet/linux/commit/19ec7f4d1d9af199ec93ad6be8e635b38f735b86>
- Baikal AHCI/xHCI/SDHCI:
  <https://github.com/rmuxnet/linux/commit/a827d7936c44e672138f269297965817f2e2a8f4>
