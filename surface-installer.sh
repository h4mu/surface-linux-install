#!/usr/bin/env bash

set -Eeuo pipefail

# --- Configuration & Constants ---
TARGET_DISTRO="noble"
# These will be passed into the chroot
export TARGET_USER="surfaceuser"
export TARGET_PASSWORD="surfaceuser"
export ROOT_PASSWORD="root"
export SWAP_SIZE_GB=4

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Logging ---
LOG_FILE="install.log"
# Redirect all output to log file and stdout
exec > >(tee -a "$LOG_FILE") 2>&1

log_info() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: $1${NC}"
}

log_warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARNING: $1${NC}"
}

log_error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}"
}

log_success() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] SUCCESS: $1${NC}"
}

# --- Error Handling ---
cleanup() {
    log_info "Cleaning up..."
    # Unmount chroot binds
    for mnt in /mnt/target/dev/pts /mnt/target/dev /mnt/target/proc /mnt/target/sys/firmware/efi/efivars /mnt/target/sys; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount -l "$mnt" || true
        fi
    done
    # Unmount partitions
    if mountpoint -q /mnt/target/boot/efi 2>/dev/null; then
        umount /mnt/target/boot/efi || true
    fi
    if mountpoint -q /mnt/target 2>/dev/null; then
        umount /mnt/target || true
    fi
}

error_handler() {
    local line_no=$1
    local last_command=$2
    local exit_code=$3
    log_error "Command '$last_command' failed at line $line_no with exit code $exit_code"
    cleanup
    exit "$exit_code"
}

trap 'error_handler $LINENO "$BASH_COMMAND" $?' ERR

# --- Requirements Check ---
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root"
   exit 1
fi

# Check for required host tools
MISSING_TOOLS=()
for tool in debootstrap sgdisk wipefs lsblk udevadm mkfs.vfat mkfs.ext4 blkid; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        MISSING_TOOLS+=("$tool")
    fi
done

if [[ ${#MISSING_TOOLS[@]} -ne 0 ]]; then
    log_error "Missing required tools on host: ${MISSING_TOOLS[*]}"
    log_info "Please install them (e.g., apt install debootstrap gdisk dosfstools e2fsprogs util-linux)"
    exit 1
fi

# --- Drive Selection ---
if [ -n "${1:-}" ]; then
    TARGET_DEV="$1"
    log_info "Using target device from argument: $TARGET_DEV"
    CONFIRM="YES"
else
    log_info "Available block devices:"
    lsblk -p -d -n -o NAME,SIZE,MODEL

    echo ""
    read -r -p "Enter the device path to install Ubuntu on (e.g., /dev/sdX): " TARGET_DEV

    if [ ! -b "$TARGET_DEV" ]; then
        log_error "Device $TARGET_DEV not found or not a block device."
        exit 1
    fi

    log_warn "ALL DATA ON $TARGET_DEV WILL BE DESTROYED!"
    read -r -p "Type 'YES' to confirm: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        log_info "Aborting."
        exit 0
    fi
fi

# --- Partitioning ---
log_info "Wiping existing signatures on $TARGET_DEV..."
wipefs -af "$TARGET_DEV"
sgdisk -Z "$TARGET_DEV"
udevadm settle

log_info "Creating partitions..."
# GPT
# 1: EFI System Partition (512MB)
# 2: Root (remainder)
sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "$TARGET_DEV"
sgdisk -n 2:0:0 -t 2:8300 -c 2:"Ubuntu Root" "$TARGET_DEV"
udevadm settle

# Use partprobe if available to refresh partition table
if command -v partprobe >/dev/null 2>&1; then
    partprobe "$TARGET_DEV"
    udevadm settle
fi

# Special handling for loop devices to ensure partition nodes appear
if [[ "$TARGET_DEV" == *loop* ]]; then
    partx -u "$TARGET_DEV" || true
    udevadm settle
fi

# Identify partitions
if [[ "$TARGET_DEV" == *nvme* ]] || [[ "$TARGET_DEV" == *mmcblk* ]]; then
    PART_EFI="${TARGET_DEV}p1"
    PART_ROOT="${TARGET_DEV}p2"
elif [[ "$TARGET_DEV" == *loop* ]]; then
    if [ -b "${TARGET_DEV}p1" ]; then
        PART_EFI="${TARGET_DEV}p1"
        PART_ROOT="${TARGET_DEV}p2"
    else
        PART_EFI="${TARGET_DEV}1"
        PART_ROOT="${TARGET_DEV}2"
    fi
else
    PART_EFI="${TARGET_DEV}1"
    PART_ROOT="${TARGET_DEV}2"
fi

# Wait for partition nodes to appear
MAX_RETRIES=10
RETRY_COUNT=0
while [ ! -b "$PART_EFI" ] || [ ! -b "$PART_ROOT" ]; do
    if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
        log_error "Partition nodes $PART_EFI or $PART_ROOT failed to appear."
        exit 1
    fi
    log_info "Waiting for partition nodes ($RETRY_COUNT/$MAX_RETRIES)..."
    sleep 1
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

log_info "Formatting partitions..."
mkfs.vfat -F 32 -n EFI "$PART_EFI"
mkfs.ext4 -F -L ROOT "$PART_ROOT"

# Optimize ext4 for flash durability
tune2fs -m 0 "$PART_ROOT"

# --- Mounting ---
log_info "Mounting filesystems..."
mkdir -p /mnt/target
# Mount options for longevity
MOUNT_OPTS="noatime,lazytime,commit=120,errors=remount-ro"
mount -o "$MOUNT_OPTS" "$PART_ROOT" /mnt/target

mkdir -p /mnt/target/boot/efi
# For loopback tests in restricted environments, vfat might fail to mount
if ! mount "$PART_EFI" /mnt/target/boot/efi; then
    log_warn "Failed to mount EFI partition. If this is a loopback test on a restricted host, this is expected."
    log_warn "Attempting to continue without EFI mount (GRUB install will fail)."
fi

# --- Debootstrap ---
log_info "Installing base system (this will take a while)..."
debootstrap --arch=amd64 "$TARGET_DISTRO" /mnt/target http://archive.ubuntu.com/ubuntu/

# --- Chroot Configuration ---
log_info "Configuring chroot environment..."

# Generate fstab
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")
EFI_UUID=$(blkid -s UUID -o value "$PART_EFI") || EFI_UUID="UNKNOWN"

cat <<EOF > /mnt/target/etc/fstab
# /etc/fstab: static file system information.
UUID=$ROOT_UUID /               ext4    $MOUNT_OPTS 0       1
UUID=$EFI_UUID  /boot/efi       vfat    umask=0077      0       2
tmpfs           /tmp            tmpfs   defaults,noatime,mode=1777 0       0
tmpfs           /var/tmp        tmpfs   defaults,noatime,mode=1777 0       0
/swapfile       none            swap    sw              0       0
EOF

# Set hostname
echo "surface-pro" > /mnt/target/etc/hostname
echo "127.0.0.1 localhost surface-pro" > /mnt/target/etc/hosts

# Prepare chroot helper script
cat <<CHROOT_EOF > /mnt/target/setup-internal.sh
#!/bin/bash
set -Eeuo pipefail

TARGET_DISTRO="$TARGET_DISTRO"
TARGET_USER="$TARGET_USER"
TARGET_PASSWORD="$TARGET_PASSWORD"
ROOT_PASSWORD="$ROOT_PASSWORD"
SWAP_SIZE_GB="$SWAP_SIZE_GB"

# Colors
GREEN='\033[0;32m'
NC='\033[0m'
log_step() { echo -e "\${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] INFO: >>> \$1\${NC}"; }

export DEBIAN_FRONTEND=noninteractive

# Configure APT sources
cat <<EOF > /etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu/ \$TARGET_DISTRO main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ \$TARGET_DISTRO-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ \$TARGET_DISTRO-security main restricted universe multiverse
EOF

# Update and install basic tools
apt update
apt install -y --fix-missing --no-install-recommends software-properties-common gnupg curl wget ca-certificates lsb-release
apt clean

# Locales
apt install -y --fix-missing locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
apt clean

# Timezone
ln -fs /usr/share/zoneinfo/UTC /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata

# Keyboard and Console
apt install -y --fix-missing keyboard-configuration console-setup
apt clean

# Swapfile
log_step "Creating swapfile..."
swapoff /swapfile || true
fallocate -l \${SWAP_SIZE_GB}G /swapfile
chmod 600 /swapfile
mkswap /swapfile

# Sysctl optimizations
log_step "Configuring sysctl..."
cat <<EOF > /etc/sysctl.d/99-surface.conf
vm.swappiness=20
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=20
EOF

# journald optimization
log_step "Configuring journald..."
mkdir -p /etc/systemd/journald.conf.d
cat <<EOF > /etc/systemd/journald.conf.d/volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=64M
EOF

# apt optimizations
log_step "Configuring apt optimizations..."
cat <<EOF > /etc/apt/apt.conf.d/99-durability
Binary::apt::APT::Keep-Downloaded-Packages "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "0";
EOF

# Users
log_step "Creating users..."
echo "root:\$ROOT_PASSWORD" | chpasswd
useradd -m -s /bin/bash -G sudo,plugdev,audio,video,render,input,dialout "\$TARGET_USER"
echo "\$TARGET_USER:\$TARGET_PASSWORD" | chpasswd

# Repository additions
log_step "Adding repositories..."
add-apt-repository -y multiverse

# NodeSource
curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -

# Google Chrome
wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /etc/apt/trusted.gpg.d/google-chrome.gpg
echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list

# Linux Surface
wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/linux-surface.gpg
echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" > /etc/apt/sources.list.d/linux-surface.list

apt update

# Package Installation
log_step "Installing packages (Base)..."
apt install -y --fix-missing sudo systemd curl wget nano vim git network-manager openssh-client openssh-server initramfs-tools
apt clean

log_step "Installing packages (Desktop)..."
apt install -y --fix-missing ubuntu-desktop-minimal gdm3
apt clean

log_step "Installing packages (Development)..."
apt install -y --fix-missing build-essential cmake
apt clean

log_step "Installing packages (Firmware)..."
apt install -y --fix-missing linux-firmware intel-microcode
apt clean

log_step "Installing packages (Android)..."
apt install -y --fix-missing adb fastboot
apt clean
# Android udev rules
wget -O /etc/udev/rules.d/51-android.rules https://raw.githubusercontent.com/M0Rf30/android-udev-rules/master/51-android.rules
chmod a+r /etc/udev/rules.d/51-android.rules

log_step "Installing packages (Node.js & Chrome)..."
apt install -y --fix-missing nodejs google-chrome-stable
apt clean

log_step "Installing packages (Surface Support)..."
# Ubuntu 24.04 (noble) compatible
apt install -y --fix-missing linux-image-surface linux-headers-surface libwacom-surface iptsd linux-surface-secureboot-mok thermald
apt clean

# Surface optimizations
log_step "Applying Surface optimizations..."

# Thermald configuration for Surface Pro 7
mkdir -p /etc/thermald
wget -O /etc/thermald/thermal-conf.xml https://raw.githubusercontent.com/linux-surface/linux-surface/refs/heads/master/contrib/thermald/surface_pro_7/thermal-conf.xml
wget -O /etc/thermald/thermal-cpu-cdev-order.xml https://raw.githubusercontent.com/linux-surface/linux-surface/refs/heads/master/contrib/thermald/surface_pro_7/thermal-cpu-cdev-order.xml

# Tablet mode: ignore lid switch
mkdir -p /etc/systemd/logind.conf.d
cat <<EOF > /etc/systemd/logind.conf.d/surface.conf
[Login]
HandleLidSwitch=ignore
EOF

# Bootloader
log_step "Installing GRUB..."
apt install -y --fix-missing grub-efi-amd64
apt clean

# Screen flicker fix & other GRUB modifications
sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="i915.enable_psr=0 /' /etc/default/grub

if mountpoint -q /boot/efi; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable
    update-grub
else
    echo "Skipping GRUB install as /boot/efi is not mounted."
fi

# Update Initramfs
log_step "Updating initramfs..."
update-initramfs -u

# Chrome cache in RAM
log_step "Optimizing Chrome..."
mkdir -p /home/\$TARGET_USER/.config/google-chrome
cat <<EOF > /etc/profile.d/chrome-cache.sh
export CHROME_FLAGS="--disk-cache-dir=/dev/shm/\$TARGET_USER-chrome-cache"
EOF

# First login script
log_step "Creating first-login script..."
cat <<'USER_EOF' > /home/\$TARGET_USER/.first-login.sh
#!/bin/bash
if [ ! -f ~/.gitconfig ]; then
    echo "First login: Configuring Git"
    read -r -p "Enter Git username: " GIT_USER
    read -r -p "Enter Git email: " GIT_EMAIL
    git config --global user.name "\$GIT_USER"
    git config --global user.email "\$GIT_EMAIL"
fi

if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "Generating SSH key..."
    mkdir -p ~/.ssh
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
    echo "Your public SSH key is:"
    cat ~/.ssh/id_ed25519.pub
fi
USER_EOF
chmod +x /home/\$TARGET_USER/.first-login.sh
chown \$TARGET_USER:\$TARGET_USER /home/\$TARGET_USER/.first-login.sh

# Trigger first login script
echo "[[ -f ~/.first-login.sh ]] && . ~/.first-login.sh" >> /home/\$TARGET_USER/.bashrc

# Final Cleanup
log_step "Final cleanup..."
# Disable periodic TRIM
systemctl disable fstrim.timer || true
apt autoremove -y
apt clean
rm /setup-internal.sh

CHROOT_EOF

chmod +x /mnt/target/setup-internal.sh

log_info "Entering chroot..."
mkdir -p /mnt/target/dev /mnt/target/dev/pts /mnt/target/proc /mnt/target/sys /mnt/target/sys/firmware/efi/efivars
mount --bind /dev /mnt/target/dev
mount --bind /dev/pts /mnt/target/dev/pts
mount --bind /proc /mnt/target/proc
mount --bind /sys /mnt/target/sys
if [ -d /sys/firmware/efi/efivars ]; then
    mount --bind /sys/firmware/efi/efivars /mnt/target/sys/firmware/efi/efivars
else
    log_warn "EFI vars not found on host, skipping bind mount."
fi

chroot /mnt/target /setup-internal.sh

cleanup
log_success "Installation complete!"
log_info "You can now unmount and reboot."
