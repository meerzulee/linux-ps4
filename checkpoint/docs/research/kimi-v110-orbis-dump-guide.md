# How to dump Orbis kernel memory + BAR0 (comprehensive guide)

**kimi-k2.6, 2026-05-13**

## Why your current dumps are truncated

The dumps at `/tmp/ps4usb_sdb1/orbis-dump/12.02/kernel.elf` are **only the first 1.7MB of a ~13MB kernel**. The PS4 kernel ELF header claims:
- Text segment: `0xcfe758` bytes (~13.6 MB) at `kbase + 0`
- RW data: `0x1314af0` bytes (~19.7 MB) at `kbase + 0xd20000`

Your dump only captured the first 12.6% of text. The MTS driver code lives at offset `0x85ec030 - 0x9cb70000 = ~0x85ec030` bytes into the kernel text — **far past the 1.7MB truncation point**.

## Goal 1: Full kernel text/data dump

### Option A: Dump kernel text via kbase + copyout (payload SDK)

The payload is running in userland with `sys_kexec` or similar syscall hook. It can call `copyout()` to read kernel virtual addresses:

```c
// kbase from your log (e.g. 0xffffffff9cb70000)
// text size from ELF header: 0xcfe758
// Or simply read until page fault

#define DUMP_SIZE 0x1500000  // 21MB covers text + some data

for (off = 0; off < DUMP_SIZE; off += 0x1000) {
    void *kvaddr = (void *)(kbase + off);
    int err = copyout(kvaddr, user_buf + off, 0x1000);
    if (err) {
        // Page not mapped — may have hit a hole
        memset(user_buf + off, 0, 0x1000);
    }
}
```

**Problem**: `copyout` from kernel space may fail for unmapped pages. The kernel text has no holes, but pages past text end may not exist.

### Option B: Dump via pmap_extract() → physical → userland mmap

If the payload can call `pmap_extract()` (kernel internal function), it can translate KVAs to physical addresses, then `mmap()` `/dev/mem` or equivalent to read physical memory from userland.

```c
// Orbis FreeBSD pmap_extract prototype:
// pmap_t pmap = kernel_pmap; // global symbol "kernel_pmap"
// vm_paddr_t pa = pmap_extract(pmap, kbase + off);
// if (pa) { read from /dev/mem at pa; }
```

**Problem**: Requires knowing the `kernel_pmap` symbol address or finding it dynamically.

### Option C: Use Lapse/ps4-payload-sdk's `kernel_read` primitive

Many PS4 payloads already have a `kernel_read(uint64_t kaddr, void *buf, size_t len)` helper that uses a known kernel ROP chain or `sys_kexec` info leak. Check if `orbis-bar-dumper.bin` already has this capability.

### Option D: Hypervisor/level-2 dump (if payload runs at higher privilege)

If the payload has SMMU/EPT access (e.g., via the WebKit/PSFree exploit chain), it can read any physical address directly, bypassing KVA translation entirely.

## Goal 2: Dump MTS BAR0 specifically

This is harder than a generic kernel dump because **PCI BAR MMIO is NOT in the direct map**.

### Why DMAP + 0xc2000000 failed

FreeBSD's direct map covers system RAM. PCI BARs are device memory mapped by the PCI driver via `bus_alloc_resource()` → `bus_space_map()`. The KVA for the BAR is allocated from the kernel's virtual memory allocator (kmem, vmem, or pmap), not from the direct map.

The `0xc2000000` you tried is a common PS4 kernel heap offset, but BAR0 could be anywhere in KVA space.

### Correct approach: Walk softc → resource → handle

From our Ghidra verification (v109), the path is:

```
1. global softc_ptr @ 0xffffffffca590938
2. softc[0x60d] = struct resource * (BAR0 resource)
3. resource->r_handle (offset 0x10) = bus_space_handle_t = KVA of BAR0 mapping
4. resource->r_type (offset 8) = 0 for port I/O, != 0 for MMIO
```

**Payload code skeleton**:

```c
uint64_t kbase = 0xffffffff9cb70000;  // from payload log
uint64_t softc_ptr_addr = kbase + (0xca590938 - 0x9cb70000);

// Read 8 bytes from kernel
uint64_t softc;
kernel_read(softc_ptr_addr, &softc, 8);

// softc[0x60d] = resource ptr
uint64_t resource_ptr_addr = softc + 0x60d * 8;
uint64_t resource;
kernel_read(resource_ptr_addr, &resource, 8);

// resource->r_type @ offset 8
uint64_t type;
kernel_read(resource + 8, &type, 8);
printf("resource type: %lu (0=port, !=0=MMIO)\n", type);

// resource->r_handle @ offset 10
uint64_t handle;
kernel_read(resource + 0x10, &handle, 8);
printf("BAR0 KVA: 0x%016lx\n", handle);

// Dump 4KB from handle
char bar0_dump[4096];
kernel_read(handle, bar0_dump, 4096);

// Write to USB
int fd = open("/mnt/usb0/orbis-dump/12.02/mts-bar0-kva.bin", ...);
write(fd, bar0_dump, 4096);
close(fd);
```

**Critical**: The `resource` pointer and `handle` value are kernel virtual addresses. You need a working `kernel_read()` that can read arbitrary KVA. If your payload only has `copyout` from userland, you need to ensure the BAR0 KVA is mapped into the calling process's page tables (unlikely).

### Alternative: Use pmap to find physical address of BAR0

If `kernel_read` only works for direct-mapped addresses, find the physical address:

```c
// kernel_pmap is a global symbol in Orbis kernel
// Search for it in the symbol table, or find it via kbase + known offset
// In FreeBSD, kernel_pmap is usually in the data segment

uint64_t kernel_pmap = ...; // need to find this symbol
uint64_t pa = pmap_extract(kernel_pmap, handle);
printf("BAR0 physical: 0x%016lx\n", pa);

// Then read from /dev/mem at pa
int memfd = open("/dev/mem", O_RDONLY);
lseek(memfd, pa, SEEK_SET);
read(memfd, bar0_dump, 4096);
```

**Problem**: `/dev/mem` may not exist or may be restricted on Orbis. Also `pmap_extract` is an internal kernel function; you need its address.

### Alternative: Use PCI config space to get BAR0 physical address

```c
// PCI config space read
// Orbis uses pcie_read_config or similar
// Read BAR0 from config space offset 0x10
uint32_t bar0_low = pci_read_config(device, 0x10, 4);
// If 64-bit BAR, also read offset 0x14 for high 32 bits
uint64_t bar0_phys = bar0_low & ~0xF;  // mask flags
```

Then read physical memory via `/dev/mem` or a hypervisor read. This is the **most reliable** path because PCI config space is standardized and does not depend on kernel VM layout.

## Recommended next steps

1. **Fix the kernel dump truncation**: Dump at least `0xd20000 + 0x1314af0 = 0x2034af0` bytes (~33MB) to capture text + data + BSS. Use `kernel_read()` with `copyout` fallback, or loop and skip unmapped pages.

2. **For BAR0 dump, use the softc path**:
   - Read `0xca590938` (global softc ptr)
   - Read `softc + 0x3068` (resource ptr)
   - Read `resource + 0x10` (handle = BAR0 KVA)
   - Dump 4KB from handle via `kernel_read()`

3. **If `kernel_read()` can't reach the BAR KVA**, use PCI config space to get BAR0 physical address, then read physical memory.

4. **Post-processing**: Once you have the 4KB raw BAR0 dump, copy it to this host. I will write a Python script to:
   - Parse the raw bytes as little-endian 32-bit words
   - Compare against our v97 broken state
   - Highlight every differing register
   - Cross-reference with Ghidra to identify unknown register purposes

## What you need from the payload side

A working `kernel_read(uint64_t kva, void *user_buf, size_t len)` that can:
- Read any kernel virtual address (not just direct-mapped RAM)
- Handle page faults gracefully (return error for unmapped pages)
- Or use `/dev/mem` + physical address translation

If your current payload SDK doesn't have this, the fastest fix is to use the PCI config space → physical address → `/dev/mem` path, which bypasses KVA translation entirely.
