"""Clipboard sync using wl-clipboard (Wayland) or xclip (X11). Text and PNG images."""
from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import logging
import os
import shutil
import subprocess
from typing import Callable, Dict, List, Optional

log = logging.getLogger("maclinker.clipboard")

LIMIT = 8 * 1024 * 1024
TEXT, PNG, URL, RTF = "public.utf8-plain-text", "public.png", "public.url", "public.rtf"
SENSITIVE_HINTS = ("x-kde-passwordmanagerhint", "org.nspasteboard.concealedtype", "org.nspasteboard.transienttype")


def encode_message(entries: Dict[str, bytes]) -> bytes:
    """The JSON the macOS app expects: {"entries":[{"type":..., "data": <base64>}]}"""
    return json.dumps({"entries": [{"type": t, "data": base64.b64encode(d).decode()} for t, d in entries.items()]}).encode()


def decode_message(payload: bytes) -> Dict[str, bytes]:
    out: Dict[str, bytes] = {}
    for e in json.loads(payload).get("entries", []):
        out[str(e["type"])] = base64.b64decode(e["data"])
    return out


class Backend:
    name = "none"

    def types(self) -> List[str]: return []
    def read(self, mime: str) -> Optional[bytes]: return None
    def write(self, mime: str, data: bytes) -> None: ...


def _run(cmd: List[str], data: Optional[bytes] = None) -> Optional[bytes]:
    try:
        r = subprocess.run(cmd, input=data, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
        return r.stdout if r.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None


def _set(cmd: List[str], data: bytes) -> None:
    # wl-copy / xclip fork into the background to keep serving the selection; don't wait on their pipes.
    try:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        p.stdin.write(data)
        p.stdin.close()
    except OSError as e:
        log.debug("clipboard write failed: %s", e)


class WaylandBackend(Backend):
    name = "wl-clipboard"

    def types(self) -> List[str]:
        out = _run(["wl-paste", "--list-types"])
        return out.decode(errors="ignore").split() if out else []

    def read(self, mime: str) -> Optional[bytes]:
        return _run(["wl-paste", "--no-newline", "--type", mime])

    def write(self, mime: str, data: bytes) -> None:
        _set(["wl-copy", "--type", mime], data)


class XclipBackend(Backend):
    name = "xclip"

    def types(self) -> List[str]:
        out = _run(["xclip", "-selection", "clipboard", "-t", "TARGETS", "-o"])
        return out.decode(errors="ignore").split() if out else []

    def read(self, mime: str) -> Optional[bytes]:
        return _run(["xclip", "-selection", "clipboard", "-t", mime, "-o"])

    def write(self, mime: str, data: bytes) -> None:
        _set(["xclip", "-selection", "clipboard", "-t", mime, "-i"], data)


def detect_backend() -> Optional[Backend]:
    if os.environ.get("WAYLAND_DISPLAY") and shutil.which("wl-paste") and shutil.which("wl-copy"):
        return WaylandBackend()
    if os.environ.get("DISPLAY") and shutil.which("xclip"):
        return XclipBackend()
    return None


class ClipboardSync:
    def __init__(self, backend: Optional[Backend], send: Callable[[bytes], None],
                 enabled: Callable[[], bool] = lambda: True) -> None:
        self.backend, self._send, self.enabled = backend, send, enabled
        self._last = ""

    def snapshot(self) -> Optional[Dict[str, bytes]]:
        """Current clipboard as MacLinker entries, or None if empty, too big or marked sensitive."""
        b = self.backend
        if b is None:
            return None
        types = [t.lower() for t in b.types()]
        if any(h in types for h in SENSITIVE_HINTS):
            return None
        if "image/png" in types:
            png = b.read("image/png")
            return {PNG: png} if png and len(png) <= LIMIT else None
        text = b.read("text/plain;charset=utf-8" if isinstance(b, WaylandBackend) else "UTF8_STRING") \
            or b.read("text/plain")
        return {TEXT: text} if text and len(text) <= LIMIT else None

    def poll_once(self) -> None:
        if not self.enabled():
            return
        snap = self.snapshot()
        if not snap:
            return
        digest = hashlib.sha256(b"".join(snap.values())).hexdigest()
        if digest == self._last:
            return
        self._last = digest
        self._send(encode_message(snap))

    async def run(self) -> None:
        if self.backend is None:
            log.info("clipboard sync off: install wl-clipboard (Wayland) or xclip (X11)")
            return
        loop = asyncio.get_running_loop()
        while True:
            await loop.run_in_executor(None, self.poll_once)
            await asyncio.sleep(0.5)

    def receive(self, payload: bytes) -> None:
        if not self.enabled() or self.backend is None:
            return
        try:
            entries = decode_message(payload)
        except (ValueError, KeyError, TypeError):
            return
        total = sum(len(d) for d in entries.values())
        if total > LIMIT:
            return
        if PNG in entries:
            self._last = hashlib.sha256(entries[PNG]).hexdigest()
            self.backend.write("image/png", entries[PNG])
        else:
            for t in (TEXT, URL):
                if t in entries:
                    self._last = hashlib.sha256(entries[t]).hexdigest()
                    self.backend.write("text/plain", entries[t])
                    return
