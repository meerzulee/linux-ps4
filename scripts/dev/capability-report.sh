#!/bin/bash
# Read-only, bounded runtime snapshot for a booted PS4 Linux system.

set -u

export LC_ALL=C
export LANG=C

section() {
    printf '\n## %s\n' "$1"
}

run() {
    printf '\n$ %s\n' "$*"
    if command -v timeout >/dev/null 2>&1; then
        timeout 10s sh -c "$*" 2>&1 || true
    else
        sh -c "$*" 2>&1 || true
    fi
}

section "identity"
run "date -Is"
run "uname -a"
run "cat /proc/cmdline"
run "uptime"
run "systemd-detect-virt"

section "cpu and memory"
run "lscpu"
run "cat /sys/devices/system/cpu/online /sys/devices/system/cpu/possible"
run "for p in /sys/devices/system/cpu/cpufreq/policy*; do [ -d \"\$p\" ] || continue; printf '%s: ' \"\$p\"; cat \"\$p/scaling_driver\" \"\$p/scaling_governor\" \"\$p/scaling_cur_freq\" 2>/dev/null | paste -sd ' ' -; done"
run "free -h"

section "pci and platform"
run "lspci -nnk"
run "ls -l /sys/bus/platform/drivers 2>/dev/null | head -80"

section "graphics"
run "lspci -nnk | sed -n '/VGA compatible controller/,+4p; /Display controller/,+4p'"
run "for c in /sys/class/drm/card*; do [ -e \"\$c\" ] || continue; printf '%s driver=' \"\$c\"; readlink -f \"\$c/device/driver\" 2>/dev/null || true; done"
run "for c in /sys/class/drm/card*-*; do [ -e \"\$c/status\" ] || continue; printf '%s: ' \"\$c\"; cat \"\$c/status\"; sed -n '1,12p' \"\$c/modes\" 2>/dev/null; done"
run "ls -l /dev/dri 2>/dev/null"
run "DISPLAY=:0 XAUTHORITY=\$HOME/.Xauthority glxinfo -B"
run "DISPLAY=:0 XAUTHORITY=\$HOME/.Xauthority eglinfo -B | sed -n '1,100p'"
run "DISPLAY=:0 XAUTHORITY=\$HOME/.Xauthority vulkaninfo --summary"
run "systemctl is-active display-manager"

section "storage"
run "lsblk -e 7 -o NAME,MAJ:MIN,SIZE,TYPE,FSTYPE,LABEL,MOUNTPOINTS,RO,TRAN"
run "findmnt -no SOURCE,FSTYPE,OPTIONS /"
run "for h in /sys/class/ata_host/host*; do [ -e \"\$h\" ] && printf '%s: ' \"\$h\" && cat \"\$h/proc_name\" 2>/dev/null; done"

section "network"
run "ip -brief link"
run "ip -brief address"
run "nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status"
run "iw dev"
run "iw dev wlan0 link"
run "for n in /sys/class/net/*; do i=\${n##*/}; printf '%s driver=' \"\$i\"; readlink -f \"\$n/device/driver\" 2>/dev/null || printf 'virtual\n'; done"
run "rfkill list"

section "audio"
run "cat /proc/asound/cards"
run "aplay -l"
run "pactl info | sed -n '1,30p'"
run "pactl list short sinks"

section "usb and bluetooth"
run "lsusb"
run "lsusb -t"
run "bluetoothctl show"

section "thermal and fan visibility"
run "for z in /sys/class/thermal/thermal_zone*; do [ -e \"\$z\" ] || continue; printf '%s ' \"\$z\"; paste -sd ' ' \"\$z/type\" \"\$z/temp\" 2>/dev/null; done"
run "for h in /sys/class/hwmon/hwmon*; do [ -e \"\$h\" ] || continue; printf '%s name=' \"\$h\"; cat \"\$h/name\" 2>/dev/null; for f in \"\$h\"/temp*_input \"\$h\"/fan*_input \"\$h\"/pwm*; do [ -e \"\$f\" ] && printf '  %s=%s\n' \"\${f##*/}\" \"\$(cat \"\$f\")\"; done; done"
run "sensors"

section "power management"
run "cat /sys/power/state /sys/power/mem_sleep"
run "cat /sys/power/wakeup_count"

section "kernel warnings"
run "journalctl -k -b -p warning --no-pager -n 200"
run "dmesg --level=warn,err,crit,alert,emerg | tail -200"

section "loaded modules"
run "lsmod"
