import asyncio
import json
import uuid

from maclinker import clipboard as cb
from maclinker import protocol as p
from maclinker.files import FileTransfer, safe_name, unique_path


def test_safe_name_blocks_path_tricks(tmp_path):
    assert safe_name("../../etc/passwd") == "passwd"
    assert safe_name("..\\..\\win.ini") == "win.ini"
    assert safe_name("...") == "file" and safe_name(".hidden") == "hidden"
    (tmp_path / "a.txt").write_text("x")
    assert unique_path(tmp_path, "a.txt").name == "a 1.txt"


def test_receive_file_from_mac_format_and_verify_checksum(tmp_path):
    import hashlib
    sent = []
    ft = FileTransfer(lambda peer, t, payload: sent.append((t, payload)) or True, directory=tmp_path)
    fid = uuid.uuid4()
    data = b"hello" * 1000
    ft.on_message("mac", p.Message(p.MsgType.FILE_OFFER, 0, json.dumps(
        {"id": str(fid).upper(), "name": "../evil.txt", "size": len(data)}).encode()))
    for i in range(0, len(data), 1500):
        ft.on_message("mac", p.Message(p.MsgType.FILE_CHUNK, 0, fid.bytes + data[i:i + 1500]))
    ft.on_message("mac", p.Message(p.MsgType.FILE_END, 0, fid.bytes + hashlib.sha256(data).digest()))
    assert (tmp_path / "evil.txt").read_bytes() == data      # sanitised name, content intact
    assert ft.log[-1][2] == "done"


def test_bad_checksum_and_oversize_are_discarded(tmp_path):
    ft = FileTransfer(lambda *a: True, directory=tmp_path)
    fid = uuid.uuid4()
    ft.on_message("mac", p.Message(p.MsgType.FILE_OFFER, 0, json.dumps({"id": str(fid), "name": "x", "size": 3}).encode()))
    ft.on_message("mac", p.Message(p.MsgType.FILE_CHUNK, 0, fid.bytes + b"abc"))
    ft.on_message("mac", p.Message(p.MsgType.FILE_END, 0, fid.bytes + b"\x00" * 32))
    assert not (tmp_path / "x").exists()
    fid2 = uuid.uuid4()
    ft.on_message("mac", p.Message(p.MsgType.FILE_OFFER, 0, json.dumps({"id": str(fid2), "name": "y", "size": 2}).encode()))
    ft.on_message("mac", p.Message(p.MsgType.FILE_CHUNK, 0, fid2.bytes + b"toolong"))
    assert not (tmp_path / "y").exists() and not ft.incoming


def test_disabled_sharing_aborts_offer(tmp_path):
    sent = []
    ft = FileTransfer(lambda peer, t, payload: sent.append(t) or True, enabled=lambda: False, directory=tmp_path)
    ft.on_message("mac", p.Message(p.MsgType.FILE_OFFER, 0, json.dumps({"id": str(uuid.uuid4()), "name": "z", "size": 1}).encode()))
    assert sent == [p.MsgType.FILE_ABORT]


class FakeBackend(cb.Backend):
    def __init__(self, types, data):
        self._types, self._data, self.written = types, data, []

    def types(self): return self._types
    def read(self, mime): return self._data.get(mime)
    def write(self, mime, data): self.written.append((mime, data))


def test_clipboard_message_format_matches_swift_codable():
    msg = json.loads(cb.encode_message({cb.TEXT: b"hi"}))
    assert msg == {"entries": [{"type": "public.utf8-plain-text", "data": "aGk="}]}
    assert cb.decode_message(cb.encode_message({cb.PNG: b"\x89PNG"})) == {cb.PNG: b"\x89PNG"}


def test_clipboard_sends_text_once_and_skips_password_manager_items():
    sent = []
    b = FakeBackend(["text/plain"], {"text/plain;charset=utf-8": b"secret?", "UTF8_STRING": b"secret?", "text/plain": b"secret?"})
    sync = cb.ClipboardSync(b, sent.append)
    sync.poll_once(); sync.poll_once()
    assert len(sent) == 1                                   # unchanged clipboard isn't re-sent
    b._types = ["text/plain", "x-kde-passwordManagerHint"]
    b._data = {"text/plain": b"hunter2"}
    sync.poll_once()
    assert len(sent) == 1                                   # password-manager item never leaves the machine


def test_clipboard_receive_prefers_image_and_does_not_echo():
    b = FakeBackend([], {})
    sent = []
    sync = cb.ClipboardSync(b, sent.append)
    sync.receive(cb.encode_message({cb.TEXT: b"t", cb.PNG: b"img"}))
    assert b.written == [("image/png", b"img")]
    b._types, b._data = ["image/png"], {"image/png": b"img"}
    sync.poll_once()
    assert sent == []                                       # what we just received isn't sent back
    off = cb.ClipboardSync(b, sent.append, enabled=lambda: False)
    off.receive(cb.encode_message({cb.TEXT: b"x"}))
    assert len(b.written) == 1
