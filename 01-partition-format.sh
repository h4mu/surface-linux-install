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
check_host_tools

# --- Drive Selection ---
# When invoked by the main installer the device and confirmation are already
# provided; when run standalone this performs the full interactive flow.
select_target_device "${1:-}"
log_info "Using target device: $TARGET_DEV"

# Resolve partitions paths
resolve_partitions "$TARGET_DEV"

# Idempotency check: only reuse an existing layout when explicitly requested.
IS_FORMATTED=false
if blkid -t LABEL="EFI" -o device | grep -q "^${PART_EFI}$" && blkid -t LABEL="ROOT" -o device | grep -q "^${PART_ROOT}$"; then
    IS_FORMATTED=true
fi

if [ "$IS_FORMATTED" = true ] && [ "$REUSE_EXISTING" = "1" ]; then
    log_info "Target device $TARGET_DEV is already partitioned and formatted with 'EFI' and 'ROOT' partitions."
    log_info "Reusing the existing layout because --reuse was supplied."
else
    log_info "Wiping existing signatures on $TARGET_DEV..."
    # If the partitions are mounted, unmount them before wiping
    if mountpoint -q /mnt/target/boot/efi 2>/dev/null; then
        umount /mnt/target/boot/efi || true
    fi
    if mountpoint -q /mnt/target 2>/dev/null; then
        umount /mnt/target || true
    fi

    wipefs -af "$TARGET_DEV"
    sgdisk -Z "$TARGET_DEV"
    safe_settle

    log_info "Creating partitions..."
    # GPT
    # 1: EFI System Partition (512MB)
    # 2: Root (remainder)
    sgdisk -n 1:0:+512M -t 1:ef00 -c 1:"EFI System Partition" "$TARGET_DEV"
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"Ubuntu Root" "$TARGET_DEV"
    safe_settle

    # Use partprobe if available to refresh partition table
    if command -v partprobe >/dev/null 2>&1; then
        partprobe "$TARGET_DEV"
        safe_settle
    fi

    # Special handling for loop devices to ensure partition nodes appear
    if [[ "$TARGET_DEV" == *loop* ]]; then
        partx -u "$TARGET_DEV" || true
        safe_settle
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
    log_success "Partitioning and formatting completed successfully."
fi
