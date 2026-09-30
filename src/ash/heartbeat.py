#!/usr/bin/env python3
"""
ash-heartbeat — System health pulse
Runs every 30 minutes via systemd timer
"""

import os
import json
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

ASH_HOME = Path(os.environ.get("ASH_HOME", "/var/lib/ash"))
LOG_FILE = ASH_HOME / "logs" / "heartbeat.log"

# Thresholds
DISK_WARN = 90  # percent
DISK_CRIT = 95
RAM_WARN = 85
RAM_CRIT = 95
CPU_WARN = 80
CPU_CRIT = 95
TEMP_WARN = 75  # celsius
TEMP_CRIT = 85


def log(msg):
    ts = datetime.now().isoformat()
    line = f"[{ts}] {msg}"
    print(line)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def check_disk():
    """Check disk usage"""
    usage = shutil.disk_usage("/")
    percent = (usage.used / usage.total) * 100
    status = "ok"
    if percent >= DISK_CRIT:
        status = "critical"
    elif percent >= DISK_WARN:
        status = "warning"
    return {"percent": round(percent, 1), "status": status, "free_gb": round(usage.free / (1024**3), 1)}


def check_ram():
    """Check RAM usage"""
    with open("/proc/meminfo") as f:
        lines = f.readlines()
    mem = {}
    for line in lines:
        if ":" in line:
            key, val = line.split(":", 1)
            mem[key.strip()] = int(val.split()[0])
    total = mem.get("MemTotal", 0)
    available = mem.get("MemAvailable", 0)
    used = total - available
    percent = (used / total) * 100 if total else 0
    status = "ok"
    if percent >= RAM_CRIT:
        status = "critical"
    elif percent >= RAM_WARN:
        status = "warning"
    return {"percent": round(percent, 1), "status": status, "total_mb": total // 1024, "available_mb": available // 1024}


def check_cpu():
    """Check CPU usage (5-second average)"""
    result = subprocess.run(
        ["bash", "-c", "top -bn2 -d2 | grep 'Cpu(s)' | tail -1"],
        capture_output=True, text=True, timeout=15
    )
    try:
        # Parse: %Cpu(s): 10.5 us, 3.2 sy, 0.0 ni, 85.1 id, ...
        parts = result.stdout.split(",")
        idle = float(parts[3].strip().split()[0])
        usage = 100 - idle
    except (IndexError, ValueError):
        usage = 0
    status = "ok"
    if usage >= CPU_CRIT:
        status = "critical"
    elif usage >= CPU_WARN:
        status = "warning"
    return {"percent": round(usage, 1), "status": status}


def check_temp():
    """Check CPU temperature"""
    try:
        with open("/sys/class/thermal/thermal_zone0/temp") as f:
            temp = int(f.read().strip()) / 1000
    except (FileNotFoundError, ValueError):
        temp = 0
    status = "ok"
    if temp >= TEMP_CRIT:
        status = "critical"
    elif temp >= TEMP_WARN:
        status = "warning"
    return {"celsius": round(temp, 1), "status": status}


def check_ollama():
    """Check if Ollama is running"""
    try:
        result = subprocess.run(
            ["curl", "-sf", "http://127.0.0.1:11434/"],
            capture_output=True, timeout=5
        )
        return {"running": result.returncode == 0, "status": "ok" if result.returncode == 0 else "down"}
    except Exception:
        return {"running": False, "status": "error"}


def check_services():
    """Check rakshak systemd services"""
    services = [
        "ash-core",
        "ash-heartbeat",
        "ash-memory",
        "llama-server",
        "ash-voice",
    ]
    results = {}
    for svc in services:
        result = subprocess.run(
            ["systemctl", "is-active", svc],
            capture_output=True, text=True, timeout=5
        )
        results[svc] = result.stdout.strip()
    return results


def heartbeat():
    """Run full heartbeat check"""
    log("=== Heartbeat check ===")

    report = {
        "timestamp": datetime.now().isoformat(),
        "disk": check_disk(),
        "ram": check_ram(),
        "cpu": check_cpu(),
        "temp": check_temp(),
        "ollama": check_ollama(),
        "services": check_services(),
    }

    # Log summary
    issues = []
    for component in ["disk", "ram", "cpu", "temp"]:
        data = report[component]
        if data["status"] != "ok":
            issues.append(f"{component}: {data['status']} ({data.get('percent', data.get('celsius'))})")
            log(f"⚠ {component.upper()}: {data['status']}")

    if not report["ollama"]["running"]:
        issues.append("ollama: down")
        log("⚠ OLLAMA: down")

    for svc, status in report["services"].items():
        if status != "active":
            issues.append(f"{svc}: {status}")
            log(f"⚠ SERVICE {svc}: {status}")

    if issues:
        log(f"Issues found: {', '.join(issues)}")
        report["overall"] = "degraded"
    else:
        log("All systems nominal")
        report["overall"] = "healthy"

    # Write report
    report_path = ASH_HOME / "logs" / "heartbeat-latest.json"
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps(report, indent=2))

    return report


if __name__ == "__main__":
    heartbeat()
