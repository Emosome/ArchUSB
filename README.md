# ArchUSB
Arch install on a USB

# For Wi-Fi (skip if using ethernet)
iwctl
# Inside iwctl:
device list
station wlan0 scan
station wlan0 get-networks
station wlan0 connect "YOUR_WIFI_NAME"

# Update your GitHub script with the version above, then:
curl -o /root/install.sh YOUR_RAW_URL && bash /root/install.sh

or

curl -o /root/install.sh YOUR_RAW_URL 

chmod +x /root/install.sh

/root/install.sh



Post-install commands (DO THIS)
1. Create swap subvolume
sudo btrfs subvolume create /swap
2. Create swap file (20GB)
sudo btrfs filesystem mkswapfile --size 20g --uuid clear /swap/swapfile
3. Enable swap
sudo swapon /swap/swapfile

Check:

swapon --show
4. Add to fstab
echo '/swap/swapfile none swap defaults 0 0' | sudo tee -a /etc/fstab
💤 Optional: enable hibernation

If you want it:

Get resume offset
sudo btrfs inspect-internal map-swapfile -r /swap/swapfile
Add to GRUB:
resume=UUID=<cryptroot-uuid> resume_offset=<number>

Then:

sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo mkinitcpio -P
