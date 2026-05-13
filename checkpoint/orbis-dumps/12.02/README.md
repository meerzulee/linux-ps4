# Orbis 12.02 kernel.elf dumps

Each PS4 boot has independent KASLR — the kernel image is identical
(same layout, same offsets) but the base virtual address slides per
boot.  Files are tagged with the boot's kbase so we can tell them
apart.

| File | kbase | Size | Status | Notes |
|------|-------|------|--------|-------|
| `kernel-boot-9ca88000-partial-999kb.elf` | `0xffffffff9ca88000` | 999424 B | partial (wedged at chunk 244) | 2026-05-13 evening, before bar-dumper attempt; kernel-dumper-hdd hung in copyout at offset 0xF4000 |
| `kernel-boot-9cb70000-partial-1720kb.elf` | `0xffffffff9cb70000` | 1720320 B | partial (wedged) | Earlier boot, same problem at a different offset |

## Full kernel.elf for Ghidra RE

The complete May 11 dump (the source the agents
hermes/glm/kimi/deepseek used to find the MTS softc offset
`kbase + 0x021f4938`) lives at:

```
checkpoint/docs/research/orbis-kernel/orbis-12.02.elf
```

- kbase `0xffffffffc839c000`
- 44 MB (full text + data segments)
- Entry `0xffffffffc8406410`

For any reverse-engineering of MTS / NIC code paths, use **this** file.
The partial dumps above are only useful for confirming the per-boot
kbase + verifying that the softc offset math still lands inside the
kernel's RW data segment.

## Why the partial dumps wedge

The Scene-Collective kernel-dumper does a blind linear sweep across
the kernel text segment: `for each 4KB chunk: get_memory_dump(kbase+pos)
-> copyout`.  On both partial-dump boots (`9ca88000` and `9cb70000`)
the copyout call hung non-interruptibly on a specific page — likely
a vm_object whose busy bit was set by another kernel thread, or
similar VM lock contention.

The hung kexec thread holds a global lock; SceShellCore subsequently
reports "Main thread has frozen in sceKernelUsleep(100*1000) for N
seconds" as the scheduler degrades.  No recovery short of
power-cycle.

**Don't run the kernel-dumper before any other payload on this FW.**
Use the May 11 full dump for RE; use `orbis-bar-dumper-hdd.bin`
directly for live BAR snapshots — it has bounded safety checks and
won't wedge on bad addresses.
