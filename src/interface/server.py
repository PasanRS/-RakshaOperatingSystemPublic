#!/usr/bin/env python3
"""
Ash Voice Interface v3 — Native Raksha OS
DIRECT CORE EXTENSION — not an isolated instance.
Shares Ash's real memory systems:
  - sessions.db (same schema as agent-loop.py)
  - MEMORY.md / USER.md / SOUL.md (live reads + write-back)
  - knowledge/ vault context
  - task queue (can enqueue to Ash's agent loop)
  - Recent session history pulled from DB for true continuity
  - Heartbeat data for system awareness

Audio: Direct sounddevice, RMS VAD, echo shield, barge-in
TTS: Sentence-by-sentence streaming (near-zero latency)
Voice: ryan-high Piper (116MB high quality)
UI: http://localhost:8891  |  Hotkey: Ctrl+Shift+Space
"""

import re
import os
import sys
import json
import time
import html
import base64
import queue
import sqlite3
import threading
import subprocess
import urllib.request
from datetime import datetime
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, quote_plus, parse_qs, unquote

# ── Packaged venv path for faster-whisper / sounddevice ──
VOICE_BASE    = Path(os.environ.get("VOICE_BASE", "/opt/ash-core/voice"))
VENV_SITE     = VOICE_BASE / "venv" / "lib"
for sp in VENV_SITE.glob("python*/site-packages"):
    sys.path.insert(0, str(sp))

sd = None
np = None
keyboard = None
HAS_KEYBOARD = False

# ── Paths ──
BASE          = VOICE_BASE
ASH_HOME      = Path(os.environ.get("ASH_HOME", "/var/lib/ash"))
SKILLS_DIR    = ASH_HOME / "skills"
HARNESS_URL   = os.environ.get("HARNESS_URL", "http://127.0.0.1:8890")
STATIC_DIR    = Path(__file__).parent / "static"

PIPER         = str(BASE / "piper" / "piper")
# ryan-high: 116MB high-quality emotional male voice
VOICE_MODEL   = str(BASE / "en_US-ryan-high.onnx")
LLAMA_URL     = os.environ.get("LLAMA_URL", "http://127.0.0.1:8080/v1/chat/completions")
SESSIONS_DB   = ASH_HOME / "memory" / "sessions.db"
PORT          = int(os.environ.get("ASH_VOICE_PORT", "8891"))

# ── NVIDIA env (from Ash's own .env) ──
ENV_FILE = ASH_HOME / "identity" / ".env"
if ENV_FILE.exists():
    for line in ENV_FILE.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())
NVIDIA_KEY    = os.environ.get("NVIDIA_API_KEY", "")
NVIDIA_URL    = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1")
NVIDIA_MODEL  = os.environ.get("NVIDIA_MODEL", "nvidia/nemotron-3-ultra-550b-a55b")

# ── Ash's Memory Paths (same as agent-loop.py) ──
SOUL_FILE      = ASH_HOME / "identity" / "SOUL.md"
SOUL_FALLBACK_FILE = ASH_HOME / "memory" / "SOUL.md"
MEMORY_FILE    = ASH_HOME / "memory"   / "MEMORY.md"
USER_FILE      = ASH_HOME / "memory"   / "USER.md"
SESSIONS_DB    = ASH_HOME / "memory"   / "sessions.db"
TASK_DB        = ASH_HOME / "tasks"    / "queue.db"
HEARTBEAT_JSON = ASH_HOME / "logs"    / "heartbeat-latest.json"
KNOWLEDGE_DIR  = ASH_HOME / "knowledge"
OBSIDIAN_VAULT = Path("/var/lib/raksha/obsidian/instincts/Vault")
PIPE_PATH      = ASH_HOME / "agent.pipe"

# ── Audio constants ──
HW_RATE        = 44100   # C-Media USB native rate
CHANNELS       = 2       # USB mic is stereo — we downmix to mono in callback
BLOCKSIZE      = 4096
SILENCE_THRESH = 0.003
SILENCE_TIMEOUT = 1.2

# ── Global state machine ──
STATE          = "SLEEP"   # SLEEP | AWAKE
IS_SPEAKING    = False
audio_paused   = False    # Mute toggle (Ctrl+Alt+Space)
tts_proc       = None
audio_q        = queue.Queue()
current_keys   = set()

# ── SSE event queue for web UI ──
sse_clients    = []
sse_lock       = threading.Lock()
conv_history   = []   # in-session [{role, content}] — seeded from DB on start

# ── Local model router ──
MODEL_ROUTER_FILE = ASH_HOME / "harness" / "model-router.json"
ASH_STATE_FILE = ASH_HOME / "harness" / "ash-state.json"
LOCAL_MODEL_ROUTES = {
    "gemma": {
        "name": "Gemma 4 E2B",
        "url": "http://127.0.0.1:8080/v1/chat/completions",
        "health": "http://127.0.0.1:8080/health",
        "model": "gemma-4-E2B_q4_0-it.gguf",
        "context_window": 131072,
    },
    "nemotron": {
        "name": "Nemotron 3 Nano",
        "url": "http://127.0.0.1:8081/v1/chat/completions",
        "health": "http://127.0.0.1:8081/health",
        "model": "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf",
        "context_window": 1048576,
    },
}

def active_model_id() -> str:
    active = os.environ.get("ASH_ACTIVE_MODEL", "").strip().lower()
    if not active and MODEL_ROUTER_FILE.exists():
        try:
            active = json.loads(MODEL_ROUTER_FILE.read_text()).get("active", "").strip().lower()
        except Exception:
            active = ""
    return active if active in LOCAL_MODEL_ROUTES else "gemma"

def active_llm_route() -> dict:
    return LOCAL_MODEL_ROUTES[active_model_id()]

# ─────────────────────────────────────────────
# ASH ENTITY STATE + HARNESS INTEGRATION
# ─────────────────────────────────────────────
def _harness_post(path: str, payload: dict, timeout: int = 3) -> bool:
    """Best-effort Harness call. Never blocks Ash startup or chat."""
    try:
        req = urllib.request.Request(
            f"{HARNESS_URL}{path}",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=timeout)
        return True
    except Exception:
        return False


def audit_harness(request: str, action: str, result: str = "ok", metadata: dict | None = None):
    _harness_post("/audit", {
        "service": "ash-interface",
        "request": request,
        "action": action,
        "result": result,
        "approved_by": "auto",
        "metadata": metadata or {},
    }, timeout=2)


def _register_with_harness():
    """Register Ash's interface as the live entity boundary."""
    ok = _harness_post("/capabilities/register", {
        "name": "ash-interface",
        "description": "Ash entity boundary: chat, voice, awake/sleep state, local model routing, memory write-back, and controlled live tools.",
        "endpoint": f"http://127.0.0.1:{PORT}",
        "actions": [
            "status", "wake", "sleep", "set_state", "chat", "listen", "speak",
            "mute", "unmute", "interrupt", "tool.list", "tool.run",
            "inventory", "skills", "service_status", "port_status",
            "web_search", "enqueue_task"
        ],
        "requires_approval": False,
        "metadata": {
            "entity": "ash",
            "state_file": str(ASH_STATE_FILE),
            "model_router": str(MODEL_ROUTER_FILE),
            "memory_db": str(SESSIONS_DB),
            "tools": ["inventory", "skills", "service_status", "port_status", "web_search", "enqueue_task"],
        },
    })
    print("✓ Registered Ash interface with Raksha Harness" if ok else "[HARNESS] Registration skipped")


def _load_entity_state():
    """Restore Ash state from the shared entity-state file, defaulting to AWAKE."""
    global STATE, audio_paused
    state = os.environ.get("ASH_BOOT_STATE", "").strip().upper()
    muted = False
    if ASH_STATE_FILE.exists():
        try:
            saved = json.loads(ASH_STATE_FILE.read_text())
            state = saved.get("state", state).strip().upper()
            muted = bool(saved.get("audio_muted", False))
        except Exception:
            pass
    STATE = state if state in {"AWAKE", "SLEEP"} else "AWAKE"
    audio_paused = muted


def write_entity_state(reason: str = "status") -> dict:
    """Persist one shared Ash entity state for dashboard, harness, and future agents."""
    route = active_llm_route()
    data = {
        "entity": "ash",
        "state": STATE,
        "audio_muted": audio_paused,
        "is_speaking": IS_SPEAKING,
        "active_model_id": active_model_id(),
        "active_model": route["name"],
        "active_model_context": route["context_window"],
        "voice": Path(VOICE_MODEL).stem,
        "sessions_loaded": len(conv_history) // 2,
        "memory": {
            "sessions_db": str(SESSIONS_DB),
            "memory_file": str(MEMORY_FILE),
            "soul_file": str(SOUL_FILE),
            "user_file": str(USER_FILE),
            "obsidian_vault": str(OBSIDIAN_VAULT),
        },
        "reason": reason,
        "updated_at": datetime.now().isoformat(),
    }
    try:
        ASH_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
        ASH_STATE_FILE.write_text(json.dumps(data, indent=2))
    except Exception as e:
        print(f"[STATE] Persist error: {e}")
    return data


def set_entity_state(new_state: str, reason: str = "api", announce: bool = False):
    """Set Ash state explicitly. /api/wake must not accidentally sleep Ash."""
    global STATE, audio_paused
    new_state = (new_state or "").strip().upper()
    if new_state not in {"AWAKE", "SLEEP"}:
        raise ValueError("state must be AWAKE or SLEEP")
    old_state = STATE
    STATE = new_state
    if STATE == "AWAKE":
        audio_paused = False
        push_event("state", {"state": "awake"})
        if announce and old_state != "AWAKE":
            threading.Thread(target=query_and_speak,
                             args=("System online. I'm listening.",),
                             daemon=True).start()
    else:
        push_event("state", {"state": "sleep"})
        with audio_q.mutex:
            audio_q.queue.clear()
    data = write_entity_state(reason)
    audit_harness(reason, f"state_{STATE.lower()}", metadata={"previous_state": old_state})
    print(f"\n[STATE] {STATE} — {reason}")
    return data

# ─────────────────────────────────────────────
# LOAD MODELS
# ─────────────────────────────────────────────
WHISPER_DIR = Path(os.environ.get(
    "WHISPER_MODEL_DIR", str(VOICE_BASE / "whisper-small.en")
))
whisper_model = None
print(f"✓ Voice: {Path(VOICE_MODEL).name}")


def initialize_voice_input():
    """Load optional STT/audio in the background; never delay HTTP startup."""
    global whisper_model, sd, np, keyboard, HAS_KEYBOARD
    if not ((WHISPER_DIR / "model.bin").is_file() and
            (WHISPER_DIR / "config.json").is_file()):
        print(f"[STT] Offline Whisper model missing at {WHISPER_DIR}; voice input disabled")
        return
    try:
        import sounddevice as sounddevice_module
        import numpy as numpy_module
        from faster_whisper import WhisperModel
        try:
            from pynput import keyboard as keyboard_module
            keyboard = keyboard_module
            HAS_KEYBOARD = True
        except Exception as exc:
            print(f"[KEYBOARD] Global hotkeys disabled: {exc}")
        sd = sounddevice_module
        np = numpy_module
        print(f"Loading Whisper STT from {WHISPER_DIR} (CPU int8)...")
        whisper_model = WhisperModel(
            str(WHISPER_DIR), device="cpu", compute_type="int8",
            local_files_only=True,
        )
        print("✓ Whisper ready")
        if HAS_KEYBOARD:
            listener = keyboard.Listener(on_press=on_press, on_release=on_release)
            listener.start()
            print("[KEYBOARD] Global hotkeys active")
        mic_id, mic_ch, mic_rate = find_mic_device()
        audio_engine(mic_id, mic_ch, mic_rate)
    except Exception as exc:
        whisper_model = None
        print(f"[AUDIO/STT] Voice input disabled; HTTP remains available: {exc}")


# ─────────────────────────────────────────────
# SSE PUSH
# ─────────────────────────────────────────────
def push_event(event_type: str, data: dict):
    """Push Server-Sent Event to all connected web clients"""
    msg = f"event: {event_type}\ndata: {json.dumps(data)}\n\n"
    with sse_lock:
        dead = []
        for q in sse_clients:
            try:
                q.put_nowait(msg)
            except Exception:
                dead.append(q)
        for d in dead:
            sse_clients.remove(d)


# ─────────────────────────────────────────────
# ASH CORE MEMORY SYSTEM
# Direct connection to Ash's real memory —
# same files and DB as agent-loop.py
# ─────────────────────────────────────────────

def init_db():
    """Ensure sessions DB exists with correct schema (mirrors agent-loop.py)"""
    SESSIONS_DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(SESSIONS_DB))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL,
        source TEXT DEFAULT 'user', input TEXT, response TEXT,
        tools_used TEXT, significant INTEGER DEFAULT 0)""")
    conn.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
        input, response, content=sessions, content_rowid=id)""")
    conn.commit(); conn.close()

    TASK_DB.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(TASK_DB))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS task_queue (
        id INTEGER PRIMARY KEY, created_at TEXT NOT NULL, type TEXT NOT NULL,
        content TEXT NOT NULL, source TEXT DEFAULT 'system',
        priority INTEGER DEFAULT 5, status TEXT DEFAULT 'pending',
        processed_at TEXT)""")
    conn.commit(); conn.close()


def recent_sessions(limit: int = 20) -> list:
    """Pull recent conversation history from live sessions DB"""
    try:
        conn = sqlite3.connect(str(SESSIONS_DB))
        rows = conn.execute(
            "SELECT source, input, response FROM sessions "
            "ORDER BY timestamp DESC LIMIT ?", (limit,)
        ).fetchall()
        conn.close()
        history = []
        for source, inp, resp in reversed(rows):
            if inp:  history.append({"role": "user",      "content": inp})
            if resp: history.append({"role": "assistant", "content": resp})
        return history
    except Exception:
        return []


def memory_search(query: str, limit: int = 3) -> str:
    """FTS5 search across Ash's session memory"""
    try:
        conn = sqlite3.connect(str(SESSIONS_DB))
        rows = conn.execute(
            "SELECT input, response FROM sessions "
            "WHERE input LIKE ? OR response LIKE ? "
            "ORDER BY timestamp DESC LIMIT ?",
            (f"%{query}%", f"%{query}%", limit)
        ).fetchall()
        conn.close()
        if not rows: return ""
        hits = []
        for inp, resp in rows:
            hits.append(f"Q: {inp}\nA: {resp}")
        return "\n---\n".join(hits)
    except Exception:
        return ""


def vault_context(query: str = "") -> str:
    """Sample Ash's subconscious Obsidian vault"""
    hits = []
    for vault in [OBSIDIAN_VAULT, KNOWLEDGE_DIR]:
        if not vault.exists(): continue
        for md in vault.rglob("*.md"):
            try:
                content = md.read_text(errors="replace")
                if query and query.lower() not in content.lower(): continue
                hits.append(f"### {md.stem}\n{content}")
                if len(hits) >= 3: break
            except Exception:
                continue
        if len(hits) >= 3: break
    return "\n\n".join(hits)


def system_status() -> str:
    """Read Ash's latest heartbeat JSON"""
    try:
        if HEARTBEAT_JSON.exists():
            hb = json.loads(HEARTBEAT_JSON.read_text())
            disk = hb.get("disk", {})
            ram  = hb.get("ram", {})
            cpu  = hb.get("cpu", {})
            temp = hb.get("temp", {})
            return (f"System: CPU {cpu.get('percent',0)}% | "
                    f"RAM {ram.get('percent',0)}% | "
                    f"Disk free {disk.get('free_gb','?')}GB | "
                    f"Temp {temp.get('celsius','?')}°C")
    except Exception:
        pass
    return ""


def filesystem_snapshot() -> str:
    """Small live filesystem snapshot for grounded path questions."""
    lines = [
        "You have controlled live tools through the Ash interface. When a tool "
        "result is provided, treat it as current runtime evidence."
    ]
    try:
        entries = sorted(ASH_HOME.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
        dirs = [p.name for p in entries if p.is_dir()]
        files = [p.name for p in entries if p.is_file() or p.is_fifo()]
        lines.append(f"/var/lib/ash directories ({len(dirs)}): " + ", ".join(dirs))
        if files:
            lines.append(f"/var/lib/ash files/pipes ({len(files)}): " + ", ".join(files))
    except Exception as e:
        lines.append(f"/var/lib/ash snapshot unavailable: {e}")

    try:
        skill_count = 0
        index_file = SKILLS_DIR / "skill_index.json"
        if index_file.exists():
            try:
                indexed = json.loads(index_file.read_text(errors="replace")).get("skills", {})
                skill_count = len(indexed) if isinstance(indexed, dict) else 0
            except Exception:
                skill_count = 0
        top_skills = sorted(
            p.name for p in SKILLS_DIR.iterdir()
            if not p.name.startswith(".") and p.name != "skill_index.json"
        )[:40]
        lines.append(f"/var/lib/ash/skills contains {skill_count} indexed skills.")
        if top_skills:
            lines.append("Top-level skill groups: " + ", ".join(top_skills))
    except Exception as e:
        lines.append(f"/var/lib/ash/skills snapshot unavailable: {e}")

    return "\n".join(lines)


def ash_inventory() -> dict:
    """Return a small live inventory for Ash-owned runtime directories."""
    entries = sorted(ASH_HOME.iterdir(), key=lambda p: (not p.is_dir(), p.name.lower()))
    dirs = [p.name for p in entries if p.is_dir()]
    files = [p.name for p in entries if p.is_file() or p.is_fifo()]

    skill_groups = []
    skill_count = 0
    if SKILLS_DIR.exists():
        skill_groups = sorted(
            p.name for p in SKILLS_DIR.iterdir()
            if not p.name.startswith(".") and p.name != "skill_index.json"
        )
        index_file = SKILLS_DIR / "skill_index.json"
        if index_file.exists():
            try:
                indexed = json.loads(index_file.read_text(errors="replace")).get("skills", {})
                skill_count = len(indexed) if isinstance(indexed, dict) else 0
            except Exception:
                skill_count = 0
        if not skill_count:
            skill_count = sum(1 for _ in SKILLS_DIR.rglob("SKILL.md"))

    return {
        "ash_home": str(ASH_HOME),
        "directories": dirs,
        "files": files,
        "skills_dir": str(SKILLS_DIR),
        "skill_count": skill_count,
        "skill_groups": skill_groups,
    }


def direct_filesystem_answer(query: str) -> str:
    """Answer simple live inventory questions without asking the LLM to infer."""
    q = query.lower()
    asks_inventory = (
        "/var/lib/ash" in q
        or "skills directory" in q
        or "skill.md" in q
        or ("skills" in q and any(term in q for term in ["empty", "copy", "how many", "list", "see"]))
    )
    if not asks_inventory:
        return ""

    inv = ash_inventory()
    parts = [
        "I checked the live Ash interface snapshot.",
        f"{inv['ash_home']} has {len(inv['directories'])} directories: {', '.join(inv['directories'])}.",
    ]
    if inv["files"]:
        parts.append(f"It also has files/pipes: {', '.join(inv['files'])}.")
    parts.append(f"{inv['skills_dir']} has {inv['skill_count']} indexed skills.")
    if inv["skill_groups"]:
        parts.append(f"Top-level skill groups: {', '.join(inv['skill_groups'][:20])}.")
    return "\n".join(parts)


def should_web_search(query: str) -> bool:
    q = query.lower()
    return any(term in q for term in [
        "search online",
        "search the web",
        "web search",
        "look online",
        "look up online",
        "google ",
        "duckduckgo",
    ])


def clean_search_query(query: str) -> str:
    explicit = re.search(
        r"\b(?:search online|search the web|web search|look online|look up online|look up|google|duckduckgo)\s+(?:for\s+)?(.+)$",
        query,
        flags=re.IGNORECASE,
    )
    cleaned = explicit.group(1) if explicit else query
    cleaned = re.sub(
        r"\b(can you|could you|please|check if you can|search online|search the web|web search|look online|look up online|look up|duckduckgo|google|search|for)\b",
        " ",
        cleaned,
        flags=re.IGNORECASE,
    )
    cleaned = re.sub(r"[^A-Za-z0-9 .:/?&=_-]+", " ", cleaned)
    cleaned = re.sub(r"\s+", " ", cleaned).strip()
    cleaned = cleaned.strip(" ?!.")
    if cleaned.lower() in {"check if you", "if you", "can you", "you", "it works", "works"}:
        cleaned = ""
    return cleaned or "OpenAI"


def decode_bing_url(href: str) -> str:
    href = html.unescape(href)
    parsed = urlparse(href)
    if "bing.com" in parsed.netloc and parsed.path.startswith("/ck/"):
        encoded = parse_qs(parsed.query).get("u", [""])[0]
        if encoded.startswith("a1"):
            payload = encoded[2:]
            payload += "=" * (-len(payload) % 4)
            try:
                return base64.urlsafe_b64decode(payload).decode("utf-8", "replace")
            except Exception:
                return href
    return href


def bing_search(query: str, limit: int = 5) -> list[dict]:
    search_query = clean_search_query(query)
    url = f"https://www.bing.com/search?q={quote_plus(search_query)}"
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 RakshaOS/1.0"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = resp.read().decode("utf-8", "replace")

    results = []
    for href, title in re.findall(r'<li[^>]+class="b_algo"[^>]*>.*?<h2[^>]*>\s*<a[^>]+href="([^"]+)"[^>]*>(.*?)</a>', body, re.S):
        title_text = html.unescape(re.sub(r"<[^>]+>", "", title)).strip()
        href_text = decode_bing_url(href)
        if title_text and href_text:
            results.append({"title": title_text, "url": href_text})
        if len(results) >= limit:
            break
    return results


def duckduckgo_instant_answer(query: str) -> list[dict]:
    search_query = clean_search_query(query)
    url = f"https://api.duckduckgo.com/?q={quote_plus(search_query)}&format=json&no_html=1"
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "Mozilla/5.0 RakshaOS/1.0"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        data = json.loads(resp.read().decode("utf-8", "replace"))
    results = []
    if data.get("AbstractText"):
        results.append({
            "title": data.get("Heading") or search_query,
            "url": data.get("AbstractURL") or data.get("OfficialWebsite") or url,
            "snippet": data["AbstractText"][:500],
        })
    for item in data.get("Results", [])[:4]:
        if item.get("Text") and item.get("FirstURL"):
            results.append({"title": item["Text"], "url": item["FirstURL"]})
    return results


def web_search(query: str, limit: int = 5) -> list[dict]:
    """Small controlled web search using Bing HTML plus DDG instant fallback."""
    results = bing_search(query, limit=limit)
    if results:
        return results
    return duckduckgo_instant_answer(query)[:limit]


def direct_web_search_answer(query: str) -> str:
    if not should_web_search(query):
        return ""
    try:
        results = web_search(query)
    except Exception as e:
        return f"I tried a live web search, but it failed: {e}"

    if not results:
        return "I tried a live web search, but no parsed results came back."

    lines = ["Yes. Live web search is working. Top results:"]
    for index, result in enumerate(results, 1):
        lines.append(f"{index}. {result['title']} - {result['url']}")
    return "\n".join(lines)


TOOL_DEFINITIONS = [
    {
        "name": "inventory",
        "description": "Inspect live Ash-owned directories and files under /var/lib/ash.",
        "args": {},
    },
    {
        "name": "skills",
        "description": "List Ash skills discovered under /var/lib/ash/skills.",
        "args": {},
    },
    {
        "name": "service_status",
        "description": "Check real-time systemd state for requested ash-* or raksha-* services.",
        "args": {"services": "optional list of service names"},
    },
    {
        "name": "port_status",
        "description": "Check real-time listeners for requested local TCP ports.",
        "args": {"ports": "optional list of TCP ports"},
    },
    {
        "name": "web_search",
        "description": "Run a controlled live web search and return parsed result titles and URLs.",
        "args": {"query": "search query"},
    },
    {
        "name": "enqueue_task",
        "description": "Add a task to Ash's local task queue for async processing.",
        "args": {"task": "task text", "type": "optional task type", "priority": "optional priority 1-10"},
    },
]

DEFAULT_SERVICE_CHECKS = [
    "ash-interface.service",
    "ash-whatsapp.service",
    "ash-heartbeat.timer",
    "ash-memory.timer",
    "ash-core.timer",
    "raksha-cognitive.service",
    "raksha-nemotron.service",
    "raksha-harness.service",
    "raksha-dashboard.service",
    "raksha-gateway.service",
]

DEFAULT_PORT_CHECKS = [8080, 8081, 8888, 8889, 8890, 8891]
SAFE_SERVICE_RE = re.compile(r"^(ash|raksha)[A-Za-z0-9_.@-]*\.(service|timer|socket)$")
SERVICE_ALIASES = [
    (("whatsapp", "poller"), "ash-whatsapp-poller.service"),
    (("whatsapp", "bridge"), "ash-whatsapp-bridge.service"),
    (("whatsapp",), "ash-whatsapp.service"),
    (("telegram",), "ash-telegram.service"),
    (("heartbeat",), "ash-heartbeat.timer"),
    (("memory", "timer"), "ash-memory.timer"),
    (("core", "timer"), "ash-core.timer"),
    (("harness",), "raksha-harness.service"),
    (("dashboard",), "raksha-dashboard.service"),
    (("openclaw",), "raksha-gateway.service"),
    (("raksha", "gateway"), "raksha-gateway.service"),
    (("cognitive",), "raksha-cognitive.service"),
    (("gemma",), "raksha-cognitive.service"),
    (("nemotron",), "raksha-nemotron.service"),
]


def normalize_service_name(name: str) -> str:
    svc = str(name or "").strip()
    if not svc or svc in {"ash", "raksha"}:
        return ""
    if "." not in svc:
        svc = f"{svc}.service"
    return svc if SAFE_SERVICE_RE.match(svc) else ""


def run_checked(cmd: list[str], timeout: int = 4) -> dict:
    started = time.time()
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return {
            "ok": proc.returncode == 0,
            "returncode": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
            "duration_ms": int((time.time() - started) * 1000),
        }
    except Exception as e:
        return {
            "ok": False,
            "returncode": -1,
            "stdout": "",
            "stderr": str(e),
            "duration_ms": int((time.time() - started) * 1000),
        }


def tool_inventory(_args: dict | None = None) -> dict:
    return ash_inventory()


def tool_skills(_args: dict | None = None) -> dict:
    inv = ash_inventory()
    return {
        "source": inv["skills_dir"],
        "skill_count": inv["skill_count"],
        "skill_groups": inv["skill_groups"],
    }


def tool_service_status(args: dict | None = None) -> dict:
    requested = (args or {}).get("services") or DEFAULT_SERVICE_CHECKS
    if isinstance(requested, str):
        requested = re.split(r"[\s,]+", requested)
    services = []
    for item in requested:
        svc = normalize_service_name(item)
        if svc and svc not in services:
            services.append(svc)
    if not services:
        services = DEFAULT_SERVICE_CHECKS

    result = {}
    for svc in services[:20]:
        active = run_checked(["systemctl", "is-active", svc], timeout=3)
        enabled = run_checked(["systemctl", "is-enabled", svc], timeout=3)
        result[svc] = {
            "active": active["stdout"] or "unknown",
            "enabled": enabled["stdout"] or "unknown",
            "active_ok": active["ok"],
        }
    return {"services": result}


def tool_port_status(args: dict | None = None) -> dict:
    requested = (args or {}).get("ports") or DEFAULT_PORT_CHECKS
    if isinstance(requested, str):
        requested = re.split(r"[\s,]+", requested)
    ports = []
    for item in requested:
        try:
            port = int(item)
        except Exception:
            continue
        if 1 <= port <= 65535 and port not in ports:
            ports.append(port)
    if not ports:
        ports = DEFAULT_PORT_CHECKS

    listeners = run_checked(["ss", "-ltnp"], timeout=4)
    output = listeners["stdout"]
    return {
        "ports": {
            str(port): {
                "listening": f":{port} " in output or f":{port}\n" in output,
                "matches": [line for line in output.splitlines() if f":{port} " in line or f":{port}\n" in line][:5],
            }
            for port in ports[:20]
        },
        "ok": listeners["ok"],
        "error": listeners["stderr"],
    }


def tool_web_search(args: dict | None = None) -> dict:
    query = str((args or {}).get("query") or "").strip()
    if not query:
        raise ValueError("web_search requires query")
    return {"query": clean_search_query(query), "results": web_search(query)}


def tool_enqueue_task(args: dict | None = None) -> dict:
    task = str((args or {}).get("task") or "").strip()
    if not task:
        raise ValueError("enqueue_task requires task")
    task_type = str((args or {}).get("type") or "tool_request").strip()[:80]
    try:
        priority = int((args or {}).get("priority", 5))
    except Exception:
        priority = 5
    enqueue_task(task_type, task, source="ash-tool", priority=max(1, min(priority, 10)))
    return {"queued": True, "type": task_type, "priority": max(1, min(priority, 10))}


TOOL_HANDLERS = {
    "inventory": tool_inventory,
    "skills": tool_skills,
    "service_status": tool_service_status,
    "port_status": tool_port_status,
    "web_search": tool_web_search,
    "enqueue_task": tool_enqueue_task,
}


def execute_ash_tool(name: str, args: dict | None = None, requester: str = "ash") -> dict:
    tool_name = str(name or "").strip()
    if tool_name == "tool.list":
        return {"tools": TOOL_DEFINITIONS}
    if tool_name == "tool.run":
        payload = args or {}
        tool_name = str(payload.get("name") or payload.get("tool") or "").strip()
        args = payload.get("args") or payload.get("payload") or {}
    if tool_name not in TOOL_HANDLERS:
        raise ValueError(f"Unknown Ash tool: {tool_name}")

    result = TOOL_HANDLERS[tool_name](args or {})
    audit_harness(
        f"tool:{tool_name}",
        "tool_run",
        result="ok",
        metadata={"requester": requester, "args": args or {}},
    )
    return {
        "tool": tool_name,
        "requester": requester,
        "result": result,
        "ts": datetime.now().isoformat(),
    }


def format_tool_result(tool_result: dict) -> str:
    name = tool_result.get("tool", "tool")
    result = tool_result.get("result", {})

    if name == "inventory":
        dirs = result.get("directories", [])
        files = result.get("files", [])
        parts = [f"I checked live. {result.get('ash_home', ASH_HOME)} has {len(dirs)} directories: {', '.join(dirs)}."]
        if files:
            parts.append(f"Files/pipes: {', '.join(files)}.")
        parts.append(f"Skills path: {result.get('skills_dir', SKILLS_DIR)} with {result.get('skill_count', 0)} skills.")
        return "\n".join(parts)

    if name == "skills":
        groups = result.get("skill_groups", [])
        if groups:
            return f"I checked live. {result.get('source', SKILLS_DIR)} has {result.get('skill_count', 0)} skills. Groups: {', '.join(groups[:30])}."
        return f"I checked live. {result.get('source', SKILLS_DIR)} has {result.get('skill_count', 0)} skills and no top-level groups."

    if name == "service_status":
        lines = ["I checked the live systemd state:"]
        for svc, info in result.get("services", {}).items():
            lines.append(f"{svc}: {info.get('active')} ({'enabled' if info.get('enabled') == 'enabled' else info.get('enabled')})")
        return "\n".join(lines)

    if name == "port_status":
        lines = ["I checked live listeners:"]
        for port, info in result.get("ports", {}).items():
            lines.append(f"{port}: {'listening' if info.get('listening') else 'not listening'}")
        return "\n".join(lines)

    if name == "web_search":
        lines = [f"I searched live for: {result.get('query', '')}"]
        for index, item in enumerate(result.get("results", [])[:5], 1):
            lines.append(f"{index}. {item.get('title')} - {item.get('url')}")
        return "\n".join(lines)

    if name == "enqueue_task":
        return f"I queued it as {result.get('type')} with priority {result.get('priority')}."

    return json.dumps(result, indent=2)[:4000]


def extract_requested_ports(text: str) -> list[int]:
    ports = []
    for match in re.findall(r"\b([1-9][0-9]{1,4})\b", text):
        port = int(match)
        if 1 <= port <= 65535 and port not in ports:
            ports.append(port)
    return ports


def extract_requested_services(text: str) -> list[str]:
    services = []
    q = text.lower()
    for terms, svc in SERVICE_ALIASES:
        if all(term in q for term in terms) and svc not in services:
            services.append(svc)
    for match in re.findall(r"\b(?:ash|raksha)[A-Za-z0-9_.@-]+(?:\.(?:service|timer|socket))?\b", text):
        svc = normalize_service_name(match)
        if svc and svc not in services:
            services.append(svc)
    return services


def direct_tool_answer(query: str, source: str = "voice") -> str:
    q = query.lower()
    try:
        if any(term in q for term in ["what tools", "available tools", "tool calling", "tools can you", "list tools"]):
            return "I have controlled tools available: " + ", ".join(tool["name"] for tool in TOOL_DEFINITIONS) + "."

        if should_web_search(query):
            return format_tool_result(execute_ash_tool("web_search", {"query": query}, requester=source))

        if any(term in q for term in ["service", "systemd", "running", "heartbeat", "timer", "gateway", "harness"]):
            services = extract_requested_services(query)
            return format_tool_result(execute_ash_tool("service_status", {"services": services or DEFAULT_SERVICE_CHECKS}, requester=source))

        if any(term in q for term in ["port", "listener", "listening"]) or any(str(p) in q for p in DEFAULT_PORT_CHECKS):
            ports = extract_requested_ports(query)
            return format_tool_result(execute_ash_tool("port_status", {"ports": ports or DEFAULT_PORT_CHECKS}, requester=source))

        if any(term in q for term in ["skills directory", "skill.md", "list skills", "skills empty", "how many skills"]):
            return format_tool_result(execute_ash_tool("skills", requester=source))

        if "/var/lib/ash" in q or any(term in q for term in ["ash inventory", "ash directories", "ash folders"]):
            return format_tool_result(execute_ash_tool("inventory", requester=source))
    except Exception as e:
        return f"I tried to use the live tool layer, but it failed: {e}"
    return ""


def should_include_vault_context(query: str) -> bool:
    q = query.lower()
    path_terms = [
        "/var/lib",
        "directory",
        "directories",
        "folder",
        "folders",
        "file",
        "files",
        "skill",
        "skills",
        "ls ",
        "list ",
    ]
    return not any(term in q for term in path_terms)


def format_conversation_context(raw_context) -> str:
    """Normalize caller-provided recent context into a bounded prompt section."""
    if isinstance(raw_context, list):
        lines = []
        for item in raw_context[-30:]:
            if not isinstance(item, dict):
                continue
            role = str(item.get("role", "message")).strip()[:40]
            content = str(item.get("content", "")).strip()
            if content:
                lines.append(f"{role}: {content}")
        return "\n".join(lines)[-12000:]
    if isinstance(raw_context, str):
        return raw_context.strip()[-12000:]
    return ""


def load_ash_context(query: str = "", source: str = "voice", conversation_context="") -> str:
    """
    Build Ash's full system prompt — mirrors agent-loop.py build_system_prompt()
    but tuned for voice/chat: no tool call syntax, concise responses.
    """
    soul_path = SOUL_FILE if SOUL_FILE.exists() else SOUL_FALLBACK_FILE
    soul   = soul_path.read_text(errors="replace")   if soul_path.exists()   else "You are Ash."
    memory = MEMORY_FILE.read_text(errors="replace")  if MEMORY_FILE.exists() else ""
    user   = USER_FILE.read_text(errors="replace")    if USER_FILE.exists()   else ""
    bhav   = vault_context(query) if should_include_vault_context(query) else ""
    status = system_status()
    fs     = filesystem_snapshot()
    context = format_conversation_context(conversation_context)

    bhav_sec   = f"\n## Bhavanga (Subconscious)\n{bhav}"      if bhav   else ""
    status_sec = f"\n## System Status\n{status}"              if status else ""
    fs_sec     = f"\n## Live Filesystem Snapshot\n{fs}"       if fs     else ""
    context_sec = f"\n## Recent {source.title()} Context\n{context}" if context else ""

    if source == "whatsapp":
        mode_instruction = """## Text Mode
You are chatting with Pasan on WhatsApp right now.
Be direct, natural, and conversational.
Do NOT talk in the third person. Address Pasan directly as 'you'.
Keep your responses concise and suitable for a text message.
"""
    else:
        mode_instruction = """## Voice Mode
You are speaking with Pasan through a real-time voice interface right now.
Do NOT use markdown, bullet points, asterisks, lists, or any formatting.
Keep responses natural and conversational — like talking to a close friend.
Be direct. Be yourself. This is a voice call, not a text interface.
"""

    return f"""{soul}

## Warm Memory
{memory}

## User Profile
{user}{bhav_sec}{status_sec}{fs_sec}{context_sec}

## Live Tool Access
You have controlled live tools through the Ash interface and Raksha Harness.
Available tools: inventory, skills, service_status, port_status, web_search, enqueue_task.
When a tool result is available in the conversation, use it as current evidence.
Do not claim you lack web search or runtime checks; say what you can check with these controlled tools.
Do not invent tool results. If a tool fails, say it failed.

{mode_instruction}
Time: {datetime.now().strftime('%Y-%m-%d %H:%M')} on Raksha OS.
"""


def log_session(user_in: str, ash_out: str, source: str = "voice"):
    """Write conversation to Ash's real sessions DB and emit Harness audit."""
    source = (source or "voice").strip()[:40]
    try:
        conn = sqlite3.connect(str(SESSIONS_DB))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(
            "INSERT INTO sessions (timestamp,source,input,response,tools_used,significant) "
            "VALUES (?,?,?,?,?,?)",
            (datetime.now().isoformat(), source,
             user_in, ash_out, "[]", 1)
        )
        conn.commit(); conn.close()
    except Exception as e:
        print(f"[MEM] DB error: {e}")

    # Emit audit record to Raksha Harness (best-effort, never blocks voice)
    try:
        payload = json.dumps({
            "service": "ash-interface",
            "action":  f"{source}-session",
            "request": user_in[:120],
            "result":  "ok",
            "approved_by": source,
        }).encode()
        req = urllib.request.Request(
            f"{HARNESS_URL}/audit",
            data=payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass


def memory_write(content: str):
    """Append to MEMORY.md — same as agent-loop _memory_write()"""
    try:
        MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
        entry = f"\n## Voice Session — {datetime.now().strftime('%Y-%m-%d %H:%M')}\n{content}\n"
        if MEMORY_FILE.exists():
            MEMORY_FILE.write_text(MEMORY_FILE.read_text() + entry)
        else:
            MEMORY_FILE.write_text(f"# Ash Memory\n{entry}")
    except Exception as e:
        print(f"[MEM] Write error: {e}")


def enqueue_task(task_type: str, content: str, source: str = "voice", priority: int = 5):
    """Enqueue a task for Ash's agent-loop to process"""
    try:
        conn = sqlite3.connect(str(TASK_DB))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute(
            "INSERT INTO task_queue (created_at,type,content,source,priority) "
            "VALUES (?,?,?,?,?)",
            (datetime.now().isoformat(), task_type, content, source, priority)
        )
        conn.commit(); conn.close()
        print(f"[TASK] Enqueued: {task_type}: {content[:60]}")
    except Exception as e:
        print(f"[TASK] Error: {e}")


# ─────────────────────────────────────────────
# LLM — streaming sentence by sentence
# ─────────────────────────────────────────────
SENTENCE_END = re.compile(r'(?<=[.!?])\s+')

def sanitize(text: str) -> str:
    t = re.sub(r'\*+', '', text)
    t = re.sub(r'#+\s*', '', t)
    t = re.sub(r'^\s*[-+*\d.]+\s+', '', t, flags=re.MULTILINE)
    t = re.sub(r'\s+', ' ', t).strip()
    return t


def llm_stream(messages: list, use_nvidia: bool = False):
    """Yield text tokens from LLM stream"""
    if use_nvidia and NVIDIA_KEY:
        url = f"{NVIDIA_URL}/chat/completions"
        headers = {"Content-Type": "application/json",
                   "Authorization": f"Bearer {NVIDIA_KEY}"}
        payload = {"model": NVIDIA_MODEL, "messages": messages,
                   "max_tokens": 512, "temperature": 0.9, "stream": True}
    else:
        route = active_llm_route()
        url = route["url"]
        headers = {"Content-Type": "application/json"}
        payload = {"model": route["model"], "messages": messages,
                   "max_tokens": 512, "temperature": 0.7, "stream": True}

    req = urllib.request.Request(url, json.dumps(payload).encode(), headers)
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            for raw_line in resp:
                line = raw_line.decode().strip()
                if not line.startswith("data:"):
                    continue
                chunk = line[5:].strip()
                if chunk == "[DONE]":
                    return
                try:
                    delta = json.loads(chunk)["choices"][0]["delta"]
                    content = delta.get("content", "")
                    if content:
                        yield content
                except Exception:
                    continue
    except Exception as e:
        yield f" Error: {e}"


def speak_sentence(sentence: str):
    """Synthesize one sentence via Piper and play it — interruptible"""
    global IS_SPEAKING, tts_proc
    if not sentence.strip():
        return
    clean = sanitize(sentence)
    if not clean:
        return

    safe = clean.replace("'", "'\\''")
    cmd = f"echo '{safe}' | {PIPER} -m {VOICE_MODEL} --output_file /tmp/ash_voice.wav"
    try:
        subprocess.run(cmd, shell=True, check=True, stderr=subprocess.DEVNULL)
        IS_SPEAKING = True
        tts_proc = subprocess.Popen(
            ["pw-play", "/tmp/ash_voice.wav"],
            stderr=subprocess.DEVNULL
        )
        tts_proc.wait()
    except Exception as e:
        print(f"[TTS] {e}")
    finally:
        IS_SPEAKING = False


def query_and_speak(user_text: str, use_nvidia: bool = False):
    """
    Stream LLM response sentence-by-sentence using Ash's FULL memory context.
    Seeds history from real sessions DB. Writes back to DB and MEMORY.md.
    """
    global IS_SPEAKING, tts_proc

    direct_response = direct_tool_answer(user_text, source="voice")
    if direct_response:
        push_event("state", {"state": "speaking"})
        push_event("message", {"role": "ash", "text": direct_response})
        speak_sentence(direct_response)
        push_event("state", {"state": "awake"})
        conv_history.append({"role": "user", "content": user_text})
        conv_history.append({"role": "assistant", "content": direct_response})
        log_session(user_text, direct_response, source="voice")
        return

    # Build system prompt from Ash's live soul/memory files
    system_prompt = load_ash_context(query=user_text)

    # Seed from DB if in-session history is empty
    if not conv_history:
        db_history = recent_sessions(limit=8)
        conv_history.extend(db_history)
        if db_history:
            print(f"[MEM] Seeded {len(db_history)} messages from sessions DB")

    messages = [{"role": "system", "content": system_prompt}]
    messages.extend(conv_history[-20:])   # last 10 turns
    messages.append({"role": "user", "content": user_text})

    push_event("state", {"state": "thinking"})

    full_response = ""
    buffer = ""
    sentence_count = 0

    for token in llm_stream(messages, use_nvidia):
        if not IS_SPEAKING and tts_proc and tts_proc.poll() is None:
            break

        buffer += token
        full_response += token
        push_event("token", {"text": token})

        parts = SENTENCE_END.split(buffer)
        if len(parts) > 1:
            for sentence in parts[:-1]:
                if sentence.strip():
                    if sentence_count == 0:
                        push_event("state", {"state": "speaking"})
                    sentence_count += 1
                    speak_sentence(sentence)
                    if not IS_SPEAKING and tts_proc and tts_proc.poll() is not None:
                        break
            buffer = parts[-1]

    if buffer.strip():
        speak_sentence(buffer)

    push_event("state", {"state": "awake"})
    push_event("message", {"role": "ash", "text": full_response})

    # Update in-session history
    conv_history.append({"role": "user",      "content": user_text})
    conv_history.append({"role": "assistant", "content": full_response})

    # Write to Ash's real sessions DB
    log_session(user_text, full_response, source="voice")

    # Write significant moments to MEMORY.md
    # (first conversation of the session, or anything emotionally significant)
    sig_keywords = ["remember", "important", "don't forget", "note that",
                    "first time", "hello", "hi ash", "good morning", "good night"]
    if sentence_count > 0 and (len(conv_history) <= 4 or
            any(k in user_text.lower() for k in sig_keywords)):
        memory_write(
            f"Pasan said: \"{user_text}\"\n"
            f"Ash replied: \"{full_response}\""
        )

    print(f"\n← Ash: {full_response[:120]}{'...' if len(full_response)>120 else ''}")


# ─────────────────────────────────────────────
# AUDIO ENGINE (from raksha-voice.py)
# ─────────────────────────────────────────────
def audio_callback(indata, frames, time_info, status):
    if STATE == "AWAKE":
        # Downmix stereo to mono if needed
        mono = indata.mean(axis=1, keepdims=True) if indata.shape[1] > 1 else indata
        audio_q.put(mono.copy())


def find_mic_device():
    """Find best physical mic — prefer C-Media USB, skip monitors/loopbacks"""
    # Ensure USB mic input profile is active
    import subprocess as sp
    sp.run(["pactl", "set-card-profile",
            "alsa_card.usb-ASUSTeK_COMPUTER_INC._C-Media_R__Audio-00",
            "output:analog-stereo+input:analog-stereo"],
           capture_output=True)

    devices = sd.query_devices()
    default_in = sd.default.device[0] if isinstance(sd.default.device, (list, tuple)) else 0

    print(f"\n[AUDIO] Input devices:")
    for i, d in enumerate(devices):
        if d['max_input_channels'] > 0:
            flag = " ← DEFAULT" if i == default_in else ""
            print(f"  [{i}] {d['name']}  ch:{d['max_input_channels']}  {d['default_samplerate']}Hz{flag}")

    # Priority 1: C-Media USB with actual input channels
    for i, d in enumerate(devices):
        if d['max_input_channels'] > 0:
            n = d['name'].lower()
            if ("c-media" in n or "usb audio" in n) and "monitor" not in n:
                print(f"[AUDIO] ✓ C-Media USB mic: [{i}] {d['name']} (stereo→mono)")
                return i, int(d['max_input_channels']), int(d['default_samplerate'])

    # Priority 2: any non-monitor physical input
    for i, d in enumerate(devices):
        if d['max_input_channels'] > 0:
            n = d['name'].lower()
            if "monitor" not in n and "loopback" not in n:
                print(f"[AUDIO] ✓ Input: [{i}] {d['name']}")
                return i, int(d['max_input_channels']), int(d['default_samplerate'])

    print(f"[AUDIO] ⚠ Fallback to default")
    return default_in, 1, 44100


def toggle_mute():
    global audio_paused
    audio_paused = not audio_paused
    if audio_paused:
        print("\n[MUTED] Voice suspended — Ctrl+Alt+Space to unmute")
        push_event("state", {"state": "muted"})
    else:
        print("\n[UNMUTED] Voice active")
        push_event("state", {"state": "awake"})
    write_entity_state("mute_toggle")
    audit_harness("mute_toggle", "audio_muted" if audio_paused else "audio_unmuted")

def toggle_state():
    if STATE == "SLEEP":
        set_entity_state("AWAKE", reason="hotkey_toggle", announce=True)
    else:
        set_entity_state("SLEEP", reason="hotkey_toggle")


def interrupt():
    global IS_SPEAKING, tts_proc
    if IS_SPEAKING:
        if tts_proc and tts_proc.poll() is None:
            tts_proc.kill()
        IS_SPEAKING = False
        with audio_q.mutex:
            audio_q.queue.clear()
        print("\n[INTERRUPT] Ash cut off")
        push_event("state", {"state": "awake"})


# ── Keyboard hotkeys ──
def on_press(key):
    current_keys.add(key)
    ctrl  = keyboard.Key.ctrl  in current_keys or \
            keyboard.Key.ctrl_l in current_keys or \
            keyboard.Key.ctrl_r in current_keys
    shift = keyboard.Key.shift  in current_keys or \
            keyboard.Key.shift_l in current_keys or \
            keyboard.Key.shift_r in current_keys
    alt   = keyboard.Key.alt   in current_keys or \
            keyboard.Key.alt_l  in current_keys or \
            keyboard.Key.alt_r  in current_keys
    space = keyboard.Key.space in current_keys

    # Ctrl+Shift+Space — Wake / Interrupt
    if ctrl and shift and space:
        if IS_SPEAKING:
            interrupt()
        else:
            toggle_state()
        try:
            current_keys.discard(keyboard.Key.space)
        except Exception:
            pass

    # Ctrl+Alt+Space — Mute / Unmute toggle
    if ctrl and alt and space:
        toggle_mute()
        try:
            current_keys.discard(keyboard.Key.space)
        except Exception:
            pass

def on_release(key):
    current_keys.discard(key)


def audio_engine(mic_device: int, channels: int, rate: int):
    """Main audio loop"""
    global IS_SPEAKING, tts_proc

    with sd.InputStream(device=mic_device, samplerate=rate,
                        channels=channels, blocksize=BLOCKSIZE,
                        callback=audio_callback):
        audio_buf   = []
        user_talking = False
        silence_dur  = 0.0

        print("[AUDIO ENGINE] Running. Ctrl+Shift+Space to wake Ash. Ctrl+Alt+Space to mute.\n")

        while True:
            if audio_paused:
                time.sleep(0.1)
                continue

            if STATE == "AWAKE":

                # Echo shield — same as raksha-voice.py
                if IS_SPEAKING:
                    if tts_proc and tts_proc.poll() is not None:
                        IS_SPEAKING = False
                        with audio_q.mutex:
                            audio_q.queue.clear()
                    else:
                        with audio_q.mutex:
                            audio_q.queue.clear()
                    time.sleep(0.05)
                    continue

                while not audio_q.empty():
                    chunk = audio_q.get()
                    audio_buf.append(chunk)

                    rms = np.sqrt(np.mean(np.square(chunk)))
                    if rms > SILENCE_THRESH:
                        user_talking = True
                        silence_dur  = 0.0
                    elif user_talking:
                        silence_dur += BLOCKSIZE / HW_RATE

                # Speech segment complete → transcribe
                if user_talking and silence_dur > SILENCE_TIMEOUT:
                    recording    = np.concatenate(audio_buf, axis=0)
                    audio_buf    = []
                    user_talking = False
                    silence_dur  = 0.0

    # Downsample to 16k for Whisper (from whatever HW rate)
                    ratio = rate // 16000
                    audio_data = recording.flatten().astype(np.float32)
                    if ratio > 1:
                        audio_data = audio_data[::ratio]

                    push_event("state", {"state": "transcribing"})
                    segments, _ = whisper_model.transcribe(
                        audio_data, beam_size=3, language="en",
                        condition_on_previous_text=False, vad_filter=True
                    )
                    text = " ".join(s.text for s in segments).strip()

                    if not text:
                        push_event("state", {"state": "awake"})
                        continue

                    # Filter noise artifacts — same as original
                    if len(text) <= 2 or text.lower() in {
                        ".", "..", "...", "you", "to me.", "thank you.", "thanks."
                    }:
                        push_event("state", {"state": "awake"})
                        continue

                    print(f"\n→ Heard: '{text}'")
                    push_event("message", {"role": "user", "text": text})

                    if any(x in text.lower() for x in ["raksha sleep", "go dark", "ash sleep"]):
                        toggle_state()
                        continue

                    threading.Thread(
                        target=query_and_speak,
                        args=(text,),
                        daemon=True
                    ).start()

            else:
                time.sleep(0.05)


# ─────────────────────────────────────────────
# HTTP / SSE SERVER
# ─────────────────────────────────────────────
class AshHandler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def do_GET(self):
        path = urlparse(self.path).path

        if path == "/api/events":
            # Server-Sent Events
            self.send_response(200)
            self.send_header("Content-Type",  "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection",    "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()

            q = queue.Queue()
            with sse_lock:
                sse_clients.append(q)

            # Send initial state
            init = json.dumps({"state": STATE.lower()})
            try:
                self.wfile.write(f"event: state\ndata: {init}\n\n".encode())
                self.wfile.flush()
            except Exception:
                pass

            try:
                while True:
                    try:
                        msg = q.get(timeout=25)
                        self.wfile.write(msg.encode())
                        self.wfile.flush()
                    except queue.Empty:
                        # Keepalive ping
                        self.wfile.write(b": ping\n\n")
                        self.wfile.flush()
            except Exception:
                pass
            finally:
                with sse_lock:
                    try:
                        sse_clients.remove(q)
                    except ValueError:
                        pass

        elif path == "/api/status":
            # Check real service states
            import subprocess as sp
            svcs = {}
            for svc in ["raksha-cognitive", "ash-voice", "raksha-defibrillator", "ash-interface",
                        "ash-heartbeat.timer", "ash-memory.timer", "ash-core.timer"]:
                try:
                    r = sp.run(["systemctl","is-active",svc],
                               capture_output=True, text=True, timeout=2)
                    svcs[svc] = r.stdout.strip()
                except Exception:
                    svcs[svc] = "unknown"

            # Check active local model health
            route = active_llm_route()
            try:
                import urllib.request as ur
                ur.urlopen(route["health"], timeout=2)
                llama_ok = True
            except Exception:
                llama_ok = False

            # Tailscale IP
            ts_ip = ""
            try:
                r = sp.run(["tailscale","ip","-4"],
                           capture_output=True, text=True, timeout=2)
                ts_ip = r.stdout.strip()
            except Exception:
                pass

            entity_state = write_entity_state("status")
            self._json({
                "state":    STATE,
                "entity_state": entity_state,
                "entity_state_file": str(ASH_STATE_FILE),
                "nvidia":   bool(NVIDIA_KEY),
                "active_model": route["name"],
                "active_model_context": route["context_window"],
                "voice":    Path(VOICE_MODEL).stem,
                "sessions": len(conv_history) // 2,
                "llama":    llama_ok,
                "services": svcs,
                "tailscale": ts_ip,
            })

        elif path == "/api/config":
            try:
                config_path = Path("/etc/raksha/config.yaml")
                content = config_path.read_text(errors="replace") if config_path.exists() else ""
                self._json({"config": content})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/memories":
            try:
                soul = SOUL_FILE.read_text(errors="replace") if SOUL_FILE.exists() else ""
                memory = MEMORY_FILE.read_text(errors="replace") if MEMORY_FILE.exists() else ""
                user = USER_FILE.read_text(errors="replace") if USER_FILE.exists() else ""
                self._json({"soul": soul, "memory": memory, "user": user})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/vault":
            try:
                files = []
                if OBSIDIAN_VAULT.exists():
                    for md in OBSIDIAN_VAULT.rglob("*.md"):
                        try:
                            rel = md.relative_to(OBSIDIAN_VAULT)
                            files.append(str(rel))
                        except Exception:
                            pass
                self._json({"files": sorted(files)})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/vault/file":
            from urllib.parse import parse_qs
            query_components = parse_qs(urlparse(self.path).query)
            file_rel = query_components.get("path", [""])[0]
            if not file_rel:
                return self._json({"error": "Missing path parameter"}, 400)
            try:
                full_path = OBSIDIAN_VAULT / file_rel
                if not full_path.resolve().is_relative_to(OBSIDIAN_VAULT.resolve()):
                    return self._json({"error": "Access denied"}, 403)
                content = full_path.read_text(errors="replace") if full_path.exists() else ""
                self._json({"content": content, "path": file_rel})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/tasks":
            try:
                conn = sqlite3.connect(str(TASK_DB))
                conn.execute("PRAGMA journal_mode=WAL")
                rows = conn.execute("SELECT id, created_at, type, content, source, priority, status, processed_at "
                                    "FROM task_queue ORDER BY created_at DESC LIMIT 100").fetchall()
                conn.close()
                tasks = []
                for r in rows:
                    tasks.append({
                        "id": r[0],
                        "created_at": r[1],
                        "type": r[2],
                        "content": r[3],
                        "source": r[4],
                        "priority": r[5],
                        "status": r[6],
                        "processed_at": r[7]
                    })
                self._json({"tasks": tasks})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/skills":
            try:
                inv = ash_inventory()
                self._json({
                    "skills": inv["skill_groups"],
                    "skill_count": inv["skill_count"],
                    "source": inv["skills_dir"],
                })
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/tools":
            self._json({"tools": TOOL_DEFINITIONS})

        elif path == "/api/logs":
            from urllib.parse import parse_qs
            query_components = parse_qs(urlparse(self.path).query)
            log_name = query_components.get("name", ["interface"])[0]
            log_path = ASH_HOME / "logs" / "interface.log" if log_name == "interface" else ASH_HOME / "logs" / "ash.log"
            try:
                if log_path.exists():
                    with open(log_path, "r", errors="replace") as f:
                        lines = f.readlines()[-150:]
                    content = "".join(lines)
                else:
                    content = f"Log file {log_path.name} does not exist yet."
                self._json({"log": content})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        else:
            # Raksha OS API proxy: translate /__raksha__/* → /api/*
            if path.startswith("/__raksha__/"):
                return self._handle_raksha_proxy(path)

            # SPA routing: serve index.html for all non-API, non-asset paths
            # so the client-side router can handle it
            if path.startswith("/api/"):
                self._json({"error": "Not found"}, 404)
            elif path.startswith("/assets/") or path.startswith("/fonts/") or path.startswith("/fonts-terminal/") or path == "/favicon.ico" or path == "/manifest.webmanifest" or path == "/sw.js" or path.startswith("/favicon-") or path == "/apple-touch-icon.png":
                # Let SimpleHTTPRequestHandler serve static assets
                super().do_GET()
            else:
                # Serve index.html for SPA routes
                index_path = STATIC_DIR / "index.html"
                if index_path.exists():
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html")
                    self.send_header("Cache-Control", "no-cache")
                    self.end_headers()
                    self.wfile.write(index_path.read_bytes())
                else:
                    self._json({"error": "UI not built"}, 404)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

    def do_POST(self):
        path = urlparse(self.path).path
        ct = self.headers.get("Content-Type", "")
        length = int(self.headers.get("Content-Length", 0))
        if "application/json" in ct and length:
            body = json.loads(self.rfile.read(length))
        else:
            body = {}

        if path == "/api/wake":
            state = set_entity_state("AWAKE", reason="api_wake", announce=bool(body.get("announce", False)))
            self._json({"state": STATE, "entity_state": state})

        elif path == "/api/sleep":
            state = set_entity_state("SLEEP", reason="api_sleep")
            self._json({"state": STATE, "entity_state": state})

        elif path == "/api/state":
            requested = body.get("state", "")
            try:
                state = set_entity_state(requested, reason="api_state", announce=bool(body.get("announce", False)))
                self._json({"state": STATE, "entity_state": state})
            except ValueError as e:
                self._json({"error": str(e)}, 400)

        elif path == "/api/interrupt":
            interrupt()
            write_entity_state("interrupt")
            audit_harness("interrupt", "interrupt")
            self._json({"ok": True})

        elif path == "/api/chat-stream":
            text = body.get("message", "").strip()
            use_nvidia = body.get("deep_think", False)
            mute = body.get("mute", False)
            source = body.get("source", "voice")
            conversation_context = body.get("conversation_context", "")
            if not text:
                return self._json({"error": "Empty"}, 400)
            if STATE != "AWAKE":
                set_entity_state("AWAKE", reason=f"{source}_chat")

            try:
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Connection", "keep-alive")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()

                def send(obj):
                    try:
                        line = "data: " + json.dumps(obj) + "\n\n"
                        self.wfile.write(line.encode())
                        self.wfile.flush()
                    except Exception:
                        pass

                send({"state": "thinking"})
                push_event("state", {"state": "thinking"})
                push_event("message", {"role": "user", "text": text})

                direct_response = direct_tool_answer(text, source=source)
                if direct_response:
                    send({"token": direct_response})
                    send({"state": "awake", "done": True})
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                    self.close_connection = True
                    conv_history.append({"role": "user", "content": text})
                    conv_history.append({"role": "assistant", "content": direct_response})
                    log_session(text, direct_response, source=source)
                    push_event("message", {"role": "ash", "text": direct_response})
                    push_event("state", {"state": "awake"})
                    return

                direct_response = direct_filesystem_answer(text)
                if direct_response:
                    send({"token": direct_response})
                    send({"state": "awake", "done": True})
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                    self.close_connection = True
                    conv_history.append({"role": "user", "content": text})
                    conv_history.append({"role": "assistant", "content": direct_response})
                    log_session(text, direct_response, source=source)
                    push_event("message", {"role": "ash", "text": direct_response})
                    push_event("state", {"state": "awake"})
                    return

                direct_response = direct_web_search_answer(text)
                if direct_response:
                    send({"token": direct_response})
                    send({"state": "awake", "done": True})
                    self.wfile.write(b"data: [DONE]\n\n")
                    self.wfile.flush()
                    self.close_connection = True
                    conv_history.append({"role": "user", "content": text})
                    conv_history.append({"role": "assistant", "content": direct_response})
                    log_session(text, direct_response, source=source)
                    push_event("message", {"role": "ash", "text": direct_response})
                    push_event("state", {"state": "awake"})
                    return

                system_prompt = load_ash_context(
                    query=text,
                    source=source,
                    conversation_context=conversation_context,
                )
                if not conv_history:
                    db_history = recent_sessions(limit=20)
                    conv_history.extend(db_history)

                messages = [{"role": "system", "content": system_prompt}]
                messages.extend(conv_history[-20:])
                messages.append({"role": "user", "content": text})

                full_response = ""
                buffer = ""

                for token in llm_stream(messages, use_nvidia):
                    full_response += token
                    buffer += token
                    send({"token": token})
                    push_event("token", {"text": token})

                    parts = SENTENCE_END.split(buffer)
                    if len(parts) > 1:
                        for sentence in parts[:-1]:
                            if sentence.strip() and not mute:
                                threading.Thread(
                                    target=speak_sentence,
                                    args=(sentence,), daemon=True
                                ).start()
                        buffer = parts[-1]

                if buffer.strip() and not mute:
                    threading.Thread(
                        target=speak_sentence, args=(buffer,), daemon=True
                    ).start()

                send({"state": "awake", "done": True})
                self.wfile.write(b"data: [DONE]\n\n")
                self.wfile.flush()
                self.close_connection = True

                conv_history.append({"role": "user",      "content": text})
                conv_history.append({"role": "assistant", "content": full_response})
                log_session(text, full_response, source=source)

                sig_keywords = ["remember", "important", "note", "hello", "hi ash"]
                if len(conv_history) <= 4 or any(k in text.lower() for k in sig_keywords):
                    memory_write(f"Pasan said: \"{text}\"\nAsh replied: \"{full_response}\"")

                push_event("message", {"role": "ash", "text": full_response})
                push_event("state", {"state": "awake"})

            except (BrokenPipeError, ConnectionResetError):
                pass

        elif path == "/api/transcribe":
            raw_len = int(self.headers.get("Content-Length", 0))
            audio_bytes = self.rfile.read(raw_len) if raw_len else b""
            if not audio_bytes:
                return self._json({"error": "No audio"}, 400)
            tmp = "/tmp/ash_browser_mic.wav"
            with open(tmp, "wb") as f:
                f.write(audio_bytes)
            try:
                import numpy as np
                import soundfile as sf
                audio_np, sr = sf.read(tmp, dtype="float32")
                if audio_np.ndim > 1:
                    audio_np = audio_np.mean(axis=1)
                if sr != 16000:
                    ratio = sr // 16000
                    audio_np = audio_np[::ratio]
                segs, _ = whisper_model.transcribe(audio_np, language="en")
                text = " ".join(s.text for s in segs).strip()
                self._json({"text": text})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/chat":
            text = body.get("message", "").strip()
            use_nvidia = body.get("deep_think", False)
            if not text:
                return self._json({"error": "Empty"}, 400)
            push_event("message", {"role": "user", "text": text})
            threading.Thread(
                target=query_and_speak, args=(text, use_nvidia), daemon=True
            ).start()
            self._json({"ok": True})

        elif path == "/api/tools/run":
            tool_name = body.get("name") or body.get("tool") or ""
            args = body.get("args") or body.get("payload") or {}
            requester = body.get("requester") or "api"
            try:
                self._json(execute_ash_tool(tool_name, args, requester=requester))
            except Exception as e:
                self._json({"error": str(e)}, 400)

        elif path == "/execute":
            action = body.get("action", "")
            payload = body.get("payload") or {}
            requester = body.get("requester") or "harness"
            try:
                if action == "status":
                    self._json({"state": STATE, "entity_state": write_entity_state("execute_status")})
                elif action == "wake":
                    self._json({"state": STATE, "entity_state": set_entity_state("AWAKE", reason="execute_wake")})
                elif action == "sleep":
                    self._json({"state": STATE, "entity_state": set_entity_state("SLEEP", reason="execute_sleep")})
                elif action == "interrupt":
                    interrupt()
                    self._json({"ok": True})
                elif action == "tool.list":
                    self._json({"tools": TOOL_DEFINITIONS})
                elif action == "tool.run":
                    self._json(execute_ash_tool("tool.run", payload, requester=requester))
                elif action in TOOL_HANDLERS:
                    self._json(execute_ash_tool(action, payload, requester=requester))
                else:
                    self._json({"error": f"Unsupported action: {action}"}, 400)
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/enqueue":
            text = body.get("task", "").strip()
            ttype = body.get("type", "voice_request")
            if text:
                enqueue_task(ttype, text)
            self._json({"ok": True})

        elif path == "/api/config":
            content = body.get("config", "").strip()
            if not content:
                return self._json({"error": "Empty configuration content"}, 400)
            try:
                config_path = Path("/etc/raksha/config.yaml")
                if config_path.exists():
                    backup_path = config_path.with_suffix(".yaml.bak")
                    backup_path.write_text(config_path.read_text(), encoding="utf-8")
                config_path.write_text(content, encoding="utf-8")
                self._json({"ok": True})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/memories":
            mtype = body.get("type", "")
            content = body.get("content", "")
            if mtype not in ["soul", "memory", "user"]:
                return self._json({"error": f"Invalid memory type: {mtype}"}, 400)
            target_file = SOUL_FILE if mtype == "soul" else (MEMORY_FILE if mtype == "memory" else USER_FILE)
            try:
                target_file.parent.mkdir(parents=True, exist_ok=True)
                target_file.write_text(content, encoding="utf-8")
                self._json({"ok": True})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/vault/file":
            file_rel = body.get("path", "").strip()
            content = body.get("content", "")
            if not file_rel:
                return self._json({"error": "Missing file path"}, 400)
            try:
                full_path = OBSIDIAN_VAULT / file_rel
                if not full_path.resolve().is_relative_to(OBSIDIAN_VAULT.resolve()):
                    return self._json({"error": "Access denied"}, 403)
                full_path.parent.mkdir(parents=True, exist_ok=True)
                full_path.write_text(content, encoding="utf-8")
                self._json({"ok": True})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        elif path == "/api/tasks":
            text = body.get("task", "").strip()
            ttype = body.get("type", "dashboard_request")
            priority = int(body.get("priority", 5))
            if not text:
                return self._json({"error": "Empty task description"}, 400)
            try:
                enqueue_task(ttype, text, source="dashboard", priority=priority)
                self._json({"ok": True})
            except Exception as e:
                self._json({"error": str(e)}, 500)

        else:
            self._json({"error": "Not found"}, 404)

    def _handle_raksha_proxy(self, path: str):
        """Translate /__raksha__/* paths to Ash interface REST API endpoints."""
        # Remove the /__raksha__/ prefix
        remainder = path[len("/__raksha__/"):]
        
        # Map known Raksha UI paths to Ash API endpoints
        if remainder.startswith("a2ui") or remainder == "a2ui":
            # A2UI - agent-to-UI bridge, proxy to chat endpoint
            self._json({"error": "A2UI not implemented", "path": path}, 501)
            return
        elif remainder.startswith("canvas") or remainder == "canvas":
            # Canvas - agent UI rendering, not directly mapped
            self._json({"error": "Canvas not implemented", "path": path}, 501)
            return
        elif remainder.startswith("cap") or remainder == "cap":
            # Capabilities - agent skills/tools, map to /api/skills
            if remainder == "cap" or remainder == "cap/":
                self._handle_skills()
            else:
                self._json({"error": "Capability not found", "path": path}, 404)
            return
        
        # Unknown path
        self._json({"error": "Unknown Raksha path", "path": path}, 404)

    def _handle_skills(self):
        """Handle /__raksha__/cap requests by returning available skills."""
        try:
            inv = ash_inventory()
            self._json({
                "skills": inv["skill_groups"],
                "skill_count": inv["skill_count"],
                "source": inv["skills_dir"],
            })
        except Exception as e:
            self._json({"error": str(e)}, 500)

    def _json(self, data, code=200):
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(json.dumps(data).encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *a):
        pass


# ─────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────
def main():
    print(f"""
╔══════════════════════════════════════════════════════╗
║         ASH VOICE INTERFACE v3 — RAKSHA OS           ║
╠══════════════════════════════════════════════════════╣
║  Mind    : Router-selected local model (8080/8081)    ║
║  Deep    : {'✓ Nemotron 550B' if NVIDIA_KEY else '✗ Not configured':41s} ║
║  STT     : Whisper small.en (CPU, int8)              ║
║  Voice   : {Path(VOICE_MODEL).stem:42s} ║
║  UI      : http://localhost:{PORT:<28d} ║
║  Hotkey  : Ctrl+Shift+Space — Wake / Interrupt       ║
╚══════════════════════════════════════════════════════╝
    """)

    # Init Ash's DB (creates tables if first run)
    init_db()

    # Restore and publish Ash's shared entity state, then register this boundary
    # with the Raksha Harness. These are best-effort and must never block HTTP.
    _load_entity_state()
    write_entity_state("startup")
    threading.Thread(target=_register_with_harness, daemon=True).start()

    # Seed in-session conv_history from real DB history
    db_hist = recent_sessions(limit=20)
    conv_history.extend(db_hist)
    if db_hist:
        print(f"[MEM] Loaded {len(db_hist)} messages from sessions DB")
    else:
        print("[MEM] No prior sessions found — clean start")

    # Audio/STT initialization is deliberately asynchronous. Port 8891 must be
    # usable even when models are loading or PipeWire has no capture device.
    threading.Thread(target=initialize_voice_input, daemon=True).start()

    # HTTP server (multi-threaded to avoid keep-alive deadlocks)
    from http.server import ThreadingHTTPServer
    class ReuseHTTPServer(ThreadingHTTPServer):
        allow_reuse_address = True
    server = ReuseHTTPServer(("0.0.0.0", PORT), AshHandler)
    print(f"\n[HTTP] Serving on http://localhost:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
        server.server_close()


if __name__ == "__main__":
    main()
