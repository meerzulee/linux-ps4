# Orbis power-off chain — RE'd and ready to port (2026-05-11)

**Problem:** `systemctl poweroff` halts Linux but the PS4 console stays
on (white LED, fans, eventually EMC watchdog cuts it ungracefully ~30 s
later). We never wired `pm_power_off` to a PS4-specific callback that
talks to the ICC subsystem, so Linux finishes its halt sequence and
then nothing tells the southbridge to drop the rails.

**Fix path (now visible from `orbis-12.02.elf`):** Sony has the full
shutdown chain in their kernel. We can transliterate it directly to a
small Linux patch (~100 LOC, lives in `drivers/ps4/`).

## Sony's shutdown event chain

`icc_power_module_init` at `0xffffffffc85745c0` (renamed in Ghidra)
registers five FreeBSD-style event handlers via the kernel's
`eventhandler_register` helper at `0xffffffffc85c0110`. In priority order
during a graceful shutdown:

| Event                  | Handler addr        | Priority | What it does                                  |
|------------------------|---------------------|----------|-----------------------------------------------|
| `shutdown_pre_sync`    | `0xc8574720`        | 0        | Flush userspace state to NVS                  |
| `shutdown_post_sync`   | `0xc8574750`        | 0        | After fs sync, before final                   |
| `shutdown_final`       | **`0xc8574860`**    | **20000**| **Actually cuts console power** (noreturn)    |
| `shutdown_force`       | `0xc8574860` (same) | 20000    | Same handler, used for forced/emergency       |
| `icc_available`        | `0xc8574bd0`        | 10000    | Reads `init_last_shutdown_cause` at boot      |

The `shutdown_final` / `shutdown_force` handler is what we need to
translate. The pre_sync / post_sync handlers exist mostly to flush
state — Linux already does that via its own reboot notifier chain, so
we can skip them on the first port.

## Inside `icc_power_shutdown_final` (Sony's path)

```c
void icc_power_shutdown_final(unused, ulong howto) {
    char buf[0x7f0];
    
    if ((howto & RB_NOSYNC) == 0)
        sync_or_flush();                                    // FUN_c86fdd80
    
    memset(buf, 0, 0x7f0);
    buf[1]  = 0x04;            // ICC command major = power
    buf[2]  = 0x04;            // ICC command minor = shutdown_final
    buf[3]  = 0x00;
    *(u16*)&buf[8] = 0x0020;   // payload length = 32 bytes
    buf[0xc] = 0;
    
    icc_send_recv(buf, buf);   // FUN_c87e3050 → ICC mailbox synchronous
    
    /* derive cause byte from howto, optional more handshakes... */
    
    icc_lowlevel_power_off();  // FUN_c85b2660 — does NOT return
}
```

`icc_send_recv` is Sony's `freebsd/sys/dev/scesb/icc/icc.c` mailbox
send-and-receive (source path embedded in the kernel as a debug
string at the function entry). It's the same protocol our existing
`apcie_icc_cmd` / `bpcie_icc_cmd` helpers implement.

Mapping Sony's 8-byte ICC mailbox header to our helper's argument shape:

| Offset in Sony buf | Field        | Maps to our `*_icc_cmd` arg |
|--------------------|--------------|------------------------------|
| `buf[0]`           | message type | (header byte set by helper)  |
| `buf[1]`           | major        | `u8 major` = `0x04`          |
| `buf[2..3]`        | minor (u16)  | `u16 minor` = `0x0004`       |
| `buf[6..7]`        | length (u16) | `u16 length` = `0x0020`      |
| `buf[8..]`         | payload      | `void *data` = `zeros[0x20]` |

So our Linux call is:

```c
u8 zero_payload[0x20] = {0};
apcie_icc_cmd(0x04, 0x0004, zero_payload, sizeof(zero_payload), NULL, 0);
```

`apcie_icc_cmd` already auto-dispatches to `bpcie_icc_cmd` when
`bpcie_initialized` is true (`src/6.x-baikal/drivers/ps4/ps4-apcie-icc.c:271`),
so one call covers both Aeolia/Belize (original PS4) and Baikal (our
hardware).

## Inside `icc_lowlevel_power_off` — the noreturn part

The post-ICC-command sequence in `FUN_c85b2660` writes directly to the
ICC southbridge MMIO at base `+0x1C8400`. Translated:

```c
void icc_lowlevel_power_off(void __iomem *icc) {
    /* state machine reset: clear bit 2 of control reg */
    writel(readl(icc + 0x1C8400) & ~0x4, icc + 0x1C8400);
    
    /* zero 8 dwords of out-of-band signaling registers */
    writel(0, icc + 0x1C844C);
    writel(0, icc + 0x1C8450);
    writel(0, icc + 0x1C8454);
    writel(0, icc + 0x1C8458);
    writel(0, icc + 0x1C845C);
    writel(0, icc + 0x1C8460);
    writel(0, icc + 0x1C8464);
    writel(0, icc + 0x1C8468);
    
    /* wait for !busy (bit 3 clear) */
    while (readl(icc + 0x1C8400) & 0x8)
        cpu_relax();
    
    /* THE POWER CUT: clear bit 0 of control reg */
    writel(readl(icc + 0x1C8400) & ~0x1, icc + 0x1C8400);
    
    /* does not return */
}
```

This block writes through the ICC mailbox device's MMIO BAR. It's the
same MMIO region our bpcie/apcie ICC drivers already map at probe
time, so we don't need to re-discover it.

## Open question for our port

Does the EMC cut power **on receipt of the ICC mailbox command alone**,
or does it require the host to also perform the low-level MMIO
sequence? Sony's code does both, in order. **We should also do both**
for behavioral fidelity, but our first port can try ICC-only and see
if the console actually powers off. If not, layer in the MMIO writes.

(There's a subtlety: between the ICC send and the MMIO writes Sony
issues other ICC commands and waits — possibly polling for the EMC to
say "ready to power off." If we omit those and write the MMIO too
early, the EMC might ignore us. Easiest mitigation: brief `msleep(100)`
between the command and the MMIO sequence, or rely on the helper's
synchronous reply to gate timing.)

## Linux-side patch shape

New file `drivers/ps4/ps4-power.c`, ~80 LOC:

```c
#include <linux/init.h>
#include <linux/pm.h>
#include <linux/delay.h>
#include "aeolia.h"
#include "baikal.h"

extern bool apcie_initialized;
extern bool bpcie_initialized;

static void (*orig_pm_power_off)(void);

static void ps4_console_power_off(void)
{
    u8 zero_payload[0x20] = { 0 };
    int ret;

    if (!apcie_initialized && !bpcie_initialized)
        goto fallback;

    /* Sony's icc_power_shutdown_final: cmd major=0x04, minor=0x0004,
     * 32-byte zero payload. apcie_icc_cmd auto-routes to bpcie when
     * bpcie_initialized.                                                */
    ret = apcie_icc_cmd(0x04, 0x0004, zero_payload, sizeof(zero_payload),
                        NULL, 0);
    if (ret < 0) {
        pr_err("ps4-power: ICC shutdown command failed (%d)\n", ret);
        goto fallback;
    }

    /* Give the EMC ~2 s to actually cut power. If we get past this we
     * fall through and let the default pm_power_off run, which at
     * minimum halts cleanly.                                            */
    mdelay(2000);

    /* TODO if mdelay returns: layer in the low-level MMIO sequence from
     * Sony's icc_lowlevel_power_off (writes to icc_bar + 0x1C8400..0x1C8468).
     * Needs an accessor in ps4-bpcie-icc.c to expose the mapped MMIO base. */

fallback:
    if (orig_pm_power_off)
        orig_pm_power_off();
}

static int __init ps4_console_power_off_init(void)
{
    if (!apcie_initialized && !bpcie_initialized)
        return -ENODEV;

    orig_pm_power_off = pm_power_off;
    pm_power_off = ps4_console_power_off;
    pr_info("ps4-power: pm_power_off → console hardware off via ICC cmd 04/0004\n");
    return 0;
}
late_initcall(ps4_console_power_off_init);

MODULE_LICENSE("GPL");
```

Plus one-line Makefile addition: `obj-y += ps4-power.o`.

Patch will land at
`patches/6.x-baikal/0200-ps4-drivers/0015-ps4-bpcie-pm-power-off-handler.patch`.

## Test plan

1. Build kernel with the patch.
2. Stage to USB.
3. Boot Linux via PSFree-Enhanced.
4. SSH in (no need for HDMI; this test is screen-independent).
5. Confirm dmesg shows `ps4-power: pm_power_off → console hardware off`.
6. Run `systemctl poweroff` (or `poweroff`).
7. **Expected:** within ~5 seconds the PS4 LED switches from solid white
   to off, and fans stop. No 30 s EMC watchdog hang.
8. If hang: SSH session also disconnects (kernel halt completed)
   but PS4 stays on. Means ICC alone wasn't enough — add the MMIO
   sequence in a follow-up.

## Ghidra rename map for this thread

| Address | Name | Notes |
|---|---|---|
| `0xffffffffc85745c0` | `icc_power_module_init`           | Wires up the 5 EVENTHANDLER_REGISTERs |
| `0xffffffffc8574720` | `icc_power_shutdown_pre_sync`     | shutdown_pre_sync handler |
| `0xffffffffc8574750` | `icc_power_shutdown_post_sync`    | shutdown_post_sync handler |
| `0xffffffffc8574860` | `icc_power_shutdown_final`        | shutdown_final + shutdown_force handler |
| `0xffffffffc8574bd0` | `icc_power_init_last_shutdown_cause` | runs when ICC becomes available |
| `0xffffffffc85c0110` | `eventhandler_register`           | FreeBSD's EVENTHANDLER_REGISTER |
| `0xffffffffc85b2660` | (icc_lowlevel_power_off) — not yet renamed; noreturn MMIO sequence |
| `0xffffffffc87e3050` | (icc_send_recv) — not yet renamed; mailbox send/recv |

## Followups for the broader "other problems" survey

These came out of the same kernel-dump session and are catalogued for
future-Claude / future-Meerzulee:

- **Suspend (`icc_power_suspend_*`)** — search Orbis kernel for similar
  EVENTHANDLER_REGISTER blocks using `suspend_pre_sync` /
  `resume_post_sync` strings. Same shape as shutdown; harder because
  S3 resume needs cooperation from the cpu/chipset.
- **Fan/thermal** — strings `critical temp setpoint`, `dashutdown` at
  `0xc8b4e731` hint at thermal-management code. ICC commands for fan
  speed are likely small (one major/minor pair). Could expose as
  `hwmon` chip in Linux.
- **Reset cause logging** — `icc_power_init_last_shutdown_cause` is the
  hook; we could mirror it to `/sys/class/ps4/last_shutdown_cause`.
- **VCE firmware** — same kernel, same pattern as UVD discovery on
  2026-05-11. Search the kernel for `[ATI LIB=VCEFW,...]` banner.
- **Ethernet** (sky2 dead-end → `stmmac`/DWMAC1000) — Sony's
  `if_dwc_eth_qos` driver in Orbis is the authoritative reference.
  Multi-day port; not in scope for this thread but unblocked by the
  kernel dump.
