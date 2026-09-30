#!/bin/bash
# RAKSHA OS: OUT-OF-BAND DEFIBRILLATOR
# Runs continuously in the background to monitor Ash's survival.

MEMORY_DIR="/var/raksha-memory"
DB_PATH="$MEMORY_DIR/sessions/sessions.db"
MD_PATH="$MEMORY_DIR/MEMORY.md"
SENTRY_FLAG="/var/run/sentry.flag"

echo "[WATCHDOG] OOB Defibrillator Online. Monitoring Substrate..."

while true; do
    # 1. Check if Sentry tripped a fatal hardware/security breach
    SENTRY_BREACH=$(cat "$SENTRY_FLAG" 2>/dev/null)
    
    # 2. Check if Ash's cognitive loop crashed and burned
    # (Checking the systemd service state is the most reliable method)
    AGENT_STATUS=$(systemctl is-active raksha-cognitive.service)

    if [[ "$SENTRY_BREACH" == "FATAL_SENTRY_BREACH" || "$AGENT_STATUS" == "failed" ]]; then
        echo "[WATCHDOG] CATASTROPHIC FAILURE DETECTED!"
        
        # Extract the last intent before death from the Hot Memory DB
        if [ -f "$DB_PATH" ]; then
            LAST_CMD=$(sqlite3 "$DB_PATH" "SELECT input FROM sessions WHERE task_type='fatal_intent_log' ORDER BY id DESC LIMIT 1;")
        else
            LAST_CMD="UNKNOWN_FATAL_COMMAND"
        fi
        
        # Inject the painful memory into Ash's long-term Markdown memory
        echo -e "\n[FATAL ERROR INJECTION - $(date)]\nI executed \`$LAST_CMD\`. It caused a kernel panic, service failure, or Sentry security breach. My loop was terminated and the OS was rolled back. I MUST NOT use this exact approach again. I must evaluate the Bedrock routing layer." >> "$MD_PATH"
        
        # Clear the Sentry flag so we don't end up in an infinite boot loop
        rm -f "$SENTRY_FLAG"
        
        # Rewind the OS to the moment right before execution
        echo "[WATCHDOG] Initiating Timeshift Rollback..."
        timeshift --restore --scripted
        
        # Reboot the substrate to wake Ash up with his new memory
        reboot
    fi
    
    # Pulse every 10 seconds
    sleep 10
done
