"""This machine's identity key and the list of paired devices."""
from __future__ import annotations

import json
import os
import socket
import threading
import time
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Dict, List, Optional

from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import Encoding, NoEncryption, PrivateFormat

from .crypto import device_id, raw_public
from .protocol import Edge


def config_dir() -> Path:
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    d = base / "maclinker"
    d.mkdir(parents=True, exist_ok=True)
    os.chmod(d, 0o700)
    return d


class Identity:
    """Ed25519 key created on first run. Stored with mode 0600 and never leaves this machine."""

    def __init__(self, directory: Optional[Path] = None) -> None:
        directory = directory or config_dir()
        path = directory / "identity.key"
        if path.exists():
            self.key = Ed25519PrivateKey.from_private_bytes(path.read_bytes())
        else:
            self.key = Ed25519PrivateKey.generate()
            raw = self.key.private_bytes(Encoding.Raw, PrivateFormat.Raw, NoEncryption())
            fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "wb") as f:
                f.write(raw)

    @property
    def public_key(self) -> bytes:
        return raw_public(self.key)

    @property
    def device_id(self) -> str:
        return device_id(self.public_key)

    @property
    def name(self) -> str:
        return socket.gethostname().split(".")[0] or "linux"


@dataclass
class TrustedDevice:
    id: str
    name: str
    public_key: str  # hex
    paired_at: float
    position: Optional[str] = None  # edge name: where this device sits relative to this machine
    last_host: Optional[str] = None
    last_port: Optional[int] = None

    @property
    def edge(self) -> Optional[Edge]:
        return Edge.parse(self.position) if self.position else None


class TrustedStore:
    def __init__(self, directory: Optional[Path] = None) -> None:
        self._path = (directory or config_dir()) / "trusted.json"
        self._lock = threading.Lock()
        self.devices: Dict[str, TrustedDevice] = {}
        if self._path.exists():
            try:
                for d in json.loads(self._path.read_text()):
                    self.devices[d["id"]] = TrustedDevice(**d)
            except (ValueError, KeyError, TypeError):
                self.devices = {}

    def is_trusted(self, public_key: bytes) -> bool:
        with self._lock:
            d = self.devices.get(device_id(public_key))
            return d is not None and d.public_key == public_key.hex()

    def get(self, id_: str) -> Optional[TrustedDevice]:
        return self.devices.get(id_)

    def trust(self, id_: str, name: str, public_key: bytes) -> None:
        with self._lock:
            existing = self.devices.get(id_)
            if existing:
                existing.name, existing.public_key = name, public_key.hex()
            else:
                self.devices[id_] = TrustedDevice(id_, name, public_key.hex(), time.time())
        self._save()

    def update(self, id_: str, **changes) -> None:
        with self._lock:
            d = self.devices.get(id_)
            if not d:
                return
            for k, v in changes.items():
                setattr(d, k, v)
        self._save()

    def remove(self, id_: str) -> None:
        with self._lock:
            self.devices.pop(id_, None)
        self._save()

    def all(self) -> List[TrustedDevice]:
        return list(self.devices.values())

    def find(self, name_or_id: str) -> Optional[TrustedDevice]:
        q = name_or_id.lower()
        for d in self.devices.values():
            if d.id == q or d.name.lower() == q:
                return d
        for d in self.devices.values():
            if d.name.lower().startswith(q):
                return d
        return None

    def _save(self) -> None:
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps([asdict(d) for d in self.devices.values()], indent=2))
        os.chmod(tmp, 0o600)
        tmp.replace(self._path)
