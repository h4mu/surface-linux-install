#!/usr/bin/env bash

# --- Shared Configuration & Constants ---
export TARGET_DISTRO="${TARGET_DISTRO:-noble}"
export TARGET_USER="${TARGET_USER:-surfaceuser}"
export NODE_MAJOR="${NODE_MAJOR:-24}"
export ASSUME_YES="${ASSUME_YES:-0}"
export REUSE_EXISTING="${REUSE_EXISTING:-0}"
export TEST_MODE="${TEST_MODE:-0}"

# Credentials: honour environment overrides when provided; otherwise generate
# strong random passwords once per installer invocation. Generated credentials
# are written to install-credentials.txt by the main installer.
gen_password() {
    dd if=/dev/urandom bs=18 count=1 2>/dev/null | base64 | tr -d '\n='
}

GENERATED_CREDENTIALS="${GENERATED_CREDENTIALS:-0}"

if [ -z "${TARGET_PASSWORD:-}" ]; then
    TARGET_PASSWORD="$(gen_password)"
    GENERATED_CREDENTIALS=1
fi
export TARGET_PASSWORD

if [ -z "${ROOT_PASSWORD:-}" ]; then
    ROOT_PASSWORD="$(gen_password)"
    GENERATED_CREDENTIALS=1
fi
export ROOT_PASSWORD
export GENERATED_CREDENTIALS

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
LOG_FILE="${LOG_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.log}"
export LOG_FILE
( umask 077; touch "$LOG_FILE" ) 2>/dev/null || true
chmod 600 "$LOG_FILE" 2>/dev/null || true

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

# --- Input Validation ---
if ! [[ "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    log_error "Invalid TARGET_USER '$TARGET_USER'. Use lowercase letters, digits, '_' or '-'."
    exit 1
fi

if ! [[ "$NODE_MAJOR" =~ ^[0-9]+$ ]]; then
    log_error "Invalid NODE_MAJOR '$NODE_MAJOR'. Expected a numeric major version."
    exit 1
fi

case "$TARGET_PASSWORD$ROOT_PASSWORD" in
    *$'\n'*|*$'\r'*)
        log_error "Passwords must not contain newline characters."
        exit 1
        ;;
esac

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
    local tools=(sgdisk wipefs lsblk udevadm mkfs.vfat mkfs.ext4 blkid tune2fs chroot findmnt mountpoint)

    if [ "$TEST_MODE" != "1" ]; then
        tools+=(debootstrap)
    fi

    for tool in "${tools[@]}"; do
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

validate_target_device() {
    local dev="$1"

    if [ -z "$dev" ]; then
        log_error "No target device specified."
        return 1
    fi

    if [ ! -b "$dev" ]; then
        log_error "Device $dev not found or not a block device."
        return 1
    fi

    local dev_type
    dev_type="$(lsblk -ndo TYPE "$dev" 2>/dev/null || true)"
    if [[ "$dev_type" != "disk" && "$dev_type" != "loop" ]]; then
        log_error "$dev is not a whole disk (detected type: ${dev_type:-unknown}). Refusing to operate on partitions or other device types."
        return 1
    fi

    # Refuse to touch the disk that backs the host root filesystem.
    local root_src root_disk
    root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
    if [ -n "$root_src" ]; then
        if [[ "$root_src" == "$dev"* ]]; then
            log_error "$dev contains the host root filesystem. Refusing to continue."
            return 1
        fi
        root_disk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -n1 || true)"
        if [ -n "$root_disk" ] && [ "/dev/$root_disk" = "$dev" ]; then
            log_error "$dev contains the host root filesystem. Refusing to continue."
            return 1
        fi
    fi

    # Refuse if the device or any child is mounted at a critical host path.
    local mnt
    while IFS= read -r mnt; do
        case "$mnt" in
            "")
                continue
                ;;
            /|/boot|/boot/efi|/home|/usr|/var|/etc)
                log_error "$dev has a partition mounted at $mnt. Refusing to continue."
                return 1
                ;;
        esac
    done < <(lsblk -nro MOUNTPOINT "$dev" 2>/dev/null || true)

    # Warn (but do not block) when the target does not look removable.
    local rm_flag
    rm_flag="$(lsblk -ndo RM "$dev" 2>/dev/null || true)"
    if [[ "$dev_type" != "loop" && "$rm_flag" = "0" ]]; then
        log_warn "$dev does not appear to be removable media. Double-check that this is the intended target."
    fi

    return 0
}

select_target_device() {
    local requested="${1:-}"
    local confirm

    if [ -n "$requested" ]; then
        TARGET_DEV="$requested"
        validate_target_device "$TARGET_DEV" || exit 1
        log_warn "ALL DATA ON $TARGET_DEV WILL BE DESTROYED!"
        if [ "$ASSUME_YES" = "1" ]; then
            log_warn "Proceeding without confirmation because --yes/ASSUME_YES=1 was supplied."
        else
            read -r -p "Type 'YES' to confirm: " confirm
            if [ "$confirm" != "YES" ]; then
                log_info "Aborting."
                exit 0
            fi
        fi
    else
        log_info "Available block devices:"
        lsblk -p -d -n -o NAME,SIZE,MODEL
        echo ""
        read -r -p "Enter the device path to install Ubuntu on (e.g., /dev/sdX): " TARGET_DEV
        validate_target_device "$TARGET_DEV" || exit 1
        log_warn "ALL DATA ON $TARGET_DEV WILL BE DESTROYED!"
        read -r -p "Type 'YES' to confirm: " confirm
        if [ "$confirm" != "YES" ]; then
            log_info "Aborting."
            exit 0
        fi
    fi

    export TARGET_DEV
    # The target has been confirmed; prevent sub-scripts from prompting again.
    export ASSUME_YES=1
}

cleanup_mounts() {
    if mountpoint -q /mnt/target 2>/dev/null; then
        rm -f /mnt/target/setup-packages.sh /mnt/target/setup-boot.sh 2>/dev/null || true
    fi
    sync || true
    local mnt
    for mnt in \
        /mnt/target/dev/pts \
        /mnt/target/dev \
        /mnt/target/proc \
        /mnt/target/sys/firmware/efi/efivars \
        /mnt/target/sys \
        /mnt/target/run \
        /mnt/target/boot/efi \
        /mnt/target; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
        fi
    done
}
