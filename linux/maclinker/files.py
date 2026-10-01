"""File transfer, compatible with the macOS app (offer -> chunks -> end with SHA-256)."""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import os
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Optional

from .protocol import Message, MsgType

log = logging.getLogger("maclinker.files")
CHUNK = 192 * 1024


def downloads_dir() -> Path:
    base = Path(os.environ.get("XDG_DOWNLOAD_DIR") or Path.home() / "Downloads")
    d = base / "MacLinker"
    d.mkdir(parents=True, exist_ok=True)
    return d


def safe_name(name: str) -> str:
    """Strip path components and leading dots; never produce an empty name."""
    clean = os.path.basename(name.replace("\\", "/")).strip(". \n\r/")
    return clean or "file"


def unique_path(directory: Path, name: str) -> Path:
    path = directory / safe_name(name)
    stem, suffix, n = path.stem, path.suffix, 1
    while path.exists():
        path = directory / f"{stem} {n}{suffix}"
        n += 1
    return path


@dataclass
class Incoming:
    path: Path
    handle: object
    expected: int
    received: int = 0
    hasher: "hashlib._Hash" = field(default_factory=hashlib.sha256)


class FileTransfer:
    def __init__(self, send: Callable[[str, MsgType, bytes], bool], enabled: Callable[[], bool] = lambda: True,
                 directory: Optional[Path] = None) -> None:
        self._send = send
        self.enabled = enabled
        self.directory = directory
        self.incoming: Dict[str, Incoming] = {}
        self.cancelled: set = set()
        self.log: list = []  # (direction, name, status)

    def _dir(self) -> Path:
        return self.directory or downloads_dir()

    # ---- receiving -----------------------------------------------------------------------------

    def on_message(self, peer: str, msg: Message) -> None:
        try:
            self._on_message(peer, msg)
        except (ValueError, KeyError, OSError) as e:
            log.error("file transfer error: %s", e)

    def _on_message(self, peer: str, msg: Message) -> None:
        t = msg.type
        if t == MsgType.FILE_OFFER:
            offer = json.loads(msg.payload)
            fid = uuid.UUID(offer["id"])
            if not self.enabled():
                self._send(peer, MsgType.FILE_ABORT, fid.bytes)
                return
            path = unique_path(self._dir(), offer["name"])
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            self.incoming[str(fid)] = Incoming(path, os.fdopen(fd, "wb"), int(offer["size"]))
            self.log.append(("receiving", path.name, "active"))
        elif t == MsgType.FILE_CHUNK:
            fid = str(uuid.UUID(bytes=msg.payload[:16]))
            f = self.incoming.get(fid)
            if f is None:
                return
            chunk = msg.payload[16:]
            f.received += len(chunk)
            if f.received > f.expected:
                self._abort(fid, "more data than announced")
                return
            f.handle.write(chunk)
            f.hasher.update(chunk)
        elif t == MsgType.FILE_END:
            fid = str(uuid.UUID(bytes=msg.payload[:16]))
            f = self.incoming.pop(fid, None)
            if f is None:
                return
            f.handle.close()
            if f.hasher.digest() == msg.payload[16:48] and f.received == f.expected:
                self.log.append(("received", f.path.name, "done"))
                log.info("received %s", f.path)
            else:
                f.path.unlink(missing_ok=True)
                self.log.append(("received", f.path.name, "checksum mismatch"))
        elif t == MsgType.FILE_ABORT:
            fid = str(uuid.UUID(bytes=msg.payload[:16]))
            self.cancelled.add(fid)
            if fid in self.incoming:
                self._abort(fid, "cancelled by sender")

    def _abort(self, fid: str, reason: str) -> None:
        f = self.incoming.pop(fid, None)
        if f:
            f.handle.close()
            f.path.unlink(missing_ok=True)
            log.info("transfer aborted: %s", reason)

    def peer_disconnected(self) -> None:
        for fid in list(self.incoming):
            self._abort(fid, "connection lost")

    # ---- sending -------------------------------------------------------------------------------

    async def send_file(self, session, path: Path) -> str:
        """Send a file over `session` with backpressure. Returns 'done' or an error string."""
        size = path.stat().st_size
        fid = uuid.uuid4()
        offer = {"id": str(fid).upper(), "name": path.name, "size": size}
        session.send(MsgType.FILE_OFFER, json.dumps(offer).encode())
        hasher = hashlib.sha256()
        try:
            with open(path, "rb") as f:
                while True:
                    chunk = await asyncio.get_running_loop().run_in_executor(None, f.read, CHUNK)
                    if not chunk:
                        break
                    if str(fid) in self.cancelled:
                        self.cancelled.discard(str(fid))
                        return "cancelled by receiver"
                    hasher.update(chunk)
                    await session.send_drain(MsgType.FILE_CHUNK, fid.bytes + chunk)
            await session.send_drain(MsgType.FILE_END, fid.bytes + hasher.digest())
        except Exception as e:  # noqa: BLE001
            return f"failed: {e}"
        return "done"
