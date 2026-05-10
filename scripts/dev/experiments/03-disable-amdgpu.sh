#!/usr/bin/env bash
# Experiment 3 — actually disable amdgpu (Kconfig OR module param)
#
# Hypothesis: 6.x hangs in DRM/amdgpu Liverpool init. The morning's
# `modprobe.blacklist=amdgpu` test was a no-op because amdgpu is
# CONFIG_DRM_AMDGPU=y (built-in), and modprobe.blacklist only affects
# loadable modules.
#
# This script offers two ways to actually disable it:
#
#   --modeset-off    : kexec-test current build with cmdline
#                      `amdgpu.modeset=0 nofb video=efifb:off`. Works
#                      for built-in drivers; module's modeset path is
#                      bypassed but driver still loads.
#
#   --rebuild        : flip CONFIG_DRM_AMDGPU=n in our 6.x config,
#                      rebuild, kexec-test. Driver is excluded from
#                      the kernel image entirely.
#
# Cost: 1 chain.
# Yield:
#   - boots with --modeset-off → DRM modeset is the cause. Look at
#     ps4_bridge.c, atomic helper, mode_valid().
#   - boots with --rebuild but not --modeset-off → driver init (not
#     modeset) is the issue.
#   - hangs both ways → DRM is NOT the cause. Move on to another
#     hypothesis.
set -euo pipefail
cd "$(dirname "$0")/../../.."

mode="${1:---modeset-off}"
BZ="output/6.x-baikal/bzImage"
INITRD="checkpoint/boot/initramfs.cpio.gz"

case "$mode" in
  --modeset-off)
    [[ -f "$BZ" ]] || { echo "[x] $BZ not found. Run: ./build.sh -t 6.x-baikal"; exit 1; }
    echo "[*] Mode: amdgpu.modeset=0 + nofb + initcall_debug"
    bash scripts/dev/kexec-test.sh "$BZ" \
      --initrd "$INITRD" \
      --cmdline "amdgpu.modeset=0 nofb video=efifb:off initcall_debug ignore_loglevel"
    ;;
  --rebuild)
    echo "[*] Mode: rebuild with CONFIG_DRM_AMDGPU=n"
    cfg=config/6.x-baikal.config
    cp "$cfg" "$cfg.bak.$(date +%H%M%S)"
    sed -i \
        -e 's/^CONFIG_DRM_AMDGPU=.*/# CONFIG_DRM_AMDGPU is not set/' \
        -e 's/^CONFIG_DRM_AMDGPU_CIK=.*/# CONFIG_DRM_AMDGPU_CIK is not set/' \
        -e 's/^CONFIG_DRM_AMDGPU_SI=.*/# CONFIG_DRM_AMDGPU_SI is not set/' \
        "$cfg"
    grep -E 'DRM_AMDGPU|DRM_RADEON' "$cfg" || true
    echo "[*] ./build.sh -t 6.x-baikal -c"
    ./build.sh -t 6.x-baikal -c
    echo
    echo "[+] Rebuilt without amdgpu. To test:"
    echo "    bash scripts/dev/kexec-test.sh $BZ \\"
    echo "      --initrd $INITRD \\"
    echo "      --cmdline 'initcall_debug ignore_loglevel'"
    echo
    echo "[!] When done, restore the config:"
    echo "    cp $cfg.bak.* $cfg && ./build.sh -t 6.x-baikal -c"
    ;;
  *)
    echo "Usage: $0 [--modeset-off | --rebuild]" >&2
    exit 1
    ;;
esac
