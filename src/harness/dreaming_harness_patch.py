#!/usr/bin/env python3
"""
Ash Dreaming Engine — v3 (Harness-integrated)
==============================================
Memory consolidation reflex. Runs on a timer (every 2h + 3am full pass).
Distills recent session logs into dream summaries appended to MEMORY.md.

Harness integration added:
  - Registers 'dreaming' capability on startup
  - Emits audit record on each consolidation run
"""

import os
import sys
import json
import sqlite3
import urllib.request
import urllib.error
from datetime import datetime, timedelta
from pathlib import Path

# Harness integration
HARNESS_URL = os.environ.get("HARNESS_URL", "http://localhost:8890")

def _harness_post(path: str, data: dict) -> bool:
    try:
        body = json.dumps(data).encode()
        req = urllib.request.Request(
            f"{HARNESS_URL}{path}", data=body,
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(req, timeout=3) as r:
            return r.status < 400
    except Exception:
        return False

def register_with_harness():
    _harness_post("/capabilities/register", {
        "name": "dreaming",
        "description": "Memory consolidation — distills sessions into dream summaries",
        "endpoint": "http://localhost:0",
        "actions": ["consolidate_light", "consolidate_full", "archive_memory"],
        "requires_approval": False,
        "metadata": {"type": "oneshot", "schedule": "every 2h + 3am full"},
    })
