#!/bin/bash
# ══════════════════════════════════════════════════════════
# Raksha OS — Post-Install Fix Script
# Run this on the INSTALLED Raksha OS machine (not build machine)
# Fixes: llama not starting, WhatsApp QR, Ash connection
# Usage: sudo bash raksha-postinstall-fix.sh
# ══════════════════════════════════════════════════════════
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

echo "══════════════════════════════════════════════════════"
echo "  Raksha OS — Post-Install Fix"
echo "══════════════════════════════════════════════════════"
echo ""

# ── 1. Fix raksha-cognitive.service (remove Bedrock strat) ──
echo "── [1/5] Fixing Ash cognitive engine (llama-server) ──"

LLAMA_BIN=""
for b in /usr/local/bin/llama-server /home/ravan/llama.cpp/build/bin/llama-server; do
  [ -f "$b" ] && LLAMA_BIN="$b" && break
done
[ -z "${LLAMA_BIN}" ] && die "llama-server not found. Is the ISO correctly installed?"
log "llama-server binary: ${LLAMA_BIN}"

MODEL_PATH="/home/ravan/llama.cpp/models/gemma-4-E2B_q4_0-it.gguf"
[ -f "${MODEL_PATH}" ] || die "Gemma model not found at ${MODEL_PATH}"
log "Model found: $(du -sh ${MODEL_PATH} | cut -f1)"

# Auto-detect GPU
GPU_LAYERS=0
if nvidia-smi &>/dev/null; then
  GPU_LAYERS=99
  log "NVIDIA GPU detected — using ${GPU_LAYERS} GPU layers"
else
  log "No NVIDIA GPU — using CPU inference"
fi

cat > /etc/systemd/system/raksha-cognitive.service << EOF
[Unit]
Description=Ash Mind — llama.cpp Gemma 4 Inference Server
After=network.target

[Service]
Type=simple
User=ravan
Group=ravan
Environment=HOME=/home/ravan
ExecStart=${LLAMA_BIN} --model ${MODEL_PATH} --ctx-size 4096 --n-gpu-layers ${GPU_LAYERS} --host 127.0.0.1 --port 8080 --log-disable
Restart=always
RestartSec=10
TimeoutStartSec=180
StandardOutput=append:/var/lib/ash/logs/cognitive.log
StandardError=append:/var/lib/ash/logs/cognitive.log

[Install]
WantedBy=multi-user.target
EOF
log "raksha-cognitive.service updated (no strat, GPU=${GPU_LAYERS})"

# ── 2. Fix ash-interface.service WorkingDirectory ──
echo ""
echo "── [2/5] Fixing Ash interface (chat UI on port 8888) ──"

IFACE_DIR=""
for d in /home/ravan/ash-interface /opt/ash-core/interface; do
  [ -f "${d}/server.py" ] && IFACE_DIR="${d}" && break
done

if [ -n "${IFACE_DIR}" ]; then
  sed -i "s|WorkingDirectory=.*|WorkingDirectory=${IFACE_DIR}|" \
    /etc/systemd/system/ash-interface.service
  sed -i "s|ExecStart=.*|ExecStart=/usr/bin/python3 ${IFACE_DIR}/server.py|" \
    /etc/systemd/system/ash-interface.service
  log "ash-interface.service → ${IFACE_DIR}/server.py"
else
  warn "ash-interface server.py not found — skipping"
fi

# ── 3. Fix WhatsApp bridge QR display ──
echo ""
echo "── [3/5] Fixing WhatsApp QR display ──"

BRIDGE_JS="/opt/ash-core/gateways/ash-whatsapp-bridge/bridge.js"
if [ -f "${BRIDGE_JS}" ]; then
  sed -i 's/printQRInTerminal: false/printQRInTerminal: true/' "${BRIDGE_JS}"
  log "WhatsApp bridge: printQRInTerminal → true"
else
  warn "bridge.js not found at ${BRIDGE_JS}"
fi

# ── 4. Reload + restart all services ──
echo ""
echo "── [4/5] Reloading and starting services ──"

systemctl daemon-reload

# Start cognitive first and wait
info "Starting llama-server (Gemma 4)... this takes ~30 seconds"
systemctl enable --now raksha-cognitive.service
sleep 5

# Check if it's up
for i in $(seq 1 12); do
  if curl -sf http://127.0.0.1:8080/health &>/dev/null; then
    log "llama-server responding on port 8080 ✓"
    break
  fi
  [ "$i" -eq 12 ] && warn "llama-server not responding yet (may still be loading model)"
  sleep 5
done

# Start remaining services
for svc in \
  ash-interface \
  raksha-harness \
  raksha-dashboard \
  ash-core.timer \
  ash-heartbeat.timer \
  ash-memory.timer \
  ash-dreaming.timer \
  ash-defibrillator; do
  systemctl enable --now "${svc}" 2>/dev/null && log "  started: ${svc}" || warn "  skipped: ${svc}"
done

# ── 5. Print access info ──
echo ""
echo "── [5/5] How to connect with Ash ──"
echo ""
echo "══════════════════════════════════════════════════════"
echo "  CHAT WITH ASH:"
echo ""
echo "  Open browser (Firefox) →  http://localhost:8888"
echo "  Dashboard              →  http://localhost:8889"
echo "  Harness (API)          →  http://localhost:8890"
echo ""
echo "  WHATSAPP SETUP:"
echo "  1. Run: sudo systemctl start ash-whatsapp-bridge"
echo "  2. Run: journalctl -u ash-whatsapp-bridge -f"
echo "  3. Scan the QR code shown in the terminal with WhatsApp"
echo "     (WhatsApp → Linked Devices → Link a Device)"
echo "  4. After scan: sudo systemctl enable ash-whatsapp-bridge"
echo ""
echo "══════════════════════════════════════════════════════"
echo ""
log "Done. Ash is ready."
