using System.Security.Cryptography;
using System.Text.Json;

namespace MacLinker.Core;

public sealed class TransferRecord
{
    public Guid Id { get; init; }
    public string Name { get; init; } = "";
    public ulong Size { get; init; }
    public ulong Transferred { get; set; }
    public bool Sending { get; init; }
    public string Peer { get; init; } = "";
    public string Status { get; set; } = "active"; // active | done | failed: ...
    public string? Path { get; set; }
}

/// <summary>File transfer compatible with the macOS app: offer, 192 KB chunks, end with SHA-256.</summary>
public sealed class FileTransfer
{
    public const int ChunkSize = 192 * 1024;

    private sealed class Incoming
    {
        public required FileStream Handle { get; init; }
        public required string Path { get; init; }
        public required ulong Expected { get; init; }
        public required TransferRecord Record { get; init; }
        public IncrementalHash Hash { get; } = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public ulong Received { get; set; }
    }

    private readonly Func<string, MsgType, byte[], bool> _send;
    private readonly Func<bool> _enabled;
    private readonly string? _directory;
    private readonly Dictionary<Guid, Incoming> _incoming = new();
    private readonly HashSet<Guid> _cancelled = new();
    private readonly object _lock = new();

    public List<TransferRecord> Log { get; } = new();
    public event Action? Changed;

    public FileTransfer(Func<string, MsgType, byte[], bool> send, Func<bool> enabled, string? directory = null)
    {
        _send = send;
        _enabled = enabled;
        _directory = directory;
    }

    private string Dir() { var d = _directory ?? AppPaths.DownloadsDir(); Directory.CreateDirectory(d); return d; }

    private static readonly char[] WindowsInvalid = "<>:\"/\\|?*".ToCharArray();
    private static readonly HashSet<string> WindowsReserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    /// <summary>A name that is safe to create on Windows: no path parts, no illegal characters, no reserved device names.
    /// Uses Windows' rules explicitly so the result is the same wherever it is computed.</summary>
    public static string SafeName(string name)
    {
        var last = name.Split('/', '\\').LastOrDefault() ?? "";
        var clean = new string(last.Select(c => c < 32 || WindowsInvalid.Contains(c) ? '_' : c).ToArray()).Trim(' ', '.');
        if (clean.Length == 0) return "file";
        var stem = clean.Contains('.') ? clean[..clean.IndexOf('.')] : clean;
        return WindowsReserved.Contains(stem) ? "_" + clean : clean;
    }

    public static string UniquePath(string directory, string name)
    {
        var path = Path.Combine(directory, SafeName(name));
        var stem = Path.GetFileNameWithoutExtension(path);
        var ext = Path.GetExtension(path);
        for (var n = 1; File.Exists(path); n++) path = Path.Combine(directory, $"{stem} {n}{ext}");
        return path;
    }

    private static byte[] IdBytes(Guid id) => id.ToByteArray(bigEndian: true);

    // ---- receiving ---------------------------------------------------------------------------

    public void OnMessage(string peer, string peerName, Message msg)
    {
        try { lock (_lock) OnMessageLocked(peer, peerName, msg); }
        catch (Exception e) when (e is IOException or JsonException or ProtocolException or UnauthorizedAccessException or ArgumentException)
        {
            // one bad transfer must not take the app down
        }
        Changed?.Invoke();
    }

    private void OnMessageLocked(string peer, string peerName, Message msg)
    {
        switch (msg.Type)
        {
            case MsgType.FileOffer:
            {
                var offer = JsonSerializer.Deserialize<FileOffer>(msg.Payload) ?? throw new ProtocolException("bad offer");
                // Copied-file batches from the Mac need a feature this build doesn't have: refuse rather than misfile them.
                if (!_enabled() || offer.Clipboard == true) { _send(peer, MsgType.FileAbort, IdBytes(offer.Id)); return; }
                var path = UniquePath(Dir(), offer.Name);
                var handle = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                var rec = new TransferRecord { Id = offer.Id, Name = System.IO.Path.GetFileName(path), Size = offer.Size, Peer = peerName, Path = path };
                Log.Insert(0, rec);
                _incoming[offer.Id] = new Incoming { Handle = handle, Path = path, Expected = offer.Size, Record = rec };
                return;
            }
            case MsgType.FileChunk:
            {
                if (msg.Payload.Length < 16) throw new ProtocolException("short chunk");
                if (!_incoming.TryGetValue(new Guid(msg.Payload.AsSpan(0, 16), bigEndian: true), out var f)) return;
                var chunk = msg.Payload.AsSpan(16);
                f.Received += (ulong)chunk.Length;
                if (f.Received > f.Expected) { Abort(f.Record.Id, "more data than announced"); return; }
                f.Handle.Write(chunk);
                f.Hash.AppendData(chunk);
                f.Record.Transferred = f.Received;
                return;
            }
            case MsgType.FileEnd:
            {
                if (msg.Payload.Length < 48) throw new ProtocolException("short end");
                var id = new Guid(msg.Payload.AsSpan(0, 16), bigEndian: true);
                if (!_incoming.Remove(id, out var f)) return;
                f.Handle.Dispose();
                var ok = f.Received == f.Expected && f.Hash.GetHashAndReset().AsSpan().SequenceEqual(msg.Payload.AsSpan(16, 32));
                if (ok) { f.Record.Status = "done"; f.Record.Transferred = f.Record.Size; }
                else { TryDelete(f.Path); f.Record.Status = "failed: checksum mismatch"; }
                return;
            }
            case MsgType.FileAbort:
            {
                if (msg.Payload.Length < 16) throw new ProtocolException("short abort");
                var id = new Guid(msg.Payload.AsSpan(0, 16), bigEndian: true);
                _cancelled.Add(id);
                if (_incoming.ContainsKey(id)) Abort(id, "cancelled by sender");
                return;
            }
        }
    }

    private void Abort(Guid id, string why)
    {
        if (!_incoming.Remove(id, out var f)) return;
        f.Handle.Dispose();
        TryDelete(f.Path);
        f.Record.Status = $"failed: {why}";
    }

    private static void TryDelete(string path) { try { File.Delete(path); } catch (IOException) { } }

    public void PeerDisconnected()
    {
        lock (_lock) foreach (var id in _incoming.Keys.ToList()) Abort(id, "connection lost");
        Changed?.Invoke();
    }

    // ---- sending -----------------------------------------------------------------------------

    /// <summary>Sends a file with backpressure (each chunk waits for the previous one to be written).</summary>
    public async Task<string> SendFileAsync(Session session, string path, string peerName)
    {
        var info = new FileInfo(path);
        var id = Guid.NewGuid();
        var rec = new TransferRecord { Id = id, Name = info.Name, Size = (ulong)info.Length, Sending = true, Peer = peerName, Path = path };
        lock (_lock) Log.Insert(0, rec);
        Changed?.Invoke();
        string result;
        try
        {
            session.Send(MsgType.FileOffer, JsonSerializer.SerializeToUtf8Bytes(new FileOffer(id, info.Name, (ulong)info.Length)));
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using var file = File.OpenRead(path);
            var buffer = new byte[ChunkSize];
            int n;
            while ((n = await file.ReadAsync(buffer)) > 0)
            {
                lock (_lock) if (_cancelled.Remove(id)) { rec.Status = "failed: cancelled by receiver"; Changed?.Invoke(); return rec.Status; }
                hash.AppendData(buffer, 0, n);
                var payload = new byte[16 + n];
                IdBytes(id).CopyTo(payload, 0);
                Buffer.BlockCopy(buffer, 0, payload, 16, n);
                await session.SendDrainAsync(MsgType.FileChunk, payload);
                rec.Transferred += (ulong)n;
                Changed?.Invoke();
            }
            var end = new byte[48];
            IdBytes(id).CopyTo(end, 0);
            hash.GetHashAndReset().CopyTo(end, 16);
            await session.SendDrainAsync(MsgType.FileEnd, end);
            result = "done";
        }
        catch (Exception e) when (e is IOException or InvalidOperationException or UnauthorizedAccessException)
        {
            result = $"failed: {e.Message}";
        }
        rec.Status = result;
        Changed?.Invoke();
        return result;
    }
}
