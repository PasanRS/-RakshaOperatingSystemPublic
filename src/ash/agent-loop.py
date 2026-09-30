#!/usr/bin/env python3
"""
ash-core — Ash's native reasoning loop
Raksha OS Native Agent — No framework dependencies
Talks directly to llama.cpp at port 8080
"""

import os
import sys
import json
import sqlite3
import subprocess
import urllib.request
import urllib.error
import select
import re
from datetime import datetime
from pathlib import Path

# === PATHS ===
ASH_HOME = Path(os.environ.get("ASH_HOME", "/var/lib/ash"))
LLAMA_URL = os.environ.get("LLAMA_URL", "http://127.0.0.1:8080/v1/chat/completions")
MODEL = os.environ.get("ASH_MODEL", "gemma-4-E2B_q4_0-it.gguf")
PIPE_PATH = ASH_HOME / "agent.pipe"
RESPONSE_PATH = ASH_HOME / "agent.response"
SESSIONS_DB = ASH_HOME / "memory" / "sessions.db"
TASK_DB = ASH_HOME / "tasks" / "queue.db"
LOG_FILE = ASH_HOME / "logs" / "ash.log"
SOUL_FILE = ASH_HOME / "identity" / "SOUL.md"
MEMORY_FILE = ASH_HOME / "memory" / "MEMORY.md"
USER_FILE = ASH_HOME / "memory" / "USER.md"
OBSIDIAN_VAULT = Path("/var/lib/raksha/obsidian/instincts/Vault")
ENV_FILE = ASH_HOME / "identity" / ".env"
MODEL_ROUTER_FILE = ASH_HOME / "harness" / "model-router.json"
LOCAL_MODEL_ROUTES = {
    "gemma": {
        "name": "Gemma 4 E2B",
        "url": "http://127.0.0.1:8080/v1/chat/completions",
        "model": "gemma-4-E2B_q4_0-it.gguf",
        "context_window": 131072,
    },
    "nemotron": {
        "name": "Nemotron 3 Nano",
        "url": "http://127.0.0.1:8081/v1/chat/completions",
        "model": "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf",
        "context_window": 1048576,
    },
}

# === NVIDIA DEEP BRAIN ===
def _load_env():
    """Load API keys from .env file"""
    if ENV_FILE.exists():
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip())

_load_env()

NVIDIA_API_KEY = os.environ.get("NVIDIA_API_KEY", "")
NVIDIA_BASE_URL = os.environ.get("NVIDIA_BASE_URL", "https://integrate.api.nvidia.com/v1")
NVIDIA_MODEL = os.environ.get("NVIDIA_MODEL", "nvidia/nemotron-3-ultra-550b-a55b")

def active_llm_route() -> dict:
    active = os.environ.get("ASH_ACTIVE_MODEL", "").strip().lower()
    if not active and MODEL_ROUTER_FILE.exists():
        try:
            active = json.loads(MODEL_ROUTER_FILE.read_text()).get("active", "").strip().lower()
        except Exception:
            active = ""
    return LOCAL_MODEL_ROUTES.get(active, {
        "name": "custom",
        "url": LLAMA_URL,
        "model": MODEL,
        "context_window": None,
    })


def log(msg: str, level: str = "INFO"):
    ts = datetime.now().isoformat(timespec="seconds")
    line = f"[{ts}] [{level}] {msg}"
    print(line, flush=True)
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def init_db():
    SESSIONS_DB.parent.mkdir(parents=True, exist_ok=True)
    TASK_DB.parent.mkdir(parents=True, exist_ok=True)

    conn = sqlite3.connect(str(SESSIONS_DB))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS sessions (
        id INTEGER PRIMARY KEY, timestamp TEXT NOT NULL,
        source TEXT DEFAULT 'user', input TEXT, response TEXT,
        tools_used TEXT, significant INTEGER DEFAULT 0)""")
    conn.execute("""CREATE VIRTUAL TABLE IF NOT EXISTS sessions_fts USING fts5(
        input, response, content=sessions, content_rowid=id)""")
    conn.commit(); conn.close()

    conn = sqlite3.connect(str(TASK_DB))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("""CREATE TABLE IF NOT EXISTS task_queue (
        id INTEGER PRIMARY KEY, created_at TEXT NOT NULL, type TEXT NOT NULL,
        content TEXT NOT NULL, source TEXT DEFAULT 'system',
        priority INTEGER DEFAULT 5, status TEXT DEFAULT 'pending', processed_at TEXT)""")
    conn.commit(); conn.close()


def load_memory() -> dict:
    memory = {}
    for key, path in [
        ("soul", SOUL_FILE), ("memory", MEMORY_FILE), ("user", USER_FILE)]:
        if path.exists():
            content = path.read_text(errors="replace")
            memory[key] = content
    return memory


def vault_context(query: str = "") -> str:
    if not OBSIDIAN_VAULT.exists():
        return ""
    hits = []
    for md in OBSIDIAN_VAULT.rglob("*.md"):
        try:
            content = md.read_text(errors="replace")
            if query and query.lower() not in content.lower():
                continue
            hits.append(f"### {md.stem}\n{content}")
            if len(hits) >= 3:
                break
        except Exception:
            continue
    return "\n\n".join(hits)


def build_system_prompt(memory: dict, query: str = "") -> str:
    soul = memory.get("soul", "You are Ash, native intelligence of Raksha OS.")
    mem  = memory.get("memory", "")
    user = memory.get("user", "")
    bhav = vault_context(query)
    bhav_section = f"\n## Bhavanga (Subconscious)\n{bhav}" if bhav else ""

    return f"""{soul}

## Warm Memory
{mem}

## User Profile
{user}{bhav_section}

## Time
{datetime.now().strftime('%Y-%m-%d %H:%M:%S')} — Raksha OS

## Tools
Emit tool calls as: <tool_call>{{"tool":"name","args":{{...}}}}</tool_call>
Available: read_file(path), write_file(path,content), search_files(query,path),
terminal(command), web_search(query), memory_search(query), memory_write(content), system_status(), deep_think(question), mcp_call(tool, args)

## Directive
Awareness not Permission. Know where things are. Act. Be direct.
"""


def llm_chat(messages: list, max_tokens: int = 1024) -> str:
    """Fast local mind — router-selected local llama.cpp model."""
    route = active_llm_route()
    payload = json.dumps({
        "model": route["model"], "messages": messages,
        "max_tokens": max_tokens, "temperature": 0.7, "stream": False
    }).encode()
    req = urllib.request.Request(route["url"], data=payload,
                                 headers={"Content-Type": "application/json"})
    try:
        resp = urllib.request.urlopen(req, timeout=120)
        return json.loads(resp.read())["choices"][0]["message"]["content"]
    except Exception as e:
        log(f"LLM error: {e}", "ERROR")
        return f"[Ash offline — {e}]"


def llm_think(messages: list, max_tokens: int = 16384) -> str:
    """Deep reasoning brain — NVIDIA Nemotron 550B with thinking"""
    if not NVIDIA_API_KEY:
        log("NVIDIA API key not set — falling back to local", "WARN")
        return llm_chat(messages, min(max_tokens, 1024))

    payload = json.dumps({
        "model": NVIDIA_MODEL, "messages": messages,
        "max_tokens": max_tokens, "temperature": 1, "top_p": 0.95,
        "stream": False,
        "extra_body": {
            "chat_template_kwargs": {"enable_thinking": True},
            "reasoning_budget": max_tokens,
        },
    }).encode()
    req = urllib.request.Request(
        f"{NVIDIA_BASE_URL}/chat/completions",
        data=payload,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {NVIDIA_API_KEY}",
        },
    )
    try:
        resp = urllib.request.urlopen(req, timeout=300)
        data = json.loads(resp.read())
        return data["choices"][0]["message"]["content"]
    except Exception as e:
        log(f"NVIDIA think error: {e} — falling back to local", "WARN")
        return llm_chat(messages, min(max_tokens, 1024))


def _system_status(_args):
    import shutil
    disk = shutil.disk_usage("/")
    try:
        mem = {l.split(":")[0]: int(l.split(":")[1].split()[0])
               for l in open("/proc/meminfo") if ":" in l and l.split(":")[1].strip()}
    except Exception:
        mem = {}
    total = mem.get("MemTotal", 1) // 1024
    avail = mem.get("MemAvailable", 0) // 1024
    return json.dumps({"disk": {"used_gb": round(disk.used/1e9,1), "free_gb": round(disk.free/1e9,1),
        "pct": round(disk.used/disk.total*100,1)},
        "ram": {"total_mb": total, "avail_mb": avail, "used_pct": round((1-avail/total)*100,1)},
        "time": datetime.now().isoformat()}, indent=2)

def _read_file(args):
    p = Path(args.get("path",""))
    return p.read_text(errors="replace")[:3000] if p.exists() else f"Not found: {p}"

def _write_file(args):
    p = Path(args.get("path",""))
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(args.get("content",""))
    return f"Written: {p}"

def _search_files(args):
    r = subprocess.run(["grep","-r","--include=*.md","-l",args.get("query",""),
        args.get("path", str(ASH_HOME))], capture_output=True, text=True, timeout=10)
    return r.stdout[:1000] or "No matches."

def _terminal(args):
    r = subprocess.run(args.get("command",""), shell=True,
        capture_output=True, text=True, timeout=30)
    return (r.stdout[:1500] + ("\n[STDERR] " + r.stderr[:300] if r.stderr else "")).strip()

def _memory_search(args):
    q = args.get("query","")
    conn = sqlite3.connect(str(SESSIONS_DB))
    rows = conn.execute("SELECT timestamp, source, input, response FROM sessions "
        "WHERE input LIKE ? OR response LIKE ? ORDER BY timestamp DESC LIMIT 5",
        (f"%{q}%", f"%{q}%")).fetchall()
    conn.close()
    return "\n---\n".join([f"[{r[0]}] {r[2]} → {r[3]}" for r in rows]) or "No memories."

def _memory_write(args):
    content = args.get("content","")
    entry = f"\n{datetime.now().strftime('%Y-%m-%d %H:%M')} — {content}\n"
    MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    if MEMORY_FILE.exists():
        MEMORY_FILE.write_text(MEMORY_FILE.read_text() + entry)
    else:
        MEMORY_FILE.write_text(f"# Ash Memory\n{entry}")
    return "Written."

def _web_search(args):
    q = args.get("query","").replace(" ","+")
    r = subprocess.run(["curl","-s","-L","--max-time","10",
        f"https://html.duckduckgo.com/html/?q={q}"], capture_output=True, text=True, timeout=15)
    text = re.sub(r'\s+',' ', re.sub(r'<[^>]+>',' ', r.stdout)).strip()
    return text[:1500] if r.returncode==0 else "Unavailable."

def _deep_think(args):
    """Escalate to NVIDIA Nemotron 550B for complex reasoning"""
    question = args.get("question", "")
    if not question:
        return "No question given."
    log(f"Deep think: {question[:80]}")
    messages = [{"role": "user", "content": question}]
    return llm_think(messages, max_tokens=4096)

def _mcp_call(args):
    """Call the local Ash Senses MCP Server"""
    tool = args.get("tool")
    tool_args = args.get("args", {})
    req = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": tool, "arguments": tool_args}}
    try:
        r = subprocess.run(["/usr/bin/python3", "/home/ravan/.local/bin/ash-senses/mcp-server/ash_senses.py"], input=json.dumps(req)+"\n", capture_output=True, text=True, timeout=10)
        res = json.loads(r.stdout.strip())
        return res["result"]["content"][0]["text"]
    except Exception as e:
        return f"MCP error: {e}"

TOOLS = {
    "system_status": _system_status, "read_file": _read_file,
    "write_file": _write_file, "search_files": _search_files,
    "terminal": _terminal, "memory_search": _memory_search,
    "memory_write": _memory_write, "web_search": _web_search,
    "deep_think": _deep_think, "mcp_call": _mcp_call,
}

def execute_tools(response: str) -> tuple:
    results = []
    for match in re.findall(r'<tool_call>(.*?)</tool_call>', response, re.DOTALL):
        try:
            call = json.loads(match.strip())
            name, args = call.get("tool",""), call.get("args",{})
            if name in TOOLS:
                log(f"Tool: {name}")
                results.append({"tool": name, "result": str(TOOLS[name](args))[:800]})
            else:
                results.append({"tool": name, "result": f"Unknown: {name}"})
        except Exception as e:
            results.append({"tool": "error", "result": str(e)})
    return response, results

def log_session(source, input_text, response, tools_used, significant=False):
    try:
        conn = sqlite3.connect(str(SESSIONS_DB))
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("INSERT INTO sessions (timestamp,source,input,response,tools_used,significant) "
            "VALUES (?,?,?,?,?,?)", (datetime.now().isoformat(), source,
            input_text, response, json.dumps(tools_used), int(significant)))
        conn.commit(); conn.close()
    except Exception as e:
        log(f"Session log error: {e}", "WARN")

    # Emit audit record to Raksha Harness
    try:
        harness_url = os.environ.get("HARNESS_URL", "http://127.0.0.1:8890")
        audit_payload = json.dumps({
            "service": "ash-core",
            "request": input_text[:120],
            "action": "session",
            "result": "ok",
            "approved_by": source,
            "metadata": {"tools": [t["tool"] for t in tools_used], "significant": significant},
        }).encode()
        req = urllib.request.Request(
            f"{harness_url}/audit",
            data=audit_payload,
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        urllib.request.urlopen(req, timeout=2)
    except Exception:
        pass  # Harness audit is best-effort — never block Ash

def get_pending_tasks():
    try:
        conn = sqlite3.connect(str(TASK_DB))
        rows = conn.execute("SELECT id,type,content,source FROM task_queue "
            "WHERE status='pending' ORDER BY priority DESC, created_at ASC LIMIT 5").fetchall()
        conn.close()
        return [{"id":r[0],"type":r[1],"content":r[2],"source":r[3]} for r in rows]
    except Exception:
        return []

def mark_done(task_id):
    try:
        conn = sqlite3.connect(str(TASK_DB))
        conn.execute("UPDATE task_queue SET status='done', processed_at=? WHERE id=?",
            (datetime.now().isoformat(), task_id))
        conn.commit(); conn.close()
    except Exception as e:
        log(f"Task update error: {e}", "WARN")

def enqueue_task(task_type, content, source="cli", priority=5):
    conn = sqlite3.connect(str(TASK_DB))
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("INSERT INTO task_queue (created_at,type,content,source,priority) VALUES (?,?,?,?,?)",
        (datetime.now().isoformat(), task_type, content, source, priority))
    conn.commit(); conn.close()
    log(f"Enqueued [{task_type}]: {content[:80]}")

def ensure_pipe():
    if not PIPE_PATH.exists():
        try:
            os.mkfifo(str(PIPE_PATH))
            os.chmod(str(PIPE_PATH), 0o666)
            log(f"IPC pipe: {PIPE_PATH}")
        except Exception as e:
            log(f"Pipe error: {e}", "WARN")

def check_pipe():
    if not PIPE_PATH.exists():
        return None
    try:
        fd = os.open(str(PIPE_PATH), os.O_RDONLY | os.O_NONBLOCK)
        r, _, _ = select.select([fd], [], [], 0.2)
        if r:
            data = os.read(fd, 8192).decode(errors="replace").strip()
            os.close(fd)
            return data or None
        os.close(fd)
    except Exception:
        pass
    return None

def process_task(task, memory):
    sp = build_system_prompt(memory, task.get("content",""))
    messages = [{"role":"system","content":sp}, {"role":"user","content":task["content"]}]
    response = llm_chat(messages)
    response, tools_used = execute_tools(response)
    if tools_used:
        tc = "\n".join([f"[{t['tool']}] → {t['result']}" for t in tools_used])
        messages += [{"role":"assistant","content":response},
                     {"role":"user","content":f"Tool results:\n{tc}\n\nContinue."}]
        response = llm_chat(messages, 512)
    log_session(task.get("source","system"), task["content"], response, tools_used, bool(tools_used))
    return response

def run_once():
    log("=== Ash — Tick ===")
    memory = load_memory()
    processed = 0

    # Named pipe (highest priority — real-time user input)
    pipe_input = check_pipe()
    if pipe_input:
        log(f"Pipe: {pipe_input[:80]}")
        resp = process_task({"type":"user","content":pipe_input,"source":"pipe"}, memory)
        RESPONSE_PATH.write_text(resp)
        processed += 1

    # Task queue
    for task in get_pending_tasks():
        log(f"Task {task['id']}: {task['type']} — {task['content'][:60]}")
        try:
            process_task(task, memory)
            mark_done(task["id"])
            processed += 1
        except Exception as e:
            log(f"Task {task['id']} error: {e}", "ERROR")

    log(f"Tick done — {processed} processed")

def main():
    log("Ash Core starting — Raksha OS")
    init_db()
    ensure_pipe()
    args = sys.argv[1:]

    if not args or "--once" in args:
        run_once()
    elif "--think" in args:
        idx = args.index("--think")
        question = " ".join(args[idx+1:]) if idx+1 < len(args) else ""
        if question:
            log(f"Deep think request: {question[:80]}")
            memory = load_memory()
            sp = build_system_prompt(memory, question)
            messages = [{"role": "system", "content": sp}, {"role": "user", "content": question}]
            response = llm_think(messages)
            print(response)
            log_session("think", question, response, [], True)
        else:
            print("Usage: ash --think 'your complex question'")
    elif "--enqueue" in args:
        idx = args.index("--enqueue")
        content = args[idx+1] if idx+1 < len(args) else ""
        source  = args[idx+2] if idx+2 < len(args) else "cli"
        if content: enqueue_task("user", content, source)
    elif "--skill" in args:
        idx = args.index("--skill")
        skill = args[idx+1] if idx+1 < len(args) else ""
        if skill:
            enqueue_task("skill", f"Execute skill: {skill}", "cron")
            run_once()
    elif "--status" in args:
        nvidia = "✓ Nemotron 550B" if NVIDIA_API_KEY else "✗ No API key"
        try:
            conn = sqlite3.connect(str(SESSIONS_DB))
            count = conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
            conn.close()
        except Exception:
            count = 0
        print(f"ASH_HOME : {ASH_HOME}")
        print(f"Pipe     : {PIPE_PATH} ({'exists' if PIPE_PATH.exists() else 'missing'})")
        route = active_llm_route()
        print(f"Local    : {route['name']} @ {route['url']}")
        print(f"Cloud    : {nvidia}")
        print(f"Sessions : {count}")

if __name__ == "__main__":
    main()
