using System.Net;
using System.Net.Sockets;
using MacLinker.Core;
using Xunit;

namespace MacLinker.Core.Tests;

internal static class Wait
{
    public static async Task Until(Func<bool> condition, int timeoutMs = 8000)
    {
        var end = Environment.TickCount64 + timeoutMs;
        while (!condition())
        {
            if (Environment.TickCount64 > end) throw new TimeoutException("condition not met in time");
            await Task.Delay(10);
        }
    }

    public static string TempDir()
    {
        var d = Path.Combine(Path.GetTempPath(), "ml-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(d);
        return d;
    }
}

public class SessionTests
{
    private sealed class Peer
    {
        public readonly Identity Identity;
        public readonly TrustedStore Trusted;
        public readonly List<Message> Messages = new();
        public readonly List<SessionState> States = new();
        public readonly List<string> Codes = new();
        public bool Confirm = true;
        public TaskCompletionSource? Hold;
        public Session? Session;

        public Peer(string name)
        {
            var dir = Wait.TempDir();
            Identity = new Identity(dir, name);
            Trusted = new TrustedStore(dir);
        }

        public Session Attach(Stream stream, bool initiator) =>
            Session = new Session(stream, initiator, Identity, Trusted, 1234, "9.9.9",
                (_, m) => { lock (Messages) Messages.Add(m); }, (_, s) => { lock (States) States.Add(s); },
                async (_, _, code) =>
                {
                    lock (Codes) Codes.Add(code);
                    if (Hold is not null) await Hold.Task;
                    return Confirm;
                });
    }

    private static async Task<(Task a, Task b, TcpListener l)> Connect(Peer a, Peer b)
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var accept = listener.AcceptTcpClientAsync();
        var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
        var server = await accept;
        var sa = a.Attach(client.GetStream(), true);      // created up front so tests can look at them straight away
        var sb = b.Attach(server.GetStream(), false);
        var ta = Task.Run(sa.RunAsync);
        var tb = Task.Run(sb.RunAsync);
        return (ta, tb, listener);
    }

    [Fact]
    public async Task PairConnectAndExchangeMessages()
    {
        Peer a = new("A"), b = new("B");
        var (ta, tb, l) = await Connect(a, b);
        await Wait.Until(() => a.Session!.State == SessionState.Connected && b.Session!.State == SessionState.Connected);
        Assert.Equal(a.Codes, b.Codes);
        Assert.Equal(6, a.Codes[0].Length);
        Assert.True(a.Trusted.IsTrusted(b.Identity.PublicKey));
        Assert.Equal("B", a.Session!.PeerName);
        Assert.Equal("9.9.9", a.Session.PeerVersion);
        Assert.True(a.Session.Send(MsgType.MouseMove, new MouseMovePayload(3, 4).Encode()));
        await Wait.Until(() => { lock (b.Messages) return b.Messages.Count > 0; });
        Assert.Equal(MsgType.MouseMove, b.Messages[0].Type);
        await a.Session.CloseAsync();
        await tb.WaitAsync(TimeSpan.FromSeconds(5));
        l.Stop();
    }

    [Fact]
    public async Task SecondConnectionNeedsNoPairing()
    {
        Peer a = new("A"), b = new("B");
        var (ta, tb, l) = await Connect(a, b);
        await Wait.Until(() => a.Session!.State == SessionState.Connected);
        await a.Session!.CloseAsync();
        await tb.WaitAsync(TimeSpan.FromSeconds(5));
        l.Stop();
        a.Codes.Clear(); b.Codes.Clear();
        (ta, tb, l) = await Connect(a, b);
        await Wait.Until(() => a.Session!.State == SessionState.Connected && b.Session!.State == SessionState.Connected);
        Assert.Empty(a.Codes);
        Assert.False(a.Session!.NeedsPairing);
        await a.Session.CloseAsync();
        await tb.WaitAsync(TimeSpan.FromSeconds(5));
        l.Stop();
    }

    [Fact]
    public async Task RejectedPairingClosesAndTrustsNobody()
    {
        Peer a = new("A"), b = new("B") { Confirm = false };
        var (ta, tb, l) = await Connect(a, b);
        await Task.WhenAll(ta, tb).WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal(SessionState.Closed, a.Session!.State);
        Assert.Equal(SessionState.Closed, b.Session!.State);
        Assert.False(a.Trusted.IsTrusted(b.Identity.PublicKey));
        Assert.False(b.Trusted.IsTrusted(a.Identity.PublicKey));
        l.Stop();
    }

    [Fact]
    public async Task DataBeforePairingIsRefused()
    {
        Peer a = new("A"), b = new("B") { Hold = new TaskCompletionSource() };
        var (ta, tb, l) = await Connect(a, b);
        await Wait.Until(() => a.Session!.State == SessionState.Pairing && b.Session!.State == SessionState.Pairing);
        Assert.False(a.Session!.Send(MsgType.MouseMove, new MouseMovePayload(1, 1).Encode()));
        b.Confirm = false;
        b.Hold.SetResult();
        await Task.WhenAll(ta, tb).WaitAsync(TimeSpan.FromSeconds(10));
        l.Stop();
    }

    [Fact]
    public async Task ASessionWithTheWrongExpectedPeerIsRefused()
    {
        Peer a = new("A"), b = new("B");
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var accept = listener.AcceptTcpClientAsync();
        var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port);
        var server = await accept;
        var sa = new Session(client.GetStream(), true, a.Identity, a.Trusted, 1, "1", (_, _) => { }, (_, _) => { },
            (_, _, _) => Task.FromResult(true), expectedPeerId: "0000000000000000");
        b.Attach(server.GetStream(), false);
        var tb = Task.Run(() => b.Session!.RunAsync());
        await sa.RunAsync().WaitAsync(TimeSpan.FromSeconds(10));
        await tb.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.NotEqual(SessionState.Connected, sa.State);
        Assert.Empty(a.Codes);
        listener.Stop();
    }
}
