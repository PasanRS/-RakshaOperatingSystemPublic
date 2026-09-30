#!/usr/bin/env python3
"""
Raksha OS Dashboard v2
========================
Harness-integrated system monitoring. Honcho completely removed.
Port: 8889 (fixed from 8080 which conflicts with llama.cpp)
"""
import asyncio, json, subprocess, os
from pathlib import Path
from datetime import datetime
from typing import Dict, Any, List, Optional
import psutil, httpx
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Raksha OS Dashboard", version="0.5.2")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

HARNESS_URL  = os.getenv("HARNESS_URL",  "http://localhost:8890")
LLAMA_URL    = os.getenv("LLAMA_URL",    "http://localhost:8080")
GATEWAY_URL  = os.getenv("GATEWAY_URL",  "http://localhost:8888")
ASH_HOME    = Path(os.getenv("ASH_HOME", "/var/lib/ash"))
MODEL_STATE_FILE = ASH_HOME / "harness" / "model-router.json"

LOCAL_MODELS = {
    "gemma": {
        "id": "gemma",
        "name": "Gemma 4 E2B",
        "service": "raksha-cognitive",
        "port": 8080,
        "base_url": "http://127.0.0.1:8080/v1",
        "health_url": "http://127.0.0.1:8080/health",
        "models_url": "http://127.0.0.1:8080/v1/models",
        "chat_url": "http://127.0.0.1:8080/v1/chat/completions",
        "model": "gemma-4-E2B_q4_0-it.gguf",
        "context_window": 131072,
    },
    "nemotron": {
        "id": "nemotron",
        "name": "Nemotron 3 Nano",
        "service": "raksha-nemotron",
        "port": 8081,
        "base_url": "http://127.0.0.1:8081/v1",
        "health_url": "http://127.0.0.1:8081/health",
        "models_url": "http://127.0.0.1:8081/v1/models",
        "chat_url": "http://127.0.0.1:8081/v1/chat/completions",
        "model": "NVIDIA-Nemotron3-Nano-4B-Q4_K_M.gguf",
        "context_window": 1048576,
    },
}

def _load_model_state() -> Dict[str, Any]:
    default = {"active": "gemma", "updated_at": None}
    try:
        if MODEL_STATE_FILE.exists():
            data = json.loads(MODEL_STATE_FILE.read_text())
            if data.get("active") in LOCAL_MODELS:
                return {**default, **data}
    except Exception:
        pass
    return default

def _save_model_state(model_id: str) -> Dict[str, Any]:
    if model_id not in LOCAL_MODELS:
        raise ValueError(f"Unknown model: {model_id}")
    state = {"active": model_id, "updated_at": datetime.now().isoformat()}
    MODEL_STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    MODEL_STATE_FILE.write_text(json.dumps(state, indent=2))
    return state

# Timer-triggered services (heartbeat, memory, dreaming, core) are one-shot:
# they run briefly then go inactive. Monitor the .timer units instead —
# those stay "active (waiting)" between runs.
MONITORED_SERVICES = [
    "raksha-gateway",        # openclaw gateway on port 8888 (replaces ash-interface)
    "raksha-cognitive",      # llama-server Gemma-4-E2B on port 8080
    "raksha-nemotron",       # llama-server Nemotron on port 8081
    "raksha-harness",        # executive control layer on port 8890
    "raksha-dashboard",      # this dashboard on port 8889
    "raksha-defibrillator",  # watchdog / crash recovery
    "ash-heartbeat.timer",   # liveness watchdog
    "ash-memory.timer",      # memory consolidation
    "ash-dreaming.timer",    # background dreaming engine
    "ash-core.timer",        # cognitive loop timer
    "ash-whatsapp-bridge",
    "ash-whatsapp-poller",
    "ash-whatsapp",
    "ash-telegram",
    "tailscaled",
]

class SystemMonitor:
    @staticmethod
    def get_service_status(svc: str) -> Dict[str, Any]:
        try:
            r = subprocess.run(["systemctl", "status", svc, "--no-pager"],
                               capture_output=True, text=True, timeout=5)
            # Accept both running (persistent) and waiting (timer units)
            active = ("active (running)" in r.stdout or
                      "active (waiting)" in r.stdout or
                      "active (exited)" in r.stdout)
            # Clean display name: strip .timer suffix for readability
            label = svc.removesuffix(".timer").removesuffix(".service")
            return {"service": label, "active": active}
        except Exception as e:
            return {"service": svc.removesuffix(".timer"), "active": False, "error": str(e)}

    @staticmethod
    def get_all_services() -> List[Dict[str, Any]]:
        return [SystemMonitor.get_service_status(s) for s in MONITORED_SERVICES]

    @staticmethod
    def get_resources() -> Dict[str, Any]:
        temp = None
        try:
            temps = psutil.sensors_temperatures()
            if "coretemp" in temps: temp = max(t.current for t in temps["coretemp"])
            elif "k10temp" in temps: temp = max(t.current for t in temps["k10temp"])
        except: pass
        return {
            "cpu_percent":  psutil.cpu_percent(interval=0.1),
            "memory":       psutil.virtual_memory()._asdict(),
            "disk":         psutil.disk_usage("/")._asdict(),
            "temperature":  temp,
            "uptime_epoch": int(psutil.boot_time()),
            "load_avg":     list(os.getloadavg()) if hasattr(os, "getloadavg") else [0,0,0],
        }

    @staticmethod
    async def get_harness() -> Dict[str, Any]:
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                h = await c.get(f"{HARNESS_URL}/health")
                k = await c.get(f"{HARNESS_URL}/capabilities")
                if h.status_code == 200:
                    return {
                        "status": "healthy",
                        "health": h.json(),
                        "capabilities": k.json().get("capabilities", []) if k.status_code == 200 else [],
                    }
        except: pass
        return {"status": "unreachable", "capabilities": []}

    @staticmethod
    async def get_audit(limit: int = 20) -> List[Dict]:
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                r = await c.get(f"{HARNESS_URL}/audit?limit={limit}")
                if r.status_code == 200: return r.json().get("records", [])
        except: pass
        # Fallback: read JSONL directly from disk
        af = ASH_HOME / "harness" / "audit.jsonl"
        recs = []
        if af.exists():
            for line in reversed(af.read_text().splitlines()):
                if line.strip():
                    try:
                        recs.append(json.loads(line))
                        if len(recs) >= limit: break
                    except: continue
        return recs

    @staticmethod
    async def get_llama() -> Dict[str, Any]:
        models = await SystemMonitor.get_models()
        return models.get("active", {"status": "unreachable"})

    @staticmethod
    async def _probe_model(model: Dict[str, Any]) -> Dict[str, Any]:
        out = dict(model)
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                h = await c.get(model["health_url"])
                out["status"] = "healthy" if h.status_code == 200 else "degraded"
                try:
                    m = await c.get(model["models_url"])
                    if m.status_code == 200:
                        data = m.json().get("data") or m.json().get("models") or []
                        if data:
                            first = data[0]
                            out["served_model"] = first.get("id") or first.get("model") or first.get("name")
                except Exception:
                    pass
                return out
        except Exception as e:
            out["status"] = "unreachable"
            out["error"] = str(e)
            return out

    @staticmethod
    async def get_models() -> Dict[str, Any]:
        state = _load_model_state()
        probed = []
        for model in LOCAL_MODELS.values():
            probed.append(await SystemMonitor._probe_model(model))
        by_id = {m["id"]: m for m in probed}
        active = by_id.get(state["active"], by_id["gemma"])
        return {
            "active_id": active["id"],
            "active": active,
            "models": probed,
            "state_file": str(MODEL_STATE_FILE),
            "updated_at": state.get("updated_at"),
        }

    @staticmethod
    async def get_gateway() -> Dict[str, Any]:
        """Poll the openclaw gateway health endpoint."""
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                r = await c.get(f"{GATEWAY_URL}/api/status")
                if r.status_code == 200:
                    data = r.json()
                    return {"status": "healthy", "version": data.get("version", "?")}
        except: pass
        # Fallback: just check if port responds
        try:
            async with httpx.AsyncClient(timeout=3) as c:
                r = await c.get(f"{GATEWAY_URL}/")
                if r.status_code in (200, 302, 401):
                    return {"status": "healthy", "version": "openclaw"}
        except: pass
        return {"status": "unreachable"}

    @staticmethod
    def get_ash_memory() -> Dict[str, Any]:
        try:
            mf = ASH_HOME / "memory" / "MEMORY.md"
            sd = ASH_HOME / "memory" / "sessions.db"
            hb = ASH_HOME / "logs" / "heartbeat-latest.json"
            hbd = {}
            if hb.exists(): hbd = json.loads(hb.read_text())
            return {
                "memory_size_kb":  round(mf.stat().st_size / 1024, 1) if mf.exists() else 0,
                "sessions_db_kb":  round(sd.stat().st_size / 1024, 1) if sd.exists() else 0,
                "heartbeat": hbd,
            }
        except: return {}

monitor = SystemMonitor()

DASHBOARD_HTML = """<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>Raksha OS Dashboard</title>
<style>
:root{--bg:#0a0a0f;--sf:#12121a;--sf2:#1a1a28;--ac:#7c3aed;--ac2:#4f46e5;
--g:#10b981;--y:#f59e0b;--r:#ef4444;--tx:#e2e8f0;--mu:#64748b;--br:#1e293b;}
*{margin:0;padding:0;box-sizing:border-box;}
body{background:var(--bg);color:var(--tx);font-family:'JetBrains Mono',monospace;font-size:13px;}
header{background:var(--sf);border-bottom:1px solid var(--br);padding:12px 24px;display:flex;align-items:center;gap:16px;}
h1{font-size:16px;font-weight:600;color:var(--ac);letter-spacing:.05em;}
.ts{color:var(--mu);font-size:11px;margin-left:auto;}
.doth{width:8px;height:8px;border-radius:50%;background:var(--g);box-shadow:0 0 6px var(--g);animation:p 2s infinite;}
@keyframes p{0%,100%{opacity:1}50%{opacity:.5}}
.grid{display:grid;grid-template-columns:1fr 1fr 1fr;gap:16px;padding:16px;}
.card{background:var(--sf);border:1px solid var(--br);border-radius:8px;padding:16px;}
.card h2{font-size:11px;color:var(--mu);text-transform:uppercase;letter-spacing:.1em;margin-bottom:12px;}
.m{display:flex;justify-content:space-between;align-items:center;padding:4px 0;border-bottom:1px solid var(--br);}
.m:last-child{border-bottom:none;}
.lb{color:var(--mu);}.vl{font-weight:600;}
.ok{color:var(--g);}.wn{color:var(--y);}.cr{color:var(--r);}
.sg{display:grid;grid-template-columns:1fr 1fr;gap:6px;}
.sv{display:flex;align-items:center;gap:8px;padding:6px 8px;background:var(--sf2);border-radius:4px;font-size:11px;}
.dot{width:6px;height:6px;border-radius:50%;flex-shrink:0;}
.dot.on{background:var(--g);box-shadow:0 0 4px var(--g);}.dot.off{background:var(--r);}
.cl{display:flex;flex-direction:column;gap:6px;}
.cp{padding:8px;background:var(--sf2);border-radius:4px;border-left:2px solid var(--ac);}
.cn{font-weight:600;color:var(--ac);}.ca{color:var(--mu);font-size:10px;margin-top:2px;}
.al{display:flex;flex-direction:column;gap:4px;max-height:260px;overflow-y:auto;}
.ar{padding:6px 8px;background:var(--sf2);border-radius:4px;font-size:11px;}
.ats{color:var(--mu);font-size:10px;}.st{color:var(--ac2);font-weight:600;}
.ro{color:var(--g);}.re{color:var(--r);}
.ctrls{display:flex;gap:8px;flex-wrap:wrap;}
.btn{padding:6px 14px;border:none;border-radius:4px;cursor:pointer;font-family:inherit;font-size:11px;font-weight:600;transition:opacity .15s;}
.btn:hover{opacity:.8;}.bv{background:var(--ac);color:white;}.bw{background:var(--y);color:#000;}
.bw2{background:var(--sf2);border-radius:4px;height:6px;overflow:hidden;margin-top:4px;}
.bar{height:100%;border-radius:4px;transition:width .5s;}
.bar.ok{background:var(--g);}.bar.wn{background:var(--y);}.bar.cr{background:var(--r);}
.full{grid-column:1/-1;}
</style></head><body>
<header>
<div class="doth" id="cdot"></div>
<h1>⬡ RAKSHA OS — SYSTEM DASHBOARD</h1>
<span class="ts" id="ts">connecting...</span>
</header>
<div class="grid">
<div class="card">
<h2>System Resources</h2>
<div class="m"><span class="lb">CPU</span><span class="vl" id="cpu">--</span></div>
<div class="bw2"><div class="bar ok" id="cpu-b" style="width:0%"></div></div>
<div class="m" style="margin-top:8px"><span class="lb">RAM</span><span class="vl" id="ram">--</span></div>
<div class="bw2"><div class="bar ok" id="ram-b" style="width:0%"></div></div>
<div class="m" style="margin-top:8px"><span class="lb">Disk</span><span class="vl" id="dsk">--</span></div>
<div class="bw2"><div class="bar ok" id="dsk-b" style="width:0%"></div></div>
<div class="m" style="margin-top:8px"><span class="lb">Temperature</span><span class="vl" id="tmp">--</span></div>
<div class="m"><span class="lb">Uptime</span><span class="vl" id="upt">--</span></div>
</div>
<div class="card">
<h2>Core Services</h2>
<div class="m"><span class="lb">Gateway :8888</span><span class="vl" id="gw">--</span></div>
<div class="m"><span class="lb">Harness :8890</span><span class="vl" id="hs">--</span></div>
<div class="m"><span class="lb">Capabilities</span><span class="vl" id="hc">--</span></div>
<div class="m"><span class="lb">Audit Records</span><span class="vl" id="ha">--</span></div>
<div class="m"><span class="lb">Active LLM</span><span class="vl" id="ll">--</span></div>
<div class="m"><span class="lb">Context Window</span><span class="vl" id="ctx">--</span></div>
<div class="m"><span class="lb">MEMORY.md</span><span class="vl" id="ms">--</span></div>
<div class="m"><span class="lb">Sessions DB</span><span class="vl" id="ss">--</span></div>
<div class="m"><span class="lb">Last Heartbeat</span><span class="vl" id="hbt">--</span></div>
<div class="m"><span class="lb">HB Alerts</span><span class="vl" id="hba">--</span></div>
</div>
<div class="card">
<h2>Ash Controls</h2>
<div class="ctrls">
<button class="btn bv" onclick="vc('mute')">🔇 Mute</button>
<button class="btn bv" onclick="vc('unmute')">🔊 Unmute</button>
<button class="btn bw" onclick="vc('restart')">↺ Voice</button>
<button class="btn bw" onclick="ac('restart')">↺ Ash</button>
<button class="btn bv" onclick="mc('gemma')">Gemma</button>
<button class="btn bv" onclick="mc('nemotron')">Nemotron</button>
</div>
<div id="cm" style="margin-top:12px;color:var(--mu);font-size:11px;"></div>
</div>
<div class="card full">
<h2>Local Model Router</h2>
<div class="sg" id="models"></div>
</div>
<div class="card full">
<h2>Resident Services</h2>
<div class="sg" id="svcs"></div>
</div>
<div class="card">
<h2>Registered Capabilities</h2>
<div class="cl" id="caps"><div style="color:var(--mu)">Waiting for Harness...</div></div>
</div>
<div class="card" style="grid-column:2/-1;">
<h2>Recent Audit Trail</h2>
<div class="al" id="audit"></div>
</div>
</div>
<script>
const ws=new WebSocket(`ws://${location.host}/ws`);
ws.onopen=()=>{document.getElementById('cdot').style.background='#10b981';document.getElementById('ts').textContent='connected';};
ws.onclose=()=>{document.getElementById('cdot').style.background='#ef4444';setTimeout(()=>location.reload(),5000);};
ws.onmessage=e=>{
const d=JSON.parse(e.data);
document.getElementById('ts').textContent=new Date().toLocaleTimeString();
const r=d.resources||{};
const cpu=r.cpu_percent||0,ram=r.memory?r.memory.percent:0,dsk=r.disk?r.disk.percent:0,tmp=r.temperature;
sv('cpu',`${cpu.toFixed(1)}%`,cpu>=90?'cr':cpu>=75?'wn':'ok');
sv('ram',`${ram.toFixed(1)}%`,ram>=85?'wn':'ok');
sv('dsk',`${dsk.toFixed(1)}%`,dsk>=95?'cr':dsk>=90?'wn':'ok');
sv('tmp',tmp?`${tmp.toFixed(1)}°C`:'N/A',tmp>=85?'cr':tmp>=75?'wn':'ok');
document.getElementById('upt').textContent=r.uptime_epoch?fmt(r.uptime_epoch):'--';
sb('cpu-b',cpu);sb('ram-b',ram);sb('dsk-b',dsk);
const gw=d.gateway||{};
sv('gw',gw.status==='healthy'?'● ONLINE':'○ OFFLINE',gw.status==='healthy'?'ok':'cr');
const h=d.harness||{};
sv('hs',h.status==='healthy'?'● ONLINE':'○ OFFLINE',h.status==='healthy'?'ok':'cr');
const caps=h.capabilities||[];
document.getElementById('hc').textContent=caps.length;
document.getElementById('ha').textContent=h.health?h.health.audit_records||'--':'--';
const mr=d.models||{},active=mr.active||{};
sv('ll',active.id?`${active.status==='healthy'?'●':'○'} ${active.name} :${active.port}`:'--',active.status==='healthy'?'ok':'wn');
document.getElementById('ctx').textContent=active.context_window?`${active.context_window} tokens`:'--';
const mdls=mr.models||[];
document.getElementById('models').innerHTML=mdls.map(m=>`<div class="sv"><div class="dot ${m.status==='healthy'?'on':'off'}"></div><span>${m.id===mr.active_id?'⬡ ':''}${m.name} :${m.port} · ctx ${m.context_window} · ${m.served_model||m.model}</span></div>`).join('');
const mem=d.ash_memory||{};
document.getElementById('ms').textContent=mem.memory_size_kb?`${mem.memory_size_kb} KB`:'--';
document.getElementById('ss').textContent=mem.sessions_db_kb?`${mem.sessions_db_kb} KB`:'--';
const hb=mem.heartbeat||{};
document.getElementById('hbt').textContent=hb.timestamp?hb.timestamp.substring(11,19):'--';
const al=hb.alerts||[];
const ae=document.getElementById('hba');
ae.textContent=al.length?al.join(', '):'None';ae.className=`vl ${al.length?'cr':'ok'}`;
const svcs=d.services||[];
document.getElementById('svcs').innerHTML=svcs.map(s=>`<div class="sv"><div class="dot ${s.active?'on':'off'}"></div><span>${s.service}</span></div>`).join('');
document.getElementById('caps').innerHTML=caps.length?caps.map(c=>`<div class="cp"><div class="cn">${c.name}</div><div class="ca">${(c.actions||[]).join(' · ')}</div><div class="ok" style="font-size:10px">${c.health||'?'}</div></div>`).join(''):'<div style="color:var(--mu)">None registered</div>';
const recs=d.audit||[];
document.getElementById('audit').innerHTML=recs.map(r=>`<div class="ar"><span class="ats">${(r.ts||'').substring(0,19)}</span><span class="st"> [${r.service}]</span> ${r.action}<span class="${r.result==='ok'?'ro':'re'}"> → ${r.result}</span>${r.error?` <span class="re">(${r.error})</span>`:''}</div>`).join('');
};
function sv(id,t,c){const e=document.getElementById(id);if(e){e.textContent=t;e.className=`vl ${c||''}`;}}
function sb(id,p){const e=document.getElementById(id);if(e){e.style.width=`${Math.min(100,p)}%`;e.className=`bar ${p>=95?'cr':p>=80?'wn':'ok'}`;}}
function fmt(b){const s=Math.floor(Date.now()/1000)-b;return`${Math.floor(s/3600)}h ${Math.floor(s%3600/60)}m`;}
async function vc(c){const m=document.getElementById('cm');m.textContent=`${c}...`;try{const r=await fetch(`/api/voice/${c}`,{method:'POST'});m.textContent=JSON.stringify(await r.json());}catch(ex){m.textContent=`Error: ${ex}`;}}
async function ac(c){const m=document.getElementById('cm');m.textContent='Restarting...';try{const r=await fetch(`/api/ash/${c}`,{method:'POST'});m.textContent=JSON.stringify(await r.json());}catch(ex){m.textContent=`Error: ${ex}`;}}
async function mc(model){const m=document.getElementById('cm');m.textContent=`Switching to ${model}...`;try{const r=await fetch('/api/models/active',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({model})});m.textContent=JSON.stringify(await r.json());}catch(ex){m.textContent=`Error: ${ex}`;}}
</script></body></html>"""

@app.get("/", response_class=HTMLResponse)
async def dashboard(): return HTMLResponse(content=DASHBOARD_HTML)

@app.get("/api/status")
async def api_status():
    h = await monitor.get_harness()
    a = await monitor.get_audit(20)
    gw = await monitor.get_gateway()
    models = await monitor.get_models()
    return {"timestamp": datetime.now().isoformat(), "services": monitor.get_all_services(),
            "resources": monitor.get_resources(), "harness": h, "gateway": gw,
            "llama": models["active"], "models": models,
            "ash_memory": monitor.get_ash_memory(), "audit": a}

@app.get("/api/gateway")
async def api_gateway(): return await monitor.get_gateway()

@app.get("/api/services")
async def api_services(): return monitor.get_all_services()

@app.get("/api/resources")
async def api_resources(): return monitor.get_resources()

@app.get("/api/harness")
async def api_harness(): return await monitor.get_harness()

@app.get("/api/audit")
async def api_audit(limit: int = 50):
    r = await monitor.get_audit(limit)
    return {"records": r, "count": len(r)}

@app.get("/api/llama")
async def api_llama(): return await monitor.get_llama()

@app.get("/api/models")
async def api_models(): return await monitor.get_models()

@app.post("/api/models/active")
async def api_model_active(body: Dict[str, str]):
    model_id = body.get("model", "").strip().lower()
    if model_id not in LOCAL_MODELS:
        return {"status": "error", "error": f"Unknown model '{model_id}'", "allowed": list(LOCAL_MODELS)}
    state = _save_model_state(model_id)
    return {"status": "ok", "active": model_id, "state": state, "models": await monitor.get_models()}

@app.get("/api/ash")
async def api_ash(): return monitor.get_ash_memory()

@app.post("/api/voice/{cmd}")
async def voice_cmd(cmd: str):
    async with httpx.AsyncClient(timeout=5) as c:
        try: r = await c.post(f"{HARNESS_URL}/voice/{cmd}"); return r.json()
        except Exception as e: return {"status": "error", "error": str(e)}

@app.post("/api/ash/restart")
async def ash_restart():
    async with httpx.AsyncClient(timeout=5) as c:
        try: r = await c.post(f"{HARNESS_URL}/ash/restart"); return r.json()
        except Exception as e: return {"status": "error", "error": str(e)}

@app.websocket("/ws")
async def ws_endpoint(websocket: WebSocket):
    await websocket.accept()
    try:
        while True:
            s = await api_status()
            await websocket.send_text(json.dumps(s, default=str))
            await asyncio.sleep(5)
    except (WebSocketDisconnect, Exception): pass

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8889, log_level="info")
