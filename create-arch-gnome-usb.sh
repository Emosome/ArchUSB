#!/bin/bash
# Arch Linux + GNOME + LUKS USB Installer
# FIXED: Works when Arch ISO is on /dev/sdb and target USB is /dev/sda
# No assumptions about device names - always prompts user

set -e

# ============================================================
# COLOR CODES FOR BETTER OUTPUT
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Arch Linux USB Installer ===${NC}"
echo ""

# ============================================================
# STEP 1: IDENTIFY ALL USB DRIVES
# ============================================================
echo -e "${YELLOW}Detecting drives...${NC}"
echo ""
lsblk -o NAME,MODEL,SIZE,TYPE,MOUNTPOINT | grep -E "NAME|disk|part"
echo ""

# Identify which USB is the Arch ISO (boot drive)
echo -e "${YELLOW}Identifying boot drive (Arch ISO)...${NC}"
BOOT_DEVICE=$(findmnt -n -o SOURCE / | sed 's/[0-9]*$//')
echo -e "Boot drive: ${GREEN}$BOOT_DEVICE${NC}"
echo ""

# Show the remaining USB drives as candidates
echo -e "${YELLOW}Available target USB drives (excluding boot drive):${NC}"
lsblk -o NAME,MODEL,SIZE -d | grep -v "$(basename "$BOOT_DEVICE")" | grep -E "sd|nvme"
echo ""

# ============================================================
# STEP 2: PROMPT FOR TARGET USB
# ============================================================
echo -e "${YELLOW}Which USB do you want to INSTALL Arch on?${NC}"
echo "  (This will be DESTROYED and become your portable Arch USB)"
echo ""
read -p "Enter device name (e.g., /dev/sda): " USB_DEV

# Validate
if [ ! -b "$USB_DEV" ]; then
    echo -e "${RED}ERROR: $USB_DEV does not exist${NC}"
    exit 1
fi

# Double-check it's not the boot drive
if [ "$USB_DEV" = "$BOOT_DEVICE" ]; then
    echo -e "${RED}ERROR: $USB_DEV is your BOOT drive (Arch ISO). You cannot install to it while running from it!${NC}"
    echo "Please select the OTHER USB drive."
    exit 1
fi

# Show what will be destroyed
echo ""
echo -e "${RED}⚠️  WARNING: This will DESTROY ALL DATA on:${NC}"
lsblk -o NAME,MODEL,SIZE "$USB_DEV"
echo ""
read -p "Type 'YES' to continue: " confirm
if [ "$confirm" != "YES" ]; then
    echo "Aborted."
    exit 1
fi

# ============================================================
# STEP 3: PROMPT FOR USER INFORMATION
# ============================================================
echo ""
echo -e "${GREEN}=== User Configuration ===${NC}"
read -p "Enter username: " USERNAME

while true; do
    read -s -p "Enter password: " PASSWORD
    echo
    read -s -p "Confirm password: " PASSWORD2
    echo
    if [ "$PASSWORD" = "$PASSWORD2" ] && [ -n "$PASSWORD" ]; then
        break
    else
        echo -e "${RED}Passwords do not match or are empty. Try again.${NC}"
    fi
done

read -p "Enter timezone (e.g., America/New_York) [UTC]: " TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"

read -p "Enter hostname [arch-usb]: " HOSTNAME
HOSTNAME="${HOSTNAME:-arch-usb}"

read -p "Enter keymap [us]: " KEYMAP
KEYMAP="${KEYMAP:-us}"

# Summary
echo ""
echo -e "${GREEN}=== Installation Summary ===${NC}"
echo "Target USB:     $USB_DEV ($(lsblk -o MODEL,SIZE "$USB_DEV" | tail -1))"
echo "Username:       $USERNAME"
echo "Hostname:       $HOSTNAME"
echo "Timezone:       $TIMEZONE"
echo "Keymap:         $KEYMAP"
echo ""
read -p "Proceed with installation? (yes/no): " proceed
if [ "$proceed" != "yes" ]; then
    echo "Aborted."
    exit 1
fi

# ============================================================
# STEP 4: BEGIN INSTALLATION
# ============================================================
echo ""
echo -e "${GREEN}=== Starting installation on $USB_DEV ===${NC}"

# Unmount anything on the target USB
echo "Unmounting any existing partitions..."
umount "${USB_DEV}"* 2>/dev/null || true

# Wipe the first few MB to ensure clean state
echo "Wiping partition table..."
dd if=/dev/zero of="$USB_DEV" bs=1M count=10 status=progress

# Create partitions
echo "Creating partitions..."
parted "$USB_DEV" mklabel gpt
parted "$USB_DEV" mkpart primary fat32 1MiB 513MiB
parted "$USB_DEV" set 1 esp on
parted "$USB_DEV" mkpart primary 513MiB 41GiB
parted "$USB_DEV" mkpart primary 41GiB 100%
sleep 2

EFI_PART="${USB_DEV}1"
SYSTEM_LUKS="${USB_DEV}2"
HOME_LUKS="${USB_DEV}3"

echo "Partitions created:"
lsblk "$USB_DEV"

# ============================================================
# STEP 5: LUKS ENCRYPTION
# ============================================================
echo ""
echo -e "${GREEN}=== Setting up LUKS encryption ===${NC}"
echo "Encrypting system partition..."
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 \
    --cipher aes-256-gcm \
    --pbkdf argon2id \
    --iter-time 2000 \
    "$SYSTEM_LUKS" -

echo "Encrypting home partition..."
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 \
    --cipher aes-256-gcm \
    --pbkdf argon2id \
    "$HOME_LUKS" -

echo "Opening encrypted partitions..."
echo -n "$PASSWORD" | cryptsetup open "$SYSTEM_LUKS" cryptsys -
echo -n "$PASSWORD" | cryptsetup open "$HOME_LUKS" crypthome -

# ============================================================
# STEP 6: FORMATTING
# ============================================================
echo "Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -O '^has_journal' /dev/mapper/cryptsys
mkfs.ext4 -O '^has_journal' /dev/mapper/crypthome

# ============================================================
# STEP 7: MOUNTING
# ============================================================
echo "Mounting partitions..."
mount /dev/mapper/cryptsys /mnt
mkdir -p /mnt/home /mnt/boot
mount /dev/mapper/crypthome /mnt/home
mount "$EFI_PART" /mnt/boot

# ============================================================
# STEP 8: BASE INSTALLATION
# ============================================================
echo ""
echo -e "${GREEN}=== Installing base system (this takes ~10-15 minutes) ===${NC}"

# Update mirrorlist for faster downloads
echo "Updating mirrors..."
pacman -Sy --noconfirm reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

# Install base packages
echo "Installing base packages..."
pacstrap -K /mnt \
    base base-devel linux-zen linux-zen-headers \
    linux-firmware sof-firmware \
    lvm2 cryptsetup \
    vim nano sudo \
    networkmanager iwd wpa_supplicant \
    git curl wget \
    efitools sbctl \
    amd-ucode intel-ucode \
    pipewire pipewire-pulse wireplumber \
    xdg-desktop-portal-gnome

# Generate fstab
genfstab -U /mnt >> /mnt/etc/fstab

# ============================================================
# STEP 9: CHROOT CONFIGURATION
# ============================================================
echo ""
echo -e "${GREEN}=== Configuring system ===${NC}"

cat << CHROOT | arch-chroot /mnt /bin/bash
set -e

# Timezone
ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOSTNAME.localdomain $HOSTNAME
HOSTS

# Set passwords
echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,storage,optical,network,power -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# Initramfs with LUKS support
cat > /etc/mkinitcpio.conf << MKINIT
MODULES=(nvme)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)
COMPRESSION=(zstd)
MKINIT
mkinitcpio -P

# Install systemd-boot
bootctl --esp-path=/boot install

# Bootloader config
cat > /boot/loader/loader.conf << LOADER
default arch.conf
timeout 3
console-mode max
LOADER

# Get UUIDs for kernel command line
SYS_UUID=\$(blkid -s UUID -o value $SYSTEM_LUKS)
HOME_UUID=\$(blkid -s UUID -o value $HOME_LUKS)

# Create boot entry
cat > /boot/loader/entries/arch.conf << ENTRY
title   Arch Linux (GNOME + LUKS)
linux   /vmlinuz-linux-zen
initrd  /initramfs-linux-zen.img
options rd.luks.name=\$SYS_UUID=cryptsys rd.luks.name=\$HOME_UUID=crypthome root=/dev/mapper/cryptsys rootflags=noatime quiet rw
ENTRY

# Enable services
systemctl enable NetworkManager
systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Flash memory optimization (RAM-only journal)
mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/usb-stick.conf << JOURNAL
[Journal]
Storage=volatile
RuntimeMaxUse=100M
JOURNAL

# Add noatime to fstab and enable trim
sed -i 's/defaults/defaults,noatime,discard=async/' /etc/fstab
systemctl enable fstrim.timer

# Install GNOME
pacman -S --noconfirm gnome gnome-tweaks gdm firefox

# Enable display manager
systemctl enable gdm

# Install paru (AUR helper)
git clone https://aur.archlinux.org/paru.git /home/$USERNAME/paru
chown -R $USERNAME:$USERNAME /home/$USERNAME/paru
cd /home/$USERNAME/paru
sudo -u $USERNAME makepkg -si --noconfirm
cd / && rm -rf /home/$USERNAME/paru

# GNOME performance tuning for USB
sudo -u $USERNAME gsettings set org.gnome.desktop.interface enable-animations false

CHROOT

# ============================================================
# STEP 10: CLEANUP
# ============================================================
echo ""
echo -e "${GREEN}=== Cleaning up ===${NC}"
umount -R /mnt
cryptsetup close crypthome
cryptsetup close cryptsys

echo ""
echo -e "${GREEN}=========================================="
echo "✅ INSTALLATION COMPLETE!"
echo "==========================================${NC}"
echo ""
echo "Next steps:"
echo "1. Remove the Arch ISO USB (the small one)"
echo "2. Keep ONLY your SanDisk Extreme PRO inserted"
echo "3. Reboot your computer"
echo "4. Enter boot menu (F12/F9/ESC) and select your SanDisk"
echo "5. Enter your LUKS password TWICE (system + home)"
echo "6. Login with: $USERNAME / [your password]"
echo ""
echo -e "${YELLOW}First boot may take 1-2 minutes while GNOME initializes.${NC}"
echo ""
