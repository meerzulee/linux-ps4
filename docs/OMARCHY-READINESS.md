# Omarchy readiness

## Decision

Ready to test **minimal Hyprland**. Not ready to install or claim support for
full Omarchy.

The PS4 now has the important graphics foundation: amdgpu KMS, a DRM render
node, radeonsi OpenGL, RADV Vulkan, libinput, PipeWire, polkit and the generic
desktop portal. The current session is still X11/XFCE. Hyprland, UWSM and the
Hyprland portal are not installed.

The [standard Omarchy installation](https://learn.omacom.io/2/the-omarchy-manual/)
expects a dedicated drive and erases it during installation. That path must
never be used on the PS4 internal disk. The existing external Arch root is the
recovery-safe base for this port.

## Acceptance order

1. Cold boot the SATA-disabled profile and keep XFCE as recovery.
2. Install only `hyprland`, `uwsm` and `xdg-desktop-portal-hyprland` from the
   Arch repositories.
3. Launch a bare Hyprland session from a TTY with one monitor rule:
   `1920x1080@60`, scale `1`.
4. Verify DRM rendering, keyboard, mouse, terminal, portal startup and clean
   exit back to XFCE.
5. Add one Omarchy component at a time: Waybar, notifications, launcher,
   terminal, lock screen, clipboard and screenshots.
6. Adapt Omarchy defaults only after each underlying component passes.

## Known gaps

- no audible HDMI output;
- no fan RPM/control, so no sustained rendering test;
- Bluetooth pairing is untested;
- suspend is unavailable;
- the guest clock is unsynchronized;
- the standard Omarchy disk, encryption, bootloader, power and hibernation
  assumptions do not match the PS4 loader and external-USB boot chain.

The first Hyprland run is an experiment, not a replacement for XFCE or a full
Omarchy installation.
