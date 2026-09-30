#!/usr/bin/env python3
"""
Raksha Harness — Capability Registration Helper
================================================
Import this module in any Ash service to self-register with the Harness
on startup and emit audit records.

Usage:
    from harness_client import HarnessClient
    
    harness = HarnessClient()
    harness.register(
        name="voice",
        description="Continuous voice interface — STT/TTS via Whisper and Piper",
        endpoint="http://localhost:8888",
        actions=["speak", "listen", "mute", "unmute", "restart"],
    )
    # ... later ...
    harness.audit(service="voice", request="wake", action="awake_state", result="ok")
"""

import json
import logging
import os
import time
from typing import Any, Dict, List, Optional

log = logging.getLogger("raksha.harness_client")

HARNESS_URL = os.environ.get("HARNESS_URL", "http://localhost:8890")


class HarnessClient:
    """Lightweight HTTP client for registering capabilities and writing audit records.
    Uses only stdlib (urllib) so it works even before pip packages are available.
    """

    def __init__(self, harness_url: str = HARNESS_URL, timeout: int = 5):
        self.base_url = harness_url.rstrip("/")
        self.timeout = timeout

    def _post(self, path: str, data: Dict) -> Optional[Dict]:
        import urllib.request
        import urllib.error
        body = json.dumps(data).encode()
        req = urllib.request.Request(
            f"{self.base_url}{path}",
            data=body,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                return json.loads(resp.read())
        except urllib.error.URLError as e:
            log.debug(f"Harness unreachable ({path}): {e}")
            return None
        except Exception as e:
            log.debug(f"Harness error ({path}): {e}")
            return None

    def _get(self, path: str) -> Optional[Dict]:
        import urllib.request
        import urllib.error
        try:
            with urllib.request.urlopen(f"{self.base_url}{path}", timeout=self.timeout) as resp:
                return json.loads(resp.read())
        except Exception as e:
            log.debug(f"Harness GET error ({path}): {e}")
            return None

    def register(
        self,
        name: str,
        description: str,
        endpoint: str,
        actions: List[str],
        requires_approval: bool = False,
        metadata: Dict[str, Any] = None,
    ) -> bool:
        """Register this capability with the Harness. Non-fatal if Harness is down."""
        result = self._post("/capabilities/register", {
            "name": name,
            "description": description,
            "endpoint": endpoint,
            "actions": actions,
            "requires_approval": requires_approval,
            "metadata": metadata or {},
        })
        if result:
            log.info(f"Registered capability '{name}' with Harness")
            return True
        else:
            log.warning(f"Could not register '{name}' — Harness may not be running yet")
            return False

    def audit(
        self,
        service: str,
        request: str,
        action: str,
        result: str = "ok",
        error: str = None,
        approved_by: str = "auto",
        metadata: Dict[str, Any] = None,
    ) -> bool:
        """Write an audit record. Non-fatal if Harness is down."""
        record = {
            "service": service,
            "request": request,
            "action": action,
            "result": result,
            "approved_by": approved_by,
            "metadata": metadata or {},
        }
        if error:
            record["error"] = error
        resp = self._post("/audit", record)
        return resp is not None

    def health(self) -> Optional[Dict]:
        """Get harness health. Returns None if unreachable."""
        return self._get("/health")

    def is_alive(self) -> bool:
        """Quick check — is the Harness reachable?"""
        return self.health() is not None

    def deregister(self, name: str) -> bool:
        result = self._post("/capabilities/deregister", {"name": name})
        return result is not None


# Convenience singleton
_client: Optional[HarnessClient] = None

def get_harness() -> HarnessClient:
    global _client
    if _client is None:
        _client = HarnessClient()
    return _client
