# Raksha OS — ISO Package Manifest
# Defines all packages to include in the ISO build
# Size: ~15-20GB (includes 8GB of AI models)
# Last updated: 2026-06-20

# ═══════════════════════════════════════════════════════════════
# SECTION 1: BASE SYSTEM (Debian 13 Trixie minimal + KDE)
# ═══════════════════════════════════════════════════════════════

# Core
debian-standard
kde-plasma-desktop
kde-standard
sddm
pipewire
pipewire-pulse
wireplumber
network-manager
modemmanager
firmware-linux
firmware-linux-nonfree
firmware-misc-nonfree
intel-microcode
amd64-microcode

# Bootloader
grub-pc
grub-efi-amd64
grub-efi-amd64-signed
efibootmgr
os-prober

# ═══════════════════════════════════════════════════════════════
# SECTION 2: COGNITIVE ENGINE (llama.cpp + AI Models)
# ═══════════════════════════════════════════════════════════════

# llama.cpp build dependencies
build-essential
cmake
git
libopenblas-dev
liblapack-dev
libblas-dev
cuda-toolkit-12-4
nvidia-cuda-dev
nvidia-driver
libnvidia-compute-550
libnvidia-ml-dev

# AI Models (8GB total, included in ISO)
# /home/ravan/llama.cpp/models/gemma-4-E2B_q4_0-it.gguf (3.2GB)
# /home/ravan/llama.cpp/models/NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf (2.7GB)
# /home/ravan/llama.cpp/models/UI-TARS-2B-SFT-Q4_K_M.gguf (1.1GB)
# /home/ravan/llama.cpp/models/UI-TARS-2B-SFT-mmproj-fp16.gguf (1.3GB)

# ═══════════════════════════════════════════════════════════════
# SECTION 3: COMPUTER USE (Mouse/Keyboard/Vision)
# ═══════════════════════════════════════════════════════════════

xdotool
scrot
imagemagick
wmctrl
x11-utils
xclip
python3-opencv
python3-pil
python3-numpy
python3-pip
tesseract-ocr
tesseract-ocr-eng
tesseract-ocr-chi-sim
tesseract-ocr-chi-tra
tesseract-ocr-jpn
tesseract-ocr-kor
tesseract-ocr-fra
tesseract-ocr-deu
tesseract-ocr-spa

# ═══════════════════════════════════════════════════════════════
# SECTION 4: ASH NERVOUS SYSTEM + GATEWAYS
# ═══════════════════════════════════════════════════════════════

# Python packages (installed via pip in overlay)
# pyyaml, requests, faster-whisper, sounddevice, pyatspi

# Gateway: WhatsApp (Baileys — Node.js)
# whatsapp_baileys/ (17MB) copied to /var/lib/ash/identity/
# whatsapp_auth/ (sessions) copied to /var/lib/ash/identity/
# node_modules/ (in gateways dir)

# Gateway: Telegram (Python)
# telegram-gateway.py in /opt/ash-core/gateways/

# Gateway: Voice (Piper TTS + Whisper STT)
# en_US-ryan-high.onnx (115MB) — male voice
# en_US-amy-medium.onnx (60MB) — female voice
# whisper-models/base.en.pt (140MB) — speech recognition

# System tools for Ash
sqlite3
timeshift
cron
systemd-cron
libsecret-1-0
gnome-keyring
ssh-agent
nodejs
npm

# ═══════════════════════════════════════════════════════════════
# SECTION 5: FILESYSTEM & HARDWARE
# ═══════════════════════════════════════════════════════════════

ntfs-3g
exfat-fuse
exfatprogs
hfsprogs
jfsutils
reiserfsprogs
xfsprogs
btrfs-progs
lvm2
mdadm
gdisk
parted
gparted
dosfstools
e2fsprogs
fsck.ext4

# ═══════════════════════════════════════════════════════════════
# SECTION 6: NETWORKING & REMOTE
# ═══════════════════════════════════════════════════════════════

openssh-server
openssh-client
tailscale
curl
wget
nmap
net-tools
iputils-ping
traceroute
dnsutils
tcpdump
wireshark-common
wireguard-tools
openvpn
network-manager-openvpn
smbclient
cifs-utils
nfs-common
avahi-daemon
cups
cups-client

# ═══════════════════════════════════════════════════════════════
# SECTION 7: DESKTOP APPLICATIONS
# ═══════════════════════════════════════════════════════════════

# KDE Apps
konsole
dolphin
kate
okular
gwenview
spectacle
ark
kcalc
kcharselect

# Browsers
firefox-esr
chromium

# Media
vlc
ffmpeg
pulseaudio-utils
pavucontrol
playerctl

# Office
libreoffice
libreoffice-gtk3
libreoffice-plasma

# Development
vim
nano
git
git-gui
meld
python3-venv
python3-virtualenv
nodejs
npm
code

# ═══════════════════════════════════════════════════════════════
# SECTION 8: INSTALLER (Calamares)
# ═══════════════════════════════════════════════════════════════

calamares
calamares-settings-debian
extra-cmake-modules
qtbase5-dev
qttools5-dev-tools
libkpmcore-dev
libparted-dev
libboost-dev
libyaml-cpp-dev
polkit-qt-1-dev
qt6-svg-dev
qt6-tools-dev

# ═══════════════════════════════════════════════════════════════
# SECTION 9: ISO BUILD TOOLS (for reference, not in ISO)
# ═══════════════════════════════════════════════════════════════

# xorriso
# isolinux
# syslinux-utils
# squashfs-tools
# genisoimage
# live-build
# debootstrap

# ═══════════════════════════════════════════════════════════════
# SECTION 10: LIVE SYSTEM (Boot-time)
# ═══════════════════════════════════════════════════════════════

live-boot
live-boot-initramfs-tools
live-tools
live-config
live-config-systemd
user-setup
sudo
# ═══════════════════════════════════════════════════════════════
# SECTION 11: SECURITY
# ═══════════════════════════════════════════════════════════════

ufw
gufw
apparmor
apparmor-utils
apparmor-profiles
apparmor-profiles-extra
fail2ban
rkhunter
chkrootkit
auditd
acl
# ═══════════════════════════════════════════════════════════════
# SECTION 12: FONTS & LOCALIZATION
# ═══════════════════════════════════════════════════════════════

fonts-dejavu
fonts-liberation
fonts-noto
fonts-noto-cjk
fonts-noto-color-emoji
fonts-wqy-zenhei
fonts-wqy-microhei
fonts-symbola
locales
# ═══════════════════════════════════════════════════════════════
# SECTION 13: MISCELLANEOUS
# ═══════════════════════════════════════════════════════════════

htop
iotop
neofetch
tree
unzip
p7zip-full
rsync
screen
tmux
less
man-db
manpages
info
which
strace
ltrace
pciutils
usbutils
hdparm
smartmontools
lm-sensors
thermald
tlp
bluetooth
bluez
