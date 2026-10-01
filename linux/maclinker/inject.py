"""Injects pointer, button, wheel and key events through the kernel's uinput (works on X11 and Wayland)."""
from __future__ import annotations

import logging
from typing import Set

from .keymap import LINUX_MODIFIERS, MAC_TO_LINUX

log = logging.getLogger("maclinker.inject")
ABS_MAX = 32767


class InjectorUnavailable(Exception):
    pass


class UInputInjector:
    """Two virtual devices: a keyboard, and an absolute pointer (like a virtual tablet).

    The pointer is absolute on purpose: positions are computed from our own tracked cursor, so there
    is no pointer-acceleration mismatch between the two machines, and "warp to this edge" is exact.
    Needs write access to /dev/uinput (see deploy/99-maclinker.rules).
    """

    def __init__(self) -> None:
        try:
            from evdev import AbsInfo, UInput, ecodes as e
        except ImportError as err:
            raise InjectorUnavailable("python-evdev is not installed (pip install evdev)") from err
        self._e = e
        keys = sorted(set(MAC_TO_LINUX.values()) | LINUX_MODIFIERS | {57})
        try:
            self._keyboard = UInput({e.EV_KEY: keys}, name="maclinker-keyboard")
            self._pointer = UInput({
                e.EV_KEY: [e.BTN_LEFT, e.BTN_RIGHT, e.BTN_MIDDLE, e.BTN_SIDE, e.BTN_EXTRA],
                e.EV_ABS: [(e.ABS_X, AbsInfo(0, 0, ABS_MAX, 0, 0, 0)), (e.ABS_Y, AbsInfo(0, 0, ABS_MAX, 0, 0, 0))],
                e.EV_REL: [e.REL_WHEEL, e.REL_HWHEEL, e.REL_WHEEL_HI_RES, e.REL_HWHEEL_HI_RES],
            }, name="maclinker-pointer")
        except (PermissionError, OSError) as err:
            raise InjectorUnavailable(f"cannot open /dev/uinput ({err}). Run `maclinker setup` for the fix.") from err
        self._down_keys: Set[int] = set()
        self._down_buttons: Set[int] = set()

    def move_abs(self, x_frac: float, y_frac: float) -> None:
        e = self._e
        self._pointer.write(e.EV_ABS, e.ABS_X, int(min(max(x_frac, 0.0), 1.0) * ABS_MAX))
        self._pointer.write(e.EV_ABS, e.ABS_Y, int(min(max(y_frac, 0.0), 1.0) * ABS_MAX))
        self._pointer.syn()

    def button(self, code: int, down: bool) -> None:
        (self._down_buttons.add if down else self._down_buttons.discard)(code)
        self._pointer.write(self._e.EV_KEY, code, 1 if down else 0)
        self._pointer.syn()

    def scroll(self, dx_lines: float, dy_lines: float) -> None:
        e = self._e
        if dy_lines:
            self._pointer.write(e.EV_REL, e.REL_WHEEL, int(dy_lines))
            self._pointer.write(e.EV_REL, e.REL_WHEEL_HI_RES, int(dy_lines) * 120)
        if dx_lines:
            self._pointer.write(e.EV_REL, e.REL_HWHEEL, int(dx_lines))
            self._pointer.write(e.EV_REL, e.REL_HWHEEL_HI_RES, int(dx_lines) * 120)
        self._pointer.syn()

    def key(self, code: int, down: bool) -> None:
        (self._down_keys.add if down else self._down_keys.discard)(code)
        self._keyboard.write(self._e.EV_KEY, code, 1 if down else 0)
        self._keyboard.syn()

    def release_all(self) -> None:
        """Release anything still held so a dropped connection can't leave a stuck key or button."""
        for code in list(self._down_buttons):
            self.button(code, False)
        for code in list(self._down_keys):
            self.key(code, False)
        # Also clear modifiers the compositor may still think are held from a grabbed physical keyboard.
        for code in LINUX_MODIFIERS | {57}:
            self._keyboard.write(self._e.EV_KEY, code, 0)
        self._keyboard.syn()

    def close(self) -> None:
        for dev in (self._keyboard, self._pointer):
            try:
                dev.close()
            except OSError:
                pass


class NullInjector:
    """Used when uinput isn't available: the machine can still control peers, just not be controlled."""

    def move_abs(self, x_frac: float, y_frac: float) -> None: ...
    def button(self, code: int, down: bool) -> None: ...
    def scroll(self, dx_lines: float, dy_lines: float) -> None: ...
    def key(self, code: int, down: bool) -> None: ...
    def release_all(self) -> None: ...
