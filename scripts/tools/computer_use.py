#!/usr/bin/env python3
"""
Ash Computer Use — Linux Desktop Control via xdotool/scrot
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Native Raksha OS integration — no Hermes required.
Uses xdotool (X11) for mouse/keyboard, scrot/maim for screenshots.
"""

import os
import json
import subprocess
import shutil
import base64
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Any, Tuple

# === CONFIG ===
XDOTOOL = shutil.which("xdotool")
SCROT = shutil.which("scrot")
MAIM = shutil.which("maim")
IMPORT = shutil.which("import")  # ImageMagick
XWININFO = shutil.which("xwininfo")
WMCTRL = shutil.which("wmctrl")
IDENTIFY = shutil.which("identify")  # ImageMagick for dimensions

ASH_HOME = Path(os.environ.get("ASH_HOME", "/var/lib/ash"))
SCREENSHOT_DIR = ASH_HOME / "screenshots"
SCREENSHOT_DIR.mkdir(parents=True, exist_ok=True)


class ComputerUse:
    """Linux desktop automation using xdotool + scrot"""

    def __init__(self):
        self.last_capture = None
        self.last_elements = []
        self._verify_tools()

    def _verify_tools(self):
        missing = []
        if not XDOTOOL:
            missing.append("xdotool")
        if not (SCROT or MAIM or IMPORT):
            missing.append("scrot/maim/import (for screenshots)")
        if missing:
            raise RuntimeError(f"Missing tools: {', '.join(missing)}")

    # ══════════════════════════════════════════════════
    # CORE ACTIONS
    # ══════════════════════════════════════════════════

    def capture(self, mode: str = "som", app: Optional[str] = None,
                window_id: Optional[str] = None) -> Dict[str, Any]:
        """
        Capture screenshot with optional element detection.
        mode: "som" (screenshot + element index), "vision" (plain), "ax" (accessibility tree)
        """
        # Focus app if specified
        if app and not window_id:
            window_id = self._find_window(app)
            if window_id:
                self._focus_window(window_id)
                time.sleep(0.2)

        # Take screenshot
        screenshot_path = self._take_screenshot(window_id)
        if not screenshot_path:
            return {"error": "Failed to capture screenshot"}

        result = {
            "screenshot": screenshot_path,
            "screenshot_b64": self._image_to_b64(screenshot_path),
            "mode": mode,
            "width": 0,
            "height": 0,
        }

        # Get dimensions using identify (ImageMagick) or file size fallback
        try:
            if IDENTIFY:
                ident_result = subprocess.run([IDENTIFY, "-format", "%w %h", screenshot_path], 
                                          capture_output=True, text=True, timeout=3)
                if ident_result.returncode == 0:
                    w, h = map(int, ident_result.stdout.strip().split())
                    result["width"], result["height"] = w, h
        except Exception:
            pass

        # SOM mode: detect elements (simplified - use xdotool getwindowgeometry + basic detection)
        if mode == "som":
            elements = self._detect_elements(window_id, screenshot_path)
            result["elements"] = elements
            self.last_elements = elements

        self.last_capture = result
        return result

    def click(self, element: Optional[int] = None,
              coordinate: Optional[List[int]] = None,
              button: str = "1",
              capture_after: bool = False,
              modifiers: List[str] = []) -> Dict[str, Any]:
        
        if element is not None:
            if self.last_elements and 0 <= element < len(self.last_elements):
                el = self.last_elements[element]
                x, y = el.get("center", el.get("position", [0, 0]))
            else:
                return {"error": f"Element index {element} not found in last capture"}
        elif coordinate:
            x, y = coordinate
        else:
            return {"error": "Must specify element index or coordinate"}

        # Apply modifiers
        mod_str = "+".join(modifiers) + "+" if modifiers else ""
        
        cmd = [XDOTOOL, "mousemove", "--sync", str(x), str(y)]
        subprocess.run(cmd, check=True)
        time.sleep(0.05)
        
        click_cmd = [XDOTOOL, "click", f"--clearmodifiers{mod_str}", button]
        subprocess.run(click_cmd, check=True)

        if capture_after:
            time.sleep(0.3)
            return self.capture(mode="som")
        return {"success": True, "x": x, "y": y}

    def key(self, keys: str, capture_after: bool = False) -> Dict[str, Any]:
        """Send key combination (e.g., 'ctrl+c', 'return', 'alt+tab')"""
        # Normalize key names
        key_map = {
            "return": "Return", "enter": "Return", "escape": "Escape", "esc": "Escape",
            "tab": "Tab", "space": "space", "up": "Up", "down": "Down",
            "left": "Left", "right": "Right", "home": "Home", "end": "End",
            "pageup": "Page_Up", "pagedown": "Page_Down",
            "ctrl": "Control_L", "alt": "Alt_L", "shift": "Shift_L",
            "cmd": "Super_L", "super": "Super_L", "win": "Super_L",
        }
        
        parts = keys.lower().split("+")
        mapped = [key_map.get(p, p) for p in parts]
        xdotool_keys = "+".join(mapped)
        
        cmd = [XDOTOOL, "key", "--clearmodifiers", xdotool_keys]
        subprocess.run(cmd, check=True)

        if capture_after:
            time.sleep(0.3)
            return self.capture(mode="som")
        return {"success": True, "keys": keys}

    def type_text(self, text: str, delay: int = 10, capture_after: bool = False) -> Dict[str, Any]:
        """Type a string (respects current keyboard layout)"""
        cmd = [XDOTOOL, "type", "--delay", str(delay), "--clearmodifiers", text]
        subprocess.run(cmd, check=True)

        if capture_after:
            time.sleep(0.3)
            return self.capture(mode="som")
        return {"success": True, "length": len(text)}

    def scroll(self, direction: str = "down", amount: int = 3,
               element: Optional[int] = None,
               coordinate: Optional[List[int]] = None,
               capture_after: bool = False) -> Dict[str, Any]:
        """Scroll in a direction"""

        if element is not None and self.last_elements and 0 <= element < len(self.last_elements):
            el = self.last_elements[element]
            x, y = el.get("center", el.get("position", [0, 0]))
            # Move to element first
            subprocess.run([XDOTOOL, "mousemove", "--sync", str(x), str(y)], check=True)
            time.sleep(0.05)
        elif coordinate:
            subprocess.run([XDOTOOL, "mousemove", "--sync", str(coordinate[0]), str(coordinate[1])], check=True)
            time.sleep(0.05)

        # Map direction to button (4=up, 5=down, 6=left, 7=right)
        scroll_map = {"up": "4", "down": "5", "left": "6", "right": "7"}
        button = scroll_map.get(direction.lower(), "5")
        
        for _ in range(amount):
            subprocess.run([XDOTOOL, "click", button], check=True)
            time.sleep(0.05)

        if capture_after:
            time.sleep(0.3)
            return self.capture(mode="som")
        return {"success": True, "direction": direction, "amount": amount}

    def drag(self, from_element: Optional[int] = None, to_element: Optional[int] = None,
             from_coordinate: Optional[List[int]] = None, to_coordinate: Optional[List[int]] = None,
             capture_after: bool = False) -> Dict[str, Any]:
        
        def get_pos(el_idx, coord):
            if el_idx is not None and self.last_elements and 0 <= el_idx < len(self.last_elements):
                el = self.last_elements[el_idx]
                return el.get("center", el.get("position", [0, 0]))
            return coord

        fx, fy = get_pos(from_element, from_coordinate)
        tx, ty = get_pos(to_element, to_coordinate)

        if not fx or not tx:
            return {"error": "Invalid from/to positions"}

        # Move to start
        subprocess.run([XDOTOOL, "mousemove", "--sync", str(fx), str(fy)], check=True)
        time.sleep(0.1)
        # Mouse down
        subprocess.run([XDOTOOL, "mousedown", "1"], check=True)
        time.sleep(0.1)
        # Move to end
        subprocess.run([XDOTOOL, "mousemove", "--sync", str(tx), str(ty)], check=True)
        time.sleep(0.1)
        # Mouse up
        subprocess.run([XDOTOOL, "mouseup", "1"], check=True)

        if capture_after:
            time.sleep(0.3)
            return self.capture(mode="som")
        return {"success": True, "from": [fx, fy], "to": [tx, ty]}

    def wait(self, seconds: float = 0.5) -> Dict[str, Any]:
        time.sleep(seconds)
        return {"success": True, "waited": seconds}

    # ══════════════════════════════════════════════════
    # WINDOW/APP MANAGEMENT
    # ══════════════════════════════════════════════════

    def list_apps(self) -> List[Dict[str, Any]]:
        """List running X11 windows with titles"""
        if not WMCTRL:
            return [{"error": "wmctrl not installed"}]
        try:
            result = subprocess.run([WMCTRL, "-l", "-x"], capture_output=True, text=True, timeout=5)
            apps = []
            for line in result.stdout.strip().split("\n"):
                if line:
                    parts = line.split(None, 4)
                    if len(parts) >= 5:
                        apps.append({
                            "window_id": parts[0],
                            "desktop": parts[1],
                            "class": parts[2],
                            "host": parts[3],
                            "title": parts[4]
                        })
            return apps
        except Exception as e:
            return [{"error": str(e)}]

    def focus_app(self, app: str, raise_window: bool = False) -> Dict[str, Any]:
        """Focus an application window"""
        window_id = self._find_window(app)
        if not window_id:
            return {"error": f"Window not found for: {app}"}
        
        if raise_window:
            subprocess.run([WMCTRL, "-i", "-a", window_id], check=True)
        else:
            subprocess.run([XDOTOOL, "windowactivate", "--sync", window_id], check=True)
        return {"success": True, "window_id": window_id}

    # ══════════════════════════════════════════════════
    # INTERNAL HELPERS
    # ══════════════════════════════════════════════════

    def _take_screenshot(self, window_id: Optional[str] = None) -> Optional[str]:
        """Take screenshot using available tool"""
        timestamp = int(time.time() * 1000)
        path = SCREENSHOT_DIR / f"ash_capture_{timestamp}.png"
        
        try:
            if window_id and XDOTOOL:
                # Window-specific screenshot
                subprocess.run([XDOTOOL, "getwindowgeometry", window_id], capture_output=True)
                subprocess.run(["import", "-window", window_id, str(path)], check=True, timeout=5)
            elif SCROT:
                subprocess.run([SCROT, "-z", str(path)], check=True, timeout=5)
            elif MAIM:
                subprocess.run([MAIM, str(path)], check=True, timeout=5)
            elif IMPORT:
                subprocess.run([IMPORT, "-window", "root", str(path)], check=True, timeout=5)
            else:
                return None
            
            if path.exists() and path.stat().st_size > 0:
                return str(path)
        except Exception as e:
            print(f"[ComputerUse] Screenshot failed: {e}")
        return None

    def _image_to_b64(self, path: str) -> str:
        with open(path, "rb") as f:
            return base64.b64encode(f.read()).decode()

    def _find_window(self, app: str) -> Optional[str]:
        """Find window ID by app name/class"""
        if not WMCTRL:
            return None
        try:
            result = subprocess.run([WMCTRL, "-l", "-x"], capture_output=True, text=True, timeout=5)
            app_lower = app.lower()
            for line in result.stdout.strip().split("\n"):
                if app_lower in line.lower():
                    return line.split()[0]
        except Exception:
            pass
        return None

    def _focus_window(self, window_id: str):
        """Focus window without raising"""
        try:
            subprocess.run([XDOTOOL, "windowactivate", "--sync", window_id], check=True, timeout=3)
        except Exception:
            pass

    def _detect_elements(self, window_id: Optional[str], screenshot_path: str) -> List[Dict]:
        """
        Simplified element detection - returns basic clickable regions.
        In a full implementation, this would use accessibility APIs or vision models.
        For now, returns a grid-based approximation.
        """
        elements = []
        try:
            from PIL import Image
            with Image.open(screenshot_path) as img:
                w, h = img.size
                
                # Create a basic grid of "elements" for demonstration
                # Real implementation would use AT-SPI / accessibility tree or vision model
                grid_size = 5
                for row in range(grid_size):
                    for col in range(grid_size):
                        cx = int((col + 0.5) * w / grid_size)
                        cy = int((row + 0.5) * h / grid_size)
                        ew = w // grid_size
                        eh = h // grid_size
                        
                        elements.append({
                            "index": row * grid_size + col,
                            "type": "grid_cell",
                            "position": [col * ew, row * eh],
                            "center": [cx, cy],
                            "size": [ew, eh],
                            "description": f"Grid cell ({row},{col})"
                        })
        except Exception:
            pass
        return elements


# ══════════════════════════════════════════════════
# TOOL SCHEMA FOR LLM
# ══════════════════════════════════════════════════

COMPUTER_USE_SCHEMA = {
    "name": "computer_use",
    "description": "Control the Linux desktop — screenshots, mouse, keyboard, scroll, drag, window management",
    "parameters": {
        "type": "object",
        "properties": {
            "action": {
                "type": "string",
                "enum": ["capture", "click", "double_click", "right_click", "middle_click",
                         "drag", "scroll", "type", "key", "wait", "list_apps", "focus_app"],
                "description": "Action to perform"
            },
            "mode": {"type": "string", "enum": ["som", "vision", "ax"], "default": "som"},
            "app": {"type": "string", "description": "Application name to target (e.g., 'firefox', 'code')"},
            "element": {"type": "integer", "description": "Element index from last capture"},
            "coordinate": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
            "from_element": {"type": "integer"},
            "to_element": {"type": "integer"},
            "from_coordinate": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
            "to_coordinate": {"type": "array", "items": {"type": "integer"}, "minItems": 2, "maxItems": 2},
            "button": {"type": "string", "enum": ["1", "2", "3"], "default": "1"},
            "direction": {"type": "string", "enum": ["up", "down", "left", "right"]},
            "amount": {"type": "integer", "default": 3},
            "keys": {"type": "string", "description": "Key combination (e.g., 'ctrl+c', 'return', 'alt+tab')"},
            "text": {"type": "string", "description": "Text to type"},
            "capture_after": {"type": "boolean", "default": False},
            "modifiers": {"type": "array", "items": {"type": "string"}},
            "raise_window": {"type": "boolean", "default": False},
            "seconds": {"type": "number", "default": 0.5},
        },
        "required": ["action"]
    }
}


# ══════════════════════════════════════════════════
# SINGLETON & ENTRY POINT
# ═�═════════════════════════════════════════════════

_computer_use: Optional[ComputerUse] = None

def get_computer_use() -> ComputerUse:
    global _computer_use
    if _computer_use is None:
        _computer_use = ComputerUse()
    return _computer_use

def computer_use(action: str, **kwargs) -> Dict[str, Any]:
    """Main entry point for LLM tool calls"""
    cu = get_computer_use()
    return getattr(cu, action)(**kwargs)

if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print(json.dumps({"error": "Usage: computer_use.py <action> [json_args]"}))
        sys.exit(1)
    action = sys.argv[1]
    args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
    result = computer_use(action, **args)
    print(json.dumps(result))