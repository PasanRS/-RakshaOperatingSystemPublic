#!/usr/bin/env python3
"""
Raksha Harness — Install Script
================================
Sets up the Harness Python venv, installs dependencies, deploys to
/opt/ash-core/harness/, installs the systemd service, and starts it.

Run as: sudo python3 install-harness.py
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

HARNESS_SRC  = Path(__file__).parent / "harness.py"
HARNESS_DEST = Path("/opt/ash-core/harness")
VENV_DIR     = HARNESS_DEST / "venv"
SERVICE_SRC  = Path(__file__).parent.parent.parent / "systemd" / "raksha-harness.service"
SERVICE_DEST = Path("/etc/systemd/system/raksha-harness.service")
ASH_HOME     = Path("/var/lib/ash")

REQUIREMENTS = [
    "fastapi>=0.110.0",
    "uvicorn[standard]>=0.29.0",
    "httpx>=0.27.0",
    "pydantic>=2.0.0",
]


def run(cmd, **kwargs):
    print(f"  $ {cmd}")
    result = subprocess.run(cmd, shell=True, **kwargs)
    if result.returncode != 0:
        print(f"  [ERROR] Command failed: {cmd}")
        sys.exit(1)
    return result


def main():
    if os.geteuid() != 0:
        print("ERROR: Run as root: sudo python3 install-harness.py")
        sys.exit(1)

    print("\n=== Raksha Harness Installer ===\n")

    # 1. Create dirs
    print("[1/6] Creating directories...")
    HARNESS_DEST.mkdir(parents=True, exist_ok=True)
    (ASH_HOME / "harness").mkdir(parents=True, exist_ok=True)
    (ASH_HOME / "logs").mkdir(parents=True, exist_ok=True)

    # 2. Copy harness source
    print("[2/6] Deploying harness.py...")
    shutil.copy2(HARNESS_SRC, HARNESS_DEST / "harness.py")
    os.chmod(HARNESS_DEST / "harness.py", 0o755)

    # 3. Create venv
    print("[3/6] Creating Python venv...")
    if not (VENV_DIR / "bin" / "python").exists():
        run(f"python3 -m venv {VENV_DIR}")

    # 4. Install deps
    print("[4/6] Installing Python dependencies...")
    pip = VENV_DIR / "bin" / "pip"
    run(f"{pip} install --quiet --upgrade pip")
    run(f"{pip} install --quiet {' '.join(REQUIREMENTS)}")

    # 5. Fix ownership
    print("[5/6] Setting ownership (ravan)...")
    ravan_uid = subprocess.run("id -u ravan", shell=True, capture_output=True, text=True).stdout.strip()
    ravan_gid = subprocess.run("id -g ravan", shell=True, capture_output=True, text=True).stdout.strip()
    if ravan_uid:
        run(f"chown -R {ravan_uid}:{ravan_gid} {HARNESS_DEST} {ASH_HOME}/harness")

    # 6. Install and enable systemd service
    print("[6/6] Installing systemd service...")
    if SERVICE_SRC.exists():
        shutil.copy2(SERVICE_SRC, SERVICE_DEST)
    else:
        # Write inline if repo service file not found
        SERVICE_DEST.write_text("""[Unit]
Description=Raksha Harness — Executive Control Layer
After=network.target ash-interface.service
Wants=network.target

[Service]
Type=simple
User=ravan
Group=ravan
WorkingDirectory=/opt/ash-core/harness
ExecStart=/opt/ash-core/harness/venv/bin/python /opt/ash-core/harness/harness.py
Restart=always
RestartSec=5
StandardOutput=append:/var/lib/ash/logs/harness.log
StandardError=append:/var/lib/ash/logs/harness.log
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/var/lib/ash
PrivateTmp=true

[Install]
WantedBy=multi-user.target
""")

    run("systemctl daemon-reload")
    run("systemctl enable raksha-harness.service")
    run("systemctl restart raksha-harness.service")

    print("\n✓ Raksha Harness installed and started.")
    print("  Health: curl http://localhost:8890/health")
    print("  Logs:   journalctl -u raksha-harness -f")
    print("  Audit:  curl http://localhost:8890/audit\n")


if __name__ == "__main__":
    main()
