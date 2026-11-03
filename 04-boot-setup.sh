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
    log_info "TEST_MODE is enabled. Simulating bootloader configuration..."

    # Simulated default grub
    log_info "Configuring simulated GRUB defaults..."
    mkdir -p /mnt/target/etc/default
    echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"' > /mnt/target/etc/default/grub

    if ! grep -q "i915.enable_psr=0" /mnt/target/etc/default/grub; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="i915.enable_psr=0 /' /mnt/target/etc/default/grub
    fi

    # Chrome cache in RAM
    log_info "Optimizing Chrome simulated config..."
    mkdir -p "/mnt/target/home/$TARGET_USER/.config/google-chrome"
    mkdir -p /mnt/target/etc/profile.d
    cat <<EOF > /mnt/target/etc/profile.d/chrome-cache.sh
export CHROME_FLAGS="--disk-cache-dir=/dev/shm/\$TARGET_USER-chrome-cache"
EOF

    # First login script
    log_info "Creating simulated first-login script..."
    cat <<'USER_EOF' > "/mnt/target/home/$TARGET_USER/.first-login.sh"
#!/bin/bash
if [ ! -f ~/.gitconfig ]; then
    echo "First login: Configuring Git"
    read -r -p "Enter Git username: " GIT_USER
    read -r -p "Enter Git email: " GIT_EMAIL
    git config --global user.name "$GIT_USER"
    git config --global user.email "$GIT_EMAIL"
fi

if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "Generating SSH key..."
    mkdir -p ~/.ssh
    ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
    echo "Your public SSH key is:"
    cat ~/.ssh/id_ed25519.pub
fi
USER_EOF
    chmod +x "/mnt/target/home/$TARGET_USER/.first-login.sh"

    # Trigger first login script (idempotently append to bashrc)
    if ! grep -q "first-login.sh" "/mnt/target/home/$TARGET_USER/.bashrc"; then
        echo "[[ -f ~/.first-login.sh ]] && . ~/.first-login.sh" >> "/mnt/target/home/$TARGET_USER/.bashrc"
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

# Bootloader
log_step "Installing GRUB..."
apt-get install -y --fix-missing grub-efi-amd64
apt-get clean

# Screen flicker fix & other GRUB modifications (Idempotent: modify default grub once)
if ! grep -q "i915.enable_psr=0" /etc/default/grub; then
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="i915.enable_psr=0 /' /etc/default/grub
fi

if mountpoint -q /boot/efi; then
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --removable
    update-grub
else
    echo "Skipping GRUB install as /boot/efi is not mounted inside chroot."
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

# Trigger first login script (idempotently append to bashrc)
if ! grep -q "first-login.sh" /home/\$TARGET_USER/.bashrc; then
    echo "[[ -f ~/.first-login.sh ]] && . ~/.first-login.sh" >> /home/\$TARGET_USER/.bashrc
fi

# Final Cleanup
log_step "Final cleanup..."
# Disable periodic TRIM
systemctl disable fstrim.timer || true
apt-get autoremove -y
apt-get clean
rm /setup-boot.sh

CHROOT_EOF

    chmod +x /mnt/target/setup-boot.sh

    log_info "Entering chroot to complete boot setup..."
    chroot /mnt/target /setup-boot.sh
fi

# Clean up outer binds and unmount
log_info "Unmounting and cleaning up outer mount points..."
for mnt in /mnt/target/dev/pts /mnt/target/dev /mnt/target/proc /mnt/target/sys/firmware/efi/efivars /mnt/target/sys; do
    if mountpoint -q "$mnt" 2>/dev/null; then
        umount -l "$mnt" || true
    fi
done

if mountpoint -q /mnt/target/boot/efi 2>/dev/null; then
    umount /mnt/target/boot/efi || true
fi

if mountpoint -q /mnt/target 2>/dev/null; then
    umount /mnt/target || true
fi

log_success "Boot setup completed successfully!"
