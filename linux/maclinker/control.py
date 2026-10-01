"""Who is driving: this machine's own devices or a peer's. Hardware-free so it can be tested anywhere.

- CONTROLLING: our pointer crossed an edge (or the hotkey was pressed). Local devices are grabbed and
  their events are streamed to the peer.
- CONTROLLED: a peer is driving us. Its events are injected; pushing against the edge we were entered
  from hands control back.
Mouse movement is batched (~3 ms) so a 1000 Hz mouse doesn't flood the link.
"""
from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass
from typing import Callable, Dict, Optional, Protocol, Tuple

from .keymap import ModifierTracker, mac_to_linux
from .protocol import (Control, Edge, Key, Message, MouseButton, MouseMove, MsgType, Scroll)

log = logging.getLogger("maclinker.control")

BTN_LEFT, BTN_RIGHT, BTN_MIDDLE, BTN_SIDE, BTN_EXTRA = 0x110, 0x111, 0x112, 0x113, 0x114
MAC_BUTTONS = {0: BTN_LEFT, 1: BTN_RIGHT, 2: BTN_MIDDLE, 3: BTN_SIDE, 4: BTN_EXTRA}


class Injector(Protocol):
    def move_abs(self, x_frac: float, y_frac: float) -> None: ...
    def button(self, code: int, down: bool) -> None: ...
    def scroll(self, dx_lines: float, dy_lines: float) -> None: ...
    def key(self, code: int, down: bool) -> None: ...
    def release_all(self) -> None: ...


@dataclass
class State:
    kind: str = "local"            # local | controlling | controlled
    peer: Optional[str] = None
    edge: Optional[Edge] = None    # controlling: edge we left through. controlled: edge we return through


def edge_point(edge: Edge, position: float, size: Tuple[int, int], inset: float) -> Tuple[float, float]:
    w, h = size
    t = min(max(position, 0.0), 1.0)
    if edge == Edge.LEFT:
        return inset, t * (h - 1)
    if edge == Edge.RIGHT:
        return w - 1 - inset, t * (h - 1)
    if edge == Edge.TOP:
        return t * (w - 1), inset
    return t * (w - 1), h - 1 - inset


def normalized(edge: Edge, point: Tuple[float, float], size: Tuple[int, int]) -> float:
    w, h = size
    v = point[1] / max(h - 1, 1) if edge in (Edge.LEFT, Edge.RIGHT) else point[0] / max(w - 1, 1)
    return float(min(max(v, 0.0), 1.0))


def is_pushing(edge: Edge, p: Tuple[float, float], d: Tuple[float, float], size: Tuple[int, int]) -> bool:
    w, h = size
    slop = 1.5
    return {Edge.RIGHT: p[0] >= w - 1 - slop and d[0] > 0, Edge.LEFT: p[0] <= slop and d[0] < 0,
            Edge.BOTTOM: p[1] >= h - 1 - slop and d[1] > 0, Edge.TOP: p[1] <= slop and d[1] < 0}[edge]


def outward(edge: Edge, d: Tuple[float, float]) -> float:
    return {Edge.RIGHT: d[0], Edge.LEFT: -d[0], Edge.BOTTOM: d[1], Edge.TOP: -d[1]}[edge]


class EdgeDetector:
    """Needs sustained outward pressure against an edge before reporting a crossing."""

    def __init__(self, threshold: float = 12.0) -> None:
        self.threshold = threshold
        self._acc = 0.0
        self._edge: Optional[Edge] = None

    def reset(self) -> None:
        self._acc, self._edge = 0.0, None

    def update(self, pos, delta, size, edges) -> Optional[Tuple[Edge, float]]:
        edge = next((e for e in edges if is_pushing(e, pos, delta, size)), None)
        if edge is None:
            self.reset()
            return None
        if edge != self._edge:
            self._edge, self._acc = edge, 0.0
        self._acc += outward(edge, delta)
        if self._acc < self.threshold:
            return None
        hit = (edge, normalized(edge, pos, size))
        self.reset()
        return hit


class ControlManager:
    def __init__(self, injector: Injector, send: Callable[[str, MsgType, bytes], bool], screen: Tuple[int, int],
                 loop: Optional[asyncio.AbstractEventLoop] = None, swap_modifiers: bool = True,
                 edge_push: float = 12.0, scroll_invert: bool = False) -> None:
        self.injector, self._send, self.screen = injector, send, screen
        self.loop = loop
        self.swap_modifiers, self.scroll_invert = swap_modifiers, scroll_invert
        self.enabled = True
        self.state = State()
        self.edge_peers: Dict[Edge, str] = {}
        self.on_grab: Callable[[bool], None] = lambda grabbed: None
        self._detector = EdgeDetector(edge_push)
        self._return = EdgeDetector(edge_push)
        self._cursor = (0.0, 0.0)
        self._mods = ModifierTracker()
        self._pending = [0.0, 0.0]
        self._flush_handle = None
        self._scroll_acc = [0.0, 0.0]

    # ---- local side: pointer position from the capture layer ----------------------------------------

    def local_pointer(self, pos: Tuple[float, float], delta: Tuple[float, float]) -> bool:
        """Called on local pointer motion (when the real position is known, e.g. X11).
        Returns True if control just moved to a peer."""
        if self.state.kind != "local" or not self.enabled or not self.edge_peers:
            return False
        hit = self._detector.update(pos, delta, self.screen, set(self.edge_peers))
        if hit is None:
            return False
        edge, position = hit
        return self.begin_controlling(self.edge_peers[edge], edge, position)

    def toggle(self, peer: Optional[str] = None) -> None:
        """Hotkey path (works on Wayland where the pointer position can't be read)."""
        if self.state.kind == "controlling":
            self.release_to_local(notify=True)
            return
        if self.state.kind != "local" or not self.enabled or not self.edge_peers:
            return
        edge, p = next(iter(self.edge_peers.items())) if peer is None else next(
            ((e, pid) for e, pid in self.edge_peers.items() if pid == peer), (None, None))
        if edge is not None:
            self.begin_controlling(p, edge, 0.5)

    def begin_controlling(self, peer: str, edge: Edge, position: float) -> bool:
        if not self._send(peer, MsgType.ENTER_CONTROL, Control(edge, position).encode()):
            return False
        self.state = State("controlling", peer, edge)
        self._pending = [0.0, 0.0]
        self.on_grab(True)
        return True

    def release_to_local(self, notify: bool, warp: Optional[float] = None) -> None:
        if self.state.kind != "controlling":
            return
        self._flush()
        if self._flush_handle:
            self._flush_handle.cancel()
            self._flush_handle = None
        peer, edge = self.state.peer, self.state.edge
        if notify and peer:
            self._send(peer, MsgType.RELEASE_CONTROL, Control(edge or Edge.LEFT, -1.0).encode())
        self.state = State()
        self.on_grab(False)
        if warp is not None and edge is not None:
            x, y = edge_point(edge, warp, self.screen, 6)
            self.injector.move_abs(x / max(self.screen[0] - 1, 1), y / max(self.screen[1] - 1, 1))

    # ---- local side: events to forward while controlling -----------------------------------------

    def forward_motion(self, dx: float, dy: float) -> None:
        if self.state.kind != "controlling":
            return
        self._pending[0] += dx
        self._pending[1] += dy
        if self._flush_handle is None and self.loop is not None:
            self._flush_handle = self.loop.call_later(0.003, self._on_flush_timer)
        elif self.loop is None:
            self._flush()

    def _on_flush_timer(self) -> None:
        self._flush_handle = None
        self._flush()

    def _flush(self) -> None:
        if self.state.kind != "controlling" or self._pending == [0.0, 0.0] or not self.state.peer:
            return
        dx, dy = self._pending
        self._pending = [0.0, 0.0]
        self._send(self.state.peer, MsgType.MOUSE_MOVE, MouseMove(dx, dy).encode())

    def forward(self, type_: MsgType, payload: bytes) -> None:
        if self.state.kind == "controlling" and self.state.peer:
            self._flush()  # keep movement ordered before clicks/keys
            self._send(self.state.peer, type_, payload)

    # ---- remote side: messages from peers -------------------------------------------------------

    def on_message(self, peer: str, msg: Message) -> None:
        try:
            self._on_message(peer, msg)
        except Exception as e:  # noqa: BLE001 - one bad message must not take the daemon down
            log.error("bad input message from %s: %s", peer, e)

    def _on_message(self, peer: str, msg: Message) -> None:
        t = msg.type
        if t == MsgType.ENTER_CONTROL:
            if not self.enabled or self.state.kind != "local":
                self._send(peer, MsgType.RELEASE_CONTROL, Control(Edge.LEFT, -1.0).encode())
                return
            c = Control.decode(msg.payload)
            ret = c.edge.opposite
            self._cursor = edge_point(ret, c.position, self.screen, 2)
            self._return.reset()
            self.state = State("controlled", peer, ret)
            self._warp(self._cursor)
        elif t == MsgType.RELEASE_CONTROL:
            c = Control.decode(msg.payload)
            if self.state.kind == "controlling" and self.state.peer == peer:
                self.release_to_local(notify=False, warp=c.position if c.position >= 0 else None)
            elif self.state.kind == "controlled" and self.state.peer == peer:
                self._end_controlled()
        elif not self._controlled_by(peer):
            return
        elif t == MsgType.MOUSE_MOVE:
            m = MouseMove.decode(msg.payload)
            w, h = self.screen
            self._cursor = (min(max(self._cursor[0] + m.dx, 0), w - 1), min(max(self._cursor[1] + m.dy, 0), h - 1))
            self._warp(self._cursor)
            hit = self._return.update(self._cursor, (m.dx, m.dy), self.screen, {self.state.edge})
            if hit:
                self._send(peer, MsgType.RELEASE_CONTROL, Control(self.state.edge, hit[1]).encode())
                self._end_controlled()
        elif t == MsgType.MOUSE_BUTTON:
            b = MouseButton.decode(msg.payload)
            code = MAC_BUTTONS.get(b.button)
            if code is not None:
                self.injector.button(code, b.down)
        elif t == MsgType.SCROLL:
            s = Scroll.decode(msg.payload)
            sign = -1 if self.scroll_invert else 1
            # pixel deltas -> wheel notches (~40 px per notch); line deltas pass through
            scale = 1 / 40 if s.continuous else 1
            self._scroll_acc[0] += s.dx * scale * sign
            self._scroll_acc[1] += s.dy * scale * sign
            ix, iy = int(self._scroll_acc[0]), int(self._scroll_acc[1])
            self._scroll_acc[0] -= ix
            self._scroll_acc[1] -= iy
            if ix or iy:
                self.injector.scroll(ix, iy)
        elif t == MsgType.KEY_EVENT:
            k = Key.decode(msg.payload)
            code = mac_to_linux(k.key_code, self.swap_modifiers)
            if code is not None:
                self.injector.key(code, k.down)
        elif t == MsgType.FLAGS_CHANGED:
            k = Key.decode(msg.payload)
            pressed = self._mods.update(k.key_code, k.flags)
            code = mac_to_linux(k.key_code, self.swap_modifiers)
            if pressed is not None and code is not None:
                self.injector.key(code, pressed)

    def _controlled_by(self, peer: str) -> bool:
        return self.state.kind == "controlled" and self.state.peer == peer

    def _warp(self, p: Tuple[float, float]) -> None:
        self.injector.move_abs(p[0] / max(self.screen[0] - 1, 1), p[1] / max(self.screen[1] - 1, 1))

    def _end_controlled(self) -> None:
        self.injector.release_all()
        self._mods = ModifierTracker()
        self._return.reset()
        self.state = State()

    def peer_disconnected(self, peer: str) -> None:
        """Never leave devices grabbed or keys stuck when a peer vanishes."""
        if self.state.peer != peer:
            return
        if self.state.kind == "controlling":
            self.release_to_local(notify=False, warp=0.5)
        elif self.state.kind == "controlled":
            self._end_controlled()
