#!/usr/bin/env bash
# Experiment 5 — patch group bisection
#
# Hypothesis: one specific patch group in our 6.x series introduces
# the regression. Find which one by applying groups incrementally
# and testing each step.
#
# Method:
#   1. Generate a temporary `series` file containing only group 0100.
#   2. Run ./build.sh -t 6.x-baikal -c (clean build).
#   3. Copy result to output/bisect/bzImage-<groups>.
#   4. (Optional) test with kexec-test.
#   5. Add next group, repeat.
#
# This script automates steps 1–3 in a loop; step 4 is manual because
# it costs chains. You can build all candidates first, then test the
# specific ones you suspect.
#
# Cost:
#   - Build phase: ~3 min × N groups, no chains.
#   - Test phase: 1 chain per built bzImage you actually kexec-test.
#     With smart ordering you typically need 2–3 tests.
#
# Yield: definitively identifies which group's addition breaks the boot.
#
# Usage:
#   05-bisect-patches.sh build              # build all candidates
#   05-bisect-patches.sh build 0100 0200    # only specific groups
#   05-bisect-patches.sh list               # show what's been built
set -euo pipefail
cd "$(dirname "$0")/../../.."

ACTION="${1:-build}"

SERIES="patches/6.x-baikal/series"
ORIG_SERIES="$SERIES.bisect-orig"
OUT_BASE="output/bisect"

# Default groups, in apply order. If you pass args after `build`,
# only those groups are accumulated.
DEFAULT_GROUPS=(0100 0200 0300 0400 0500 0700 0800 0900 1000 1100)

usage() {
  echo "Usage: $0 build [GROUP_PREFIX...]"
  echo "       $0 list"
  exit 1
}

build_one() {
  local upto="$1"
  local label="$2"
  local outdir="$OUT_BASE/$label"

  if [[ -f "$outdir/bzImage" ]]; then
    echo "[*] Already built: $outdir/bzImage. Skipping."
    return
  fi

  mkdir -p "$outdir"
  echo "================================================================"
  echo " Building bisect step: include groups up to $upto  →  $label"
  echo "================================================================"

  # Generate trimmed series.
  awk -v upto="$upto" '
    /^# /                  { print; next }
    /^[[:space:]]*$/       { print; next }
    /^([0-9]{4})-/ {
      group = substr($1, 1, 4)
      if (group <= upto) print
      next
    }
    { print }
  ' "$ORIG_SERIES" > "$SERIES.tmp"

  cp "$SERIES.tmp" "$SERIES"

  # Clean rebuild.
  ./build.sh -t 6.x-baikal -c

  cp -v output/6.x-baikal/bzImage "$outdir/bzImage"
  cp -v output/6.x-baikal/config  "$outdir/config"
  echo "$label" > "$outdir/label.txt"
}

case "$ACTION" in
  build)
    shift || true
    [[ -f "$SERIES" ]] || { echo "[x] $SERIES not found"; exit 1; }
    [[ -f "$ORIG_SERIES" ]] || cp "$SERIES" "$ORIG_SERIES"

    if [[ $# -eq 0 ]]; then
      groups=("${DEFAULT_GROUPS[@]}")
    else
      groups=("$@")
    fi

    label_acc=""
    for g in "${groups[@]}"; do
      label_acc="${label_acc:+${label_acc}-}${g}"
      build_one "$g" "$label_acc"
    done

    # Restore canonical series so subsequent normal builds work.
    cp "$ORIG_SERIES" "$SERIES"
    echo
    echo "[+] Bisect builds done. Restored canonical series."
    echo "[+] Outputs:"
    ls -la "$OUT_BASE"/*/bzImage 2>/dev/null || true
    ;;

  list)
    echo "Bisect builds available:"
    ls -la "$OUT_BASE"/*/bzImage 2>/dev/null || echo "  (none yet — run: $0 build)"
    ;;

  *)
    usage
    ;;
esac

echo
echo "To test a specific bisect step:"
echo "  bash scripts/dev/kexec-test.sh $OUT_BASE/<label>/bzImage \\"
echo "    --initrd checkpoint/boot/initramfs.cpio.gz \\"
echo "    --cmdline 'initcall_debug ignore_loglevel'"
echo
echo "Recommended bisect order (test these, in order):"
echo "  1. $OUT_BASE/0100-0200/bzImage             # baseline"
echo "  2. $OUT_BASE/0100-0200-0300/bzImage         # adds GPU"
echo "  3. $OUT_BASE/0100-0200-0300-0400-...-1000/bzImage  # adds IOMMU"
echo "  4. all groups (full build)                  # control"
