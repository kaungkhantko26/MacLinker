"""Wire format shared with the macOS app (see Sources/MacLinker/Network/Message*.swift)."""
from __future__ import annotations

import json
import struct
from dataclasses import dataclass
from enum import IntEnum
from typing import Optional

MAGIC = 0x4D4C4E4B  # "MLNK"
VERSION = 1
HEADER = struct.Struct(">IBBII")  # magic, version, type, sequence, payload length
MAX_FRAME = 16 * 1024 * 1024
MAX_HANDSHAKE_FRAME = 1024


class MsgType(IntEnum):
    HELLO = 1
    PAIR_CONFIRM = 2
    PAIR_REJECT = 3
    HEARTBEAT = 4
    MOUSE_MOVE = 10
    MOUSE_BUTTON = 11
    SCROLL = 12
    KEY_EVENT = 13
    FLAGS_CHANGED = 14
    ENTER_CONTROL = 20
    RELEASE_CONTROL = 21
    LAYOUT = 22
    CLIPBOARD = 30
    FILE_OFFER = 40
    FILE_CHUNK = 41
    FILE_END = 42
    FILE_ABORT = 43
    SYSTEM_CONTROL = 50
    SYSTEM_STATE = 51
    SYSTEM_QUERY = 52


HANDSHAKE_PHASE = {MsgType.HELLO, MsgType.PAIR_CONFIRM, MsgType.PAIR_REJECT, MsgType.HEARTBEAT}


class ProtocolError(Exception):
    pass


class UnknownMessageType(ProtocolError):
    def __init__(self, code: int):
        super().__init__(f"unknown message type {code}")
        self.code = code


class Edge(IntEnum):
    LEFT = 1
    RIGHT = 2
    TOP = 3
    BOTTOM = 4

    @property
    def opposite(self) -> "Edge":
        return {Edge.LEFT: Edge.RIGHT, Edge.RIGHT: Edge.LEFT, Edge.TOP: Edge.BOTTOM, Edge.BOTTOM: Edge.TOP}[self]

    @property
    def title(self) -> str:
        return self.name.lower()

    @staticmethod
    def parse(text: str) -> Optional["Edge"]:
        try:
            return Edge[text.strip().upper()]
        except KeyError:
            return None


@dataclass
class Message:
    type: MsgType
    sequence: int
    payload: bytes


def encode_message(type_: MsgType, sequence: int, payload: bytes = b"") -> bytes:
    return HEADER.pack(MAGIC, VERSION, int(type_), sequence & 0xFFFFFFFF, len(payload)) + payload


def decode_message(data: bytes) -> Message:
    if len(data) < HEADER.size:
        raise ProtocolError("short message")
    magic, version, raw_type, sequence, length = HEADER.unpack_from(data)
    if magic != MAGIC:
        raise ProtocolError("bad magic")
    if version != VERSION:
        raise ProtocolError(f"unsupported version {version}")
    if len(data) - HEADER.size != length:
        raise ProtocolError("length mismatch")
    try:
        type_ = MsgType(raw_type)
    except ValueError:
        raise UnknownMessageType(raw_type) from None
    return Message(type_, sequence, data[HEADER.size:])


def frame(body: bytes) -> bytes:
    return struct.pack(">I", len(body)) + body


class FrameBuffer:
    """Reassembles length-prefixed frames from a byte stream."""

    def __init__(self) -> None:
        self._buf = bytearray()

    def feed(self, data: bytes) -> None:
        self._buf += data

    def next_frame(self, limit: int) -> Optional[bytes]:
        if len(self._buf) < 4:
            return None
        (length,) = struct.unpack_from(">I", self._buf)
        if length > limit:
            raise ProtocolError("frame too large")
        if len(self._buf) < 4 + length:
            return None
        body = bytes(self._buf[4:4 + length])
        del self._buf[:4 + length]
        return body


# --- payloads -------------------------------------------------------------------------------------

@dataclass
class Hello:
    name: str
    device_id: str
    trusts_you: bool
    port: int
    app_version: str

    def encode(self) -> bytes:
        return json.dumps({"name": self.name, "deviceID": self.device_id, "trustsYou": self.trusts_you,
                           "port": self.port, "appVersion": self.app_version}).encode()

    @staticmethod
    def decode(data: bytes) -> "Hello":
        try:
            d = json.loads(data)
            return Hello(str(d["name"])[:80], str(d["deviceID"]), bool(d["trustsYou"]),
                         int(d.get("port", 0)), str(d.get("appVersion", "0")))
        except (ValueError, KeyError, TypeError) as e:
            raise ProtocolError(f"bad hello: {e}") from None


@dataclass
class MouseMove:
    dx: float
    dy: float
    FMT = struct.Struct(">ff")

    def encode(self) -> bytes:
        return self.FMT.pack(self.dx, self.dy)

    @staticmethod
    def decode(data: bytes) -> "MouseMove":
        return MouseMove(*MouseMove.FMT.unpack(data))


@dataclass
class MouseButton:
    button: int
    down: bool
    click_count: int
    FMT = struct.Struct(">BBB")

    def encode(self) -> bytes:
        return self.FMT.pack(self.button, 1 if self.down else 0, self.click_count)

    @staticmethod
    def decode(data: bytes) -> "MouseButton":
        b, d, c = MouseButton.FMT.unpack(data)
        return MouseButton(b, d != 0, c)


@dataclass
class Scroll:
    dx: int
    dy: int
    continuous: bool
    FMT = struct.Struct(">iiB")

    def encode(self) -> bytes:
        return self.FMT.pack(self.dx, self.dy, 1 if self.continuous else 0)

    @staticmethod
    def decode(data: bytes) -> "Scroll":
        dx, dy, c = Scroll.FMT.unpack(data)
        return Scroll(dx, dy, c != 0)


@dataclass
class Key:
    """`key_code` is a macOS virtual key code; `flags` is a CGEventFlags bit set."""
    key_code: int
    down: bool
    flags: int
    autorepeat: bool
    FMT = struct.Struct(">HBQB")

    def encode(self) -> bytes:
        return self.FMT.pack(self.key_code, 1 if self.down else 0, self.flags, 1 if self.autorepeat else 0)

    @staticmethod
    def decode(data: bytes) -> "Key":
        k, d, f, a = Key.FMT.unpack(data)
        return Key(k, d != 0, f, a != 0)


@dataclass
class Control:
    edge: Edge
    position: float
    FMT = struct.Struct(">Bf")

    def encode(self) -> bytes:
        return self.FMT.pack(int(self.edge), self.position)

    @staticmethod
    def decode(data: bytes) -> "Control":
        e, p = Control.FMT.unpack(data)
        try:
            return Control(Edge(e), p)
        except ValueError:
            raise ProtocolError("bad edge") from None


@dataclass
class Layout:
    """Where the sender places the receiver relative to its own screen (None = unset)."""
    peer_position: Optional[Edge]
    user_initiated: bool
    FMT = struct.Struct(">BB")

    def encode(self) -> bytes:
        return self.FMT.pack(int(self.peer_position) if self.peer_position else 0, 1 if self.user_initiated else 0)

    @staticmethod
    def decode(data: bytes) -> "Layout":
        e, u = Layout.FMT.unpack(data)
        try:
            return Layout(Edge(e) if e else None, u != 0)
        except ValueError:
            raise ProtocolError("bad edge") from None


@dataclass
class SystemState:
    has_brightness: bool
    has_volume: bool
    brightness: float
    volume: float
    muted: bool
    FMT = struct.Struct(">BBffB")

    def encode(self) -> bytes:
        return self.FMT.pack(self.has_brightness, self.has_volume, self.brightness, self.volume, self.muted)

    @staticmethod
    def decode(data: bytes) -> "SystemState":
        a, b, c, d, e = SystemState.FMT.unpack(data)
        return SystemState(a != 0, b != 0, c, d, e != 0)
