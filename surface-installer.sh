#!/usr/bin/env bash

set -Eeuo pipefail

# Locate script directory to execute modular scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source config.sh for logging and common helpers
# shellcheck source=config.sh
source "$SCRIPT_DIR/config.sh"

# Redirect stdout and stderr to the log file while preserving console output
exec > >(tee -a "$LOG_FILE") 2>&1

CLEANUP_ON_ERROR=1

error_handler() {
    local line_no=$1
    local last_command=$2
    local exit_code=$3
    log_error "Main Installer: Command '$last_command' failed at line $line_no with exit code $exit_code"
    if [ "${CLEANUP_ON_ERROR:-0}" = "1" ]; then
        cleanup_mounts
    fi
    exit "$exit_code"
}

trap 'error_handler $LINENO "$BASH_COMMAND" $?' ERR
trap 'log_error "Interrupted by signal."; cleanup_mounts; exit 130' INT TERM

usage() {
    cat <<EOF
Usage: $0 [--yes] [--reuse] [DEVICE]

  DEVICE    Target whole disk (e.g. /dev/sdX). Omit for interactive selection.
  --yes     Skip the interactive "YES" confirmation (DESTRUCTIVE).
  --reuse   Reuse an existing EFI/ROOT formatted device without reformatting.

Environment:
  TEST_MODE=1           Simulate the slow steps (for loopback/testing).
  ASSUME_YES=1          Same as --yes.
  TARGET_USER=...       Username to create (default: surfaceuser).
  TARGET_PASSWORD=...   Password for the user (default: random).
  ROOT_PASSWORD=...     Root password (default: random).
  NODE_MAJOR=...        Node.js major version (default: 24).
  ALLOW_MISSING_EFI=1   Continue if the EFI partition cannot be mounted.
EOF
}

TARGET_DEV_ARG=""
for arg in "$@"; do
    case "$arg" in
        --yes|-y)
            ASSUME_YES=1
            ;;
        --reuse)
            REUSE_EXISTING=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        -*)
            log_error "Unknown option: $arg"
            usage
            exit 2
            ;;
        *)
            if [ -n "$TARGET_DEV_ARG" ]; then
                log_error "Only one target device may be specified."
                exit 2
            fi
            TARGET_DEV_ARG="$arg"
            ;;
    esac
done
export ASSUME_YES REUSE_EXISTING

assert_root
check_host_tools
select_target_device "$TARGET_DEV_ARG"

if [ "$GENERATED_CREDENTIALS" = "1" ]; then
    CREDENTIALS_CONTENT="Installed user: $TARGET_USER
User password:  $TARGET_PASSWORD
Root password:  $ROOT_PASSWORD"
    CREDENTIALS_FILE="$SCRIPT_DIR/install-credentials.txt"

    if ! ( umask 077; printf '%s\n' "$CREDENTIALS_CONTENT" > "$CREDENTIALS_FILE" ) 2>/dev/null; then
        CREDENTIALS_FILE="/root/surface-install-credentials.txt"
        ( umask 077; printf '%s\n' "$CREDENTIALS_CONTENT" > "$CREDENTIALS_FILE" )
        log_warn "Script directory is not writable; wrote generated credentials to $CREDENTIALS_FILE."
    else
        log_info "Generated credentials written to $CREDENTIALS_FILE (mode 600)."
    fi
    chmod 600 "$CREDENTIALS_FILE"
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

CLEANUP_ON_ERROR=0
log_success "=== All installation steps completed successfully! ==="
