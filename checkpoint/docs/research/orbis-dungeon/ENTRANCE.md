# 🚪 Entrance Hall — Orbis Kernel Boot Path

The first thing executed when the BTX bootloader transfers control to the
kernel. Three functions in a chain, then control hands to the SYSINIT
system (FreeBSD-inherited).

```
BTX bootloader (loader.efi)
       ↓ jmp to ELF entry
entry @ c8406410
       ↓ calls
setup_kernel_environment @ c85087a0
       ↓ returns kernel work area pointer
mi_startup @ c83e4170  (SYSINIT chain)
       ↓ runs every module's SYSINIT in order
[infinite idle loop]
```

---

## Function 1: `entry` @ `0xffffffffc8406410`

```c
void entry(void)
{
    _DAT_00000472 = 0x1234;                                 // BIOS warm-boot flag
                                                            // (skip POST on reboot)
    DAT_ffffffffc94bb810 = ...;                             // bootloader's "next address"
    lVar1 = setup_kernel_environment(unaff_retaddr, in_stack_00000008);
    *(undefined8 *)(lVar1 + -8) = ...;                      // bottom of kernel stack
    mi_startup();                                           // hand off to SYSINIT
    while (true) { /* never returns */ }
}
```

**What this does:**

1. Writes `0x1234` to physical address `0x40:0x72` (the legacy BIOS Data
   Area "warm-boot" flag — tells BIOS to skip POST on next reboot).
2. Reads boot parameters off the stack (BTX bootloader's args).
3. Calls `setup_kernel_environment` which builds the GDT/IDT, sets up
   per-CPU state, and returns a pointer to the kernel work area.
4. Stores that pointer as the kernel stack bottom.
5. Calls `mi_startup` — never returns.
6. Falls into an infinite loop if `mi_startup` ever did return.

---

## Function 2: `setup_kernel_environment` @ `0xffffffffc85087a0`

This is the **big one** — does all the architecture-level setup that
FreeBSD normally puts in `machdep.c::hammer_time()`.

### What it sets up

1. **Boot parameters from BTX**
   - `_DAT_0009bb4c` holds the BTX bootloader's `bootinfo` struct.
   - First fields: `(_DAT_0009bb4c & 0x3FFFFFFF)` is some count;
     `(_DAT_0009bb4c >> 0x1E)` is a divisor; together they describe
     the kernel's load address and its relocation.
   - The two values get combined into `DAT_ffffffffc9ec61c0` (kernel
     work area base) and `DAT_ffffffffc9ec6158` (per-CPU pointer).

2. **Module table lookup** — finds either `"elf kernel"` or
   `"elf64 kernel"` modulehandle. Hard error if neither is present.

3. **GDT (Global Descriptor Table)** — 16 entries built from
   `DAT_ffffffffc9ddd510` template. Each entry's bit-fields get
   shifted/ORed together; standard x86-64 segment descriptors with
   limit / base / type / DPL / G / D / L / AVL bits.

4. **GDT register** — `FUN_c8659c50(&DAT_ffffffffca550430)` loads GDT
   via `lgdt`.

5. **Segment-base MSRs**:
   - `wrmsr(0xc0000100, 0)` → IA32_FS_BASE = 0
   - `wrmsr(0xc0000101, 0xffffffffca550480)` → IA32_GS_BASE → per-CPU
   - `wrmsr(0xc0000102, 0)` → IA32_KERNEL_GS_BASE = 0

6. **Per-CPU GS_OFFSET layout** (offsets in 8-byte words):
   - `[0x00]` = kernel module list head
   - `[0x04]` = per-CPU work area
   - `[0x50]` = per-CPU TSS pointer
   - `[0x52..0x53]` = ?
   - `[0x57..0x5A]` = pointers into the per-CPU GDT entry slots
     (`+0x48`, `+0x58`, `+0x10`, `+0x18`)

7. **IDT (Interrupt Descriptor Table)** — 256 entries × 16 bytes = 4 KB.
   Each entry is populated from a template at `DAT_ffffffffc9ddd4f8`
   with bit-field shuffling identical to the GDT loop. Loaded with
   `InterruptDescriptorTableRegister(...)` (lidt).

8. **TSS (Task State Segment)** — loaded with `TaskRegister(0x48)`
   where `0x48` is the GDT selector for the TSS.

9. **EFER MSRs**:
   - `wrmsr(0xc0000080, ... | 1)` → SCE bit (SYSCALL/SYSRET enable)
   - `wrmsr(0xc0000082, 0xffffffffc839c1c0)` → LSTAR (SYSCALL entry)
   - `wrmsr(0xc0000083, 0xffffffffc855e280)` → CSTAR (compat SYSCALL)
   - `wrmsr(0xc0000081, 0x33002000000000)` → STAR (segment selectors)
   - `wrmsr(0xc0000084, 0x4701)` → FMASK (RFLAGS mask)

10. **CPU vendor check**:
    - `DAT_ffffffffca56ee5c == 0x1022` → **AMD** (vendor ID)
    - `(DAT_ffffffffca56ee80 & 0xf00) == 0xf00` → family ≥ F (long mode)
    - If both true: `DAT_ffffffffca549370 = 1` (some AMD-specific flag set)

11. **`kernelname` boot arg lookup** via `FUN_c83ca170("kernelname")` —
    reads from BTX environment, copies to `DAT_ffffffffc9dd7cf0` (up to
    1024 bytes).

12. Returns pointer to `DAT_ffffffffc9ec6158` (per-CPU work area).

### Sub-functions of interest

| Address | What | Equivalent in Linux/FreeBSD |
|---|---|---|
| `c86593c0` | memset/clear | `bzero()` |
| `c83e9da0` | SYSINIT table copy | static array init |
| `c85d6970` | module probe | `linker_init()` |
| `c85d6720(name)` | module-by-name lookup | `linker_find_class_by_name()` |
| `c85d67f0(modhandle, type)` | lookup linker file metadata | `linker_file_lookup_set()` |
| `c8785bf0` | early PCI / chipset detect | `cpu_startup()` |
| `c8659c50` | lgdt wrapper | `lgdt()` |
| `c84e45d0` / `c84e4650` | per-CPU FS/GS setup | `pcpu_init()` |
| `c8714e10` | mutex init head | `mtx_init` head |
| `c8714d30` | individual mutex init | `mtx_init(name, type)` |
| `c8520f70` | MTRR-related | `cpu_setregs()` |
| `c8595f50` | initial smp probe | `cpu_topology_setup()` |
| `c8509520` | EFER + paging finalize | `cpu_setregs()` finish |
| `c83cb100` | early console init | `cninit()` |
| `c89f1730` | early panic handler | `panic_init()` |
| `c867dcb0` | locore-style fixups | `vm_machdep_fixup()` |
| `c857b980` | acpi / atom-bios init | `acpi_machdep_init()` |
| `c8509f10` | ? (lots of xrefs) | likely `proc0_init()` |

### Mutexes initialized by name

From `FUN_c8714d30(addr, name, 0, N)` calls:
- `&DAT_ffffffffca55c480` = mutex "(no name)" type 9
- `&DAT_ffffffffca549378` = `"descriptor tables"` type 0
- `&DAT_ffffffffca55c4a0` = `"wbinvd"` type 0
- `&DAT_ffffffffca55c4c0` = `"l2idsm"` type 1

(More mutexes added by SYSINITs later in mi_startup.)

---

## Function 3: `mi_startup` @ `0xffffffffc83e4170`

Classic **FreeBSD machine-independent startup loop**:

```c
void mi_startup(void)
{
    // 1. Sort the SYSINIT table by (subsystem, order)
    //    Sorted in place using a pointer-swap loop
    //    SYSINIT array: DAT_ffffffffc9ec02e0 .. DAT_ffffffffc9ec25e8
    //    (size: 0x2308 bytes = ~1130 sysinits × 16 bytes? or pointers)

    // 2. For each SYSINIT in sorted order:
    //    if (state == 1) skip   // already run
    //    if (state >= 2) continue
    //    call sysinit->func(sysinit->arg)
    //    mark state = 1

    // 3. After loop, "Shouldn't get here!" panic.
}
```

**Key SYSINIT subsystem IDs** (inferred from FreeBSD 9.0 convention,
the codebase Sony forked from):

| ID range | What runs |
|---|---|
| 0x0000..0x0fff | SI_SUB_DUMMY .. SI_SUB_DONE (no-ops) |
| 0x1000..0x1fff | SI_SUB_TUNABLES, SI_SUB_COPYRIGHT |
| 0x1800 | SI_SUB_LOCK |
| 0x2000 | SI_SUB_VM (vm_init, pmap_init) |
| 0x2200 | SI_SUB_KMEM |
| 0x2300 | SI_SUB_HYPERVISOR |
| 0x3800 | SI_SUB_CPU |
| 0x4000 | SI_SUB_SMP |
| 0x4800 | SI_SUB_KLD (kernel loadable modules) |
| 0x4c00 | SI_SUB_PROC0 |
| 0x5800 | SI_SUB_DEVFS |
| 0x6000 | SI_SUB_INTRINSIC |
| 0x8000 | SI_SUB_INTRINSIC_POST |
| 0xa000 | SI_SUB_DEVFS |
| 0xc000 | SI_SUB_KICK_SCHEDULER |
| 0xe000 | SI_SUB_KMOD |
| ... |
| 0xfa00 | SI_SUB_LAST |

**Each kernel module from `sys/internal/modules/*` registers
SYSINITs that get hooked into this chain.** That's how the dungeon's
rooms are actually entered at boot time — not by direct function call
but by registering with the SYSINIT system, which then dispatches.

### How to enumerate every module init function

For each room we explore:
1. Search for the source-path string of that module (e.g.
   `sys\\internal\\modules\\regmgr\\regmgr.c`).
2. Look at functions that REFERENCE that string (typically the module's
   panic / dev_init prints).
3. Cross-reference back to a SYSINIT entry that calls those functions.
4. The SYSINIT's subsystem / order tells us WHEN in boot the module
   runs.

---

## Open questions

- Where exactly is the SYSINIT array? Boundaries `c9ec02e0`..`c9ec25e8`
  give 0x2308 bytes. If each entry is 16 bytes (pointer + flags + state)
  that's ~560 sysinits. If 24 bytes (FreeBSD `struct sysinit`) that's
  ~370. Need to read the actual struct layout from one of the calls.
- Are there any boot-time decisions based on dev/console output that
  PSFree-Enhanced would affect? (Jailbreak alters parts of kernel
  memory before this code runs, but the warm-boot flag write at 0x472
  suggests no.)
- The CSTAR (`c855e280`) MSR target is the compat-mode SYSCALL entry —
  decompiling that gives us the BSD syscall dispatcher. Useful for the
  ipmimgr/regmgr explorations later.

## Linux equivalent

Linux on PS4 doesn't go through any of this — `linux-1024mb.bin` is a
self-contained payload loaded by the PSFree exploit chain that sets up
its own GDT/IDT/etc. None of Sony's boot-time module setup is preserved
into Linux. That's the **fundamental reason** modules like UVD that
depend on Sony's boot-time SBL/SMU programming can't be replicated from
mainline Linux without a Linux-side SBL driver port.
