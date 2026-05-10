# Experiments

Each script here is a self-contained experiment to learn something
about why 6.x hangs. They are ranked by **information yield per
PSFree chain**. Pick the cheapest one whose result you don't
already know.

Read [`checkpoint/docs/study/07-failure-analysis.md`](../../../checkpoint/docs/study/07-failure-analysis.md)
for the hypotheses these experiments distinguish between.

## Quick map

| # | Script | What it tests | Chains | When to use |
|---|--------|---------------|--------|-------------|
| 1 | `01-initcall-debug.sh` | Which initcall is the kernel hung in? | 1 | First. Always. The HDMI photo at hang time is the most informative single data point. |
| 2 | `02-build-crashniels-vanilla.sh` | Does crashniels' tree boot as-is? | 1 | If you suspect our patch slicing introduced a bug. |
| 3 | `03-disable-amdgpu.sh` | Is the GPU stack the cause of the hang? | 1 | After #1, if initcall debug points at amdgpu. |
| 4 | `04-iommu-off.sh` | Is MSI/IOMMU plumbing wrong on Baikal? | 1 | Top suspect per failure-analysis.md. |
| 5 | `05-bisect-patches.sh` | Which patch group's addition breaks 6.x? | 2–5 | When other tests don't pinpoint, run a real bisection. |
| 6 | `06-build-with-gcc14.sh` | Is GCC 15 a toolchain regression? | 1 | If everything else fails. Last suspect. |
| 7 | `07-uart-capture.sh` | (Process improvement) capture UART to file | 0 | Run BEFORE every other test. Compounds value. |

## Candidate patches (not auto-applied)

These live in `patches/{5.4,6.x}-baikal/` but are commented out in
`series`. To enable, uncomment the line and rebuild.

- `patches/6.x-baikal/0200-ps4-drivers/0003-ps4-bpcie-uart-port8250-variant.patch.candidate`
  — alternative bpcie-uart fix using `PORT_8250` instead of `PORT_16550A`. The
  PORT_16550A variant triple-faults at kexec on 6.x; the 8250 path skips the
  FIFO/auto-flow setup that may be breaking it.

- `patches/{5.4,6.x}-baikal/0200-ps4-drivers/0004-ps4-bpcie-uart-explicit-line-numbers.patch.candidate`
  — assigns ttyS4 ↔ UART0 explicitly. Without this, the 8250 driver auto-numbers
  and ttyS4 ends up on UART1 (which is the wrong cable). With this, `cat /dev/ttyS4`
  on the cable side actually yields the cable's UART.

To enable a candidate:

```sh
cp patches/6.x-baikal/0200-ps4-drivers/<file>.candidate \
   patches/6.x-baikal/0200-ps4-drivers/<file>
# Then add the line to patches/6.x-baikal/series (without "# " prefix)
./build.sh -t 6.x-baikal
```

## Long-running parallel work

- [`checkpoint/docs/study/08-mt7668-port-todo.md`](../../../checkpoint/docs/study/08-mt7668-port-todo.md)
  — port the MT7668 WiFi/BT vendor driver to 6.x APIs. ~1 day of compile-error
  whack-a-mole. Doable while waiting for PS4 boot tests. Zero chains.

## Proposals (not yet implemented)

- [`PROPOSAL-all-in-one-harness.md`](PROPOSAL-all-in-one-harness.md)
  — design for a 3-phase diagnostic harness that snapshots the working 5.4
  hardware state (zero risk), runs userspace hardware probes (zero risk),
  and ends with one opt-in kexec test. Phase 0+1 logs persist on
  rootfs even if phase 2 hangs the kernel. Read before starting any
  serious 6.x debug session — the reference dataset compounds value
  across all chains spent.

## Workflow

The recommended sequence for a 3-chain session:

1. Run `07-uart-capture.sh` in a separate terminal (host-side, no PS4 needed).
2. **Chain 1**: power-cycle, jailbreak, boot known-good 5.4. Run `01-initcall-debug.sh`.
3. Photograph HDMI at hang. Read which initcall hung.
4. **Chain 2**: based on initcall name, run `03-disable-amdgpu.sh` OR `04-iommu-off.sh` OR rebuild and re-test.
5. **Chain 3**: validate the fix.

After each successful boot, run `bash scripts/dev/mark-good.sh` to set the
new floor for rollback. Don't skip this — a single later failure wipes
your progress otherwise.
