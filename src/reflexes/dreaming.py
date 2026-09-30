#!/usr/bin/env python3
"""
Ash Dreaming (Memory Consolidation) Reflex — 3-Phase Architecture
Light: Ingest sessions, dedupe, stage candidates (no disk write)
REM:   Reflect on themes, write DREAMS.md entries (no MEMORY.md write)
Deep:  Score candidates with weighted ranking, promote to MEMORY.md

Config: /etc/raksha/config.yaml  [dreaming] section
"""

import sqlite3
import json
import urllib.request
import urllib.error
import os
import re
import math
from datetime import datetime, timezone, timedelta
from pathlib import Path
from collections import Counter, defaultdict

# --- Paths ---
SESSIONS_DB = Path("/var/lib/ash/memory/sessions.db")
MEMORY_FILE = Path("/var/lib/ash/memory/MEMORY.md")
DREAMS_DIARY = Path("/var/lib/ash/memory/DREAMS.md")
LOG_FILE = Path("/var/lib/ash/logs/memory.log")
CONFIG_PATH = Path("/etc/raksha/config.yaml")
PHASE_REPORTS_DIR = Path("/var/lib/ash/knowledge/kali-dreams")

# --- Defaults (overridden by config) ---
DEFAULT_WEIGHTS = {
    "relevance": 0.30,
    "frequency": 0.24,
    "query_diversity": 0.15,
    "recency": 0.15,
    "consolidation": 0.10,
    "conceptual_richness": 0.06,
}
DEFAULT_THRESHOLDS = {
    "min_score": 0.45,
    "min_recall_count": 2,
    "min_unique_queries": 1,
    "max_promoted_snippet_tokens": 160,
}
DEFAULT_LLM = {
    "model": "gemma-4-E2B_q4_0-it",
    "base_url": "http://127.0.0.1:8080/v1/chat/completions",
    "temperature": 0.3,
    "max_tokens": 1024,
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
def log(msg):
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write(f"[{datetime.now().isoformat()}] {msg}\n")
    print(msg)

# ---------------------------------------------------------------------------
# Config loader (minimal YAML parser — no external deps)
# ---------------------------------------------------------------------------
def _parse_yaml_value(val):
    """Best-effort scalar parse for the simple YAML we handle."""
    v = val.strip()
    if v.lower() in ("true", "yes"):
        return True
    if v.lower() in ("false", "no"):
        return False
    if v.lower() in ("null", "~"):
        return None
    try:
        return int(v)
    except ValueError:
        pass
    try:
        return float(v)
    except ValueError:
        pass
    return v.strip("'\"")

def load_config():
    """Parse the dreaming section from /etc/raksha/config.yaml."""
    cfg = {
        "weights": dict(DEFAULT_WEIGHTS),
        "thresholds": dict(DEFAULT_THRESHOLDS),
        "llm": dict(DEFAULT_LLM),
        "enabled_phases": {"light": True, "rem": True, "deep": True},
        "cadence_normal_hours": 2,
        "timezone": "Australia/Melbourne",
    }
    if not CONFIG_PATH.exists():
        log(f"Config not found at {CONFIG_PATH}, using defaults.")
        return cfg

    text = CONFIG_PATH.read_text(errors="replace")
    lines = text.splitlines()

    # Navigate to autonomic_reflexes -> dreaming section
    in_autonomic = False
    in_dreaming = False
    in_phases = False
    in_weights = False
    in_deep_ranking = False
    current_phase = None

    for raw_line in lines:
        stripped = raw_line.rstrip()
        if not stripped or stripped.lstrip().startswith("#"):
            continue
        indent = len(stripped) - len(stripped.lstrip())
        content = stripped.strip()

        # Top-level: autonomic_reflexes
        if content == "autonomic_reflexes:" and indent == 0:
            in_autonomic = True
            in_dreaming = False
            in_phases = False
            in_weights = False
            in_deep_ranking = False
            continue

        # Under autonomic_reflexes (indent 2)
        if in_autonomic and not in_dreaming:
            if content.startswith("dreaming:") and indent == 2:
                in_dreaming = True
                continue
            # Any other top-2-level key ends dreaming block
            if indent == 2 and content.endswith(":") and not content.startswith("dreaming"):
                in_dreaming = False
                in_autonomic = False
                continue
            continue

        # Under dreaming (indent 4)
        if in_dreaming and indent == 4:
            if content.startswith("phases:"):
                in_phases = True
                in_weights = False
                in_deep_ranking = False
                continue
            if content.startswith("deep_ranking:"):
                in_phases = False
                in_weights = False
                in_deep_ranking = True
                continue
            if content.startswith("enabled:"):
                cfg["enabled_phases"]["light"] = "true" in content.lower() or "yes" in content.lower()
                continue
            # Simple key: value pairs
            if ":" in content:
                key, _, val = content.partition(":")
                key = key.strip()
                val = val.strip()
                if key == "enabled":
                    cfg["enabled_phases"]["light"] = _parse_yaml_value(val) is True
                elif key == "cadence_normal_hours":
                    cfg["cadence_normal_hours"] = _parse_yaml_value(val)
                elif key == "log_path":
                    cfg["log_path"] = val
                elif key == "max_memory_file_bytes":
                    cfg["max_memory_file_bytes"] = _parse_yaml_value(val)
                elif key == "dreams_diary":
                    cfg["dreams_diary"] = val
                elif key == "phase_reports_dir":
                    cfg["phase_reports_dir"] = val
                elif key == "timezone":
                    cfg["timezone"] = val
                elif key == "summary_model":
                    cfg["llm"]["model"] = val
            continue

        # Under phases (indent 6)
        if in_phases and indent == 6:
            if content.endswith(":"):
                current_phase = content.rstrip(":")
                if current_phase in ("light", "rem", "deep"):
                    cfg["enabled_phases"][current_phase] = True
                continue
        if in_phases and indent == 8:
            if content.startswith("enabled:") and current_phase:
                cfg["enabled_phases"][current_phase] = _parse_yaml_value(content.split(":", 1)[1]) is True
            continue

        # Under deep_ranking (indent 6)
        if in_deep_ranking and indent == 6:
            if content.startswith("weights:"):
                in_weights = True
                continue
            if content.startswith("min_score"):
                cfg["thresholds"]["min_score"] = _parse_yaml_value(content.split(":", 1)[1])
            elif content.startswith("min_recall_count"):
                cfg["thresholds"]["min_recall_count"] = _parse_yaml_value(content.split(":", 1)[1])
            elif content.startswith("min_unique_queries"):
                cfg["thresholds"]["min_unique_queries"] = _parse_yaml_value(content.split(":", 1)[1])
            elif content.startswith("max_promoted_snippet_tokens"):
                cfg["thresholds"]["max_promoted_snippet_tokens"] = _parse_yaml_value(content.split(":", 1)[1])
            continue

        # Under deep_ranking -> weights (indent 8)
        if in_deep_ranking and in_weights and indent == 8 and ":" in content:
            key, _, val = content.partition(":")
            key = key.strip()
            if key in cfg["weights"]:
                cfg["weights"][key] = _parse_yaml_value(val)
            continue

    # Apply overrides from llm section if present
    if "llm" in cfg and "base_url" not in cfg["llm"]:
        cfg["llm"]["base_url"] = DEFAULT_LLM["base_url"]

    return cfg

# ---------------------------------------------------------------------------
# LLM helper
# ---------------------------------------------------------------------------
def call_llm(cfg, system_prompt, user_prompt, max_tokens=None):
    """Call the local LLM and return the text response."""
    max_tok = max_tokens or cfg["llm"].get("max_tokens", 1024)
    payload = json.dumps({
        "model": cfg["llm"]["model"],
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "temperature": cfg["llm"].get("temperature", 0.3),
        "max_tokens": max_tok,
        "stream": False,
    }).encode()

    url = cfg["llm"].get("base_url", DEFAULT_LLM["base_url"])
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    try:
        resp = urllib.request.urlopen(req, timeout=180)
        data = json.loads(resp.read())
        return data["choices"][0]["message"]["content"]
    except Exception as e:
        log(f"LLM call failed: {e}")
        return None

# ---------------------------------------------------------------------------
# Session ingestion
# ---------------------------------------------------------------------------
def get_recent_sessions(limit=100):
    """Read sessions from SQLite, return list of dicts in chronological order."""
    try:
        conn = sqlite3.connect(f"file:{SESSIONS_DB}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT id, timestamp, source, input, response, tools_used, significant "
            "FROM sessions ORDER BY timestamp DESC LIMIT ?",
            (limit,)
        ).fetchall()
        conn.close()
        return [dict(r) for r in reversed(rows)]
    except Exception as e:
        log(f"Error reading sessions: {e}")
        return []

# ---------------------------------------------------------------------------
# PHASE 1 — Light: ingest, dedupe, stage candidates
# ---------------------------------------------------------------------------
def phase_light(cfg):
    """
    Ingest recent sessions, deduplicate, and stage candidates.
    Returns a dict with staged data (no disk writes).
    """
    log("=== LIGHT PHASE: Ingest & Stage ===")
    sessions = get_recent_sessions(limit=100)
    if not sessions:
        log("No sessions to process.")
        return None

    log(f"Ingested {len(sessions)} sessions.")

    # Dedupe: group by normalized input text
    seen = {}
    unique = []
    for s in sessions:
        norm = re.sub(r"\s+", " ", (s.get("input") or "").strip().lower())
        if not norm:
            continue
        if norm in seen:
            seen[norm]["count"] += 1
            seen[norm]["ids"].append(s["id"])
        else:
            entry = {
                "id": s["id"],
                "timestamp": s["timestamp"],
                "source": s.get("source", "user"),
                "input": s.get("input", ""),
                "response": s.get("response", ""),
                "tools_used": s.get("tools_used", ""),
                "significant": s.get("significant", 0),
                "count": 1,
                "ids": [s["id"]],
            }
            seen[norm] = entry
            unique.append(entry)

    log(f"After dedup: {len(unique)} unique inputs.")

    # Stage candidates: filter out trivial/greeting inputs
    greetings = re.compile(
        r"^(hi|hey|hello|yo|sup|what'?s up|good morning|good evening|"
        r"good night|how are you|how'?s it going|ok|okay|thanks|thank you|"
        r"bye|goodbye|see you|model|)$",
        re.IGNORECASE,
    )
    candidates = []
    for u in unique:
        inp = u["input"].strip()
        if len(inp) < 5:
            continue
        if greetings.match(inp):
            continue
        candidates.append(u)

    log(f"Staged {len(candidates)} candidates (non-trivial, non-greeting).")

    return {
        "total_sessions": len(sessions),
        "unique_inputs": len(unique),
        "candidates": candidates,
        "raw_sessions": sessions,
    }

# ---------------------------------------------------------------------------
# PHASE 2 — REM: reflect on themes, write DREAMS.md entries
# ---------------------------------------------------------------------------
def phase_rem(cfg, light_data):
    """
    Reflect on staged candidates, extract themes, write dream diary entries.
    Returns the dream entry text (no MEMORY.md write).
    """
    log("=== REM PHASE: Reflect & Dream ===")
    if not light_data or not light_data.get("candidates"):
        log("No candidates to reflect on.")
        return None

    candidates = light_data["candidates"]

    # Build a compact summary for the LLM
    lines = []
    for c in candidates:
        ts = c["timestamp"]
        src = c["source"]
        inp = c["input"]
        resp = c["response"]
        lines.append(f"[{ts}] ({src}) Q: {inp}\n  A: {resp}")
    block = "\n---\n".join(lines)

    system = (
        "You are the REM reflection layer of Ash (Raksha OS). "
        "Analyze the following conversation extracts and identify recurring themes, "
        "emerging patterns, notable facts, and unresolved threads. "
        "Output a concise dream diary entry in markdown. "
        "Format: a short paragraph of reflection, then bullet points for distinct themes/patterns found. "
        "Do NOT write to MEMORY.md — only produce the diary entry text."
    )
    prompt = (
        f"Recent conversation extracts ({len(candidates)} candidates):\n\n{block}\n\n"
        "Reflect on these. What themes emerge? What patterns do you notice? "
        "Write a dream diary entry."
    )

    response = call_llm(cfg, system, prompt, max_tokens=768)
    if not response:
        log("REM phase: LLM returned no response.")
        return None

    # Append to DREAMS.md diary
    date_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    diary_entry = f"\n## Dream — {date_str}\n{response.strip()}\n"

    DREAMS_DIARY.parent.mkdir(parents=True, exist_ok=True)
    existing = DREAMS_DIARY.read_text(errors="replace") if DREAMS_DIARY.exists() else "# Ash Dream Diary\n"
    DREAMS_DIARY.write_text(existing.rstrip() + "\n" + diary_entry)
    log(f"REM phase: appended dream diary entry to {DREAMS_DIARY}")

    # Write phase report
    report_dir = Path(cfg.get("phase_reports_dir", str(PHASE_REPORTS_DIR))) / "rem"
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / f"{datetime.now().strftime('%Y-%m-%d')}.md"
    report_path.write_text(
        f"# REM Phase Report — {datetime.now().strftime('%Y-%m-%d %H:%M')}\n\n"
        f"Candidates analyzed: {len(candidates)}\n"
        f"Total sessions ingested: {light_data['total_sessions']}\n\n"
        f"## Dream Entry\n{response.strip()}\n",
        errors="replace",
    )
    log(f"REM phase: wrote report to {report_path}")

    return diary_entry

# ---------------------------------------------------------------------------
# PHASE 3 — Deep: score candidates, promote to MEMORY.md
# ---------------------------------------------------------------------------
def _tokenize(text):
    """Simple word tokenizer for diversity/richness scoring."""
    return re.findall(r"\b[a-z][a-z'-]{2,}\b", text.lower())

def _cosine_similarity(a, b):
    """Cosine similarity between two Counter vectors."""
    if not a or not b:
        return 0.0
    common = set(a.keys()) & set(b.keys())
    dot = sum(a[k] * b[k] for k in common)
    mag_a = math.sqrt(sum(v * v for v in a.values()))
    mag_b = math.sqrt(sum(v * v for v in b.values()))
    if mag_a == 0 or mag_b == 0:
        return 0.0
    return dot / (mag_a * mag_b)

def phase_deep(cfg, light_data):
    """
    Score candidates with weighted ranking, promote durable facts to MEMORY.md.
    Returns list of promoted items.
    """
    log("=== DEEP PHASE: Score & Promote ===")
    if not light_data or not light_data.get("candidates"):
        log("No candidates to score.")
        return []

    candidates = light_data["candidates"]
    weights = cfg.get("weights", DEFAULT_WEIGHTS)
    thresholds = cfg.get("thresholds", DEFAULT_THRESHOLDS)
    min_score = thresholds["min_score"]
    min_recall = thresholds["min_recall_count"]
    min_unique_q = thresholds["min_unique_queries"]
    max_snippet_tokens = thresholds["max_promoted_snippet_tokens"]

    # Build corpus stats
    all_inputs = [c["input"] for c in candidates]
    all_tokens = []
    for inp in all_inputs:
        all_tokens.extend(_tokenize(inp))
    token_freq = Counter(all_tokens)
    total_tokens = max(len(all_tokens), 1)

    # Compute reference vectors for relevance (pairwise similarity)
    candidate_vectors = []
    for c in candidates:
        tokens = _tokenize(c["input"] + " " + c["response"])
        candidate_vectors.append(Counter(tokens))

    # Score each candidate
    scored = []
    now = datetime.now(tz=timezone.utc)
    for i, c in enumerate(candidates):
        # --- Relevance: average similarity to other candidates ---
        sims = []
        for j, v in enumerate(candidate_vectors):
            if i == j:
                continue
            sims.append(_cosine_similarity(candidate_vectors[i], v))
        relevance = sum(sims) / max(len(sims), 1)

        # --- Frequency: how often this input appeared (normalized) ---
        freq_raw = c.get("count", 1)
        frequency = min(freq_raw / max(min_recall, 1), 3.0) / 3.0  # cap at 3x, normalize to [0,1]

        # --- Query diversity: unique tokens / total tokens in this input ---
        tokens = _tokenize(c["input"])
        unique_tokens = len(set(tokens))
        total = max(len(tokens), 1)
        query_diversity = unique_tokens / total

        # --- Recency: exponential decay based on age ---
        try:
            ts = datetime.fromisoformat(c["timestamp"].replace("Z", "+00:00"))
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
        except Exception:
            ts = now
        if ts.tzinfo is None:
            ts = ts.replace(tzinfo=timezone.utc)
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        age_hours = max((now - ts).total_seconds() / 3600.0, 0)
        recency = math.exp(-age_hours / 168.0)  # half-life ~1 week

        # --- Consolidation: is this already reflected in MEMORY.md? ---
        consolidation = 0.0
        if MEMORY_FILE.exists():
            mem_text = MEMORY_FILE.read_text(errors="replace").lower()
            key_tokens = set(tokens) - {"the", "a", "an", "is", "are", "was", "were",
                                          "in", "on", "at", "to", "for", "of", "and", "or",
                                          "this", "that", "it", "i", "you", "he", "she", "we",
                                          "they", "my", "your", "his", "her", "our", "their"}
            if key_tokens:
                overlap = sum(1 for t in key_tokens if t in mem_text)
                consolidation = overlap / len(key_tokens)

        # --- Conceptual richness: ratio of low-frequency (informative) tokens ---
        if tokens:
            rarity_scores = [1.0 - (token_freq.get(t, 0) / total_tokens) for t in set(tokens)]
            conceptual_richness = sum(rarity_scores) / len(rarity_scores)
        else:
            conceptual_richness = 0.0

        # Weighted sum
        score = (
            weights["relevance"] * relevance
            + weights["frequency"] * frequency
            + weights["query_diversity"] * query_diversity
            + weights["recency"] * recency
            + weights["consolidation"] * consolidation
            + weights["conceptual_richness"] * conceptual_richness
        )

        scored.append({
            "candidate": c,
            "score": round(score, 4),
            "components": {
                "relevance": round(relevance, 4),
                "frequency": round(frequency, 4),
                "query_diversity": round(query_diversity, 4),
                "recency": round(recency, 4),
                "consolidation": round(consolidation, 4),
                "conceptual_richness": round(conceptual_richness, 4),
            },
        })

    # Filter by thresholds
    passed = [
        s for s in scored
        if s["score"] >= min_score
        and s["candidate"].get("count", 1) >= min_recall
    ]

    # Count unique queries per candidate (rough: distinct inputs that share >50% tokens)
    unique_query_groups = defaultdict(set)
    for s in passed:
        tokens = set(_tokenize(s["candidate"]["input"]))
        for s2 in passed:
            if s["candidate"]["id"] == s2["candidate"]["id"]:
                continue
            other_tokens = set(_tokenize(s2["candidate"]["input"]))
            if tokens and other_tokens:
                overlap = len(tokens & other_tokens) / max(len(tokens), 1)
                if overlap > 0.5:
                    unique_query_groups[s["candidate"]["id"]].add(s2["candidate"]["id"])

    final = [
        s for s in passed
        if len(unique_query_groups[s["candidate"]["id"]]) + 1 >= min_unique_q
    ]

    # Sort by score descending
    final.sort(key=lambda x: x["score"], reverse=True)

    log(f"Scored {len(scored)} candidates: {len(final)} passed thresholds (score>={min_score}, recall>={min_recall}).")

    if not final:
        log("Deep phase: no candidates promoted.")
        return []

    # Promote: extract durable facts via LLM, append to MEMORY.md
    promotion_block = []
    for item in final[:10]:  # top 10 per cycle
        c = item["candidate"]
        snippet = c["input"]
        resp_snippet = c["response"]
        promotion_block.append(
            f"- Input: {snippet}\n  Response: {resp_snippet}\n  Score: {item['score']}"
        )

    system = (
        "You are the deep memory consolidation layer of Ash (Raksha OS). "
        "Given the following high-scoring memory candidates, extract concise, durable facts "
        "suitable for long-term retention. Output as a markdown bullet list. "
        "Each bullet should be a single, self-contained fact or insight. "
        f"Keep each bullet under {max_snippet_tokens} tokens. "
        "Do not include scoring metadata — only the fact."
    )
    prompt = (
        f"Promote these candidates to long-term memory:\n\n"
        + "\n---\n".join(promotion_block)
    )

    promoted_text = call_llm(cfg, system, prompt, max_tokens=512)
    if not promoted_text:
        log("Deep phase: LLM returned no promotion text.")
        # Still write a report with scores even if LLM fails
        report_dir = Path(cfg.get("phase_reports_dir", str(PHASE_REPORTS_DIR))) / "deep"
        report_dir.mkdir(parents=True, exist_ok=True)
        report_path = report_dir / f"{datetime.now().strftime('%Y-%m-%d')}.md"
        report_lines = [
            f"# Deep Phase Report — {datetime.now().strftime('%Y-%m-%d %H:%M')}\n",
            f"Total scored: {len(scored)}",
            f"Passed thresholds: {len(final)}\n",
            "## Scored Candidates\n",
        ]
        for s in final:
            c = s["candidate"]
            report_lines.append(f"- [{s['score']}] {c['input']}")
            report_lines.append(f"  Components: {s['components']}")
        report_lines.append("\n## Promoted Text\n[LLM unavailable — scoring completed, promotion skipped]")
        report_path.write_text("\n".join(report_lines), errors="replace")
        return []

    # Append to MEMORY.md
    date_str = datetime.now().strftime("%Y-%m-%d %H:%M")
    entry = f"\n## Memory Promotion: {date_str}\n{promoted_text.strip()}\n"

    MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    existing = MEMORY_FILE.read_text(errors="replace") if MEMORY_FILE.exists() else "# Ash Memory\n"
    MEMORY_FILE.write_text(existing.rstrip() + "\n" + entry)
    log(f"Deep phase: promoted {len(final)} candidates to {MEMORY_FILE}")

    # Enforce max file size
    max_bytes = cfg.get("max_memory_file_bytes", 8000)
    if MEMORY_FILE.exists() and MEMORY_FILE.stat().st_size > max_bytes:
        log(f"Deep phase: MEMORY.md exceeds {max_bytes} bytes, consider archiving.")

    # Write phase report
    report_dir = Path(cfg.get("phase_reports_dir", str(PHASE_REPORTS_DIR))) / "deep"
    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / f"{datetime.now().strftime('%Y-%m-%d')}.md"
    report_lines = [
        f"# Deep Phase Report — {datetime.now().strftime('%Y-%m-%d %H:%M')}\n",
        f"Total scored: {len(scored)}",
        f"Passed thresholds: {len(final)}\n",
        "## Scored Candidates\n",
    ]
    for s in final:
        c = s["candidate"]
        report_lines.append(f"- [{s['score']}] {c['input']}")
        report_lines.append(f"  Components: {s['components']}")
    report_lines.append(f"\n## Promoted Text\n{promoted_text.strip()}")
    report_path.write_text("\n".join(report_lines), errors="replace")
    log(f"Deep phase: wrote report to {report_path}")

    return final

# ---------------------------------------------------------------------------
# Main orchestrator
# ---------------------------------------------------------------------------
def main():
    log("=" * 60)
    log("Ash Dreaming Reflex — 3-Phase Cycle Starting")
    log("=" * 60)

    cfg = load_config()
    phases = cfg.get("enabled_phases", {"light": True, "rem": True, "deep": True})

    # Phase 1: Light
    light_data = None
    if phases.get("light", True):
        light_data = phase_light(cfg)
        # Write light phase report
        if light_data:
            report_dir = Path(cfg.get("phase_reports_dir", str(PHASE_REPORTS_DIR))) / "light"
            report_dir.mkdir(parents=True, exist_ok=True)
            report_path = report_dir / f"{datetime.now().strftime('%Y-%m-%d')}.md"
            report_lines = [
                f"# Light Phase Report — {datetime.now().strftime('%Y-%m-%d %H:%M')}\n",
                f"Total sessions: {light_data['total_sessions']}",
                f"Unique inputs: {light_data['unique_inputs']}",
                f"Candidates staged: {len(light_data['candidates'])}\n",
                "## Staged Candidates\n",
            ]
            for c in light_data["candidates"]:
                report_lines.append(f"- [{c['timestamp']}] ({c['source']}) {c['input']}")
            report_path.write_text("\n".join(report_lines), errors="replace")
            log(f"Light phase: wrote report to {report_path}")
    else:
        log("Light phase disabled.")

    # Phase 2: REM
    if phases.get("rem", True):
        phase_rem(cfg, light_data)
    else:
        log("REM phase disabled.")

    # Phase 3: Deep
    if phases.get("deep", True):
        phase_deep(cfg, light_data)
    else:
        log("Deep phase disabled.")

    log("=" * 60)
    log("Dreaming cycle complete.")
    log("=" * 60)

if __name__ == "__main__":
    main()
