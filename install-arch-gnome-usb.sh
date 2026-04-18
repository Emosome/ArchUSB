#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

trap 'echo -e "${RED}ERROR:${NC} Install failed on line $LINENO. Review the last command output."' ERR

require_root() {
  if [[ ${EUID} -ne 0 ]]; then
    echo -e "${RED}Run this script as root from the Arch ISO live environment.${NC}"
    exit 1
  fi
}

require_uefi() {
  if [[ ! -d /sys/firmware/efi ]]; then
    echo -e "${RED}This script requires UEFI mode. Reboot the Arch ISO in UEFI mode and try again.${NC}"
    exit 1
  fi
}

require_cmds() {
  local missing=0
  for cmd in arch-chroot blkid cryptsetup genfstab lsblk mount pacman pacstrap parted partprobe sgdisk systemctl umount wipefs; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      echo -e "${RED}Missing required command:${NC} $cmd"
      missing=1
    fi
  done
  (( missing == 0 )) || exit 1
}

prompt_secret() {
  local __var="$1"
  local prompt="$2"
  local first second
  read -r -s -p "$prompt" first
  echo
  read -r -s -p "Confirm: " second
  echo
  if [[ -z "$first" || "$first" != "$second" ]]; then
    echo -e "${RED}Values did not match or were empty.${NC}"
    exit 1
  fi
  printf -v "$__var" '%s' "$first"
}

cleanup_mounts() {
  swapoff -a 2>/dev/null || true
  umount -R /mnt 2>/dev/null || true
  cryptsetup close cryptroot 2>/dev/null || true
}

require_root
require_uefi
require_cmds
cleanup_mounts

clear
printf "%b\n" "${GREEN}========================================${NC}"
printf "%b\n" "${GREEN}   Arch Linux USB Installer v7.0${NC}"
printf "%b\n" "${GREEN}========================================${NC}"
printf "\n"

echo -e "${YELLOW}Detected block devices:${NC}"
lsblk -d -o NAME,MODEL,SIZE,TRAN,TYPE
printf "\n"

read -r -p "Enter FULL target device path (example: /dev/sdb): " USB_DEV
if [[ -z "${USB_DEV:-}" || ! -b "$USB_DEV" ]]; then
  echo -e "${RED}Invalid block device:${NC} ${USB_DEV:-<empty>}"
  exit 1
fi

read -r -p "Enter username: " USERNAME
[[ -n "${USERNAME:-}" ]] || { echo -e "${RED}Username cannot be empty.${NC}"; exit 1; }

read -r -p "Enter hostname [arch-usb]: " HOSTNAME
HOSTNAME="${HOSTNAME:-arch-usb}"

read -r -p "Enter timezone [UTC]: " TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"
[[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || { echo -e "${RED}Timezone not found:${NC} $TIMEZONE"; exit 1; }

read -r -p "Enter locale [en_US.UTF-8]: " LOCALE
LOCALE="${LOCALE:-en_US.UTF-8}"

read -r -p "Enter keymap [us]: " KEYMAP
KEYMAP="${KEYMAP:-us}"

prompt_secret USER_PASS "Enter password for user ${USERNAME}: "
prompt_secret ROOT_PASS "Enter root password: "
prompt_secret LUKS_PASS "Enter LUKS passphrase: "

printf "\n"
echo -e "${RED}Selected target:${NC}"
lsblk -o NAME,MODEL,SIZE,TYPE,MOUNTPOINT "$USB_DEV"
printf "\n"
echo -e "${RED}This will ERASE all data on $USB_DEV.${NC}"
read -r -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Cancelled."; exit 0; }

echo -e "${YELLOW}Refreshing keyring and mirrors...${NC}"
timedatectl set-ntp true || true
pacman -Sy --noconfirm archlinux-keyring reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || true

echo -e "${YELLOW}Wiping and partitioning ${USB_DEV}...${NC}"
cleanup_mounts
sgdisk --zap-all "$USB_DEV"
wipefs -a "$USB_DEV"
partprobe "$USB_DEV" || true

parted -s "$USB_DEV" mklabel gpt
parted -s "$USB_DEV" mkpart ESP fat32 1MiB 1025MiB
parted -s "$USB_DEV" set 1 esp on
parted -s "$USB_DEV" mkpart CRYPTROOT 1025MiB 100%
partprobe "$USB_DEV"
sleep 2

if [[ "$USB_DEV" =~ nvme|mmcblk ]]; then
  EFI_PART="${USB_DEV}p1"
  ROOT_PART="${USB_DEV}p2"
else
  EFI_PART="${USB_DEV}1"
  ROOT_PART="${USB_DEV}2"
fi

echo -e "${YELLOW}Creating filesystems...${NC}"
mkfs.fat -F 32 -n ARCHUSBEFI "$EFI_PART"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id "$ROOT_PART" -
printf '%s' "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -
mkfs.ext4 -L ARCHUSBROOT /dev/mapper/cryptroot

echo -e "${YELLOW}Mounting target system...${NC}"
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

echo -e "${YELLOW}Installing base system...${NC}"
pacstrap -K /mnt \
  base base-devel \
  linux linux-headers linux-firmware \
  grub efibootmgr \
  cryptsetup mkinitcpio \
  sudo networkmanager \
  git curl vim nano \
  gnome gdm firefox \
  pipewire pipewire-pulse wireplumber \
  xdg-desktop-portal-gnome \
  intel-ucode amd-ucode \
  reflector man-db man-pages texinfo bash-completion

genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"

export ROOT_UUID HOSTNAME TIMEZONE LOCALE KEYMAP USERNAME USER_PASS ROOT_PASS

arch-chroot /mnt /usr/bin/env \
  ROOT_UUID="$ROOT_UUID" \
  HOSTNAME="$HOSTNAME" \
  TIMEZONE="$TIMEZONE" \
  LOCALE="$LOCALE" \
  KEYMAP="$KEYMAP" \
  USERNAME="$USERNAME" \
  USER_PASS="$USER_PASS" \
  ROOT_PASS="$ROOT_PASS" \
  /bin/bash <<'CHROOT'
set -Eeuo pipefail

ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

if grep -Eq "^#?${LOCALE//./\\.}[[:space:]]+UTF-8" /etc/locale.gen; then
  sed -i "s/^#\?\(${LOCALE//./\\.}[[:space:]]\+UTF-8\)/\1/" /etc/locale.gen
else
  echo "${LOCALE} UTF-8" >> /etc/locale.gen
fi
locale-gen

echo "LANG=$LOCALE" > /etc/locale.conf
echo "KEYMAP=$KEYMAP" > /etc/vconsole.conf

echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<HOSTS
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
HOSTS

echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$USER_PASS" | chpasswd
install -d -m 0750 /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"rd.luks.name=${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot rw quiet\"|" /etc/default/grub
else
  echo "GRUB_CMDLINE_LINUX=\"rd.luks.name=${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot rw quiet\"" >> /etc/default/grub
fi
if grep -q '^#\?GRUB_ENABLE_CRYPTODISK=' /etc/default/grub; then
  sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
else
  echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCHUSB --removable --recheck
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager
systemctl enable gdm
systemctl enable fstrim.timer

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/usb.conf <<JEOF
[Journal]
Storage=volatile
RuntimeMaxUse=64M
JEOF

sed -i '/[[:space:]]\/[[:space:]]/ s/,relatime//; /[[:space:]]\/[[:space:]]/ s/defaults/defaults,noatime/' /etc/fstab
sed -i '/[[:space:]]\/boot[[:space:]]/ s/,relatime//; /[[:space:]]\/boot[[:space:]]/ s/defaults/defaults,noatime/' /etc/fstab

sudo -u "$USERNAME" bash <<'UEOF'
set -Eeuo pipefail
cd /tmp
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si --noconfirm
UEOF
CHROOT

sync
cleanup_mounts

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Install complete.${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "Next steps:"
echo "  1. Reboot"
echo "  2. Remove the Arch ISO USB"
echo "  3. Boot the target USB in UEFI mode"
echo "  4. Enter your LUKS passphrase once"
echo "  5. Log in as $USERNAME"
