# Surface Pro 7 Ubuntu USB Installer

This project provides a single, self-contained Bash installer script (`surface-installer.sh`) that installs a minimal, highly optimized Ubuntu 24.04 LTS (Noble) environment onto a USB flash drive. This installation is configured specifically to run on Microsoft Surface Pro 7 hardware.

The installer runs from an existing Linux host and creates a completely bootable, persistent installation on a target USB drive.

---

## Target Hardware and Operating System

- **Target Hardware:** Microsoft Surface Pro 7 (Intel x86_64, UEFI boot, Secure Boot supported).
- **Storage Medium:** USB flash drive (64 GB+ recommended).
- **Operating System:** Ubuntu 24.04 LTS (Noble) minimal installation, bootstrapped via `debootstrap` (bypassing Subiquity and the live installer).

---

## Filesystem Layout and Durability

The installer prepares the target drive with a robust layout optimized for USB flash-drive longevity:

- **Partitioning:** GPT layout containing:
  - **EFI System Partition:** FAT32 (512 MB).
  - **Root Partition:** ext4 (occupying the remaining space of the drive).
- **Ext4 Optimizations:** Reserved blocks are set to 0% (`tune2fs -m 0`) to maximize usable space.
- **Mount Options:** The root partition is mounted with flash-durability options:
  - `noatime`, `lazytime`, `commit=120`, and `errors=remount-ro`.
- **Trim & Discard:** No periodic TRIM is scheduled (the `fstrim.timer` service is disabled), and the `discard` mount option is not used to prevent excessive writes.

---

## Swap Configuration

To preserve flash life while providing virtual memory:
- A **4 GB swapfile** (`/swapfile`) is utilized instead of a swap partition.
- Swappiness is set to a conservative value (`vm.swappiness=20`) to reduce unnecessary paging.

---

## Logging & tmpfs Configurations

- **Systemd Journal:** System logging is configured to write to volatile memory rather than the flash drive to reduce write cycles:
  - `Storage=volatile`
  - `RuntimeMaxUse=64M`
- **Volatile Mounts:** Both `/tmp` and `/var/tmp` are mounted using `tmpfs` to keep temporary file writes entirely in RAM.

---

## Package Management (APT) Optimizations

The installed system minimizes storage writes from software updates by:
- Disabling the retention of downloaded packages (`Binary::apt::APT::Keep-Downloaded-Packages "0"`).
- Automatically cleaning the package cache.
- Disabling unnecessary periodic package list updates and background unattended upgrades.

---

## Sysctl Optimizations

System-level memory and write-buffer parameters are configured for desktop responsiveness and flash safety:
- `vm.swappiness = 20`
- `vm.vfs_cache_pressure = 50`
- `vm.dirty_background_ratio = 5`
- `vm.dirty_ratio = 20`

---

## Installer Robustness & Safety

The installation script is built to professional standards:
- **Bash Safeguards:** Written with `set -Eeuo pipefail` to ensure immediate exit on failure.
- **Robust Cleanup:** A trap handler catches errors, reports failure lines, and guarantees clean unmounting of all chroot bind mounts and target partitions.
- **Logging:** All installer outputs are output to the terminal with timestamps and ANSI colors, while concurrently being written to `install.log`.
- **Idempotency and Safeguards:** The script lists available block devices using `lsblk` and prompts for user confirmation before performing any operations on the target device. Destructive operations require entering `YES`. It also supports passing the target device path as a command-line argument for non-interactive execution.
- **Partition and Loopback Support:** Uses `sgdisk` and `wipefs` to prepare disk geometry, and relies on `udevadm settle` and `partx` to handle device-node generation reliably, even within loopback-testing environments.

---

## System Packages & Environment

### User Accounts
- **Root User:** Default password is set to `root`.
- **Default User:** A standard user named `surfaceuser` (password `surfaceuser`) is created and assigned to essential groups: `sudo`, `plugdev`, `audio`, `video`, `render`, `input`, `dialout`.

### Installed Software
The installer selects essential, lightweight, and required developer packages:
- **Base System:** `sudo`, `systemd`, `locales`, `curl`, `wget`, `nano`, `vim`, `git`, `network-manager`, `openssh-client`, `openssh-server`, and `initramfs-tools`.
- **Desktop Environment:** Minimal GNOME desktop environment using `ubuntu-desktop-minimal` and `gdm3` for the display manager.
- **Development Tools:** `build-essential` and `cmake`.
- **Firmware:** `linux-firmware` and `intel-microcode`.
- **Android Development Support:** `adb`, `fastboot`, and custom Android udev rules downloaded from the official repository.
- **Node.js:** Current LTS release installed via the official NodeSource repository.
- **Web Browser:** Google Chrome Stable, installed via the official Google stable repository.

---

## Microsoft Surface Pro 7 Integration

The installer integrates dedicated packages and tweaks to ensure out-of-the-box functionality for the Surface Pro 7:

- **Linux Surface Kernel:** Installs the standard Linux-surface kernel packages:
  - `linux-image-surface`
  - `linux-headers-surface`
  - `libwacom-surface`
  - `iptsd` (for touch and stylus input)
  - `linux-surface-secureboot-mok` (for Secure Boot MOK enrollment)
- **Power and Thermal Management:**
  - Installs `thermald` and downloads the official Surface Pro 7-specific thermal configurations (`thermal-conf.xml` and `thermal-cpu-cdev-order.xml`) from the `linux-surface` repository.
  - Configures Systemd login manager to ignore lid switches (`HandleLidSwitch=ignore`) for convenient tablet/docked usage.
- **Display Flickering Patch:** Automatically adds `i915.enable_psr=0` to the GRUB kernel parameters to mitigate common Intel graphics flickering issues.
- **Bootloader Installation:** Installs a removable-media-configured EFI GRUB bootloader (`--removable`) to support booting on different devices without needing system NVRAM modifications.

---

## First-Login Experience

Upon the user's first login:
- A shell script (`~/.first-login.sh`) executes automatically.
- If `~/.gitconfig` is missing, the user is prompted to configure their Git username and email.
- If an SSH key does not exist at `~/.ssh/id_ed25519`, a new one is generated, and its public key is displayed.

---

## Web Browser Optimization

Google Chrome is optimized for RAM-based caching to limit flash storage wear:
- Environment configuration sets `CHROME_FLAGS` to point the disk cache directory to `/dev/shm/surfaceuser-chrome-cache`.

---

## Cleanup & Finalization

Upon successful package installation and setup:
- A complete APT cleanup is performed via `apt autoremove` and `apt clean`.
- The temporary internal installer script is deleted from the target filesystem.
- All bind mounts and drive partitions are cleanly unmounted.
