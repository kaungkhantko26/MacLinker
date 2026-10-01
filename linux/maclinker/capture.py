"""Reads this machine's keyboards and mice (evdev) so they can drive a peer.

Not grabbed (normal use): a passive read, only to notice the edge push or the hotkey.
Grabbed (controlling a peer): the devices are grabbed exclusively, so nothing reaches this machine's
desktop, and every event is forwarded.
Hotkey (always available, and the only way to switch on Wayland where the pointer position can't be
read): Ctrl+Alt+Shift+Space toggles control of the first positioned peer.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import Dict, List, Optional, Tuple

from . import control as ctl
from .keymap import FlagState, LINUX_MODIFIERS, linux_to_mac, MAC_MODIFIER_BIT
from .protocol import Key, MouseButton, MsgType, Scroll

log = logging.getLogger("maclinker.capture")

KEY_SPACE, KEY_LCTRL, KEY_RCTRL, KEY_LALT, KEY_RALT, KEY_LSHIFT, KEY_RSHIFT = 57, 29, 97, 56, 100, 42, 54
HOTKEY_MODS = ({KEY_LCTRL, KEY_RCTRL}, {KEY_LALT, KEY_RALT}, {KEY_LSHIFT, KEY_RSHIFT})
BTN_TO_MAC = {0x110: 0, 0x111: 1, 0x112: 2, 0x113: 3, 0x114: 4}


class X11Probe:
    """Real pointer position, available on X11 sessions (not Wayland)."""

    def __init__(self) -> None:
        from Xlib import display  # python-xlib, optional
        self._root = display.Display().screen().root

    def position(self) -> Tuple[float, float]:
        q = self._root.query_pointer()
        return float(q.root_x), float(q.root_y)


def make_probe() -> Optional[X11Probe]:
    if os.environ.get("XDG_SESSION_TYPE") == "wayland" or not os.environ.get("DISPLAY"):
        return None
    try:
        return X11Probe()
    except Exception as e:  # noqa: BLE001
        log.info("no X11 pointer probe (%s); edge crossing from this machine uses the hotkey", e)
        return None


class Capture:
    def __init__(self, control: ctl.ControlManager, loop: asyncio.AbstractEventLoop,
                 swap_modifiers: bool = True, mouse_speed: float = 1.0, touchpad_scale: float = 1.5) -> None:
        try:
            import evdev  # noqa: F401
        except ImportError as e:
            raise RuntimeError("python-evdev is not installed") from e
        self.control, self.loop = control, loop
        self.swap_modifiers, self.mouse_speed, self.touchpad_scale = swap_modifiers, mouse_speed, touchpad_scale
        self.probe = make_probe()
        self._devices: Dict[str, object] = {}
        self._grabbed = False
        self._mods_down: set = set()
        self._flags = FlagState()
        self._rel = [0.0, 0.0]
        self._last_click: Dict[int, Tuple[float, int]] = {}
        self._touch: Dict[str, List[Optional[float]]] = {}
        control.on_grab = self.set_grab
        self._scan_task: Optional[asyncio.Task] = None

    # ---- devices -------------------------------------------------------------------------------

    def start(self) -> None:
        self._scan()
        self._scan_task = self.loop.create_task(self._rescan_forever())

    async def _rescan_forever(self) -> None:
        while True:
            await asyncio.sleep(5)
            self._scan()

    def _scan(self) -> None:
        from evdev import InputDevice, ecodes as e, list_devices
        for path in list_devices():
            if path in self._devices:
                continue
            try:
                dev = InputDevice(path)
                caps = dev.capabilities()
                if dev.name.startswith("maclinker"):
                    dev.close()
                    continue
                keys = caps.get(e.EV_KEY, [])
                is_keyboard = e.KEY_A in keys and e.KEY_SPACE in keys
                is_mouse = e.EV_REL in caps and e.REL_X in caps[e.EV_REL] and e.BTN_LEFT in keys
                is_touchpad = e.EV_ABS in caps and e.BTN_TOOL_FINGER in keys and e.BTN_LEFT in keys
                if not (is_keyboard or is_mouse or is_touchpad):
                    dev.close()
                    continue
                os.set_blocking(dev.fd, False)
                self.loop.add_reader(dev.fd, self._on_readable, dev)
                self._devices[path] = dev
                if self._grabbed:
                    dev.grab()
                log.info("capturing %s (%s)", dev.name, path)
            except (OSError, PermissionError) as err:
                log.debug("skip %s: %s", path, err)

    def set_grab(self, grabbed: bool) -> None:
        self._grabbed = grabbed
        for dev in list(self._devices.values()):
            try:
                dev.grab() if grabbed else dev.ungrab()
            except OSError as err:
                log.debug("grab(%s) failed: %s", grabbed, err)
        if not grabbed:
            self._flags = FlagState()
            self._mods_down.clear()
            # grabbed keys' releases never reached the desktop; clear any stuck modifier
            self.control.injector.release_all()

    def _on_readable(self, dev) -> None:
        from evdev import ecodes as e
        try:
            events = list(dev.read())
        except BlockingIOError:
            return
        except OSError:  # device unplugged
            self._remove(dev)
            return
        for ev in events:
            if ev.type == e.EV_REL:
                self._on_rel(ev)
            elif ev.type == e.EV_KEY:
                self._on_key(ev)
            elif ev.type == e.EV_ABS:
                self._on_abs(dev, ev)
            elif ev.type == e.EV_SYN and ev.code == e.SYN_REPORT:
                self._on_sync()

    def _remove(self, dev) -> None:
        self.loop.remove_reader(dev.fd)
        self._devices = {p: d for p, d in self._devices.items() if d is not dev}
        try:
            dev.close()
        except OSError:
            pass

    # ---- event handling ------------------------------------------------------------------------

    def _on_rel(self, ev) -> None:
        from evdev import ecodes as e
        if ev.code == e.REL_X:
            self._rel[0] += ev.value
        elif ev.code == e.REL_Y:
            self._rel[1] += ev.value
        elif self._grabbed and ev.code == e.REL_WHEEL:
            self.control.forward(MsgType.SCROLL, Scroll(0, ev.value, False).encode())
        elif self._grabbed and ev.code == e.REL_HWHEEL:
            self.control.forward(MsgType.SCROLL, Scroll(ev.value, 0, False).encode())

    def _on_sync(self) -> None:
        dx, dy = self._rel
        self._rel = [0.0, 0.0]
        if not (dx or dy):
            return
        if self._grabbed:
            self.control.forward_motion(dx * self.mouse_speed, dy * self.mouse_speed)
        elif self.probe is not None:
            self.control.local_pointer(self.probe.position(), (dx, dy))

    def _on_abs(self, dev, ev) -> None:
        """Touchpads report absolute finger positions; turn them into relative motion."""
        from evdev import ecodes as e
        if ev.code not in (e.ABS_X, e.ABS_Y):
            return
        last = self._touch.setdefault(dev.path, [None, None])
        i = 0 if ev.code == e.ABS_X else 1
        if last[i] is not None:
            self._rel[i] += (ev.value - last[i]) * self.touchpad_scale
        last[i] = ev.value

    def _on_key(self, ev) -> None:
        from evdev import ecodes as e
        code, value = ev.code, ev.value
        if code in HOTKEY_MODS[0] | HOTKEY_MODS[1] | HOTKEY_MODS[2]:
            (self._mods_down.add if value else self._mods_down.discard)(code)
        if code == KEY_SPACE and value == 1 and all(self._mods_down & group for group in HOTKEY_MODS):
            self.control.toggle()
            return
        if code in BTN_TO_MAC:
            if not self._grabbed:
                self._touch_reset()
                return
            down = value != 0
            count = self._click_count(code, down)
            self.control.forward(MsgType.MOUSE_BUTTON, MouseButton(BTN_TO_MAC[code], down, count).encode())
            return
        if code == e.BTN_TOUCH or code == e.BTN_TOOL_FINGER:
            self._touch_reset()
            return
        if not self._grabbed:
            return
        mac = linux_to_mac(code, self.swap_modifiers)
        if mac is None:
            return
        if code in LINUX_MODIFIERS and mac in MAC_MODIFIER_BIT:
            flags = self._flags.update(mac, value != 0)
            if value != 2:
                self.control.forward(MsgType.FLAGS_CHANGED, Key(mac, True, flags, False).encode())
        else:
            self.control.forward(MsgType.KEY_EVENT,
                                 Key(mac, value != 0, self._flags.flags, value == 2).encode())

    def _touch_reset(self) -> None:
        for v in self._touch.values():
            v[0] = v[1] = None

    def _click_count(self, code: int, down: bool) -> int:
        now = time.monotonic()
        last_t, count = self._last_click.get(code, (0.0, 0))
        if down:
            count = count + 1 if now - last_t < 0.4 else 1
            self._last_click[code] = (now, count)
        return count if down else max(self._last_click.get(code, (0, 1))[1], 1)
