#!/bin/bash
# Arch Linux + GNOME + LUKS USB Installer
# DEBUGGED VERSION - No auto-detection, pure manual entry

set -e

# ============================================================
# COLORS
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Arch Linux USB Installer v2.0${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""

# ============================================================
# STEP 1: SHOW ALL DRIVES
# ============================================================
echo -e "${YELLOW}=== ALL DETECTED DRIVES ===${NC}"
echo ""
lsblk -o NAME,MODEL,SIZE,TYPE
echo ""
echo -e "${YELLOW}=== DETAILED PARTITION INFO ===${NC}"
echo ""
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT
echo ""

# ============================================================
# STEP 2: MANUAL USB SELECTION
# ============================================================
echo -e "${YELLOW}Which drive do you want to INSTALL Arch on?${NC}"
echo -e "${RED}⚠️  This drive will be COMPLETELY WIPED ⚠️${NC}"
echo ""
read -p "Enter FULL device path (e.g., /dev/sda): " USB_DEV

# Trim any whitespace
USB_DEV=$(echo "$USB_DEV" | xargs)

# Check if empty
if [ -z "$USB_DEV" ]; then
    echo -e "${RED}ERROR: No device entered.${NC}"
    exit 1
fi

# Check if exists
if [ ! -b "$USB_DEV" ]; then
    echo -e "${RED}ERROR: $USB_DEV does NOT exist!${NC}"
    echo ""
    echo "Available devices are:"
    lsblk -d -o NAME,SIZE,TYPE | grep disk
    exit 1
fi

# ============================================================
# STEP 3: WARNING AND CONFIRMATION
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
# STEP 4: USER INFO
# ============================================================
echo ""
echo -e "${GREEN}=== User Setup ===${NC}"
read -p "Enter username: " USERNAME

while true; do
    read -s -p "Enter password: " PASSWORD
    echo
    read -s -p "Confirm password: " PASSWORD2
    echo
    if [ "$PASSWORD" = "$PASSWORD2" ] && [ -n "$PASSWORD" ]; then
        break
    else
        echo -e "${RED}Passwords do not match or empty. Try again.${NC}"
    fi
done

read -p "Enter timezone (e.g., America/New_York) [UTC]: " TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"

read -p "Enter hostname [arch-usb]: " HOSTNAME
HOSTNAME="${HOSTNAME:-arch-usb}"

# ============================================================
# STEP 5: FINAL SUMMARY
# ============================================================
echo ""
echo -e "${GREEN}=== INSTALLATION SUMMARY ===${NC}"
echo "Target drive:   $USB_DEV"
echo "Username:       $USERNAME"
echo "Hostname:       $HOSTNAME"
echo "Timezone:       $TIMEZONE"
echo ""
read -p "Start installation? (yes/no): " start
if [ "$start" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# ============================================================
# STEP 6: BEGIN INSTALLATION
# ============================================================
echo ""
echo -e "${GREEN}=== Starting installation ===${NC}"

# Unmount anything on the target
echo "Cleaning target drive..."
umount "${USB_DEV}"* 2>/dev/null || true

# Wipe the drive
echo "Wiping partition table..."
dd if=/dev/zero of="$USB_DEV" bs=1M count=10 status=progress 2>/dev/null

# Create partitions
echo "Creating partitions..."
parted -s "$USB_DEV" mklabel gpt
parted -s "$USB_DEV" mkpart primary fat32 1MiB 513MiB
parted -s "$USB_DEV" set 1 esp on
parted -s "$USB_DEV" mkpart primary 513MiB 41GiB
parted -s "$USB_DEV" mkpart primary 41GiB 100%
sleep 2

EFI_PART="${USB_DEV}1"
SYSTEM_LUKS="${USB_DEV}2"
HOME_LUKS="${USB_DEV}3"

# Verify partitions were created
if [ ! -b "$EFI_PART" ] || [ ! -b "$SYSTEM_LUKS" ] || [ ! -b "$HOME_LUKS" ]; then
    echo -e "${RED}ERROR: Partition creation failed!${NC}"
    lsblk "$USB_DEV"
    exit 1
fi

echo "Partitions created successfully:"
lsblk "$USB_DEV"

# ============================================================
# STEP 7: ENCRYPTION
# ============================================================
echo ""
echo -e "${GREEN}=== Setting up LUKS encryption ===${NC}"

echo "Encrypting system partition..."
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 \
    --cipher aes-256-gcm \
    --pbkdf argon2id \
    --iter-time 2000 \
    "$SYSTEM_LUKS" - || { echo -e "${RED}Encryption failed!${NC}"; exit 1; }

echo "Encrypting home partition..."
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 \
    --cipher aes-256-gcm \
    --pbkdf argon2id \
    "$HOME_LUKS" - || { echo -e "${RED}Encryption failed!${NC}"; exit 1; }

echo "Opening encrypted partitions..."
echo -n "$PASSWORD" | cryptsetup open "$SYSTEM_LUKS" cryptsys -
echo -n "$PASSWORD" | cryptsetup open "$HOME_LUKS" crypthome -

# ============================================================
# STEP 8: FORMAT
# ============================================================
echo "Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -O '^has_journal' /dev/mapper/cryptsys
mkfs.ext4 -O '^has_journal' /dev/mapper/crypthome

# ============================================================
# STEP 9: MOUNT
# ============================================================
echo "Mounting partitions..."
mount /dev/mapper/cryptsys /mnt
mkdir -p /mnt/home /mnt/boot
mount /dev/mapper/crypthome /mnt/home
mount "$EFI_PART" /mnt/boot

# ============================================================
# STEP 10: BASE INSTALLATION
# ============================================================
echo ""
echo -e "${GREEN}=== Installing base system (15-30 minutes) ===${NC}"

# Set up faster mirrors
pacman -Sy --noconfirm reflector 2>/dev/null
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null

# Install
pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
    lvm2 cryptsetup vim sudo networkmanager git curl \
    amd-ucode intel-ucode pipewire pipewire-pulse wireplumber \
    xdg-desktop-portal-gnome

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# ============================================================
# STEP 11: CHROOT
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

# Users
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,storage,optical,network,power -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Initramfs
cat > /etc/mkinitcpio.conf << EOF
MODULES=(nvme)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)
COMPRESSION=(zstd)
EOF
mkinitcpio -P

# Bootloader
bootctl --esp-path=/boot install
cat > /boot/loader/loader.conf << EOF
default arch.conf
timeout 3
EOF

SYS_UUID=\$(blkid -s UUID -o value $SYSTEM_LUKS)
HOME_UUID=\$(blkid -s UUID -o value $HOME_LUKS)

cat > /boot/loader/entries/arch.conf << EOF
title   Arch Linux (GNOME)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options rd.luks.name=\$SYS_UUID=cryptsys rd.luks.name=\$HOME_UUID=crypthome root=/dev/mapper/cryptsys rootflags=noatime quiet rw
EOF

# Services
systemctl enable NetworkManager systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Flash tuning
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/usb.conf << EOF
[Journal]
Storage=volatile
RuntimeMaxUse=100M
EOF
sed -i 's/defaults/defaults,noatime,discard=async/' /etc/fstab
systemctl enable fstrim.timer

# GNOME
pacman -S --noconfirm gnome gnome-tweaks gdm firefox
systemctl enable gdm

# paru
git clone https://aur.archlinux.org/paru.git /home/$USERNAME/paru
chown -R $USERNAME:$USERNAME /home/$USERNAME/paru
cd /home/$USERNAME/paru
sudo -u $USERNAME makepkg -si --noconfirm
cd / && rm -rf /home/$USERNAME/paru

CHROOT

# ============================================================
# STEP 12: CLEANUP
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
echo "1. Remove the Arch ISO USB"
echo "2. Reboot"
echo "3. Boot from your SanDisk"
echo "4. Enter LUKS password TWICE"
echo "5. Login: $USERNAME"
echo ""
