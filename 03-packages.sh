#!/usr/bin/env bash

set -Eeuo pipefail

# Locate script directory to source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# Redirect stdout and stderr to the log file while preserving console output
exec > >(tee -a "$LOG_FILE") 2>&1

error_handler() {
    local line_no=$1
    local last_command=$2
    local exit_code=$3
    log_error "Command '$last_command' failed at line $line_no with exit code $exit_code"
    exit "$exit_code"
}

trap 'error_handler $LINENO "$BASH_COMMAND" $?' ERR

assert_root

# Ensure /mnt/target is mounted
if ! mountpoint -q /mnt/target; then
    log_error "/mnt/target is not mounted. Run 02-chroot-setup.sh first."
    exit 1
fi

if [ "$TEST_MODE" = "1" ]; then
    log_info "TEST_MODE is enabled. Simulating packages configuration..."
    
    # Simulate swapfile configuration (Idempotent: if /swapfile size is correct, skip)
    log_info "Configuring simulated swapfile..."
    SWAP_SIZE_BYTES=$((SWAP_SIZE_GB * 1024 * 1024 * 1024))
    CURRENT_SWAP_SIZE=$(stat -c %s /mnt/target/swapfile 2>/dev/null || echo 0)

    if [ "$CURRENT_SWAP_SIZE" -ne "$SWAP_SIZE_BYTES" ]; then
        log_info "Creating simulated swapfile of size ${SWAP_SIZE_GB}GB..."
        fallocate -l ${SWAP_SIZE_GB}G /mnt/target/swapfile
        chmod 600 /mnt/target/swapfile
    else
        log_info "Simulated swapfile already exists with correct size."
    fi

    # Sysctl optimizations
    log_info "Configuring simulated sysctl..."
    mkdir -p /mnt/target/etc/sysctl.d
    cat <<EOF > /mnt/target/etc/sysctl.d/99-surface.conf
vm.swappiness=20
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=20
EOF

    # journald optimization
    log_info "Configuring simulated journald..."
    mkdir -p /mnt/target/etc/systemd/journald.conf.d
    cat <<EOF > /mnt/target/etc/systemd/journald.conf.d/volatile.conf
[Journal]
Storage=volatile
RuntimeMaxUse=64M
EOF

    # apt optimizations
    log_info "Configuring simulated apt optimizations..."
    mkdir -p /mnt/target/etc/apt/apt.conf.d
    cat <<EOF > /mnt/target/etc/apt/apt.conf.d/99-durability
Binary::apt::APT::Keep-Downloaded-Packages "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "0";
EOF

    # Create mock user
    log_info "Configuring simulated users..."
    mkdir -p "/mnt/target/home/$TARGET_USER"
    touch "/mnt/target/home/$TARGET_USER/.bashrc"

    log_success "Packages simulation phase complete."
else
    # Prepare chroot helper script
    cat <<CHROOT_EOF > /mnt/target/setup-packages.sh
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
log_step() { echo -e "\${GREEN}[\$(date +'%Y-%m-%d %H:%M:%S')] INFO: >>> \$1\${NC}"; }

export DEBIAN_FRONTEND=noninteractive

# Configure APT sources
cat <<EOF > /etc/apt/sources.list
deb http://archive.ubuntu.com/ubuntu/ \${TARGET_DISTRO} main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ \${TARGET_DISTRO}-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ \${TARGET_DISTRO}-security main restricted universe multiverse
EOF

# Update and install basic tools
apt-get update
apt-get install -y --fix-missing --no-install-recommends software-properties-common gnupg curl wget ca-certificates lsb-release
apt-get clean

# Locales
apt-get install -y --fix-missing locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
apt-get clean

# Timezone
ln -fs /usr/share/zoneinfo/UTC /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata

# Keyboard and Console
apt-get install -y --fix-missing keyboard-configuration console-setup
apt-get clean

# Swapfile (idempotent: if /swapfile size is correct, skip)
log_step "Configuring swapfile..."
SWAP_SIZE_BYTES=\$((SWAP_SIZE_GB * 1024 * 1024 * 1024))
CURRENT_SWAP_SIZE=\$(stat -c %s /swapfile 2>/dev/null || echo 0)

if [ "\$CURRENT_SWAP_SIZE" -ne "\$SWAP_SIZE_BYTES" ]; then
    log_step "Creating swapfile of size \${SWAP_SIZE_GB}GB..."
    swapoff /swapfile || true
    fallocate -l \${SWAP_SIZE_GB}G /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
else
    log_step "Swapfile of correct size already exists. Skipping."
fi

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

# Users (Idempotent check before creating root/user)
log_step "Configuring users..."
echo "root:\$ROOT_PASSWORD" | chpasswd

if ! id -u "\$TARGET_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,plugdev,audio,video,render,input,dialout "\$TARGET_USER"
    echo "\$TARGET_USER:\$TARGET_PASSWORD" | chpasswd
else
    log_step "User \$TARGET_USER already exists."
fi

# Repository additions
log_step "Adding repositories..."
add-apt-repository -y multiverse

# NodeSource
if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
    log_step "Adding NodeSource repository..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
fi

# Google Chrome
if [ ! -f /etc/apt/sources.list.d/google-chrome.list ]; then
    log_step "Adding Google Chrome repository..."
    wget -q -O - https://dl-ssl.google.com/linux/linux_signing_key.pub | gpg --dearmor > /etc/apt/trusted.gpg.d/google-chrome.gpg
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
fi

# Linux Surface
if [ ! -f /etc/apt/sources.list.d/linux-surface.list ]; then
    log_step "Adding Linux Surface repository..."
    wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc | gpg --dearmor > /etc/apt/trusted.gpg.d/linux-surface.gpg
    echo "deb [arch=amd64] https://pkg.surfacelinux.com/debian release main" > /etc/apt/sources.list.d/linux-surface.list
fi

apt-get update

# Package Installation
log_step "Installing packages (Base)..."
apt-get install -y --fix-missing sudo systemd curl wget nano vim git network-manager openssh-client openssh-server initramfs-tools
apt-get clean

log_step "Installing packages (Desktop)..."
apt-get install -y --fix-missing ubuntu-desktop-minimal gdm3
apt-get clean

log_step "Installing packages (Development)..."
apt-get install -y --fix-missing build-essential cmake
apt-get clean

log_step "Installing packages (Firmware)..."
apt-get install -y --fix-missing linux-firmware intel-microcode
apt-get clean

log_step "Installing packages (Android)..."
apt-get install -y --fix-missing adb fastboot
apt-get clean
# Android udev rules
if [ ! -f /etc/udev/rules.d/51-android.rules ]; then
    wget -O /etc/udev/rules.d/51-android.rules https://raw.githubusercontent.com/M0Rf30/android-udev-rules/master/51-android.rules
    chmod a+r /etc/udev/rules.d/51-android.rules
fi

log_step "Installing packages (Node.js & Chrome)..."
apt-get install -y --fix-missing nodejs google-chrome-stable
apt-get clean

log_step "Installing packages (Surface Support)..."
apt-get install -y --fix-missing linux-image-surface linux-headers-surface libwacom-surface iptsd linux-surface-secureboot-mok thermald
apt-get clean

# Surface optimizations
log_step "Applying Surface optimizations..."

# Thermald configuration for Surface Pro 7
mkdir -p /etc/thermald
if [ ! -f /etc/thermald/thermal-conf.xml ]; then
    wget -O /etc/thermald/thermal-conf.xml https://raw.githubusercontent.com/linux-surface/linux-surface/refs/heads/master/contrib/thermald/surface_pro_7/thermal-conf.xml
fi
if [ ! -f /etc/thermald/thermal-cpu-cdev-order.xml ]; then
    wget -O /etc/thermald/thermal-cpu-cdev-order.xml https://raw.githubusercontent.com/linux-surface/linux-surface/refs/heads/master/contrib/thermald/surface_pro_7/thermal-cpu-cdev-order.xml
fi

# Tablet mode: ignore lid switch
mkdir -p /etc/systemd/logind.conf.d
cat <<EOF > /etc/systemd/logind.conf.d/surface.conf
[Login]
HandleLidSwitch=ignore
EOF

# Finished packages installation inside chroot
log_step "Chroot packages script finished."
rm /setup-packages.sh
CHROOT_EOF

    chmod +x /mnt/target/setup-packages.sh

    log_info "Entering chroot to install packages..."
    chroot /mnt/target /setup-packages.sh
    log_success "Packages installation phase complete."
fi
