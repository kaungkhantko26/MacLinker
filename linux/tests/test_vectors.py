"""The Python implementation must match the bytes produced by the macOS app's Swift code."""
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from maclinker import protocol as p
from maclinker.crypto import INITIATOR, RESPONDER, Handshake, device_id, raw_public


def make(role, id_seed, eph_seed):
    return Handshake(role, Ed25519PrivateKey.from_private_bytes(bytes([id_seed]) * 32),
                     X25519PrivateKey.from_private_bytes(bytes([eph_seed]) * 32))


def test_handshake_matches_swift(vectors):
    i, r = make(INITIATOR, 1, 3), make(RESPONDER, 2, 4)
    assert i.own_hello.hex() == vectors["initiator_hello"]
    assert r.own_hello.hex() == vectors["responder_hello"]
    i.receive_hello(r.own_hello)
    r.receive_hello(i.own_hello)
    assert i.sas == r.sas == vectors["sas"]
    assert i.peer_device_id == device_id(bytes.fromhex(vectors["responder_identity_pub"]))
    assert device_id(bytes.fromhex(vectors["initiator_identity_pub"])) == vectors["initiator_device_id"]


def test_signatures_from_swift_verify_and_ciphertext_matches(vectors):
    i, r = make(INITIATOR, 1, 3), make(RESPONDER, 2, 4)
    i.receive_hello(r.own_hello)
    r.receive_hello(i.own_hello)
    # Swift's Ed25519 signatures are randomized, so verify them instead of comparing bytes.
    ci = i.receive_auth(bytes.fromhex(vectors["responder_auth"]))
    cr = r.receive_auth(bytes.fromhex(vectors["initiator_auth"]))
    # Encryption is deterministic: the same plaintext must give the same ciphertext as Swift.
    plain_i = bytes.fromhex(vectors["plain_initiator"])
    assert ci.seal(plain_i).hex() == vectors["sealed_initiator_0"]
    assert ci.seal(plain_i).hex() == vectors["sealed_initiator_1"]
    assert cr.seal(bytes.fromhex(vectors["plain_responder"])).hex() == vectors["sealed_responder_0"]
    # ...and we can open what Swift sealed.
    assert cr.open(bytes.fromhex(vectors["sealed_initiator_0"])) == plain_i
    assert cr.open(bytes.fromhex(vectors["sealed_initiator_1"])) == plain_i
    assert ci.open(bytes.fromhex(vectors["sealed_responder_0"])) == bytes.fromhex(vectors["plain_responder"])


def test_our_signatures_are_accepted_by_ourselves():
    i, r = make(INITIATOR, 5, 6), make(RESPONDER, 7, 8)
    i.receive_hello(r.own_hello)
    r.receive_hello(i.own_hello)
    ci, cr = i.receive_auth(r.make_auth()), r.receive_auth(i.make_auth())
    assert cr.open(ci.seal(b"hi")) == b"hi"


def test_message_and_payload_encodings_match_swift(vectors):
    msg = p.encode_message(p.MsgType.MOUSE_MOVE, 0, p.MouseMove(1.5, -2).encode())
    assert msg.hex() == vectors["plain_initiator"]
    assert p.encode_message(p.MsgType.HEARTBEAT, 7, bytes([1, 0, 0, 0, 0, 0, 0, 0, 9])).hex() == vectors["plain_responder"]
    assert p.Key(55, True, 0x100000, False).encode().hex() == vectors["key_payload"]
    assert p.MouseButton(1, True, 2).encode().hex() == vectors["button_payload"]
    assert p.Scroll(-3, 12, True).encode().hex() == vectors["scroll_payload"]
    assert p.Control(p.Edge.RIGHT, 0.25).encode().hex() == vectors["control_payload"]
    assert p.Layout(p.Edge.LEFT, True).encode().hex() == vectors["layout_payload"]
    assert p.SystemState(True, True, 0.5, 0.25, False).encode().hex() == vectors["system_state_payload"]


def test_payload_round_trips():
    assert p.Key.decode(p.Key(55, True, 0x100000, True).encode()) == p.Key(55, True, 0x100000, True)
    assert p.Control.decode(p.Control(p.Edge.TOP, 0.5).encode()).edge == p.Edge.TOP
    assert p.Layout.decode(p.Layout(None, False).encode()).peer_position is None
    assert p.SystemState.decode(p.SystemState(True, False, 0.1, 0.2, True).encode()).muted


def test_unknown_type_and_bad_magic():
    import pytest
    data = bytearray(p.encode_message(p.MsgType.HEARTBEAT, 1))
    data[5] = 250
    with pytest.raises(p.UnknownMessageType):
        p.decode_message(bytes(data))
    data[0] = 0
    with pytest.raises(p.ProtocolError):
        p.decode_message(bytes(data))


def test_frame_buffer_split_and_oversize():
    import pytest
    buf = p.FrameBuffer()
    data = p.frame(b"abc") + p.frame(b"de")
    buf.feed(data[:2])
    assert buf.next_frame(100) is None
    buf.feed(data[2:])
    assert buf.next_frame(100) == b"abc"
    assert buf.next_frame(100) == b"de"
    assert buf.next_frame(100) is None
    buf.feed(p.frame(b"x" * 2000))
    with pytest.raises(p.ProtocolError):
        buf.next_frame(p.MAX_HANDSHAKE_FRAME)


def test_tampered_ciphertext_and_replay_rejected():
    import pytest
    from cryptography.exceptions import InvalidTag
    i, r = make(INITIATOR, 9, 10), make(RESPONDER, 11, 12)
    i.receive_hello(r.own_hello)
    r.receive_hello(i.own_hello)
    ci, cr = i.receive_auth(r.make_auth()), r.receive_auth(i.make_auth())
    frame = ci.seal(b"once")
    assert cr.open(frame) == b"once"
    with pytest.raises(InvalidTag):
        cr.open(frame)  # replay
    bad = bytearray(ci.seal(b"x"))
    bad[0] ^= 1
    with pytest.raises(InvalidTag):
        cr.open(bytes(bad))
