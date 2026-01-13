#!/bin/bash
#
# Create minimal Arch Linux rootfs for PS4
# Uses Docker to create a clean Arch environment
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR}/.."
OUTPUT_DIR="${PROJECT_DIR}/output"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_step() { echo -e "${BLUE}[STEP]${NC} $1"; }

ROOTFS_NAME="ps4-archlinux-rootfs"
ARCHIVE_NAME="ps4linux.tar.xz"

echo ""
echo "=============================================="
echo "  Create Arch Linux Rootfs for PS4"
echo "=============================================="
echo ""

# Check for Docker
if ! command -v docker &> /dev/null; then
    log_warn "Docker not found. Alternative methods:"
    echo ""
    echo "Option 1: Use pacstrap (if on Arch Linux):"
    echo "  sudo pacstrap -c /mnt/ps4root base linux-firmware networkmanager"
    echo ""
    echo "Option 2: Download pre-made PS4 Arch rootfs:"
    echo "  - whitehax0r's ArchLinux-PS4v2"
    echo "  - Check ps4linux.com for community images"
    echo ""
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

log_step "Creating Arch Linux rootfs using Docker..."

# Create Dockerfile for PS4 Arch
cat > "${OUTPUT_DIR}/Dockerfile.ps4arch" << 'DOCKERFILE'
FROM archlinux:latest

# Update and install base packages
# Note: Using --needed to skip reinstalls, removed mesa-vdpau (merged into mesa)
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
    base \
    linux-firmware \
    networkmanager \
    sudo \
    nano \
    vim \
    htop \
    wget \
    curl \
    git \
    usbutils \
    pciutils \
    bluez \
    bluez-utils \
    xorg-server \
    xorg-xinit \
    xfce4-session \
    xfce4-panel \
    xfce4-settings \
    xfce4-terminal \
    xfdesktop \
    xfwm4 \
    thunar \
    lightdm \
    lightdm-gtk-greeter \
    mesa \
    vulkan-radeon \
    libva-mesa-driver \
    firefox \
    pulseaudio \
    pavucontrol \
    && pacman -Scc --noconfirm

# Create user 'ps4' with password 'ps4'
RUN useradd -m -G wheel -s /bin/bash ps4 && \
    echo "ps4:ps4" | chpasswd && \
    echo "root:root" | chpasswd && \
    echo "%wheel ALL=(ALL) ALL" >> /etc/sudoers

# Enable services
RUN systemctl enable NetworkManager && \
    systemctl enable lightdm && \
    systemctl enable bluetooth

# Set hostname
RUN echo "ps4-linux" > /etc/hostname

# Set locale
RUN echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen && \
    locale-gen && \
    echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Create important file for PS4
RUN echo -e "Username: ps4\nPassword: ps4\n\nRoot password: root" > /home/ps4/CREDENTIALS.txt
DOCKERFILE

log_step "Building Docker image (this may take a while)..."
docker build -t "$ROOTFS_NAME" -f "${OUTPUT_DIR}/Dockerfile.ps4arch" "${OUTPUT_DIR}"

log_step "Creating container and exporting rootfs..."
CONTAINER_ID=$(docker create "$ROOTFS_NAME")

log_step "Exporting filesystem..."
docker export "$CONTAINER_ID" | xz -9 -T0 > "${OUTPUT_DIR}/${ARCHIVE_NAME}"

log_step "Cleaning up..."
docker rm "$CONTAINER_ID"
rm -f "${OUTPUT_DIR}/Dockerfile.ps4arch"

echo ""
log_info "Rootfs created successfully!"
echo ""
echo "Output: ${OUTPUT_DIR}/${ARCHIVE_NAME}"
echo "Size:   $(du -h "${OUTPUT_DIR}/${ARCHIVE_NAME}" | cut -f1)"
echo ""
echo "Credentials:"
echo "  User: ps4 / ps4"
echo "  Root: root / root"
echo ""
echo "To extract to USB drive:"
echo "  sudo tar -xvJpf ${OUTPUT_DIR}/${ARCHIVE_NAME} -C /mnt/ps4root"
echo ""
