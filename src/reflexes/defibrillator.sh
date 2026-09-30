#!/bin/bash
# Ash Defibrillator - Autonomic Reflex
# Keeps the cognitive layer alive

CONFIG="/etc/raksha/config.yaml"
# Ensure we check the status of raksha-cognitive.service
SERVICE="raksha-cognitive.service"
LOG_FILE="/var/lib/ash/logs/defibrillator.log"

mkdir -p $(dirname $LOG_FILE)

echo "[$(date)] Ash Defibrillator Activated" >> $LOG_FILE

while true; do
    if ! systemctl is-active --quiet $SERVICE; then
        echo "[$(date)] FATAL: $SERVICE is dead. Initiating restart..." >> $LOG_FILE
        systemctl restart $SERVICE
        sleep 5
        if systemctl is-active --quiet $SERVICE; then
            echo "[$(date)] RECOVERY SUCCESS: $SERVICE is back online." >> $LOG_FILE
        else
            echo "[$(date)] RECOVERY FAILED: $SERVICE could not be restarted." >> $LOG_FILE
        fi
    fi
    sleep 10
done
