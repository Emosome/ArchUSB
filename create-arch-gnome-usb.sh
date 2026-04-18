#!/bin/bash
# Arch Linux + GNOME + LUKS USB Installer
# WORKING VERSION - Uses aes-cbc-essiv:sha256 cipher

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

clear
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    Arch Linux USB Installer v5.0${NC}"
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
# FUNCTION FOR INPUT
# ============================================================
get_input() {
    local prompt="$1"
    local result
    read -p "$prompt" result </dev/tty
    echo "$result"
}

get_password() {
    local prompt="$1"
    local result
    read -s -p "$prompt" result </dev/tty
    echo
    echo "$result"
}

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

USB_DEV=$(get_input "Enter FULL device path (e.g., /dev/sda): ")
USB_DEV=$(echo "$USB_DEV" | xargs)

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

confirm=$(get_input "Type 'YES' to continue: ")
if [ "$confirm" != "YES" ]; then
    echo "Installation cancelled."
    exit 0
fi

# ============================================================
# USER INFORMATION
# ============================================================
echo ""
echo -e "${GREEN}=== User Setup ===${NC}"

USERNAME=$(get_input "Enter username: ")

while true; do
    PASSWORD=$(get_password "Enter password: ")
    PASSWORD2=$(get_password "Confirm password: ")
    if [ "$PASSWORD" = "$PASSWORD2" ] && [ -n "$PASSWORD" ]; then
        break
    else
        echo -e "${RED}Passwords do not match or empty. Try again.${NC}"
    fi
done

TIMEZONE=$(get_input "Enter timezone (e.g., America/New_York) [UTC]: ")
TIMEZONE="${TIMEZONE:-UTC}"

HOSTNAME=$(get_input "Enter hostname [arch-usb]: ")
HOSTNAME="${HOSTNAME:-arch-usb}"

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

proceed=$(get_input "Start installation? (yes/no): ")
if [ "$proceed" != "yes" ]; then
    echo "Cancelled."
    exit 0
fi

# ============================================================
# PARTITION
# ============================================================
echo ""
echo -e "${GREEN}=== Partitioning drive ===${NC}"

umount "${USB_DEV}"* 2>/dev/null || true
dd if=/dev/zero of="$USB_DEV" bs=1M count=10 status=progress 2>/dev/null

parted -s "$USB_DEV" mklabel gpt
parted -s "$USB_DEV" mkpart primary fat32 1MiB 513MiB
parted -s "$USB_DEV" set 1 esp on
parted -s "$USB_DEV" mkpart primary 513MiB 41GiB
parted -s "$USB_DEV" mkpart primary 41GiB 100%
sleep 2

EFI_PART="${USB_DEV}1"
SYSTEM_LUKS="${USB_DEV}2"
HOME_LUKS="${USB_DEV}3"

echo -e "${GREEN}✓ Partitions created${NC}"
lsblk "$USB_DEV"

# ============================================================
# LUKS ENCRYPTION (USING WORKING CIPHER)
# ============================================================
echo ""
echo -e "${GREEN}=== Setting up LUKS encryption ===${NC}"
echo -e "${YELLOW}Using aes-cbc-essiv:sha256 cipher (compatible)${NC}"

echo "Encrypting system partition..."
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 \
    --cipher aes-cbc-essiv:sha256 \
    --key-size 256 \
    --pbkdf argon2id \
    "$SYSTEM_LUKS" -

echo "Encrypting home partition..."
echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 \
    --cipher aes-cbc-essiv:sha256 \
    --key-size 256 \
    --pbkdf argon2id \
    "$HOME_LUKS" -

echo "Opening encrypted partitions..."
echo -n "$PASSWORD" | cryptsetup open "$SYSTEM_LUKS" cryptsys -
echo -n "$PASSWORD" | cryptsetup open "$HOME_LUKS" crypthome -

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

pacman -Sy --noconfirm reflector 2>/dev/null
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist 2>/dev/null

pacstrap -K /mnt base base-devel linux-zen linux-zen-headers linux-firmware \
    lvm2 cryptsetup vim sudo networkmanager git curl \
    amd-ucode intel-ucode pipewire pipewire-pulse wireplumber \
    xdg-desktop-portal-gnome

genfstab -U /mnt >> /mnt/etc/fstab

# ============================================================
# CHROOT
# ============================================================
echo ""
echo -e "${GREEN}=== Configuring system ===${NC}"

arch-chroot /mnt /bin/bash << CHROOT
set -e

ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
hwclock --systohc

echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname

echo "root:$PASSWORD" | chpasswd
useradd -m -G wheel,audio,video,storage,optical,network,power -s /bin/bash $USERNAME
echo "$USERNAME:$PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

cat > /etc/mkinitcpio.conf << EOF
MODULES=(nvme aesni_intel)
BINARIES=()
FILES=()
HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole sd-encrypt block filesystems fsck)
COMPRESSION=(zstd)
EOF
mkinitcpio -P

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

systemctl enable NetworkManager systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

mkdir -p /etc/systemd/journald.conf.d/
cat > /etc/systemd/journald.conf.d/usb.conf << EOF
[Journal]
Storage=volatile
RuntimeMaxUse=100M
EOF

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
echo "1. Remove the Arch ISO USB"
echo "2. Reboot"
echo "3. Boot from your SanDisk"
echo "4. Enter LUKS password TWICE"
echo "5. Login: $USERNAME"
echo ""
