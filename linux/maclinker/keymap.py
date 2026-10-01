"""Key translation between macOS virtual key codes and Linux evdev key codes."""
from __future__ import annotations

from typing import Dict, Optional

# macOS virtual key code -> Linux evdev KEY_* code (ANSI layout plus common extras).
MAC_TO_LINUX: Dict[int, int] = {
    0: 30, 1: 31, 2: 32, 3: 33, 4: 35, 5: 34, 6: 44, 7: 45, 8: 46, 9: 47, 10: 86, 11: 48,
    12: 16, 13: 17, 14: 18, 15: 19, 16: 21, 17: 20, 18: 2, 19: 3, 20: 4, 21: 5, 22: 7, 23: 6,
    24: 13, 25: 10, 26: 8, 27: 12, 28: 9, 29: 11, 30: 27, 31: 24, 32: 22, 33: 26, 34: 23, 35: 25,
    36: 28, 37: 38, 38: 36, 39: 40, 40: 37, 41: 39, 42: 43, 43: 51, 44: 53, 45: 49, 46: 50, 47: 52,
    48: 15, 49: 57, 50: 41, 51: 14, 53: 1,
    54: 126, 55: 125, 56: 42, 57: 58, 58: 56, 59: 29, 60: 54, 61: 100, 62: 97,
    # keypad
    65: 83, 67: 55, 69: 78, 75: 98, 76: 96, 78: 74, 81: 117,
    82: 82, 83: 79, 84: 80, 85: 81, 86: 75, 87: 76, 88: 77, 89: 71, 91: 72, 92: 73,
    # function keys
    122: 59, 120: 60, 99: 61, 118: 62, 96: 63, 97: 64, 98: 65, 100: 66, 101: 67, 109: 68, 103: 87, 111: 88,
    105: 183, 107: 184, 113: 185, 106: 186, 64: 187, 79: 188, 80: 189, 90: 190,
    # navigation
    114: 110, 115: 102, 116: 104, 117: 111, 119: 107, 121: 109, 123: 105, 124: 106, 125: 108, 126: 103,
    # media
    72: 115, 73: 114, 74: 113,
}
LINUX_TO_MAC: Dict[int, int] = {v: k for k, v in MAC_TO_LINUX.items()}

# macOS modifier key codes and the CGEventFlags bit each one controls.
FLAG_CAPS = 0x10000
FLAG_SHIFT = 0x20000
FLAG_CONTROL = 0x40000
FLAG_OPTION = 0x80000
FLAG_COMMAND = 0x100000
FLAG_FN = 0x800000

MAC_MODIFIER_BIT: Dict[int, int] = {
    55: FLAG_COMMAND, 54: FLAG_COMMAND, 56: FLAG_SHIFT, 60: FLAG_SHIFT,
    58: FLAG_OPTION, 61: FLAG_OPTION, 59: FLAG_CONTROL, 62: FLAG_CONTROL, 57: FLAG_CAPS, 63: FLAG_FN,
}
# Mac modifier code -> its left/right twin
MAC_MODIFIER_TWIN = {55: 54, 54: 55, 56: 60, 60: 56, 58: 61, 61: 58, 59: 62, 62: 59}

# Linux modifier codes (left/right).
LINUX_MODIFIERS = {42, 54, 29, 97, 56, 100, 125, 126, 58}

# "Mac-style" shortcuts on Linux: Command works like Ctrl, Option like Alt, Control like Super.
_SWAP_MAC_TO_LINUX = {55: 29, 54: 97, 59: 125, 62: 126, 58: 56, 61: 100}
_SWAP_LINUX_TO_MAC = {29: 55, 97: 54, 125: 59, 126: 62, 56: 58, 100: 61}


def mac_to_linux(code: int, swap_modifiers: bool = True) -> Optional[int]:
    if swap_modifiers and code in _SWAP_MAC_TO_LINUX:
        return _SWAP_MAC_TO_LINUX[code]
    return MAC_TO_LINUX.get(code)


def linux_to_mac(code: int, swap_modifiers: bool = True) -> Optional[int]:
    if swap_modifiers and code in _SWAP_LINUX_TO_MAC:
        return _SWAP_LINUX_TO_MAC[code]
    return LINUX_TO_MAC.get(code)


class ModifierTracker:
    """Mac->Linux: turns flagsChanged (which carries only a code and the full flag set) into key presses."""

    def __init__(self) -> None:
        self.down: set[int] = set()

    def update(self, mac_code: int, flags: int) -> Optional[bool]:
        """Returns True for press, False for release, None if this isn't a modifier we track."""
        bit = MAC_MODIFIER_BIT.get(mac_code)
        if bit is None:
            return None
        twin = MAC_MODIFIER_TWIN.get(mac_code)
        if not flags & bit:
            self.down.discard(mac_code)
            if twin is not None:
                self.down.discard(twin)
            return False
        if mac_code in self.down:      # the other side is still held; this is a release of this one
            self.down.discard(mac_code)
            return False
        self.down.add(mac_code)
        return True


class FlagState:
    """Linux->Mac: keeps the CGEventFlags that go with every key event."""

    def __init__(self) -> None:
        self.flags = 0
        self._held: set[int] = set()

    def update(self, mac_code: int, down: bool) -> int:
        bit = MAC_MODIFIER_BIT.get(mac_code)
        if bit is None:
            return self.flags
        if mac_code == 57:  # caps lock toggles
            if down:
                self.flags ^= bit
            return self.flags
        (self._held.add if down else self._held.discard)(mac_code)
        still = any(MAC_MODIFIER_BIT.get(c) == bit for c in self._held)
        self.flags = (self.flags | bit) if still else (self.flags & ~bit)
        return self.flags
