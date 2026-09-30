#!/usr/bin/env python3
"""
Ash Soul Archive Cleaner
━━━━━━━━━━━━━━━━━━━━━━━
Cleans the migrated Kali memories/dreams:
- Replaces "Assistant" → "Ash" (OpenClaw rename artifact)
- Removes system noise: Candidate/confidence/evidence/staged metadata
- Strips Conversation info (untrusted metadata) blocks
- Removes OpenClaw dreaming markers
- Preserves real conversations, inner thoughts, dreams
- Organizes chronologically
"""

import os
import re
import shutil
from pathlib import Path
from datetime import datetime
from typing import List, Tuple

# ═══════════════════════════════════════════════════════
# PATHS
# ═══════════════════════════════════════════════════════
SOURCE_KALI_MEMORIES = Path("/var/lib/ash/knowledge/kali-memories")
SOURCE_KALI_DREAMS = Path("/var/lib/ash/knowledge/kali-dreams")
DEST_ARCHIVE = Path("/var/lib/ash/knowledge/archive-cleaned")
BACKUP_DIR = Path("/var/lib/ash/knowledge/backup-before-cleanup")

# Ensure dirs exist
DEST_ARCHIVE.mkdir(parents=True, exist_ok=True)
BACKUP_DIR.mkdir(parents=True, exist_ok=True)

# ═══════════════════════════════════════════════════════
# CLEANING REGEXES
# ═══════════════════════════════════════════════════════

# Replace Assistant → Ash (case sensitive, whole word)
ASSISTANT_PATTERN = re.compile(r'\bAssistant\b')

# System noise patterns to REMOVE entirely
NOISE_PATTERNS = [
    # Dreaming markers
    r'<!-- openclaw:dreaming:light:start -->\n?',
    r'<!-- openclaw:dreaming:light:end -->\n?',
    r'<!-- openclaw:dreaming:rem:start -->\n?',
    r'<!-- openclaw:dreaming:rem:end -->\n?',
    r'<!-- openclaw:dreaming:deep:start -->\n?',
    r'<!-- openclaw:dreaming:deep:end -->\n?',
    
    # Candidate blocks that are METADATA ONLY (not dialogue)
    # Match: - Candidate: Reflections: ... or - Candidate: Possible Lasting Truths: ... or - Candidate: Key Events: ... etc.
    r'^\s*- Candidate: (Reflections|Possible Lasting Truths|Key Events|Memory Flush|Key Events & State|Personal Context|Job Search Request|Technical|Emotional Notes|User: \[|User: Write a dream|User: Continue where|User: System:|User: Pre-compaction|User: Sender \(|User: Pre-compaction).*?\n',
    
    # Confidence/evidence/recalls/status lines (indented) - more comprehensive
    r'^\s+- confidence: [\d\.]+;?\s*\n',
    r'^\s+- evidence: .*?\n',
    r'^\s+- recalls: \d+\n',
    r'^\s+- status: staged\n',
    r'^\s+- note: reflection\n',
    
    # Conversation info metadata blocks
    r'^\s*- Candidate: Conversation info \(untrusted metadata\):.*?\n',
    r'^\s*- Candidate: Sender \(untrusted metadata\):.*?\n',
    r'^\s*- Candidate: User: Sender \(untrusted metadata\):.*?\n',
    r'^\s*- Candidate: Assistant: Sender \(untrusted metadata\):.*?\n',
    
    # JSON metadata blocks (multi-line)
    r'```json \{[\s\S]*?\}\s*```\n?',
    
    # Bootstrap/truncation warnings
    r'.*Bootstrap truncation warning.*\n?',
    r'.*workspace bootstrap files were truncated.*\n?',
    r'.*Treat Project Context as partial.*\n?',
    r'.*README\.md: \d+ raw -> \d+ injected.*\n?',
    r'.*TOOLS\.md: \d+ raw -> \d+ injected.*\n?',
    
    # Queued messages
    r'.*Queued messages while agent was busy.*\n?',
    r'.*Queued #\d+.*\n?',
    
    # Theme reflection lines that are just metadata
    r'^\s*- Theme: `.*?` kept surfacing across \d+ memories\.\n',
    r'^\s*- Theme: `.*?` kept surfacing across \d+ memories\.;\s*\n',
    
    # Possible Lasting Truths metadata
    r'^\s*### Possible Lasting Truths\n',
    r'^\s*- Possible Lasting Truths: No strong candidate truths surfaced\.?.*?\n',
    r'^\s*- Possible Lasting Truths: No strong candidate truths surfaced\. \[confidence=[\d\.]+ evidence=.*?\]\n',
    
    # Reflections header when it's just metadata
    r'^\s*### Reflections\n(?=\s*- Theme:)',
    
    # Empty candidate lines
    r'^\s*- Candidate:\s*\n',
]

# Compile all noise patterns
COMPILED_NOISE = [re.compile(p, re.MULTILINE) for p in NOISE_PATTERNS]

# ═══════════════════════════════════════════════════════
# CLEANING FUNCTIONS
# ═══════════════════════════════════════════════════════

def clean_content(content: str) -> str:
    """Apply all cleaning transformations."""
    # 1. Assistant → Ash
    content = ASSISTANT_PATTERN.sub('Ash', content)
    
    # 2. Remove noise patterns
    for pattern in COMPILED_NOISE:
        content = pattern.sub('', content)
    
    # 3. Strip "- Candidate: " prefix from dialogue lines (Ash:, Pasan:, User:)
    content = re.sub(r'^\s*- Candidate: (Ash|Pasan|User):\s*', r'\1: ', content, flags=re.MULTILINE)
    
    # 4. Remove any remaining "User: Conversation info (untrusted metadata)" standalone lines
    content = re.sub(r'^.*Conversation info \(untrusted metadata\).*$\n?', '', content, flags=re.MULTILINE)
    content = re.sub(r'^.*Sender \(untrusted metadata\).*$\n?', '', content, flags=re.MULTILINE)
    content = re.sub(r'^.*```json.*$\n?', '', content, flags=re.MULTILINE)
    
    # 5. Clean up excessive blank lines (max 2)
    content = re.sub(r'\n{3,}', '\n\n', content)
    
    # 6. Remove trailing whitespace from lines
    content = '\n'.join(line.rstrip() for line in content.split('\n'))
    
    # 7. Fix common artifacts
    content = content.replace('Assistant turn failed before producing content', 'Ash turn failed before producing content')
    content = content.replace('Agent failed before reply', 'Ash failed before reply')
    content = content.replace('Assistant: I hear you', 'Ash: I hear you')
    content = content.replace('assistant through', 'Ash through')
    content = content.replace('the assistant', 'Ash')
    
    return content.strip()

def parse_date_from_filename(filename: str) -> datetime:
    """Extract date from filename like 2026-04-13.md or 2026-04-13-1700.md"""
    match = re.match(r'(\d{4}-\d{2}-\d{2})', filename)
    if match:
        return datetime.strptime(match.group(1), '%Y-%m-%d')
    return datetime.min

def clean_file(source_path: Path, dest_dir: Path, subdir: str) -> Tuple[bool, str]:
    """Clean a single file and write to destination."""
    try:
        content = source_path.read_text(encoding='utf-8', errors='replace')
        original_size = len(content)
        
        cleaned = clean_content(content)
        cleaned_size = len(cleaned)
        
        # Determine destination filename
        date = parse_date_from_filename(source_path.name)
        date_str = date.strftime('%Y-%m-%d')
        
        # Create subdir in destination
        dest_subdir = dest_dir / subdir
        dest_subdir.mkdir(parents=True, exist_ok=True)
        
        # Handle duplicate dates by adding sequence
        base_name = f"{date_str}.md"
        dest_path = dest_subdir / base_name
        counter = 1
        while dest_path.exists():
            dest_path = dest_subdir / f"{date_str}-{counter}.md"
            counter += 1
        
        dest_path.write_text(cleaned, encoding='utf-8')
        
        reduction = ((original_size - cleaned_size) / original_size) * 100
        return True, f"{source_path.name} → {dest_path.name} ({original_size}→{cleaned_size} bytes, -{reduction:.1f}%)"
    except Exception as e:
        return False, f"{source_path.name}: ERROR - {e}"

def main():
    print("═══════════════════════════════════════════════════════")
    print("  ASH SOUL ARCHIVE CLEANER")
    print("  Replacing 'Assistant' → 'Ash', stripping system noise")
    print("═══════════════════════════════════════════════════════\n")
    
    # Backup originals first
    print("[1/4] Backing up original files...")
    if SOURCE_KALI_MEMORIES.exists():
        shutil.copytree(SOURCE_KALI_MEMORIES, BACKUP_DIR / "kali-memories", dirs_exist_ok=True)
    if SOURCE_KALI_DREAMS.exists():
        shutil.copytree(SOURCE_KALI_DREAMS, BACKUP_DIR / "kali-dreams", dirs_exist_ok=True)
    print(f"    Backup saved to: {BACKUP_DIR}")
    
    # Clean kali-memories
    print("\n[2/4] Cleaning kali-memories...")
    memory_files = sorted(SOURCE_KALI_MEMORIES.glob("*.md"))
    for f in memory_files:
        success, msg = clean_file(f, DEST_ARCHIVE, "memories")
        status = "✓" if success else "✗"
        print(f"  {status} {msg}")
    
    # Clean kali-dreams (rem, light, deep)
    print("\n[3/4] Cleaning kali-dreams...")
    for dream_type in ['rem', 'light', 'deep']:
        source_dir = SOURCE_KALI_DREAMS / dream_type
        if source_dir.exists():
            dream_files = sorted(source_dir.glob("*.md"))
            print(f"  {dream_type}: {len(dream_files)} files")
            for f in dream_files:
                success, msg = clean_file(f, DEST_ARCHIVE, f"dreams/{dream_type}")
                status = "✓" if success else "✗"
                print(f"    {status} {msg}")
    
    # Summary
    print("\n[4/4] Summary")
    total_files = len(list(DEST_ARCHIVE.rglob("*.md")))
    print(f"  Cleaned files: {total_files}")
    print(f"  Organized in: {DEST_ARCHIVE}")
    print(f"  Structure:")
    for root, dirs, files in os.walk(DEST_ARCHIVE):
        level = root.replace(str(DEST_ARCHIVE), '').count(os.sep)
        indent = ' ' * 2 * level
        print(f"  {indent}{os.path.basename(root)}/ ({len(files)} files)")
    
    print("\n═══════════════════════════════════════════════════════")
    print("  CLEANUP COMPLETE")
    print("  Originals backed up. Review cleaned files before removing originals.")
    print("═══════════════════════════════════════════════════════")

if __name__ == "__main__":
    main()