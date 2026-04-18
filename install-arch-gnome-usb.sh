#!/bin/bash
# Arch Linux + GNOME + LUKS USB Installer
# WORKING VERSION - Clean prompts, no /dev/tty issues

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Arch Linux USB Installer v6.0${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ============================================================
# LOAD KERNEL MODULES
# ============================================================
echo -e "${YELLOW}Loading kernel modules...${NC}"
modprobe dm_mod 2>/dev/null || true
modprobe dm_crypt 2>/dev/null || true
modprobe aesni_intel 2>/dev/null || true
modprobe aes_x86_64 2>/dev/null || true
echo -e "${GREEN}✓ Modules loaded${NC}"
echo ""

# ============================================================
# SHOW DRIVES
# ============================================================
echo -e "${YELLOW}=== ALL DETECTED DRIVES ===${NC}"
lsblk -o NAME,MODEL,SIZE,TYPE
echo ""

# ============================================================
# GET TARGET USB
# ============================================================
echo -e "${YELLOW}Which drive do you want to INSTALL Arch on?${NC}"
echo -e "${RED}⚠️  This drive will be COMPLETELY WIPED ⚠️${NC}"
echo ""
read -p "Enter FULL device path (e.g., /dev/sda): " USB_DEV

if [ -z "$USB_DEV" ]; then
    echo -e "${RED}ERROR: No device entered.${NC}"
    exit 1
fi

if [ ! -b "$USB_DEV" ]; then
    echo -e "${RED}ERROR: $USB_DEV does NOT exist!${NC}"
    exit 1
fi

# ============================================================
# CONFIRMATION
# ============================================================
echo ""
echo -e "${RED}⚠️  YOU HAVE SELECTED:${NC}"
lsblk -o NAME,MODEL,SIZE "$USB_DEV"
echo ""
echo -e "${RED}ALL DATA ON THIS DRIVE WILL BE DESTROYED!${NC}"
echo ""
read -p "Type 'YES' to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Installation cancelled."
    exit 0
fi

# ============================================================
# USER INFORMATION
# ============================================================
echo ""
echo -e "${GREEN}=== User Setup ===${NC}"
read -p "Enter username: " USERNAME

echo ""
read -s -p "Enter user password (for login): " USER_PASS
echo ""
read -s -p "Confirm user password: " USER_PASS2
echo ""
if [ "$USER_PASS" != "$USER_PASS2" ] || [ -z "$USER_PASS" ]; then
    echo -e "${RED}Passwords do not match or empty. Exiting.${NC}"
    exit 1
fi

echo ""
read -p "Enter timezone (e.g., America/New_York) [UTC]: " TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"

read -p "Enter hostname [arch-usb]: " HOSTNAME
HOSTNAME="${HOSTNAME:-arch-usb}"

# ============================================================
# LUKS PASSPHRASE (CAN BE SAME OR DIFFERENT FROM USER PASSWORD)
# ============================================================
echo ""
echo -e "${GREEN}=== LUKS Encryption Setup ===${NC}"
echo -e "${YELLOW}This passphrase will be required EVERY TIME you boot the USB${NC}"
echo ""
read -s -p "Enter LUKS passphrase (for disk encryption): " LUKS_PASS
echo ""
read -s -p "Confirm LUKS passphrase: " LUKS_PASS2
echo ""
if [ "$LUKS_PASS" != "$LUKS_PASS2" ] || [ -z "$LUKS_PASS" ]; then
    echo -e "${RED}Passphrases do not match or empty. Exiting.${NC}"
    exit 1
fi

# ============================================================
# SUMMARY
# ============================================================
echo ""
echo -e "${GREEN}=== INSTALLATION SUMMARY ===${NC}"
echo "Target drive:   $USB_DEV"
echo "Username:       $USERNAME"
echo "Hostname:       $HOSTNAME"
echo "Timezone:       $TIMEZONE"
echo ""
read -p "Start installation? (yes/no): " proceed
if [ "$proceed" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# ============================================================
# DYNAMIC PARTITIONING (FIXED)
# ============================================================
echo ""
echo -e "${GREEN}=== Partitioning drive ===${NC}"

# Get total size in GiB for user info
TOTAL_SIZE=$(lsblk -b -d -o SIZE -n "$USB_DEV" | head -1)
TOTAL_GB=$((TOTAL_SIZE / 1024 / 1024 / 1024))

echo -e "${YELLOW}USB size detected: ${TOTAL_GB} GiB${NC}"
echo -e "${YELLOW}Will use: 512MB EFI, 30% of remaining for system, 70% for home${NC}"
echo ""

umount "${USB_DEV}"* 2>/dev/null || true
dd if=/dev/zero of="$USB_DEV" bs=1M count=10 status=progress 2>/dev/null

parted -s "$USB_DEV" mklabel gpt
parted -s "$USB_DEV" mkpart primary fat32 1MiB 513MiB
parted -s "$USB_DEV" set 1 esp on
parted -s "$USB_DEV" mkpart primary 513MiB 30%
parted -s "$USB_DEV" mkpart primary 30% 100%
sleep 2

EFI_PART="${USB_DEV}1"
SYSTEM_LUKS="${USB_DEV}2"
HOME_LUKS="${USB_DEV}3"

echo -e "${GREEN}✓ Partitions created${NC}"
lsblk "$USB_DEV"

# ============================================================
# LUKS ENCRYPTION (FIXED CIPHER)
# ============================================================
echo ""
echo -e "${GREEN}=== Setting up LUKS encryption ===${NC}"
echo -e "${YELLOW}Using aes-256-gcm (authenticated encryption, hardware accelerated)${NC}"

# System partition
echo "Encrypting system partition..."
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 \
    --cipher aes-256-gcm \
    --key-size 256 \
    --pbkdf argon2id \
    "$SYSTEM_LUKS" -

# Home partition
echo "Encrypting home partition..."
echo -n "$LUKS_PASS" | cryptsetup luksFormat --type luks2 \
    --cipher aes-256-gcm \
    --key-size 256 \
    --pbkdf argon2id \
    "$HOME_LUKS" -

# Open partitions
echo "Opening encrypted partitions..."
echo -n "$LUKS_PASS" | cryptsetup open "$SYSTEM_LUKS" cryptsys -
echo -n "$LUKS_PASS" | cryptsetup open "$HOME_LUKS" crypthome -

echo -e "${GREEN}✓ Encryption complete${NC}"

# ============================================================
# FORMAT
# ============================================================
echo "Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -O '^has_journal' /dev/mapper/cryptsys
mkfs.ext4 -O '^has_journal' /dev/mapper/crypthome

# ============================================================
# MOUNT
# ============================================================
mount /dev/mapper/cryptsys /mnt
mkdir -p /mnt/home /mnt/boot
mount /dev/mapper/crypthome /mnt/home
mount "$EFI_PART" /mnt/boot

# ============================================================
# BASE INSTALLATION
# ============================================================
echo ""
echo -e "${GREEN}=== Installing base system (15-30 minutes) ===${NC}"

# Faster mirrors
pacman -Sy --noconfirm reflector 2>/dev/null
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null

# Install packages
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
    lvm2 cryptsetup vim sudo networkmanager git curl \
    amd-ucode intel-ucode pipewire pipewire-pulse wireplumber \
    xdg-desktop-portal-gnome

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# ============================================================
# CHROOT CONFIGURATION
# ============================================================
echo ""
echo -e "${GREEN}=== Configuring system ===${NC}"

arch-chroot /mnt /bin/bash << CHROOT
set -e

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname

# Users (using USER_PASS for login)
echo "root:$USER_PASS" | chpasswd
useradd -m -G wheel,audio,video,storage,optical,network,power -s /bin/bash $USERNAME
echo "$USERNAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Initramfs with encryption support
cat > /etc/mkinitcpio.conf << EOF
MODULES=(nvme aesni_intel)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)
COMPRESSION=(zstd)
EOF
mkinitcpio -P

# systemd-boot
bootctl --esp-path=/boot install
cat > /boot/loader/loader.conf << EOF
default arch.conf
timeout 3
EOF

# Get UUIDs for kernel command line
SYS_UUID=\$(blkid -s UUID -o value $SYSTEM_LUKS)
HOME_UUID=\$(blkid -s UUID -o value $HOME_LUKS)

cat > /boot/loader/entries/arch.conf << EOF
title   Arch Linux (GNOME)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options rd.luks.name=\$SYS_UUID=cryptsys rd.luks.name=\$HOME_UUID=crypthome root=/dev/mapper/cryptsys rootflags=noatime quiet rw
EOF

# Enable services
systemctl enable NetworkManager
systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Flash memory optimization
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/usb.conf << EOF
[Journal]
Storage=volatile
RuntimeMaxUse=100M
EOF

# Add noatime and trim
sed -i 's/defaults/defaults,noatime,discard=async/' /etc/fstab
systemctl enable fstrim.timer

# Install GNOME
pacman -S --noconfirm gnome gnome-tweaks gdm firefox
systemctl enable gdm

# GDM stability fix for USB boot
mkdir -p /etc/systemd/system/gdm.service.d/
cat > /etc/systemd/system/gdm.service.d/wait-for-usb.conf << GDM
[Service]
ExecStartPre=/bin/sleep 2
GDM

# Install paru (AUR helper)
git clone https://aur.archlinux.org/paru.git /home/$USERNAME/paru
chown -R $USERNAME:$USERNAME /home/$USERNAME/paru
cd /home/$USERNAME/paru
sudo -u $USERNAME makepkg -si --noconfirm
cd / && rm -rf /home/$USERNAME/paru

CHROOT

# ============================================================
# CLEANUP
# ============================================================
echo ""
echo -e "${GREEN}=== Cleaning up ===${NC}"
umount -R /mnt
cryptsetup close crypthome
cryptsetup close cryptsys

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}✅ INSTALLATION COMPLETE!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo "SUMMARY:"
echo "  LUKS passphrase: [the one you entered for disk encryption]"
echo "  User login:      $USERNAME / [your user password]"
echo ""
echo "NEXT STEPS:"
echo "  1. Remove the Arch ISO USB"
echo "  2. Reboot"
echo "  3. Boot from your SanDisk"
echo "  4. Enter LUKS passphrase TWICE"
echo "  5. Login with your username and password"
echo ""
