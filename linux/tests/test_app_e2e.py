"""Two complete daemons on loopback: pair, connect, mirror layout, hand control across, transfer a file."""
import asyncio
import tempfile
from pathlib import Path

import pytest

from maclinker import protocol as p
from maclinker.app import App, apply_remote_layout
from maclinker.identity import TrustedStore


def short_dir() -> Path:
    return Path(tempfile.mkdtemp(prefix="ml", dir="/tmp"))   # unix socket paths must be short


async def wait_for(cond, timeout=8):
    end = asyncio.get_running_loop().time() + timeout
    while not cond():
        if asyncio.get_running_loop().time() > end:
            raise AssertionError("timed out")
        await asyncio.sleep(0.02)


async def start(app: App):
    task = asyncio.create_task(app.run())
    await wait_for(lambda: hasattr(app, "files") and app.port != 52845 or getattr(app, "control", None))
    await wait_for(lambda: app.ctl_path.exists())
    return task


@pytest.mark.asyncio
async def test_full_flow_between_two_daemons():
    a = App(port=0, discovery=False, capture=False, config=short_dir())
    b = App(port=0, discovery=False, capture=False, config=short_dir())
    ta, tb = await start(a), await start(b)
    try:
        assert "connecting" in await a.connect("127.0.0.1", b.port)
        await wait_for(lambda: a.pairing and b.pairing)
        assert a.pairing.code == b.pairing.code
        assert (await a.handle_command({"cmd": "confirm"}))["ok"] and (await b.handle_command({"cmd": "confirm"}))["ok"]
        await wait_for(lambda: a.sessions and b.sessions and
                       all(s.state == "connected" for s in [*a.sessions.values(), *b.sessions.values()]))
        assert a.trusted.get(b.identity.device_id) and b.trusted.get(a.identity.device_id)

        # layout: A says B is on its right -> B records A on its left, and both can hand control across
        await a.handle_command({"cmd": "position", "device": b.identity.name, "edge": "right"})
        await wait_for(lambda: b.trusted.get(a.identity.device_id).position == "left")
        assert a.control.edge_peers == {p.Edge.RIGHT: b.identity.device_id}
        a.control.begin_controlling(b.identity.device_id, p.Edge.RIGHT, 0.5)
        await wait_for(lambda: b.control.state.kind == "controlled")
        a.control.forward_motion(10, 0)
        a.control.release_to_local(notify=True)
        await wait_for(lambda: b.control.state.kind == "local")

        # file transfer A -> B
        src = short_dir() / "note.txt"
        src.write_text("hello from A")
        b.files.directory = short_dir()
        reply = await a.handle_command({"cmd": "send", "path": str(src)})
        assert reply["ok"]
        await wait_for(lambda: b.files.log and b.files.log[-1][2] == "done")
        assert (b.files.directory / "note.txt").read_text() == "hello from A"

        # reconnect without pairing
        await a.sessions[b.identity.device_id].close()
        await wait_for(lambda: not a.sessions and not b.sessions)
        assert "connecting" in await a.connect("127.0.0.1", b.port)
        await wait_for(lambda: a.sessions and b.sessions and
                       all(s.state == "connected" for s in [*a.sessions.values(), *b.sessions.values()]))
        assert a.pairing is None
    finally:
        for t in (ta, tb):
            t.cancel()


def test_layout_sync_rules(tmp_path):
    store = TrustedStore(tmp_path)
    store.trust("bbbb", "B", b"k" * 32)
    # user change always applies, mirrored
    assert apply_remote_layout(store, "aaaa", "bbbb", p.Layout(p.Edge.RIGHT, True))
    assert store.get("bbbb").position == "left"
    # connect-time sync: sender with the larger ID loses to our existing setting...
    assert not apply_remote_layout(store, "aaaa", "bbbb", p.Layout(p.Edge.TOP, False))
    # ...but the sender with the smaller ID wins
    assert apply_remote_layout(store, "cccc", "bbbb", p.Layout(p.Edge.TOP, False))
    assert store.get("bbbb").position == "bottom"
    # "unset" during sync is ignored
    assert not apply_remote_layout(store, "aaaa", "bbbb", p.Layout(None, False))
