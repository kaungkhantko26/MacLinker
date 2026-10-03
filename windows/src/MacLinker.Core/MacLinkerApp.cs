using System.Net;
using System.Net.Sockets;

namespace MacLinker.Core;

public sealed class AppOptions
{
    public int Port { get; set; } = 52845;
    public bool UseDiscovery { get; set; } = true;
    public bool SwapModifiers { get; set; } = true;
    public double EdgePush { get; set; } = 12;
    public bool ScrollInvert { get; set; }
    /// <summary>Reported to peers. Deliberately below the Mac app's 1.2.0, the first version that sends messages this app doesn't handle.</summary>
    public string AppVersion { get; set; } = "0.1.0";
    public string? ConfigDir { get; set; }
    public string? Name { get; set; }
    public string? DownloadsDir { get; set; }
    public bool ClipboardSharing { get; set; } = true;
    public bool FileSharing { get; set; } = true;
    public bool InputSharing { get; set; } = true;
}

public sealed class PairingPrompt
{
    public required Session Session { get; init; }
    public required string Name { get; init; }
    public required string Code { get; init; }
    internal TaskCompletionSource<bool> Result { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public string SpacedCode => Code.Length == 6 ? $"{Code[..3]} {Code[3..]}" : Code;
}

public sealed record DeviceStatus(string Id, string Name, string? Position, bool Connected, bool Pairing, double? LatencyMs,
                                  bool Nearby, bool Trusted, string Version, string? Host);

/// <summary>
/// The whole engine behind the Windows app (and the tests): listens for Macs, finds them, pairs, reconnects, keeps the
/// layout in step, and routes messages to input, clipboard and file transfer.
/// </summary>
public sealed class MacLinkerApp : IDisposable
{
    public AppOptions Options { get; }
    public Identity Identity { get; }
    public TrustedStore Trusted { get; }
    public ControlManager Control { get; }
    public FileTransfer Files { get; }
    public ClipboardSync? Clipboard { get; private set; }
    public PairingPrompt? Pairing { get; private set; }
    public int Port { get; private set; }

    public event Action? Changed;
    public event Action<string>? Log;
    public event Action<PairingPrompt>? PairingRequested;

    private readonly Dictionary<string, Session> _sessions = new();
    private readonly Dictionary<string, FoundDevice> _found = new();
    private readonly Dictionary<string, DateTime> _offlineSince = new(), _nextAttempt = new();
    private readonly Dictionary<string, int> _failures = new();
    private readonly object _lock = new();
    private readonly CancellationTokenSource _cts = new();
    private TcpListener? _listener;
    private Discovery? _discovery;

    public MacLinkerApp(AppOptions options, IInputInjector injector, (int Width, int Height) screen, IClipboardBackend? clipboard = null)
    {
        Options = options;
        Identity = new Identity(options.ConfigDir, options.Name);
        Trusted = new TrustedStore(options.ConfigDir);
        Control = new ControlManager(injector, SendTo, screen, options.SwapModifiers, options.EdgePush, options.ScrollInvert)
        {
            Enabled = options.InputSharing,
        };
        Files = new FileTransfer(SendTo, () => Options.FileSharing, options.DownloadsDir);
        Files.Changed += () => Changed?.Invoke();
        if (clipboard is not null) Clipboard = new ClipboardSync(clipboard, payload => Broadcast(MsgType.Clipboard, payload), () => Options.ClipboardSharing);
    }

    // ---- lifecycle ---------------------------------------------------------------------------

    public void Start()
    {
        _listener = new TcpListener(IPAddress.IPv6Any, Options.Port) { Server = { DualMode = true } };
        try { _listener.Start(); }
        catch (SocketException)
        {
            _listener = new TcpListener(IPAddress.IPv6Any, 0) { Server = { DualMode = true } };   // default port taken: use any free one
            _listener.Start();
        }
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        Log?.Invoke($"{Identity.Name} [{Identity.DeviceId}] listening on port {Port}");
        _ = Task.Run(AcceptLoopAsync);
        _ = Task.Run(ReconnectLoopAsync);
        if (Options.UseDiscovery)
        {
            _discovery = new Discovery(Identity.DeviceId);
            _discovery.Found += d => { lock (_lock) _found[d.Id] = d; Changed?.Invoke(); };
            _discovery.Lost += id => { lock (_lock) _found.Remove(id); Changed?.Invoke(); };
            _discovery.Log += m => Log?.Invoke(m);
            _discovery.Start(Identity.Name, Identity.DeviceId, Port);
        }
        RefreshEdges();
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener?.Stop();
        _discovery?.Dispose();
        List<Session> all;
        lock (_lock) all = _sessions.Values.ToList();
        foreach (var s in all) _ = s.CloseAsync();
    }

    // ---- sessions ----------------------------------------------------------------------------

    private async Task AcceptLoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener!.AcceptTcpClientAsync(_cts.Token); }
            catch (Exception e) when (e is OperationCanceledException or ObjectDisposedException or SocketException) { return; }
            _ = Task.Run(() => RunSessionAsync(client, initiator: false, expected: null));
        }
    }

    public async Task<string> ConnectAsync(string host, int port = 52845, string? expectedId = null)
    {
        var client = new TcpClient { NoDelay = true };
        try
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(8));
            await client.ConnectAsync(host, port, timeout.Token);
        }
        catch (Exception e) when (e is SocketException or OperationCanceledException or IOException)
        {
            client.Dispose();
            return $"couldn't connect to {host}:{port}: {e.Message}";
        }
        _ = Task.Run(() => RunSessionAsync(client, initiator: true, expected: expectedId));
        return $"connecting to {host}:{port}";
    }

    private async Task RunSessionAsync(TcpClient client, bool initiator, string? expected)
    {
        client.NoDelay = true;
        var remote = (client.Client.RemoteEndPoint as IPEndPoint)?.Address;
        if (remote is { IsIPv4MappedToIPv6: true }) remote = remote.MapToIPv4();
        var session = new Session(client.GetStream(), initiator, Identity, Trusted, Port, Options.AppVersion, OnMessage, OnState,
                                  OnPairingAsync, expected, remote?.ToString());
        try { await session.RunAsync(); }
        finally { client.Dispose(); }
    }

    private void OnState(Session s, SessionState state)
    {
        if (state is SessionState.Pairing or SessionState.Connected && s.PeerId is not null) Claim(s);
        if (state == SessionState.Connected && IsActive(s)) Connected(s);
        else if (state == SessionState.Closed)
        {
            lock (_lock)
            {
                if (Pairing?.Session == s) { Pairing.Result.TrySetResult(false); Pairing = null; }
                if (s.PeerId is not null && _sessions.TryGetValue(s.PeerId, out var cur) && cur == s) _sessions.Remove(s.PeerId);
                else { Changed?.Invoke(); return; }
            }
            Control.PeerDisconnected(s.PeerId!);
            Files.PeerDisconnected();
            RefreshEdges();
            Log?.Invoke($"{(s.PeerName.Length > 0 ? s.PeerName : s.PeerId)} disconnected");
        }
        Changed?.Invoke();
    }

    private bool IsActive(Session s) { lock (_lock) return s.PeerId is not null && _sessions.TryGetValue(s.PeerId, out var c) && c == s; }

    /// <summary>Both machines may dial each other; both keep the connection started by the smaller device ID.</summary>
    private void Claim(Session s)
    {
        Session? loser = null;
        lock (_lock)
        {
            if (_sessions.TryGetValue(s.PeerId!, out var existing) && existing != s && existing.State != SessionState.Closed)
            {
                string InitiatorId(Session x) => x.Initiator ? Identity.DeviceId : x.PeerId!;
                if (string.CompareOrdinal(InitiatorId(s), InitiatorId(existing)) < 0) loser = existing;
                else { loser = s; }
            }
            if (loser != s) _sessions[s.PeerId!] = s;
        }
        if (loser is not null) _ = loser.CloseAsync();
    }

    private void Connected(Session s)
    {
        Log?.Invoke($"connected to {s.PeerName} ({s.PeerId})");
        Trusted.Update(s.PeerId!, d =>
        {
            d.Name = s.PeerName;
            if (s.RemoteHost is { } host && !host.Contains(':'))
            {
                d.LastHost = host;
                d.LastPort = s.PeerPort > 0 ? s.PeerPort : 52845;
            }
        });
        lock (_lock) { _failures.Remove(s.PeerId!); }
        if (Trusted.Get(s.PeerId!)?.Edge is { } edge) s.Send(MsgType.Layout, new LayoutPayload(edge, false).Encode());
        RefreshEdges();
    }

    private async Task<bool> OnPairingAsync(Session s, string name, string code)
    {
        var prompt = new PairingPrompt { Session = s, Name = name, Code = code };
        lock (_lock) Pairing = prompt;
        Changed?.Invoke();
        PairingRequested?.Invoke(prompt);
        try { return await prompt.Result.Task; }
        finally { lock (_lock) { if (Pairing == prompt) Pairing = null; } Changed?.Invoke(); }
    }

    /// <summary>Adds a line to the activity log (shown in the window).</summary>
    public void Say(string message) => Log?.Invoke(message);

    public void ConfirmPairing(bool accept) { PairingPrompt? p; lock (_lock) p = Pairing; p?.Result.TrySetResult(accept); }

    // ---- routing -----------------------------------------------------------------------------

    private bool SendTo(string peer, MsgType type, byte[] payload)
    {
        Session? s;
        lock (_lock) _sessions.TryGetValue(peer, out s);
        return s is not null && s.Send(type, payload);
    }

    private void Broadcast(MsgType type, byte[] payload)
    {
        List<string> peers;
        lock (_lock) peers = _sessions.Where(kv => kv.Value.State == SessionState.Connected).Select(kv => kv.Key).ToList();
        foreach (var p in peers) SendTo(p, type, payload);
    }

    private void OnMessage(Session s, Message msg)
    {
        if (!IsActive(s) || s.PeerId is null) return;
        switch (msg.Type)
        {
            case MsgType.MouseMove or MsgType.MouseButton or MsgType.Scroll or MsgType.KeyEvent or MsgType.FlagsChanged
                or MsgType.EnterControl or MsgType.ReleaseControl:
                Control.OnMessage(s.PeerId, msg);
                break;
            case MsgType.Clipboard:
                Clipboard?.Receive(msg.Payload);
                break;
            case MsgType.FileOffer or MsgType.FileChunk or MsgType.FileEnd or MsgType.FileAbort:
                Files.OnMessage(s.PeerId, s.PeerName, msg);
                break;
            case MsgType.Layout:
                if (ApplyRemoteLayout(Trusted, Identity.DeviceId, s.PeerId, LayoutPayload.Decode(msg.Payload))) RefreshEdges();
                break;
        }
    }

    /// <summary>Mirrors the peer's layout choice. On connect the machine with the smaller ID wins, so two inconsistent
    /// configurations converge instead of swapping. Returns true if the position changed.</summary>
    public static bool ApplyRemoteLayout(TrustedStore trusted, string myId, string peerId, LayoutPayload layout)
    {
        var dev = trusted.Get(peerId);
        if (dev is null) return false;
        if (!layout.UserInitiated)
        {
            if (layout.PeerPosition is null) return false;
            var senderWins = string.CompareOrdinal(peerId, myId) < 0;
            if (!(senderWins || dev.Position is null)) return false;
        }
        var newPosition = layout.PeerPosition?.Opposite().Title();
        if (newPosition == dev.Position) return false;
        trusted.Update(peerId, d => d.Position = newPosition);
        return true;
    }

    // ---- layout & status ---------------------------------------------------------------------

    private void RefreshEdges()
    {
        var edges = new Dictionary<Edge, string>();
        lock (_lock)
            foreach (var dev in Trusted.All())
                if (dev.Edge is { } e && _sessions.TryGetValue(dev.Id, out var s) && s.State == SessionState.Connected) edges[e] = dev.Id;
        Control.EdgePeers = edges;
        Changed?.Invoke();
    }

    public void SetPosition(string deviceId, Edge? edge)
    {
        Trusted.Update(deviceId, d => d.Position = edge?.Title());
        SendTo(deviceId, MsgType.Layout, new LayoutPayload(edge, true).Encode());
        RefreshEdges();
    }

    public async Task ForgetAsync(string deviceId)
    {
        Session? s;
        lock (_lock) _sessions.TryGetValue(deviceId, out s);
        if (s is not null) await s.CloseAsync();
        Trusted.Remove(deviceId);
        RefreshEdges();
    }

    public Task<string> SendFileAsync(string deviceId, string path)
    {
        Session? s;
        lock (_lock) _sessions.TryGetValue(deviceId, out s);
        if (s is null || s.State != SessionState.Connected) return Task.FromResult("failed: not connected");
        return Files.SendFileAsync(s, path, s.PeerName);
    }

    public IReadOnlyList<DeviceStatus> Devices()
    {
        lock (_lock)
        {
            var ids = Trusted.All().Select(d => d.Id).Concat(_found.Keys).Concat(_sessions.Keys).Distinct().ToList();
            return ids.Select(id =>
            {
                var trusted = Trusted.Get(id);
                _sessions.TryGetValue(id, out var s);
                _found.TryGetValue(id, out var f);
                return new DeviceStatus(id, trusted?.Name ?? s?.PeerName ?? f?.Name ?? id, trusted?.Position,
                    s?.State == SessionState.Connected, s?.State == SessionState.Pairing, s?.LatencyMs, f is not null, trusted is not null,
                    s?.PeerVersion ?? "", f?.Host ?? trusted?.LastHost);
            }).OrderByDescending(d => d.Connected).ThenBy(d => d.Name, StringComparer.OrdinalIgnoreCase).ToList();
        }
    }

    // ---- reconnect ---------------------------------------------------------------------------

    private async Task ReconnectLoopAsync()
    {
        while (!_cts.IsCancellationRequested)
        {
            try { await Task.Delay(2000, _cts.Token); } catch (OperationCanceledException) { return; }
            var now = DateTime.UtcNow;
            foreach (var dev in Trusted.All())
            {
                string? host; int port;
                lock (_lock)
                {
                    if (_sessions.ContainsKey(dev.Id)) { _offlineSince.Remove(dev.Id); continue; }
                    var since = _offlineSince.TryGetValue(dev.Id, out var t) ? t : _offlineSince[dev.Id] = now;
                    // The smaller ID dials first; the other waits so they don't collide, but still dials if it has to.
                    if (string.CompareOrdinal(Identity.DeviceId, dev.Id) > 0 && now - since < TimeSpan.FromSeconds(6)) continue;
                    if (_nextAttempt.TryGetValue(dev.Id, out var next) && now < next) continue;
                    if (_found.TryGetValue(dev.Id, out var f)) { host = f.Host; port = f.Port; }
                    else { host = dev.LastHost; port = dev.LastPort ?? 52845; }
                    if (host is null) continue;
                    var n = _failures.GetValueOrDefault(dev.Id);
                    _failures[dev.Id] = n + 1;
                    _nextAttempt[dev.Id] = now + TimeSpan.FromSeconds(Math.Min(30, 2 * Math.Pow(1.6, n)));
                }
                await ConnectAsync(host, port, dev.Id);
            }
        }
    }
}
