# Orbis kernel dumper — landscape scan for PS4 FW 12.02 (2026-05-11)

**Why this doc:** Per `PLAN.md` priority #1, we want to dump Orbis kernel to
RE the PS4-specific UVD/VCE power-on sequence (v71 stalled at this) plus
Synopsys DWMAC1000 ethernet (v69 sky2 dead-end) and other unknowns.

**Constraint:** PS4 is on FW **12.02**, jailbroken via **PSFree-Enhanced**
(WebKit → Lapse kernel exploit → Payload Loader on port 9020 → `.bin`).

**Verdict:** No off-the-shelf 12.02-compatible kernel-dumper `.bin` exists
publicly. Path forward is to port `LUA-Lapse`'s 12.02 dump logic into a
port-9020 payload `.bin`. All offsets we need are reproduced below.

## Tools surveyed

| Tool | FW 12.02? | Loader | Verdict |
|---|---|---|---|
| [obhq/kernel-dumper](https://github.com/obhq/kernel-dumper) | ❌ 11.00 only | PPPwn `--stage2` | Wrong FW + wrong loader chain (PPPwn ≠ PSFree). No active forks targeting 12.x. |
| [VV1LD/PS4-KernelDumper](https://github.com/VV1LD/PS4-KernelDumper) | ❌ 4.05/4.55/5.05 | socat → port 9020 | Loader OK, FW way too old. |
| [TeamFAPS/PS4-Kernel-Dumper](https://github.com/TeamFAPS/PS4-Kernel-Dumper) | ❌ 3.50–5.07 | — | Older still. |
| [Scene-Collective/ps4-kernel-dumper](https://github.com/Scene-Collective/ps4-kernel-dumper) | 🤷 "any FW the SDK supports" | Scene-Collective SDK loader | Source is FW-agnostic but `meta.json` dated 2021-01-01; relies on SDK to provide kbase offsets, and the SDK does not document 12.02 support. Untrustworthy without a confirmed v12.02 SDK build. |
| [egycnq/LUA-Lapse](https://github.com/egycnq/LUA-Lapse) | ✅ **Tested on 9.00/11.00/12.02** | Lua via remote_lua_loader | The only project with verified 12.02 dumper logic. **But entry requires an Artemis-engine PS4 game** (Raspberry Cube, Hamidashi Creative, Aikagi 2, Jinki Resurrection, Fuyu Kiss, Nora Princess… — mostly JP visual novels). Incompatible with our PSFree-Enhanced workflow. |
| [obhq/firmware-dumper](https://github.com/obhq/firmware-dumper) | — | — | Different purpose: dumps userspace SELF/SPRX files for Obliteration, not the kernel binary. |
| [GoldHEN/ps4debug](https://github.com/GoldHEN/ps4debug) | ✅ 11.50/11.52/12.00/12.02 | TCP debugger | Live kernel inspection, not a one-shot dumper. Useful follow-up tool but heavier setup. |

## The exploit chain (already in place)

```
Web browser → PSFree (WebKit exploit by abc, 2025)
            → Lapse (kernel exploit, aio_multi_delete race, FW 5.00–12.02)
            → Payload Loader (listens TCP port 9020 for .bin)
            → custom payload runs in kernel mode
```

User's current usage: drops `linux-1024mb.bin` (ArabPixel v24b unified) at
this stage to boot Linux. We need a *different* `.bin` that, instead of
booting Linux, dumps the Orbis kernel to USB.

## The 12.02 offsets — load-bearing knowledge

Extracted from
[`egycnq/LUA-Lapse:lapse.lua:1649-1654`](https://github.com/egycnq/LUA-Lapse/blob/main/lapse.lua#L1649).
These were confirmed by the LUA-Lapse author against a real 12.02 console:

```c
/* FW 12.02 — Liverpool / Gladius */
#define EVF_OFFSET           0x00784798   /* leaked_evf_ptr - this = kbase */
#define PRISON0_OFFSET       0x0111FA18
#define ROOTVNODE_OFFSET     0x02136E90
#define TARGET_ID_OFFSET     0x021CC60D
```

For reference (other tested versions, in case 12.02 dump fails to validate):

```c
/* FW 11.00 */
#define EVF_OFFSET_11_00     0x07FC26F
#define PRISON0_OFFSET_11_00 0x0111F830
#define ROOTVNODE_11_00      0x02116640
#define TARGET_ID_11_00      0x221C60D

/* FW 9.00 (n0llptr) */
#define EVF_OFFSET_9_00      0x7F6F27
#define PRISON0_OFFSET_9_00  0x111F870
#define ROOTVNODE_9_00       0x21EFF20
#define TARGET_ID_9_00       0x221688D
```

## KBASE discovery algorithm (from `lapse.lua`)

1. Lapse exploit yields kernel-mode shellcode execution.
2. Leak an EVF (Event Flag) pointer — this is a kernel string Lapse
   already exposes (`kernel.addr.inside_kdata` in Lua).
3. `kbase = leaked_evf_ptr - 0x00784798` for FW 12.02.
4. Verify by reading 4 bytes at `kbase` — must be `7F 45 4C 46` (ELF magic).
5. If mismatch, brute-scan backwards page-by-page (0x1000 aligned), looking
   for ELF magic + valid target_id offset, up to N pages.

## Dump algorithm (from `lapse.lua:1774`)

1. `kernel_size = get_kernel_elf_size(kbase)` — parses ELF program headers,
   sums `p_memsz` aligned by `p_align`, subtracts `kbase`, returns the
   in-memory extent.
2. `fd = sys_open("/mnt/usb0/kernel.elf", O_WRONLY|O_CREAT|O_TRUNC, 0777)`.
3. Loop `for off in 0..kernel_size step 0x4000`:
   - `sys_write(fd, kbase + off, min(0x4000, kernel_size - off))`
4. `sys_fsync(fd); sys_close(fd)`.

USB must be FAT32 or exFAT (no NTFS), mounted as `/mnt/usb0` by the PS4 OS.

## Port plan — `.bin` payload for FW 12.02 via PSFree-Enhanced

**Scaffold:** [Scene-Collective/ps4-payload-sdk](https://github.com/Scene-Collective/ps4-payload-sdk)
— provides ELF→PS4-bin glue, syscall stubs, port-9020 entry conventions.
Even though its FW coverage isn't documented for 12.02, it produces a
valid PS4 ELF — the actual *kernel* offsets we need are encoded in our
payload's source, not the SDK's.

**Payload skeleton** (~300 LOC C):

```c
#include "ps4.h"

#define KBASE_EVF_OFFSET_12_02  0x00784798
#define CHUNK_SIZE              0x4000          /* 16 KB */

static uint64_t leak_evf_ptr(void) {
    /* TODO: pick the same EVF leak primitive Lapse uses (kernel.addr.inside_kdata
     * in Lua maps to a specific kdata location after kexploit setup) */
}

static uint64_t calc_kbase(void) {
    uint64_t evf = leak_evf_ptr();
    uint64_t kbase = evf - KBASE_EVF_OFFSET_12_02;
    if (kread32(kbase) != 0x464C457F)  /* "\x7FELF" */
        return brute_find_kbase(evf);
    return kbase;
}

static uint64_t get_kernel_size(uint64_t kbase) {
    /* identical to Scene-Collective's get_kernel_size() — parses
     * Elf64_Phdr entries, sums (p_vaddr + p_memsz aligned by p_align),
     * subtracts kbase */
}

int payload_main(struct payload_args *args) {
    uint64_t kbase = calc_kbase();
    uint64_t size = get_kernel_size(kbase);

    int fd = open("/mnt/usb0/kernel.elf", O_WRONLY|O_CREAT|O_TRUNC, 0777);
    if (fd < 0) return -1;

    for (uint64_t off = 0; off < size; off += CHUNK_SIZE) {
        size_t n = (size - off < CHUNK_SIZE) ? (size - off) : CHUNK_SIZE;
        write(fd, (void*)(kbase + off), n);
    }
    fsync(fd); close(fd);

    /* notify */
    notify("kernel.elf dumped to USB");
    return 0;
}
```

**Where this lives in our tree:**
- `tools/orbis-kernel-dumper/source/main.c` — the payload
- `tools/orbis-kernel-dumper/Makefile` — invokes ps4-payload-sdk
- `tools/orbis-kernel-dumper/README.md` — build + use instructions
- Output `tools/orbis-kernel-dumper/build/kernel-dumper.bin` — drop into
  the PS4 USB next to `linux-1024mb.bin`

**Workflow once built:**
1. Stage `kernel-dumper.bin` on PS4 USB.
2. Boot PSFree-Enhanced → Lapse → Payload Guest UI → load
   `kernel-dumper.bin` *instead of* `linux-1024mb.bin`.
3. Wait 30–90 s (kernel is ~70–90 MB compressed in memory, less than
   3 minutes typical USB write).
4. Power-off PS4, pull USB.
5. On host: `cp /mnt/usb0/kernel.elf
   checkpoint/docs/research/orbis-kernel/orbis-12.02.elf`.
6. Open in Ghidra (free): `analyzeHeadless . orbis_proj -import
   orbis-12.02.elf` then drive the GUI to find `uvd_*` symbols,
   `liverpool_*` register tables, `if_dwc_eth_qos` for ethernet, etc.

## Risks for the port

1. **EVF leak primitive** — `lapse.lua` relies on Lapse's `kernel` table
   exposing `addr.inside_kdata`. In our port-9020 payload, we land in
   kernel-mode but *don't* automatically inherit Lapse's leaked pointers.
   We need to either (a) call the same kheap leak primitive Lapse uses
   (`aio_multi_delete` UAF on an `evf` object), or (b) parse PSFree-Enhanced's
   already-leaked state from the args struct it passes us. Need to read
   PSFree-Enhanced source to see what's already in scope.
2. **ASLR resilience** — `0x00784798` is a per-build constant. If Sony
   ships 12.05/12.10 with a different layout, the magic number changes.
   For now we hardcode 12.02; brute-scan path is the fallback.
3. **USB mount path** — `/mnt/usb0` is the standard FAT32 mount on PS4 OS.
   If multiple USBs are inserted at boot, ours might land on `/mnt/usb1`.
   Mitigation: try `/mnt/usb0` then `/mnt/usb1` etc.
4. **Kernel still running** — we're reading kernel memory while the
   scheduler is still active. Some sections may be inconsistent. Mitigation:
   `disable_interrupts()` for the duration, or accept the inconsistency
   (RE doesn't need perfect snapshot, just symbols + .text).

## Why we're not using PPPwn / obhq/kernel-dumper

`obhq/kernel-dumper` was the user's initial pick, but it specifically
targets the **PPPwn exploit chain (TheFlow, FW 11.00)**. PSFree-Enhanced
uses an entirely different entry (WebKit + Lapse) on a different FW.
The dumper code itself has hardcoded 11.00 kernel offsets too. Porting
its Rust source to 12.02 + port-9020 entry would be roughly equivalent
work to porting LUA-Lapse's Lua dump function to C; we chose the latter
because (a) LUA-Lapse offsets are already public/tested for 12.02 and
(b) C → ps4-payload-sdk is a more familiar toolchain than Rust →
no-std PS4 target. (We are not opposed to revisiting Rust later.)

## Followups after the dump lands

1. **UVD/VCE power-on RE** — for v72+ on `wip/uvd-vce-poc`. Find Sony's
   ICC commands for `SCE_ICC_CMD_VIDEOENC_xxx` / `SCE_ICC_CMD_VIDEODEC_xxx`,
   trace them back to register writes, port the sequence into a Linux-side
   `uvd_v4_2_start` Liverpool override.
2. **Stmmac/DWMAC1000 ethernet** — find Orbis's `if_msk` or `if_dwc_eth_qos`
   driver, extract Baikal-specific register layout, port mainline `stmmac`.
3. **Fan/thermal curve** — Orbis has the actual thermal targets for
   Liverpool/Gladius; expose as `hwmon` in Linux.
4. **HDD timing** — Orbis routes internal HDD through AHCI with
   Sony-encrypted partitions; understand the timing/auth to either disable
   cleanly or pass through unencrypted bytes.

Tracked separately in `PLAN.md` priority list; this doc is just for the
dumper bring-up.

## Sources

- [obhq/kernel-dumper](https://github.com/obhq/kernel-dumper) — FW 11.00, PPPwn-bound, no 12.02 forks
- [egycnq/LUA-Lapse](https://github.com/egycnq/LUA-Lapse) — verified 12.02 dumper, game-Lua entry only
- [shahrilnet/remote_lua_loader](https://github.com/shahrilnet/remote_lua_loader) — Artemis-engine-game entry chain
- [ArabPixel/PSFree-Enhanced](https://github.com/ArabPixel/PSFree-Enhanced) — our exploit chain
- [Scene-Collective/ps4-kernel-dumper](https://github.com/Scene-Collective/ps4-kernel-dumper) — Scene-Collective SDK consumer, 2021-vintage offsets
- [Scene-Collective/ps4-payload-sdk](https://github.com/Scene-Collective/ps4-payload-sdk) — proposed scaffolding for our port
- [VV1LD/PS4-KernelDumper](https://github.com/VV1LD/PS4-KernelDumper) — too old (5.05)
- [GoldHEN/ps4debug](https://github.com/GoldHEN/ps4debug) — alternative for live inspection
- [Lapse kernel exploit announcement (Wololo, May 2025)](https://wololo.net/2025/05/10/ps5-ps4-lapse-kernel-exploit-released-compatible-up-to-ps4-12-02-and-ps5-10-01-but/)
