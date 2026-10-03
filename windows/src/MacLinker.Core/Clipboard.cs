using System.Security.Cryptography;
using System.Text.Json;

namespace MacLinker.Core;

/// <summary>The clipboard message the macOS app understands: {"entries":[{"type":..., "data": base64}]}.</summary>
public static class ClipboardCodec
{
    public const string Text = "public.utf8-plain-text", Png = "public.png", Url = "public.url";
    public const int Limit = 8 * 1024 * 1024;

    public static byte[] Encode(IReadOnlyDictionary<string, byte[]> entries)
    {
        var list = entries.Select(kv => new Dictionary<string, string> { ["type"] = kv.Key, ["data"] = Convert.ToBase64String(kv.Value) });
        return JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object> { ["entries"] = list.ToList() });
    }

    public static Dictionary<string, byte[]> Decode(byte[] payload)
    {
        var result = new Dictionary<string, byte[]>();
        try
        {
            using var doc = JsonDocument.Parse(payload);
            foreach (var e in doc.RootElement.GetProperty("entries").EnumerateArray())
                result[e.GetProperty("type").GetString() ?? ""] = Convert.FromBase64String(e.GetProperty("data").GetString() ?? "");
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or FormatException or InvalidOperationException)
        {
            result.Clear();
        }
        return result;
    }
}

/// <summary>This PC's clipboard, implemented over the Windows clipboard (and a fake in tests).</summary>
public interface IClipboardBackend
{
    /// <summary>Changes whenever the clipboard content changes.</summary>
    long ChangeToken { get; }
    /// <summary>True if the owner asked for the content to be kept out of history and sync (password managers do).</summary>
    bool IsSensitive { get; }
    string? ReadText();
    byte[]? ReadPng();
    void WriteText(string text);
    void WritePng(byte[] png);
}

/// <summary>Keeps clipboards in step: text and PNG images, nothing marked sensitive, nothing over 8 MB, no echoes.</summary>
public sealed class ClipboardSync
{
    private readonly IClipboardBackend _backend;
    private readonly Action<byte[]> _broadcast;
    private readonly Func<bool> _enabled;
    private long _lastToken;
    private string _lastDigest = "";

    public ClipboardSync(IClipboardBackend backend, Action<byte[]> broadcast, Func<bool> enabled)
    {
        _backend = backend;
        _broadcast = broadcast;
        _enabled = enabled;
        _lastToken = backend.ChangeToken;
    }

    private static string Digest(byte[] data) => Convert.ToHexString(SHA256.HashData(data));

    /// <summary>Call every few hundred milliseconds.</summary>
    public void Poll()
    {
        var token = _backend.ChangeToken;
        if (token == _lastToken) return;
        _lastToken = token;
        if (!_enabled() || _backend.IsSensitive) return;

        Dictionary<string, byte[]>? entries = null;
        var png = _backend.ReadPng();
        if (png is { Length: > 0 } && png.Length <= ClipboardCodec.Limit) entries = new() { [ClipboardCodec.Png] = png };
        else if (_backend.ReadText() is { Length: > 0 } text)
        {
            var bytes = System.Text.Encoding.UTF8.GetBytes(text);
            if (bytes.Length <= ClipboardCodec.Limit) entries = new() { [ClipboardCodec.Text] = bytes };
        }
        if (entries is null) return;
        var digest = Digest(entries.Values.First());
        if (digest == _lastDigest) return;       // what we just received, or an unchanged copy
        _lastDigest = digest;
        _broadcast(ClipboardCodec.Encode(entries));
    }

    public void Receive(byte[] payload)
    {
        if (!_enabled()) return;
        var entries = ClipboardCodec.Decode(payload);
        if (entries.Sum(e => e.Value.Length) > ClipboardCodec.Limit) return;
        if (entries.TryGetValue(ClipboardCodec.Png, out var png))
        {
            _lastDigest = Digest(png);
            _backend.WritePng(png);
        }
        else
        {
            foreach (var type in new[] { ClipboardCodec.Text, ClipboardCodec.Url })
            {
                if (!entries.TryGetValue(type, out var data)) continue;
                _lastDigest = Digest(data);
                _backend.WriteText(System.Text.Encoding.UTF8.GetString(data));
                break;
            }
        }
        _lastToken = _backend.ChangeToken;       // our own write isn't a new copy
    }
}
