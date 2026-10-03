using MacLinker.Core;
using Xunit;

namespace MacLinker.Core.Tests;

public sealed class FakeInjector : IInputInjector
{
    public List<string> Events { get; } = new();
    public void MoveAbs(double x, double y) => Events.Add($"move {x:F3} {y:F3}");
    public void Button(MouseButtonKind b, bool down) => Events.Add($"button {b} {(down ? "down" : "up")}");
    public void Scroll(int dx, int dy) => Events.Add($"scroll {dx} {dy}");
    public void Key(ScanKey k, bool down) => Events.Add($"key {k.Scan:X2}{(k.Extended ? "e" : "")} {(down ? "down" : "up")}");
    public void ReleaseAll() => Events.Add("release_all");
}

public class ControlTests
{
    private static readonly (int, int) Screen = (1000, 800);

    private sealed class Harness
    {
        public FakeInjector Injector = new();
        public List<(string Peer, MsgType Type, byte[] Payload)> Sent = new();
        public List<bool> Grabs = new();
        public ControlManager Control;

        public Harness(bool swap = true)
        {
            Control = new ControlManager(Injector, (p, t, b) => { Sent.Add((p, t, b)); return true; }, Screen, swap);
            Control.GrabChanged += Grabs.Add;
        }

        public void Receive(MsgType type, byte[] payload, string peer = "mac") => Control.OnMessage(peer, new Message(type, 0, payload));
    }

    [Fact]
    public void PushingAgainstAnEdgeHandsControlToThePeerAndGrabs()
    {
        var h = new Harness { };
        h.Control.EdgePeers = new() { [Edge.Right] = "mac" };
        var results = Enumerable.Range(0, 3).Select(_ => h.Control.OnLocalMotion((999, 400), 5, 0)).ToArray();
        Assert.Equal(new[] { false, false, true }, results);
        Assert.Equal(ControlKind.Controlling, h.Control.State.Kind);
        Assert.Equal(new[] { true }, h.Grabs);
        var (peer, type, payload) = h.Sent[0];
        Assert.Equal(("mac", MsgType.EnterControl), (peer, type));
        var c = ControlPayload.Decode(payload);
        Assert.Equal(Edge.Right, c.Edge);
        Assert.Equal(400.0 / 799, c.Position, 4);
    }

    [Fact]
    public void ControllingSwallowsLocalInputAndSendsItOrdered()
    {
        var h = new Harness();
        h.Control.EdgePeers = new() { [Edge.Right] = "mac" };
        h.Control.Toggle();
        h.Sent.Clear();
        Assert.True(h.Control.OnLocalMotion((10, 10), 3, 4));
        Assert.True(h.Control.OnLocalButton(MouseButtonKind.Left, true));          // flushes the pending move first
        Assert.Equal(new[] { MsgType.MouseMove, MsgType.MouseButton }, h.Sent.Select(s => s.Type).ToArray());
        Assert.True(h.Control.OnLocalScroll(0, 2));
        Assert.Equal(MsgType.Scroll, h.Sent[^1].Type);
    }

    [Fact]
    public void LocalInputPassesThroughWhenNobodyIsBeingControlled()
    {
        var h = new Harness();
        Assert.False(h.Control.OnLocalMotion((999, 400), 5, 0));
        Assert.False(h.Control.OnLocalButton(MouseButtonKind.Left, true));
        Assert.False(h.Control.OnLocalKey(new ScanKey(0x1E, false), true, false));
        Assert.Empty(h.Sent);
    }

    [Fact]
    public void WindowsKeysBecomeMacKeysWithModifierSwap()
    {
        var h = new Harness();
        h.Control.EdgePeers = new() { [Edge.Right] = "mac" };
        h.Control.Toggle();
        h.Sent.Clear();
        h.Control.OnLocalKey(new ScanKey(0x1D, false), true, false);               // Left Ctrl -> Command (modifier)
        h.Control.OnLocalKey(new ScanKey(0x2E, false), true, false);               // C
        var modifier = KeyPayload.Decode(h.Sent[0].Payload);
        Assert.Equal((MsgType.FlagsChanged, (ushort)55), (h.Sent[0].Type, modifier.KeyCode));
        Assert.True((modifier.Flags & Keymap.FlagCommand) != 0);
        var key = KeyPayload.Decode(h.Sent[1].Payload);
        Assert.Equal((MsgType.KeyEvent, (ushort)8), (h.Sent[1].Type, key.KeyCode));         // mac keycode 8 = c
        Assert.True((key.Flags & Keymap.FlagCommand) != 0, "Cmd+C reaches the Mac with Command held");
        h.Control.OnLocalKey(new ScanKey(0x1D, false), false, false);
        Assert.True((KeyPayload.Decode(h.Sent[^1].Payload).Flags & Keymap.FlagCommand) == 0);
    }

    [Fact]
    public void MacKeysBecomeWindowsScanCodes()
    {
        var h = new Harness();
        h.Receive(MsgType.EnterControl, new ControlPayload(Edge.Right, 0.5f).Encode());
        Assert.Equal(ControlKind.Controlled, h.Control.State.Kind);
        Assert.Equal(Edge.Left, h.Control.State.Edge);                              // returns through the left edge
        h.Receive(MsgType.KeyEvent, new KeyPayload(0, true, 0, false).Encode());   // mac 'a'
        h.Receive(MsgType.FlagsChanged, new KeyPayload(55, true, Keymap.FlagCommand, false).Encode());   // Command down -> Ctrl
        h.Receive(MsgType.FlagsChanged, new KeyPayload(55, true, 0, false).Encode());                     // released
        h.Receive(MsgType.MouseButton, new MouseButtonPayload(1, true, 1).Encode());
        h.Receive(MsgType.Scroll, new ScrollPayload(0, 3, false).Encode());
        Assert.Contains("key 1E down", h.Injector.Events);
        Assert.Contains("key 1D down", h.Injector.Events);
        Assert.Contains("key 1D up", h.Injector.Events);
        Assert.Contains("button Right down", h.Injector.Events);
        Assert.Contains("scroll 0 3", h.Injector.Events);
    }

    [Fact]
    public void CapsLockIsTappedBecauseWindowsTogglesOnPress()
    {
        var h = new Harness();
        h.Receive(MsgType.EnterControl, new ControlPayload(Edge.Right, 0.5f).Encode());
        h.Injector.Events.Clear();
        h.Receive(MsgType.FlagsChanged, new KeyPayload(57, true, Keymap.FlagCaps, false).Encode());
        Assert.Equal(new[] { "key 3A down", "key 3A up" }, h.Injector.Events);
    }

    [Fact]
    public void PushingBackThroughTheReturnEdgeReleasesControl()
    {
        var h = new Harness();
        h.Receive(MsgType.EnterControl, new ControlPayload(Edge.Right, 0.5f).Encode());
        for (var i = 0; i < 3; i++) h.Receive(MsgType.MouseMove, new MouseMovePayload(-20, 0).Encode());
        Assert.Equal(ControlKind.Local, h.Control.State.Kind);
        var release = h.Sent.Last(s => s.Type == MsgType.ReleaseControl);
        Assert.Equal(Edge.Left, ControlPayload.Decode(release.Payload).Edge);
        Assert.Contains("release_all", h.Injector.Events);
    }

    [Fact]
    public void InputFromTheWrongPeerOrWhileDisabledIsIgnored()
    {
        var h = new Harness();
        h.Receive(MsgType.MouseButton, new MouseButtonPayload(0, true, 1).Encode());
        Assert.Empty(h.Injector.Events);
        h.Control.Enabled = false;
        h.Receive(MsgType.EnterControl, new ControlPayload(Edge.Right, 0.5f).Encode());
        Assert.Equal(ControlKind.Local, h.Control.State.Kind);
        Assert.Equal(MsgType.ReleaseControl, h.Sent[^1].Type);
        h.Control.Enabled = true;
        h.Receive(MsgType.EnterControl, new ControlPayload(Edge.Right, 0.5f).Encode());
        h.Receive(MsgType.MouseButton, new MouseButtonPayload(0, true, 1).Encode(), peer: "intruder");
        Assert.DoesNotContain("button Left down", h.Injector.Events);
    }

    [Fact]
    public void ReleaseFromThePeerReturnsThePointerToTheRightEdgeAndUngrabs()
    {
        var h = new Harness();
        h.Control.EdgePeers = new() { [Edge.Right] = "mac" };
        h.Control.Toggle();
        h.Receive(MsgType.ReleaseControl, new ControlPayload(Edge.Left, 0.25f).Encode());
        Assert.Equal(ControlKind.Local, h.Control.State.Kind);
        Assert.Equal(new[] { true, false }, h.Grabs);
        Assert.StartsWith("move 0.99", h.Injector.Events[^1]);
    }

    [Fact]
    public void DisconnectNeverLeavesDevicesGrabbedOrKeysStuck()
    {
        var h = new Harness();
        h.Control.EdgePeers = new() { [Edge.Right] = "mac" };
        h.Control.Toggle();
        h.Control.PeerDisconnected("mac");
        Assert.Equal(ControlKind.Local, h.Control.State.Kind);
        Assert.False(h.Grabs[^1]);
        h.Receive(MsgType.EnterControl, new ControlPayload(Edge.Right, 0.5f).Encode());
        h.Control.PeerDisconnected("mac");
        Assert.Contains("release_all", h.Injector.Events);
    }

    [Fact]
    public void HotkeyTogglesControlAndIsSwallowed()
    {
        var h = new Harness();
        h.Control.EdgePeers = new() { [Edge.Left] = "mac" };
        foreach (var k in new ScanKey[] { new(0x1D, false), new(0x38, false), new(0x2A, false) }) Assert.False(h.Control.OnLocalKey(k, true, false));
        Assert.True(h.Control.OnLocalKey(new ScanKey(0x39, false), true, false));        // space completes the chord
        Assert.Equal(ControlKind.Controlling, h.Control.State.Kind);
        h.Control.OnLocalKey(new ScanKey(0x39, false), false, false);
        foreach (var k in new ScanKey[] { new(0x1D, false), new(0x38, false), new(0x2A, false) }) h.Control.OnLocalKey(k, true, false);
        Assert.True(h.Control.OnLocalKey(new ScanKey(0x39, false), true, false));
        Assert.Equal(ControlKind.Local, h.Control.State.Kind);
        Assert.Equal(MsgType.ReleaseControl, h.Sent[^1].Type);
    }

    [Fact]
    public void KeymapRoundTripsAndSwapsModifiers()
    {
        foreach (var mac in new ushort[] { 0, 11, 36, 49, 51, 53, 96, 122, 123, 126, 76, 82 })
        {
            var win = Keymap.MacToWindows(mac, swapModifiers: false);
            Assert.NotNull(win);
            Assert.Equal(mac, Keymap.WindowsToMac(win!.Value, swapModifiers: false));
        }
        Assert.Equal(new ScanKey(0x1D, false), Keymap.MacToWindows(55));                  // Command -> Ctrl
        Assert.Equal(new ScanKey(0x5B, true), Keymap.MacToWindows(59));                   // Control -> Windows key
        Assert.Equal(new ScanKey(0x38, false), Keymap.MacToWindows(58));                  // Option -> Alt
        Assert.Equal((ushort)55, Keymap.WindowsToMac(new ScanKey(0x1D, false)));
        Assert.Equal(new ScanKey(0x5B, true), Keymap.MacToWindows(55, swapModifiers: false));   // unswapped: Command -> Win
        var t = new Keymap.ModifierTracker();
        Assert.True(t.Update(55, Keymap.FlagCommand));
        Assert.False(t.Update(55, 0));
        Assert.True(t.Update(55, Keymap.FlagCommand));
        Assert.True(t.Update(54, Keymap.FlagCommand));
        Assert.False(t.Update(55, Keymap.FlagCommand), "left released while right still holds the bit");
        Assert.Null(t.Update(0, 0));
    }

    [Fact]
    public void EdgeDetectorNeedsSustainedPressure()
    {
        var d = new EdgeDetector(10);
        Assert.Null(d.Update((500, 400), (5, 0), Screen, new[] { Edge.Right }));
        Assert.Null(d.Update((999, 400), (4, 0), Screen, new[] { Edge.Right }));
        Assert.Null(d.Update((999, 400), (4, 0), Screen, new[] { Edge.Right }));
        var hit = d.Update((999, 400), (4, 0), Screen, new[] { Edge.Right });
        Assert.Equal(Edge.Right, hit?.Edge);
        Assert.Equal(2, ControlManager.EdgePoint(Edge.Left, 0.5, Screen, 2).X);
    }
}
