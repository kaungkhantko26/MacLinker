namespace MacLinker.Core;

public enum MouseButtonKind { Left = 0, Right = 1, Middle = 2, X1 = 3, X2 = 4 }

/// <summary>Injects input into this PC. Implemented with SendInput on Windows and with a fake in tests.</summary>
public interface IInputInjector
{
    /// <summary>Moves the pointer to a position given as a fraction (0..1) of the whole virtual desktop.</summary>
    void MoveAbs(double xFrac, double yFrac);
    void Button(MouseButtonKind button, bool down);
    /// <summary>Wheel notches; positive is up / right.</summary>
    void Scroll(int dxNotches, int dyNotches);
    void Key(ScanKey key, bool down);
    void ReleaseAll();
}

public enum ControlKind { Local, Controlling, Controlled }

public sealed record ControlState(ControlKind Kind, string? Peer = null, Edge? Edge = null);

/// <summary>
/// Who is driving: this PC's own devices or a peer's.
/// Controlling: our pointer crossed an edge (or the hotkey was pressed); local input is swallowed and streamed to the peer.
/// Controlled: a peer is driving us; its input is injected, and pushing back against the edge it entered from hands control back.
/// Mouse movement is batched (~3 ms) so a 1000 Hz mouse doesn't flood the link.
/// </summary>
public sealed class ControlManager
{
    private readonly IInputInjector _injector;
    private readonly Func<string, MsgType, byte[], bool> _send;
    private readonly object _gate = new();
    private readonly bool _swapModifiers, _scrollInvert;
    private readonly EdgeDetector _detector, _returnDetector;
    private readonly Keymap.ModifierTracker _mods = new();
    private readonly Keymap.FlagState _flags = new();
    private readonly HashSet<ScanKey> _held = new();
    private readonly Dictionary<MouseButtonKind, (long Ticks, int Count)> _lastClick = new();
    private (double X, double Y) _cursor;
    private double _pendingDx, _pendingDy;
    private bool _flushScheduled;
    private double _scrollRemX, _scrollRemY;

    public (int Width, int Height) Screen { get; set; }
    public bool Enabled { get; set; } = true;
    public int DoubleClickMs { get; set; } = 500;
    public ControlState State { get; private set; } = new(ControlKind.Local);
    public Dictionary<Edge, string> EdgePeers { get; set; } = new();

    /// <summary>The capture layer should grab (true) or release (false) this PC's own mouse and keyboard.</summary>
    public event Action<bool>? GrabChanged;
    public event Action<ControlState>? StateChanged;

    public ControlManager(IInputInjector injector, Func<string, MsgType, byte[], bool> send, (int, int) screen,
                          bool swapModifiers = true, double edgePush = 12, bool scrollInvert = false)
    {
        _injector = injector;
        _send = send;
        Screen = screen;
        _swapModifiers = swapModifiers;
        _scrollInvert = scrollInvert;
        _detector = new EdgeDetector(edgePush);
        _returnDetector = new EdgeDetector(edgePush);
    }

    private void SetState(ControlState s)
    {
        State = s;
        StateChanged?.Invoke(s);
    }

    // ---- geometry ----------------------------------------------------------------------------

    public static (double X, double Y) EdgePoint(Edge edge, double position, (int W, int H) size, double inset)
    {
        var t = Math.Clamp(position, 0, 1);
        return edge switch
        {
            Edge.Left => (inset, t * (size.H - 1)),
            Edge.Right => (size.W - 1 - inset, t * (size.H - 1)),
            Edge.Top => (t * (size.W - 1), inset),
            _ => (t * (size.W - 1), size.H - 1 - inset),
        };
    }

    public static double Normalized(Edge edge, (double X, double Y) p, (int W, int H) size) =>
        Math.Clamp(edge is Edge.Left or Edge.Right ? p.Y / Math.Max(size.H - 1, 1) : p.X / Math.Max(size.W - 1, 1), 0, 1);

    // ---- this PC's own input (called by the capture layer) -----------------------------------

    /// <summary>Pointer movement. Returns true if the event should be swallowed (a peer is being controlled).</summary>
    public bool OnLocalMotion((double X, double Y) position, double dx, double dy)
    {
        lock (_gate)
        {
            switch (State.Kind)
            {
                case ControlKind.Controlling:
                    ForwardMotionLocked(dx, dy);
                    return true;
                case ControlKind.Local when Enabled && EdgePeers.Count > 0:
                    var hit = _detector.Update(position, (dx, dy), Screen, EdgePeers.Keys);
                    if (hit is { } h) BeginControllingLocked(EdgePeers[h.Edge], h.Edge, h.Position);
                    return State.Kind == ControlKind.Controlling;
                default:
                    return false;
            }
        }
    }

    public bool OnLocalButton(MouseButtonKind button, bool down)
    {
        lock (_gate)
        {
            if (State.Kind != ControlKind.Controlling) return false;
            FlushLocked();
            var count = ClickCount(button, down);
            _send(State.Peer!, MsgType.MouseButton, new MouseButtonPayload((byte)button, down, (byte)count).Encode());
            return true;
        }
    }

    public bool OnLocalScroll(int dxNotches, int dyNotches)
    {
        lock (_gate)
        {
            if (State.Kind != ControlKind.Controlling) return false;
            FlushLocked();
            _send(State.Peer!, MsgType.Scroll, new ScrollPayload(dxNotches, dyNotches, false).Encode());
            return true;
        }
    }

    /// <summary>
    /// A key event on this PC. Ctrl+Alt+Shift+Space always toggles control of the first positioned peer (the only
    /// switch that works without edge detection); otherwise, while controlling, the key goes to the peer.
    /// Returns true if the event should be swallowed.
    /// </summary>
    public bool OnLocalKey(ScanKey key, bool down, bool autorepeat)
    {
        lock (_gate)
        {
            if (down) _held.Add(key); else _held.Remove(key);
            if (down && !autorepeat && key == new ScanKey(0x39, false) && HotkeyModifiersHeld())
            {
                ToggleLocked(null);
                return true;
            }
            if (State.Kind != ControlKind.Controlling) return false;
            var mac = Keymap.WindowsToMac(key, _swapModifiers);
            if (mac is null) return true;                       // an unmapped key still must not leak to this PC
            FlushLocked();
            if (Keymap.IsMacModifier(mac.Value))
            {
                if (autorepeat) return true;
                var flags = _flags.Update(mac.Value, down);
                if (mac.Value == 57 && !down) return true;      // caps lock toggles on press only
                _send(State.Peer!, MsgType.FlagsChanged, new KeyPayload(mac.Value, true, flags, false).Encode());
            }
            else
            {
                _send(State.Peer!, MsgType.KeyEvent, new KeyPayload(mac.Value, down, _flags.Flags, autorepeat).Encode());
            }
            return true;
        }
    }

    private bool HotkeyModifiersHeld() =>
        (_held.Contains(new(0x1D, false)) || _held.Contains(new(0x1D, true))) &&
        (_held.Contains(new(0x38, false)) || _held.Contains(new(0x38, true))) &&
        (_held.Contains(new(0x2A, false)) || _held.Contains(new(0x36, false)));

    private int ClickCount(MouseButtonKind b, bool down)
    {
        var now = Environment.TickCount64;
        _lastClick.TryGetValue(b, out var last);
        if (!down) return Math.Max(last.Count, 1);
        var count = now - last.Ticks < DoubleClickMs ? last.Count + 1 : 1;
        _lastClick[b] = (now, count);
        return count;
    }

    public void Toggle(string? peer = null) { lock (_gate) ToggleLocked(peer); }

    private void ToggleLocked(string? peer)
    {
        if (State.Kind == ControlKind.Controlling) { ReleaseLocked(notify: true, warp: null); return; }
        if (State.Kind != ControlKind.Local || !Enabled || EdgePeers.Count == 0) return;
        var pair = peer is null ? EdgePeers.First() : EdgePeers.FirstOrDefault(kv => kv.Value == peer);
        if (pair.Value is not null) BeginControllingLocked(pair.Value, pair.Key, 0.5);
    }

    private bool BeginControllingLocked(string peer, Edge edge, double position)
    {
        if (!_send(peer, MsgType.EnterControl, new ControlPayload(edge, (float)position).Encode())) return false;
        SetState(new ControlState(ControlKind.Controlling, peer, edge));
        _pendingDx = _pendingDy = 0;
        GrabChanged?.Invoke(true);
        return true;
    }

    public void ReleaseToLocal(bool notify = true, double? warp = null) { lock (_gate) ReleaseLocked(notify, warp); }

    private void ReleaseLocked(bool notify, double? warp)
    {
        if (State.Kind != ControlKind.Controlling) return;
        FlushLocked();
        var (peer, edge) = (State.Peer!, State.Edge ?? Edge.Left);
        if (notify) _send(peer, MsgType.ReleaseControl, new ControlPayload(edge, -1).Encode());
        _held.Clear();
        SetState(new ControlState(ControlKind.Local));
        GrabChanged?.Invoke(false);
        if (warp is { } w)
        {
            var (x, y) = EdgePoint(edge, w, Screen, 6);
            _injector.MoveAbs(x / Math.Max(Screen.Width - 1, 1), y / Math.Max(Screen.Height - 1, 1));
        }
    }

    private void ForwardMotionLocked(double dx, double dy)
    {
        _pendingDx += dx;
        _pendingDy += dy;
        if (_flushScheduled) return;
        _flushScheduled = true;
        _ = Task.Delay(3).ContinueWith(_ => { lock (_gate) { _flushScheduled = false; FlushLocked(); } });
    }

    private void FlushLocked()
    {
        if (State.Kind != ControlKind.Controlling || (_pendingDx == 0 && _pendingDy == 0)) return;
        var (dx, dy) = (_pendingDx, _pendingDy);
        _pendingDx = _pendingDy = 0;
        _send(State.Peer!, MsgType.MouseMove, new MouseMovePayload((float)dx, (float)dy).Encode());
    }

    // ---- messages from peers -----------------------------------------------------------------

    public void OnMessage(string peer, Message msg)
    {
        try { lock (_gate) OnMessageLocked(peer, msg); }
        catch (ProtocolException) { /* one bad message must not take the app down */ }
    }

    private void OnMessageLocked(string peer, Message msg)
    {
        switch (msg.Type)
        {
            case MsgType.EnterControl:
            {
                if (!Enabled || State.Kind != ControlKind.Local)
                {
                    _send(peer, MsgType.ReleaseControl, new ControlPayload(Edge.Left, -1).Encode());
                    return;
                }
                var c = ControlPayload.Decode(msg.Payload);
                var ret = c.Edge.Opposite();
                _cursor = EdgePoint(ret, c.Position, Screen, 2);
                _returnDetector.Reset();
                SetState(new ControlState(ControlKind.Controlled, peer, ret));
                Warp();
                return;
            }
            case MsgType.ReleaseControl:
            {
                var c = ControlPayload.Decode(msg.Payload);
                if (State.Kind == ControlKind.Controlling && State.Peer == peer) ReleaseLocked(notify: false, warp: c.Position >= 0 ? c.Position : null);
                else if (State.Kind == ControlKind.Controlled && State.Peer == peer) EndControlledLocked();
                return;
            }
        }
        if (State.Kind != ControlKind.Controlled || State.Peer != peer) return;
        switch (msg.Type)
        {
            case MsgType.MouseMove:
            {
                var m = MouseMovePayload.Decode(msg.Payload);
                _cursor = (Math.Clamp(_cursor.X + m.Dx, 0, Screen.Width - 1), Math.Clamp(_cursor.Y + m.Dy, 0, Screen.Height - 1));
                Warp();
                var hit = _returnDetector.Update(_cursor, (m.Dx, m.Dy), Screen, new[] { State.Edge!.Value });
                if (hit is { } h)
                {
                    _send(peer, MsgType.ReleaseControl, new ControlPayload(State.Edge.Value, (float)h.Position).Encode());
                    EndControlledLocked();
                }
                return;
            }
            case MsgType.MouseButton:
            {
                var b = MouseButtonPayload.Decode(msg.Payload);
                if (Enum.IsDefined(typeof(MouseButtonKind), (int)b.Button)) _injector.Button((MouseButtonKind)b.Button, b.Down);
                return;
            }
            case MsgType.Scroll:
            {
                var s = ScrollPayload.Decode(msg.Payload);
                var sign = _scrollInvert ? -1.0 : 1.0;
                var scale = s.Continuous ? 1.0 / 40 : 1.0;      // pixel deltas -> wheel notches (~40 px each)
                _scrollRemX += s.Dx * scale * sign;
                _scrollRemY += s.Dy * scale * sign;
                var (ix, iy) = ((int)_scrollRemX, (int)_scrollRemY);
                _scrollRemX -= ix;
                _scrollRemY -= iy;
                if (ix != 0 || iy != 0) _injector.Scroll(ix, iy);
                return;
            }
            case MsgType.KeyEvent:
            {
                var k = KeyPayload.Decode(msg.Payload);
                if (Keymap.MacToWindows(k.KeyCode, _swapModifiers) is { } key) _injector.Key(key, k.Down);
                return;
            }
            case MsgType.FlagsChanged:
            {
                var k = KeyPayload.Decode(msg.Payload);
                if (Keymap.MacToWindows(k.KeyCode, _swapModifiers) is not { } key) return;
                if (k.KeyCode == 57) { _injector.Key(key, true); _injector.Key(key, false); return; } // caps lock: tap
                var pressed = _mods.Update(k.KeyCode, k.Flags);
                if (pressed is { } p) _injector.Key(key, p);
                return;
            }
        }
    }

    private void Warp() =>
        _injector.MoveAbs(_cursor.X / Math.Max(Screen.Width - 1, 1), _cursor.Y / Math.Max(Screen.Height - 1, 1));

    private void EndControlledLocked()
    {
        _injector.ReleaseAll();
        _returnDetector.Reset();
        SetState(new ControlState(ControlKind.Local));
    }

    /// <summary>Never leave this PC's devices grabbed or keys stuck when a peer vanishes.</summary>
    public void PeerDisconnected(string peer)
    {
        lock (_gate)
        {
            if (State.Peer != peer) return;
            if (State.Kind == ControlKind.Controlling) ReleaseLocked(notify: false, warp: 0.5);
            else if (State.Kind == ControlKind.Controlled) EndControlledLocked();
        }
    }
}

/// <summary>Requires sustained outward pressure against an edge before reporting a crossing.</summary>
public sealed class EdgeDetector
{
    public double Threshold { get; set; }
    private double _accumulated;
    private Edge? _current;

    public EdgeDetector(double threshold = 12) => Threshold = threshold;

    public void Reset() { _accumulated = 0; _current = null; }

    public readonly record struct Hit(Edge Edge, double Position);

    public static bool IsPushing(Edge edge, (double X, double Y) p, (double X, double Y) d, (int W, int H) size)
    {
        const double slop = 1.5;
        return edge switch
        {
            Edge.Right => p.X >= size.W - 1 - slop && d.X > 0,
            Edge.Left => p.X <= slop && d.X < 0,
            Edge.Bottom => p.Y >= size.H - 1 - slop && d.Y > 0,
            _ => p.Y <= slop && d.Y < 0,
        };
    }

    private static double Outward(Edge edge, (double X, double Y) d) => edge switch
    {
        Edge.Right => d.X, Edge.Left => -d.X, Edge.Bottom => d.Y, _ => -d.Y,
    };

    public Hit? Update((double X, double Y) position, (double X, double Y) delta, (int W, int H) size, IEnumerable<Edge> edges)
    {
        Edge? hit = null;
        foreach (var e in edges) if (IsPushing(e, position, delta, size)) { hit = e; break; }
        if (hit is not { } edge) { Reset(); return null; }
        if (_current != edge) { _current = edge; _accumulated = 0; }
        _accumulated += Outward(edge, delta);
        if (_accumulated < Threshold) return null;
        var result = new Hit(edge, ControlManager.Normalized(edge, position, size));
        Reset();
        return result;
    }
}
