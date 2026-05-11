# Room: audioout — Audio Output Stack

**Source paths embedded:**
- `sys/internal/modules/audioout/snd_hda/hdac.c` @ string `c8bd6a8b`
- `sys/internal/modules/audioout/sound/pcm/sound.c` @ string `c8bd7a1c`
- `sys/internal/modules/audioout/sound/pcm/feeder_mixer.c` @ string `c8bd8725`
- `sys/internal/modules/audioout/sound/pcm/channel.c` @ string `c8bd8a4c`
- `sys/internal/modules/audioout/sound/pcm/vchan.c` @ string `c8bd9fc8`
- `sys/internal/modules/audioout/sound/pcm/mixer.c` @ string `c8bda321`
- `sys/internal/modules/audioout/sound/pcm/buffer.c` @ string `c8bda4f2`
- `sys/internal/modules/audioout/sound/pcm/dsp.c` @ string `c8bda992`
- `sys/internal/modules/audioout/uaudio/uaudio_pcm.c` @ string `c8bdab99`
- `sys/internal/modules/audioout/uaudio/uaudio.c` @ string `c8bdacf4`

**Function address ranges:**
- `snd_hda/hdac.c`: ~`c88cc000..c88d8800`
- `sound/pcm/*` and `uaudio/*`: TBD (unmapped this iter)

## What this room does

Three layers stacked together:

```
┌────────────────────────────────────┐
│ uaudio (USB audio class)           │  uaudio.c, uaudio_pcm.c
├────────────────────────────────────┤
│ sound/pcm  (FreeBSD core PCM)      │  sound, channel, vchan,
│   - virtual channels               │  feeder_mixer, mixer, buffer,
│   - mixer / SRC / channel mgmt     │  dsp
├────────────────────────────────────┤
│ snd_hda/hdac (HD Audio controller) │  hdac.c
│   - CORB/RIRB ring buffers         │
│   - codec verb send                │
│   - widget tree discovery          │
└────────────────────────────────────┘
```

The 7 `sound/pcm/*` files are **stock FreeBSD 9.0 sound subsystem** —
known-good code. Sony forked FreeBSD's `sys/dev/sound/pcm/*.c`
verbatim (the source paths even reflect the original FreeBSD layout).

The Sony-specific code is in `snd_hda/hdac.c`.

## Why it matters for Linux on PS4

🔍 **Indirectly relevant.** Linux on PS4 already detects HDMI audio
via mainline `snd_hda_intel` — confirmed in our A17 boot log:

```
[    7.289341] input: HD-Audio Generic HDMI/DP,pcm=3 as
               /devices/pci0000:00/0000:00:01.1/sound/card0/input1
[    7.296299] input: HD-Audio Generic HDMI/DP,pcm=7 as
               /devices/pci0000:00/0000:00:01.1/sound/card0/input2
```

The HD audio controller is at PCI 00:01.1 (function 1 of the GPU
device). Mainline driver covers this hardware fully. Once HDMI
display works (via our `ps4_bridge.c` — informed by the `hdmi` room
mapping), HDMI audio should follow automatically.

For this dungeon map, we only need a high-level overview of audioout —
no port work needed.

## Function map (first-pass — `snd_hda/hdac.c` only)

| Sony function | Address | Purpose |
|---|---|---|
| `hdac_attach` | (TBD) | Sony's device-attach handler |
| `hdac_command_send_internal` | (TBD) | Send a HD Audio verb to a codec |
| `hdac_corb_init` | (TBD) | Init Command Output Ring Buffer |
| `hdac_rirb_init` | (TBD) | Init Response Input Ring Buffer |
| `hdac_probe_codec` | (TBD) | Probe codec on a CODEC line |
| `hdac_widget_connection_parse` | (TBD) | Parse codec widget tree |
| `hdac_mem_alloc` / `dma_alloc` / `irq_alloc` | (TBD) | Resource allocation |
| `hdac_get_capabilities` | (TBD) | Query controller caps from PCI |
| **`hdac_suspend_phase3`** | (TBD) | Suspend PM hook (phase 3) |
| **`hdac_resume_phase4`** | (TBD) | Resume PM hook (phase 4) |
| `hdac_buffer_latency_sysctl` | `c88d4090` | sysctl: clamp latency 1..5000 ms, convert to ticks |
| `hdac_helper_3e00` | `c88d3e00` | (10+ string xrefs — likely a major function) |
| `hdac_helper_2e40` | `c88d2e40` | (5 string xrefs) |
| `hdac_helper_4090` | `c88d4090` | (sysctl shown above) |
| `hdac_helper_4210` | `c88d4210` | |
| `hdac_helper_5cb0` | `c88d5cb0` | |
| `hdac_helper_5ea0` | `c88d5ea0` | |
| `hdac_helper_7040` | `c88d7040` | |
| `hdac_helper_74f0` | `c88d74f0` | |
| `hdac_helper_78d0` | `c88d78d0` | |
| `hdac_helper_7d50` | `c88d7d50` | |
| `hdac_helper_8390` | `c88d8390` | |
| `hdac_helper_8410` | `c88d8410` | |
| `hdac_helper_85f0` | `c88d85f0` | |
| `hdac_helper_cd270` | `c88cd270` | |
| `hdac_helper_cd7a0` | `c88cd7a0` | |
| `hdac_helper_cde70` | `c88cde70` | |
| `hdac_helper_ccae0` | `c88ccae0` | |
| `hdac_helper_ccfd0` | `c88ccfd0` | |

## Key strings found

```
"hdac driver mutex"        — main lock name
"hdac_attach"              — printk tag
"hdac_command_send_internal" — verb send fn name
"hdac_mem_alloc"           — mem alloc tag
"hdac_irq_alloc"           — irq alloc tag
"hdac_get_capabilities"    — caps probe tag
"hdac_dma_alloc"           — DMA alloc tag
"Unable to put hdac in reset\n"  — error message
"hdac_corb_init"           — CORB init tag
"hdac_rirb_init"           — RIRB init tag
"hdac_probe_codec"         — codec probe tag
"hdac_widget_connection_parse"   — widget tree parse tag
"hdac_suspend_phase3"      — suspend phase 3 hook
"hdac_resume_phase4"       — resume phase 4 hook
```

## Sony-specific quirks (TBD — needs deeper dig)

The reason Sony forked FreeBSD's snd_hda instead of using upstream
unchanged is likely PS4-specific quirks like:
1. The **DSP reset sequence** — PS4's HDMI audio may need a non-standard
   reset.
2. **HDCP synchronization** — encrypted audio over HDMI requires the
   HDA controller to coordinate with HDMI link state.
3. **Bluetooth audio path** — PS4's BT controller talks to the HDA
   controller through a special path (maybe a virtual codec).
4. **PS4 controller speaker** — DualShock 4 has a built-in speaker
   addressable via HDA + USB combo.

These deserve a deeper second-pass if PS4 audio has any quirks on
Linux that we need to match.

## Open questions / TODOs

1. Decompile `hdac_attach` to confirm which PCI device IDs Sony's
   driver claims (should be AMD/ATI 0x1002 + specific subsystem IDs).
2. Decompile `hdac_command_send_internal` — verb send. If Sony has
   any non-standard verb format, that's a clue.
3. Map the 4 PM hooks (suspend phase 3, resume phase 4). Wonder why
   "phase 3" / "phase 4" — implies a multi-phase suspend coordinator
   somewhere.
4. Check the SDMA ↔ snd_hda interaction. Does HDA use SDMA for
   audio transfers, or its own ring buffer?

## Linux equivalent

| Sony layer | Linux mainline |
|---|---|
| `snd_hda/hdac.c` | `sound/pci/hda/hda_intel.c` (snd-hda-intel) |
| `sound/pcm/*` (FreeBSD) | ALSA `sound/core/pcm*.c` |
| `uaudio/*` (FreeBSD) | ALSA `sound/usb/*.c` |

For our PS4 Linux port:
- HD audio at PCI 00:01.1 — handled by `snd_hda_intel`, already loads
  per boot log.
- USB audio for headsets — handled by `snd_usb_audio`, already loads.
- Bluetooth audio for wireless headsets — needs full Bluetooth stack
  working first (mt7668 BT not yet ported in our Linux port).
- DualShock 4 audio (controller speaker) — works once `hid-sony` is
  loaded; routed through standard ALSA sink.

**No audioout-specific porting work needed for basic Linux on PS4.**

## Connections to other rooms

- **hdmi** room: HDMI audio over HD audio link. Hot-add events from
  the HDMI bridge tell HDA when a sink connects.
- **bt** room: BT audio (HFP/A2DP) coordination.
- **mbus** room: HDMI hotplug events (event_id 9) drive HDA to switch
  default sink.
- **sdma** room: probably moves PCM samples for low-latency paths.
