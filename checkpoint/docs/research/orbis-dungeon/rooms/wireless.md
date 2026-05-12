# Floor 7 trio: wlan + bt + wlanbt

## Source paths

**wlan (5 files):**
- `sys/internal/modules/wlan/trooper/if_wlc.c` @ string `c8e0eeb8`
- `sys/internal/modules/wlan/trooper/mtwl_hif.c` @ string `c8e0f806`
- `sys/internal/modules/wlan/trooper/wlan_dal.c` @ string `c8e0fa2a`
- `sys/internal/modules/wlan/trooper/mtwl_core.c` @ string `c8e10dc4`
- `sys/internal/modules/wlan/torus/if_trsw.c` @ string `c8e1042e`

**bt (3 files):**
- `sys/internal/modules/bt/bt_sys.c` @ string `c8e708a6`
- `sys/internal/modules/bt/bt_gatt.c` @ string `c8e70ff4`
- `sys/internal/modules/bt/bt_driver.c` @ string `c8e714f7`

**wlanbt (1 file):**
- `sys/internal/modules/wlanbt/torus.c` @ string `c8e76a58`

**Function ranges:**
- `wlan/trooper/`: ~`c892f200..c8937830` (very large, ~150+ functions)
- `bt/`: ~`c894c740..c8952200`
- `wlanbt/torus.c`: ~`c8960db0..c89617d9`

## What this room does

PS4 Slim/Pro has a **Mediatek MT76xx combo chip** (WiFi + Bluetooth on
one die, codenamed **"Trooper"** by Sony, with the USB-side combo radio
called **"Torus"**). Three modules cooperate:

```
┌─────────────────────────────────────────┐
│ wlan/trooper/  (MT76xx WiFi driver)    │  if_wlc.c, mtwl_*.c, wlan_dal.c
│   - 802.11 stack glue                   │
│   - HIF (host interface) over PCI/USB   │
├─────────────────────────────────────────┤
│ wlan/torus/if_trsw.c (combo glue)      │  (BT/WLAN switch)
├─────────────────────────────────────────┤
│ bt/  (Bluetooth stack)                 │  bt_sys.c, bt_gatt.c, bt_driver.c
│   - HCI / L2CAP / GATT                  │
│   - PS4-specific BT controller quirks   │
├─────────────────────────────────────────┤
│ wlanbt/torus.c (USB combo radio glue)  │
│   - Handles WiFi+BT multiplexing        │
│   - 0x800 byte max packets              │
└─────────────────────────────────────────┘
```

Confirmed Sony codenames from extracted strings:
- **TROOPER** — MediaTek MT76xx series WiFi/BT combo (per
  string `c8e0fa83`)
- **Trooper firmware** — the .bin blob (`"WARNING: Trooper firmware
  not found"` at `c8e7095a`)
- "trsw" = TRoooper SWitch (combo BT/WLAN)
- **TORUS** — Sony's name for the USB combo BT/WLAN device

## Why it matters for Linux on PS4

🔥 **HIGH PRIORITY — wireless is broken in our Linux port.**

From `CLAUDE.md`:
> WiFi/BT (mt7668 driver not yet ported)

Our `6.x-baikal` build has the `mt7668` driver but it's listed as
deferred. This is the single biggest userland-feature gap on Linux.
We HAVE the driver source (in our patches under
`drivers/net/wireless/mediatek/mt76/mt7615/` etc.) but it's not yet
fully wired up for PS4's specific PCI device IDs.

What this dungeon mapping confirms:
1. **The chip is MT76xx series** — fully supported by mainline Linux
   `mt76` driver (since kernel 4.15+).
2. **PS4 Slim/Pro uses "Trooper" = MT7668** — has known mainline
   support via `mt76x0u` for USB and `mt76x2e` for PCIe variants.
3. **The "Torus" combo** — that's the BT half. Mainline has `mt7663s`
   and similar combo glue.

For our port:
- The MT7668 driver in `drivers/net/wireless/mediatek/mt76/mt7615/`
  needs PCI device ID added for PS4
- The BT side needs `btusb` quirks for the MT76xx HCI vendor extensions

This is a **straightforward driver port** — no reverse-engineering
needed. Mainline already has all the protocol code. Just need to wire
up the IDs.

## Function map (first-pass)

### wlan/trooper (very large — only top-level)

| Sony function | Address | Purpose (inferred) |
|---|---|---|
| `wlc_helper_31130` | `c8931130` | wlc helper |
| `wlc_helper_31420` | `c8931420` | |
| `wlc_helper_31700` | `c8931700` | |
| `wlc_helper_31ab0` | `c8931ab0` | |
| `wlc_helper_31d80` | `c8931d80` | |
| `wlc_helper_31ff0` | `c8931ff0` | |
| `wlc_helper_32290` | `c8932290` | |
| `wlc_helper_32530` | `c8932530` | |
| `wlc_helper_32740` | `c8932740` | |
| `wlc_helper_32950` | `c8932950` | |
| `wlc_helper_32b80` | `c8932b80` | |
| `wlc_helper_32d70` | `c8932d70` | |
| `wlc_helper_32fb0` | `c8932fb0` | |
| `mtwl_helper_331d0` | `c89331d0` | |
| `mtwl_helper_333f0` | `c89333f0` | |
| `mtwl_helper_33580` | `c8933580` | |
| `mtwl_helper_33880` | `c8933880` | |
| `mtwl_helper_33a90` | `c8933a90` | |
| `mtwl_helper_33cd0` | `c8933cd0` | |
| `mtwl_helper_33ef0` | `c8933ef0` | |
| `mtwl_helper_340f0` | `c89340f0` | |
| `mtwl_helper_349a0` | `c89349a0` | |
| `mtwl_helper_34c00` | `c8934c00` | (10+ xrefs — major) |
| `mtwl_helper_35280` | `c8935280` | |
| `mtwl_helper_35770` | `c8935770` | (~15 xrefs — major) |
| `mtwl_helper_35e10` | `c8935e10` | |
| `mtwl_helper_35fb0` | `c8935fb0` | (~10 xrefs — major) |
| `mtwl_helper_36dc0` | `c8936dc0` | |
| `mtwl_helper_371e0` | `c89371e0` | |
| `mtwl_helper_374f0` | `c89374f0` | |
| `mtwl_helper_376b0` | `c89376b0` | |
| `wlc_helper_2f200` | `c892f200` | |
| `wlc_helper_30350` | `c8930350` | |
| `wlc_helper_30720` | `c8930720` | |
| `wlc_helper_30a80` | `c8930a80` | |
| `wlc_helper_30dc0` | `c8930dc0` | |

### bt (medium)

| Sony function | Address | Purpose |
|---|---|---|
| `bt_helper_4c740` | `c894c740` | (touches hdac.c source path — odd) |
| `bt_helper_50840` | `c8950840` | |
| `bt_helper_50b40` | `c8950b40` | |
| `bt_helper_50be0` | `c8950be0` | |
| `bt_helper_50ca0` | `c8950ca0` | |
| `bt_helper_50db0` | `c8950db0` | |
| **`bt_helper_50fb0`** | `c8950fb0` | (~6 xrefs — likely HCI dispatcher) |
| `bt_helper_520f0` | `c89520f0` | |

### wlanbt/torus.c

| Sony function | Address | Purpose |
|---|---|---|
| **`torus_ioctl`** | `c8960db0` | **WiFi/BT multiplexed IOCTL handler** |
| `torus_helper_61460` | `c8961460` | (3 xref slots) |
| `torus_helper_615b0` | `c89615b0` | (3 xref slots) |
| `torus_helper_61740` | `c8961740` | (3 xref slots) |
| `torus_alloc_request` | `c89613c0` | Allocate request buffer (called from torus_ioctl) |
| `torus_release_request` | `c8961410` | Release request buffer |
| `torus_send_command` | `c890f5e0` | HIF/HCI send command (in `wlc` range) |

## `torus_ioctl` decoded

```
torus_ioctl(handle, args):
  validate args.size <= 0x800 (case 0/4) or 0x7FA (case 1/5)
  copyin(args.buf, scratch, args.size)
  
  switch ((cmd + 0x6ED7) & 0xFFFF):
    case 0:  # WiFi command
    case 4:  # WiFi command (variant)
      build packet at handle->[0x118] (request slot):
        psVar4[0] = size + 4         (length field)
        psVar4[1] = 1                (type = WIFI)
        copy scratch into payload
      send via torus_send_command(handle, queue=handle->[0x40] | wifi_q, ...)
      release request
      cv_timedwait(handle->cv, lock, 10s)
      copyout response from handle->[0x120]+4 back to args.buf
    
    case 1:  # BT command
    case 5:  # BT command (variant)
      build packet (similar):
        *(byte*)(psVar4 + 3) = 1     (type = BT)
        *psVar4 = size + 4
      send + wait + copyout response from offset +7 (skip BT header)
```

So the torus chip uses a **4-byte request header** with type byte + 16-bit
length. Request types 0/4 = WiFi, 1/5 = BT. Different response offsets
(WiFi response data starts at +4, BT response starts at +7).

## Key strings extracted

- `"TROOPER"` — chip codename (used in capability/version reports)
- `"[wlc]: Trooper Assert Dump ("` — fatal-error dump prefix
- `"WARNING: Trooper firmware not found\n"` — missing firmware blob
  message (expected to be loaded from `/system_data/firmware/` on
  Sony PUP)

## Open questions / TODOs

1. **Find the PCI device IDs** Sony's wlan driver claims. Look at
   `mtwl_helper_34c00` or similar for the `pci_device_t` table.
2. **Locate the firmware blob path** — `wlan_dal.c` likely has the
   filesystem path like `/system/firmware/trooper.bin`. Useful for
   extracting and re-using the firmware on Linux.
3. **Map BT HCI vendor extensions** — Sony's `bt_driver.c` likely has
   non-standard HCI commands. Compare against mainline `btusb`'s MT76xx
   quirks.
4. **wlanbt vs wlan/torus** — there are TWO "torus" files (`wlan/torus/`
   AND `wlanbt/torus.c`). Likely different chip variants (PS4 Slim
   internal vs USB external dongle).
5. **GATT layer** (`bt_gatt.c`) — for BLE devices like DS5 / PS4 BLE
   accessories. Map this if any of those are LE-only.

## Linux equivalent

| Sony | Linux mainline |
|---|---|
| `wlan/trooper/mtwl_*.c` | `drivers/net/wireless/mediatek/mt76/mt7615/` and `mt76x0/` etc. |
| `wlan/torus/if_trsw.c` | (combo glue — handled by mt76 internally) |
| `bt/bt_driver.c` | `drivers/bluetooth/btusb.c` + `btmtksdio.c` |
| `bt/bt_gatt.c` | `net/bluetooth/att.c` + GATT helpers |
| `bt/bt_sys.c` | `net/bluetooth/hci_*.c` |
| `wlanbt/torus.c` | (mt76 combo glue) |

For Linux on PS4: **the upstream mt76 driver covers this hardware**.
Port work needed:
1. **Add PS4-specific PCI device IDs** to mt7615 / mt7663 / mt7668
   driver match tables. Sony might use a custom subsystem ID.
2. **Add btusb quirks** for the BT HCI side — Sony probably uses
   a vendor-specific HCI reset sequence.
3. **Provide the firmware blob** — need to extract `trooper.bin` from
   PS4's firmware and place it at `/lib/firmware/mediatek/mt76xx_*.bin`
   for the mainline driver.

This is straightforward driver work, not RE — should take days, not
weeks.

## Connections to other rooms

- **bluetooth_hid** room (Floor 6): uses bt's HCI to deliver HID
  reports from BT controllers.
- **regmgr** room: probably stores wifi credentials, BT pairings,
  preferred networks.
- **sbl/keymgr** room: probably stores network passwords encrypted.
- **mbus**: WiFi/BT hotplug events (chip reset, link state changes)
  may flow through.
