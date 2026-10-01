"""Authenticated key exchange and the encrypted channel. Byte-compatible with the macOS app
(see Sources/MacLinker/Security/EncryptionManager.swift and the vectors in tests/vectors.json)."""
from __future__ import annotations

import hashlib
import struct
from typing import Optional

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

from .protocol import MAGIC, VERSION

HELLO_LENGTH = 4 + 1 + 32 + 32
INITIATOR, RESPONDER = 1, 2


class HandshakeError(Exception):
    pass


def raw_public(key) -> bytes:
    return key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)


def device_id(public_key: bytes) -> str:
    """First 8 bytes of SHA-256 over the identity public key, hex."""
    return hashlib.sha256(public_key).digest()[:8].hex()


class SecureCodec:
    """ChaCha20-Poly1305 with an implicit, strictly increasing counter nonce (replay/reorder safe)."""

    def __init__(self, send_key: bytes, receive_key: bytes) -> None:
        self._send = ChaCha20Poly1305(send_key)
        self._recv = ChaCha20Poly1305(receive_key)
        self._send_counter = 0
        self._recv_counter = 0

    @staticmethod
    def _nonce(counter: int) -> bytes:
        return b"\x00\x00\x00\x00" + struct.pack(">Q", counter)

    def seal(self, plaintext: bytes) -> bytes:
        out = self._send.encrypt(self._nonce(self._send_counter), plaintext, None)
        self._send_counter += 1
        return out

    def open(self, data: bytes) -> bytes:
        if len(data) < 16:
            raise HandshakeError("ciphertext too short")
        out = self._recv.decrypt(self._nonce(self._recv_counter), data, None)  # raises InvalidTag
        self._recv_counter += 1
        return out


class Handshake:
    def __init__(self, role: int, identity: Ed25519PrivateKey,
                 ephemeral: Optional[X25519PrivateKey] = None) -> None:
        self.role = role
        self._identity = identity
        self._ephemeral = ephemeral or X25519PrivateKey.generate()
        self.own_hello = (struct.pack(">IB", MAGIC, VERSION) + raw_public(identity)
                          + raw_public(self._ephemeral))
        self.peer_identity: Optional[bytes] = None
        self._peer_ephemeral: Optional[bytes] = None
        self._transcript: Optional[bytes] = None

    @property
    def peer_device_id(self) -> Optional[str]:
        return device_id(self.peer_identity) if self.peer_identity else None

    def receive_hello(self, data: bytes) -> None:
        if len(data) != HELLO_LENGTH:
            raise HandshakeError("malformed hello")
        magic, version = struct.unpack_from(">IB", data)
        if magic != MAGIC or version != VERSION:
            raise HandshakeError("malformed hello")
        self.peer_identity = data[5:37]
        self._peer_ephemeral = data[37:69]
        initiator_hello = self.own_hello if self.role == INITIATOR else data
        responder_hello = data if self.role == INITIATOR else self.own_hello
        self._transcript = hashlib.sha256(b"maclinker-v1-transcript" + initiator_hello + responder_hello).digest()

    def make_auth(self) -> bytes:
        if self._transcript is None:
            raise HandshakeError("out of order")
        return self._identity.sign(self._transcript + bytes([self.role]))

    def receive_auth(self, signature: bytes) -> SecureCodec:
        if self._transcript is None or self.peer_identity is None or self._peer_ephemeral is None:
            raise HandshakeError("out of order")
        other = RESPONDER if self.role == INITIATOR else INITIATOR
        try:
            Ed25519PublicKey.from_public_bytes(self.peer_identity).verify(signature, self._transcript + bytes([other]))
        except InvalidSignature:
            raise HandshakeError("bad signature") from None
        shared = self._ephemeral.exchange(X25519PublicKey.from_public_bytes(self._peer_ephemeral))
        if not any(shared):  # low-order point
            raise HandshakeError("weak shared secret")

        def derive(label: str) -> bytes:
            return HKDF(algorithm=hashes.SHA256(), length=32, salt=self._transcript,
                        info=label.encode()).derive(shared)

        i2r = derive("maclinker-v1-initiator-to-responder")
        r2i = derive("maclinker-v1-responder-to-initiator")
        return SecureCodec(i2r, r2i) if self.role == INITIATOR else SecureCodec(r2i, i2r)

    @property
    def sas(self) -> Optional[str]:
        """Six digits both users compare when pairing."""
        if self._transcript is None:
            return None
        digest = hashlib.sha256(b"maclinker-v1-sas" + self._transcript).digest()
        return f"{int.from_bytes(digest[:4], 'big') % 1_000_000:06d}"
