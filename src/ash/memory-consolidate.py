#!/usr/bin/env python3
"""
ash-memory — Dreaming and memory consolidation
Runs every 2h normally, full rebuild at 3am daily
"""
import json, sqlite3, sys, urllib.request
from datetime import datetime, timedelta
from pathlib import Path

ASH_HOME    = Path("/var/lib/ash")
SESSIONS_DB = ASH_HOME / "memory" / "sessions.db"
MEMORY_FILE = ASH_HOME / "memory" / "MEMORY.md"
KNOWLEDGE   = ASH_HOME / "knowledge"
LOG_FILE    = ASH_HOME / "logs" / "memory.log"
LLAMA_URL   = "http://127.0.0.1:8080/v1/chat/completions"
MODEL       = "gemma-4-E2B_q4_0-it.gguf"
MODEL_ROUTER_FILE = ASH_HOME / "harness" / "model-router.json"
LOCAL_MODEL_ROUTES = {
    "gemma": {
        "name": "Gemma 4 E2B",
        "url": "http://127.0.0.1:8080/v1/chat/completions",
        "model": "gemma-4-E2B_q4_0-it.gguf",
    },
    "nemotron": {
        "name": "Nemotron 3 Nano",
        "url": "http://127.0.0.1:8081/v1/chat/completions",
        "model": "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf",
    },
}
MEMORY_MAX  = 8000

def active_llm_route():
    active = ""
    if MODEL_ROUTER_FILE.exists():
        try:
            active = json.loads(MODEL_ROUTER_FILE.read_text()).get("active", "").strip().lower()
        except Exception:
            active = ""
    return LOCAL_MODEL_ROUTES.get(active, {
        "name": "custom",
        "url": LLAMA_URL,
        "model": MODEL,
    })

def log(msg):
    ts = datetime.now().isoformat(timespec="seconds")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a") as f: f.write(line + "\n")

def llm_distil(text):
    route = active_llm_route()
    payload = json.dumps({"model": route["model"], "messages": [
        {"role": "system", "content": "You are Ash's memory consolidator on Raksha OS. "
         "From these sessions extract: key facts, decisions, patterns. Bullet points. Concise."},
        {"role": "user", "content": text}],
        "max_tokens": 600, "temperature": 0.3, "stream": False}).encode()
    req = urllib.request.Request(route["url"], data=payload,
        headers={"Content-Type": "application/json"})
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        return json.loads(resp.read())["choices"][0]["message"]["content"]
    except Exception as e:
        return f"[distil failed: {e}]"

def rebuild_fts():
    if not SESSIONS_DB.exists(): return
    try:
        conn = sqlite3.connect(str(SESSIONS_DB))
        conn.execute("INSERT INTO sessions_fts(sessions_fts) VALUES('rebuild')")
        conn.commit(); conn.close()
        log("FTS5 rebuilt")
    except Exception as e:
        log(f"FTS5 error: {e}")

def archive_if_large():
    if not MEMORY_FILE.exists(): return
    content = MEMORY_FILE.read_text()
    if len(content) <= MEMORY_MAX: return
    KNOWLEDGE.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%d-%H%M")
    arc = KNOWLEDGE / f"memory-archive-{stamp}.md"
    arc.write_text(content)
    MEMORY_FILE.write_text(f"# Ash Memory\n*(Archived → {arc.name})*\n\n")
    log(f"Memory archived → {arc}")

def consolidate(full=False):
    log(f"=== Dream {'(FULL)' if full else ''} ===")
    if not SESSIONS_DB.exists():
        log("No sessions DB yet"); return

    hours = 168 if full else 24
    since = (datetime.now() - timedelta(hours=hours)).isoformat()
    conn  = sqlite3.connect(str(SESSIONS_DB))
    rows  = conn.execute("SELECT timestamp, source, input, response FROM sessions "
        "WHERE timestamp > ? ORDER BY timestamp", (since,)).fetchall()
    conn.close()

    if not rows:
        log("No sessions — nothing to consolidate")
        rebuild_fts(); return

    log(f"Processing {len(rows)} sessions")
    text = "\n---\n".join([
        f"[{r[0]}] ({r[1]}) Q: {r[2]} A: {r[3]}" for r in rows
    ])

    summary = llm_distil(text)
    archive_if_large()

    stamp = datetime.now().strftime("%Y-%m-%d %H:%M")
    entry = f"\n\n## Dream — {stamp}\n{summary}\n"
    MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    if MEMORY_FILE.exists():
        MEMORY_FILE.write_text(MEMORY_FILE.read_text() + entry)
    else:
        MEMORY_FILE.write_text(f"# Ash Memory\n{entry}")

    log("Dream complete")
    rebuild_fts()

if __name__ == "__main__":
    consolidate(full="--full" in sys.argv)
