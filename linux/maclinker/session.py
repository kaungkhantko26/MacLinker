"""One TCP connection to one peer: handshake, pairing, encryption, heartbeat."""
from __future__ import annotations

import asyncio
import logging
import struct
import time
from typing import Awaitable, Callable, Optional

from cryptography.exceptions import InvalidTag

from . import APP_VERSION
from .crypto import Handshake, HandshakeError, INITIATOR, RESPONDER, SecureCodec, device_id
from .identity import Identity, TrustedStore
from .protocol import (HANDSHAKE_PHASE, MAX_FRAME, MAX_HANDSHAKE_FRAME, FrameBuffer, Hello, Message, MsgType,
                       ProtocolError, UnknownMessageType, decode_message, encode_message, frame)

log = logging.getLogger("maclinker.session")

HEARTBEAT_INTERVAL = 2.0
HEARTBEAT_TIMEOUT = 8.0
PAIRING_TIMEOUT = 90.0


class SessionError(Exception):
    pass


class Session:
    """Create with connected asyncio streams, then `await session.run()` until it ends."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, initiator: bool,
                 identity: Identity, trusted: TrustedStore, listen_port: int,
                 on_message: Callable[["Session", Message], None],
                 on_state: Callable[["Session", str], None],
                 on_pairing: Callable[["Session", str, str], Awaitable[bool]],
                 expected_peer_id: Optional[str] = None) -> None:
        self.reader, self.writer = reader, writer
        self.initiator = initiator
        self.identity, self.trusted = identity, trusted
        self.listen_port = listen_port
        self.on_message, self.on_state, self.on_pairing = on_message, on_state, on_pairing
        self.expected_peer_id = expected_peer_id

        role = INITIATOR if initiator else RESPONDER
        self._hs = Handshake(role, identity.key)
        self._codec: Optional[SecureCodec] = None
        self._seq = 0
        self._last_recv = time.monotonic()
        self._closed = False
        self._local_confirmed = False
        self._remote_confirmed = False
        self._pairing_task: Optional[asyncio.Task] = None

        self.state = "connecting"   # connecting | handshaking | pairing | connected | closed
        self.peer_id: Optional[str] = None
        self.peer_name = ""
        self.peer_key = b""
        self.peer_port = 0
        self.peer_version = "0"
        self.needs_pairing = False
        self.latency_ms: Optional[float] = None
        self.remote_host: Optional[str] = (writer.get_extra_info("peername") or (None,))[0]
        self.close_reason: Optional[Exception] = None

    # ---- lifecycle -----------------------------------------------------------------------------

    def _set_state(self, state: str) -> None:
        if self.state != state and self.state != "closed":
            self.state = state
            self.on_state(self, state)

    async def run(self) -> None:
        heartbeat: Optional[asyncio.Task] = None
        try:
            self._set_state("handshaking")
            self._write_raw(self._hs.own_hello)
            buf = FrameBuffer()
            hello = await self._read_frame(buf, MAX_HANDSHAKE_FRAME)
            self._hs.receive_hello(hello)
            self._write_raw(self._hs.make_auth())
            auth = await self._read_frame(buf, MAX_HANDSHAKE_FRAME)
            self._codec = self._hs.receive_auth(auth)
            self.peer_key = self._hs.peer_identity or b""
            self.peer_id = self._hs.peer_device_id
            if self.peer_id == self.identity.device_id:
                raise SessionError("connected to ourselves")
            if self.expected_peer_id and self.expected_peer_id != self.peer_id:
                raise SessionError("unexpected peer")
            self._send(MsgType.HELLO, Hello(self.identity.name, self.identity.device_id,
                                            self.trusted.is_trusted(self.peer_key), self.listen_port,
                                            APP_VERSION).encode())
            heartbeat = asyncio.create_task(self._heartbeat())
            while not self._closed:
                frame_ = await self._read_frame(buf, MAX_FRAME)
                self._handle_frame(frame_)
        except asyncio.IncompleteReadError:
            pass
        except (HandshakeError, ProtocolError, SessionError, InvalidTag, struct.error, OSError, ValueError) as e:
            self.close_reason = e
            log.info("session closed: %s", e)
        finally:
            if heartbeat:
                heartbeat.cancel()
            if self._pairing_task:
                self._pairing_task.cancel()
            await self.close()

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        self.state, prev = "closed", self.state
        try:
            self.writer.close()
            await self.writer.wait_closed()
        except Exception:  # noqa: BLE001 - closing a dead socket may raise anything
            pass
        self.on_state(self, "closed")

    # ---- reading -------------------------------------------------------------------------------

    async def _read_frame(self, buf: FrameBuffer, limit: int) -> bytes:
        while True:
            f = buf.next_frame(limit)
            if f is not None:
                return f
            data = await self.reader.read(256 * 1024)
            if not data:
                raise asyncio.IncompleteReadError(b"", None)
            self._last_recv = time.monotonic()
            buf.feed(data)

    def _handle_frame(self, frame_: bytes) -> None:
        assert self._codec is not None
        plain = self._codec.open(frame_)
        try:
            msg = decode_message(plain)
        except UnknownMessageType as e:
            log.info("ignoring unknown message type %s", e.code)  # a newer peer; skip, don't drop the link
            return
        if msg.type not in HANDSHAKE_PHASE and self.state != "connected":
            raise SessionError("data before pairing completed")
        self._handle_message(msg)

    def _handle_message(self, msg: Message) -> None:
        t = msg.type
        if t == MsgType.HELLO:
            hello = Hello.decode(msg.payload)
            if hello.device_id != self.peer_id:
                raise SessionError("id mismatch")
            self.peer_name, self.peer_port, self.peer_version = hello.name, hello.port, hello.app_version
            self.needs_pairing = not (self.trusted.is_trusted(self.peer_key) and hello.trusts_you)
            if self.needs_pairing:
                self._set_state("pairing")
                self._pairing_task = asyncio.create_task(self._ask_pairing())
            else:
                self._local_confirmed = True
                self._send(MsgType.PAIR_CONFIRM)
                self._complete_if_ready()
        elif t == MsgType.PAIR_CONFIRM:
            self._remote_confirmed = True
            self._complete_if_ready()
        elif t == MsgType.PAIR_REJECT:
            raise SessionError("pairing rejected by peer")
        elif t == MsgType.HEARTBEAT:
            kind, stamp = struct.unpack(">BQ", msg.payload)
            if kind == 0:
                self._send(MsgType.HEARTBEAT, struct.pack(">BQ", 1, stamp))
            else:
                self.latency_ms = float(int(time.time() * 1000) - stamp)
        else:
            self.on_message(self, msg)

    async def _ask_pairing(self) -> None:
        try:
            ok = await asyncio.wait_for(self.on_pairing(self, self.peer_name, self._hs.sas or ""), PAIRING_TIMEOUT)
        except asyncio.TimeoutError:
            ok = False
        except asyncio.CancelledError:
            return
        if self._closed:
            return
        if ok:
            self._local_confirmed = True
            self._send(MsgType.PAIR_CONFIRM)
            self._complete_if_ready()
        else:
            try:
                self._send(MsgType.PAIR_REJECT)
                await asyncio.sleep(0.2)
            finally:
                await self.close()

    def _complete_if_ready(self) -> None:
        if self._local_confirmed and self._remote_confirmed and self.state not in ("connected", "closed"):
            if self.needs_pairing:
                self.trusted.trust(self.peer_id or "", self.peer_name, self.peer_key)
            self._set_state("connected")

    # ---- writing -------------------------------------------------------------------------------

    def _write_raw(self, body: bytes) -> None:
        self.writer.write(frame(body))

    def _send(self, type_: MsgType, payload: bytes = b"") -> None:
        """Seal and write in one synchronous step so the AEAD counter always matches wire order."""
        if self._closed or self._codec is None:
            raise SessionError("not connected")
        if type_ not in HANDSHAKE_PHASE and self.state != "connected":
            raise SessionError("not connected")
        plain = encode_message(type_, self._seq, payload)
        self._seq = (self._seq + 1) & 0xFFFFFFFF
        self.writer.write(frame(self._codec.seal(plain)))

    def send(self, type_: MsgType, payload: bytes = b"") -> bool:
        """Fire-and-forget send. Returns False if the session can't carry it right now."""
        try:
            self._send(type_, payload)
            return True
        except SessionError:
            return False

    async def send_drain(self, type_: MsgType, payload: bytes = b"") -> None:
        """Send and wait until the socket buffer has room: used for file chunks (backpressure)."""
        self._send(type_, payload)
        await self.writer.drain()

    async def _heartbeat(self) -> None:
        while not self._closed:
            await asyncio.sleep(HEARTBEAT_INTERVAL)
            if time.monotonic() - self._last_recv > HEARTBEAT_TIMEOUT:
                self.close_reason = SessionError("timeout")
                await self.close()
                return
            if self._codec is not None and self.peer_id:
                try:
                    self._send(MsgType.HEARTBEAT, struct.pack(">BQ", 0, int(time.time() * 1000)))
                except SessionError:
                    pass
