#!/bin/bash
# Arch Linux + GNOME + LUKS USB Installer
# GitHub-ready - no hardcoded credentials
# Usage: curl -s https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/create-arch-gnome-usb.sh | bash

set -e

# ============================================================
# CONFIGURATION - Set via environment or prompts
# ============================================================

# Required variables (set these or they'll prompt)
USB_DEV="${USB_DEV:-}"                    # e.g., /dev/sdb
USERNAME="${USERNAME:-}"                  # Your username
PASSWORD="${PASSWORD:-}"                  # Your password
TIMEZONE="${TIMEZONE:-UTC}"               # e.g., America/New_York
HOSTNAME="${HOSTNAME:-arch-usb}"
KEYMAP="${KEYMAP:-us}"

# ============================================================
# PROMPT FOR MISSING VARIABLES
# ============================================================

if [ -z "$USB_DEV" ]; then
    echo "Available drives:"
    lsblk -o NAME,MODEL,SIZE | grep -E "disk|NAME"
    read -p "Enter USB device (e.g., /dev/sdb): " USB_DEV
fi

if [ -z "$USERNAME" ]; then
    read -p "Enter username: " USERNAME
fi

if [ -z "$PASSWORD" ]; then
    read -s -p "Enter password: " PASSWORD
    echo
fi

# Validate USB device exists
if [ ! -b "$USB_DEV" ]; then
    echo "ERROR: $USB_DEV does not exist"
    exit 1
fi

# ============================================================
# VERIFICATION
# ============================================================

echo ""
echo "=== INSTALLATION SUMMARY ==="
echo "Target USB: $USB_DEV ($(lsblk -o MODEL,SIZE "$USB_DEV" | tail -1))"
echo "Username:   $USERNAME"
echo "Hostname:   $HOSTNAME"
echo "Timezone:   $TIMEZONE"
echo "Keymap:     $KEYMAP"
echo "============================"
echo ""
read -p "Type 'YES' to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# ============================================================
# BEGIN INSTALLATION (same as previous script but using variables)
# ============================================================

echo "=== Starting installation ==="

# Unmount if mounted
mount | grep -q "$USB_DEV" && umount -R "${USB_DEV}"* 2>/dev/null || true

# Partition
dd if=/dev/zero of="$USB_DEV" bs=1M count=10 status=progress
parted "$USB_DEV" mklabel gpt
parted "$USB_DEV" mkpart primary fat32 1MiB 513MiB
parted "$USB_DEV" set 1 esp on
parted "$USB_DEV" mkpart primary 513MiB 41GiB
parted "$USB_DEV" mkpart primary 41GiB 100%
sleep 2

EFI_PART="${USB_DEV}1"
SYSTEM_LUKS="${USB_DEV}2"
HOME_LUKS="${USB_DEV}3"

# Encryption
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 --cipher aes-256-gcm --pbkdf argon2id "$SYSTEM_LUKS" -
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 --cipher aes-256-gcm --pbkdf argon2id "$HOME_LUKS" -
echo -n "$PASSWORD" | cryptsetup open "$SYSTEM_LUKS" cryptsys -
echo -n "$PASSWORD" | cryptsetup open "$HOME_LUKS" crypthome -

# Format
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -O '^has_journal' /dev/mapper/cryptsys
mkfs.ext4 -O '^has_journal' /dev/mapper/crypthome

# Mount
mount /dev/mapper/cryptsys /mnt
mkdir -p /mnt/home /mnt/boot
mount /dev/mapper/crypthome /mnt/home
mount "$EFI_PART" /mnt/boot

# Base install
pacman -Sy --noconfirm reflector
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
    lvm2 cryptsetup vim sudo networkmanager git curl efitools sbctl \
    amd-ucode intel-ucode pipewire pipewire-pulse wireplumber \
    xdg-desktop-portal-gnome

# fstab
genfstab -U /mnt >> /mnt/etc/fstab

# Chroot
cat << CHROOT | arch-chroot /mnt /bin/bash
set -e
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,storage,optical,network,power -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel
cat > /etc/mkinitcpio.conf << MKINIT
MODULES=(nvme)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)
COMPRESSION=()
MKINIT
mkinitcpio -P
bootctl --esp-path=/boot install
cat > /boot/loader/loader.conf << LOADER
default arch.conf
timeout 3
LOADER
SYS_UUID=\$(blkid -s UUID -o value $SYSTEM_LUKS)
HOME_UUID=\$(blkid -s UUID -o value $HOME_LUKS)
cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux (GNOME + LUKS)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options rd.luks.name=\$SYS_UUID=cryptsys rd.luks.name=\$HOME_UUID=crypthome root=/dev/mapper/cryptsys rootflags=noatime quiet rw
ENTRY
systemctl enable NetworkManager systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/usb-stick.conf << JOURNAL
[Journal]
Storage=volatile
RuntimeMaxUse=100M
JOURNAL
sed -i 's/defaults/defaults,noatime,discard=async/' /etc/fstab
systemctl enable fstrim.timer
pacman -S --noconfirm gnome gnome-tweaks gdm firefox
systemctl enable gdm
git clone https://aur.archlinux.org/paru.git /home/$USERNAME/paru
chown -R $USERNAME:$USERNAME /home/$USERNAME/paru
cd /home/$USERNAME/paru
sudo -u $USERNAME makepkg -si --noconfirm
cd / && rm -rf /home/$USERNAME/paru
CHROOT

# Cleanup
umount -R /mnt
cryptsetup close cryptsys
cryptsetup close crypthome

echo "=========================================="
echo "✅ INSTALLATION COMPLETE!"
echo "=========================================="
echo "Remove the Arch ISO USB and boot from $USB_DEV"
echo "Login: $USERNAME"
echo "LUKS password: [the password you entered]"
echo "=========================================="
