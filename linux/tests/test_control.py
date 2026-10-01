from maclinker import protocol as p
from maclinker.control import ControlManager, EdgeDetector, edge_point
from maclinker.keymap import FLAG_COMMAND, FlagState, ModifierTracker, linux_to_mac, mac_to_linux
from maclinker.screen import parse_drm_mode, parse_xrandr

SIZE = (1000, 800)


class FakeInjector:
    def __init__(self):
        self.events = []

    def move_abs(self, x, y): self.events.append(("move", round(x, 3), round(y, 3)))
    def button(self, code, down): self.events.append(("button", code, down))
    def scroll(self, dx, dy): self.events.append(("scroll", dx, dy))
    def key(self, code, down): self.events.append(("key", code, down))
    def release_all(self): self.events.append(("release_all",))


def make():
    sent, inj = [], FakeInjector()
    cm = ControlManager(inj, lambda peer, t, payload: sent.append((peer, t, payload)) or True, SIZE)
    return cm, inj, sent


def msg(t, payload=b""):
    return p.Message(t, 0, payload)


def test_edge_push_hands_control_to_peer_and_grabs():
    cm, inj, sent = make()
    cm.edge_peers = {p.Edge.RIGHT: "mac"}
    grabs = []
    cm.on_grab = grabs.append
    results = [cm.local_pointer((999, 400), (5, 0)) for _ in range(3)]
    assert results == [False, False, True]
    assert cm.state.kind == "controlling" and grabs == [True]
    peer, t, payload = sent[0]
    assert (peer, t) == ("mac", p.MsgType.ENTER_CONTROL)
    c = p.Control.decode(payload)
    assert c.edge == p.Edge.RIGHT and abs(c.position - 400 / 799) < 1e-6


def test_motion_is_batched_and_ordered_before_clicks():
    cm, inj, sent = make()
    cm.edge_peers = {p.Edge.RIGHT: "mac"}
    cm.begin_controlling("mac", p.Edge.RIGHT, 0.5)
    sent.clear()
    for _ in range(5):
        cm.forward_motion(1, 2)          # loop is None -> flushes immediately; use batching path below
    assert len(sent) == 5
    cm.loop = None
    sent.clear()
    cm.state.kind = "controlling"
    cm._pending = [3.0, 4.0]
    cm.forward(p.MsgType.MOUSE_BUTTON, p.MouseButton(0, True, 1).encode())
    assert [t for _, t, _ in sent] == [p.MsgType.MOUSE_MOVE, p.MsgType.MOUSE_BUTTON]


def test_controlled_by_mac_moves_clicks_scrolls_and_types():
    cm, inj, sent = make()
    cm.on_message("mac", msg(p.MsgType.ENTER_CONTROL, p.Control(p.Edge.RIGHT, 0.5).encode()))
    assert cm.state.kind == "controlled" and cm.state.edge == p.Edge.LEFT    # returns through the left edge
    assert inj.events[0][0] == "move" and inj.events[0][1] < 0.01
    cm.on_message("mac", msg(p.MsgType.MOUSE_MOVE, p.MouseMove(100, 0).encode()))
    assert inj.events[-1][1] > 0.1
    cm.on_message("mac", msg(p.MsgType.MOUSE_BUTTON, p.MouseButton(0, True, 1).encode()))
    assert inj.events[-1] == ("button", 0x110, True)
    cm.on_message("mac", msg(p.MsgType.KEY_EVENT, p.Key(0, True, 0, False).encode()))   # mac 'a' -> KEY_A
    assert inj.events[-1] == ("key", 30, True)
    cm.on_message("mac", msg(p.MsgType.SCROLL, p.Scroll(0, 3, False).encode()))
    assert inj.events[-1] == ("scroll", 0, 3)


def test_pointer_pushed_back_through_return_edge_releases_control():
    cm, inj, sent = make()
    cm.on_message("mac", msg(p.MsgType.ENTER_CONTROL, p.Control(p.Edge.RIGHT, 0.5).encode()))
    for _ in range(3):
        cm.on_message("mac", msg(p.MsgType.MOUSE_MOVE, p.MouseMove(-20, 0).encode()))
    assert cm.state.kind == "local"
    release = [x for x in sent if x[1] == p.MsgType.RELEASE_CONTROL][-1]
    assert p.Control.decode(release[2]).edge == p.Edge.LEFT
    assert ("release_all",) in inj.events


def test_input_ignored_unless_controlled_by_that_peer_or_disabled():
    cm, inj, sent = make()
    cm.on_message("mac", msg(p.MsgType.MOUSE_BUTTON, p.MouseButton(0, True, 1).encode()))
    assert inj.events == []
    cm.enabled = False
    cm.on_message("mac", msg(p.MsgType.ENTER_CONTROL, p.Control(p.Edge.RIGHT, 0.5).encode()))
    assert cm.state.kind == "local" and sent[-1][1] == p.MsgType.RELEASE_CONTROL
    cm.enabled = True
    cm.on_message("mac", msg(p.MsgType.ENTER_CONTROL, p.Control(p.Edge.RIGHT, 0.5).encode()))
    cm.on_message("other", msg(p.MsgType.MOUSE_BUTTON, p.MouseButton(0, True, 1).encode()))
    assert ("button", 0x110, True) not in inj.events


def test_release_from_mac_returns_pointer_to_the_right_edge_and_ungrabs():
    cm, inj, sent = make()
    cm.edge_peers = {p.Edge.RIGHT: "mac"}
    grabs = []
    cm.on_grab = grabs.append
    cm.begin_controlling("mac", p.Edge.RIGHT, 0.5)
    cm.on_message("mac", msg(p.MsgType.RELEASE_CONTROL, p.Control(p.Edge.LEFT, 0.25).encode()))
    assert cm.state.kind == "local" and grabs == [True, False]
    x, y = inj.events[-1][1:]
    assert x > 0.99 and abs(y - 0.25) < 0.01


def test_disconnect_never_leaves_devices_grabbed_or_keys_stuck():
    cm, inj, sent = make()
    cm.edge_peers = {p.Edge.RIGHT: "mac"}
    grabs = []
    cm.on_grab = grabs.append
    cm.begin_controlling("mac", p.Edge.RIGHT, 0.5)
    cm.peer_disconnected("mac")
    assert cm.state.kind == "local" and grabs[-1] is False
    cm.on_message("mac", msg(p.MsgType.ENTER_CONTROL, p.Control(p.Edge.RIGHT, 0.5).encode()))
    cm.peer_disconnected("mac")
    assert ("release_all",) in inj.events and cm.state.kind == "local"


def test_hotkey_toggle_round_trip():
    cm, inj, sent = make()
    cm.edge_peers = {p.Edge.LEFT: "mac"}
    cm.toggle()
    assert cm.state.kind == "controlling"
    cm.toggle()
    assert cm.state.kind == "local" and sent[-1][1] == p.MsgType.RELEASE_CONTROL


def test_modifier_translation_and_swap():
    assert mac_to_linux(55) == 29 and mac_to_linux(55, swap_modifiers=False) == 125   # Cmd -> Ctrl (or Super)
    assert linux_to_mac(29) == 55 and linux_to_mac(30) == 0
    t = ModifierTracker()
    assert t.update(55, FLAG_COMMAND) is True and t.update(55, 0) is False
    assert t.update(55, FLAG_COMMAND) is True and t.update(54, FLAG_COMMAND) is True
    assert t.update(55, FLAG_COMMAND) is False        # left released, right still holds the bit
    f = FlagState()
    assert f.update(55, True) & FLAG_COMMAND and not f.update(55, False) & FLAG_COMMAND


def test_edge_geometry_and_screen_parsers():
    assert edge_point(p.Edge.LEFT, 0.5, SIZE, 2)[0] == 2 and edge_point(p.Edge.RIGHT, 0, SIZE, 2)[0] == 997
    d = EdgeDetector(10)
    assert d.update((500, 400), (5, 0), SIZE, {p.Edge.RIGHT}) is None
    assert parse_xrandr("Screen 0: minimum 320 x 200, current 2560 x 1440, maximum 16384 x 16384") == (2560, 1440)
    assert parse_drm_mode("1920x1080\n1280x720\n") == (1920, 1080) and parse_drm_mode("") is None
