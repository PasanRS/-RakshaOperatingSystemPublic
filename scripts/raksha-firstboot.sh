#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Raksha OS — First Boot Setup
# Runs ONCE on first boot after Calamares installation.
# Everything is pre-installed — this script just initialises and verifies.
# No internet required. No downloads. Just wake Ash up.
# ═══════════════════════════════════════════════════════════════════════════
set -euo pipefail

LOG="/var/log/raksha-firstboot.log"
INSTALLED_MARKER="/var/lib/raksha/installed"
STAMP="/var/lib/raksha/.first-boot-done"
ASH_HOME="/var/lib/ash"
OPT="/opt/ash-core"
DASH_DIR="/opt/raksha-dashboard"

mkdir -p "$(dirname "$LOG")" /var/lib/raksha

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG"
}

banner() {
    echo ""
    echo "╔═══════════════════════════════════════════════════════════════╗"
    echo "║                                                               ║"
    echo "║   ██████╗  █████╗ ██╗  ██╗███████╗██╗  ██╗  █████╗          ║"
    echo "║   ██╔══██╗██╔══██╗██║ ██╔╝██╔════╝██║  ██║ ██╔══██╗         ║"
    echo "║   ██████╔╝███████║█████╔╝ ███████╗███████║ ███████║         ║"
    echo "║   ██╔══██╗██╔══██║██╔═██╗ ╚════██║██╔══██║ ██╔══██║         ║"
    echo "║   ██║  ██║██║  ██║██║  ██╗███████║██║  ██║ ██║  ██║         ║"
    echo "║   ╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝         ║"
    echo "║                                                               ║"
    echo "║            R A K S H A   O S   —   A W A K E N I N G        ║"
    echo "║                                                               ║"
    echo "╚═══════════════════════════════════════════════════════════════╝"
    echo ""
}

# ── 1. Hardware check ────────────────────────────────────────────────────
check_hardware() {
    log "[1/8] Hardware detection..."

    # GPU
    if command -v nvidia-smi &>/dev/null && nvidia-smi &>/dev/null 2>&1; then
        GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        log "  ✓ NVIDIA GPU: ${GPU}"
    elif lspci 2>/dev/null | grep -qi "amd.*radeon"; then
        log "  ⚠ AMD GPU detected (NVIDIA recommended for full AI performance)"
    else
        log "  ⚠ No discrete GPU — Ash will use CPU inference (slower but functional)"
    fi

    # RAM
    TOTAL_RAM=$(grep MemTotal /proc/meminfo | awk '{print int($2/1024/1024)}')
    log "  RAM: ${TOTAL_RAM}GB detected"
    [ "${TOTAL_RAM}" -lt 4 ] && log "  ⚠ Low RAM — voice + LLM may be slow"

    # Audio
    if command -v pactl &>/dev/null && pactl info &>/dev/null 2>&1; then
        log "  ✓ Audio: PipeWire/PulseAudio active"
    elif aplay -l &>/dev/null 2>&1; then
        log "  ✓ Audio: ALSA available"
    else
        log "  ⚠ Audio subsystem not ready — voice interface may need manual setup"
    fi

    # Disk
    FREE=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    log "  Disk: ${FREE}GB free on /"
}

# ── 2. Verify core files ─────────────────────────────────────────────────
verify_install() {
    log "[2/8] Verifying installation..."
    local ok=true

    check_file() {
        if [ -f "$1" ]; then
            log "  ✓ $1"
        else
            log "  ✗ MISSING: $1"
            ok=false
        fi
    }
    check_dir() {
        if [ -d "$1" ]; then
            log "  ✓ $1/"
        else
            log "  ✗ MISSING: $1/"
            ok=false
        fi
    }

    check_file "/usr/local/lib/ash/agent-loop.py"
    check_file "${OPT}/harness/harness.py"
    check_dir  "${OPT}/harness/venv"
    check_file "${DASH_DIR}/main.py"
    check_dir  "${DASH_DIR}/venv"
    check_file "${OPT}/voice/server.py"
    check_dir  "${OPT}/voice/venv"
    check_file "${OPT}/voice/en_US-ryan-high.onnx"
    check_file "${OPT}/voice/piper/piper"
    check_dir  "${ASH_HOME}/identity"
    check_file "${ASH_HOME}/identity/SOUL.md"
    check_file "${ASH_HOME}/identity/.env"

    # Check models
    MODEL_FOUND=false
    for model in gemma-4-E2B_q4_0-it.gguf NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf; do
        if [ -f "/home/ravan/llama.cpp/models/${model}" ]; then
            SZ=$(du -sh "/home/ravan/llama.cpp/models/${model}" | cut -f1)
            log "  ✓ Model: ${model} (${SZ})"
            MODEL_FOUND=true
        fi
    done
    $MODEL_FOUND || log "  ✗ No LLM models found — Ash core inference will not work"

    # Skills
    if [ -f "${ASH_HOME}/skills/skill_index.json" ]; then
        SKILL_COUNT=$(python3 -c "import json; d=json.load(open('${ASH_HOME}/skills/skill_index.json')); print(len(d.get('skills',{})))" 2>/dev/null || echo "?")
        log "  ✓ Skills: ${SKILL_COUNT} loaded"
    else
        log "  ⚠ Skill index not found — skills unavailable"
    fi

    $ok && log "  ✓ Installation verification passed" || \
           log "  ⚠ Some files missing — check log"
}

# ── 3. Initialise ASH_HOME structure ────────────────────────────────────
init_ash_home() {
    log "[3/8] Initialising Ash home..."

    mkdir -p \
        "${ASH_HOME}/identity" \
        "${ASH_HOME}/memory" \
        "${ASH_HOME}/logs" \
        "${ASH_HOME}/knowledge" \
        "${ASH_HOME}/tasks" \
        "${ASH_HOME}/harness" \
        "${ASH_HOME}/creations" \
        "${ASH_HOME}/screenshots" \
        "${ASH_HOME}/skills" \
        /var/lib/raksha \
        /var/lib/helayidaya/reports \
        /etc/raksha

    # Create log files
    touch \
        "${ASH_HOME}/logs/ash.log" \
        "${ASH_HOME}/logs/harness.log" \
        "${ASH_HOME}/logs/interface.log" \
        "${ASH_HOME}/logs/heartbeat.log" \
        "${ASH_HOME}/logs/dashboard.log" \
        "${ASH_HOME}/logs/heartbeat-latest.json"

    # Named pipe (IPC between services)
    if [ ! -p "${ASH_HOME}/agent.pipe" ]; then
        mkfifo "${ASH_HOME}/agent.pipe" 2>/dev/null || true
        chmod 666 "${ASH_HOME}/agent.pipe"
    fi

    # Initialise heartbeat JSON
    cat > "${ASH_HOME}/logs/heartbeat-latest.json" << 'JSON'
{"status": "initialising", "ts": "boot", "cpu": {"percent": 0}, "ram": {"percent": 0}, "disk": {"free_gb": 0}}
JSON

    # Initialise SQLite DBs (Ash will do this properly on first run)
    python3 -c "
import sqlite3, pathlib
db = pathlib.Path('${ASH_HOME}/memory/sessions.db')
db.parent.mkdir(parents=True, exist_ok=True)
conn = sqlite3.connect(str(db))
conn.execute('''CREATE TABLE IF NOT EXISTS sessions (
    id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL,
    source TEXT DEFAULT \"user\", input TEXT, response TEXT,
    tools_used TEXT, significant INTEGER DEFAULT 0)''')
conn.commit(); conn.close()

db2 = pathlib.Path('${ASH_HOME}/tasks/queue.db')
db2.parent.mkdir(parents=True, exist_ok=True)
conn2 = sqlite3.connect(str(db2))
conn2.execute('''CREATE TABLE IF NOT EXISTS task_queue (
    id INTEGER PRIMARY KEY, created_at TEXT NOT NULL,
    type TEXT NOT NULL, content TEXT NOT NULL,
    source TEXT DEFAULT \"system\", priority INTEGER DEFAULT 5,
    status TEXT DEFAULT \"pending\", processed_at TEXT)''')
conn2.commit(); conn2.close()
print('DBs initialised')
" 2>/dev/null && log "  ✓ Memory databases initialised" || log "  ⚠ DB init skipped (will init on first Ash run)"

    # Set ownership only on mutable state. Immutable runtimes, models, skills,
    # and virtual environments under /opt are owned during image construction.
    ASH_USER=$(id -nu 1000 2>/dev/null || echo "ravan")
    local state_dir
    for state_dir in \
        "${ASH_HOME}/identity" \
        "${ASH_HOME}/memory" \
        "${ASH_HOME}/logs" \
        "${ASH_HOME}/tasks" \
        "${ASH_HOME}/harness" \
        "${ASH_HOME}/creations" \
        "${ASH_HOME}/screenshots" \
        /var/lib/raksha/logs \
        /var/lib/raksha/gateways \
        /var/lib/raksha/sessions \
        /var/lib/helayidaya/reports; do
        mkdir -p "${state_dir}"
        chown -R "${ASH_USER}:${ASH_USER}" "${state_dir}" 2>/dev/null || true
    done

    log "  ✓ Ash home initialised (user: ${ASH_USER})"
}

# ── 4. Enable and start all services ────────────────────────────────────
start_services() {
    log "[4/8] Starting Ash services..."

    systemctl daemon-reload 2>/dev/null || true

    # Services to enable (already pre-enabled in image, but re-enable to be safe)
    local ENABLE=(
        raksha-harness.service
        raksha-dashboard.service
        ash-interface.service
        ash-defibrillator.service
        ash-heartbeat.timer
        ash-dreaming.timer
        ash-memory.timer
    )

    for svc in "${ENABLE[@]}"; do
        if [ -f "/etc/systemd/system/${svc}" ]; then
            systemctl enable "${svc}" 2>/dev/null || true
        fi
    done

    # Start in dependency order
    # 1. Harness first
    if systemctl is-enabled raksha-harness.service &>/dev/null; then
        systemctl start raksha-harness.service 2>/dev/null || true
        sleep 2
        if systemctl is-active raksha-harness.service &>/dev/null; then
            log "  ✓ Raksha Harness :8890 — active"
        else
            log "  ⚠ Harness failed to start — check: journalctl -u raksha-harness"
        fi
    fi

    # 2. Dashboard
    if systemctl is-enabled raksha-dashboard.service &>/dev/null; then
        systemctl start raksha-dashboard.service 2>/dev/null || true
        sleep 1
        log "  ✓ Dashboard :8889 — started"
    fi

    # 3. Voice interface (needs X11 for audio — start after desktop)
    if systemctl is-enabled ash-interface.service &>/dev/null; then
        systemctl start ash-interface.service 2>/dev/null || true
        log "  ✓ Voice Interface :8888 — started"
    fi

    # 4. Timers (background cognitive processes)
    for timer in ash-heartbeat.timer ash-dreaming.timer ash-memory.timer; do
        systemctl start "${timer}" 2>/dev/null || true
    done
    log "  ✓ Cognitive timers active"

    # 5. Defibrillator (watchdog)
    systemctl start ash-defibrillator.service 2>/dev/null || true
    log "  ✓ Defibrillator watchdog active"
}

# ── 5. Verify llama-server ───────────────────────────────────────────────
verify_llama() {
    log "[5/8] Verifying inference engine..."

    if ! command -v llama-server &>/dev/null; then
        log "  ✗ llama-server not found — check /usr/local/bin/llama-server"
        return
    fi

    # Check if a llama-server service is installed
    if [ -f "/etc/systemd/system/llama-server.service" ] || \
       [ -f "/etc/systemd/system/raksha-cognitive.service" ]; then
        SVC=$([ -f "/etc/systemd/system/raksha-cognitive.service" ] && \
              echo "raksha-cognitive" || echo "llama-server")
        systemctl enable "${SVC}.service" 2>/dev/null || true
        systemctl start  "${SVC}.service" 2>/dev/null || true
        log "  ✓ ${SVC} starting (model load takes 30-120s)"
    else
        log "  ⚠ No llama-server systemd unit found"
        log "    Ash will use NVIDIA cloud (NVIDIA_API_KEY in .env) as fallback"
    fi

    # Report model inventory
    MODEL_DIR="/home/ravan/llama.cpp/models"
    if [ -d "${MODEL_DIR}" ]; then
        MODEL_COUNT=$(find "${MODEL_DIR}" -name "*.gguf" 2>/dev/null | wc -l)
        MODEL_SIZE=$(du -sh "${MODEL_DIR}" 2>/dev/null | cut -f1)
        log "  ✓ ${MODEL_COUNT} models available (${MODEL_SIZE} total)"
    fi
}

# ── 6. WhatsApp gateway onboarding ──────────────────────────────────────
whatsapp_onboarding() {
    log "[6/8] WhatsApp gateway onboarding..."

    # Check if we have a terminal (interactive)
    if [ -t 1 ] && [ -f "/opt/ash-core/gateways/whatsapp-gateway.js" ]; then
        echo ""
        echo "┌─────────────────────────────────────────────────────┐"
        echo "│   WhatsApp Gateway Setup (Optional)                 │"
        echo "│   Connect your phone so Ash can receive messages    │"
        echo "└─────────────────────────────────────────────────────┘"
        echo ""
        read -t 15 -p "Set up WhatsApp now? [y/N]: " WA_ANSWER || WA_ANSWER="n"
        case "${WA_ANSWER,,}" in
            y|yes)
                log "  User chose WhatsApp setup"
                raksha-whatsapp-setup 2>&1 | tee -a "$LOG" || true
                ;;
            *)
                log "  WhatsApp setup skipped (run 'raksha-whatsapp-setup' later)"
                ;;
        esac
    else
        log "  WhatsApp setup: run 'raksha-whatsapp-setup' when ready"
    fi
}

# ── 7. Report health ─────────────────────────────────────────────────────
health_report() {
    log "[7/8] System health report..."

    # Harness
    if curl -sf http://localhost:8890/health &>/dev/null; then
        HARNESS_STATUS=$(curl -sf http://localhost:8890/health | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status','?'))" 2>/dev/null || echo "ok")
        log "  ✓ Harness: ${HARNESS_STATUS}"
    else
        log "  ⚠ Harness not responding (may still be starting)"
    fi

    # Dashboard
    curl -sf http://localhost:8889/ &>/dev/null && \
        log "  ✓ Dashboard: http://localhost:8889" || \
        log "  ⚠ Dashboard not yet ready"

    # Voice
    log "  Voice Interface: http://localhost:8888"
    log "  Hotkey: Ctrl+Shift+Space to wake Ash"

    # Skills
    if [ -f "${ASH_HOME}/skills/skill_index.json" ]; then
        SKILL_COUNT=$(python3 -c "
import json
d=json.load(open('${ASH_HOME}/skills/skill_index.json'))
print(len(d.get('skills',{})))
" 2>/dev/null || echo "?")
        log "  ✓ ${SKILL_COUNT} skills loaded"
    fi
}

# ── 8. Desktop welcome notification ─────────────────────────────────────
desktop_welcome() {
    log "[8/8] Sending desktop welcome..."

    # Write welcome file
    cat > /tmp/raksha-welcome.txt << 'WELCOME'
╔═══════════════════════════════════════════════════════════════╗
║              ◈  RAKSHA OS — ASH IS AWAKE  ◈                ║
╠═══════════════════════════════════════════════════════════════╣
║  Dashboard  : http://localhost:8889                          ║
║  Voice UI   : http://localhost:8888                          ║
║  Hotkey     : Ctrl+Shift+Space — Wake Ash                   ║
║                                                               ║
║  WhatsApp   : raksha-whatsapp-setup                         ║
║  Telegram   : raksha-telegram-setup                         ║
║  Status     : ash --status                                   ║
║                                                               ║
║  Welcome home.                                                ║
╚═══════════════════════════════════════════════════════════════╝
WELCOME

    # Desktop notification (if in graphical session)
    ASH_USER=$(id -nu 1000 2>/dev/null || echo "ravan")
    for DISPLAY_NUM in 0 1; do
        DBUS_ADDR=$(cat "/run/user/1000/dbus-session" 2>/dev/null || \
                    grep -r "DBUS_SESSION_BUS_ADDRESS" "/proc/$(pgrep -u 1000 plasmashell 2>/dev/null || echo 1)/environ" 2>/dev/null | \
                    tr '\0' '\n' | grep DBUS | head -1 || true)
        if sudo -u "${ASH_USER}" \
               DISPLAY=":${DISPLAY_NUM}" \
               ${DBUS_ADDR:+DBUS_SESSION_BUS_ADDRESS="${DBUS_ADDR}"} \
               notify-send \
               --app-name="Raksha OS" \
               --icon=dialog-information \
               "Ash is awake" \
               "Raksha OS cognitive systems online. Dashboard: localhost:8889" \
               2>/dev/null; then
            log "  ✓ Desktop notification sent"
            break
        fi
    done

    cat /tmp/raksha-welcome.txt | tee -a "$LOG"
}

# ══════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════

main() {
    banner
    log "Raksha OS First Boot — $(date)"
    log "Running as: $(whoami) on $(uname -r)"

    check_hardware
    verify_install
    init_ash_home
    start_services
    verify_llama
    whatsapp_onboarding
    health_report
    desktop_welcome

    # Completion means the preserved core services are actually reachable.
    # If one is still broken, leave the marker absent so firstboot retries.
    local endpoint ready attempt
    for endpoint in \
        http://127.0.0.1:8890/health \
        http://127.0.0.1:8889/ \
        http://127.0.0.1:8888/; do
        ready=false
        for attempt in $(seq 1 30); do
            if curl -fsS --max-time 2 "${endpoint}" >/dev/null 2>&1; then
                ready=true
                break
            fi
            sleep 1
        done
        if [ "${ready}" != true ]; then
            log "Required service endpoint unavailable: ${endpoint}"
            return 1
        fi
    done

    log ""
    log "═══════════════════════════════════════════════════════════════"
    log "  ◈ AWAKENING COMPLETE — $(date)"
    log "═══════════════════════════════════════════════════════════════"

    # Mark done only after required onboarding services are healthy.
    touch "${STAMP}"
    log "First boot marked complete: ${STAMP}"
}

# ── Guard: installed systems only, and only once ──
if [ ! -f "${INSTALLED_MARKER}" ] && [ "${1:-}" != "--force" ]; then
    log "Installed-system marker absent; skipping firstboot in live media."
    exit 0
fi

if [ -f "${STAMP}" ] && [ "${1:-}" != "--force" ]; then
    log "First boot already completed. Use --force to re-run."
    exit 0
fi

main "$@"
