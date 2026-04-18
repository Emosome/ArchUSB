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
