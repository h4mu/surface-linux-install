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

if [ -z "${1:-}" ]; then
    log_error "Target device argument is required (e.g. /dev/sdX or /dev/loop0)"
    exit 1
fi
TARGET_DEV="$1"

# Resolve partitions paths
resolve_partitions "$TARGET_DEV"

# Check if target partitions actually exist
if [ ! -b "$PART_EFI" ] || [ ! -b "$PART_ROOT" ]; then
    log_error "Partition nodes $PART_EFI or $PART_ROOT do not exist. Please run step 01 first."
    exit 1
fi

# --- Mounting ---
log_info "Setting up mount points..."
mkdir -p /mnt/target
MOUNT_OPTS="noatime,lazytime,commit=120,errors=remount-ro"

# Mount Root if not already mounted
if ! mountpoint -q /mnt/target; then
    log_info "Mounting root partition $PART_ROOT to /mnt/target..."
    mount -o "$MOUNT_OPTS" "$PART_ROOT" /mnt/target
else
    log_info "Root partition already mounted at /mnt/target."
fi

# Mount EFI if not already mounted
mkdir -p /mnt/target/boot/efi
if ! mountpoint -q /mnt/target/boot/efi; then
    log_info "Mounting EFI partition $PART_EFI to /mnt/target/boot/efi..."
    if ! mount "$PART_EFI" /mnt/target/boot/efi; then
        if [ "${ALLOW_MISSING_EFI:-0}" = "1" ]; then
            log_warn "Failed to mount EFI partition; continuing because ALLOW_MISSING_EFI=1."
            log_warn "GRUB installation will be skipped and the resulting system may not boot."
        else
            log_error "Failed to mount EFI partition $PART_EFI. Refusing to build an unbootable system."
            log_info "For loopback testing where EFI mounting is unavailable, set ALLOW_MISSING_EFI=1."
            exit 1
        fi
    fi
else
    log_info "EFI partition already mounted at /mnt/target/boot/efi."
fi

# --- Debootstrap ---
# Idempotency: skip debootstrap if base files are already installed (e.g. /usr/bin/dpkg exists)
if [ -f /mnt/target/usr/bin/dpkg ] || [ -f /mnt/target/bin/bash ]; then
    log_info "Base system already installed/simulated. Skipping debootstrap."
elif [ "$TEST_MODE" = "1" ]; then
    log_info "TEST_MODE is enabled. Simulating base system install (skipping slow debootstrap download)..."
    mkdir -p /mnt/target/usr/bin /mnt/target/bin /mnt/target/etc /mnt/target/home
    touch /mnt/target/usr/bin/dpkg
    touch /mnt/target/bin/bash
else
    log_info "Installing base system (this will take a while)..."
    debootstrap --arch=amd64 "$TARGET_DISTRO" /mnt/target http://archive.ubuntu.com/ubuntu/
fi

# --- Chroot Configuration ---
log_info "Configuring fstab, hostname and hosts..."

# Generate fstab only with valid filesystem UUIDs
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT" || true)
EFI_UUID=$(blkid -s UUID -o value "$PART_EFI" || true)

if [ -z "$ROOT_UUID" ] || [ -z "$EFI_UUID" ]; then
    log_error "Could not determine filesystem UUIDs (root='$ROOT_UUID', efi='$EFI_UUID')."
    exit 1
fi

cat <<EOF > /mnt/target/etc/fstab
# /etc/fstab: static file system information.
UUID=$ROOT_UUID /               ext4    $MOUNT_OPTS 0       1
UUID=$EFI_UUID  /boot/efi       vfat    umask=0077      0       2
tmpfs           /tmp            tmpfs   defaults,noatime,mode=1777 0       0
tmpfs           /var/tmp        tmpfs   defaults,noatime,mode=1777 0       0
/swapfile       none            swap    sw,nofail       0       0
EOF

# Set hostname
echo "surface-pro" > /mnt/target/etc/hostname
cat > /mnt/target/etc/hosts <<EOF
127.0.0.1 localhost surface-pro
::1       localhost ip6-localhost ip6-loopback
EOF

# Mount bind mounts for chroot
log_info "Setting up bind mounts..."

# Create basic dirs under target root before bind mounts are mounted
mkdir -p /mnt/target/dev /mnt/target/dev/pts /mnt/target/proc /mnt/target/sys /mnt/target/run

bind_mount() {
    local src="$1"
    local dest="$2"
    if [ -d "$src" ]; then
        if ! mountpoint -q "$dest"; then
            mount --bind "$src" "$dest"
            log_info "Mounted $src to $dest"
        else
            log_info "$dest is already mounted."
        fi
    fi
}

bind_mount /dev /mnt/target/dev
bind_mount /dev/pts /mnt/target/dev/pts
bind_mount /proc /mnt/target/proc
bind_mount /sys /mnt/target/sys
bind_mount /run /mnt/target/run

if [ -d /sys/firmware/efi/efivars ]; then
    mkdir -p /mnt/target/sys/firmware/efi/efivars
    bind_mount /sys/firmware/efi/efivars /mnt/target/sys/firmware/efi/efivars
else
    log_warn "EFI vars not found on host, skipping bind mount."
fi

log_success "Chroot environment setup completed."
