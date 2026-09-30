#!/usr/bin/env python3
"""
Raksha OS Skill Engine — Antigravity Skill Integration
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Loads Antigravity skill bundles and exposes them as Ash's native capabilities.
Skills are loaded on-demand and injected into the system prompt context.
"""

import os
import json
import re
import subprocess
from pathlib import Path
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field
from functools import lru_cache

# ═══════════════════════════════════════════════════════
# PATHS
# ═══════════════════════════════════════════════════════
ANTIGRAVITY_ROOT = Path("/home/ravan/.gemini/antigravity-cli/skills")
SKILL_CACHE_FILE = Path("/var/lib/ash/skills/skill_index.json")
SKILL_CACHE_FILE.parent.mkdir(parents=True, exist_ok=True)

# ═══════════════════════════════════════════════════════
# DATA MODELS
# ═══════════════════════════════════════════════════════
@dataclass
class Skill:
    name: str
    bundle: str
    path: Path
    description: str = ""
    risk: str = "unknown"
    source: str = ""
    date_added: str = ""
    content: str = ""
    triggers: List[str] = field(default_factory=list)
    capabilities: List[str] = field(default_factory=list)
    prerequisites: List[str] = field(default_factory=list)
    related: List[str] = field(default_factory=list)

    def to_dict(self) -> Dict:
        return {
            "name": self.name,
            "bundle": self.bundle,
            "path": str(self.path),
            "description": self.description,
            "risk": self.risk,
            "source": self.source,
            "date_added": self.date_added,
            "triggers": self.triggers,
            "capabilities": self.capabilities,
            "prerequisites": self.prerequisites,
            "related": self.related,
        }

# ═══════════════════════════════════════════════════════
# SKILL LOADER
# ═══════════════════════════════════════════════════════
class SkillEngine:
    def __init__(self, root: Path = ANTIGRAVITY_ROOT):
        self.root = root
        self.skills: Dict[str, Skill] = {}
        self.bundles: Dict[str, List[str]] = {}
        self._indexed = False

    def index_all(self, force: bool = False) -> Dict[str, Skill]:
        """Scan all bundles and build skill index."""
        if self._indexed and not force:
            return self.skills

        self.skills = {}
        self.bundles = {}

        if not self.root.exists():
            print(f"[SKILL] Antigravity root not found: {self.root}")
            return self.skills

        for bundle_dir in sorted(self.root.iterdir()):
            if not bundle_dir.is_dir():
                continue

            bundle_name = bundle_dir.name
            skills_dir = bundle_dir / "skills"
            if not skills_dir.exists():
                # Check if bundle itself is a skill (has SKILL.md)
                skill_file = bundle_dir / "SKILL.md"
                if skill_file.exists():
                    skill = self._parse_skill(skill_file, bundle_name)
                    if skill:
                        self.skills[skill.name] = skill
                        self.bundles.setdefault(bundle_name, []).append(skill.name)
                continue

            # Bundle has skills/ subdirectory
            self.bundles[bundle_name] = []
            for skill_dir in sorted(skills_dir.iterdir()):
                if not skill_dir.is_dir():
                    continue
                skill_file = skill_dir / "SKILL.md"
                if skill_file.exists():
                    skill = self._parse_skill(skill_file, bundle_name)
                    if skill:
                        self.skills[skill.name] = skill
                        self.bundles[bundle_name].append(skill.name)

        self._indexed = True
        self._save_cache()
        print(f"[SKILL] Indexed {len(self.skills)} skills across {len(self.bundles)} bundles")
        return self.skills

    def _parse_skill(self, skill_file: Path, bundle: str) -> Optional[Skill]:
        """Parse a SKILL.md file."""
        try:
            content = skill_file.read_text(errors="replace")
            # Split frontmatter
            frontmatter = {}
            body = content
            if content.startswith("---"):
                parts = content.split("---", 2)
                if len(parts) >= 3:
                    frontmatter = self._parse_yaml_frontmatter(parts[1])
                    body = parts[2].strip()

            name = frontmatter.get("name", skill_file.parent.name)
            description = frontmatter.get("description", "")
            risk = frontmatter.get("risk", "unknown")
            source = frontmatter.get("source", "")
            date_added = frontmatter.get("date_added", "")

            # Extract triggers from "When to Use" section
            triggers = self._extract_triggers(body)
            capabilities = self._extract_capabilities(body)
            prerequisites = self._extract_prerequisites(body)
            related = self._extract_related(body)

            return Skill(
                name=name,
                bundle=bundle,
                path=skill_file.parent,
                description=description,
                risk=risk,
                source=source,
                date_added=str(date_added) if date_added else "",
                content=body,
                triggers=triggers,
                capabilities=capabilities,
                prerequisites=prerequisites,
                related=related,
            )
        except Exception as e:
            print(f"[SKILL] Failed to parse {skill_file}: {e}")
            return None

    def _extract_triggers(self, body: str) -> List[str]:
        """Extract trigger phrases from 'When to Use' section."""
        triggers = []
        for line in body.split("\n"):
            line = line.strip().lower()
            if any(kw in line for kw in ["when to use", "user mentions", "user implies", "applicable to"]):
                # Extract quoted phrases
                import re
                found = re.findall(r'["\']([^"\']+)["\']', line)
                triggers.extend(found)
        return triggers[:10]  # Limit

    def _extract_capabilities(self, body: str) -> List[str]:
        """Extract capabilities from content."""
        caps = []
        in_caps = False
        for line in body.split("\n"):
            if "## Capabilities" in line or "### Capabilities" in line or "### Expertise" in line:
                in_caps = True
                continue
            if in_caps and line.startswith("## "):
                break
            if in_caps and line.strip().startswith("-"):
                caps.append(line.strip()[1:].strip())
        return caps[:10]

    def _extract_prerequisites(self, body: str) -> List[str]:
        """Extract prerequisites."""
        prereqs = []
        in_pre = False
        for line in body.split("\n"):
            if "## Prerequisites" in line or "### Prerequisites" in line:
                in_pre = True
                continue
            if in_pre and line.startswith("## "):
                break
            if in_pre and line.strip().startswith("-"):
                prereqs.append(line.strip()[1:].strip())
        return prereqs

    def _extract_related(self, body: str) -> List[str]:
        """Extract related skills."""
        related = []
        for line in body.split("\n"):
            if "Related Skills" in line or "Works well with" in line:
                import re
                found = re.findall(r'`([^`]+)`', line)
                related.extend(found)
        return related

    def _parse_yaml_frontmatter(self, yaml_text: str) -> Dict:
        """Simple YAML frontmatter parser for basic key: value pairs."""
        result = {}
        for line in yaml_text.strip().split("\n"):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            # Handle key: value pairs
            match = re.match(r'^(\w+):\s*(.+)$', line)
            if match:
                key = match.group(1)
                value = match.group(2).strip()
                # Remove quotes
                if value.startswith('"') and value.endswith('"'):
                    value = value[1:-1]
                elif value.startswith("'") and value.endswith("'"):
                    value = value[1:-1]
                # Try to parse as bool/int/float
                if value.lower() in ("true", "false"):
                    value = value.lower() == "true"
                elif value.isdigit():
                    value = int(value)
                elif re.match(r'^-?\d+\.\d+$', value):
                    value = float(value)
                result[key] = value
        return result

    def _save_cache(self):
        """Save index to cache file."""
        try:
            data = {
                "skills": {k: v.to_dict() for k, v in self.skills.items()},
                "bundles": self.bundles,
            }
            SKILL_CACHE_FILE.write_text(json.dumps(data, indent=2))
        except Exception as e:
            print(f"[SKILL] Cache save failed: {e}")

    def load_cache(self) -> bool:
        """Load index from cache."""
        try:
            if SKILL_CACHE_FILE.exists():
                data = json.loads(SKILL_CACHE_FILE.read_text())
                for k, v in data.get("skills", {}).items():
                    # Ensure string fields
                    v["name"] = str(v.get("name", k))
                    v["bundle"] = str(v.get("bundle", ""))
                    v["description"] = str(v.get("description", ""))
                    v["risk"] = str(v.get("risk", "unknown"))
                    v["source"] = str(v.get("source", ""))
                    v["date_added"] = str(v.get("date_added", ""))
                    # Ensure lists
                    v["triggers"] = [str(t) for t in v.get("triggers", [])]
                    v["capabilities"] = [str(c) for c in v.get("capabilities", [])]
                    v["prerequisites"] = [str(p) for p in v.get("prerequisites", [])]
                    v["related"] = [str(r) for r in v.get("related", [])]
                    self.skills[k] = Skill(**v)
                self.bundles = {str(k): [str(s) for s in v] for k, v in data.get("bundles", {}).items()}
                self._indexed = True
                print(f"[SKILL] Loaded {len(self.skills)} skills from cache")
                return True
        except Exception as e:
            print(f"[SKILL] Cache load failed: {e}")
        return False

    # ═══════════════════════════════════════════════════════
    # QUERY METHODS
    # ═══════════════════════════════════════════════════════
    def get_skill(self, name: str) -> Optional[Skill]:
        """Get skill by name."""
        if not self._indexed:
            self.load_cache() or self.index_all()
        return self.skills.get(name)

    def find_skills(self, query: str, limit: int = 10) -> List[Skill]:
        """Find skills matching query (triggers, name, description)."""
        if not self._indexed:
            self.load_cache() or self.index_all()

        query = query.lower()
        scored = []
        for skill in self.skills.values():
            try:
                score = 0
                name = str(skill.name).lower()
                if query in name:
                    score += 10
                desc = str(skill.description).lower()
                if query in desc:
                    score += 5
                for t in skill.triggers:
                    if query in str(t).lower():
                        score += 8
                for c in skill.capabilities:
                    if query in str(c).lower():
                        score += 3
                if score > 0:
                    scored.append((score, skill))
            except Exception:
                continue

        scored.sort(key=lambda x: -x[0])
        return [s for _, s in scored[:limit]]

    def get_bundle_skills(self, bundle: str) -> List[Skill]:
        """Get all skills in a bundle."""
        if not self._indexed:
            self.load_cache() or self.index_all()
        names = self.bundles.get(bundle, [])
        return [self.skills[n] for n in names if n in self.skills]

    # ══════════════════════════════════════════════════════
    # CONTEXT INJECTION
    # ═══════════════════════════════════════════════════════
    def get_context_for_query(self, query: str, max_skills: int = 5, max_chars: int = 4000) -> str:
        """Get relevant skill context for a query."""
        skills = self.find_skills(query, limit=max_skills)
        if not skills:
            return ""

        context_parts = ["## Available Skills (Antigravity)"]
        total_chars = len(context_parts[0])

        for skill in skills:
            skill_text = f"""
### {skill.name} ({skill.bundle})
{skill.description}
**Capabilities:** {', '.join(skill.capabilities[:5]) if skill.capabilities else 'N/A'}
**Triggers:** {', '.join(skill.triggers[:5]) if skill.triggers else 'N/A'}
**Related:** {', '.join(skill.related[:5]) if skill.related else 'N/A'}
"""
            if total_chars + len(skill_text) > max_chars:
                break
            context_parts.append(skill_text)
            total_chars += len(skill_text)

        return "\n".join(context_parts)

    def get_core_skills_context(self, max_chars: int = 3000) -> str:
        """Get context for Ash's core identity skills."""
        core_names = [
            "ai-agents-architect", "prompt-engineering", "rag-engineer",
            "agent-memory-systems", "autonomous-agent-patterns", "multi-agent-patterns",
            "agent-orchestrator", "context-optimization", "context-window-management",
            "tool-use-guardian", "mcp-builder", "tool-design",
            "linux-shell-scripting", "bash-pro", "systems-programming",
            "security-audit", "threat-modeling-expert", "observability-engineer",
            "voice-agents", "voice-ai-development", "audio-transcriber",
            "debugging-toolkit", "systematic-debugging", "error-diagnostics-smart-debug",
        ]

        context_parts = ["## Core Identity Skills (Antigravity)"]
        total_chars = len(context_parts[0])

        for name in core_names:
            skill = self.skills.get(name)
            if not skill:
                continue
            skill_text = f"""
### {skill.name}
{skill.description[:500] if skill.description else 'No description'}
**Key Capabilities:** {', '.join(skill.capabilities[:5]) if skill.capabilities else 'N/A'}
"""
            if total_chars + len(skill_text) > max_chars:
                break
            context_parts.append(skill_text)
            total_chars += len(skill_text)

        return "\n".join(context_parts)

# ═══════════════════════════════════════════════════════
# SINGLETON
# ═══════════════════════════════════════════════════════
_engine: Optional[SkillEngine] = None

def get_skill_engine() -> SkillEngine:
    global _engine
    if _engine is None:
        _engine = SkillEngine()
        _engine.load_cache() or _engine.index_all()
    return _engine

# ═══════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════
def main():
    import argparse
    parser = argparse.ArgumentParser(description="Raksha OS Skill Engine")
    parser.add_argument("--index", action="store_true", help="Rebuild skill index")
    parser.add_argument("--search", metavar="QUERY", help="Search skills")
    parser.add_argument("--skill", metavar="NAME", help="Get skill details")
    parser.add_argument("--bundle", metavar="NAME", help="List skills in bundle")
    parser.add_argument("--context", metavar="QUERY", help="Get context for query")
    parser.add_argument("--core", action="store_true", help="Get core identity skills context")
    args = parser.parse_args()

    engine = get_skill_engine()

    if args.index:
        engine.index_all(force=True)
        return

    if args.search:
        results = engine.find_skills(args.search)
        for s in results:
            print(f"{s.name} ({s.bundle}) — {s.description[:80]}")
        return

    if args.skill:
        skill = engine.get_skill(args.skill)
        if skill:
            print(json.dumps(skill.to_dict(), indent=2))
        else:
            print(f"Skill not found: {args.skill}")
        return

    if args.bundle:
        skills = engine.get_bundle_skills(args.bundle)
        for s in skills:
            print(f"  {s.name}: {s.description[:60]}")
        return

    if args.context:
        print(engine.get_context_for_query(args.context))
        return

    if args.core:
        print(engine.get_core_skills_context())
        return

    # Default: show stats
    print(f"Total skills: {len(engine.skills)}")
    print(f"Total bundles: {len(engine.bundles)}")
    for bundle, skills in sorted(engine.bundles.items()):
        print(f"  {bundle}: {len(skills)} skills")

if __name__ == "__main__":
    main()