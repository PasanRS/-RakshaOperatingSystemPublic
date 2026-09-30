#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Raksha OS — Ash Runtime Installer
# Called from build-iso-v2.sh inside the chroot to set up the full Ash stack.
# Also usable standalone for manual installs: sudo bash install-ash-runtime.sh
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/ash-core/repo}"
ASH_HOME="${ASH_HOME:-/var/lib/ash}"
OPT_BASE="/opt/ash-core"
DASH_DIR="/opt/raksha-dashboard"
LOG="/var/log/raksha-install.log"
ASH_USER="${ASH_USER:-ravan}"

mkdir -p "$(dirname "$LOG")"
log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }
die() { echo "[FATAL] $1" >&2; exit 1; }

log "═══════════════════════════════════════════════"
log "  Raksha OS — Ash Runtime Installer v1.0"
log "  REPO_DIR  : ${REPO_DIR}"
log "  ASH_USER  : ${ASH_USER}"
log "═══════════════════════════════════════════════"

# ── 1. Directory structure ──────────────────────────────────────────────────
log "[1/10] Creating directory structure..."
mkdir -p \
  "${OPT_BASE}/harness" \
  "${OPT_BASE}/voice/piper" \
  "${OPT_BASE}/gateways/ash-whatsapp-bridge" \
  "${OPT_BASE}/reflexes" \
  "${DASH_DIR}" \
  "${ASH_HOME}/identity" \
  "${ASH_HOME}/memory" \
  "${ASH_HOME}/logs" \
  "${ASH_HOME}/knowledge" \
  "${ASH_HOME}/tasks" \
  "${ASH_HOME}/harness" \
  "${ASH_HOME}/creations" \
  "${ASH_HOME}/screenshots" \
  /usr/local/lib/ash \
  /usr/local/bin
log "  ✓ directories created"

# ── 2. Copy Ash core ────────────────────────────────────────────────────────
log "[2/10] Installing Ash core..."
cp "${REPO_DIR}/src/ash/agent-loop.py"  /usr/local/lib/ash/
cp "${REPO_DIR}/src/ash/ash"            /usr/local/bin/raksha-ash
cp "${REPO_DIR}/src/ash/ash-heartbeat"  /usr/local/bin/ash-heartbeat  2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-memory"     /usr/local/bin/ash-memory     2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-status"     /usr/local/bin/ash-status     2>/dev/null || true
cp "${REPO_DIR}/src/ash/ash-talk"       /usr/local/bin/ash-talk       2>/dev/null || true
chmod +x /usr/local/bin/raksha-ash /usr/local/bin/ash-heartbeat 2>/dev/null || true
log "  ✓ Ash core installed"

# ── 3. Copy reflexes ────────────────────────────────────────────────────────
log "[3/10] Installing reflexes..."
cp "${REPO_DIR}/src/reflexes/heartbeat.py"     "${OPT_BASE}/reflexes/"
cp "${REPO_DIR}/src/reflexes/dreaming.py"      "${OPT_BASE}/reflexes/"
cp "${REPO_DIR}/src/reflexes/defibrillator.sh" "${OPT_BASE}/reflexes/"
chmod +x "${OPT_BASE}/reflexes/defibrillator.sh"
log "  ✓ reflexes installed"

# ── 4. Install Harness ──────────────────────────────────────────────────────
log "[4/10] Installing Raksha Harness..."
cp "${REPO_DIR}/src/harness/harness.py"        "${OPT_BASE}/harness/"
cp "${REPO_DIR}/src/harness/harness_client.py" "${OPT_BASE}/harness/"

if [ ! -f "${OPT_BASE}/harness/venv/bin/python" ]; then
  log "  Creating Harness venv..."
  python3 -m venv "${OPT_BASE}/harness/venv"
  "${OPT_BASE}/harness/venv/bin/pip" install --quiet \
    "fastapi>=0.115" "uvicorn[standard]>=0.32" "httpx>=0.28" "pydantic>=2.0"
  log "  ✓ Harness venv created"
else
  log "  ✓ Harness venv already exists"
fi
log "  ✓ Harness installed"

# ── 5. Install Dashboard ────────────────────────────────────────────────────
log "[5/10] Installing Dashboard..."
cp "${REPO_DIR}/src/dashboard/main.py" "${DASH_DIR}/"

if [ ! -f "${DASH_DIR}/venv/bin/python" ]; then
  log "  Creating Dashboard venv..."
  python3 -m venv "${DASH_DIR}/venv"
  "${DASH_DIR}/venv/bin/pip" install --quiet \
    "fastapi>=0.115" "uvicorn[standard]>=0.32" "httpx>=0.28" "psutil>=6.0"
  log "  ✓ Dashboard venv created"
else
  log "  ✓ Dashboard venv already exists"
fi
log "  ✓ Dashboard installed"

# ── 6. Install Voice Interface ──────────────────────────────────────────────
log "[6/10] Installing Voice Interface..."
cp "${REPO_DIR}/src/interface/server.py" "${OPT_BASE}/voice/"

# Copy Piper binary and libraries from MODELS_DIR or live system
PIPER_SRC="${MODELS_DIR:-/home/ravan/raksha-vocie}/piper"
VOICE_SRC="${MODELS_DIR:-/home/ravan/raksha-vocie}"

if [ -d "${PIPER_SRC}" ]; then
  cp -r "${PIPER_SRC}"/* "${OPT_BASE}/voice/piper/"
  log "  ✓ Piper binary installed"
else
  log "  ⚠ Piper binary not found at ${PIPER_SRC} — voice TTS will not work"
fi

# Copy voice models
for model in en_US-ryan-high.onnx en_US-ryan-high.onnx.json \
             en_US-amy-medium.onnx en_US-amy-medium.onnx.json; do
  if [ -f "${VOICE_SRC}/${model}" ]; then
    cp "${VOICE_SRC}/${model}" "${OPT_BASE}/voice/"
    log "  ✓ ${model}"
  fi
done

# Copy espeak-ng data (needed by piper)
if [ -d "${PIPER_SRC}/espeak-ng-data" ]; then
  cp -r "${PIPER_SRC}/espeak-ng-data" "${OPT_BASE}/voice/piper/"
fi

if [ ! -f "${OPT_BASE}/voice/venv/bin/python" ]; then
  log "  Creating Voice venv..."
  python3 -m venv "${OPT_BASE}/voice/venv"
  "${OPT_BASE}/voice/venv/bin/pip" install --quiet \
    "faster-whisper>=1.0" "sounddevice>=0.4" "numpy>=1.24" "pynput>=1.7"
  log "  ✓ Voice venv created"
else
  log "  ✓ Voice venv already exists"
fi
log "  ✓ Voice interface installed"

# ── 7. Install Gateways ─────────────────────────────────────────────────────
log "[7/10] Installing Gateways..."
if [ -d "${REPO_DIR}/src/gateways" ]; then
  cp "${REPO_DIR}/src/gateways/ash-whatsapp-poller.py" "${OPT_BASE}/gateways/" 2>/dev/null || true
  cp "${REPO_DIR}/src/gateways/telegram-gateway.py"    "${OPT_BASE}/gateways/" 2>/dev/null || true
  cp "${REPO_DIR}/src/gateways/whatsapp-gateway.js"    "${OPT_BASE}/gateways/" 2>/dev/null || true
  cp "${REPO_DIR}/src/gateways/package.json"           "${OPT_BASE}/gateways/" 2>/dev/null || true
  if [ -d "${REPO_DIR}/src/gateways/ash-whatsapp-bridge" ]; then
    cp -r "${REPO_DIR}/src/gateways/ash-whatsapp-bridge"/* \
          "${OPT_BASE}/gateways/ash-whatsapp-bridge/"
  fi
  log "  ✓ Gateways installed"
else
  log "  ⚠ Gateways dir not found in repo"
fi

# ── 8. Ash Identity ─────────────────────────────────────────────────────────
log "[8/10] Installing Ash identity..."
if [ -f "${REPO_DIR}/config/ash/SOUL.md" ]; then
  cp "${REPO_DIR}/config/ash/SOUL.md"   "${ASH_HOME}/identity/"
  log "  ✓ SOUL.md"
fi
if [ -f "${REPO_DIR}/config/ash/USER.md" ]; then
  cp "${REPO_DIR}/config/ash/USER.md"   "${ASH_HOME}/identity/"
  log "  ✓ USER.md"
fi
if [ -f "${REPO_DIR}/config/ash/MEMORY.md" ]; then
  cp "${REPO_DIR}/config/ash/MEMORY.md" "${ASH_HOME}/memory/"
  log "  ✓ MEMORY.md"
fi

# Write clean .env (no Honcho, no real API keys — user fills in)
cat > "${ASH_HOME}/identity/.env" << 'ENV_EOF'
# Ash — Runtime Configuration
# Edit this file to add your API keys

# Local inference
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
log "  ✓ identity installed"

# ── 9. Systemd services ─────────────────────────────────────────────────────
log "[9/10] Installing systemd services..."
SYSTEMD_SRC="${REPO_DIR}/systemd"
SYSTEMD_DST="/etc/systemd/system"

for unit in "${SYSTEMD_SRC}"/*.service "${SYSTEMD_SRC}"/*.timer; do
  [ -f "$unit" ] || continue
  cp "$unit" "${SYSTEMD_DST}/"
  log "  ✓ $(basename $unit)"
done

# Enable core services
systemctl daemon-reload 2>/dev/null || true

SERVICES_ENABLE=(
  raksha-harness.service
  raksha-dashboard.service
  ash-interface.service
  ash-defibrillator.service
  ash-heartbeat.timer
  ash-dreaming.timer
  ash-memory.timer
)

for svc in "${SERVICES_ENABLE[@]}"; do
  systemctl enable "$svc" 2>/dev/null && log "  ✓ enabled: $svc" \
    || log "  ⚠ could not enable $svc (may be normal in chroot)"
done

# Enable first-boot service if present
systemctl enable raksha-firstboot.service 2>/dev/null && log "  ✓ enabled: raksha-firstboot" \
  || log "  (raksha-firstboot.service not found — skipping)"

log "  ✓ services configured"

# ── 10. Ownership ───────────────────────────────────────────────────────────
log "[10/10] Setting ownership..."
chown -R "${ASH_USER}:${ASH_USER}" \
  "${OPT_BASE}" \
  "${DASH_DIR}" \
  "${ASH_HOME}" 2>/dev/null || true

# Log files: allow ravan to write
touch "${ASH_HOME}/logs/ash.log" \
      "${ASH_HOME}/logs/harness.log" \
      "${ASH_HOME}/logs/interface.log" \
      "${ASH_HOME}/logs/heartbeat.log" \
      "${ASH_HOME}/logs/dashboard.log"
chown "${ASH_USER}:${ASH_USER}" "${ASH_HOME}/logs/"*.log 2>/dev/null || true
log "  ✓ ownership set"

log ""
log "═══════════════════════════════════════════════"
log "  Ash Runtime Install Complete"
log "  Services enabled: ${#SERVICES_ENABLE[@]}"
log "  Harness : ${OPT_BASE}/harness/"
log "  Voice   : ${OPT_BASE}/voice/"
log "  Dashboard: ${DASH_DIR}/"
log "  Identity: ${ASH_HOME}/identity/"
log "═══════════════════════════════════════════════"
