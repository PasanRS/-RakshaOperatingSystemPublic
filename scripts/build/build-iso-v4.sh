#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# Raksha OS — ISO Build Script v4 (FINAL)
# Fixes all known Bedrock Linux build issues:
#   ✓ WORK_DIR respects env var, defaults to /home/ravan/raksha-build
#   ✓ USER_HOME hardcoded to /home/ravan (sudo sets $HOME=/root)
#   ✓ Kernel downloaded outside chroot (Bedrock chroot kernel install fails)
#   ✓ Uses find instead of glob for vmlinuz (glob fails on Bedrock)
#   ✓ xorriso -iso-level 3 wrapper (bypasses 4GB file size limit)
#   ✓ All venvs pre-built inside rootfs (no internet at install time)
#   ✓ All 1500+ skills, models, voice bundled into squashfs
#
# Usage: sudo bash build-iso-v4.sh
# Time:  45-90 minutes
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════
# CONFIGURATION
# ══════════════════════════════════════════════════════════════════════

ISO_NAME="raksha-os-1.0.0-amd64"
ISO_FILE="${ISO_NAME}.iso"
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${REPO_DIR}/builds"
WORK_DIR="${WORK_DIR:-/home/ravan/raksha-build}"
OVERLAY_DIR="${REPO_DIR}/overlay"

# Asset paths — always /home/ravan, never $HOME (which is /root under sudo)
USER_HOME="/home/ravan"
MODELS_DIR="${USER_HOME}/llama.cpp/models"
VOICE_DIR="${USER_HOME}/raksha-vocie"
SKILLS_DIR="/opt/ash-core/skills/skills"
AGY_SKILLS_DIR="${USER_HOME}/.gemini/antigravity-cli/skills"
SKILL_INDEX="/var/lib/ash/skills/skill_index.json"
KNOWLEDGE_DIR="/var/lib/ash/knowledge"
LLAMA_BIN="${USER_HOME}/llama.cpp/build/bin/llama-server"
HELAYIDAYA_BIN="/opt/ash-core/helayidaya/helayidaya.py"

MODELS_INCLUDE=(
  "gemma-4-E2B_q4_0-it.gguf"
  "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf"
  "UI-TARS-2B-SFT-Q4_K_M.gguf"
  "UI-TARS-2B-SFT-mmproj-fp16.gguf"
)

VOICE_MODELS_INCLUDE=(
  "en_US-ryan-high.onnx"
  "en_US-ryan-high.onnx.json"
  "en_US-amy-medium.onnx"
  "en_US-amy-medium.onnx.json"
)

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()     { echo -e "${GREEN}[BUILD]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()     { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"; \
            echo -e "${CYAN}  $1${NC}"; \
            echo -e "${CYAN}══════════════════════════════════════════════════${NC}"; }

# ══════════════════════════════════════════════════════════════════════
# PRE-FLIGHT
# ══════════════════════════════════════════════════════════════════════
section "Raksha OS ISO Build v4 — $(date)"
[ "$(id -u)" -ne 0 ] && err "Run as root: sudo bash $0"

for cmd in debootstrap xorriso mksquashfs grub-mkrescue mkinitramfs; do
  command -v "$cmd" &>/dev/null || err "Missing: $cmd  →  apt install $cmd"
done

log "Repo    : ${REPO_DIR}"
log "Work    : ${WORK_DIR}"
log "Output  : ${OUTPUT_DIR}/${ISO_FILE}"

[ -d "${MODELS_DIR}" ]    || warn "Models dir not found: ${MODELS_DIR}"
[ -d "${VOICE_DIR}" ]     || warn "Voice dir not found: ${VOICE_DIR}"
[ -f "${LLAMA_BIN}" ]     || warn "llama-server not found: ${LLAMA_BIN}"
[ -d "${SKILLS_DIR}" ]    || warn "Skills not found: ${SKILLS_DIR}"

# xorriso wrapper — injects -iso-level 3 to bypass 4GB ISO file size limit
XORRISO_WRAPPER="/tmp/xorriso-raksha-$$"
cat > "${XORRISO_WRAPPER}" << 'WRAPPER_EOF'
#!/bin/bash
ARGS=()
for arg in "$@"; do
    ARGS+=("$arg")
    [ "$arg" = "mkisofs" ] && ARGS+=("-iso-level" "3")
done
exec /usr/bin/xorriso "${ARGS[@]}"
WRAPPER_EOF
chmod +x "${XORRISO_WRAPPER}"
log "xorriso iso-level-3 wrapper created"

# ══════════════════════════════════════════════════════════════════════
# STAGE 0: Download kernel .deb OUTSIDE chroot (Bedrock Linux fix)
# ══════════════════════════════════════════════════════════════════════
section "Stage 0: Pre-downloading kernel (Bedrock Linux fix)"

KERNEL_TMPDIR="${WORK_DIR}-kernel"
mkdir -p "${KERNEL_TMPDIR}/extract"

# Resolve the real kernel package name from the meta-package
KERNEL_PKG=$(apt-cache depends linux-image-amd64 2>/dev/null \
    | grep 'Depends:' | awk '{print $2}' | head -1)
[ -z "${KERNEL_PKG}" ] && KERNEL_PKG="linux-image-6.12.95+deb13-amd64"
log "Kernel package: ${KERNEL_PKG}"

# Download only if not already cached
KERNEL_DEB=$(find "${KERNEL_TMPDIR}" -name "linux-image-*.deb" \
    ! -name "linux-image-amd64*" 2>/dev/null | head -1)
if [ -z "${KERNEL_DEB}" ]; then
  log "Downloading ${KERNEL_PKG} (~108MB)..."
  cd "${KERNEL_TMPDIR}"
  apt-get download "${KERNEL_PKG}" 2>&1 | tail -3
  KERNEL_DEB=$(find "${KERNEL_TMPDIR}" -name "linux-image-*.deb" \
      ! -name "linux-image-amd64*" | head -1)
  cd -
fi
log "  .deb: $(basename ${KERNEL_DEB}) ($(du -sh ${KERNEL_DEB} | cut -f1))"

# Extract vmlinuz
log "Extracting vmlinuz..."
rm -rf "${KERNEL_TMPDIR}/extract"
mkdir -p "${KERNEL_TMPDIR}/extract"
dpkg-deb -x "${KERNEL_DEB}" "${KERNEL_TMPDIR}/extract"
VMLINUZ_SRC=$(find "${KERNEL_TMPDIR}/extract/boot" -name "vmlinuz-*" | head -1)
[ -z "${VMLINUZ_SRC}" ] && err "vmlinuz not found in ${KERNEL_DEB}"
KVER=$(basename "${VMLINUZ_SRC}" | sed 's/vmlinuz-//')
log "  vmlinuz: $(basename ${VMLINUZ_SRC})"
log "  kernel version: ${KVER}"

# ══════════════════════════════════════════════════════════════════════
# PREPARE WORK DIRECTORY
# ══════════════════════════════════════════════════════════════════════
section "Preparing work directory"

if [ -d "${WORK_DIR}" ]; then
  for mnt in proc sys dev/pts dev; do
    umount -l "${WORK_DIR}/rootfs/${mnt}" 2>/dev/null || true
  done
  rm -rf "${WORK_DIR}"
fi
mkdir -p "${WORK_DIR}"/{rootfs,iso/boot/grub,iso/live}
mkdir -p "${OUTPUT_DIR}"
log "Work directory ready"

# ══════════════════════════════════════════════════════════════════════
# STAGE 1: Bootstrap Debian base
# ══════════════════════════════════════════════════════════════════════
section "Stage 1: Bootstrapping Debian 13 Trixie"

debootstrap \
  --arch amd64 --variant=minbase \
  --include=locales,sudo,ca-certificates,curl,wget,git,vim,nano,htop,unzip,rsync,\
fonts-dejavu,fonts-liberation,fonts-noto,fonts-noto-cjk,fonts-noto-color-emoji \
  trixie "${WORK_DIR}/rootfs" http://deb.debian.org/debian
log "Base bootstrapped"

mount --bind /proc    "${WORK_DIR}/rootfs/proc"
mount --bind /sys     "${WORK_DIR}/rootfs/sys"
mount --bind /dev     "${WORK_DIR}/rootfs/dev"
mount --bind /dev/pts "${WORK_DIR}/rootfs/dev/pts"
cp /etc/resolv.conf   "${WORK_DIR}/rootfs/etc/resolv.conf"

cat > "${WORK_DIR}/rootfs/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

echo "raksha" > "${WORK_DIR}/rootfs/etc/hostname"
cat > "${WORK_DIR}/rootfs/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   raksha
::1         localhost ip6-localhost ip6-loopback
EOF

# ══════════════════════════════════════════════════════════════════════
# STAGE 2: Install packages
# (Note: linux-image is NOT installed here — installed via pre-downloaded .deb)
# ══════════════════════════════════════════════════════════════════════
section "Stage 2: Installing packages (30-45 min)"

chroot "${WORK_DIR}/rootfs" /bin/bash << 'CHROOT_PACKAGES'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get update -qq

# Core system (NO linux-image here — installed from pre-downloaded .deb below)
apt-get install -y \
  grub-pc grub-efi-amd64 grub-efi-amd64-bin \
  systemd systemd-sysv systemd-resolved \
  dbus dbus-x11 polkitd \
  bash-completion console-setup keyboard-configuration \
  tzdata dosfstools e2fsprogs btrfs-progs ntfs-3g \
  openssh-server iproute2 iputils-ping net-tools \
  network-manager modemmanager \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-realtek firmware-atheros \
  intel-microcode amd64-microcode \
  live-boot live-boot-initramfs-tools live-config live-config-systemd \
  initramfs-tools plymouth plymouth-themes \
  calamares calamares-settings-debian \
  2>&1 | grep -E "^(Get|Inst|Err|Setting)" || true

# EFI GRUB is a hard requirement for the installed target. This separate,
# unfiltered transaction prevents the package-log pipeline above from hiding
# a failed install and producing an ISO that reaches Calamares but cannot boot.
if ! apt-get install -y \
  grub-common grub2-common grub-efi-amd64 grub-efi-amd64-bin efibootmgr; then
  echo "Fatal: target EFI GRUB packages could not be installed" >&2
  exit 1
fi
for executable in \
  /usr/sbin/grub-install /usr/sbin/grub-mkconfig /usr/sbin/grub-probe \
  /usr/bin/efibootmgr; do
  test -x "${executable}" || { echo "Fatal: missing ${executable}" >&2; exit 1; }
done
test -f /usr/lib/grub/x86_64-efi/modinfo.sh
test -f /usr/lib/grub/x86_64-efi/normal.mod
test -f /usr/lib/grub/x86_64-efi/linux.mod
! ldd /usr/sbin/grub-install | grep -q 'not found'

# Exercise the installed target's EFI writer without requiring host firmware
# variables. The real Calamares run uses the mounted ESP and firmware NVRAM.
rm -rf /tmp/raksha-grub-smoke
mkdir -p /tmp/raksha-grub-smoke/efi /tmp/raksha-grub-smoke/boot
env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  /usr/sbin/grub-install --target=x86_64-efi \
    --efi-directory=/tmp/raksha-grub-smoke/efi \
    --boot-directory=/tmp/raksha-grub-smoke/boot \
    --bootloader-id=Raksha_OS --force --no-nvram --removable
test -s /tmp/raksha-grub-smoke/efi/EFI/BOOT/BOOTX64.EFI
rm -rf /tmp/raksha-grub-smoke
echo "[PASS] target chroot x86_64-efi grub-install smoke test"

# Desktop
apt-get install -y \
  xorg xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-all \
  plasma-desktop plasma-workspace sddm kwin-x11 \
  konsole dolphin kate okular gwenview ark kcalc kscreen \
  plasma-nm plasma-pa kinfocenter firefox-esr \
  2>&1 | grep -E "^(Get|Inst|Err|Setting)" || true

# Audio
apt-get install -y \
  pipewire pipewire-pulse pipewire-alsa wireplumber alsa-utils \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

# Python
apt-get install -y \
  python3 python3-pip python3-venv python3-dev python3-wheel \
  python3-numpy python3-requests python3-aiohttp \
  sqlite3 libsqlite3-dev \
  build-essential cmake pkg-config \
  libopenblas-dev libffi-dev libssl-dev \
  portaudio19-dev libsndfile1 libasound2-dev \
  espeak-ng espeak-ng-data \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

# Runtime
apt-get install -y \
  nodejs npm chromium \
  timeshift p7zip-full gparted ffmpeg vlc \
  bluez cups ufw apparmor apparmor-utils fail2ban auditd \
  lm-sensors tlp thermald wireguard-tools openvpn \
  avahi-daemon screen tmux less man-db \
  pciutils usbutils hdparm smartmontools \
  xdotool scrot imagemagick wmctrl x11-utils xclip xdg-utils \
  tesseract-ocr tesseract-ocr-eng libnotify-bin \
  fastfetch neofetch \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

# Try NVIDIA
apt-get install -y nvidia-driver 2>/dev/null || true

echo "Packages done."
CHROOT_PACKAGES

log "Packages installed"

# ── Install kernel from pre-downloaded .deb (bypasses Bedrock chroot issue) ──
section "Stage 2b: Installing kernel from pre-downloaded .deb"

R="${WORK_DIR}/rootfs"

# Copy .deb into rootfs and install without running post-install scripts
# (dpkg-deb -x extracts files only, no scripts)
dpkg-deb -x "${KERNEL_DEB}" "${R}"
log "  Kernel files extracted into rootfs"

# Also copy kernel module files
find "${KERNEL_TMPDIR}/extract/lib" -maxdepth 0 -type d 2>/dev/null && \
  cp -r "${KERNEL_TMPDIR}/extract/lib/modules" "${R}/lib/" 2>/dev/null || true

# Verify
VMLINUZ_IN_ROOTFS=$(find "${R}/boot" -name "vmlinuz-*" | head -1)
if [ -n "${VMLINUZ_IN_ROOTFS}" ]; then
  log "  ✓ vmlinuz in rootfs: $(basename ${VMLINUZ_IN_ROOTFS})"
else
  warn "  vmlinuz not in rootfs (will use pre-downloaded copy for ISO boot)"
fi

log "Kernel installed"

# ══════════════════════════════════════════════════════════════════════
# STAGE 3: System configuration
# ══════════════════════════════════════════════════════════════════════
section "Stage 3: System configuration"

chroot "${WORK_DIR}/rootfs" /bin/bash << 'CHROOT_CONFIG'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale
ln -sf /usr/share/zoneinfo/Australia/Melbourne /etc/localtime
echo "Australia/Melbourne" > /etc/timezone

echo "root:raksha" | chpasswd
useradd -m -s /bin/bash -G sudo,audio,video,plugdev,users,input ravan 2>/dev/null || true
echo "ravan:raksha" | chpasswd
echo "ravan ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ravan
chmod 440 /etc/sudoers.d/ravan

mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << 'SDDM'
[Autologin]
User=ravan
Session=raksha.desktop
Relogin=false

[General]
DisplayServer=x11
SDDM

systemctl enable sddm          2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable ssh           2>/dev/null || true
systemctl enable cups          2>/dev/null || true
systemctl enable bluetooth     2>/dev/null || true
systemctl enable ufw           2>/dev/null || true
systemctl enable thermald      2>/dev/null || true
systemctl enable tlp           2>/dev/null || true

echo "System configured."
CHROOT_CONFIG

log "System configured"

# ══════════════════════════════════════════════════════════════════════
# STAGE 4: OS Identity (Raksha OS branding — not Debian)
# ══════════════════════════════════════════════════════════════════════
section "Stage 4: Raksha OS identity"

R="${WORK_DIR}/rootfs"

# Primary identity file (read by KDE, fastfetch, neofetch, lsb_release, etc.)
cat > "${R}/etc/os-release" << 'EOF'
NAME="Raksha OS"
VERSION="1.0.0"
ID=raksha
ID_LIKE=debian
PRETTY_NAME="Raksha OS 1.0.0"
VERSION_ID="1.0.0"
VERSION_CODENAME="awakening"
HOME_URL="https://github.com/PasanRS/Raksha-OS-Core"
SUPPORT_URL="https://github.com/PasanRS/Raksha-OS-Core/issues"
BUG_REPORT_URL="https://github.com/PasanRS/Raksha-OS-Core/issues"
LOGO="raksha-logo"
EOF
install -m 0644 "${R}/etc/os-release" "${R}/usr/lib/os-release"
rm -f "${R}/etc/os-release"
ln -s ../usr/lib/os-release "${R}/etc/os-release"

cat > "${R}/etc/lsb-release" << 'EOF'
DISTRIB_ID=RakshaOS
DISTRIB_RELEASE=1.0.0
DISTRIB_CODENAME=awakening
DISTRIB_DESCRIPTION="Raksha OS 1.0.0"
EOF

# Keep /etc/debian_version for compatibility but relabel it
echo "raksha-1.0.0 (trixie-based)" > "${R}/etc/debian_version"

# TTY login prompt
printf 'Raksha OS 1.0.0 \\n \\l\n\n' > "${R}/etc/issue"
printf 'Raksha OS 1.0.0\nAsh — Native Cognitive Entity\n' > "${R}/etc/issue.net"

# MOTD with Raksha ASCII logo
cat > "${R}/etc/motd" << 'EOF'

██████╗  █████╗ ██╗  ██╗███████╗██╗  ██╗ █████╗ 
██╔══██╗██╔══██╗██║ ██╔╝██╔════╝██║  ██║██╔══██╗
██████╔╝███████║█████╔╝ ███████╗███████║███████║
██╔══██╗██╔══██║██╔═██╗ ╚════██║██╔══██║██╔══██║
██║  ██║██║  ██║██║  ██╗███████║██║  ██║██║  ██║
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝

          R A K S H A   O S   1 . 0 . 0
    ────────────────────────────────────────
    Dashboard  :  http://localhost:8889
    Voice UI   :  http://localhost:8888
    Hotkey     :  Ctrl+Shift+Space
    ────────────────────────────────────────

EOF

# fastfetch config (shows Raksha logo + system info on terminal open)
mkdir -p "${R}/etc/skel/.config/fastfetch"
cat > "${R}/etc/skel/.config/fastfetch/config.jsonc" << 'EOF'
{
    "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
    "logo": {
        "type": "file",
        "source": "/etc/raksha/logo.txt",
        "color": { "1": "green", "2": "bright_green" }
    },
    "display": { "separator": "  →  ", "color": { "keys": "bright_green" } },
    "modules": [
        { "type": "title",    "format": "{user-name}@{host-name}" },
        "separator",
        { "type": "os",       "key": "OS",         "format": "{pretty-name}" },
        { "type": "kernel",   "key": "Kernel" },
        { "type": "uptime",   "key": "Uptime" },
        { "type": "shell",    "key": "Shell" },
        { "type": "de",       "key": "DE" },
        { "type": "cpu",      "key": "CPU" },
        { "type": "gpu",      "key": "GPU",        "detectionMethod": "pci" },
        { "type": "memory",   "key": "Memory" },
        { "type": "disk",     "key": "Disk" },
        "break",
        { "type": "custom",   "format": "  Ash Voice  →  http://localhost:8888",    "key": "" },
        { "type": "custom",   "format": "  Harness    →  http://localhost:8890",    "key": "" },
        { "type": "custom",   "format": "  Dashboard  →  http://localhost:8889",    "key": "" },
        "break",
        "colors"
    ]
}
EOF
mkdir -p "${R}/etc/raksha"
cat > "${R}/etc/raksha/logo.txt" << 'EOF'
██████╗  █████╗ ██╗  ██╗███████╗██╗  ██╗ █████╗ 
██╔══██╗██╔══██╗██║ ██╔╝██╔════╝██║  ██║██╔══██╗
██████╔╝███████║█████╔╝ ███████╗███████║███████║
██╔══██╗██╔══██║██╔═██╗ ╚════██║██╔══██║██╔══██║
██║  ██║██║  ██║██║  ██╗███████║██║  ██║██║  ██║
╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝
  R A K S H A   O S   1 . 0 . 0
EOF

# Show fastfetch on interactive terminal login
cat >> "${R}/etc/skel/.bashrc" << 'EOF'

# Raksha OS — show system info on login
if [[ $- == *i* ]] && [[ -z "$RAKSHA_SHOWN" ]]; then
    export RAKSHA_SHOWN=1
    command -v fastfetch &>/dev/null && fastfetch 2>/dev/null || true
fi
EOF

# Login shell env
cat > "${R}/etc/profile.d/raksha.sh" << 'EOF'
#!/bin/bash
export ASH_HOME=/var/lib/ash
export HARNESS_URL=http://127.0.0.1:8890
export LLAMA_URL=http://127.0.0.1:8080/v1/chat/completions
export VOICE_BASE=/opt/ash-core/voice
export PATH="${HOME}/.local/bin:${HOME}/bin:/usr/local/bin:${PATH}"

if [ -f "${ASH_HOME}/identity/.env" ]; then
    set -a; source "${ASH_HOME}/identity/.env" 2>/dev/null || true; set +a
fi

alias ash-log='tail -f /var/lib/ash/logs/ash.log'
alias ash-harness='curl -s http://localhost:8890/health | python3 -m json.tool'
alias ash-dashboard='xdg-open http://localhost:8889 2>/dev/null || echo "http://localhost:8889"'
alias ash-voice='xdg-open http://localhost:8888 2>/dev/null || echo "http://localhost:8888"'
EOF

log "Identity files set — system will identify as Raksha OS"

# ══════════════════════════════════════════════════════════════════════
# STAGE 5: Ash core files
# ══════════════════════════════════════════════════════════════════════
section "Stage 5: Staging Ash source files"

R="${WORK_DIR}/rootfs"
mkdir -p \
  "${R}/opt/ash-core/harness" \
  "${R}/opt/ash-core/voice/piper" \
  "${R}/opt/ash-core/reflexes" \
  "${R}/opt/ash-core/gateways/ash-whatsapp-bridge" \
  "${R}/opt/ash-core/helayidaya" \
  "${R}/opt/ash-core/tools" \
  "${R}/opt/raksha-dashboard" \
  "${R}/usr/local/lib/ash/tools" \
  "${R}/usr/local/bin" \
  "${R}/var/lib/ash/identity" \
  "${R}/var/lib/ash/memory" \
  "${R}/var/lib/ash/logs" \
  "${R}/var/lib/ash/knowledge" \
  "${R}/var/lib/ash/tasks" \
  "${R}/var/lib/ash/skills" \
  "${R}/var/lib/ash/creations" \
  "${R}/var/lib/ash/screenshots" \
  "${R}/var/lib/raksha"

cp "${REPO_DIR}/src/ash/agent-loop.py"       "${R}/usr/local/lib/ash/"
cp "${REPO_DIR}/src/ash/ash"                 "${R}/usr/local/bin/ash"
cp "${REPO_DIR}/src/ash/ash-heartbeat"       "${R}/usr/local/bin/ash-heartbeat"  2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-memory"          "${R}/usr/local/bin/ash-memory"     2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-status"          "${R}/usr/local/bin/ash-status"     2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-talk"            "${R}/usr/local/bin/ash-talk"       2>/dev/null || true
chmod +x "${R}/usr/local/bin/ash" 2>/dev/null || true

cp "${REPO_DIR}/src/reflexes/heartbeat.py"     "${R}/opt/ash-core/reflexes/"
cp "${REPO_DIR}/src/reflexes/dreaming.py"      "${R}/opt/ash-core/reflexes/"
cp "${REPO_DIR}/src/reflexes/defibrillator.sh" "${R}/opt/ash-core/reflexes/"
chmod +x "${R}/opt/ash-core/reflexes/defibrillator.sh"

cp "${REPO_DIR}/src/harness/harness.py"        "${R}/opt/ash-core/harness/"
cp "${REPO_DIR}/src/harness/harness_client.py" "${R}/opt/ash-core/harness/" 2>/dev/null || true
cp "${REPO_DIR}/src/dashboard/main.py"         "${R}/opt/raksha-dashboard/"
cp "${REPO_DIR}/src/interface/server.py"       "${R}/opt/ash-core/voice/"
if [ -f /home/ravan/ash-interface/static/index.html ]; then
  mkdir -p "${R}/opt/ash-core/voice/static"
  cp -a /home/ravan/ash-interface/static/. "${R}/opt/ash-core/voice/static/"
else
  err "Voice interface UI assets missing: /home/ravan/ash-interface/static"
fi

if [ -d "${REPO_DIR}/src/gateways" ]; then
  cp "${REPO_DIR}/src/gateways/"*.py  "${R}/opt/ash-core/gateways/" 2>/dev/null || true
  cp "${REPO_DIR}/src/gateways/"*.js  "${R}/opt/ash-core/gateways/" 2>/dev/null || true
  cp "${REPO_DIR}/src/gateways/package.json" "${R}/opt/ash-core/gateways/" 2>/dev/null || true
  [ -d "${REPO_DIR}/src/gateways/ash-whatsapp-bridge" ] && \
    cp -r "${REPO_DIR}/src/gateways/ash-whatsapp-bridge/"* \
          "${R}/opt/ash-core/gateways/ash-whatsapp-bridge/" 2>/dev/null || true
fi

[ -f "${HELAYIDAYA_BIN}" ] && cp "${HELAYIDAYA_BIN}" "${R}/opt/ash-core/helayidaya/" || true

cp "${REPO_DIR}/config/ash/SOUL.md"   "${R}/var/lib/ash/identity/"
cp "${REPO_DIR}/config/ash/USER.md"   "${R}/var/lib/ash/identity/"
cp "${REPO_DIR}/config/ash/MEMORY.md" "${R}/var/lib/ash/memory/" 2>/dev/null || true

cat > "${R}/var/lib/ash/identity/.env" << 'ENV_EOF'
LLAMA_URL=http://127.0.0.1:8080/v1/chat/completions
ASH_MODEL=gemma-4-E2B_q4_0-it
HARNESS_URL=http://127.0.0.1:8890
NVIDIA_API_KEY=
NVIDIA_BASE_URL=https://integrate.api.nvidia.com/v1
NVIDIA_MODEL=nvidia/nemotron-3-ultra-550b-a55b
VOICE_BASE=/opt/ash-core/voice
ASH_VOICE_PORT=8888
ASH_HOME=/var/lib/ash
ENV_EOF
chmod 600 "${R}/var/lib/ash/identity/.env"

cp "${REPO_DIR}/scripts/raksha-firstboot.sh" "${R}/usr/local/bin/raksha-firstboot"
chmod +x "${R}/usr/local/bin/raksha-firstboot"

cat > "${R}/usr/local/bin/helayidaya" << 'HEOF'
#!/bin/bash
exec python3 /opt/ash-core/helayidaya/helayidaya.py "$@"
HEOF
chmod +x "${R}/usr/local/bin/helayidaya"

cat > "${R}/usr/local/bin/raksha-whatsapp-setup" << 'WSEOF'
#!/bin/bash
echo "🜂 Raksha OS — WhatsApp Gateway Setup"
read -p "Press Enter to generate QR code..."
cd /opt/ash-core/gateways && node whatsapp-gateway.js &
GW_PID=$!; sleep 5
echo "Scan the QR code above, then press Enter..."
read; kill $GW_PID 2>/dev/null
echo "✓ WhatsApp configured!"
WSEOF
chmod +x "${R}/usr/local/bin/raksha-whatsapp-setup"
install -m 0755 "${REPO_DIR}/scripts/raksha-whatsapp-setup.sh" \
  "${R}/usr/local/bin/raksha-whatsapp-setup"

log "Ash files staged"

# ══════════════════════════════════════════════════════════════════════
# STAGE 6: Large assets (models, skills, voice)
# ══════════════════════════════════════════════════════════════════════
section "Stage 6: Copying assets (models, skills, voice)"

R="${WORK_DIR}/rootfs"
mkdir -p "${R}/home/ravan/llama.cpp/models"

for model in "${MODELS_INCLUDE[@]}"; do
  [ -f "${MODELS_DIR}/${model}" ] && \
    { log "  Model: ${model} ($(du -sh ${MODELS_DIR}/${model} | cut -f1))"; \
      cp "${MODELS_DIR}/${model}" "${R}/home/ravan/llama.cpp/models/"; } || \
    warn "  Missing model: ${model}"
done

[ -f "${LLAMA_BIN}" ] && \
  { cp "${LLAMA_BIN}" "${R}/usr/local/bin/llama-server"; \
    chmod +x "${R}/usr/local/bin/llama-server"; \
    log "  llama-server installed"; } || \
  warn "  llama-server not found"

[ -d "${VOICE_DIR}/piper" ] && \
  { cp -r "${VOICE_DIR}/piper/"* "${R}/opt/ash-core/voice/piper/"; \
    log "  Piper installed"; } || warn "  Piper not found"

for model in "${VOICE_MODELS_INCLUDE[@]}"; do
  [ -f "${VOICE_DIR}/${model}" ] && \
    { cp "${VOICE_DIR}/${model}" "${R}/opt/ash-core/voice/"; \
      log "  Voice model: ${model}"; }
done

[ -d "${SKILLS_DIR}" ] && \
  { log "  Skills library (77MB)..."; \
    mkdir -p "${R}/opt/ash-core/skills"; \
    cp -r "${SKILLS_DIR}" "${R}/opt/ash-core/skills/"; \
    log "  ✓ Core skills"; } || warn "  Skills not found"

[ -d "${AGY_SKILLS_DIR}" ] && \
  { log "  Antigravity skills (162MB, 1500+)..."; \
    mkdir -p "${R}/opt/ash-core/agy-skills"; \
    cp -r "${AGY_SKILLS_DIR}"/* "${R}/opt/ash-core/agy-skills/"; \
    log "  ✓ Antigravity skills"; } || warn "  Antigravity skills not found"

[ -f "${SKILL_INDEX}" ] && \
  { cp "${SKILL_INDEX}" "${R}/var/lib/ash/skills/"; \
    log "  ✓ Skill index"; }

[ -d "${KNOWLEDGE_DIR}" ] && \
  { cp -r "${KNOWLEDGE_DIR}"/* "${R}/var/lib/ash/knowledge/" 2>/dev/null || true; \
    log "  ✓ Knowledge base"; }

log "Assets copied"

# Bundle the existing Faster-Whisper model as real files, not Hugging Face
# cache symlinks. The voice HTTP service must remain fully offline.
WHISPER_SNAPSHOT="${USER_HOME}/.cache/huggingface/hub/models--Systran--faster-whisper-small.en/snapshots/d1d751a5f8271d482d14ca55d9e2deeebbae577f"
if [ -f "${WHISPER_SNAPSHOT}/model.bin" ] && [ -f "${WHISPER_SNAPSHOT}/config.json" ]; then
  mkdir -p "${R}/opt/ash-core/voice/whisper-small.en"
  cp -aL "${WHISPER_SNAPSHOT}/." "${R}/opt/ash-core/voice/whisper-small.en/"
  log "  ✓ Offline Whisper small.en bundled"
else
  warn "Offline Whisper snapshot missing; port 8888 will work but STT will be disabled"
fi

# ══════════════════════════════════════════════════════════════════════
# STAGE 7: Build Python venvs inside chroot
# ══════════════════════════════════════════════════════════════════════
section "Stage 7: Building Python venvs (no internet needed at install time)"

chroot "${WORK_DIR}/rootfs" /bin/bash << 'CHROOT_VENVS'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

echo "[VENV] Harness..."
python3 -m venv /opt/ash-core/harness/venv
/opt/ash-core/harness/venv/bin/pip install -q --upgrade pip
/opt/ash-core/harness/venv/bin/pip install -q \
  "fastapi>=0.115" "uvicorn[standard]>=0.32" "httpx>=0.28" "pydantic>=2.0"
echo "  ✓ Harness"

echo "[VENV] Dashboard..."
python3 -m venv /opt/raksha-dashboard/venv
/opt/raksha-dashboard/venv/bin/pip install -q --upgrade pip
/opt/raksha-dashboard/venv/bin/pip install -q \
  "fastapi>=0.115" "uvicorn[standard]>=0.32" "httpx>=0.28" "psutil>=6.0"
echo "  ✓ Dashboard"

echo "[VENV] Voice..."
python3 -m venv /opt/ash-core/voice/venv
/opt/ash-core/voice/venv/bin/pip install -q --upgrade pip
/opt/ash-core/voice/venv/bin/pip install -q \
  "faster-whisper>=1.0" "sounddevice>=0.4" "numpy>=1.24" "pynput>=1.7"
echo "  ✓ Voice"

echo "[VENV] Reflexes..."
python3 -m venv /opt/ash-core/reflexes/venv
/opt/ash-core/reflexes/venv/bin/pip install -q --upgrade pip
/opt/ash-core/reflexes/venv/bin/pip install -q "psutil>=6.0" "requests>=2.31"
echo "  ✓ Reflexes"

echo "All venvs built."

# Repair and validate relocatable venv launchers. Never preserve circular or
# build-host-relative interpreter links in the squashfs.
PYTHON_REAL=$(readlink -f /usr/bin/python3)
PYTHON_NAME=$(basename "${PYTHON_REAL}")
for VENV in /opt/ash-core/harness/venv /opt/raksha-dashboard/venv \
            /opt/ash-core/voice/venv /opt/ash-core/reflexes/venv; do
  rm -f "${VENV}/bin/python" "${VENV}/bin/python3" "${VENV}/bin/${PYTHON_NAME}"
  ln -s /usr/bin/python3 "${VENV}/bin/python3"
  ln -s python3 "${VENV}/bin/python"
  ln -s python3 "${VENV}/bin/${PYTHON_NAME}"
  "${VENV}/bin/python" -c 'import sys; assert sys.prefix != sys.base_prefix'
done

# WhatsApp must be physically runnable without npm/network after installation.
command -v node >/dev/null
command -v npm >/dev/null
cd /opt/ash-core/gateways
npm install --omit=dev --no-audit --no-fund
test -f node_modules/whatsapp-web.js/index.js
test -f node_modules/qrcode-terminal/lib/main.js
cd /opt/ash-core/gateways/ash-whatsapp-bridge
npm ci --omit=dev --no-audit --no-fund
test -f node_modules/@whiskeysockets/baileys/package.json
CHROOT_VENVS

log "Venvs built"

# ══════════════════════════════════════════════════════════════════════
# STAGE 8: Systemd services
# ══════════════════════════════════════════════════════════════════════
section "Stage 8: Installing systemd services"

R="${WORK_DIR}/rootfs"
for unit in "${REPO_DIR}/systemd/"*.service "${REPO_DIR}/systemd/"*.timer; do
  [ -f "$unit" ] || continue
  cp "$unit" "${R}/etc/systemd/system/"
  log "  Installed: $(basename $unit)"
done

cp "${REPO_DIR}/systemd/raksha-firstboot.service" \
   "${R}/etc/systemd/system/raksha-firstboot.service"

for svc in \
  sddm.service NetworkManager.service \
  raksha-harness.service raksha-dashboard.service \
  ash-interface.service ash-defibrillator.service \
  ash-heartbeat.timer ash-dreaming.timer ash-memory.timer \
  raksha-firstboot.service; do
  if [ -f "${R}/etc/systemd/system/${svc}" ] || \
     [ -f "${R}/usr/lib/systemd/system/${svc}" ]; then
    systemctl --root="${R}" enable "${svc}" 2>/dev/null && \
      log "  ✓ Enabled: ${svc}" || warn "  Could not enable: ${svc}"
  fi
done
log "Services configured"

# ══════════════════════════════════════════════════════════════════════
# STAGE 9: Calamares installer
# ══════════════════════════════════════════════════════════════════════
section "Stage 9: Calamares installer configuration"

R="${WORK_DIR}/rootfs"
mkdir -p "${R}/etc/calamares/modules"

cat > "${R}/etc/calamares/modules/bootloader.conf" << 'EOF'
---
# Absolute target paths avoid dependence on the graphical installer's PATH.
efiBootLoader: "grub"
grubInstall: "/usr/sbin/grub-install"
grubMkconfig: "/usr/sbin/grub-mkconfig"
grubCfg: "/boot/grub/grub.cfg"
grubProbe: "/usr/sbin/grub-probe"
efiBootMgr: "/usr/bin/efibootmgr"
efiBootloaderId: "Raksha_OS"
installEFIFallback: true
EOF

cat > "${R}/etc/calamares/settings.conf" << 'EOF'
---
modules-search: [ local, /usr/lib/calamares/modules ]

sequence:
  - show:
    - welcome
    - locale
    - keyboard
    - partition
    - users
    - summary
  - exec:
    - partition
    - mount
    - unpackfs
    - machineid
    - fstab
    - locale
    - keyboard
    - localecfg
    - users
    - networkcfg
    - hwclock
    - services-systemd
    - grubcfg
    - bootloader
    - shellprocess@raksha-post
    - preservefiles
    - umount
  - show:
    - finished

branding: raksha-os
prompt-install: true
dont-chroot: false
disable-cancel: false
disable-cancel-during-exec: true
quit-at-end: false
EOF

cat > "${R}/etc/calamares/modules/shellprocess@raksha-post.conf" << 'EOF'
---
dontChroot: false
timeout: 300
script:
  - "-/bin/bash -c 'systemctl enable raksha-harness raksha-dashboard ash-interface ash-heartbeat.timer ash-dreaming.timer ash-memory.timer raksha-firstboot 2>/dev/null || true'"
  - "-/bin/bash -c 'mkdir -p /var/lib/raksha /var/lib/ash/logs /var/lib/ash/memory /var/lib/ash/tasks /var/lib/ash/identity'"
  - "-/bin/bash -c 'touch /var/lib/raksha/installed; rm -f /var/lib/raksha/.first-boot-done'"
  - "-/bin/bash -c 'chown -R 1000:1000 /var/lib/ash/logs /var/lib/ash/memory /var/lib/ash/tasks /var/lib/ash/identity 2>/dev/null || true'"
EOF

cat > "${R}/etc/calamares/modules/welcome.conf" << 'EOF'
---
requirements:
  requiredStorage: 40
  requiredRam: 4
  checkHasInternet: false
  checkForUpdates: false
  checkIsRoot: true
  checkArch: true
EOF

cat > "${R}/etc/calamares/modules/unpackfs.conf" << 'EOF'
---
unpack:
  - source: /run/live/medium/live/filesystem.squashfs
    sourcefs: squashfs
    destination: ""
EOF

cat > "${R}/etc/calamares/modules/finished.conf" << 'EOF'
---
restartNowEnabled: true
restartNowChecked: true
restartNowCommand: "systemctl reboot"
EOF

[ -d "${OVERLAY_DIR}/etc/calamares/branding" ] && \
  cp -r "${OVERLAY_DIR}/etc/calamares/branding" "${R}/etc/calamares/" && \
  log "  Calamares branding applied"

log "Calamares configured"

# ══════════════════════════════════════════════════════════════════════
# STAGE 10: Apply overlay + ownership
# ══════════════════════════════════════════════════════════════════════
section "Stage 10: Overlay + ownership"

R="${WORK_DIR}/rootfs"
# The custom overlay contains Raksha assets but the live theme supplies the
# complete tested QML implementation and metadata.
mkdir -p "${R}/usr/share/sddm/themes/raksha"
if [ -f /usr/share/sddm/themes/raksha/Main.qml ]; then
  cp -a /usr/share/sddm/themes/raksha/. "${R}/usr/share/sddm/themes/raksha/"
fi
[ -d "${OVERLAY_DIR}" ] && cp -a "${OVERLAY_DIR}/"* "${R}/" && log "Overlay applied"
test -f "${R}/usr/share/sddm/themes/raksha/Main.qml" || err "Raksha SDDM Main.qml missing"
test -f "${R}/usr/share/sddm/themes/raksha/metadata.desktop" || err "Raksha SDDM metadata missing"

if [ -d "${R}/etc/calamares/branding/raksha-os" ]; then
  rm -rf "${R}/etc/calamares/branding/raksha"
  cp -a "${R}/etc/calamares/branding/raksha-os" \
    "${R}/etc/calamares/branding/raksha"
  sed -i 's/^branding:.*/branding: raksha/' "${R}/etc/calamares/settings.conf"
fi

# Complete the Raksha look-and-feel with Breeze's standard logout/OSD/layout
# components while retaining Raksha's metadata, defaults and splash overrides.
cp -an "${R}/usr/share/plasma/look-and-feel/org.kde.breeze.desktop/." \
  "${R}/usr/share/plasma/look-and-feel/org.raksha.desktop/"
chroot "${R}" plymouth-set-default-theme raksha

# Replace calamares-settings-debian's live desktop branding while retaining
# its working privilege wrapper and package integration.
cat > "${R}/etc/xdg/autostart/calamares-desktop-icon.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Debian Calamares Desktop Icon (disabled by Raksha OS)
Hidden=true
EOF
mkdir -p "${R}/usr/local/share/applications"
cat > "${R}/usr/local/share/applications/calamares-install-debian.desktop" << 'EOF'
[Desktop Entry]
Type=Application
Name=Install Debian
Hidden=true
NoDisplay=true
EOF

# Make Raksha the Plasma default for both the live user and users created by
# Calamares. A wallpaper package lets Plasma scale the image for each screen.
RAKSHA_WALLPAPER="${R}/usr/share/backgrounds/raksha/raksha-default.png"
test -f "${RAKSHA_WALLPAPER}" || err "Raksha desktop wallpaper missing"
mkdir -p "${R}/usr/share/wallpapers/RakshaOS/contents/images"
cp "${RAKSHA_WALLPAPER}" "${R}/usr/share/wallpapers/RakshaOS/contents/images/1920x1080.jpg"
cat > "${R}/usr/share/wallpapers/RakshaOS/metadata.json" << 'EOF'
{
  "KPlugin": {
    "Id": "RakshaOS",
    "Name": "Raksha OS",
    "License": "Proprietary"
  }
}
EOF
for defaults in \
  "${R}/usr/share/plasma/look-and-feel/org.debian.desktop/contents/defaults" \
  "${R}/usr/share/plasma/look-and-feel/org.kde.breeze.desktop/contents/defaults" \
  "${R}/usr/share/plasma/look-and-feel/org.kde.breezedark.desktop/contents/defaults"; do
  if [ -f "${defaults}" ]; then
    sed -i 's|^Image=.*|Image=RakshaOS|' "${defaults}"
  fi
done
rm -rf "${R}/usr/share/plasma/look-and-feel/org.debian.desktop"
find "${R}/usr/share/wallpapers" -maxdepth 1 -type l \
  \( -name DebianTheme -o -lname '*desktop-base*' \) -delete
log "Raksha live desktop wallpaper and installer launcher configured"

# /opt is immutable runtime content and stays root-owned in the image.
chown -R 0:0 "${R}/opt/ash-core" "${R}/opt/raksha-dashboard" 2>/dev/null || true
chmod -R a+rX "${R}/opt/ash-core" "${R}/opt/raksha-dashboard"
chown -R 1000:1000 \
  "${R}/var/lib/ash/logs" "${R}/var/lib/ash/memory" \
  "${R}/var/lib/ash/tasks" "${R}/var/lib/ash/identity" \
  "${R}/home/ravan" 2>/dev/null || true

touch \
  "${R}/var/lib/ash/logs/ash.log" \
  "${R}/var/lib/ash/logs/harness.log" \
  "${R}/var/lib/ash/logs/interface.log"
chown 1000:1000 "${R}/var/lib/ash/logs/"* 2>/dev/null || true
log "Ownership set"

# Do not force a proprietary driver that was not successfully built for the
# ISO kernel. In that case retain nouveau so normal graphics can reach SDDM.
if ! find "${R}/lib/modules/${KVER}" -type f \
    \( -name 'nvidia.ko*' -o -name 'nvidia-current.ko*' \) -print -quit | grep -q .; then
  rm -f "${R}/etc/modules-load.d/nvidia.conf"
  rm -f "${R}/etc/modprobe.d/nvidia-blacklists-nouveau.conf"
  rm -f "${R}/etc/modprobe.d/nvidia.conf"
  systemctl --root="${R}" disable nvidia-persistenced.service 2>/dev/null || true
  log "Graphics: no NVIDIA kernel module; enabled nouveau fallback"
fi

rm -f "${R}/var/lib/raksha/installed" "${R}/var/lib/raksha/.first-boot-done"
printf 'RAKSHA_ISO_BUILD=4\n' > "${R}/etc/raksha-iso-build"
"${REPO_DIR}/scripts/build/verify-rootfs.sh" "${R}"
log "Static rootfs verification passed"

# ══════════════════════════════════════════════════════════════════════
# STAGE 11: Squashfs
# ══════════════════════════════════════════════════════════════════════
section "Stage 11: Building squashfs (10-30 min)"

R="${WORK_DIR}/rootfs"
rm -rf "${R}/tmp/"* "${R}/var/cache/apt/"* "${R}/var/lib/apt/lists/"*
rm -f  "${R}/etc/resolv.conf"

# ── Generate initrd FROM INSIDE chroot BEFORE unmounting ──────────────
# Must run here while proc/sys/dev are still mounted.
# The chroot has live-boot installed so the initrd will have live-boot hooks.
section "Stage 11b: Generating initrd inside chroot (live-boot hooks)"

printf '#!/bin/sh\nexit 101\n' > "${R}/usr/sbin/policy-rc.d"
chmod +x "${R}/usr/sbin/policy-rc.d"

cp "${KERNEL_DEB}" "${R}/tmp/"
KDEB_BASE=$(basename "${KERNEL_DEB}")

chroot "${R}" /bin/bash -c "
  export DEBIAN_FRONTEND=noninteractive
  echo 'Installing kernel inside chroot...'
  dpkg -i /tmp/${KDEB_BASE} 2>&1 | grep -E 'npack|etting|rror' || true
  echo 'Generating initrd with live-boot hooks...'
  update-initramfs -u -k ${KVER} 2>&1
  ls -lh /boot/
"

mkdir -p "${WORK_DIR}/iso/boot"
cp "${R}/boot/initrd.img-${KVER}" "${WORK_DIR}/iso/boot/initrd"
cp "${R}/boot/vmlinuz-${KVER}"    "${WORK_DIR}/iso/boot/vmlinuz"
rm -f "${R}/usr/sbin/policy-rc.d"
log "  ✓ initrd (with live-boot): $(du -sh ${WORK_DIR}/iso/boot/initrd | cut -f1)"
log "  ✓ vmlinuz: $(du -sh ${WORK_DIR}/iso/boot/vmlinuz | cut -f1)"

# Now unmount and build squashfs
for mnt in proc sys dev/pts dev; do
  umount -l "${R}/${mnt}" 2>/dev/null || true
done

mkdir -p "${WORK_DIR}/iso/live"
mksquashfs "${R}" "${WORK_DIR}/iso/live/filesystem.squashfs" \
  -comp xz -b 1M -Xdict-size 100% -no-recovery \
  -e "${WORK_DIR}/iso/live/filesystem.squashfs"

SQUASH_SIZE=$(du -sh "${WORK_DIR}/iso/live/filesystem.squashfs" | cut -f1)
log "Squashfs: ${SQUASH_SIZE}"
du -sx --block-size=1 "${R}" | cut -f1 > "${WORK_DIR}/iso/live/filesystem.size"
"${REPO_DIR}/scripts/build/verify-squashfs.sh" \
  "${WORK_DIR}/iso/live/filesystem.squashfs"
log "Static squashfs verification passed"

# ══════════════════════════════════════════════════════════════════════
# STAGE 12: GRUB config + assemble ISO
# (initrd already built in Stage 11b with live-boot hooks)
# ══════════════════════════════════════════════════════════════════════
section "Stage 12: Assembling ISO"

mkdir -p "${WORK_DIR}/iso/boot/grub/themes"

# Copy real Raksha GRUB theme
if [ -d "${OVERLAY_DIR}/boot/grub/themes/raksha" ]; then
  cp -r "${OVERLAY_DIR}/boot/grub/themes/raksha" \
        "${WORK_DIR}/iso/boot/grub/themes/"
  log "  ✓ Real GRUB theme copied"
fi

# GRUB config
cat > "${WORK_DIR}/iso/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=10

if loadfont /boot/grub/fonts/unicode.pf2; then
  set gfxmode=auto
  insmod all_video
  insmod gfxterm
  terminal_output gfxterm
fi

menuentry "Install Raksha OS" --class raksha --class linux {
  linux /boot/vmlinuz boot=live components splash quiet \
        live-config.hostname=raksha \
        live-config.username=ravan \
        live-config.password=raksha \
        live-config.autologin=true
  initrd /boot/initrd
}

menuentry "Raksha OS Live (Try without installing)" --class raksha {
  linux /boot/vmlinuz boot=live components splash quiet
  initrd /boot/initrd
}

menuentry "Raksha OS (Safe Graphics / nomodeset)" --class raksha {
  linux /boot/vmlinuz boot=live components quiet nomodeset
  initrd /boot/initrd
}

menuentry "Raksha OS (Debug Mode)" --class raksha {
  linux /boot/vmlinuz boot=live components debug
  initrd /boot/initrd
}
EOF

# Assemble ISO — using xorriso wrapper for iso-level 3 (bypasses 4GB limit)
log "Assembling ISO (3-5 min)..."
mkdir -p "${OUTPUT_DIR}"
rm -f "${OUTPUT_DIR}/${ISO_FILE}"

grub-mkrescue \
    --xorriso="${XORRISO_WRAPPER}" \
    -o "${OUTPUT_DIR}/${ISO_FILE}" \
    "${WORK_DIR}/iso" 2>&1

# Cleanup
rm -f "${XORRISO_WRAPPER}"
rm -rf "${KERNEL_TMPDIR}"

ISO_SIZE=$(du -sh "${OUTPUT_DIR}/${ISO_FILE}" | cut -f1)

section "BUILD COMPLETE"
echo ""
echo "  ✅  File    : ${OUTPUT_DIR}/${ISO_FILE}"
echo "  ✅  Size    : ${ISO_SIZE}"
echo "  ✅  Squashfs: ${SQUASH_SIZE}"
echo ""
echo "  Flash to USB:"
echo "    sudo dd if=${OUTPUT_DIR}/${ISO_FILE} of=/dev/sdX bs=4M status=progress"
echo ""
echo "  Test:"
echo "    qemu-system-x86_64 -m 8G -enable-kvm -cdrom ${OUTPUT_DIR}/${ISO_FILE} -boot d"
echo ""
