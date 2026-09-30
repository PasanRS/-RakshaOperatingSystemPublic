#!/usr/bin/env python3
"""
Raksha Harness — Executive Control Layer
=========================================
The Harness is the operating layer that allows Ash to coordinate the
entire operating system. It is NOT an AI — it is a routing, registry,
and audit service.

Architecture:
    Ash (port 8888) ──► Harness (port 8890) ──► Registered Capabilities
                                              ╠══ Audit Log (JSONL)
                                              ╠══ Capability Registry (JSON)
                                              ╚══ Permission Rules (JSON)

API:
    GET  /health                    — Harness health + aggregate capability health
    GET  /capabilities              — List all registered capabilities
    POST /capabilities/register     — Register a new capability
    POST /capabilities/deregister   — Deregister a capability
    POST /dispatch                  — Route a request to a capability
    GET  /audit                     — Query audit records
    POST /audit                     — Write an audit record directly
    GET  /permissions               — List permission rules
    POST /permissions               — Add/update a permission rule
    GET  /status                    — Full system state dump

Author: Raksha OS Project / Pasan
Version: 0.5.1
"""

import asyncio
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List, Optional

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel

# ── Paths ──────────────────────────────────────────────────────────────────
ASH_HOME        = Path("/var/lib/ash")
HARNESS_DIR     = ASH_HOME / "harness"
REGISTRY_FILE   = HARNESS_DIR / "registry.json"
AUDIT_FILE      = HARNESS_DIR / "audit.jsonl"
PERMISSIONS_FILE = HARNESS_DIR / "permissions.json"
ASH_STATE_FILE  = HARNESS_DIR / "ash-state.json"
LOG_FILE        = ASH_HOME / "logs" / "harness.log"

HARNESS_PORT    = 8890
HARNESS_VERSION = "0.5.1"

# ── Logging ────────────────────────────────────────────────────────────────
LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [HARNESS] %(levelname)s %(message)s",
    handlers=[
        logging.FileHandler(str(LOG_FILE)),
        logging.StreamHandler(),
    ],
)
log = logging.getLogger("raksha.harness")


def read_ash_state() -> Dict[str, Any]:
    """Read the shared Ash entity state published by ash-interface."""
    if not ASH_STATE_FILE.exists():
        return {
            "entity": "ash",
            "state": "UNKNOWN",
            "state_file": str(ASH_STATE_FILE),
        }
    try:
        data = json.loads(ASH_STATE_FILE.read_text())
        data.setdefault("entity", "ash")
        data.setdefault("state_file", str(ASH_STATE_FILE))
        return data
    except Exception as e:
        return {
            "entity": "ash",
            "state": "ERROR",
            "state_file": str(ASH_STATE_FILE),
            "error": str(e),
        }

# ── Models ─────────────────────────────────────────────────────────────────

class CapabilityRegistration(BaseModel):
    name: str
    description: str
    endpoint: str                        # e.g. "http://localhost:8891"
    actions: List[str]                   # e.g. ["speak", "listen", "mute"]
    requires_approval: bool = False
    metadata: Dict[str, Any] = {}

class DispatchRequest(BaseModel):
    capability: str
    action: str
    payload: Dict[str, Any] = {}
    requester: str = "ash"               # which identity is requesting
    priority: str = "normal"            # low | normal | high | critical

class AuditRecord(BaseModel):
    service: str
    request: str
    action: str
    result: str = "ok"                  # ok | error | pending
    error: Optional[str] = None
    approved_by: str = "auto"           # ash | auto | user
    metadata: Dict[str, Any] = {}

class PermissionRule(BaseModel):
    capability: str
    action: str
    allow: bool = True
    requires_user_approval: bool = False
    requester_filter: Optional[str] = None  # restrict to specific requester

# ── Registry ───────────────────────────────────────────────────────────────

class CapabilityRegistry:
    """Persistent capability registry. Thread-safe via asyncio."""

    def __init__(self):
        HARNESS_DIR.mkdir(parents=True, exist_ok=True)
        self._registry: Dict[str, Dict] = {}
        self._load()

    def _load(self):
        if REGISTRY_FILE.exists():
            try:
                self._registry = json.loads(REGISTRY_FILE.read_text())
                log.info(f"Registry loaded: {len(self._registry)} capabilities")
            except Exception as e:
                log.error(f"Registry load error: {e}")
                self._registry = {}

    def _save(self):
        try:
            REGISTRY_FILE.write_text(json.dumps(self._registry, indent=2))
        except Exception as e:
            log.error(f"Registry save error: {e}")

    def register(self, reg: CapabilityRegistration) -> Dict:
        entry = {
            **reg.model_dump(),
            "registered_at": datetime.utcnow().isoformat(),
            "last_seen": datetime.utcnow().isoformat(),
            "status": "registered",
            "health": "unknown",
        }
        self._registry[reg.name] = entry
        self._save()
        log.info(f"Registered capability: {reg.name} @ {reg.endpoint}")
        return entry

    def deregister(self, name: str) -> bool:
        if name in self._registry:
            del self._registry[name]
            self._save()
            log.info(f"Deregistered capability: {name}")
            return True
        return False

    def get(self, name: str) -> Optional[Dict]:
        return self._registry.get(name)

    def list_all(self) -> List[Dict]:
        return list(self._registry.values())

    def update_health(self, name: str, healthy: bool):
        if name in self._registry:
            self._registry[name]["health"] = "ok" if healthy else "degraded"
            self._registry[name]["last_seen"] = datetime.utcnow().isoformat()
            self._save()

    def mark_seen(self, name: str):
        if name in self._registry:
            self._registry[name]["last_seen"] = datetime.utcnow().isoformat()

# ── Audit Log ──────────────────────────────────────────────────────────────

class AuditLog:
    """Append-only JSONL audit log. Never deletes records."""

    def __init__(self):
        HARNESS_DIR.mkdir(parents=True, exist_ok=True)
        AUDIT_FILE.touch(exist_ok=True)
        log.info(f"Audit log initialised: {AUDIT_FILE}")

    def write(self, record: Dict) -> Dict:
        """Write a record to the audit log. Returns the stamped record."""
        stamped = {
            "ts": datetime.utcnow().isoformat(),
            "ts_epoch": time.time(),
            **record,
        }
        try:
            with open(AUDIT_FILE, "a") as f:
                f.write(json.dumps(stamped) + "\n")
        except Exception as e:
            log.error(f"Audit write error: {e}")
        return stamped

    def query(
        self,
        service: Optional[str] = None,
        since_epoch: Optional[float] = None,
        limit: int = 100,
    ) -> List[Dict]:
        """Read audit records, optionally filtered."""
        records = []
        try:
            lines = AUDIT_FILE.read_text().splitlines()
            for line in reversed(lines):
                if not line.strip():
                    continue
                try:
                    r = json.loads(line)
                    if service and r.get("service") != service:
                        continue
                    if since_epoch and r.get("ts_epoch", 0) < since_epoch:
                        continue
                    records.append(r)
                    if len(records) >= limit:
                        break
                except Exception:
                    continue
        except Exception as e:
            log.error(f"Audit read error: {e}")
        return records

    def size(self) -> int:
        try:
            return sum(1 for _ in open(AUDIT_FILE))
        except Exception:
            return 0

# ── Permission Engine ──────────────────────────────────────────────────────

class PermissionEngine:
    """Simple rule-based permission engine for capability actions."""

    def __init__(self):
        HARNESS_DIR.mkdir(parents=True, exist_ok=True)
        self._rules: List[Dict] = []
        self._load()

    def _load(self):
        if PERMISSIONS_FILE.exists():
            try:
                self._rules = json.loads(PERMISSIONS_FILE.read_text())
                log.info(f"Permissions loaded: {len(self._rules)} rules")
            except Exception as e:
                log.error(f"Permissions load error: {e}")
                self._rules = []
        else:
            # Default: allow everything from ash, auto-approve
            self._rules = [
                {
                    "capability": "*",
                    "action": "*",
                    "allow": True,
                    "requires_user_approval": False,
                    "requester_filter": None,
                    "created_at": datetime.utcnow().isoformat(),
                }
            ]
            self._save()

    def _save(self):
        PERMISSIONS_FILE.write_text(json.dumps(self._rules, indent=2))

    def check(self, capability: str, action: str, requester: str) -> Dict:
        """
        Returns {"allowed": bool, "requires_approval": bool, "rule": dict|None}
        Specificity wins: capability+action > capability+* > *+* 
        """
        best_rule = None
        best_score = -1
        for rule in self._rules:
            cap_match = rule["capability"] == capability or rule["capability"] == "*"
            act_match = rule["action"] == action or rule["action"] == "*"
            req_match = (rule.get("requester_filter") is None or
                         rule.get("requester_filter") == requester)
            if cap_match and act_match and req_match:
                score = (
                    (2 if rule["capability"] == capability else 0) +
                    (1 if rule["action"] == action else 0)
                )
                if score > best_score:
                    best_score = score
                    best_rule = rule

        if best_rule is None:
            # Default deny for unmatched
            return {"allowed": False, "requires_approval": False, "rule": None}

        return {
            "allowed": best_rule["allow"],
            "requires_approval": best_rule.get("requires_user_approval", False),
            "rule": best_rule,
        }

    def add_rule(self, rule: PermissionRule) -> Dict:
        entry = {
            **rule.model_dump(),
            "created_at": datetime.utcnow().isoformat(),
        }
        # Replace existing rule for same capability+action
        self._rules = [
            r for r in self._rules
            if not (r["capability"] == rule.capability and r["action"] == rule.action)
        ]
        self._rules.append(entry)
        self._save()
        log.info(f"Permission rule added: {rule.capability}/{rule.action} allow={rule.allow}")
        return entry

    def list_rules(self) -> List[Dict]:
        return self._rules

# ── Health Checker ─────────────────────────────────────────────────────────

async def check_capability_health(registry: CapabilityRegistry) -> Dict[str, str]:
    """Ping all registered capabilities and update their health status."""
    results = {}
    async with httpx.AsyncClient(timeout=3.0) as client:
        for cap in registry.list_all():
            name = cap["name"]
            endpoint = cap.get("endpoint", "")
            if not endpoint:
                results[name] = "no_endpoint"
                continue
            try:
                resp = await client.get(f"{endpoint}/health")
                healthy = resp.status_code < 500
                registry.update_health(name, healthy)
                results[name] = "ok" if healthy else "degraded"
            except Exception:
                registry.update_health(name, False)
                results[name] = "unreachable"
    return results

# ── App Lifecycle ──────────────────────────────────────────────────────────

registry = CapabilityRegistry()
audit    = AuditLog()
perms    = PermissionEngine()

@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info(f"Raksha Harness v{HARNESS_VERSION} starting on port {HARNESS_PORT}")
    audit.write({
        "service": "harness",
        "request": "startup",
        "action": "start",
        "result": "ok",
        "approved_by": "system",
    })
    # Background health check task
    task = asyncio.create_task(health_check_loop())
    yield
    task.cancel()
    audit.write({
        "service": "harness",
        "request": "shutdown",
        "action": "stop",
        "result": "ok",
        "approved_by": "system",
    })
    log.info("Raksha Harness stopped.")

async def health_check_loop():
    """Periodically check all registered capability health."""
    while True:
        try:
            await asyncio.sleep(60)
            results = await check_capability_health(registry)
            log.debug(f"Health check complete: {results}")
        except asyncio.CancelledError:
            break
        except Exception as e:
            log.error(f"Health check error: {e}")

# ── FastAPI App ────────────────────────────────────────────────────────────

app = FastAPI(
    title="Raksha Harness",
    description="Executive control layer for Raksha OS — capability registry, routing, audit, permissions",
    version=HARNESS_VERSION,
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

# ── Routes: Health ─────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    caps = registry.list_all()
    return {
        "status": "ok",
        "service": "raksha-harness",
        "version": HARNESS_VERSION,
        "ash": read_ash_state(),
        "capabilities_registered": len(caps),
        "audit_records": audit.size(),
        "permissions_rules": len(perms.list_rules()),
        "ts": datetime.utcnow().isoformat(),
    }

@app.get("/status")
async def status():
    cap_health = await check_capability_health(registry)
    return {
        "harness": {
            "status": "ok",
            "version": HARNESS_VERSION,
            "ts": datetime.utcnow().isoformat(),
        },
        "ash": read_ash_state(),
        "capabilities": registry.list_all(),
        "capability_health": cap_health,
        "audit_records": audit.size(),
        "permissions": perms.list_rules(),
    }

# ── Routes: Capabilities ───────────────────────────────────────────────────

@app.get("/capabilities")
async def list_capabilities():
    return {"capabilities": registry.list_all()}

@app.post("/capabilities/register")
async def register_capability(reg: CapabilityRegistration):
    entry = registry.register(reg)
    audit.write({
        "service": reg.name,
        "request": "register",
        "action": "capability_register",
        "result": "ok",
        "approved_by": "auto",
        "metadata": {"endpoint": reg.endpoint, "actions": reg.actions},
    })
    return {"status": "registered", "capability": entry}

@app.post("/capabilities/deregister")
async def deregister_capability(body: Dict[str, str]):
    name = body.get("name", "")
    if not name:
        raise HTTPException(400, "name required")
    ok = registry.deregister(name)
    if not ok:
        raise HTTPException(404, f"Capability '{name}' not found")
    audit.write({
        "service": name,
        "request": "deregister",
        "action": "capability_deregister",
        "result": "ok",
        "approved_by": "auto",
    })
    return {"status": "deregistered", "name": name}

@app.get("/capabilities/{name}")
async def get_capability(name: str):
    cap = registry.get(name)
    if not cap:
        raise HTTPException(404, f"Capability '{name}' not found")
    return cap

# ── Routes: Dispatch ───────────────────────────────────────────────────────

@app.post("/dispatch")
async def dispatch(req: DispatchRequest):
    """
    Route a capability request from Ash to the appropriate capability.
    Flow:
        1. Check capability is registered
        2. Check permission
        3. Forward request to capability's endpoint
        4. Write audit record
        5. Return result
    """
    cap = registry.get(req.capability)
    if not cap:
        audit.write({
            "service": req.capability,
            "request": req.action,
            "action": "dispatch_fail",
            "result": "error",
            "error": "capability_not_registered",
            "approved_by": "auto",
        })
        raise HTTPException(404, f"Capability '{req.capability}' not registered with Harness")

    # Permission check
    perm = perms.check(req.capability, req.action, req.requester)
    if not perm["allowed"]:
        audit.write({
            "service": req.capability,
            "request": req.action,
            "action": "dispatch_denied",
            "result": "error",
            "error": "permission_denied",
            "approved_by": "auto",
        })
        raise HTTPException(403, f"Action '{req.action}' denied on capability '{req.capability}'")

    # Forward to capability
    endpoint = cap["endpoint"]
    try:
        async with httpx.AsyncClient(timeout=30.0) as client:
            resp = await client.post(
                f"{endpoint}/execute",
                json={
                    "action": req.action,
                    "payload": req.payload,
                    "requester": req.requester,
                },
            )
            result_data = resp.json() if resp.headers.get("content-type", "").startswith("application/json") else {"raw": resp.text}
            result_status = "ok" if resp.status_code < 400 else "error"

            registry.mark_seen(req.capability)
            audit.write({
                "service": req.capability,
                "request": req.action,
                "action": "dispatch",
                "result": result_status,
                "approved_by": req.requester,
                "metadata": {"status_code": resp.status_code},
            })
            return {
                "status": result_status,
                "capability": req.capability,
                "action": req.action,
                "result": result_data,
                "ts": datetime.utcnow().isoformat(),
            }
    except httpx.TimeoutException:
        audit.write({
            "service": req.capability,
            "request": req.action,
            "action": "dispatch_timeout",
            "result": "error",
            "error": "timeout",
            "approved_by": "auto",
        })
        raise HTTPException(504, f"Capability '{req.capability}' timed out")
    except Exception as e:
        audit.write({
            "service": req.capability,
            "request": req.action,
            "action": "dispatch_error",
            "result": "error",
            "error": str(e),
            "approved_by": "auto",
        })
        raise HTTPException(502, f"Dispatch error: {e}")

# ── Routes: Audit ──────────────────────────────────────────────────────────

@app.get("/audit")
async def get_audit(
    service: Optional[str] = None,
    since: Optional[float] = None,
    limit: int = 100,
):
    records = audit.query(service=service, since_epoch=since, limit=min(limit, 500))
    return {"records": records, "count": len(records)}

@app.post("/audit")
async def write_audit(record: AuditRecord):
    stamped = audit.write(record.model_dump())
    return {"status": "written", "record": stamped}

# ── Routes: Permissions ────────────────────────────────────────────────────

@app.get("/permissions")
async def get_permissions():
    return {"rules": perms.list_rules()}

@app.post("/permissions")
async def add_permission(rule: PermissionRule):
    entry = perms.add_rule(rule)
    audit.write({
        "service": "harness",
        "request": f"permission:{rule.capability}/{rule.action}",
        "action": "permission_update",
        "result": "ok",
        "approved_by": "user",
        "metadata": entry,
    })
    return {"status": "added", "rule": entry}

# ── Routes: Voice Control (convenience forwarding) ─────────────────────────

@app.post("/voice/mute")
async def voice_mute():
    """Convenience: mute the voice capability."""
    cap = registry.get("voice")
    if not cap:
        raise HTTPException(404, "Voice capability not registered")
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            r = await client.post(f"{cap['endpoint']}/mute")
            audit.write({"service": "voice", "request": "mute", "action": "mute", "result": "ok", "approved_by": "user"})
            return r.json()
        except Exception as e:
            raise HTTPException(502, str(e))

@app.post("/voice/unmute")
async def voice_unmute():
    """Convenience: unmute the voice capability."""
    cap = registry.get("voice")
    if not cap:
        raise HTTPException(404, "Voice capability not registered")
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            r = await client.post(f"{cap['endpoint']}/unmute")
            audit.write({"service": "voice", "request": "unmute", "action": "unmute", "result": "ok", "approved_by": "user"})
            return r.json()
        except Exception as e:
            raise HTTPException(502, str(e))

@app.post("/voice/restart")
async def voice_restart():
    """Convenience: restart the voice service."""
    import subprocess
    audit.write({"service": "voice", "request": "restart", "action": "restart", "result": "ok", "approved_by": "user"})
    subprocess.Popen(["systemctl", "restart", "ash-voice"])
    return {"status": "restarting"}

@app.post("/ash/restart")
async def ash_restart():
    """Restart the Ash interface service."""
    import subprocess
    audit.write({"service": "ash-interface", "request": "restart", "action": "restart", "result": "ok", "approved_by": "user"})
    subprocess.Popen(["systemctl", "restart", "ash-interface"])
    return {"status": "restarting"}

# ── Entry Point ────────────────────────────────────────────────────────────

if __name__ == "__main__":
    uvicorn.run(
        "harness:app",
        host="127.0.0.1",
        port=HARNESS_PORT,
        log_level="info",
        reload=False,
    )
