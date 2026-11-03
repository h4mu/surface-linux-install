#!/usr/bin/env bash

# --- Shared Configuration & Constants ---
TARGET_DISTRO="noble"
export TARGET_USER="surfaceuser"
export TARGET_PASSWORD="surfaceuser"
export ROOT_PASSWORD="root"
export TEST_MODE="${TEST_MODE:-0}"

if [ "$TEST_MODE" = "1" ]; then
    export SWAP_SIZE_GB=1
else
    export SWAP_SIZE_GB=4
fi

# Colors for logging
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Logging Setup ---
LOG_FILE="install.log"

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

# --- Common Helper Functions ---
resolve_partitions() {
    local dev="$1"
    if [[ "$dev" == *nvme* ]] || [[ "$dev" == *mmcblk* ]]; then
        PART_EFI="${dev}p1"
        PART_ROOT="${dev}p2"
    elif [[ "$dev" == *loop* ]]; then
        # Check for loopXp1 format first, then loopX1
        if [ -b "${dev}p1" ]; then
            PART_EFI="${dev}p1"
            PART_ROOT="${dev}p2"
        elif [ -b "${dev}1" ]; then
            PART_EFI="${dev}1"
            PART_ROOT="${dev}2"
        else
            # Default to p1/p2 for loop devices, especially with -P flag
            PART_EFI="${dev}p1"
            PART_ROOT="${dev}p2"
        fi
    else
        PART_EFI="${dev}1"
        PART_ROOT="${dev}2"
    fi
    export PART_EFI
    export PART_ROOT
}

assert_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
}

check_host_tools() {
    local MISSING_TOOLS=()
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
}

safe_settle() {
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle -t 5 || true
    else
        sleep 1
    fi
}
