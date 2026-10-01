"""Screen size detection (needed to turn normalised pointer positions into pixels)."""
from __future__ import annotations

import glob
import os
import re
import subprocess
from typing import Optional, Tuple


def parse_xrandr(text: str) -> Optional[Tuple[int, int]]:
    m = re.search(r"current (\d+) x (\d+)", text)
    return (int(m.group(1)), int(m.group(2))) if m else None


def parse_drm_mode(text: str) -> Optional[Tuple[int, int]]:
    """First line of /sys/class/drm/*/modes is the preferred/current mode, e.g. `2560x1440`."""
    for line in text.splitlines():
        m = re.match(r"(\d+)x(\d+)", line.strip())
        if m:
            return int(m.group(1)), int(m.group(2))
    return None


def detect_screen() -> Tuple[int, int]:
    override = os.environ.get("MACLINKER_SCREEN", "")
    m = re.fullmatch(r"(\d+)x(\d+)", override.strip())
    if m:
        return int(m.group(1)), int(m.group(2))
    try:
        out = subprocess.run(["xrandr", "--current"], capture_output=True, text=True, timeout=3).stdout
        found = parse_xrandr(out)
        if found:
            return found
    except (OSError, subprocess.SubprocessError):
        pass
    for status_path in sorted(glob.glob("/sys/class/drm/card*-*/status")):
        try:
            with open(status_path) as f:
                if f.read().strip() != "connected":
                    continue
            with open(status_path.replace("status", "modes")) as f:
                found = parse_drm_mode(f.read())
            if found:
                return found
        except OSError:
            continue
    return 1920, 1080
