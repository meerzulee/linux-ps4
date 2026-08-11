# Patch provenance

Snapshot date: 2026-08-11

The release is intentionally patch-based. Linux is cloned from an immutable
upstream tag, and PS4 changes remain reviewable instead of hiding inside a
whole-kernel fork.

## Baselines and source trees

| Role | Exact source |
|---|---|
| Linux base | [`gregkh/linux` v6.18.44 at `1efe5d048a391de3ead2804b2e7f86376c356cc5`](https://github.com/gregkh/linux/tree/1efe5d048a391de3ead2804b2e7f86376c356cc5) |
| Initial 6.x forward port | [`crashniels/linux`, `ps4-linux-6.15.y-baikal` at `b3b6b1e4fe8754482186f1d894a8eda431dbcd05`](https://github.com/crashniels/linux/commit/b3b6b1e4fe8754482186f1d894a8eda431dbcd05) |
| Current Baikal comparison | [`rmuxnet/linux`, `baikal/7.0.8-Stable` at `d8cbb8e912f59c352479f1158103e8ce7b6ca8c4`](https://github.com/rmuxnet/linux/tree/d8cbb8e912f59c352479f1158103e8ce7b6ca8c4) |
| Older Baikal and MT7668 reference | [`feeRnt/ps4-linux-12xx`, `5.4.247-baikal-dfaus` at `1fdfbd9a4c5690602893f6d5f65e154c6d9ba711`](https://github.com/feeRnt/ps4-linux-12xx/tree/1fdfbd9a4c5690602893f6d5f65e154c6d9ba711) |

The crashniels tree supplied the starting x86 platform, PS4 southbridge,
graphics, AHCI/SDHCI, xHCI, thermal, IOMMU, and MSI forward ports. They were
then rebased and adapted to the 6.18 APIs in this repository. “Source” does not
mean a patch was copied without changes; local patch headers and git history
must be consulted for adaptations.

## Exact wireless and xHCI imports

| Area | Immutable source | Local use |
|---|---|---|
| MT7668 vendor tree | [`feeRnt` 5.4 Baikal tree at `1fdfbd9a4c5690602893f6d5f65e154c6d9ba711`](https://github.com/feeRnt/ps4-linux-12xx/tree/1fdfbd9a4c5690602893f6d5f65e154c6d9ba711/drivers/net/wireless/mediatek/mt76x8) | Imported with original per-file license headers, then forward-ported |
| MT7668 `dev_addr` adaptation | [`c46339880113ef935c10dd1f781c4bcf7df621fc`](https://github.com/feeRnt/ps4-linux-12xx/commit/c46339880113ef935c10dd1f781c4bcf7df621fc) | Preserved as an authored patch |
| MT7668 timer/tx-power adaptation | [`ec88cc9699fd4f35bd4145b8d4ea8b7947b4b738`](https://github.com/rmuxnet/linux/commit/ec88cc9699fd4f35bd4145b8d4ea8b7947b4b738) | Preserved as an authored patch |
| Disable MT7668 power saving on PS4 | [`a30953ce2d1c0f7fdf78e55f4deba64f5cbf5d1a`](https://github.com/rmuxnet/linux/commit/a30953ce2d1c0f7fdf78e55f4deba64f5cbf5d1a) | Preserved as an authored patch |
| Fortified MT7668 userspace-copy fix | [`2a5e792097d550be08e239da8b0741465746d265`](https://github.com/rmuxnet/linux/commit/2a5e792097d550be08e239da8b0741465746d265) | Preserved as an authored patch |
| Baikal xHCI shutdown condition | [`b0969f7d101f89cfe6f60c42d607aff9d35b142a`](https://github.com/feeRnt/ps4-linux-12xx/commit/b0969f7d101f89cfe6f60c42d607aff9d35b142a) | Forward-ported with original author recorded |

## Exact rmux changes used or consulted

| Area | Source commit | How it is used here |
|---|---|---|
| Southbridge/MSI and Sony PCI filtering | [`19ec7f4d1d9af199ec93ad6be8e635b38f735b86`](https://github.com/rmuxnet/ps4-linux-12xx/commit/19ec7f4d1d9af199ec93ad6be8e635b38f735b86) | MSI code adapted to 6.18; the phantom-device filter is gated to PS4 hardware |
| Current Baikal AHCI, SATA PHY, SDHCI and xHCI IRQ path | [`a827d7936c44e672138f269297965817f2e2a8f4`](https://github.com/rmuxnet/ps4-linux-12xx/commit/a827d7936c44e672138f269297965817f2e2a8f4) | Ported selectively; AHCI uses the valid `0x7fffffff` DMA boundary and Baikal PCI-ID gates |
| Revert experimental per-subfunction MSI allocation | [`0ffd91bf838b2cef8dfaf83e00574322d769d383`](https://github.com/rmuxnet/ps4-linux-12xx/commit/0ffd91bf838b2cef8dfaf83e00574322d769d383) | Used to reject the obsolete local MSI experiment chain |
| Baikal coherent-DMA handling | [`d5e2c79bffe4be6a48d34eaca07139c82a629434`](https://github.com/rmuxnet/ps4-linux-12xx/commit/d5e2c79bffe4be6a48d34eaca07139c82a629434) | Narrowly gated IOMMU/DMA adaptation |
| Wider IOMMU comparison point | [`c4e7f040d08f37e2cedac4920183913aac242556`](https://github.com/rmuxnet/ps4-linux-12xx/commit/c4e7f040d08f37e2cedac4920183913aac242556) | Compared while auditing the current IOMMU path; not represented as a verbatim patch |
| Liverpool display comparison | [`c9e16f3ad2591c5e35fbe1fb81f02a8e799775ac`](https://github.com/rmuxnet/ps4-linux-12xx/commit/c9e16f3ad2591c5e35fbe1fb81f02a8e799775ac) | Used as a modern comparison, while preserving the hardware-tested local HDMI path |
| Explicit xHCI settle delay | [`6513cc8e3f7ac011a0f5c8a5a0d1716371ed03ed`](https://github.com/rmuxnet/ps4-linux-12xx/commit/6513cc8e3f7ac011a0f5c8a5a0d1716371ed03ed) | Replaces a timing-dependent `printk` delay with `usleep_range` |
| Older xHCI timing work | [`f6cf0e0de15d49ca5b54de536dcf6b6865d49a14`](https://github.com/rmuxnet/ps4-linux-12xx/commit/f6cf0e0de15d49ca5b54de536dcf6b6865d49a14) | Source of the retained, hardware-backed Baikal settle sequence |
| Liverpool MSI requirement | [`732f6ec470af3e66fa1e05b73bcf99cae4d41b16`](https://github.com/rmuxnet/ps4-linux-12xx/commit/732f6ec470af3e66fa1e05b73bcf99cae4d41b16) | Compared with and cited by the local GPU MSI patch |

## Local hardware-backed work

These commits are public evidence from this repository rather than anonymous
claims:

- [IRQ 9 / ACPI fix](https://github.com/meerzulee/linux-ps4/commit/e01ef2188818ba511120f7f6b2d7e86a9eebacd0)
- [Baikal xHCI development milestone](https://github.com/meerzulee/linux-ps4/commit/671128be35a5ab978c653482ac03807a72088edb)
- [HDMI v60 milestone](https://github.com/meerzulee/linux-ps4/commit/f5aea5d4d442d3227039d5bd0e7acb05aa4b01c7)
- [MT7668 hardware milestone](https://github.com/meerzulee/linux-ps4/commit/4311cddd0a9dbabf94978e6ea4056af9a18c160a)
- [Hyprland/OpenGL hardware evidence on the earlier 6.15 experiment line](https://github.com/meerzulee/linux-ps4/commit/82acaf447e8e976ddc2cc4b93b743bdf99b2c962)
- [`sky2` experiment closed after no working TX](https://github.com/meerzulee/linux-ps4/commit/4ec638d8462e7ba6189e62f2be32da74990590fc)

The Hyprland result proves that it can render on this Baikal console under a
particular experimental 6.15 stack. It does not prove this clean 6.18 target,
portals, audio, suspend, or a supported Omarchy product.

The local 6.18 patch
`0034-amdgpu-ps4-bridge-devm-lifetime.patch` was independently derived from
Linux v6.18.44's own `drm_bridge.c` after hardware experiment
`EXP-20260810-001-A25` exposed the exact static-object kref corruption guarded
by that API. A later full comparison found that rmux had already implemented
the same core managed-lifetime pattern in commit
[`3a8f6997c56b64321f3ced03886a2dda69835cb6`](https://github.com/rmuxnet/linux/commit/3a8f6997c56b64321f3ced03886a2dda69835cb6):
`devm_drm_bridge_alloc()`, `devm_drm_bridge_add()`, and clearing the pointer
global during teardown. The A29 artifact remains an independently authored
adaptation, but rmux's prior implementation is now explicitly credited. The
patch file itself is frozen with the already-built A29 series hash; update its
header at the next source-changing candidate rather than silently invalidating
the recorded artifact manifest.

The post-A28 patch
`0035-amdgpu-ps4-bridge-cq-lane-diagnostics.patch` is also local work, not an
rmux patch. It adapts the repository's hardware-tested v55/v60 UART
instrumentation to the valid post-0034 bridge pointer and deliberately leaves
the functional command sequence monolithic. Its patch header links both the
immutable local v60 milestone and the rmux Liverpool comparison commit. The
archived v55 split patch remains disabled because it does not apply cleanly
after the Linux 6.18 bridge-lifetime adaptation.

## Release policy

- Keep source URLs and immutable commit IDs in patch headers or this ledger.
- Never represent comparison code as verbatim provenance.
- Keep experiments in the repository when historically useful, but comment
  them out of `series` until hardware evidence supports them.
- A successful compile is not hardware validation.
- Do not redistribute proprietary PS4 firmware or per-console keys.
- Release manifests record both `series_sha256` and `patchset_sha256`. The
  latter hashes each active patch's content together with its ordered path, so
  editing a patch header or hunk changes the build identity.
