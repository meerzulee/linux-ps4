#!/usr/bin/env bash
# Install Arch Linux + XFCE onto a USB drive for PS4 Baikal Linux boot.
#
# Layout:
#   /dev/sdX1  FAT32  2 GiB    PS4BOOT   - kernel + bootargs
#   /dev/sdX2  ext4   rest     ARCHROOT  - Arch root
#
# Run as root: sudo bash install-arch-usb.sh
# Override the target device with: TARGET_DEV=/dev/sdb sudo -E bash install-arch-usb.sh

set -euo pipefail

TARGET_DEV="${TARGET_DEV:-/dev/sda}"
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KERNEL_SRC="$PROJECT_ROOT/src/5.4-baikal"
KERNEL_OUT="$PROJECT_ROOT/output/5.4-baikal"
MNT="/mnt/ps4root"
BOOT_MNT="$MNT/boot/ps4"

USERNAME="ps4"
PASSWORD="ps4"
HOSTNAME="ps4"
TIMEZONE="UTC"
LOCALE="en_US.UTF-8"

PACKAGES=(
  base base-devel
  linux-firmware
  networkmanager
  sudo vim nano openssh git htop bash-completion
  dosfstools e2fsprogs gptfdisk
  xorg-server xorg-xinit
  xfce4 xfce4-goodies
  lightdm lightdm-gtk-greeter
)

log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root: sudo bash $0"
[[ -b "$TARGET_DEV" ]] || die "$TARGET_DEV is not a block device"
[[ -d "$KERNEL_SRC" ]] || die "Missing $KERNEL_SRC — build the 5.4 kernel first"
[[ -f "$KERNEL_OUT/bzImage" ]] || die "Missing $KERNEL_OUT/bzImage"

for cmd in pacstrap arch-chroot genfstab sgdisk wipefs mkfs.fat mkfs.ext4 partprobe blkid; do
  command -v "$cmd" >/dev/null || die "Missing '$cmd'. Install: pacman -S --needed arch-install-scripts dosfstools e2fsprogs gptfdisk util-linux"
done

# ----- Pre-flight -----
DEV_SIZE_GB=$(($(blockdev --getsize64 "$TARGET_DEV") / 1024 / 1024 / 1024))
log "Target: $TARGET_DEV (${DEV_SIZE_GB} GiB)"
log "Partitions to create:"
log "  ${TARGET_DEV}1  FAT32  2 GiB    PS4BOOT"
log "  ${TARGET_DEV}2  ext4   $((DEV_SIZE_GB - 2)) GiB  ARCHROOT"

if mount | grep -q "^$TARGET_DEV"; then
  warn "Some partitions of $TARGET_DEV are mounted. Unmounting..."
  for p in $(mount | awk -v d="$TARGET_DEV" '$1 ~ "^"d {print $1}'); do
    umount "$p" || true
  done
fi

read -rp "Wipe $TARGET_DEV and continue? Type WIPE to proceed: " confirm
[[ "$confirm" == "WIPE" ]] || die "Aborted."

# ----- Wipe + partition -----
log "Wiping $TARGET_DEV"
wipefs -a "$TARGET_DEV"
sgdisk --zap-all "$TARGET_DEV"

log "Creating GPT partitions"
sgdisk --new=1:0:+2GiB    --typecode=1:0700 --change-name=1:PS4BOOT  "$TARGET_DEV"
sgdisk --new=2:0:0        --typecode=2:8300 --change-name=2:ARCHROOT "$TARGET_DEV"
partprobe "$TARGET_DEV"
sleep 1

# Resolve partition device names (sda1 vs nvme0n1p1)
if [[ "$TARGET_DEV" == *[0-9] ]]; then
  P1="${TARGET_DEV}p1"; P2="${TARGET_DEV}p2"
else
  P1="${TARGET_DEV}1";  P2="${TARGET_DEV}2"
fi

log "Formatting $P1 as FAT32 (label PS4BOOT)"
mkfs.fat -F32 -n PS4BOOT "$P1"

log "Formatting $P2 as ext4 (label ARCHROOT)"
mkfs.ext4 -F -L ARCHROOT "$P2"

# ----- Mount -----
log "Mounting"
mkdir -p "$MNT"
mount "$P2" "$MNT"
mkdir -p "$BOOT_MNT"
mount "$P1" "$BOOT_MNT"

# ----- pacstrap -----
log "pacstrap: installing base + XFCE (this is the long step)"
pacstrap -K "$MNT" "${PACKAGES[@]}"

log "Generating fstab"
genfstab -U "$MNT" >> "$MNT/etc/fstab"

# ----- Install our kernel modules -----
log "Installing 5.4 kernel modules into rootfs"
make -C "$KERNEL_SRC" INSTALL_MOD_PATH="$MNT" INSTALL_MOD_STRIP=1 modules_install

# ----- Configure inside chroot -----
log "Configuring system in chroot"
cat > "$MNT/root/postinstall.sh" <<EOF
#!/bin/bash
set -euo pipefail

# Time + locale
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc || true
sed -i 's/^#$LOCALE/$LOCALE/' /etc/locale.gen
locale-gen
echo "LANG=$LOCALE" > /etc/locale.conf

# Hostname + hosts
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# root password
echo "root:$PASSWORD" | chpasswd

# user
useradd -m -G wheel,video,audio,storage,network -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd

# wheel sudo
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Services
systemctl enable NetworkManager.service
systemctl enable lightdm.service
systemctl enable sshd.service

# Auto-login XFCE for the test user (convenience on PS4)
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-autologin.conf <<LDM
[Seat:*]
autologin-user=$USERNAME
autologin-session=xfce
LDM
groupadd -r autologin 2>/dev/null || true
gpasswd -a $USERNAME autologin

echo "[+] postinstall done"
EOF
chmod +x "$MNT/root/postinstall.sh"
arch-chroot "$MNT" /root/postinstall.sh
rm -f "$MNT/root/postinstall.sh"

# ----- Boot artifacts on FAT32 -----
log "Copying kernel + bootargs to PS4BOOT"
ROOT_UUID=$(blkid -s UUID -o value "$P2")
cp -v "$KERNEL_OUT/bzImage" "$BOOT_MNT/bzImage"
cp -v "$KERNEL_OUT/config"   "$BOOT_MNT/config" 2>/dev/null || true
cat > "$BOOT_MNT/bootargs.txt" <<EOF
root=UUID=$ROOT_UUID rootfstype=ext4 rw console=ttyS0,115200n8 earlyprintk=serial,ttyS0,115200 loglevel=7
EOF
log "bootargs.txt:"
cat "$BOOT_MNT/bootargs.txt"

# ----- Cleanup -----
log "Syncing + unmounting"
sync
umount "$BOOT_MNT"
umount "$MNT"
rmdir "$BOOT_MNT" "$MNT"

log "Done. USB ready."
log "Boot partition: $P1 (FAT32, label PS4BOOT) — bzImage + bootargs.txt"
log "Root partition: $P2 (ext4,   label ARCHROOT) — Arch + XFCE"
log "Login: $USERNAME / $PASSWORD"
