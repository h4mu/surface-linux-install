# Surface Pro 7 Ubuntu USB Installer Requirements

## Goal

Create a **single self-contained Bash installer** that installs **Ubuntu 24.04 LTS (Noble)** onto a **USB flash drive** for booting on a **Microsoft Surface Pro 7**.

The installer runs from an existing Linux system and creates a completely bootable installation on the target USB drive.

The output should be one executable script (`surface-installer.sh`).

---

# Target hardware

* Microsoft Surface Pro 7
* Intel x86_64
* UEFI boot
* Secure Boot optional
* USB flash drive (NOT SSD)
* 64 GB+ recommended

---

# Operating System

Ubuntu 24.04 LTS

Minimal installation using

```
debootstrap
```

NOT using Subiquity or live installer.

---

# Filesystem Layout

GPT

EFI System Partition

* FAT32
* 512 MB

Root

* ext4
* remainder of drive

NO swap partition.

Use a swapfile.

---

# Flash-drive durability

Optimize aggressively for flash longevity.

Filesystem mount options:

```
noatime
lazytime
commit=120
errors=remount-ro
```

No periodic TRIM.

No discard mount option.

Set ext4 reserved blocks to

```
0%
```

```
tune2fs -m 0
```

---

# Swap

Enable swapping (4GB size).

Use

```
/swapfile
```

NOT a partition.

Set

```
vm.swappiness=20
```

---

# Logging

Reduce writes.

Configure journald

```
Storage=volatile
RuntimeMaxUse=64M
```

No persistent journal.

---

# tmpfs

Mount

```
/tmp
```

as tmpfs.

Optionally

```
/var/tmp
```

also tmpfs.

---

# apt

Disable keeping downloaded packages.

Automatically clean package cache.

Disable unnecessary periodic apt jobs.

---

# sysctl

Configure

```
vm.swappiness=20
vm.vfs_cache_pressure=50
vm.dirty_background_ratio=5
vm.dirty_ratio=20
```

---

# Installer robustness

Use

```
set -Eeuo pipefail
```

Provide

* cleanup trap
* error trap
* line number on failure
* colored logging
* timestamps

---

# Drive selection

Never hardcode

```
/dev/sdb
```

Instead

Show

```
lsblk
```

Prompt user.

Require typing

```
YES
```

before destroying drive.

---

# Partitioning

Use

```
sgdisk
```

Wipe signatures

```
wipefs -af
```

Use

```
udevadm settle
```

Never use arbitrary

```
sleep
```

---

# Bootloader

Install

GRUB EFI

Support removable media

```
--removable
```

Should boot without NVRAM entries.

---

# Chroot

Properly bind

```
/dev
/dev/pts
/proc
/sys
/sys/firmware/efi/efivars
```

Pass variables correctly into chroot.

Do NOT rely on outer-shell variables.

---

# Packages

Base

* sudo
* systemd
* locales
* curl
* wget
* nano
* vim
* git

Networking

* NetworkManager
* openssh-client
* openssh-server

Desktop

LXDE

Display manager

Prefer

LightDM

over LXDM.

---

# Development

Install

* build-essential
* gcc
* g++
* clang
* cmake
* ninja
* pkg-config
* git-lfs

---

# Graphics

Install

* mesa-utils
* mesa-vulkan-drivers
* vulkan-tools
* vainfo

---

# Firmware

Install

* linux-firmware
* intel-microcode

---

# Android

Install

* adb
* fastboot

Configure Android udev rules.

---

# Steam

Enable

```
i386
```

Install Steam.

---

# Node.js

Install current LTS

using the official NodeSource repository.

---

# Google Chrome

Install from Google's official repository or official .deb.

No unofficial mirrors.

---

# Surface support

Install

Linux Surface kernel

using the **current official Linux Surface installation method**.

Do NOT hardcode outdated repository URLs or GPG keys.

Install

* Surface kernel
* Surface headers
* IPTS
* Surface libwacom
* Secure Boot support

Follow current project recommendations.

---

# Secure Boot

Support MOK enrollment.

If Secure Boot is enabled,

prepare system correctly.

---

# User

Create

```
surfaceuser
```

Default password

```
surfaceuser
```

Root password

```
root
```

User belongs to

* sudo
* plugdev
* audio
* video
* render
* input
* dialout

---

# First login

On first login

If

```
~/.gitconfig
```

does not exist

Prompt for

Git username

Git email

Configure git.

Generate

```
ed25519
```

SSH key

if absent.

Display public key.

Never overwrite existing keys.

---

# Browser optimization

Chrome cache

Store in

```
/dev/shm
```

or another RAM-backed location.

---

# Cleanup

Run

```
apt autoremove
apt clean
```

Remove temporary installer files.

Unmount everything cleanly.

---

# Code quality

Script should be

* ShellCheck clean
* idempotent where practical
* heavily commented
* modular

Prefer functions.

Avoid duplicated code.

---

# Safety

Never

```
curl | sh
```

unless using an official installer that explicitly requires it and the rationale is documented.

Verify downloads where practical.

---

# Deliverable

One file

```
surface-installer.sh
```

Requirements:

* executable
* production quality
* no placeholder URLs
* no TODOs
* no pseudocode
* current Ubuntu 24.04 compatible
* Surface Pro 7 compatible
* boots directly from USB
* optimized for flash-drive longevity
* thoroughly commented
