#!/bin/bash
# Raksha OS — ISO Build Script v2
# Builds a bootable ISO from the overlay + debootstrap
# Size: ~20-25GB (includes 8GB AI models)
# Tested on: Debian 13 Trixie (build on Debian or Bedrock)

set -euo pipefail

# ══════════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════════

ISO_NAME="raksha-os-0.1.0-amd64"
ISO_FILE="${ISO_NAME}.iso"
WORK_DIR="/tmp/raksha-iso-build"
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${REPO_DIR}/builds}"
OVERLAY_DIR="${REPO_DIR}/overlay"
MODELS_DIR="${MODELS_DIR:-${REPO_DIR}/models}"
GATEWAY_DIR="/opt/ash-core/gateways"
VOICE_DIR="${VOICE_DIR:-/opt/raksha/voice}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ══════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ══════════════════════════════════════════════════════════════

log "Raksha OS ISO Build v2 — Starting at $(date)"
log "Output: ${OUTPUT_DIR}/${ISO_FILE}"

if [ "$(id -u)" -ne 0 ]; then
    err "Must run as root (sudo)"
fi

for cmd in debootstrap xorriso mksquashfs grub-mkrescue; do
    if ! command -v "$cmd" &>/dev/null; then
        err "Missing tool: $cmd"
    fi
done

AVAIL=$(df -BG /tmp | awk 'NR==2 {print $4}' | tr -d 'G')
if [ "$AVAIL" -lt 30 ]; then
    err "Not enough disk space: ${AVAIL}GB available, need 30GB+"
fi

# ══════════════════════════════════════════════════════════════
# PREPARE WORK DIRECTORY
# ══════════════════════════════════════════════════════════════

log "Preparing work directory..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"/{rootfs,iso/boot/grub,iso/live}

# ══════════════════════════════════════════════════════════════
# BOOTSTRAP BASE SYSTEM
# ══════════════════════════════════════════════════════════════

log "Bootstrapping Debian 13 Trixie base..."
debootstrap --arch amd64 --variant=minbase --include=locales,sudo,ca-certificates,curl,wget,git,vim,nano,htop,unzip,rsync,fonts-dejavu,fonts-liberation,fonts-noto,fonts-noto-cjk,fonts-noto-color-emoji trixie "${WORK_DIR}/rootfs" http://deb.debian.org/debian

# Mount proc/sys/dev for chroot
mount --bind /proc "${WORK_DIR}/rootfs/proc"
mount --bind /sys "${WORK_DIR}/rootfs/sys"
mount --bind /dev "${WORK_DIR}/rootfs/dev"
mount --bind /dev/pts "${WORK_DIR}/rootfs/dev/pts"

# ══════════════════════════════════════════════════════════════
# CONFIGURE BASE SYSTEM
# ══════════════════════════════════════════════════════════════

log "Configuring base system..."

cp /etc/resolv.conf "${WORK_DIR}/rootfs/etc/resolv.conf"

cat > "${WORK_DIR}/rootfs/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

echo "raksha" > "${WORK_DIR}/rootfs/etc/hostname"

cat > "${WORK_DIR}/rootfs/etc/fstab" << 'EOF'
/dev/sr0 / iso9660 ro,noauto 0 0
tmpfs /tmp tmpfs defaults 0 0
tmpfs /run tmpfs defaults 0 0
EOF

# ══════════════════════════════════════════════════════════════
# INSTALL BASE PACKAGES
# ══════════════════════════════════════════════════════════════

log "Installing base packages (this takes 15-30 minutes)..."

chroot "${WORK_DIR}/rootfs" /bin/bash << 'CHROOT_EOF'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

apt-get update

# Core system
apt-get install -y     linux-image-amd64     grub-pc grub-efi-amd64     systemd systemd-sysv     dbus dbus-x11     polkitd     bash-completion     console-setup     keyboard-configuration     tzdata     dosfstools     e2fsprogs     btrfs-progs     ntfs-3g     exfat-fuse     hfsprogs     openssh-server     iproute2     iputils-ping     net-tools     network-manager     modemmanager     firmware-linux firmware-linux-nonfree firmware-misc-nonfree     intel-microcode amd64-microcode

# Desktop environment
apt-get install -y     xorg xserver-xorg-core xserver-xorg-input-libinput     nvidia-driver nvidia-cuda-toolkit plasma-desktop sddm     konsole dolphin kate     okular gwenview ksnapshot ark kcalc     firefox-esr

# Audio
apt-get install -y     pipewire pipewire-pulse wireplumber

# Python + tools
apt-get install -y     python3 python3-pip python3-venv python3-dev     python3-numpy     sqlite3     timeshift     p7zip-full     cmake build-essential     libopenblas-dev liblapack-dev     libsecret-1-0 gnome-keyring     cron     gparted     ffmpeg     vlc     libreoffice     bluez     cups     ufw     apparmor apparmor-utils apparmor-profiles     fail2ban     auditd     lm-sensors     tlp     wireguard-tools     openvpn     network-manager-openvpn     nfs-common     cifs-utils     smbclient     avahi-daemon     screen tmux     less man-db manpages info     which strace ltrace     pciutils usbutils hdparm smartmontools     thermald     nodejs npm     xdotool scrot imagemagick wmctrl x11-utils xclip     tesseract-ocr tesseract-ocr-eng

# Set root password
echo "root:raksha" | chpasswd

# Create user
useradd -m -s /bin/bash -G sudo,audio,video,plugdev,users ravan
echo "ravan:raksha" | chpasswd

# Configure sudo
echo "ravan ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ravan
chmod 440 /etc/sudoers.d/ravan

# Locale
sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale

# Timezone
ln -sf /usr/share/zoneinfo/Australia/Melbourne /etc/localtime

# Enable services (best effort — some may not exist in chroot)
systemctl enable sddm 2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable ssh 2>/dev/null || true
systemctl enable cron 2>/dev/null || true
systemctl enable timeshift 2>/dev/null || true
systemctl enable bluetooth 2>/dev/null || true
systemctl enable cups 2>/dev/null || true
systemctl enable ufw 2>/dev/null || true
systemctl enable apparmor 2>/dev/null || true
systemctl enable auditd 2>/dev/null || true
systemctl enable thermald 2>/dev/null || true
systemctl enable tlp 2>/dev/null || true

CHROOT_EOF

log "Base packages installed."

# ══════════════════════════════════════════════════════════════
# INSTALL AI MODELS (8GB)
# ══════════════════════════════════════════════════════════════

log "Installing AI models (8GB)..."

mkdir -p "${WORK_DIR}/rootfs/home/ravan/llama.cpp/models"

for model in gemma-4-E2B_q4_0-it.gguf NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf UI-TARS-2B-SFT-Q4_K_M.gguf UI-TARS-2B-SFT-mmproj-fp16.gguf; do
    if [ -f "${MODELS_DIR}/${model}" ]; then
        cp "${MODELS_DIR}/${model}" "${WORK_DIR}/rootfs/home/ravan/llama.cpp/models/"
        log "  Installed: ${model} ($(du -h "${MODELS_DIR}/${model}" | cut -f1))"
    else
        warn "  Missing: ${model}"
    fi
done

# ══════════════════════════════════════════════════════════════
# INSTALL ASH NERVOUS SYSTEM
# ══════════════════════════════════════════════════════════════

log "Installing Ash nervous system..."

# Systemd units
mkdir -p "${WORK_DIR}/rootfs/etc/systemd/system"
cp "${REPO_DIR}/systemd/"*.service "${REPO_DIR}/systemd/"*.timer "${WORK_DIR}/rootfs/etc/systemd/system/" 2>/dev/null || true

# Ash identity
mkdir -p "${WORK_DIR}/rootfs/var/lib/ash/identity"
cp "${REPO_DIR}/config/ash/SOUL.md" "${WORK_DIR}/rootfs/var/lib/ash/identity/"
cp "${REPO_DIR}/config/ash/USER.md" "${WORK_DIR}/rootfs/var/lib/ash/identity/"
cp "${REPO_DIR}/config/ash/MEMORY.md" "${WORK_DIR}/rootfs/var/lib/ash/identity/"

# .env template
cat > "${WORK_DIR}/rootfs/var/lib/ash/identity/.env" << 'EOF'
# Ash — API Keys (fill in after install)
NVIDIA_API_KEY=
NVIDIA_BASE_URL=https://integrate.api.nvidia.com/v1
NVIDIA_MODEL=nvidia/nemotron-3-ultra-550b-a55b
HONCHO_API_KEY=
HONCHO_APP_NAME=raksha-os
HONCHO_USER_ID=raksha-user
HONCHO_SESSION_ID=ash-primary
EOF
chmod 600 "${WORK_DIR}/rootfs/var/lib/ash/identity/.env"

# Memory directories
mkdir -p "${WORK_DIR}/rootfs/var/lib/ash"/{memory,knowledge,logs,tasks,creations,screenshots,skills}

# Obsidian vault
mkdir -p "${WORK_DIR}/rootfs/var/lib/raksha/obsidian/instincts/Vault/Ash_Cortex"

# Agent scripts
mkdir -p "${WORK_DIR}/rootfs/usr/local/lib/ash/tools"
cp "${REPO_DIR}/src/ash/agent-loop.py" "${WORK_DIR}/rootfs/usr/local/lib/ash/agent-loop.py" 2>/dev/null || true
cp /usr/local/lib/ash/tools/computer_use.py "${WORK_DIR}/rootfs/usr/local/lib/ash/tools/computer_use.py" 2>/dev/null || true

# Wrapper binary
cat > "${WORK_DIR}/rootfs/usr/local/bin/ash" << 'EOF'
#!/bin/bash
export ASH_HOME="${ASH_HOME:-/var/lib/ash}"
export LLAMA_URL="${LLAMA_URL:-http://127.0.0.1:8080/v1/chat/completions}"
exec python3 /usr/local/lib/ash/agent-loop.py "$@"
EOF
chmod +x "${WORK_DIR}/rootfs/usr/local/bin/ash"

# Autonomic scripts
mkdir -p "${WORK_DIR}/rootfs/opt/ash-core"
cp /opt/ash-core/reflexes/*.py "${WORK_DIR}/rootfs/opt/ash-core/reflexes/" 2>/dev/null || true

# Config
mkdir -p "${WORK_DIR}/rootfs/etc/raksha"
cp /etc/raksha/config.yaml "${WORK_DIR}/rootfs/etc/raksha/config.yaml" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
# INSTALL GATEWAYS
# ══════════════════════════════════════════════════════════════

log "Installing gateways..."

# WhatsApp gateway
if [ -d "${GATEWAY_DIR}" ]; then
    mkdir -p "${WORK_DIR}/rootfs/opt/ash-core/gateways"
    cp -a "${GATEWAY_DIR}"/* "${WORK_DIR}/rootfs/opt/ash-core/gateways/" 2>/dev/null || true
    
    # WhatsApp auth
    mkdir -p "${WORK_DIR}/rootfs/var/lib/ash/identity/whatsapp_auth"
    if [ -d /var/lib/ash/identity/whatsapp_auth ]; then
        cp -a /var/lib/ash/identity/whatsapp_auth/* "${WORK_DIR}/rootfs/var/lib/ash/identity/whatsapp_auth/" 2>/dev/null || true
    fi
    if [ -d /var/lib/ash/identity/whatsapp_baileys ]; then
        cp -a /var/lib/ash/identity/whatsapp_baileys "${WORK_DIR}/rootfs/var/lib/ash/identity/" 2>/dev/null || true
    fi
    
    # WhatsApp setup script
    cat > "${WORK_DIR}/rootfs/usr/local/bin/raksha-whatsapp-setup" << 'WSEOF'
#!/bin/bash
echo "🜂 Raksha OS — WhatsApp Gateway Setup"
echo ""
echo "1. Open WhatsApp on your phone"
echo "2. Go to Settings → Linked Devices → Link a Device"
echo "3. Scan the QR code that will appear"
echo ""
read -p "Press Enter to start..." 
node /opt/ash-core/gateways/whatsapp-gateway.js &
echo "Gateway started. Scan QR code in your terminal."
echo "Press Enter when done..."
read
WSEOF
    chmod +x "${WORK_DIR}/rootfs/usr/local/bin/raksha-whatsapp-setup"
    log "  WhatsApp gateway installed"
fi

# Telegram gateway
if [ -f "${GATEWAY_DIR}/telegram-gateway.py" ]; then
    cp "${GATEWAY_DIR}/telegram-gateway.py" "${WORK_DIR}/rootfs/opt/ash-core/gateways/"
    cat > "${WORK_DIR}/rootfs/usr/local/bin/raksha-telegram-setup" << 'TSEOF'
#!/bin/bash
echo "🜂 Raksha OS — Telegram Gateway Setup"
echo ""
echo "1. Open Telegram and search for @BotFather"
echo "2. Send /newbot and follow instructions"
echo "3. Copy the bot token"
echo ""
read -p "Paste your Telegram bot token: " TOKEN
sed -i "s/BOT_TOKEN=.*/BOT_TOKEN=${TOKEN}/" /etc/systemd/system/ash-telegram.service
systemctl daemon-reload
echo "Telegram gateway configured!"
TSEOF
    chmod +x "${WORK_DIR}/rootfs/usr/local/bin/raksha-telegram-setup"
    log "  Telegram gateway installed"
fi

# Voice models
if [ -d "${VOICE_DIR}" ]; then
    mkdir -p "${WORK_DIR}/rootfs/home/ravan/raksha-vocie"
    for voice in en_US-ryan-high.onnx en_US-amy-medium.onnx; do
        if [ -f "${VOICE_DIR}/${voice}" ]; then
            cp "${VOICE_DIR}/${voice}" "${WORK_DIR}/rootfs/home/ravan/raksha-vocie/"
            log "  Voice model: ${voice} ($(du -h "${VOICE_DIR}/${voice}" | cut -f1))"
        fi
    done
    # Piper binary
    if [ -f "${VOICE_DIR}/piper" ]; then
        cp "${VOICE_DIR}/piper" "${WORK_DIR}/rootfs/home/ravan/raksha-vocie/"
    fi
    log "  Voice models installed"
fi

# ══════════════════════════════════════════════════════════════
# INSTALL RAKSHA TOOLS (Helayidaya, Dashboard, Firstboot)
# ══════════════════════════════════════════════════════════════

log "Installing Raksha tools..."

# Helayidaya (self-check utility)
if [ -d "/opt/ash-core/helayidaya" ]; then
    mkdir -p "${WORK_DIR}/rootfs/opt/ash-core/helayidaya"
    cp /opt/ash-core/helayidaya/helayidaya.py "${WORK_DIR}/rootfs/usr/local/bin/helayidaya"
    chmod +x "${WORK_DIR}/rootfs/usr/local/bin/helayidaya"
    mkdir -p "${WORK_DIR}/rootfs/var/lib/helayidaya"/{reports,snapshots}
    log "  ✅ Helayidaya installed"
fi

# First-boot setup script
if [ -f "/opt/ash-core/raksha-firstboot.sh" ]; then
    cp /opt/ash-core/raksha-firstboot.sh "${WORK_DIR}/rootfs/usr/local/bin/raksha-firstboot.sh"
    chmod +x "${WORK_DIR}/rootfs/usr/local/bin/raksha-firstboot.sh"
    log "  ✅ First-boot script installed"
fi

# First-boot systemd service
cat > "${WORK_DIR}/rootfs/etc/systemd/system/raksha-firstboot.service" << 'EOF'
[Unit]
Description=Raksha OS — First Boot Setup (Ash Awakening)
After=multi-user.target network-online.target
Wants=network-online.target
ConditionPathExists=!/var/lib/raksha/.firstboot-complete

[Service]
Type=oneshot
ExecStart=/usr/local/bin/raksha-firstboot.sh
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
EOF
systemctl enable raksha-firstboot.service 2>/dev/null || true
log "  ✅ First-boot service enabled"

# Raksha Dashboard
if [ -d "${REPO_DIR}/raksha-dashboard" ]; then
    mkdir -p "${WORK_DIR}/rootfs/opt/raksha-dashboard"
    cp -a "${REPO_DIR}/raksha-dashboard"/* "${WORK_DIR}/rootfs/opt/raksha-dashboard/"
    if [ -f "${REPO_DIR}/raksha-dashboard/requirements.txt" ]; then
        chroot "${WORK_DIR}/rootfs" pip3 install -r /opt/raksha-dashboard/requirements.txt 2>/dev/null || true
    fi
    if [ -f "${REPO_DIR}/raksha-dashboard/raksha-dashboard.service" ]; then
        cp "${REPO_DIR}/raksha-dashboard/raksha-dashboard.service" \
           "${WORK_DIR}/rootfs/etc/systemd/system/"
        systemctl enable raksha-dashboard.service 2>/dev/null || true
        log "  ✅ Dashboard installed + enabled"
    fi
fi

# ══════════════════════════════════════════════════════════════
# ENABLE ASH SERVICES
# ══════════════════════════════════════════════════════════════

log "Enabling Ash services..."

for svc in llama-server.service ash-core.timer ash-heartbeat.timer \
           ash-dreaming.timer ash-memory.timer ash-defibrillator.service \
           ash-interface.service; do
    if [ -f "${WORK_DIR}/rootfs/etc/systemd/system/$svc" ]; then
        systemctl --root="${WORK_DIR}/rootfs" enable "$svc" 2>/dev/null || true
        log "  ✅ Enabled: $svc"
    else
        log "  ⚠️  Not found: $svc"
    fi
done

# ══════════════════════════════════════════════════════════════
# LIVE USER AUTO-LOGIN (SDDM)
# ══════════════════════════════════════════════════════════════

log "Configuring auto-login for live boot..."

# Ensure SDDM config exists with auto-login
mkdir -p "${WORK_DIR}/rootfs/etc/sddm.conf.d"
cat > "${WORK_DIR}/rootfs/etc/sddm.conf.d/raksha-autologin.conf" << 'EOF'
[Autologin]
User=ravan
Session=plasma.desktop
Relogin=false

[General]
DisplayServer=x11
EOF

# Ensure skel has config directory
mkdir -p "${WORK_DIR}/rootfs/etc/skel/.config"
mkdir -p "${WORK_DIR}/rootfs/etc/skel/.local/bin"

log "  ✅ Auto-login configured (ravan → Plasma)"

# ══════════════════════════════════════════════════════════════
# INSTALL OVERLAY
# ══════════════════════════════════════════════════════════════

log "Applying overlay..."

cp -a "${OVERLAY_DIR}/"* "${WORK_DIR}/rootfs/"

# Set ownership
chown -R ravan:ravan "${WORK_DIR}/rootfs/var/lib/ash" 2>/dev/null || true
chown -R ravan:ravan "${WORK_DIR}/rootfs/var/lib/raksha" 2>/dev/null || true
chown -R ravan:ravan "${WORK_DIR}/rootfs/home/ravan" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════
# BUILD SQUASHFS
# ══════════════════════════════════════════════════════════════

log "Building squashfs (this takes 10-20 minutes)..."

# Unmount
umount "${WORK_DIR}/rootfs/proc" 2>/dev/null || true
umount "${WORK_DIR}/rootfs/sys" 2>/dev/null || true
umount "${WORK_DIR}/rootfs/dev/pts" 2>/dev/null || true
umount "${WORK_DIR}/rootfs/dev" 2>/dev/null || true

# Clean up
rm -rf "${WORK_DIR}/rootfs/tmp/"*
rm -rf "${WORK_DIR}/rootfs/var/cache/apt/"*
rm -rf "${WORK_DIR}/rootfs/var/lib/apt/lists/"*

# Build
mkdir -p "${WORK_DIR}/iso/live"
mksquashfs "${WORK_DIR}/rootfs" "${WORK_DIR}/iso/live/filesystem.squashfs"     -comp xz -b 1M -Xdict-size 100% -no-recovery

SQUASH_SIZE=$(du -sh "${WORK_DIR}/iso/live/filesystem.squashfs" | cut -f1)
log "Squashfs built: ${SQUASH_SIZE}"

# ══════════════════════════════════════════════════════════════
# BUILD ISO
# ══════════════════════════════════════════════════════════════

log "Building ISO..."

# Copy kernel and initrd
cp "${WORK_DIR}/rootfs/boot/vmlinuz-"* "${WORK_DIR}/iso/boot/vmlinuz"
cp "${WORK_DIR}/rootfs/boot/initrd.img-"* "${WORK_DIR}/iso/boot/initrd"

# GRUB config
cat > "${WORK_DIR}/iso/boot/grub/grub.cfg" << 'EOF'
set timeout=10
set default=0

menuentry "Raksha OS (Ash Awakening)" {
    linux /boot/vmlinuz boot=live components quiet splash
    initrd /boot/initrd
}

menuentry "Raksha OS (Debug Mode)" {
    linux /boot/vmlinuz boot=live components debug
    initrd /boot/initrd
}

menuentry "Raksha OS (Text Mode)" {
    linux /boot/vmlinuz boot=live components nomodeset text
    initrd /boot/initrd
}
EOF

# Build ISO
mkdir -p "${OUTPUT_DIR}"
grub-mkrescue -o "${OUTPUT_DIR}/${ISO_FILE}" "${WORK_DIR}/iso"     --fonts="" --locales="" --themes="" 2>/dev/null

# ══════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════

ISO_SIZE=$(du -sh "${OUTPUT_DIR}/${ISO_FILE}" | cut -f1)
log "══════════════════════════════════════════════════════════════"
log "Raksha OS ISO Build Complete!"
log "File: ${OUTPUT_DIR}/${ISO_FILE}"
log "Size: ${ISO_SIZE}"
log ""
log "To write to USB:"
log "  sudo dd if=${OUTPUT_DIR}/${ISO_FILE} of=/dev/sdX bs=4M status=progress"
log ""
log "To test in QEMU:"
log "  qemu-system-x86_64 -m 4G -cdrom ${OUTPUT_DIR}/${ISO_FILE} -boot d"
log "══════════════════════════════════════════════════════════════"
