# Proposal — all-in-one diagnostic harness

A design for running maximum diagnostic in one PS4 session ("chain")
while losing as little as possible to kexec failures.

**Status**: idea, not yet implemented. Capture here so we can pick it
up later or in a future session.

## The constraint

Each kexec experiment that **hangs** the kernel costs a PSFree chain
(~60% jailbreak success, 1–15 min depending on luck). Each kexec
that **boots** costs zero. We can't reliably sequence multiple kexec
tests because:

- We can't auto-detect "did 6.x boot to /bin/sh" without UART
  transmit working (currently broken — see [05-uart.md](../../../checkpoint/docs/study/05-uart.md)).
- A hung kernel can't kexec itself back to a known-good state.

So a naive "try every cmdline in sequence" doesn't work. But
**a phased structure does**.

## Three phases

```
Phase 0 — pre-flight on running 5.4 (zero risk, ~5 min)
Phase 1 — userspace hardware probes on running 5.4 (zero risk, ~10 min)
Phase 2 — one chained kexec test of 6.x (HIGH risk, ~3 min if hangs)
```

Phases 0+1 collect **everything the working 5.4 system tells us
about the hardware**, before risking phase 2. If phase 2 hangs, we
still have all phase 0+1 logs — they're saved to `/dev/sda2` which
survives any kexec failure. After recovery, tar + rsync to host,
analyze offline.

## Phase 0 — snapshot the working 5.4 reference

`scripts/dev/experiments/00-snapshot-5.4-reference.sh`

Saves to `/var/log/ps4-diag/<UTC-timestamp>/` on the PS4 rootfs:

| File | Source | Use |
|---|---|---|
| `dmesg.txt` | `dmesg -T` (full, not ring-truncated) | Reference 5.4 boot log to compare against 6.x partial UART. |
| `cmdline.txt` | `/proc/cmdline` | What cmdline the loader gave 5.4. |
| `cpuinfo.txt` | `/proc/cpuinfo` | Confirm Jaguar feature set. |
| `iomem.txt` | `/proc/iomem` | What MMIO regions are mapped to which device. |
| `interrupts.txt` | `/proc/interrupts` | IRQ → device mapping. |
| `ioports.txt` | `/proc/ioports` | Port I/O space (mostly empty on PS4). |
| `tty-serial.txt` | `/proc/tty/driver/serial` | ttyS-to-MMIO mapping; `tx_counter`/`rx_counter`. |
| `iommu/*` | `/sys/kernel/iommu_groups/*` | IOMMU groupings (if active). |
| `pci-vvxxx.txt` | `lspci -vvxxx` | Full PCI config space dump for every device. |
| `pci-tree.txt` | `lspci -tv` | Topology. |
| `pci-numeric.txt` | `lspci -nn` | Vendor/device IDs side-by-side with names. |
| `acpi-tables/` | `acpidump -o` (or copy of `/sys/firmware/acpi/tables/`) | ACPI tables verbatim. |
| `lsmod.txt` | `lsmod` | Loaded modules. |
| `modules-deps.txt` | `find /lib/modules/$(uname -r) -name '*.ko' | xargs modinfo` | What every module says about itself. |
| `bpcie-bar2.bin` | `dd if=/dev/mem bs=4 count=$((0x10000)) skip=$((0xC8800000/4))` | Raw register dump of BPCIe BAR2 region. |
| `liverpool-bar0.bin` | same idea for `00:01.0` BAR0 | Raw GPU register dump. |
| `dmidecode.txt` | `dmidecode` | SMBIOS info (mostly empty on PS4 but worth recording). |
| `sysctl.txt` | `sysctl -a` | Kernel tunables. |

Tar the directory at the end. Note: BAR dumps may panic if hardware
doesn't like blind reads — start with smaller/safer offsets and
expand only if needed. The MMIO read is the only "real" risk in this
phase; everything else is reading pseudo-files.

## Phase 1 — userspace hardware probes

`scripts/dev/experiments/01-userspace-probes.sh`

Builds on phase 0 with **active** probing — write to hardware,
observe behavior. Still on running 5.4, still zero risk to the
kernel.

- **`uartprobe-extended.py`**: write known sentinel bytes to BPCIe
  UART data registers. Read LSR. Walk through 16550 register space
  with mmap. Try to figure out what makes `tx_counter` actually
  increment (the broken-transmit mystery).
- **`bpftrace-trace.sh`**: attach probes to:
  - `serial8250_register_8250_port` — every UART registration
    captured with port struct contents.
  - `bpcie_uart_init`, `bpcie_uart_remove` — entry/exit + args.
  - `apcie_status`, `bpcie_status` — when each becomes ready.
  - `pci_enable_msi`, `msi_domain_alloc_irqs_descs_locked` — every
    MSI allocation request and result.
  - `iommu_dma_map_page`, `iommu_dma_unmap_page` — IOMMU activity.
  - Run for 60 seconds while doing normal activity (`ssh`, `ping`,
    `dd if=/dev/zero of=/tmp/test bs=1M count=100`).
- **`mt7668-sdio-probe.py`**: read SDHCI host registers via
  `/dev/mem` to understand what the WiFi card reports.
- **`bar-scan.py`**: for each PS4 PCI device, dump every BAR's
  first 4KB and look for register patterns / known constants.

Output: `/var/log/ps4-diag/<timestamp>/probes/`.

## Phase 2 — one chained kexec test (manual opt-in)

`scripts/dev/experiments/02-kexec-chain.sh`

Picks ONE 6.x candidate to test, with the highest expected
information yield. Default: current `output/6.x-baikal/bzImage`
with `initcall_debug ignore_loglevel debug printk.devkmsg=on`
appended to the inherited cmdline.

- Confirms phase 0+1 ran first (wants `/var/log/ps4-diag/<latest>/`
  to exist).
- Confirms `bzImage-stable` is current (rollback target valid).
- Asks for confirmation before firing.
- Fires the kexec.
- If 6.x boots → SSH in → snapshot its full dmesg and probes →
  optionally kexec back to 5.4 (requires 5.4 bzImage staged in
  `/tmp` first, AND 6.x to be alive enough to run kexec-tools —
  which assumes systemd is up).
- If 6.x hangs → exit. Phase 0+1 data is safe on sda2.

## Recovery / log retrieval

`scripts/dev/experiments/03-fetch-logs.sh` (host-side)

Run on host after either phase 2 succeeded or after a power-cycle
recovery. Fetches `/var/log/ps4-diag/<latest>/` to host
`logs/ps4-diag/<timestamp>/` for offline analysis.

## Orchestrator

`scripts/dev/experiments/run-all.sh`

```sh
run-all.sh phase0          # safe, run anytime on a booted 5.4
run-all.sh phase1          # also safe, builds on phase0 output
run-all.sh phase2          # WARNS, asks for confirmation, fires kexec
run-all.sh fetch           # rsync logs from PS4 to host
run-all.sh                 # interactive — asks at each phase boundary
```

Default flow: `phase0 → phase1 → asks before phase2 → fetch on
recovery`.

## Why this is worth building

- **Maximum information per chain.** Whatever phase 2 produces (boot
  log up to hang point), we now have a 5.4 reference to compare
  against. "6.x diverged at line N from the 5.4 reference" is a
  much more actionable observation than "6.x produced 120 lines
  then hung."
- **Phase 0+1 are reusable.** Every chain we burn produces a fresh
  phase 0+1 reference dataset. Compare across runs to see what
  drifts.
- **Phase 2 is opt-in.** No accidental chain spend. The orchestrator
  pauses and warns before firing the kexec.
- **Cross-tool data.** dmesg + bpftrace + raw register dumps + ACPI
  tables in one tar means future debugging doesn't require us to
  re-collect any of it.

## What this does NOT solve

- **6.x boot still requires chains.** Phases 0+1 give us reference
  data, not a fix for the hang. We still have to kexec and possibly
  burn chains.
- **No UART transmit fix.** That's still required for kgdb /
  reliable post-fbcon UART logs. Phase 1 may produce data that
  helps, but the fix itself is a kernel patch.

## Implementation order if/when we build this

1. `00-snapshot-5.4-reference.sh` — easiest, all reading. ~150 LOC bash.
2. `03-fetch-logs.sh` — trivial rsync wrapper. ~20 LOC.
3. `01-userspace-probes.sh` — moderate; needs uartprobe extension and
   bpftrace one-liners. ~300 LOC across multiple files.
4. `02-kexec-chain.sh` — wraps existing `kexec-test.sh` with the
   safety-confirmation prompts and pre-flight checks. ~80 LOC.
5. `run-all.sh` — orchestrator, ~50 LOC.

Total estimate: 1 day of host-side scripting work, no chains
required to develop. Test data starts flowing the next time PS4
is booted to known-good 5.4.
