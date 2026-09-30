#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Raksha OS — ISO Build Script v3
# Self-contained: everything pre-installed in squashfs, no host dependencies
# after install. Works like Kali — install via Calamares, reboot, done.
#
# Run as root: sudo bash build-iso-v3.sh
# Build time: 45-90 minutes
# Output size: ~30-40GB (squashfs ~15-20GB compressed with models)
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

# ══════════════════════════════════════════════════════════════════════
# CONFIGURATION — edit these paths if your build environment differs
# ══════════════════════════════════════════════════════════════════════

ISO_NAME="raksha-os-1.0.0-amd64"
ISO_FILE="${ISO_NAME}.iso"
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${REPO_DIR}/builds"
# Respect WORK_DIR env var (useful to point at /home when /tmp is tight)
WORK_DIR="${WORK_DIR:-/home/ravan/raksha-build}"
OVERLAY_DIR="${REPO_DIR}/overlay"

# ── Asset source paths ──
# NOTE: $HOME = /root when running as root via sudo.
#       Use /home/ravan explicitly so all paths resolve correctly.
USER_HOME="/home/ravan"
MODELS_DIR="${USER_HOME}/llama.cpp/models"
VOICE_DIR="${USER_HOME}/raksha-vocie"
SKILLS_DIR="/opt/ash-core/skills/skills"
AGY_SKILLS_DIR="${USER_HOME}/.gemini/antigravity-cli/skills"
SKILL_INDEX="/var/lib/ash/skills/skill_index.json"
KNOWLEDGE_DIR="/var/lib/ash/knowledge"
LLAMA_BIN="${USER_HOME}/llama.cpp/build/bin/llama-server"
HELAYIDAYA_BIN="/opt/ash-core/helayidaya/helayidaya.py"
COMPUTER_USE_PY="/usr/local/lib/ash/tools/computer_use.py"

# ── Models to include (all local .gguf files that exist) ──
MODELS_INCLUDE=(
  "gemma-4-E2B_q4_0-it.gguf"
  "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf"
  "UI-TARS-2B-SFT-Q4_K_M.gguf"
  "UI-TARS-2B-SFT-mmproj-fp16.gguf"
)

# ── Voice models ──
VOICE_MODELS_INCLUDE=(
  "en_US-ryan-high.onnx"
  "en_US-ryan-high.onnx.json"
  "en_US-amy-medium.onnx"
  "en_US-amy-medium.onnx.json"
)

# ── Colors ──
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[BUILD]${NC} $1"; }
info() { echo -e "${CYAN}[INFO]${NC}  $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
err()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${CYAN}══════════════════════════════════════════════════════${NC}"; echo -e "${CYAN}  $1${NC}"; echo -e "${CYAN}══════════════════════════════════════════════════════${NC}"; }

# ══════════════════════════════════════════════════════════════════════
# PRE-FLIGHT CHECKS
# ══════════════════════════════════════════════════════════════════════

section "Raksha OS ISO Build v3 — $(date)"
info "Repo     : ${REPO_DIR}"
info "Output   : ${OUTPUT_DIR}/${ISO_FILE}"
info "Work dir : ${WORK_DIR}"

[ "$(id -u)" -ne 0 ] && err "Must run as root: sudo bash $0"

for cmd in debootstrap xorriso mksquashfs grub-mkrescue python3; do
  command -v "$cmd" &>/dev/null || err "Missing required tool: $cmd (apt install $cmd)"
done

AVAIL=$(df -BG "${WORK_DIR%/*}" 2>/dev/null | awk 'NR==2{print $4}' | tr -d 'G' || echo 999)
[ "${AVAIL}" -lt 50 ] && warn "Low disk space: ${AVAIL}GB. Build may fail (need ~50GB)."

# Warn about missing assets (don't fail — warn and continue)
[ -f "${LLAMA_BIN}" ]      || warn "llama-server binary not found at ${LLAMA_BIN}"
[ -d "${VOICE_DIR}" ]      || warn "Voice dir not found: ${VOICE_DIR}"
[ -d "${MODELS_DIR}" ]     || warn "Models dir not found: ${MODELS_DIR}"
[ -d "${SKILLS_DIR}" ]     || warn "Skills dir not found: ${SKILLS_DIR}"

# ══════════════════════════════════════════════════════════════════════
# PREPARE WORK DIRECTORY
# ══════════════════════════════════════════════════════════════════════

section "Preparing work directory"

# Clean previous build
if [ -d "${WORK_DIR}" ]; then
  # Unmount anything still mounted
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

section "Stage 1: Bootstrapping Debian 13 Trixie base"

debootstrap \
  --arch amd64 \
  --variant=minbase \
  --include=locales,sudo,ca-certificates,curl,wget,git,vim,nano,htop,unzip,rsync,\
fonts-dejavu,fonts-liberation,fonts-noto,fonts-noto-cjk,fonts-noto-color-emoji \
  trixie \
  "${WORK_DIR}/rootfs" \
  http://deb.debian.org/debian

log "Debian base bootstrapped"

# Mount pseudo-filesystems
mount --bind /proc    "${WORK_DIR}/rootfs/proc"
mount --bind /sys     "${WORK_DIR}/rootfs/sys"
mount --bind /dev     "${WORK_DIR}/rootfs/dev"
mount --bind /dev/pts "${WORK_DIR}/rootfs/dev/pts"

# DNS for chroot
cp /etc/resolv.conf "${WORK_DIR}/rootfs/etc/resolv.conf"

# Apt sources
cat > "${WORK_DIR}/rootfs/etc/apt/sources.list" << 'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware
EOF

# Hostname
echo "raksha" > "${WORK_DIR}/rootfs/etc/hostname"
cat > "${WORK_DIR}/rootfs/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   raksha
::1         localhost ip6-localhost ip6-loopback
EOF

# ══════════════════════════════════════════════════════════════════════
# STAGE 2: Install all packages inside chroot
# ══════════════════════════════════════════════════════════════════════

section "Stage 2: Installing packages (30-45 min)"

chroot "${WORK_DIR}/rootfs" /bin/bash << 'CHROOT_PACKAGES'
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C

apt-get update -qq

# ── Core system ──
apt-get install -y \
  linux-image-amd64 linux-headers-amd64 \
  grub-pc grub-efi-amd64 grub-efi-amd64-bin \
  systemd systemd-sysv systemd-resolved \
  dbus dbus-x11 polkitd \
  bash-completion console-setup keyboard-configuration \
  tzdata dosfstools e2fsprogs btrfs-progs ntfs-3g exfat-fuse \
  openssh-server \
  iproute2 iputils-ping net-tools \
  network-manager modemmanager \
  firmware-linux firmware-linux-nonfree firmware-misc-nonfree \
  firmware-iwlwifi firmware-realtek firmware-atheros \
  intel-microcode amd64-microcode \
  live-boot live-boot-initramfs-tools live-config live-config-systemd \
  calamares calamares-settings-debian \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

# ── Desktop: KDE Plasma ──
apt-get install -y \
  xorg xserver-xorg-core xserver-xorg-input-libinput xserver-xorg-video-all \
  plasma-desktop plasma-workspace sddm \
  konsole dolphin kate okular gwenview ark kcalc kscreen \
  plasma-nm plasma-pa kinfocenter \
  firefox-esr \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

# ── NVIDIA (best-effort — may not be in trixie main) ──
apt-get install -y nvidia-driver nvidia-cuda-toolkit 2>/dev/null || \
  apt-get install -y nvidia-driver 2>/dev/null || true

# ── Audio: PipeWire ──
apt-get install -y \
  pipewire pipewire-pulse pipewire-alsa wireplumber \
  alsa-utils pavucontrol \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

# ── Python full stack ──
apt-get install -y \
  python3 python3-pip python3-venv python3-dev python3-wheel \
  python3-numpy python3-scipy python3-pillow \
  python3-requests python3-aiohttp \
  sqlite3 libsqlite3-dev \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

# ── Build tools (for native Python extensions) ──
apt-get install -y \
  build-essential cmake pkg-config \
  libopenblas-dev liblapack-dev \
  libffi-dev libssl-dev \
  portaudio19-dev libsndfile1 \
  libasound2-dev \
  libsoundio-dev \
  espeak-ng espeak-ng-data \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

# ── Runtime tools ──
apt-get install -y \
  nodejs npm \
  sqlite3 \
  timeshift \
  p7zip-full \
  gparted \
  ffmpeg vlc \
  bluez \
  cups \
  ufw \
  apparmor apparmor-utils apparmor-profiles \
  fail2ban auditd \
  lm-sensors tlp thermald \
  wireguard-tools openvpn \
  nfs-common cifs-utils smbclient avahi-daemon \
  screen tmux \
  less man-db manpages info \
  which strace ltrace pciutils usbutils hdparm smartmontools \
  xdotool scrot imagemagick wmctrl x11-utils xclip xdg-utils \
  tesseract-ocr tesseract-ocr-eng \
  notify-send \
  2>&1 | grep -E "^(Get|Inst|Err)" || true

echo "Packages installed."
CHROOT_PACKAGES

log "All packages installed"

# ══════════════════════════════════════════════════════════════════════
# STAGE 3: Configure system inside chroot
# ══════════════════════════════════════════════════════════════════════

section "Stage 3: System configuration"

chroot "${WORK_DIR}/rootfs" /bin/bash << 'CHROOT_CONFIG'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C

# Locale
sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/default/locale

# Timezone (Melbourne — adjust in firstboot if user wants different)
ln -sf /usr/share/zoneinfo/Australia/Melbourne /etc/localtime
echo "Australia/Melbourne" > /etc/timezone

# Root password
echo "root:raksha" | chpasswd

# Default user — Calamares will replace this with the real user
# But we need ravan for services during live session
useradd -m -s /bin/bash -G sudo,audio,video,plugdev,users,input ravan
echo "ravan:raksha" | chpasswd
echo "ravan ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/ravan
chmod 440 /etc/sudoers.d/ravan

# SDDM auto-login for live session
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/autologin.conf << 'SDDM'
[Autologin]
User=ravan
Session=plasma.desktop
Relogin=false

[General]
DisplayServer=x11
SDDM

# Enable base system services
systemctl enable sddm          2>/dev/null || true
systemctl enable NetworkManager 2>/dev/null || true
systemctl enable ssh           2>/dev/null || true
systemctl enable cups          2>/dev/null || true
systemctl enable bluetooth     2>/dev/null || true
systemctl enable ufw           2>/dev/null || true
systemctl enable apparmor      2>/dev/null || true
systemctl enable thermald      2>/dev/null || true
systemctl enable tlp           2>/dev/null || true
systemctl enable auditd        2>/dev/null || true

echo "System configured."
CHROOT_CONFIG

log "System configured"

# ══════════════════════════════════════════════════════════════════════
# STAGE 4: Copy all Ash source files into rootfs
# ══════════════════════════════════════════════════════════════════════

section "Stage 4: Staging Ash source files"

R="${WORK_DIR}/rootfs"

# ── Directory structure ──
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
  "${R}/var/lib/ash/harness" \
  "${R}/var/lib/ash/creations" \
  "${R}/var/lib/ash/screenshots" \
  "${R}/var/lib/ash/skills" \
  "${R}/var/lib/raksha/obsidian/instincts/Vault/Ash_Cortex" \
  "${R}/etc/raksha" \
  "${R}/etc/systemd/system"

# ── Ash cognitive core ──
cp "${REPO_DIR}/src/ash/agent-loop.py"      "${R}/usr/local/lib/ash/"
cp "${REPO_DIR}/src/ash/heartbeat.py"       "${R}/opt/ash-core/reflexes/" 2>/dev/null || true
cp "${REPO_DIR}/src/ash/memory-consolidate.py" "${R}/opt/ash-core/reflexes/" 2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash"                "${R}/usr/local/bin/ash"
cp "${REPO_DIR}/src/ash/ash-heartbeat"      "${R}/usr/local/bin/ash-heartbeat"   2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-memory"         "${R}/usr/local/bin/ash-memory"      2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-status"         "${R}/usr/local/bin/ash-status"      2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-talk"           "${R}/usr/local/bin/ash-talk"        2>/dev/null || true
chmod +x "${R}/usr/local/bin/ash" "${R}/usr/local/bin/ash-heartbeat" 2>/dev/null || true

# ── Reflexes ──
cp "${REPO_DIR}/src/reflexes/heartbeat.py"     "${R}/opt/ash-core/reflexes/"
cp "${REPO_DIR}/src/reflexes/dreaming.py"      "${R}/opt/ash-core/reflexes/"
cp "${REPO_DIR}/src/reflexes/defibrillator.sh" "${R}/opt/ash-core/reflexes/"
chmod +x "${R}/opt/ash-core/reflexes/defibrillator.sh"

# ── Harness ──
cp "${REPO_DIR}/src/harness/harness.py"        "${R}/opt/ash-core/harness/"
cp "${REPO_DIR}/src/harness/harness_client.py" "${R}/opt/ash-core/harness/" 2>/dev/null || true

# ── Dashboard ──
cp "${REPO_DIR}/src/dashboard/main.py"         "${R}/opt/raksha-dashboard/"

# ── Voice interface ──
cp "${REPO_DIR}/src/interface/server.py"       "${R}/opt/ash-core/voice/"

# ── Gateways ──
if [ -d "${REPO_DIR}/src/gateways" ]; then
  cp "${REPO_DIR}/src/gateways/"*.py "${R}/opt/ash-core/gateways/"   2>/dev/null || true
  cp "${REPO_DIR}/src/gateways/"*.js "${R}/opt/ash-core/gateways/"   2>/dev/null || true
  cp "${REPO_DIR}/src/gateways/package.json" "${R}/opt/ash-core/gateways/" 2>/dev/null || true
  if [ -d "${REPO_DIR}/src/gateways/ash-whatsapp-bridge" ]; then
    cp -r "${REPO_DIR}/src/gateways/ash-whatsapp-bridge/"* \
          "${R}/opt/ash-core/gateways/ash-whatsapp-bridge/" 2>/dev/null || true
  fi
fi

# ── Helayidaya (system health tool) ──
[ -f "${HELAYIDAYA_BIN}" ] && cp "${HELAYIDAYA_BIN}" "${R}/opt/ash-core/helayidaya/" || true
[ -f "${COMPUTER_USE_PY}" ] && cp "${COMPUTER_USE_PY}" "${R}/opt/ash-core/tools/"   || true

# ── Ash identity ──
cp "${REPO_DIR}/config/ash/SOUL.md"   "${R}/var/lib/ash/identity/"
cp "${REPO_DIR}/config/ash/USER.md"   "${R}/var/lib/ash/identity/"
cp "${REPO_DIR}/config/ash/MEMORY.md" "${R}/var/lib/ash/memory/"  2>/dev/null || true

# ── Clean .env (no Honcho, no real API keys) ──
cat > "${R}/var/lib/ash/identity/.env" << 'ENV_EOF'
# Ash — Runtime Configuration
# Edit this file to add API keys after installation

# Local inference (pre-installed — no internet needed)
LLAMA_URL=http://127.0.0.1:8080/v1/chat/completions
ASH_MODEL=gemma-4-E2B_q4_0-it

# Raksha Harness
HARNESS_URL=http://127.0.0.1:8890

# NVIDIA Deep Brain (optional — get key at https://build.nvidia.com)
NVIDIA_API_KEY=
NVIDIA_BASE_URL=https://integrate.api.nvidia.com/v1
NVIDIA_MODEL=nvidia/nemotron-3-ultra-550b-a55b

# Voice
VOICE_BASE=/opt/ash-core/voice
ASH_VOICE_PORT=8888
ASH_HOME=/var/lib/ash
ENV_EOF
chmod 600 "${R}/var/lib/ash/identity/.env"

# ── Raksha config ──
cat > "${R}/etc/raksha/config.yaml" << 'YAML_EOF'
# Raksha OS Configuration
version: "1.0.0"
ash:
  home: /var/lib/ash
  model: gemma-4-E2B_q4_0-it
  llama_url: http://127.0.0.1:8080
  harness_url: http://127.0.0.1:8890
  voice_url: http://127.0.0.1:8888
  dashboard_url: http://127.0.0.1:8889
voice:
  base: /opt/ash-core/voice
  model: en_US-ryan-high.onnx
  stt: small.en
YAML_EOF

# ── Firstboot script ──
cp "${REPO_DIR}/scripts/raksha-firstboot.sh" "${R}/usr/local/bin/raksha-firstboot"
chmod +x "${R}/usr/local/bin/raksha-firstboot"

# ── WhatsApp and Telegram setup scripts ──
cat > "${R}/usr/local/bin/raksha-whatsapp-setup" << 'WSEOF'
#!/bin/bash
echo "🜂 Raksha OS — WhatsApp Gateway Setup"
echo ""
echo "1. Open WhatsApp on your phone"
echo "2. Settings → Linked Devices → Link a Device"
echo "3. Scan the QR code that appears below"
echo ""
read -p "Press Enter to generate QR code..."
cd /opt/ash-core/gateways
node whatsapp-gateway.js &
GATEWAY_PID=$!
sleep 5
echo ""
echo "Scan the QR code above, then press Enter..."
read
kill $GATEWAY_PID 2>/dev/null
echo "✓ WhatsApp gateway configured!"
WSEOF
chmod +x "${R}/usr/local/bin/raksha-whatsapp-setup"

cat > "${R}/usr/local/bin/raksha-telegram-setup" << 'TSEOF'
#!/bin/bash
echo "🜂 Raksha OS — Telegram Gateway Setup"
echo ""
echo "1. Open Telegram → search @BotFather → /newbot"
echo "2. Copy the bot token"
echo ""
read -p "Paste your Telegram bot token: " TOKEN
sed -i "s/BOT_TOKEN=.*/BOT_TOKEN=${TOKEN}/" \
  /var/lib/ash/identity/.env
echo "✓ Telegram gateway configured. Restart ash-telegram.service."
TSEOF
chmod +x "${R}/usr/local/bin/raksha-telegram-setup"

# ── Helayidaya wrapper ──
cat > "${R}/usr/local/bin/helayidaya" << 'HEOF'
#!/bin/bash
exec python3 /opt/ash-core/helayidaya/helayidaya.py "$@"
HEOF
chmod +x "${R}/usr/local/bin/helayidaya"

log "Ash source files staged"

# ══════════════════════════════════════════════════════════════════════
# STAGE 5: Copy large assets (models, voice, skills, knowledge)
# ══════════════════════════════════════════════════════════════════════

section "Stage 5: Copying AI models and assets"

# ── LLM models ──
mkdir -p "${R}/home/ravan/llama.cpp/models"
for model in "${MODELS_INCLUDE[@]}"; do
  if [ -f "${MODELS_DIR}/${model}" ]; then
    log "  Copying model: ${model} ($(du -sh "${MODELS_DIR}/${model}" | cut -f1))"
    cp "${MODELS_DIR}/${model}" "${R}/home/ravan/llama.cpp/models/"
  else
    warn "  Model not found (skipping): ${model}"
  fi
done

# ── llama-server binary ──
if [ -f "${LLAMA_BIN}" ]; then
  cp "${LLAMA_BIN}" "${R}/usr/local/bin/llama-server"
  chmod +x "${R}/usr/local/bin/llama-server"
  log "  llama-server binary installed"
else
  warn "  llama-server binary not found — models won't serve without it"
fi

# ── Piper TTS binary and libraries ──
if [ -d "${VOICE_DIR}/piper" ]; then
  cp -r "${VOICE_DIR}/piper/"* "${R}/opt/ash-core/voice/piper/"
  log "  Piper binary and libs installed"
else
  warn "  Piper not found at ${VOICE_DIR}/piper"
fi

# ── Voice models ──
for model in "${VOICE_MODELS_INCLUDE[@]}"; do
  if [ -f "${VOICE_DIR}/${model}" ]; then
    cp "${VOICE_DIR}/${model}" "${R}/opt/ash-core/voice/"
    log "  Voice model: ${model} ($(du -sh "${VOICE_DIR}/${model}" | cut -f1))"
  fi
done

# ── Skills: core library (77MB) ──
if [ -d "${SKILLS_DIR}" ]; then
  log "  Copying core skills library (77MB)..."
  cp -r "${SKILLS_DIR}"  "${R}/opt/ash-core/skills/"
  log "  Core skills installed"
else
  warn "  Core skills not found at ${SKILLS_DIR}"
fi

# ── Skills: Antigravity bundles (162MB, 1500+ skills) ──
if [ -d "${AGY_SKILLS_DIR}" ]; then
  log "  Copying Antigravity skill bundles (162MB, 1500+ skills)..."
  mkdir -p "${R}/opt/ash-core/agy-skills"
  cp -r "${AGY_SKILLS_DIR}"/* "${R}/opt/ash-core/agy-skills/"
  log "  Antigravity skills installed"
else
  warn "  Antigravity skills not found at ${AGY_SKILLS_DIR}"
fi

# ── Skill index ──
if [ -f "${SKILL_INDEX}" ]; then
  cp "${SKILL_INDEX}" "${R}/var/lib/ash/skills/"
  log "  Skill index installed ($(du -sh "${SKILL_INDEX}" | cut -f1))"
fi

# ── Knowledge base ──
if [ -d "${KNOWLEDGE_DIR}" ]; then
  log "  Copying knowledge base..."
  cp -r "${KNOWLEDGE_DIR}"/* "${R}/var/lib/ash/knowledge/" 2>/dev/null || true
  log "  Knowledge base installed ($(du -sh "${KNOWLEDGE_DIR}" | cut -f1))"
fi

log "All assets copied"

# ══════════════════════════════════════════════════════════════════════
# STAGE 6: Build Python venvs INSIDE chroot
# ══════════════════════════════════════════════════════════════════════

section "Stage 6: Building Python venvs inside chroot (pre-built, no internet at install time)"

chroot "${WORK_DIR}/rootfs" /bin/bash << 'CHROOT_VENVS'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
set -e

log() { echo "[VENV] $1"; }

# ── Harness venv ──
log "Creating Harness venv..."
python3 -m venv /opt/ash-core/harness/venv
/opt/ash-core/harness/venv/bin/pip install --quiet --upgrade pip
/opt/ash-core/harness/venv/bin/pip install --quiet \
  "fastapi>=0.115" "uvicorn[standard]>=0.32" "httpx>=0.28" "pydantic>=2.0"
log "  ✓ Harness venv ready"

# ── Dashboard venv ──
log "Creating Dashboard venv..."
python3 -m venv /opt/raksha-dashboard/venv
/opt/raksha-dashboard/venv/bin/pip install --quiet --upgrade pip
/opt/raksha-dashboard/venv/bin/pip install --quiet \
  "fastapi>=0.115" "uvicorn[standard]>=0.32" "httpx>=0.28" "psutil>=6.0"
log "  ✓ Dashboard venv ready"

# ── Voice venv ──
log "Creating Voice venv (faster-whisper + sounddevice)..."
python3 -m venv /opt/ash-core/voice/venv
/opt/ash-core/voice/venv/bin/pip install --quiet --upgrade pip
/opt/ash-core/voice/venv/bin/pip install --quiet \
  "faster-whisper>=1.0" \
  "sounddevice>=0.4" \
  "numpy>=1.24" \
  "pynput>=1.7"
log "  ✓ Voice venv ready"

# ── Reflexes venv (heartbeat, dreaming) ──
log "Creating Reflexes venv..."
python3 -m venv /opt/ash-core/reflexes/venv
/opt/ash-core/reflexes/venv/bin/pip install --quiet --upgrade pip
/opt/ash-core/reflexes/venv/bin/pip install --quiet \
  "psutil>=6.0" "requests>=2.31"
log "  ✓ Reflexes venv ready"

echo "All venvs built."
CHROOT_VENVS

log "Python venvs pre-built inside rootfs"

# ══════════════════════════════════════════════════════════════════════
# STAGE 7: Install systemd services
# ══════════════════════════════════════════════════════════════════════

section "Stage 7: Installing and enabling systemd services"

R="${WORK_DIR}/rootfs"

# Copy all service and timer units from repo
for unit in "${REPO_DIR}/systemd/"*.service "${REPO_DIR}/systemd/"*.timer; do
  [ -f "$unit" ] || continue
  cp "$unit" "${R}/etc/systemd/system/"
  log "  Installed: $(basename $unit)"
done

# ── Firstboot service ──
cat > "${R}/etc/systemd/system/raksha-firstboot.service" << 'EOF'
[Unit]
Description=Raksha OS — First Boot Setup (Ash Awakening)
After=multi-user.target network.target
Wants=network.target
ConditionPathExists=!/var/lib/raksha/.firstboot-complete

[Service]
Type=oneshot
ExecStart=/usr/local/bin/raksha-firstboot
RemainAfterExit=yes
StandardOutput=journal+console
StandardError=journal+console
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF

# ── Enable services using systemctl --root= (works without boot) ──
ENABLE_SERVICES=(
  sddm.service
  NetworkManager.service
  raksha-harness.service
  raksha-dashboard.service
  ash-interface.service
  ash-defibrillator.service
  ash-heartbeat.timer
  ash-dreaming.timer
  ash-memory.timer
  raksha-firstboot.service
)

for svc in "${ENABLE_SERVICES[@]}"; do
  if [ -f "${R}/etc/systemd/system/${svc}" ] || \
     [ -f "${R}/usr/lib/systemd/system/${svc}" ]; then
    systemctl --root="${R}" enable "${svc}" 2>/dev/null && \
      log "  ✓ Enabled: ${svc}" || \
      warn "  Could not enable (may be normal): ${svc}"
  else
    warn "  Not found in rootfs: ${svc}"
  fi
done

log "Services configured"

# ══════════════════════════════════════════════════════════════════════
# STAGE 8: Calamares installer configuration
# ══════════════════════════════════════════════════════════════════════

section "Stage 8: Configuring Calamares installer"

R="${WORK_DIR}/rootfs"
mkdir -p "${R}/etc/calamares/modules"

# ── settings.conf ──
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
oem-setup: false
disable-cancel: false
disable-cancel-during-exec: true
quit-at-end: false
EOF

# ── Post-install shellprocess ──
# Runs INSIDE the installed system (chroot) — enables services, preps firstboot
cat > "${R}/etc/calamares/modules/shellprocess@raksha-post.conf" << 'EOF'
---
# Raksha OS post-install setup
# Runs inside the target chroot after files are copied
# Must be fast — no internet, no pip, no downloads
# All venvs and models are already on disk from the squashfs

dontChroot: false
timeout: 300

script:
  - "-/bin/bash -c 'systemctl enable raksha-harness.service 2>/dev/null || true'"
  - "-/bin/bash -c 'systemctl enable raksha-dashboard.service 2>/dev/null || true'"
  - "-/bin/bash -c 'systemctl enable ash-interface.service 2>/dev/null || true'"
  - "-/bin/bash -c 'systemctl enable ash-defibrillator.service 2>/dev/null || true'"
  - "-/bin/bash -c 'systemctl enable ash-heartbeat.timer 2>/dev/null || true'"
  - "-/bin/bash -c 'systemctl enable ash-dreaming.timer 2>/dev/null || true'"
  - "-/bin/bash -c 'systemctl enable ash-memory.timer 2>/dev/null || true'"
  - "-/bin/bash -c 'systemctl enable raksha-firstboot.service 2>/dev/null || true'"
  - "-/bin/bash -c 'mkdir -p /var/lib/raksha /var/lib/ash/logs'"
  - "-/bin/bash -c 'touch /var/lib/ash/logs/ash.log /var/lib/ash/logs/harness.log /var/lib/ash/logs/interface.log'"
  - "-/bin/bash -c 'chown -R 1000:1000 /opt/ash-core /opt/raksha-dashboard /var/lib/ash /var/lib/raksha 2>/dev/null || true'"
EOF

# ── Welcome module config ──
cat > "${R}/etc/calamares/modules/welcome.conf" << 'EOF'
---
showSupportUrl: false
showKnownIssuesUrl: false
showReleaseNotesUrl: false

requirements:
  requiredStorage: 40
  requiredRam: 4
  checkHasInternet: false
  checkForUpdates: false
  checkIsRoot: true
  checkArch: true
EOF

# ── unpackfs module (points at our squashfs) ──
cat > "${R}/etc/calamares/modules/unpackfs.conf" << 'EOF'
---
unpack:
  - source: /run/live/medium/live/filesystem.squashfs
    sourcefs: squashfs
    destination: ""
EOF

# ── finished module ──
cat > "${R}/etc/calamares/modules/finished.conf" << 'EOF'
---
restartNowEnabled: true
restartNowChecked: true
restartNowCommand: "systemctl reboot"
notifyOnFinished: false
EOF

# ── Copy branding from overlay ──
if [ -d "${OVERLAY_DIR}/etc/calamares/branding" ]; then
  cp -r "${OVERLAY_DIR}/etc/calamares/branding" "${R}/etc/calamares/"
  log "  Calamares branding applied"
fi

log "Calamares configured"

# ══════════════════════════════════════════════════════════════════════
# STAGE 9: Apply overlay (branding, themes, wallpapers, GRUB, Plymouth)
# ══════════════════════════════════════════════════════════════════════

section "Stage 9: Applying Raksha OS overlay"

R="${WORK_DIR}/rootfs"

# Apply all overlay files
if [ -d "${OVERLAY_DIR}" ]; then
  cp -a "${OVERLAY_DIR}/"* "${R}/"
  log "Overlay applied"
fi

# ── GRUB config ──
mkdir -p "${WORK_DIR}/iso/boot/grub"
cat > "${WORK_DIR}/iso/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=10

# Raksha branding
if loadfont /boot/grub/fonts/unicode.pf2 ; then
  set gfxmode=auto
  insmod all_video
  insmod gfxterm
  terminal_output gfxterm
fi

if [ -f /boot/grub/themes/raksha/theme.txt ]; then
  set theme=/boot/grub/themes/raksha/theme.txt
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
  linux /boot/vmlinuz boot=live components splash quiet nomodeset \
        live-config.hostname=raksha
  initrd /boot/initrd
}

menuentry "Raksha OS Installer (Text Mode)" --class raksha {
  linux /boot/vmlinuz boot=live components text \
        live-config.hostname=raksha
  initrd /boot/initrd
}

menuentry "Raksha OS (Safe Graphics)" --class raksha {
  linux /boot/vmlinuz boot=live components splash quiet \
        nomodeset xforcevesa \
        live-config.hostname=raksha
  initrd /boot/initrd
}
EOF

# ══════════════════════════════════════════════════════════════════════
# STAGE 10: Set final ownership
# ══════════════════════════════════════════════════════════════════════

section "Stage 10: Setting ownership"

R="${WORK_DIR}/rootfs"

chown -R 1000:1000 \
  "${R}/var/lib/ash" \
  "${R}/var/lib/raksha" \
  "${R}/opt/ash-core" \
  "${R}/opt/raksha-dashboard" \
  "${R}/home/ravan" \
  2>/dev/null || true

# Log files — create and own them
touch \
  "${R}/var/lib/ash/logs/ash.log" \
  "${R}/var/lib/ash/logs/harness.log" \
  "${R}/var/lib/ash/logs/interface.log" \
  "${R}/var/lib/ash/logs/heartbeat-latest.json"
chown 1000:1000 "${R}/var/lib/ash/logs/"* 2>/dev/null || true

# Named pipe for IPC
[ -p "${R}/var/lib/ash/agent.pipe" ] || \
  mknod "${R}/var/lib/ash/agent.pipe" p 2>/dev/null || true
chmod 666 "${R}/var/lib/ash/agent.pipe" 2>/dev/null || true
chown 1000:1000 "${R}/var/lib/ash/agent.pipe" 2>/dev/null || true

log "Ownership set"

# ══════════════════════════════════════════════════════════════════════
# STAGE 11: Cleanup, unmount, squashfs
# ══════════════════════════════════════════════════════════════════════

section "Stage 11: Building squashfs"

R="${WORK_DIR}/rootfs"

# Remove build artifacts
rm -rf "${R}/tmp/"*
rm -rf "${R}/var/cache/apt/"*
rm -rf "${R}/var/lib/apt/lists/"*
rm -f  "${R}/etc/resolv.conf"

# Unmount pseudo-filesystems
for mnt in proc sys dev/pts dev; do
  umount -l "${R}/${mnt}" 2>/dev/null || true
done

log "Building squashfs (this takes 10-30 min)..."
mkdir -p "${WORK_DIR}/iso/live"

mksquashfs "${R}" "${WORK_DIR}/iso/live/filesystem.squashfs" \
  -comp xz \
  -b 1M \
  -Xdict-size 100% \
  -no-recovery \
  -e "${WORK_DIR}/iso/live/filesystem.squashfs" \
  2>&1 | tail -5

SQUASH_SIZE=$(du -sh "${WORK_DIR}/iso/live/filesystem.squashfs" | cut -f1)
log "Squashfs built: ${SQUASH_SIZE}"

# Write filesystem size file (used by installer)
du -sx --block-size=1 "${R}" | cut -f1 > "${WORK_DIR}/iso/live/filesystem.size"

# ══════════════════════════════════════════════════════════════════════
# STAGE 12: Assemble and build ISO
# ══════════════════════════════════════════════════════════════════════

section "Stage 12: Assembling ISO"

# ── Kernel and initrd — use find, NOT glob (glob fails under Bedrock Linux) ──
VMLINUZ=$(find "${R}/boot" -maxdepth 1 -name "vmlinuz-*" | sort -V | tail -1)
INITRD=$(find  "${R}/boot" -maxdepth 1 -name "initrd.img-*" | sort -V | tail -1)

if [ -z "${VMLINUZ}" ] || [ -z "${INITRD}" ]; then
  warn "Kernel not found in rootfs/boot — kernel may have failed to install in chroot"
  warn "(Common on Bedrock Linux — using recover-stage12.sh to extract from squashfs)"
  bash "$(dirname "$0")/recover-stage12.sh"
  exit $?
fi

log "  Kernel : $(basename ${VMLINUZ})"
log "  Initrd : $(basename ${INITRD})"
cp "${VMLINUZ}" "${WORK_DIR}/iso/boot/vmlinuz"
cp "${INITRD}"  "${WORK_DIR}/iso/boot/initrd"

# GRUB theme from rootfs into ISO boot dir (best-effort)
if [ -d "${R}/boot/grub/themes/raksha" ]; then
  mkdir -p "${WORK_DIR}/iso/boot/grub/themes"
  cp -r "${R}/boot/grub/themes/raksha" "${WORK_DIR}/iso/boot/grub/themes/"
fi


# Build ISO
log "Assembling ISO with grub-mkrescue..."
mkdir -p "${OUTPUT_DIR}"
grub-mkrescue \
  -o "${OUTPUT_DIR}/${ISO_FILE}" \
  "${WORK_DIR}/iso" \
  --fonts="" --locales="" --themes="" \
  2>&1 | tail -5

# ══════════════════════════════════════════════════════════════════════
# DONE
# ══════════════════════════════════════════════════════════════════════

ISO_SIZE=$(du -sh "${OUTPUT_DIR}/${ISO_FILE}" | cut -f1)

section "BUILD COMPLETE"
log "══════════════════════════════════════════════════════"
log "  Raksha OS v1.0 ISO Build Complete"
log "  File    : ${OUTPUT_DIR}/${ISO_FILE}"
log "  Size    : ${ISO_SIZE}"
log "  Squashfs: ${SQUASH_SIZE}"
log ""
log "  What's inside:"
log "    ✓ Debian 13 Trixie + KDE Plasma"
log "    ✓ Ash cognitive core (agent-loop, heartbeat, dreaming)"
log "    ✓ Raksha Harness :8890"
log "    ✓ Dashboard :8889"
log "    ✓ Voice interface :8888 (Whisper + Piper)"
log "    ✓ 1500+ skills (Antigravity bundles)"
log "    ✓ All LLM models (Gemma 4, Nemotron, UI-TARS)"
log "    ✓ Piper TTS (ryan-high + amy-medium)"
log "    ✓ WhatsApp + Telegram gateways"
log "    ✓ Calamares installer"
log "    ✓ All services pre-enabled"
log "    ✓ Full Raksha branding"
log ""
log "  Install:"
log "    sudo dd if=${OUTPUT_DIR}/${ISO_FILE} of=/dev/sdX bs=4M status=progress"
log ""
log "  Test:"
log "    qemu-system-x86_64 -m 8G -enable-kvm -cdrom ${OUTPUT_DIR}/${ISO_FILE} -boot d"
log "══════════════════════════════════════════════════════"
