using MacLinker.Core;
using static MacLinker.Windows.NativeMethods;

namespace MacLinker.Windows;

/// <summary>Injects mouse and keyboard input with SendInput. Keys go in by scan code, so they work in any keyboard layout.</summary>
internal sealed class WindowsInjector : IInputInjector
{
    private readonly HashSet<MouseButtonKind> _buttonsDown = new();
    private readonly HashSet<ScanKey> _keysDown = new();
    private readonly object _lock = new();

    private static void Send(INPUT input) => SendInput(1, new[] { input }, System.Runtime.InteropServices.Marshal.SizeOf<INPUT>());

    private static INPUT Mouse(uint flags, int dx = 0, int dy = 0, uint data = 0) => new()
    {
        type = INPUT_MOUSE,
        U = new InputUnion { mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = data, dwFlags = flags, dwExtraInfo = InjectedMarker } },
    };

    public void MoveAbs(double xFrac, double yFrac)
    {
        // Absolute coordinates are 0..65535 across the whole virtual desktop, whatever the monitor layout.
        var x = (int)Math.Round(Math.Clamp(xFrac, 0, 1) * 65535);
        var y = (int)Math.Round(Math.Clamp(yFrac, 0, 1) * 65535);
        Send(Mouse(MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, x, y));
    }

    public void Button(MouseButtonKind button, bool down)
    {
        lock (_lock) { if (down) _buttonsDown.Add(button); else _buttonsDown.Remove(button); }
        var (flag, data) = button switch
        {
            MouseButtonKind.Left => (down ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP, 0u),
            MouseButtonKind.Right => (down ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP, 0u),
            MouseButtonKind.Middle => (down ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP, 0u),
            MouseButtonKind.X1 => (down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, XBUTTON1),
            _ => (down ? MOUSEEVENTF_XDOWN : MOUSEEVENTF_XUP, XBUTTON2),
        };
        Send(Mouse(flag, data: data));
    }

    public void Scroll(int dxNotches, int dyNotches)
    {
        if (dyNotches != 0) Send(Mouse(MOUSEEVENTF_WHEEL, data: unchecked((uint)(dyNotches * 120))));
        if (dxNotches != 0) Send(Mouse(MOUSEEVENTF_HWHEEL, data: unchecked((uint)(dxNotches * 120))));
    }

    public void Key(ScanKey key, bool down)
    {
        lock (_lock) { if (down) _keysDown.Add(key); else _keysDown.Remove(key); }
        var flags = KEYEVENTF_SCANCODE | (key.Extended ? KEYEVENTF_EXTENDEDKEY : 0) | (down ? 0 : KEYEVENTF_KEYUP);
        Send(new INPUT
        {
            type = INPUT_KEYBOARD,
            U = new InputUnion { ki = new KEYBDINPUT { wScan = key.Scan, dwFlags = flags, dwExtraInfo = InjectedMarker } },
        });
    }

    /// <summary>Releases anything still held so a dropped connection can't leave a stuck key or button.</summary>
    public void ReleaseAll()
    {
        MouseButtonKind[] buttons;
        ScanKey[] keys;
        lock (_lock) { buttons = _buttonsDown.ToArray(); keys = _keysDown.ToArray(); }
        foreach (var b in buttons) Button(b, false);
        foreach (var k in keys) Key(k, false);
    }

    /// <summary>The virtual desktop: all monitors together. Origin can be negative when a monitor sits left of or above the primary.</summary>
    public static (int X, int Y, int Width, int Height) VirtualScreen() =>
        (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
         Math.Max(GetSystemMetrics(SM_CXVIRTUALSCREEN), 1), Math.Max(GetSystemMetrics(SM_CYVIRTUALSCREEN), 1));
}
