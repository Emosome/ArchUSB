#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

LOGFILE="/root/arch-laptop-install.log"
exec > >(tee -a "$LOGFILE") 2>&1

trap 'echo -e "${RED}ERROR:${NC} Install failed on line $LINENO. Review $LOGFILE and the last command output."' ERR

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
  for cmd in arch-chroot blkid cryptsetup genfstab lsblk mount pacman pacstrap parted partprobe sgdisk systemctl umount wipefs btrfs tee; do
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
printf "%b\n" "${GREEN}   Arch Linux Laptop Installer v1.0${NC}"
printf "%b\n" "${GREEN}========================================${NC}"
printf "%b\n" "${YELLOW}Log file:${NC} $LOGFILE"
printf "\n"

echo -e "${YELLOW}Detected block devices:${NC}"
lsblk -d -o NAME,MODEL,SIZE,TRAN,TYPE
printf "\n"

read -r -p "Enter FULL target disk path (example: /dev/nvme0n1 or /dev/sda): " TARGET_DISK
if [[ -z "${TARGET_DISK:-}" || ! -b "$TARGET_DISK" ]]; then
  echo -e "${RED}Invalid block device:${NC} ${TARGET_DISK:-<empty>}"
  exit 1
fi

read -r -p "Enter username: " USERNAME
[[ -n "${USERNAME:-}" ]] || { echo -e "${RED}Username cannot be empty.${NC}"; exit 1; }

read -r -p "Enter hostname [arch-laptop]: " HOSTNAME
HOSTNAME="${HOSTNAME:-arch-laptop}"

read -r -p "Enter timezone [UTC]: " TIMEZONE
TIMEZONE="${TIMEZONE:-UTC}"
[[ -e "/usr/share/zoneinfo/$TIMEZONE" ]] || { echo -e "${RED}Timezone not found:${NC} $TIMEZONE"; exit 1; }

read -r -p "Enter locale [en_US.UTF-8]: " LOCALE
LOCALE="${LOCALE:-en_US.UTF-8}"

read -r -p "Enter keymap [us]: " KEYMAP
KEYMAP="${KEYMAP:-us}"

read -r -p "CPU vendor for microcode [intel/amd/none]: " CPU_VENDOR
CPU_VENDOR="${CPU_VENDOR,,}"

case "$CPU_VENDOR" in
  intel) MICROCODE_PKG="intel-ucode" ;;
  amd)   MICROCODE_PKG="amd-ucode" ;;
  none|"") MICROCODE_PKG="" ;;
  *) echo -e "${RED}Invalid CPU vendor. Use intel, amd, or none.${NC}"; exit 1 ;;
esac

read -r -p "Enable hibernation? [y/N]: " ENABLE_HIBERNATION
ENABLE_HIBERNATION="${ENABLE_HIBERNATION,,}"

prompt_secret USER_PASS "Enter password for user ${USERNAME}: "
prompt_secret ROOT_PASS "Enter root password: "
prompt_secret LUKS_PASS "Enter LUKS passphrase: "

printf "\n"
echo -e "${RED}Selected target:${NC}"
lsblk -o NAME,MODEL,SIZE,TYPE,MOUNTPOINT "$TARGET_DISK"
printf "\n"
echo -e "${RED}This will ERASE all data on $TARGET_DISK.${NC}"
read -r -p "Type YES to continue: " CONFIRM
[[ "$CONFIRM" == "YES" ]] || { echo "Cancelled."; exit 0; }

echo -e "${YELLOW}Refreshing keyring and mirrors...${NC}"
timedatectl set-ntp true || true
pacman -Sy --noconfirm archlinux-keyring reflector
reflector --latest 20 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || true

echo -e "${YELLOW}Wiping and partitioning ${TARGET_DISK}...${NC}"
cleanup_mounts
sgdisk --zap-all "$TARGET_DISK"
wipefs -a "$TARGET_DISK"
partprobe "$TARGET_DISK" || true

# 1 GiB EFI, 1 GiB /boot, rest LUKS
parted -s "$TARGET_DISK" mklabel gpt
parted -s "$TARGET_DISK" mkpart ESP fat32 1MiB 1025MiB
parted -s "$TARGET_DISK" set 1 esp on
parted -s "$TARGET_DISK" mkpart BOOT ext4 1025MiB 2049MiB
parted -s "$TARGET_DISK" mkpart CRYPTROOT 2049MiB 100%
partprobe "$TARGET_DISK"
sleep 2

if [[ "$TARGET_DISK" =~ nvme|mmcblk ]]; then
  EFI_PART="${TARGET_DISK}p1"
  BOOT_PART="${TARGET_DISK}p2"
  ROOT_PART="${TARGET_DISK}p3"
else
  EFI_PART="${TARGET_DISK}1"
  BOOT_PART="${TARGET_DISK}2"
  ROOT_PART="${TARGET_DISK}3"
fi

echo -e "${YELLOW}Creating filesystems...${NC}"
mkfs.fat -F 32 -n EFI "$EFI_PART"
mkfs.ext4 -L BOOT "$BOOT_PART"

printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --pbkdf argon2id "$ROOT_PART" -
printf '%s' "$LUKS_PASS" | cryptsetup open "$ROOT_PART" cryptroot -

mkfs.btrfs -f -L ARCHROOT /dev/mapper/cryptroot

echo -e "${YELLOW}Creating Btrfs subvolumes...${NC}"
mount /dev/mapper/cryptroot /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@log
btrfs subvolume create /mnt/@snapshots
umount /mnt

echo -e "${YELLOW}Mounting target system...${NC}"
mount -o noatime,compress=zstd,subvol=@ /dev/mapper/cryptroot /mnt
mkdir -p /mnt/{boot,home,.snapshots,var/log}
mount -o noatime,compress=zstd,subvol=@home /dev/mapper/cryptroot /mnt/home
mount -o noatime,compress=zstd,subvol=@snapshots /dev/mapper/cryptroot /mnt/.snapshots
mount -o noatime,compress=zstd,subvol=@log /dev/mapper/cryptroot /mnt/var/log
mount "$BOOT_PART" /mnt/boot
mkdir -p /mnt/boot/efi
mount "$EFI_PART" /mnt/boot/efi

echo -e "${YELLOW}Installing base system...${NC}"

BASE_PKGS=(
  base base-devel
  linux linux-headers linux-firmware
  grub efibootmgr
  cryptsetup mkinitcpio
  sudo networkmanager
  git curl vim nano
  btrfs-progs
  reflector man-db man-pages texinfo bash-completion
  gnome gdm firefox
  pipewire pipewire-pulse wireplumber
  xdg-desktop-portal-gnome
  tlp
  zram-generator
)

if [[ -n "$MICROCODE_PKG" ]]; then
  BASE_PKGS+=("$MICROCODE_PKG")
fi

pacstrap -K /mnt "${BASE_PKGS[@]}"

genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"

cat > /mnt/root/postinstall.sh <<'POSTINSTALL'
#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "POSTINSTALL ERROR on line $LINENO"; exit 1' ERR

: "${ROOT_UUID:?}"
: "${HOSTNAME:?}"
: "${TIMEZONE:?}"
: "${LOCALE:?}"
: "${KEYMAP:?}"
: "${USERNAME:?}"
: "${USER_PASS:?}"
: "${ROOT_PASS:?}"
: "${ENABLE_HIBERNATION:?}"

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

if ! id "$USERNAME" >/dev/null 2>&1; then
  useradd -m -G wheel -s /bin/bash "$USERNAME"
fi
echo "$USERNAME:$USER_PASS" | chpasswd

install -d -m 0750 /etc/sudoers.d
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel

sed -i 's/^HOOKS=.*/HOOKS=(base systemd autodetect microcode modconf kms keyboard sd-vconsole block sd-encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub

CMDLINE="rd.luks.name=${ROOT_UUID}=cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet"

if grep -q '^GRUB_CMDLINE_LINUX=' /etc/default/grub; then
  sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"${CMDLINE}\"|" /etc/default/grub
else
  echo "GRUB_CMDLINE_LINUX=\"${CMDLINE}\"" >> /etc/default/grub
fi

if grep -q '^#\?GRUB_ENABLE_CRYPTODISK=' /etc/default/grub; then
  sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
else
  echo 'GRUB_ENABLE_CRYPTODISK=y' >> /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=Arch --recheck
grub-mkconfig -o /boot/grub/grub.cfg

systemctl enable NetworkManager
systemctl enable gdm.service
systemctl enable fstrim.timer
systemctl enable tlp.service

# zram default: no disk swap unless you later choose hibernate
mkdir -p /etc/systemd/zram-generator.conf.d
cat > /etc/systemd/zram-generator.conf.d/default.conf <<ZRAM
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

# Optional: disable if you later build explicit hibernation support
if [[ "$ENABLE_HIBERNATION" == "y" ]]; then
  echo "NOTE: Hibernation requested, but this script does not create disk swap."
  echo "You must add a real swap partition or swap file and update resume parameters later."
fi

# sudo -u "$USERNAME" bash <<'UEOF'
# set -Eeuo pipefail
# workdir="$(mktemp -d)"
# cd "$workdir"
# git clone https://aur.archlinux.org/paru.git
# cd paru
# makepkg -sf --noconfirm
# pkgfile="$(find . -maxdepth 1 -type f -name 'paru-*.pkg.tar.*' | head -n1)"
# if [[ -z "${pkgfile:-}" ]]; then
  # echo "Failed to locate built paru package"
  # exit 1
# fi
# printf '%s' "$PWD/$pkgfile" > /tmp/paru_pkg_path
# UEOF
cat > /etc/motd <<'MOTD'
Post-install note:
To install paru after first boot, run:

sudo pacman -S --needed base-devel git
cd /tmp
git clone https://aur.archlinux.org/paru.git
cd paru
makepkg -si
MOTD

pacman -U --noconfirm "$(cat /tmp/paru_pkg_path)"
rm -f /tmp/paru_pkg_path

pacman -Q gdm gnome-shell networkmanager tlp zram-generator >/dev/null
POSTINSTALL

chmod +x /mnt/root/postinstall.sh

arch-chroot /mnt /usr/bin/env \
  ROOT_UUID="$ROOT_UUID" \
  HOSTNAME="$HOSTNAME" \
  TIMEZONE="$TIMEZONE" \
  LOCALE="$LOCALE" \
  KEYMAP="$KEYMAP" \
  USERNAME="$USERNAME" \
  USER_PASS="$USER_PASS" \
  ROOT_PASS="$ROOT_PASS" \
  ENABLE_HIBERNATION="$ENABLE_HIBERNATION" \
  /root/postinstall.sh

arch-chroot /mnt pacman -Q gdm gnome-shell networkmanager tlp zram-generator >/dev/null
sync
cleanup_mounts

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Install complete.${NC}"
echo -e "${GREEN}========================================${NC}"
echo
echo "Next steps:"
echo "  1. Reboot"
echo "  2. Remove the Arch ISO USB"
echo "  3. Boot the internal SSD in UEFI mode"
echo "  4. Enter your LUKS passphrase once"
echo "  5. Log in as $USERNAME"
echo
echo "Install log saved to: $LOGFILE"
