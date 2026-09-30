#!/usr/bin/env python3
"""
Ash Heartbeat Reflex — v2 (Harness-integrated)
================================================
Collects system telemetry (CPU, RAM, Disk, Temp) and writes to heartbeat.log
and latest.json. Also registers itself with the Raksha Harness and emits
an audit record on each run.

Fixed: checks llama.cpp at :8080 (not Ollama at :11434)
Added: Harness capability registration + audit record
"""

import os
import json
import sys
import urllib.request
import urllib.error
import psutil
from datetime import datetime
from pathlib import Path

LOG_FILE    = Path("/var/lib/ash/logs/heartbeat.log")
LATEST_FILE = Path("/var/lib/ash/logs/heartbeat-latest.json")
HARNESS_URL = os.environ.get("HARNESS_URL", "http://localhost:8890")
LLAMA_URL   = os.environ.get("LLAMA_URL", "http://localhost:8080")

# Thresholds
DISK_WARN   = 90.0
DISK_CRIT   = 95.0
RAM_WARN    = 85.0
CPU_WARN    = 90.0
TEMP_WARN   = 75.0
TEMP_CRIT   = 85.0


def _harness_post(path: str, data: dict) -> bool:
    """Fire-and-forget POST to Harness. Non-fatal."""
    try:
        body = json.dumps(data).encode()
        req = urllib.request.Request(
            f"{HARNESS_URL}{path}",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with urllib.request.urlopen(req, timeout=3) as r:
            return r.status < 400
    except Exception:
        return False


def register_with_harness():
    """Register heartbeat capability with the Harness."""
    _harness_post("/capabilities/register", {
        "name": "heartbeat",
        "description": "System health telemetry — CPU, RAM, disk, temperature",
        "endpoint": "http://localhost:0",  # oneshot — no HTTP endpoint
        "actions": ["collect_metrics", "report_health"],
        "requires_approval": False,
        "metadata": {"type": "oneshot", "schedule": "every 30 minutes"},
    })


def get_llama_status() -> str:
    """Check llama.cpp inference server health at :8080."""
    try:
        req = urllib.request.Request(f"{LLAMA_URL}/health", method="GET")
        with urllib.request.urlopen(req, timeout=3) as r:
            if r.status == 200:
                return "ok"
    except Exception:
        pass
    return "unreachable"


def get_ash_services_status() -> dict:
    """Quick check of critical Ash systemd services."""
    import subprocess
    services = [
        "ash-interface", "ash-whatsapp-bridge", "ash-whatsapp-poller",
        "ash-defibrillator", "raksha-harness", "raksha-dashboard",
    ]
    status = {}
    for svc in services:
        try:
            r = subprocess.run(
                ["systemctl", "is-active", svc],
                capture_output=True, text=True, timeout=3
            )
            status[svc] = r.stdout.strip()
        except Exception:
            status[svc] = "unknown"
    return status


def get_metrics() -> dict:
    disk   = psutil.disk_usage("/")
    mem    = psutil.virtual_memory()
    cpu    = psutil.cpu_percent(interval=1)
    temp_c = 0.0

    try:
        temps = psutil.sensors_temperatures()
        if "coretemp" in temps:
            temp_c = temps["coretemp"][0].current
        elif "k10temp" in temps:
            temp_c = temps["k10temp"][0].current
    except Exception:
        pass

    alerts = []
    if disk.percent >= DISK_CRIT:
        alerts.append(f"CRITICAL: Disk {disk.percent:.1f}%")
    elif disk.percent >= DISK_WARN:
        alerts.append(f"WARN: Disk {disk.percent:.1f}%")
    if mem.percent >= RAM_WARN:
        alerts.append(f"WARN: RAM {mem.percent:.1f}%")
    if cpu >= CPU_WARN:
        alerts.append(f"WARN: CPU {cpu:.1f}%")
    if temp_c >= TEMP_CRIT:
        alerts.append(f"CRITICAL: Temp {temp_c:.1f}°C")
    elif temp_c >= TEMP_WARN:
        alerts.append(f"WARN: Temp {temp_c:.1f}°C")

    return {
        "timestamp":    datetime.now().isoformat(),
        "cpu_percent":  cpu,
        "ram_percent":  mem.percent,
        "ram_used_mb":  mem.used // (1024 * 1024),
        "disk_percent": disk.percent,
        "disk_free_gb": round(disk.free / (1024 ** 3), 1),
        "temp_c":       temp_c,
        "llama_status": get_llama_status(),
        "alerts":       alerts,
    }


def main():
    # Self-register with Harness (non-fatal)
    register_with_harness()

    metrics = get_metrics()
    services = get_ash_services_status()
    metrics["services"] = services

    # Write latest JSON
    LATEST_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LATEST_FILE, "w") as f:
        json.dump(metrics, f, indent=2)

    # Append to log
    alert_str = " | " + ", ".join(metrics["alerts"]) if metrics["alerts"] else ""
    log_line = (
        f"[{metrics['timestamp']}] "
        f"CPU: {metrics['cpu_percent']}% | "
        f"RAM: {metrics['ram_percent']}% ({metrics['ram_used_mb']}MB) | "
        f"Disk: {metrics['disk_percent']}% (Free: {metrics['disk_free_gb']}GB) | "
        f"Temp: {metrics['temp_c']}C | "
        f"llama.cpp: {metrics['llama_status']}"
        f"{alert_str}"
    )
    with open(LOG_FILE, "a") as f:
        f.write(log_line + "\n")

    # Emit audit record to Harness
    _harness_post("/audit", {
        "service":     "heartbeat",
        "request":     "collect_metrics",
        "action":      "heartbeat_tick",
        "result":      "error" if metrics["alerts"] else "ok",
        "approved_by": "auto",
        "metadata":    {
            "cpu": metrics["cpu_percent"],
            "ram": metrics["ram_percent"],
            "disk": metrics["disk_percent"],
            "temp": metrics["temp_c"],
            "llama": metrics["llama_status"],
            "alerts": metrics["alerts"],
        },
    })

    if metrics["alerts"]:
        print(f"[HEARTBEAT] ALERTS: {'; '.join(metrics['alerts'])}", file=sys.stderr)
    else:
        print(f"[HEARTBEAT] OK — CPU:{metrics['cpu_percent']}% RAM:{metrics['ram_percent']}% Disk:{metrics['disk_percent']}% Temp:{metrics['temp_c']}C llama:{metrics['llama_status']}")


if __name__ == "__main__":
    main()
