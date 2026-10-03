using MacLinker.Core;
using Xunit;
using Xunit.Abstractions;

namespace MacLinker.Core.Tests;

/// <summary>Opt-in (MACLINKER_LIVE=1): looks for a real MacLinker on this network and prints what it finds.</summary>
public class LiveDiscoveryTests
{
    private readonly ITestOutputHelper _out;
    public LiveDiscoveryTests(ITestOutputHelper output) => _out = output;

    [Fact]
    public async Task FindsARealMacOnTheNetwork()
    {
        if (Environment.GetEnvironmentVariable("MACLINKER_LIVE") != "1") return;
        var found = new List<FoundDevice>();
        using var discovery = new Discovery("ffffffffffffffff");
        discovery.Found += d => { lock (found) found.Add(d); };
        discovery.Log += m => _out.WriteLine(m);
        discovery.Start("Windows probe", "ffffffffffffffff", 52999);
        for (var i = 0; i < 100; i++) { lock (found) if (found.Count > 0) break; await Task.Delay(100); }   // up to 10 s
        lock (found) foreach (var d in found) _out.WriteLine($"FOUND {d.Name} id={d.Id} at {d.Host}:{d.Port}");
        Assert.NotEmpty(found);
    }
}

public class LiveHandshakeTests
{
    private readonly ITestOutputHelper _out;
    public LiveHandshakeTests(ITestOutputHelper output) => _out = output;

    /// <summary>Opt-in (MACLINKER_LIVE_PORT=n): handshakes with a real Mac app, then declines the pairing.</summary>
    [Fact]
    public async Task HandshakesWithTheRealMacApp()
    {
        if (!int.TryParse(Environment.GetEnvironmentVariable("MACLINKER_LIVE_PORT"), out var port)) return;
        var dir = Wait.TempDir();
        var identity = new Identity(dir, "Windows probe");
        var trusted = new TrustedStore(dir);
        using var client = new System.Net.Sockets.TcpClient();
        await client.ConnectAsync("127.0.0.1", port);
        string? name = null, version = null, code = null;
        var states = new List<SessionState>();
        var session = new Session(client.GetStream(), true, identity, trusted, 52999, "0.1.0", (_, _) => { },
            (_, s) => states.Add(s), (s, n, c) => { name = n; version = s.PeerVersion; code = c; return Task.FromResult(false); });
        await session.RunAsync().WaitAsync(TimeSpan.FromSeconds(15));
        _out.WriteLine($"LIVE peer='{name}' version={version} code={code} states={string.Join(",", states)} peerId={session.PeerId}");
        Assert.NotNull(name);           // we decrypted the Mac's hello
        Assert.Contains(SessionState.Pairing, states);
    }
}
