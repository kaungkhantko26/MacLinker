"""The daemon: server, discovery, sessions, pairing, reconnect, routing and the local control socket."""
from __future__ import annotations

import asyncio
import json
import logging
import os
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Optional

from . import DEFAULT_PORT
from .clipboard import ClipboardSync, detect_backend
from .control import ControlManager
from .discovery import Discovery, Found
from .files import FileTransfer
from .identity import Identity, TrustedStore, config_dir
from .inject import InjectorUnavailable, NullInjector, UInputInjector
from .protocol import Edge, Layout, Message, MsgType
from .screen import detect_screen
from .session import Session

log = logging.getLogger("maclinker.app")

INPUT_TYPES = {MsgType.MOUSE_MOVE, MsgType.MOUSE_BUTTON, MsgType.SCROLL, MsgType.KEY_EVENT,
               MsgType.FLAGS_CHANGED, MsgType.ENTER_CONTROL, MsgType.RELEASE_CONTROL}


@dataclass
class PairingPrompt:
    session: Session
    name: str
    code: str
    future: "asyncio.Future[bool]"


def apply_remote_layout(trusted: TrustedStore, my_id: str, peer_id: str, layout: Layout) -> bool:
    """Mirror the peer's layout choice. On connect the machine with the smaller ID wins, so two
    inconsistent configurations converge instead of swapping. Returns True if the position changed."""
    dev = trusted.get(peer_id)
    if dev is None:
        return False
    if not layout.user_initiated:
        if layout.peer_position is None:
            return False
        if not (peer_id < my_id or dev.position is None):
            return False
    new = layout.peer_position.opposite.title if layout.peer_position else None
    if new == dev.position:
        return False
    trusted.update(peer_id, position=new)
    return True


class App:
    def __init__(self, port: int = DEFAULT_PORT, discovery: bool = True, swap_modifiers: bool = True,
                 mouse_speed: float = 1.0, edge_push: float = 12.0, scroll_invert: bool = False,
                 capture: bool = True, config: Optional[Path] = None) -> None:
        self.cfg = config or config_dir()
        self.identity, self.trusted = Identity(self.cfg), TrustedStore(self.cfg)
        self.port = port
        self.use_discovery, self.use_capture = discovery, capture
        self.swap_modifiers, self.mouse_speed = swap_modifiers, mouse_speed
        self.edge_push, self.scroll_invert = edge_push, scroll_invert
        self.sessions: Dict[str, Session] = {}      # peer id -> identified session
        self.found: Dict[str, Found] = {}
        self.pairing: Optional[PairingPrompt] = None
        self._offline_since: Dict[str, float] = {}
        self._next_attempt: Dict[str, float] = {}
        self._failures: Dict[str, int] = {}
        self._tasks: list = []
        self.loop: Optional[asyncio.AbstractEventLoop] = None

    # ---- lifecycle -----------------------------------------------------------------------------

    async def run(self) -> None:
        self.loop = asyncio.get_running_loop()
        try:
            injector = UInputInjector()
        except InjectorUnavailable as e:
            log.warning("this machine can't be controlled: %s", e)
            injector = NullInjector()
        screen = detect_screen()
        log.info("screen %dx%d", *screen)
        self.control = ControlManager(injector, self._send, screen, self.loop, self.swap_modifiers,
                                      self.edge_push, self.scroll_invert)
        self.files = FileTransfer(self._send)
        self.clipboard = ClipboardSync(detect_backend(), lambda payload: self._broadcast(MsgType.CLIPBOARD, payload))
        self.capture = None
        if self.use_capture:
            try:
                from .capture import Capture
                self.capture = Capture(self.control, self.loop, self.swap_modifiers, self.mouse_speed)
                self.capture.start()
            except (RuntimeError, OSError) as e:
                log.warning("can't read keyboard/mouse (%s): this machine can be controlled but can't control peers. "
                            "Run `maclinker setup`.", e)

        server = await asyncio.start_server(self._on_connection, "0.0.0.0", self.port)
        self.port = server.sockets[0].getsockname()[1]
        log.info("%s [%s] listening on port %d", self.identity.name, self.identity.device_id, self.port)
        if self.use_discovery:
            self.discovery = Discovery(self.identity.name, self.identity.device_id, self.port,
                                       self._on_found, lambda i: self.found.pop(i, None))
            await self.discovery.start()
        ctl_server = await self._start_ctl()
        self._tasks = [asyncio.create_task(self.clipboard.run()), asyncio.create_task(self._reconnect_loop())]
        self._refresh_edges()
        async with server, ctl_server:
            await asyncio.Event().wait()

    # ---- sessions ------------------------------------------------------------------------------

    def _new_session(self, reader, writer, initiator: bool, expected: Optional[str] = None) -> Session:
        return Session(reader, writer, initiator, self.identity, self.trusted, self.port,
                       self._on_message, self._on_state, self._on_pairing, expected)

    async def _on_connection(self, reader, writer) -> None:
        await self._new_session(reader, writer, False).run()

    async def connect(self, host: str, port: int = DEFAULT_PORT, expected: Optional[str] = None) -> str:
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection(host, port), 8)
        except (OSError, asyncio.TimeoutError) as e:
            return f"couldn't connect to {host}:{port}: {e}"
        asyncio.create_task(self._new_session(reader, writer, True, expected).run())
        return f"connecting to {host}:{port}"

    def _on_state(self, s: Session, state: str) -> None:
        if state in ("pairing", "connected") and s.peer_id and self.sessions.get(s.peer_id) is not s:
            self._claim(s)
        if state == "connected" and self.sessions.get(s.peer_id or "") is s:
            self._connected(s)
        elif state == "closed":
            if self.pairing and self.pairing.session is s and not self.pairing.future.done():
                self.pairing.future.set_result(False)
            if s.peer_id and self.sessions.get(s.peer_id) is s:
                del self.sessions[s.peer_id]
                self.control.peer_disconnected(s.peer_id)
                self.files.peer_disconnected()
                self._refresh_edges()
                log.info("%s disconnected", s.peer_name or s.peer_id)

    def _claim(self, s: Session) -> None:
        """Both machines may dial each other; both keep the connection started by the smaller device ID."""
        existing = self.sessions.get(s.peer_id)
        if existing and existing is not s and existing.state != "closed":
            def initiator_id(x: Session) -> str:
                return self.identity.device_id if x.initiator else x.peer_id
            if initiator_id(s) < initiator_id(existing):
                asyncio.ensure_future(existing.close())
            else:
                asyncio.ensure_future(s.close())
                return
        self.sessions[s.peer_id] = s

    def _connected(self, s: Session) -> None:
        log.info("connected to %s (%s)", s.peer_name, s.peer_id)
        host = s.remote_host if s.remote_host and ":" not in s.remote_host else None
        if host:
            peername = s.writer.get_extra_info("peername")
            # the port we dialed if we initiated, otherwise the port the peer says it listens on
            port = peername[1] if s.initiator else s.peer_port
            self.trusted.update(s.peer_id, name=s.peer_name, last_host=host, last_port=port or DEFAULT_PORT)
        self._failures.pop(s.peer_id, None)
        dev = self.trusted.get(s.peer_id)
        if dev and dev.edge:
            s.send(MsgType.LAYOUT, Layout(dev.edge, False).encode())
        self._refresh_edges()

    def _refresh_edges(self) -> None:
        edges = {}
        for dev in self.trusted.all():
            s = self.sessions.get(dev.id)
            if dev.edge and s and s.state == "connected":
                edges[dev.edge] = dev.id
        self.control.edge_peers = edges

    def _send(self, peer: str, type_: MsgType, payload: bytes) -> bool:
        s = self.sessions.get(peer)
        return bool(s and s.send(type_, payload))

    def _broadcast(self, type_: MsgType, payload: bytes) -> None:
        for peer in list(self.sessions):
            self._send(peer, type_, payload)

    def _on_message(self, s: Session, msg: Message) -> None:
        if self.sessions.get(s.peer_id or "") is not s:
            return
        if msg.type in INPUT_TYPES:
            self.control.on_message(s.peer_id, msg)
        elif msg.type == MsgType.CLIPBOARD:
            self.clipboard.receive(msg.payload)
        elif msg.type in (MsgType.FILE_OFFER, MsgType.FILE_CHUNK, MsgType.FILE_END, MsgType.FILE_ABORT):
            self.files.on_message(s.peer_id, msg)
        elif msg.type == MsgType.LAYOUT:
            if apply_remote_layout(self.trusted, self.identity.device_id, s.peer_id, Layout.decode(msg.payload)):
                self._refresh_edges()
        elif msg.type == MsgType.SYSTEM_QUERY:
            pass  # brightness/volume of this machine isn't exposed (and peers don't send these to <1.2 builds)

    # ---- pairing -------------------------------------------------------------------------------

    async def _on_pairing(self, s: Session, name: str, code: str) -> bool:
        fut: asyncio.Future = asyncio.get_running_loop().create_future()
        self.pairing = PairingPrompt(s, name, code, fut)
        spaced = f"{code[:3]} {code[3:]}"
        print(f"\n=== Pairing with \"{name}\" ===\nCode: {spaced}\n"
              f"Make sure the other Mac shows the same code. Then run: maclinker confirm   (or maclinker reject)\n",
              flush=True)
        if sys.stdin and sys.stdin.isatty():
            self._read_tty_answer(fut)
        try:
            return await fut
        finally:
            self.pairing = None

    def _read_tty_answer(self, fut: "asyncio.Future[bool]") -> None:
        loop = asyncio.get_running_loop()

        def ask() -> None:
            try:
                answer = input("Codes match? [y/N] ").strip().lower() == "y"
            except EOFError:
                return
            loop.call_soon_threadsafe(lambda: fut.done() or fut.set_result(answer))
        threading.Thread(target=ask, daemon=True).start()

    # ---- discovery & reconnect -------------------------------------------------------------------

    def _on_found(self, f: Found) -> None:
        self.found[f.id] = f

    async def _reconnect_loop(self) -> None:
        while True:
            await asyncio.sleep(2)
            now = time.monotonic()
            for dev in self.trusted.all():
                if dev.id in self.sessions:
                    self._offline_since.pop(dev.id, None)
                    continue
                since = self._offline_since.setdefault(dev.id, now)
                # smaller ID dials first; the other waits so they don't collide, but still dials if needed
                if self.identity.device_id > dev.id and now - since < 6:
                    continue
                if now < self._next_attempt.get(dev.id, 0):
                    continue
                found = self.found.get(dev.id)
                host = found.host if found else dev.last_host
                port = found.port if found else (dev.last_port or DEFAULT_PORT)
                if not host:
                    continue
                n = self._failures.get(dev.id, 0)
                self._failures[dev.id] = n + 1
                self._next_attempt[dev.id] = now + min(30, 2 * 1.6 ** n)
                await self.connect(host, port, expected=dev.id)

    # ---- local control socket (used by the CLI) ----------------------------------------------------

    @property
    def ctl_path(self) -> Path:
        return self.cfg / "ctl.sock"

    async def _start_ctl(self):
        try:
            self.ctl_path.unlink()
        except FileNotFoundError:
            pass
        server = await asyncio.start_unix_server(self._on_ctl, path=str(self.ctl_path))
        os.chmod(self.ctl_path, 0o600)
        return server

    async def _on_ctl(self, reader, writer) -> None:
        try:
            line = await asyncio.wait_for(reader.readline(), 5)
            reply = await self.handle_command(json.loads(line or b"{}"))
        except Exception as e:  # noqa: BLE001
            reply = {"ok": False, "error": str(e)}
        writer.write(json.dumps(reply).encode() + b"\n")
        await writer.drain()
        writer.close()

    def status(self) -> dict:
        return {
            "name": self.identity.name, "id": self.identity.device_id, "port": self.port,
            "state": self.control.state.kind,
            "devices": [{
                "id": d.id, "name": d.name, "position": d.position,
                "connected": d.id in self.sessions and self.sessions[d.id].state == "connected",
                "latency_ms": (self.sessions[d.id].latency_ms if d.id in self.sessions else None),
                "nearby": d.id in self.found,
            } for d in self.trusted.all()],
            "nearby_unpaired": [{"id": f.id, "name": f.name, "host": f.host, "port": f.port}
                                for f in self.found.values() if not self.trusted.get(f.id)],
            "pairing": ({"name": self.pairing.name, "code": self.pairing.code} if self.pairing else None),
            "transfers": self.files.log[-10:],
        }

    async def handle_command(self, cmd: dict) -> dict:
        name = cmd.get("cmd")
        if name == "status":
            return {"ok": True, **self.status()}
        if name in ("confirm", "reject"):
            if not self.pairing or self.pairing.future.done():
                return {"ok": False, "error": "no pairing in progress"}
            self.pairing.future.set_result(name == "confirm")
            return {"ok": True}
        if name == "connect":
            from .protocol import ProtocolError  # noqa: F401
            host, _, port = str(cmd.get("host", "")).partition(":")
            return {"ok": True, "message": await self.connect(host, int(port or DEFAULT_PORT))}
        if name == "send":
            dev = self.trusted.find(cmd.get("to", "")) if cmd.get("to") else None
            if dev is None and len(self.sessions) == 1:
                s = next(iter(self.sessions.values()))
            else:
                s = self.sessions.get(dev.id) if dev else None
            if s is None or s.state != "connected":
                return {"ok": False, "error": "that device isn't connected (use --to NAME)"}
            path = Path(cmd["path"]).expanduser()
            if not path.is_file():
                return {"ok": False, "error": f"not a file: {path}"}
            asyncio.create_task(self.files.send_file(s, path))
            return {"ok": True, "message": f"sending {path.name} to {s.peer_name}"}
        if name == "position":
            dev = self.trusted.find(cmd.get("device", ""))
            if dev is None:
                return {"ok": False, "error": "unknown device; pair it first"}
            edge = Edge.parse(cmd["edge"]) if cmd.get("edge") not in (None, "none") else None
            if cmd.get("edge") not in (None, "none") and edge is None:
                return {"ok": False, "error": "edge must be left, right, top, bottom or none"}
            self.trusted.update(dev.id, position=edge.title if edge else None)
            self._send(dev.id, MsgType.LAYOUT, Layout(edge, True).encode())
            self._refresh_edges()
            return {"ok": True}
        if name == "toggle":
            self.control.toggle()
            return {"ok": True, "state": self.control.state.kind}
        if name == "forget":
            dev = self.trusted.find(cmd.get("device", ""))
            if dev is None:
                return {"ok": False, "error": "unknown device"}
            s = self.sessions.get(dev.id)
            if s:
                await s.close()
            self.trusted.remove(dev.id)
            self._refresh_edges()
            return {"ok": True}
        return {"ok": False, "error": f"unknown command {name!r}"}
