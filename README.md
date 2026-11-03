# Surface Pro 7 Ubuntu USB Installer

This project provides a modular Bash installer (`surface-installer.sh` plus numbered step scripts and a shared `config.sh`) that installs a minimal, highly optimized Ubuntu 24.04 LTS (Noble) environment onto a USB flash drive. This installation is configured specifically to run on Microsoft Surface Pro 7 hardware.

The installer runs from an existing Linux host and creates a completely bootable, persistent installation on a target USB drive.

## Usage

```bash
sudo ./surface-installer.sh                 # interactive device selection
sudo ./surface-installer.sh /dev/sdX        # confirm interactively, then install
sudo ./surface-installer.sh --yes /dev/sdX  # non-interactive (DESTRUCTIVE)
sudo ./surface-installer.sh --reuse /dev/sdX # keep an existing EFI/ROOT layout
```

Passing a device path still asks for `YES` unless `--yes` (or `ASSUME_YES=1`) is supplied. The installer refuses to operate on partitions, on the disk backing the host root filesystem, or on devices mounted at critical host paths. `--reuse` is required to skip repartitioning/reformatting an existing layout.

If no passwords are supplied, strong random passwords are generated and written to `install-credentials.txt` (mode `600`) next to the scripts. Override them with `TARGET_PASSWORD` and `ROOT_PASSWORD` environment variables.

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
- **Robust Cleanup:** Error traps report the failing line and unmount all chroot bind mounts and target partitions (with a `sync` first).
- **Logging:** All installer outputs are written to the terminal with timestamps and ANSI colors, while concurrently being written to `install.log`.
- **Safety Checks:** The installer lists available block devices with `lsblk`, validates that the target is a whole disk, refuses disks that back the host root filesystem or are mounted at critical paths, and requires an explicit `YES` (or `--yes`) before any destructive action.
- **Idempotency:** Existing layouts are only reused when `--reuse` is explicitly supplied; otherwise the target is repartitioned and reformatted.
- **Partition and Loopback Support:** Uses `sgdisk` and `wipefs` to prepare disk geometry, and relies on `udevadm settle` and `partx` to handle device-node generation reliably, even within loopback-testing environments.
- **Boot Integrity:** EFI mount failure is fatal by default, and the installer verifies filesystem UUIDs before writing `/etc/fstab`. For restricted loopback tests, `ALLOW_MISSING_EFI=1` can be used to continue at the cost of a non-bootable result.

---

## System Packages & Environment

### User Accounts
- **Passwords:** Strong random passwords are generated unless `ROOT_PASSWORD`/`TARGET_PASSWORD` are provided. Generated credentials are written to `install-credentials.txt` (mode `600`).
- **Root User:** Uses the generated (or supplied) root password.
- **Default User:** A standard user named `surfaceuser` is created and assigned to essential groups: `sudo`, `plugdev`, `audio`, `video`, `render`, `input`, `dialout`. When a password is generated, the user is forced to change it at first login.

### Installed Software
The installer selects essential, lightweight, and required developer packages:
- **Base System:** `sudo`, `systemd`, `locales`, `curl`, `wget`, `nano`, `vim`, `git`, `network-manager`, `openssh-client`, `openssh-server`, and `initramfs-tools`.
- **Desktop Environment:** Minimal GNOME desktop environment using `ubuntu-desktop-minimal` and `gdm3` for the display manager.
- **Development Tools:** `build-essential` and `cmake`.
- **Firmware:** `linux-firmware` and `intel-microcode`.
- **Android Development Support:** `adb`, `fastboot`, and custom Android udev rules downloaded from the official repository.
- **Node.js:** LTS release (default major 24, override with `NODE_MAJOR`) installed via the official NodeSource repository.
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
- **Bootloader Installation:** Installs signed GRUB (`grub-efi-amd64-signed`) plus `shim-signed`, configured with `--removable` so the drive can boot on different devices without modifying NVRAM.
- **Secure Boot:** The signed shim/GRUB chain is compatible with Secure Boot, but the linux-surface kernel modules require enrolling the linux-surface MOK. At first boot, select "Enroll MOK" and follow the prompts (the MOK Manager is copied to `EFI/BOOT/mmx64.efi`). If you do not enroll the MOK, disable Secure Boot or the surface modules will not load.
- **Initramfs:** Generated for every installed kernel (`update-initramfs -c -k all`), which is required because `uname -r` inside the chroot reports the host kernel.

---

## First-Login Experience

Upon the user's first interactive login:
- A one-shot shell script (`~/.first-login.sh`) executes automatically (non-interactive shells skip it).
- If `~/.gitconfig` is missing, the user is prompted to configure their Git username and email.
- If an SSH key does not exist at `~/.ssh/id_ed25519`, a new passphrase-protected one is generated, and its public key is displayed.
- The trigger line and script remove themselves after a successful run.

---

## Web Browser Optimization

Google Chrome is optimized for RAM-based caching to limit flash storage wear:
- A `/usr/local/bin/google-chrome` wrapper passes `--disk-cache-dir=/dev/shm/<user>-chrome-cache`, and a desktop-file override routes GUI launches through the wrapper (Chrome does not read a `CHROME_FLAGS` environment variable).

---

## Cleanup & Finalization

Upon successful package installation and setup:
- A complete APT cleanup is performed via `apt autoremove` and `apt clean`.
- The temporary internal installer script is deleted from the target filesystem.
- All bind mounts and drive partitions are cleanly unmounted.
