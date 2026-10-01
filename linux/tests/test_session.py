import asyncio
import tempfile
from pathlib import Path

import pytest

from maclinker.identity import Identity, TrustedStore
from maclinker.protocol import MouseMove, MsgType
from maclinker.session import Session


class Peer:
    def __init__(self, tmp, auto_confirm=True):
        d = Path(tempfile.mkdtemp(dir=tmp))
        self.identity, self.trusted = Identity(d), TrustedStore(d)
        self.messages, self.states, self.codes = [], [], []
        self.auto_confirm = auto_confirm
        self.hold = None   # set to an asyncio.Event to keep a pairing prompt open
        self.session = None

    async def pairing(self, session, name, sas):
        self.codes.append(sas)
        if self.hold is not None:
            await self.hold.wait()
        return self.auto_confirm

    def attach(self, reader, writer, initiator):
        self.session = Session(reader, writer, initiator, self.identity, self.trusted, 1234,
                               lambda s, m: self.messages.append(m), lambda s, st: self.states.append(st),
                               self.pairing)
        return self.session


async def connect_pair(a: Peer, b: Peer):
    server_ready = asyncio.get_running_loop().create_future()

    async def on_conn(reader, writer):
        server_ready.set_result(asyncio.create_task(b.attach(reader, writer, False).run()))

    server = await asyncio.start_server(on_conn, "127.0.0.1", 0)
    port = server.sockets[0].getsockname()[1]
    reader, writer = await asyncio.open_connection("127.0.0.1", port)
    task_a = asyncio.create_task(a.attach(reader, writer, True).run())
    task_b = await server_ready
    return server, task_a, task_b


async def wait_for(cond, timeout=5):
    end = asyncio.get_running_loop().time() + timeout
    while not cond():
        if asyncio.get_running_loop().time() > end:
            raise AssertionError("timed out")
        await asyncio.sleep(0.01)


@pytest.mark.asyncio
async def test_pair_connect_and_exchange_messages(tmp_path):
    a, b = Peer(tmp_path), Peer(tmp_path)
    server, ta, tb = await connect_pair(a, b)
    await wait_for(lambda: a.session.state == "connected" and b.session.state == "connected")
    assert a.codes == b.codes and len(a.codes[0]) == 6            # both saw the same code
    assert a.trusted.is_trusted(b.identity.public_key)             # trust persisted after both confirmed
    assert a.session.peer_name == b.identity.name
    assert a.session.send(MsgType.MOUSE_MOVE, MouseMove(3, 4).encode())
    await wait_for(lambda: b.messages)
    assert b.messages[0].type == MsgType.MOUSE_MOVE
    await a.session.close()
    await asyncio.wait_for(tb, 5)
    server.close()


@pytest.mark.asyncio
async def test_second_connection_needs_no_pairing(tmp_path):
    a, b = Peer(tmp_path), Peer(tmp_path)
    server, ta, tb = await connect_pair(a, b)
    await wait_for(lambda: a.session.state == "connected")
    await a.session.close(); await asyncio.wait_for(tb, 5); server.close()
    a.codes.clear(); b.codes.clear()
    server, ta, tb = await connect_pair(a, b)
    await wait_for(lambda: a.session.state == "connected" and b.session.state == "connected")
    assert not a.codes and not b.codes and not a.session.needs_pairing
    await a.session.close(); await asyncio.wait_for(tb, 5); server.close()


@pytest.mark.asyncio
async def test_rejected_pairing_closes_and_does_not_trust(tmp_path):
    a, b = Peer(tmp_path), Peer(tmp_path, auto_confirm=False)
    server, ta, tb = await connect_pair(a, b)
    await asyncio.wait_for(asyncio.gather(ta, tb), 8)
    assert a.session.state == "closed" and b.session.state == "closed"
    assert not a.trusted.is_trusted(b.identity.public_key)
    assert not b.trusted.is_trusted(a.identity.public_key)
    server.close()


@pytest.mark.asyncio
async def test_data_before_pairing_is_refused(tmp_path):
    a, b = Peer(tmp_path), Peer(tmp_path, auto_confirm=False)
    b.hold = asyncio.Event()
    server, ta, tb = await connect_pair(a, b)
    await wait_for(lambda: a.session.state == "pairing" and b.session.state == "pairing")
    assert not a.session.send(MsgType.MOUSE_MOVE, MouseMove(1, 1).encode())
    b.hold.set()   # now b rejects
    await asyncio.wait_for(asyncio.gather(ta, tb), 8)
    server.close()
