#!/bin/bash
# PS4 Arch boot speedup + zram (run on PS4 via SSH, requires sudo)
set -e
say() { echo -e "\033[1;36m=== $* ===\033[0m"; }

say "1. Kill man-db's boot-time regeneration (saves ~38s)"
# It's a timer — keep it but disable boot trigger
sudo systemctl mask man-db.service 2>&1 || true

say "2. Disable plymouth (no boot splash visible anyway during PS4 gauntlet)"
sudo systemctl mask plymouth-start.service plymouth-quit.service plymouth-quit-wait.service 2>&1 || true

say "3. Disable accounts-daemon (auto-login user, not needed)"
sudo systemctl mask accounts-daemon.service 2>&1 || true

say "4. Disable systemd-time-wait-sync (PS4 has no RTC battery, time syncs over network later)"
sudo systemctl mask systemd-time-wait-sync.service 2>&1 || true

say "5. Disable systemd-readahead (negligible benefit on USB rootfs)"
sudo systemctl mask systemd-readahead-collect.service systemd-readahead-replay.service 2>&1 || true

say "6. Disable initramfs regeneration on every kernel-update boot"
sudo systemctl mask mkinitcpio-generate-shutdown-ramfs.service 2>&1 || true

say "7. ldconfig at boot — runs in shutdown anyway"
sudo systemctl mask ldconfig.service 2>&1 || true

say "8. Install zram-generator"
if ! pacman -Q zram-generator >/dev/null 2>&1; then
  sudo pacman -S --noconfirm --needed --assume-installed opengl-driver=1.0 zram-generator 2>&1 | tail -5
fi

say "9. Configure zram (1.5GB compressed swap, zstd)"
sudo tee /etc/systemd/zram-generator.conf > /dev/null <<EOF
[zram0]
zram-size = min(ram / 2, 1536)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

say "10. vm tunables for zram-as-swap"
sudo tee /etc/sysctl.d/99-zram.conf > /dev/null <<EOF
vm.swappiness = 180
vm.watermark_boost_factor = 0
vm.watermark_scale_factor = 125
vm.page-cluster = 0
EOF
sudo sysctl --system 2>&1 | grep -E "(swap|watermark|page-cluster)" || true

say "11. Reduce default systemd unit timeout (faster fail-fast)"
sudo mkdir -p /etc/systemd/system.conf.d
sudo tee /etc/systemd/system.conf.d/99-ps4-timeouts.conf > /dev/null <<EOF
[Manager]
DefaultTimeoutStartSec=15s
DefaultTimeoutStopSec=10s
DefaultDeviceTimeoutSec=15s
EOF

say "12. systemd-networkd-wait-online: don't block boot waiting for net"
sudo systemctl mask systemd-networkd-wait-online.service NetworkManager-wait-online.service 2>&1 || true

say "DONE — boot tweaks applied. Reboot to take effect for boot-time changes."
say "Live changes already in effect: zram (after daemon-reload), sysctl tunables."

sudo systemctl daemon-reload
sudo systemctl start systemd-zram-setup@zram0.service 2>&1 || true
echo
echo "current swap state:"
swapon --show
echo
echo "current memory:"
free -h
