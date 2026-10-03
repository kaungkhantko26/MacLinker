using System.Buffers.Binary;
using System.Threading.Channels;

namespace MacLinker.Core;

public enum SessionState { Connecting, Handshaking, Pairing, Connected, Closed }

/// <summary>
/// One TCP connection to one peer: handshake, pairing, encryption and heartbeat.
/// Create with a connected stream, then await <see cref="RunAsync"/> until it ends.
/// </summary>
public sealed class Session
{
    public static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(2);
    public static readonly TimeSpan HeartbeatTimeout = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan PairingTimeout = TimeSpan.FromSeconds(90);

    private readonly Stream _stream;
    private readonly Identity _identity;
    private readonly TrustedStore _trusted;
    private readonly int _listenPort;
    private readonly string _appVersion;
    private readonly Action<Session, Message> _onMessage;
    private readonly Action<Session, SessionState> _onState;
    private readonly Func<Session, string, string, Task<bool>> _onPairing;
    private readonly Handshake _hs;
    private readonly Channel<(byte[] Frame, TaskCompletionSource? Done)> _outbox =
        Channel.CreateUnbounded<(byte[], TaskCompletionSource?)>(new UnboundedChannelOptions { SingleReader = true });
    private readonly object _sendLock = new();
    private readonly CancellationTokenSource _stop = new();

    private SecureCodec? _codec;
    private uint _seq;
    private long _lastReceivedTicks = Environment.TickCount64;
    private bool _closed, _localConfirmed, _remoteConfirmed;
    private int _stateValue = (int)SessionState.Connecting;

    public bool Initiator { get; }
    public string? ExpectedPeerId { get; }
    public string? RemoteHost { get; }
    public string? PeerId { get; private set; }
    public string PeerName { get; private set; } = "";
    public byte[] PeerKey { get; private set; } = Array.Empty<byte>();
    public int PeerPort { get; private set; }
    public string PeerVersion { get; private set; } = "0";
    public bool NeedsPairing { get; private set; }
    public double? LatencyMs { get; private set; }
    public Exception? CloseReason { get; private set; }
    public SessionState State => (SessionState)Volatile.Read(ref _stateValue);

    public Session(Stream stream, bool initiator, Identity identity, TrustedStore trusted, int listenPort, string appVersion,
                   Action<Session, Message> onMessage, Action<Session, SessionState> onState,
                   Func<Session, string, string, Task<bool>> onPairing, string? expectedPeerId = null, string? remoteHost = null)
    {
        _stream = stream;
        Initiator = initiator;
        _identity = identity;
        _trusted = trusted;
        _listenPort = listenPort;
        _appVersion = appVersion;
        _onMessage = onMessage;
        _onState = onState;
        _onPairing = onPairing;
        ExpectedPeerId = expectedPeerId;
        RemoteHost = remoteHost;
        _hs = new Handshake(initiator ? Handshake.Initiator : Handshake.Responder, identity.Seed);
    }

    private void SetState(SessionState s)
    {
        while (true)
        {
            var current = Volatile.Read(ref _stateValue);
            if (current == (int)SessionState.Closed || current == (int)s) return;
            if (Interlocked.CompareExchange(ref _stateValue, (int)s, current) != current) continue;
            _onState(this, s);
            return;
        }
    }

    // ---- lifecycle ---------------------------------------------------------------------------

    public async Task RunAsync()
    {
        var writer = Task.Run(WriterLoopAsync);
        Task? heartbeat = null;
        try
        {
            SetState(SessionState.Handshaking);
            EnqueueRaw(_hs.OwnHello);
            var frames = new FrameBuffer();
            _hs.ReceiveHello(await ReadFrameAsync(frames, Wire.MaxHandshakeFrame));
            EnqueueRaw(_hs.MakeAuth());
            _codec = _hs.ReceiveAuth(await ReadFrameAsync(frames, Wire.MaxHandshakeFrame));
            PeerKey = _hs.PeerIdentity!;
            PeerId = _hs.PeerDeviceId;
            if (PeerId == _identity.DeviceId) throw new InvalidOperationException("connected to ourselves");
            if (ExpectedPeerId is not null && ExpectedPeerId != PeerId) throw new InvalidOperationException("unexpected peer");

            _ = SendInternal(MsgType.Hello, new Hello(_identity.Name, _identity.DeviceId, _trusted.IsTrusted(PeerKey), _listenPort, _appVersion).Encode());
            heartbeat = Task.Run(HeartbeatLoopAsync);
            while (!_closed)
            {
                var frame = await ReadFrameAsync(frames, Wire.MaxFrame);
                HandleFrame(frame);
            }
        }
        catch (Exception e) when (e is HandshakeException or ProtocolException or InvalidOperationException or IOException
                                       or ObjectDisposedException or System.Net.Sockets.SocketException or EndOfStreamException)
        {
            CloseReason = e;
        }
        finally
        {
            await CloseAsync();
            try { await writer; } catch { /* the writer ends with the stream */ }
            if (heartbeat is not null) { try { await heartbeat; } catch { } }
        }
    }

    public Task CloseAsync()
    {
        lock (_sendLock)
        {
            if (_closed) return Task.CompletedTask;
            _closed = true;
        }
        _outbox.Writer.TryComplete();
        _stop.Cancel();
        try { _stream.Dispose(); } catch { /* already gone */ }
        Interlocked.Exchange(ref _stateValue, (int)SessionState.Closed);
        _onState(this, SessionState.Closed);
        return Task.CompletedTask;
    }

    // ---- reading -----------------------------------------------------------------------------

    private async Task<byte[]> ReadFrameAsync(FrameBuffer frames, int limit)
    {
        var buffer = new byte[64 * 1024];
        while (true)
        {
            var frame = frames.NextFrame(limit);
            if (frame is not null) return frame;
            var n = await _stream.ReadAsync(buffer);
            if (n == 0) throw new EndOfStreamException();
            Volatile.Write(ref _lastReceivedTicks, Environment.TickCount64);
            frames.Feed(buffer.AsSpan(0, n));
        }
    }

    private void HandleFrame(byte[] frame)
    {
        var plain = _codec!.Open(frame);
        Message msg;
        try { msg = Wire.DecodeMessage(plain); }
        catch (UnknownMessageTypeException) { return; } // a newer peer: skip it, don't drop the link
        if (!Wire.IsHandshakePhase(msg.Type) && State != SessionState.Connected)
            throw new InvalidOperationException("data before pairing completed");
        HandleMessage(msg);
    }

    private void HandleMessage(Message msg)
    {
        switch (msg.Type)
        {
            case MsgType.Hello:
            {
                var hello = Hello.Decode(msg.Payload);
                if (hello.DeviceId != PeerId) throw new InvalidOperationException("id mismatch");
                PeerName = hello.Name;
                PeerPort = hello.Port;
                PeerVersion = hello.AppVersion;
                NeedsPairing = !(_trusted.IsTrusted(PeerKey) && hello.TrustsYou);
                if (NeedsPairing)
                {
                    SetState(SessionState.Pairing);
                    _ = Task.Run(AskPairingAsync);
                }
                else
                {
                    _localConfirmed = true;
                    _ = SendInternal(MsgType.PairConfirm, Array.Empty<byte>());
                    CompleteIfReady();
                }
                break;
            }
            case MsgType.PairConfirm:
                _remoteConfirmed = true;
                CompleteIfReady();
                break;
            case MsgType.PairReject:
                throw new InvalidOperationException("pairing rejected by peer");
            case MsgType.Heartbeat:
            {
                if (msg.Payload.Length < 9) throw new ProtocolException("short heartbeat");
                var stamp = BinaryPrimitives.ReadUInt64BigEndian(msg.Payload.AsSpan(1));
                if (msg.Payload[0] == 0)
                {
                    var pong = new byte[9];
                    pong[0] = 1;
                    BinaryPrimitives.WriteUInt64BigEndian(pong.AsSpan(1), stamp);
                    SendInternal(MsgType.Heartbeat, pong);
                }
                else
                {
                    LatencyMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - (long)stamp;
                }
                break;
            }
            default:
                _onMessage(this, msg);
                break;
        }
    }

    private async Task AskPairingAsync()
    {
        bool ok;
        try { ok = await _onPairing(this, PeerName, _hs.Sas ?? "").WaitAsync(PairingTimeout); }
        catch (TimeoutException) { ok = false; }
        catch (Exception) { ok = false; }
        if (_closed) return;
        if (ok)
        {
            _localConfirmed = true;
            try { _ = SendInternal(MsgType.PairConfirm, Array.Empty<byte>()); } catch (InvalidOperationException) { return; }
            CompleteIfReady();
        }
        else
        {
            try { _ = SendInternal(MsgType.PairReject, Array.Empty<byte>()); await Task.Delay(200); } catch (InvalidOperationException) { }
            await CloseAsync();
        }
    }

    private void CompleteIfReady()
    {
        if (!_localConfirmed || !_remoteConfirmed || State is SessionState.Connected or SessionState.Closed) return;
        if (NeedsPairing && PeerId is not null) _trusted.Trust(PeerId, PeerName, PeerKey);
        SetState(SessionState.Connected);
    }

    // ---- writing -----------------------------------------------------------------------------

    private void EnqueueRaw(byte[] body) => _outbox.Writer.TryWrite((Wire.Frame(body), null));

    /// <summary>Seals and enqueues under one lock so the encryption counter always matches wire order.</summary>
    private Task SendInternal(MsgType type, byte[] payload)
    {
        lock (_sendLock)
        {
            if (_closed || _codec is null) throw new InvalidOperationException("not connected");
            if (!Wire.IsHandshakePhase(type) && State != SessionState.Connected) throw new InvalidOperationException("not connected");
            var plain = Wire.EncodeMessage(type, _seq++, payload);
            var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!_outbox.Writer.TryWrite((Wire.Frame(_codec.Seal(plain)), done))) throw new InvalidOperationException("not connected");
            return done.Task;
        }
    }

    /// <summary>Fire and forget. Returns false if the session can't carry the message right now.</summary>
    public bool Send(MsgType type, byte[] payload)
    {
        try { SendInternal(type, payload); return true; }
        catch (InvalidOperationException) { return false; }
    }

    /// <summary>Sends and waits until the bytes have been written: backpressure for file chunks.</summary>
    public Task SendDrainAsync(MsgType type, byte[] payload) => SendInternal(type, payload);

    private async Task WriterLoopAsync()
    {
        try
        {
            await foreach (var (frame, done) in _outbox.Reader.ReadAllAsync())
            {
                await _stream.WriteAsync(frame);
                await _stream.FlushAsync();
                done?.TrySetResult();
            }
        }
        catch (Exception e)
        {
            CloseReason ??= e;
            await CloseAsync();
        }
        finally
        {
            while (_outbox.Reader.TryRead(out var item)) item.Done?.TrySetException(new IOException("session closed"));
        }
    }

    private async Task HeartbeatLoopAsync()
    {
        using var timer = new PeriodicTimer(HeartbeatInterval);
        while (!_closed)
        {
            try { if (!await timer.WaitForNextTickAsync(_stop.Token)) return; }
            catch (OperationCanceledException) { return; }
            if (Environment.TickCount64 - Volatile.Read(ref _lastReceivedTicks) > HeartbeatTimeout.TotalMilliseconds)
            {
                CloseReason = new TimeoutException("heartbeat timeout");
                await CloseAsync();
                return;
            }
            var ping = new byte[9];
            BinaryPrimitives.WriteUInt64BigEndian(ping.AsSpan(1), (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
            Send(MsgType.Heartbeat, ping);
        }
    }
}
