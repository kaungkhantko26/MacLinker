namespace MacLinker.Core;

/// <summary>A physical key as Windows sees it: a Set-1 scan code plus whether it is an "extended" (E0-prefixed) key.</summary>
public readonly record struct ScanKey(ushort Scan, bool Extended);

/// <summary>Translation between macOS virtual key codes and Windows scan codes.</summary>
public static class Keymap
{
    // macOS virtual key code -> Windows scan code (ANSI layout, plus common extras).
    private static readonly Dictionary<ushort, ScanKey> MacToWin = new()
    {
        [0] = new(0x1E, false), [1] = new(0x1F, false), [2] = new(0x20, false), [3] = new(0x21, false), [4] = new(0x23, false),
        [5] = new(0x22, false), [6] = new(0x2C, false), [7] = new(0x2D, false), [8] = new(0x2E, false), [9] = new(0x2F, false),
        [10] = new(0x56, false), [11] = new(0x30, false), [12] = new(0x10, false), [13] = new(0x11, false), [14] = new(0x12, false),
        [15] = new(0x13, false), [16] = new(0x15, false), [17] = new(0x14, false), [18] = new(0x02, false), [19] = new(0x03, false),
        [20] = new(0x04, false), [21] = new(0x05, false), [22] = new(0x07, false), [23] = new(0x06, false), [24] = new(0x0D, false),
        [25] = new(0x0A, false), [26] = new(0x08, false), [27] = new(0x0C, false), [28] = new(0x09, false), [29] = new(0x0B, false),
        [30] = new(0x1B, false), [31] = new(0x18, false), [32] = new(0x16, false), [33] = new(0x1A, false), [34] = new(0x17, false),
        [35] = new(0x19, false), [36] = new(0x1C, false), [37] = new(0x26, false), [38] = new(0x24, false), [39] = new(0x28, false),
        [40] = new(0x25, false), [41] = new(0x27, false), [42] = new(0x2B, false), [43] = new(0x33, false), [44] = new(0x35, false),
        [45] = new(0x31, false), [46] = new(0x32, false), [47] = new(0x34, false), [48] = new(0x0F, false), [49] = new(0x39, false),
        [50] = new(0x29, false), [51] = new(0x0E, false), [53] = new(0x01, false),
        // modifiers
        // Unswapped, each key keeps its own meaning: Command is the Windows key, Control is Ctrl.
        [54] = new(0x5C, true), [55] = new(0x5B, true), [56] = new(0x2A, false), [57] = new(0x3A, false), [58] = new(0x38, false),
        [59] = new(0x1D, false), [60] = new(0x36, false), [61] = new(0x38, true), [62] = new(0x1D, true),
        // keypad
        [65] = new(0x53, false), [67] = new(0x37, false), [69] = new(0x4E, false), [75] = new(0x35, true), [76] = new(0x1C, true),
        [78] = new(0x4A, false), [82] = new(0x52, false), [83] = new(0x4F, false), [84] = new(0x50, false), [85] = new(0x51, false),
        [86] = new(0x4B, false), [87] = new(0x4C, false), [88] = new(0x4D, false), [89] = new(0x47, false), [91] = new(0x48, false),
        [92] = new(0x49, false),
        // function keys
        [122] = new(0x3B, false), [120] = new(0x3C, false), [99] = new(0x3D, false), [118] = new(0x3E, false), [96] = new(0x3F, false),
        [97] = new(0x40, false), [98] = new(0x41, false), [100] = new(0x42, false), [101] = new(0x43, false), [109] = new(0x44, false),
        [103] = new(0x57, false), [111] = new(0x58, false), [105] = new(0x64, false), [107] = new(0x65, false), [113] = new(0x66, false),
        [106] = new(0x67, false), [64] = new(0x68, false), [79] = new(0x69, false), [80] = new(0x6A, false), [90] = new(0x6B, false),
        // navigation
        [114] = new(0x52, true), [115] = new(0x47, true), [116] = new(0x49, true), [117] = new(0x53, true), [119] = new(0x4F, true),
        [121] = new(0x51, true), [123] = new(0x4B, true), [124] = new(0x4D, true), [125] = new(0x50, true), [126] = new(0x48, true),
        // media
        [72] = new(0x30, true), [73] = new(0x2E, true), [74] = new(0x20, true),
    };

    private static readonly Dictionary<ScanKey, ushort> WinToMac = MacToWin.ToDictionary(kv => kv.Value, kv => kv.Key);

    // "Mac-style" shortcuts on Windows: Command works like Ctrl, Option like Alt, Control like the Windows key.
    private static readonly Dictionary<ushort, ScanKey> SwappedMacToWin = new()
    {
        [55] = new(0x1D, false), [54] = new(0x1D, true),   // Command -> Ctrl
        [59] = new(0x5B, true), [62] = new(0x5C, true),    // Control -> Windows key
        [58] = new(0x38, false), [61] = new(0x38, true),   // Option  -> Alt
    };

    private static readonly Dictionary<ScanKey, ushort> SwappedWinToMac = SwappedMacToWin.ToDictionary(kv => kv.Value, kv => kv.Key);

    public static ScanKey? MacToWindows(ushort macCode, bool swapModifiers = true)
    {
        if (swapModifiers && SwappedMacToWin.TryGetValue(macCode, out var swapped)) return swapped;
        return MacToWin.TryGetValue(macCode, out var k) ? k : null;
    }

    public static ushort? WindowsToMac(ScanKey key, bool swapModifiers = true)
    {
        if (swapModifiers && SwappedWinToMac.TryGetValue(key, out var swapped)) return swapped;
        return WinToMac.TryGetValue(key, out var m) ? m : null;
    }

    // CGEventFlags bits.
    public const ulong FlagCaps = 0x10000, FlagShift = 0x20000, FlagControl = 0x40000, FlagOption = 0x80000, FlagCommand = 0x100000, FlagFn = 0x800000;

    private static readonly Dictionary<ushort, ulong> ModifierBit = new()
    {
        [55] = FlagCommand, [54] = FlagCommand, [56] = FlagShift, [60] = FlagShift, [58] = FlagOption, [61] = FlagOption,
        [59] = FlagControl, [62] = FlagControl, [57] = FlagCaps, [63] = FlagFn,
    };

    private static readonly Dictionary<ushort, ushort> Twin = new()
    {
        [55] = 54, [54] = 55, [56] = 60, [60] = 56, [58] = 61, [61] = 58, [59] = 62, [62] = 59,
    };

    public static bool IsMacModifier(ushort code) => ModifierBit.ContainsKey(code);

    /// <summary>Mac to Windows: turns flagsChanged (a code plus the full flag set) into press/release of a modifier key.</summary>
    public sealed class ModifierTracker
    {
        private readonly HashSet<ushort> _down = new();

        /// <summary>True = press, false = release, null = not a modifier.</summary>
        public bool? Update(ushort macCode, ulong flags)
        {
            if (!ModifierBit.TryGetValue(macCode, out var bit)) return null;
            Twin.TryGetValue(macCode, out var twin);
            if ((flags & bit) == 0)
            {
                _down.Remove(macCode);
                if (twin != 0) _down.Remove(twin);
                return false;
            }
            if (_down.Contains(macCode)) { _down.Remove(macCode); return false; } // the other side still holds the bit
            _down.Add(macCode);
            return true;
        }
    }

    /// <summary>Windows to Mac: tracks the flags that go with every key event.</summary>
    public sealed class FlagState
    {
        private readonly HashSet<ushort> _held = new();
        public ulong Flags { get; private set; }

        public ulong Update(ushort macCode, bool down)
        {
            if (!ModifierBit.TryGetValue(macCode, out var bit)) return Flags;
            if (macCode == 57) { if (down) Flags ^= bit; return Flags; } // caps lock toggles
            if (down) _held.Add(macCode); else _held.Remove(macCode);
            var still = _held.Any(c => ModifierBit[c] == bit);
            Flags = still ? Flags | bit : Flags & ~bit;
            return Flags;
        }
    }
}
