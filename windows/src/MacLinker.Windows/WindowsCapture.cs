using System.Runtime.InteropServices;
using MacLinker.Core;
using static MacLinker.Windows.NativeMethods;
using Message = System.Windows.Forms.Message;

namespace MacLinker.Windows;

/// <summary>
/// Watches this PC's keyboard and mouse. Normally it only notices: the pointer reaching a screen edge, or the hotkey.
/// While a Mac is being controlled it swallows everything (so nothing reaches Windows), freezes and hides the pointer, and
/// the events go to the Mac instead.
///
/// Movement comes from Raw Input (relative device counts), because a pointer pinned at a screen edge stops producing
/// position changes; swallowing and button/key/wheel events come from low-level hooks.
/// Runs on its own thread with its own message loop, as hooks require.
/// </summary>
internal sealed class WindowsCapture : IDisposable
{
    private readonly ControlManager _control;
    private readonly Func<double> _mouseSpeed;
    private readonly HookProc _keyboardProc, _mouseProc;     // kept in fields so the garbage collector can't free them
    private readonly HashSet<ScanKey> _down = new();
    private Thread? _thread;
    private uint _threadId;
    private IntPtr _keyboardHook, _mouseHook;
    private RawInputWindow? _window;
    private volatile bool _grabbed;
    private readonly BlankCursor _blank = new();
    private (int X, int Y, int W, int H) _desktop;

    public WindowsCapture(ControlManager control, Func<double> mouseSpeed)
    {
        _control = control;
        _mouseSpeed = mouseSpeed;
        _keyboardProc = KeyboardProc;
        _mouseProc = MouseProc;
        _control.GrabChanged += OnGrab;
    }

    public void Start()
    {
        var ready = new ManualResetEventSlim();
        _thread = new Thread(() =>
        {
            _threadId = GetCurrentThreadId();
            var module = GetModuleHandle(null);
            _keyboardHook = SetWindowsHookEx(WH_KEYBOARD_LL, _keyboardProc, module, 0);
            _mouseHook = SetWindowsHookEx(WH_MOUSE_LL, _mouseProc, module, 0);
            _window = new RawInputWindow(OnRawMouse);
            ready.Set();
            while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
            if (_keyboardHook != IntPtr.Zero) UnhookWindowsHookEx(_keyboardHook);
            if (_mouseHook != IntPtr.Zero) UnhookWindowsHookEx(_mouseHook);
            _window?.DestroyHandle();
        }) { IsBackground = true, Name = "MacLinker input", Priority = ThreadPriority.Highest };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        ready.Wait(TimeSpan.FromSeconds(5));
        BlankCursor.RestoreSystemCursors();      // in case an earlier run ended while the pointer was hidden
    }

    public void Dispose()
    {
        _control.GrabChanged -= OnGrab;
        OnGrab(false);
        if (_threadId != 0) PostThreadMessage(_threadId, WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
        _thread?.Join(1000);
    }

    // ---- hand over / take back -------------------------------------------------------------------------

    private void OnGrab(bool grabbed)
    {
        _grabbed = grabbed;
        if (grabbed)
        {
            GetCursorPos(out var p);
            var rect = new RECT { Left = p.X, Top = p.Y, Right = p.X + 1, Bottom = p.Y + 1 };
            ClipCursor(ref rect);               // freeze the pointer where it is
            _blank.Hide();
        }
        else
        {
            ClipCursorRelease(IntPtr.Zero);
            _blank.Show();
            lock (_down) _down.Clear();
        }
    }

    // ---- hooks -----------------------------------------------------------------------------------------

    private IntPtr KeyboardProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0) return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        var k = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
        if (k.dwExtraInfo == InjectedMarker) return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        var down = (k.flags & LLKHF_UP) == 0;
        var key = new ScanKey((ushort)k.scanCode, (k.flags & LLKHF_EXTENDED) != 0);
        bool repeat;
        lock (_down) repeat = down ? !_down.Add(key) : _down.Remove(key) && false;
        var swallow = _control.OnLocalKey(key, down, repeat);
        return swallow ? (IntPtr)1 : CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    private IntPtr MouseProc(int code, IntPtr wParam, IntPtr lParam)
    {
        if (code < 0) return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        var m = Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam);
        if (m.dwExtraInfo == InjectedMarker) return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
        var swallow = false;
        switch ((int)wParam)
        {
            case WM_MOUSEMOVE: swallow = _grabbed; break;     // movement itself is read from Raw Input
            case WM_LBUTTONDOWN: swallow = _control.OnLocalButton(MouseButtonKind.Left, true); break;
            case WM_LBUTTONUP: swallow = _control.OnLocalButton(MouseButtonKind.Left, false); break;
            case WM_RBUTTONDOWN: swallow = _control.OnLocalButton(MouseButtonKind.Right, true); break;
            case WM_RBUTTONUP: swallow = _control.OnLocalButton(MouseButtonKind.Right, false); break;
            case WM_MBUTTONDOWN: swallow = _control.OnLocalButton(MouseButtonKind.Middle, true); break;
            case WM_MBUTTONUP: swallow = _control.OnLocalButton(MouseButtonKind.Middle, false); break;
            case WM_XBUTTONDOWN:
            case WM_XBUTTONUP:
                var x2 = ((m.mouseData >> 16) & 0xFFFF) == XBUTTON2;
                swallow = _control.OnLocalButton(x2 ? MouseButtonKind.X2 : MouseButtonKind.X1, (int)wParam == WM_XBUTTONDOWN);
                break;
            case WM_MOUSEWHEEL:
                swallow = _control.OnLocalScroll(0, (short)((m.mouseData >> 16) & 0xFFFF) / 120);
                break;
            case WM_MOUSEHWHEEL:
                swallow = _control.OnLocalScroll((short)((m.mouseData >> 16) & 0xFFFF) / 120, 0);
                break;
        }
        return swallow ? (IntPtr)1 : CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }

    // ---- raw movement ----------------------------------------------------------------------------------

    private void OnRawMouse(int dx, int dy)
    {
        if (dx == 0 && dy == 0) return;
        GetCursorPos(out var p);
        if ((DateTime.UtcNow - _lastDesktopRead).TotalSeconds > 5) { _desktop = (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN)); _lastDesktopRead = DateTime.UtcNow; }
        var speed = _mouseSpeed();
        _control.OnLocalMotion((p.X - _desktop.X, p.Y - _desktop.Y), dx * speed, dy * speed);
    }

    private DateTime _lastDesktopRead = DateTime.MinValue;

    /// <summary>A message-only window that receives WM_INPUT for the mouse.</summary>
    private sealed class RawInputWindow : NativeWindow
    {
        private readonly Action<int, int> _onMove;

        public RawInputWindow(Action<int, int> onMove)
        {
            _onMove = onMove;
            CreateHandle(new CreateParams { Parent = new IntPtr(-3) });   // HWND_MESSAGE
            var device = new RAWINPUTDEVICE { usUsagePage = 0x01, usUsage = 0x02, dwFlags = RIDEV_INPUTSINK, hwndTarget = Handle };
            RegisterRawInputDevices(new[] { device }, 1, (uint)Marshal.SizeOf<RAWINPUTDEVICE>());
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_INPUT) ReadRaw(m.LParam);
            base.WndProc(ref m);
        }

        private void ReadRaw(IntPtr handle)
        {
            uint size = 0;
            var headerSize = (uint)Marshal.SizeOf<RAWINPUTHEADER>();
            GetRawInputData(handle, RID_INPUT, IntPtr.Zero, ref size, headerSize);
            if (size == 0 || size > 1024) return;
            var buffer = Marshal.AllocHGlobal((int)size);
            try
            {
                if (GetRawInputData(handle, RID_INPUT, buffer, ref size, headerSize) != size) return;
                var header = Marshal.PtrToStructure<RAWINPUTHEADER>(buffer);
                if (header.dwType != RIM_TYPEMOUSE) return;
                var mouse = Marshal.PtrToStructure<RAWMOUSE>(buffer + (int)headerSize);
                if ((mouse.usFlags & MOUSE_MOVE_ABSOLUTE) == 0) _onMove(mouse.lLastX, mouse.lLastY);   // ignore tablets / remote desktop
            }
            finally { Marshal.FreeHGlobal(buffer); }
        }
    }
}

/// <summary>Hides the pointer system-wide by swapping every system cursor for a transparent one, then restores them.</summary>
internal sealed class BlankCursor
{
    private bool _hidden;

    public void Hide()
    {
        if (_hidden) return;
        _hidden = true;
        var and = Enumerable.Repeat((byte)0xFF, 128).ToArray();   // 32x32, 1 bit per pixel: AND all ones + XOR all zeros = transparent
        var xor = new byte[128];
        foreach (var id in CursorIds)
        {
            var blank = CreateCursor(IntPtr.Zero, 0, 0, 32, 32, and, xor);   // SetSystemCursor takes ownership, so one per id
            if (blank != IntPtr.Zero) SetSystemCursor(blank, id);
        }
    }

    public void Show()
    {
        if (!_hidden) return;
        _hidden = false;
        RestoreSystemCursors();
    }

    public static void RestoreSystemCursors() => SystemParametersInfo(SPI_SETCURSORS, 0, IntPtr.Zero, 0);
}
