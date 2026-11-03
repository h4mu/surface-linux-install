#!/usr/bin/env bash

set -Eeuo pipefail

# Locate script directory to execute modular scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config.sh for logging and common helpers
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# Redirect stdout and stderr to the log file while preserving console output
exec > >(tee -a "$LOG_FILE") 2>&1

error_handler() {
    local line_no=$1
    local last_command=$2
    local exit_code=$3
    log_error "Main Installer: Command '$last_command' failed at line $line_no with exit code $exit_code"
    exit "$exit_code"
}

trap 'error_handler $LINENO "$BASH_COMMAND" $?' ERR

assert_root
check_host_tools

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

log_info "Starting modular Surface Pro 7 Ubuntu installation on $TARGET_DEV..."

# Step 1: Disk partitioning + formatting
log_info "=== [Step 1/4] Partitioning & Formatting ==="
bash "$SCRIPT_DIR/01-partition-format.sh" "$TARGET_DEV"

# Step 2: Chroot setup & base installation (debootstrap)
log_info "=== [Step 2/4] Chroot Setup & Base System Installation ==="
bash "$SCRIPT_DIR/02-chroot-setup.sh" "$TARGET_DEV"

# Step 3: Package installation
log_info "=== [Step 3/4] Package Configuration & Installation ==="
bash "$SCRIPT_DIR/03-packages.sh"

# Step 4: Boot setup & cleanup
log_info "=== [Step 4/4] Bootloader Setup & System Cleanup ==="
bash "$SCRIPT_DIR/04-boot-setup.sh"

log_success "=== All installation steps completed successfully! ==="
