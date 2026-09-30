
# ══════════════════════════════════════════════════════════════
# INSTALL WHATSAPP GATEWAY
# ══════════════════════════════════════════════════════════════

log "Installing WhatsApp gateway..."

# Copy gateway files
mkdir -p "${WORK_DIR}/rootfs/opt/ash-core/gateways"
cp -a /opt/ash-core/gateways/* "${WORK_DIR}/rootfs/opt/ash-core/gateways/" 2>/dev/null || true

# WhatsApp auth (sessions, state)
mkdir -p "${WORK_DIR}/rootfs/var/lib/ash/identity/whatsapp_auth"
if [ -d /var/lib/ash/identity/whatsapp_auth ]; then
    cp -a /var/lib/ash/identity/whatsapp_auth/* "${WORK_DIR}/rootfs/var/lib/ash/identity/whatsapp_auth/" 2>/dev/null || true
fi

# WhatsApp baileys library
if [ -d /var/lib/ash/identity/whatsapp_baileys ]; then
    cp -a /var/lib/ash/identity/whatsapp_baileys "${WORK_DIR}/rootfs/var/lib/ash/identity/" 2>/dev/null || true
fi

# Ensure node is available
chroot "${WORK_DIR}/rootfs" /bin/bash -c "
    if ! command -v node &>/dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt-get install -y nodejs
    fi
"

# WhatsApp setup script (first boot)
cat > "${WORK_DIR}/rootfs/usr/local/bin/raksha-whatsapp-setup" << 'WSEOF'
#!/bin/bash
# WhatsApp setup — run on first boot or from settings
echo "🜂 Raksha OS — WhatsApp Gateway Setup"
echo ""
echo "This will pair your phone with Ash via WhatsApp."
echo ""
echo "1. Open WhatsApp on your phone"
echo "2. Go to Settings → Linked Devices → Link a Device"
echo "3. Scan the QR code that will appear"
echo ""
read -p "Press Enter to generate QR code..."

# Start the gateway temporarily to generate QR
node /opt/ash-core/gateways/whatsapp-gateway.js &
GATEWAY_PID=$!

# Wait for QR code
sleep 5
echo ""
echo "After scanning, the connection will be saved automatically."
echo "Press Enter when done..."
read

kill $GATEWAY_PID 2>/dev/null
echo "WhatsApp gateway configured!"
WSEOF
chmod +x "${WORK_DIR}/rootfs/usr/local/bin/raksha-whatsapp-setup"

# ══════════════════════════════════════════════════════════════
# INSTALL TELEGRAM GATEWAY
# ══════════════════════════════════════════════════════════════

log "Installing Telegram gateway..."

# Copy Telegram gateway
if [ -f /opt/ash-core/gateways/telegram-gateway.py ]; then
    cp /opt/ash-core/gateways/telegram-gateway.py "${WORK_DIR}/rootfs/opt/ash-core/gateways/"
fi

# Telegram setup script
cat > "${WORK_DIR}/rootfs/usr/local/bin/raksha-telegram-setup" << 'TSEOF'
#!/bin/bash
# Telegram setup
echo "🜂 Raksha OS — Telegram Gateway Setup"
echo ""
echo "1. Open Telegram and search for @BotFather"
echo "2. Send /newbot and follow instructions"
echo "3. Copy the bot token"
echo ""
read -p "Paste your Telegram bot token: " TOKEN

# Update service environment
sed -i "s/BOT_TOKEN=.*/BOT_TOKEN=${TOKEN}/" /etc/systemd/system/ash-telegram.service
systemctl daemon-reload
echo "Telegram gateway configured!"
TSEOF
chmod +x "${WORK_DIR}/rootfs/usr/local/bin/raksha-telegram-setup"

# ══════════════════════════════════════════════════════════════
# INSTALL VOICE MODELS (Piper TTS + Whisper STT)
# ══════════════════════════════════════════════════════════════

log "Installing voice models (682MB)..."

mkdir -p "${WORK_DIR}/rootfs/home/ravan/raksha-vocie"

# Copy Piper voice models
for voice in en_US-amy-medium.onnx en_US-ryan-high.onnx; do
    if [ -f "/home/ravan/raksha-vocie/${voice}" ]; then
        cp "/home/ravan/raksha-vocie/${voice}" "${WORK_DIR}/rootfs/home/ravan/raksha-vocie/"
        log "  Installed: ${voice} ($(du -h /home/ravan/raksha-vocie/${voice} | cut -f1))"
    fi
    if [ -f "/home/ravan/raksha-vocie/${voice}.json" ]; then
        cp "/home/raksha-vocie/${voice}.json" "${WORK_DIR}/rootfs/home/ravan/raksha-vocie/" 2>/dev/null || true
    fi
done

# Copy Piper binary
if [ -f /home/ravan/raksha-vocie/piper ]; then
    cp /home/ravan/raksha-vocie/piper "${WORK_DIR}/rootfs/home/ravan/raksha-vocie/"
fi

# Copy voice Python script
if [ -f /home/ravan/raksha-vocie/raksha-voice.py ]; then
    cp /home/ravan/raksha-vocie/raksha-voice.py "${WORK_DIR}/rootfs/home/ravan/raksha-vocie/"
fi

# Install faster-whisper via pip in the ISO
chroot "${WORK_DIR}/rootfs" /bin/bash -c "
    pip3 install --break-system-packages faster-whisper 2>/dev/null || true
"

# Download Whisper base model (small, ~140MB)
log "Downloading Whisper base model..."
chroot "${WORK_DIR}/rootfs" /bin/bash -c "
    mkdir -p /home/ravan/raksha-vocie/whisper-models
    # Use the smallest model that works well
    if [ ! -f /home/ravan/raksha-vocie/whisper-models/base.en.pt ]; then
        python3 -c "
import urllib.request
url = 'https://hf-mirror.com/openai/whisper/resolve/main/base.en.pt'
path = '/home/ravan/raksha-vocie/whisper-models/base.en.pt'
print(f'Downloading {url}...')
urllib.request.urlretrieve(url, path)
print(f'Saved to {path}')
" 2>/dev/null || echo 'Whisper download skipped (no network)'
    fi
"

# ══════════════════════════════════════════════════════════════
# INSTALL HONCHO CLI
# ══════════════════════════════════════════════════════════════

log "Installing Honcho CLI..."

chroot "${WORK_DIR}/rootfs" /bin/bash -c "
    if ! command -v honcho &>/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="\$HOME/.local/bin:\$PATH"
        uv tool install honcho-cli
        # Install click dependency
        /root/.local/share/uv/python/cpython-3.11.*/bin/pip install click --break-system-packages 2>/dev/null || true
    fi
"

# ══════════════════════════════════════════════════════════════
# GATEWAY SETUP IN FIRST BOOT
# ══════════════════════════════════════════════════════════════

# Update raksha-init.sh to include gateway setup
cat >> "${WORK_DIR}/rootfs/usr/local/bin/raksha-init.sh" << 'INITEOF'

# ── 12. Gateway Setup ──
echo "[INIT] Setting up messaging gateways..."
echo "  WhatsApp: Run 'raksha-whatsapp-setup' to pair your phone"
echo "  Telegram: Run 'raksha-telegram-setup' with your bot token"
echo "  Voice: Piper TTS + Whisper STT ready"
INITEOF

log "Gateways installed."
