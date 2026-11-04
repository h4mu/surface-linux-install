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
    log_info "TEST_MODE is enabled. Simulating bootloader configuration..."

    # Simulated default grub
    log_info "Configuring simulated GRUB defaults..."
    mkdir -p /mnt/target/etc/default
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > /mnt/target/etc/default/grub

    if ! grep -q "i915.enable_psr=0" /mnt/target/etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="i915.enable_psr=0 /' /mnt/target/etc/default/grub
    fi

    # Chrome cache in RAM via a wrapper (Chrome does not read CHROME_FLAGS)
    log_info "Optimizing Chrome simulated config..."
    mkdir -p /mnt/target/usr/local/bin /mnt/target/usr/local/share/applications
    cat <<'WRAPPER_EOF' > /mnt/target/usr/local/bin/google-chrome
#!/bin/bash
exec /usr/bin/google-chrome --disk-cache-dir="/dev/shm/${USER:-$(id -un)}-chrome-cache" "$@"
WRAPPER_EOF
    chmod 0755 /mnt/target/usr/local/bin/google-chrome

    # First login script
    log_info "Creating simulated first-login script..."
    mkdir -p "/mnt/target/home/$TARGET_USER"
    cat <<'USER_EOF' > "/mnt/target/home/$TARGET_USER/.first-login.sh"
#!/bin/bash
# Only run in interactive shells.
[ -t 0 ] || exit 0

if [ ! -f ~/.gitconfig ]; then
    echo "First login: Configuring Git"
    read -r -p "Enter Git username: " GIT_USER
    read -r -p "Enter Git email: " GIT_EMAIL
    git config --global user.name "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"
fi

if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "Generating SSH key (you will be asked for a passphrase)..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
    echo "Your public SSH key is:"
    cat ~/.ssh/id_ed25519.pub
fi

# Remove the one-shot trigger after a successful run.
sed -i '/first-login\.sh/d' ~/.bashrc 2>/dev/null || true
rm -f ~/.first-login.sh
USER_EOF
    chmod +x "/mnt/target/home/$TARGET_USER/.first-login.sh"

    # Trigger first login script (idempotently append to bashrc)
    if ! grep -q "first-login.sh" "/mnt/target/home/$TARGET_USER/.bashrc" 2>/dev/null; then
        echo "[[ -f ~/.first-login.sh && -t 0 ]] && . ~/.first-login.sh" >> "/mnt/target/home/$TARGET_USER/.bashrc"
    fi

    log_success "Boot setup simulation phase complete."
else
    # Prepare chroot helper script
    cat <<CHROOT_EOF > /mnt/target/setup-boot.sh
#!/bin/bash
set -Eeuo pipefail

TARGET_USER="$TARGET_USER"

# Colors
GREEN='\033[0;32m'
NC='\033[0m'
log_step() { echo -e "\${GREEN}[\$(date +'%Y-%m-%d %H:%M:%S')] INFO: >>> \$1\${NC}"; }

export DEBIAN_FRONTEND=noninteractive

# Bootloader: use signed GRUB + shim so Secure Boot can chain-load it.
log_step "Installing GRUB..."
apt-get install -y grub-efi-amd64-signed shim-signed
apt-get clean

# Screen flicker fix & other GRUB modifications (Idempotent: modify default grub once)
if ! grep -q "i915.enable_psr=0" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="i915.enable_psr=0 /' /etc/default/grub
fi

if mountpoint -q /boot/efi; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable
    # Make the MOK Manager available for enrolling the linux-surface module key.
    if [ -f /usr/lib/shim/mmx64.efi.signed ] && [ -d /boot/efi/EFI/BOOT ]; then
        cp -f /usr/lib/shim/mmx64.efi.signed /boot/efi/EFI/BOOT/mmx64.efi
    fi
    update-grub

    # Prefer the linux-surface kernel when more than one kernel is installed.
    SURFACE_ENTRY="\$(sed -n "s/.*--id '\(gnulinux-[^']*surface[^']*\)'.*/\1/p" /boot/grub/grub.cfg | head -n1)"
    if [ -n "\$SURFACE_ENTRY" ]; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
        update-grub
        grub-set-default "\$SURFACE_ENTRY" || echo "WARNING: could not set the linux-surface kernel as default." >&2
    fi
else
    echo "Skipping GRUB install as /boot/efi is not mounted inside chroot."
fi

# Update initramfs for every installed kernel. Inside a chroot, uname -r reports
# the host kernel, so -u would target the wrong (or a missing) kernel.
log_step "Updating initramfs..."
update-initramfs -c -k all

# Basic boot sanity checks
log_step "Verifying boot files..."
if ! compgen -G "/boot/vmlinuz-*surface*" >/dev/null; then
    echo "WARNING: no linux-surface kernel found in /boot." >&2
fi
if ! compgen -G "/boot/initrd.img-*surface*" >/dev/null; then
    echo "WARNING: no linux-surface initramfs found in /boot." >&2
fi
if mountpoint -q /boot/efi && [ ! -f /boot/efi/EFI/BOOT/BOOTX64.EFI ]; then
    echo "ERROR: EFI fallback bootloader /boot/efi/EFI/BOOT/BOOTX64.EFI is missing." >&2
    exit 1
fi

# Chrome cache in RAM via a wrapper (Chrome does not read CHROME_FLAGS)
log_step "Optimizing Chrome..."
mkdir -p /usr/local/bin /usr/local/share/applications
cat <<'WRAPPER_EOF' > /usr/local/bin/google-chrome
#!/bin/bash
exec /usr/bin/google-chrome --disk-cache-dir="/dev/shm/\${USER:-\$(id -un)}-chrome-cache" "\$@"
WRAPPER_EOF
chmod 0755 /usr/local/bin/google-chrome

if [ -f /usr/share/applications/google-chrome.desktop ]; then
    sed -E 's|^Exec=/usr/bin/google-chrome(-stable)?|Exec=/usr/local/bin/google-chrome|' \
        /usr/share/applications/google-chrome.desktop \
        > /usr/local/share/applications/google-chrome.desktop
fi

# First login script
log_step "Creating first-login script..."
cat <<'USER_EOF' > /home/\$TARGET_USER/.first-login.sh
#!/bin/bash
# Only run in interactive shells.
[ -t 0 ] || exit 0

if [ ! -f ~/.gitconfig ]; then
    echo "First login: Configuring Git"
    read -r -p "Enter Git username: " GIT_USER
    read -r -p "Enter Git email: " GIT_EMAIL
    git config --global user.name "\$GIT_USER"
    git config --global user.email "\$GIT_EMAIL"
fi

if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "Generating SSH key (you will be asked for a passphrase)..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519
    echo "Your public SSH key is:"
    cat ~/.ssh/id_ed25519.pub
fi

# Remove the one-shot trigger after a successful run.
sed -i '/first-login\.sh/d' ~/.bashrc 2>/dev/null || true
rm -f ~/.first-login.sh
USER_EOF
chmod +x /home/\$TARGET_USER/.first-login.sh
chown "\$TARGET_USER:\$TARGET_USER" /home/\$TARGET_USER/.first-login.sh

# Trigger first login script (idempotently append to bashrc)
if ! grep -q "first-login.sh" /home/\$TARGET_USER/.bashrc; then
    echo "[[ -f ~/.first-login.sh && -t 0 ]] && . ~/.first-login.sh" >> /home/\$TARGET_USER/.bashrc
fi

# Final Cleanup
log_step "Final cleanup..."
# Disable periodic TRIM
systemctl disable fstrim.timer || true
apt-get autoremove -y
apt-get clean

CHROOT_EOF

    chmod +x /mnt/target/setup-boot.sh

    log_info "Entering chroot to complete boot setup..."
    chroot /mnt/target /setup-boot.sh
    rm -f /mnt/target/setup-boot.sh
fi

# Clean up outer binds and unmount
log_info "Unmounting and cleaning up outer mount points..."
cleanup_mounts
CLEANUP_ON_ERROR=0

log_success "Boot setup completed successfully!"
