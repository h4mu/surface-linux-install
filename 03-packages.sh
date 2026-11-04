#!/usr/bin/env bash

set -Eeuo pipefail

# Locate script directory to source configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# Redirect stdout and stderr to the log file while preserving console output
exec > >(tee -a "$LOG_FILE") 2>&1

CLEANUP_ON_ERROR=1

error_handler() {
    local line_no=$1
    local last_command=$2
    local exit_code=$3
    log_error "Command '$last_command' failed at line $line_no with exit code $exit_code"
    if [ "${CLEANUP_ON_ERROR:-0}" = "1" ]; then
        cleanup_mounts
    fi
    exit "$exit_code"
}

trap 'error_handler $LINENO "$BASH_COMMAND" $?' ERR
trap 'log_error "Interrupted by signal."; cleanup_mounts; exit 130' INT TERM

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
    # Configure swapfile on the host. Doing this inside the chroot is unreliable:
    # the chroot shares the host's /proc, so if the host already has an active
    # /swapfile, mkswap refuses the target's /swapfile ("is mounted") and
    # swapoff cannot find the host's swap area from inside the chroot.
    log_info "Configuring swapfile..."
    SWAP_SIZE_BYTES=$((SWAP_SIZE_GB * 1024 * 1024 * 1024))
    CURRENT_SWAP_SIZE=$(stat -c %s /mnt/target/swapfile 2>/dev/null || echo 0)

    if [ "$CURRENT_SWAP_SIZE" -ne "$SWAP_SIZE_BYTES" ]; then
        log_info "Creating swapfile of size ${SWAP_SIZE_GB}GB..."
        rm -f /mnt/target/swapfile
        fallocate -l ${SWAP_SIZE_GB}G /mnt/target/swapfile
        chmod 600 /mnt/target/swapfile
        mkswap /mnt/target/swapfile
    else
        log_info "Swapfile of correct size already exists. Skipping."
    fi

    # Prepare chroot helper script
    cat <<CHROOT_EOF > /mnt/target/setup-packages.sh
#!/bin/bash
set -Eeuo pipefail

TARGET_DISTRO="$TARGET_DISTRO"
TARGET_USER="\${TARGET_USER:?TARGET_USER is required}"
TARGET_PASSWORD="\${TARGET_PASSWORD:?TARGET_PASSWORD is required}"
ROOT_PASSWORD="\${ROOT_PASSWORD:?ROOT_PASSWORD is required}"
SWAP_SIZE_GB="$SWAP_SIZE_GB"
GENERATED_CREDENTIALS="$GENERATED_CREDENTIALS"

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
apt-get update -o Acquire::Retries=3
apt-get install -y --no-install-recommends software-properties-common gnupg curl wget ca-certificates lsb-release
apt-get clean

# Locales
apt-get install -y locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8
apt-get clean

# Timezone
ln -fs /usr/share/zoneinfo/UTC /etc/localtime
dpkg-reconfigure --frontend noninteractive tzdata

# Keyboard and Console
apt-get install -y keyboard-configuration console-setup
apt-get clean

# Swapfile was created on the host before entering the chroot
log_step "Swapfile configured."

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
    if [ "\$GENERATED_CREDENTIALS" = "1" ]; then
        chage -d 0 "\$TARGET_USER"
    fi
else
    log_step "User \$TARGET_USER already exists."
fi

# Repository additions
log_step "Adding repositories..."
mkdir -p /etc/apt/keyrings

# NodeSource (manual repository setup instead of piping a remote script to bash)
if [ ! -f /etc/apt/sources.list.d/nodesource.list ]; then
    log_step "Adding NodeSource repository..."
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
fi

# Google Chrome
if [ ! -f /etc/apt/sources.list.d/google-chrome.list ]; then
    log_step "Adding Google Chrome repository..."
    wget -qO - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list
fi

# Linux Surface
if [ ! -f /etc/apt/sources.list.d/linux-surface.list ]; then
    log_step "Adding Linux Surface repository..."
    wget -qO - https://raw.githubusercontent.com/linux-surface/linux-surface/master/pkg/keys/surface.asc | gpg --dearmor -o /etc/apt/keyrings/linux-surface.gpg
    echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/linux-surface.gpg] https://pkg.surfacelinux.com/debian release main" > /etc/apt/sources.list.d/linux-surface.list
fi

apt-get update -o Acquire::Retries=3

# Package Installation
log_step "Installing packages (Base)..."
apt-get install -y sudo systemd curl wget nano vim git network-manager openssh-client openssh-server initramfs-tools
apt-get clean

log_step "Installing packages (Desktop)..."
apt-get install -y ubuntu-desktop-minimal gdm3
apt-get clean

log_step "Installing packages (Development)..."
apt-get install -y build-essential cmake
apt-get clean

log_step "Installing packages (Firmware)..."
apt-get install -y linux-firmware intel-microcode
apt-get clean

log_step "Installing packages (Android)..."
apt-get install -y adb fastboot
apt-get clean
# Android udev rules
if [ ! -f /etc/udev/rules.d/51-android.rules ]; then
    wget -O /etc/udev/rules.d/51-android.rules https://raw.githubusercontent.com/M0Rf30/android-udev-rules/master/51-android.rules
    chmod a+r /etc/udev/rules.d/51-android.rules
fi

log_step "Installing packages (Node.js & Chrome)..."
apt-get install -y nodejs google-chrome-stable
apt-get clean

log_step "Installing packages (Surface Support)..."
apt-get install -y linux-image-surface linux-headers-surface libwacom-surface iptsd linux-surface-secureboot-mok thermald
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
CHROOT_EOF

    chmod +x /mnt/target/setup-packages.sh

    log_info "Entering chroot to install packages..."
    chroot /mnt/target /setup-packages.sh
    rm -f /mnt/target/setup-packages.sh
    log_success "Packages installation phase complete."
fi
