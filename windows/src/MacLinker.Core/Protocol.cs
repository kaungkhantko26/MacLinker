using System.Buffers.Binary;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MacLinker.Core;

/// <summary>Message types shared with the macOS app. Types this build doesn't know are ignored, never fatal.</summary>
public enum MsgType : byte
{
    Hello = 1,
    PairConfirm = 2,
    PairReject = 3,
    Heartbeat = 4,

    MouseMove = 10,
    MouseButton = 11,
    Scroll = 12,
    KeyEvent = 13,
    FlagsChanged = 14,

    EnterControl = 20,
    ReleaseControl = 21,
    Layout = 22,

    Clipboard = 30,

    FileOffer = 40,
    FileChunk = 41,
    FileEnd = 42,
    FileAbort = 43,
}

public enum Edge : byte
{
    Left = 1,
    Right = 2,
    Top = 3,
    Bottom = 4,
}

public static class EdgeExtensions
{
    public static Edge Opposite(this Edge e) => e switch
    {
        Edge.Left => Edge.Right,
        Edge.Right => Edge.Left,
        Edge.Top => Edge.Bottom,
        _ => Edge.Top,
    };

    public static string Title(this Edge e) => e.ToString().ToLowerInvariant();

    public static Edge? Parse(string? text) =>
        Enum.TryParse<Edge>(text?.Trim(), ignoreCase: true, out var e) && Enum.IsDefined(e) ? e : null;
}

public class ProtocolException : Exception
{
    public ProtocolException(string message) : base(message) { }
}

public sealed class UnknownMessageTypeException : ProtocolException
{
    public byte Code { get; }
    public UnknownMessageTypeException(byte code) : base($"unknown message type {code}") => Code = code;
}

public sealed record Message(MsgType Type, uint Sequence, byte[] Payload);

public static class Wire
{
    public const uint Magic = 0x4D4C4E4B; // "MLNK"
    public const byte Version = 1;
    public const int HeaderSize = 14;
    public const int MaxFrame = 16 * 1024 * 1024;
    public const int MaxHandshakeFrame = 1024;

    private static readonly HashSet<MsgType> HandshakePhase = new() { MsgType.Hello, MsgType.PairConfirm, MsgType.PairReject, MsgType.Heartbeat };

    public static bool IsHandshakePhase(MsgType t) => HandshakePhase.Contains(t);

    /// <summary>magic(4) version(1) type(1) sequence(4) payloadLength(4) payload, big-endian.</summary>
    public static byte[] EncodeMessage(MsgType type, uint sequence, ReadOnlySpan<byte> payload)
    {
        var buf = new byte[HeaderSize + payload.Length];
        BinaryPrimitives.WriteUInt32BigEndian(buf, Magic);
        buf[4] = Version;
        buf[5] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(6), sequence);
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(10), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(HeaderSize));
        return buf;
    }

    public static Message DecodeMessage(ReadOnlySpan<byte> data)
    {
        if (data.Length < HeaderSize) throw new ProtocolException("short message");
        if (BinaryPrimitives.ReadUInt32BigEndian(data) != Magic) throw new ProtocolException("bad magic");
        if (data[4] != Version) throw new ProtocolException($"unsupported version {data[4]}");
        var raw = data[5];
        var seq = BinaryPrimitives.ReadUInt32BigEndian(data[6..]);
        var length = BinaryPrimitives.ReadUInt32BigEndian(data[10..]);
        if (data.Length - HeaderSize != length) throw new ProtocolException("length mismatch");
        if (!Enum.IsDefined(typeof(MsgType), raw)) throw new UnknownMessageTypeException(raw);
        return new Message((MsgType)raw, seq, data[HeaderSize..].ToArray());
    }

    /// <summary>Length-prefixes a body for the TCP stream.</summary>
    public static byte[] Frame(ReadOnlySpan<byte> body)
    {
        var buf = new byte[4 + body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(buf, (uint)body.Length);
        body.CopyTo(buf.AsSpan(4));
        return buf;
    }
}

/// <summary>Reassembles length-prefixed frames from a byte stream.</summary>
public sealed class FrameBuffer
{
    private byte[] _buf = new byte[4096];
    private int _len;

    public void Feed(ReadOnlySpan<byte> data)
    {
        if (_len + data.Length > _buf.Length) Array.Resize(ref _buf, Math.Max(_buf.Length * 2, _len + data.Length));
        data.CopyTo(_buf.AsSpan(_len));
        _len += data.Length;
    }

    public byte[]? NextFrame(int limit)
    {
        if (_len < 4) return null;
        var length = BinaryPrimitives.ReadUInt32BigEndian(_buf);
        if (length > (uint)limit) throw new ProtocolException("frame too large");
        if (_len < 4 + length) return null;
        var body = _buf.AsSpan(4, (int)length).ToArray();
        var rest = _len - 4 - (int)length;
        Buffer.BlockCopy(_buf, 4 + (int)length, _buf, 0, rest);
        _len = rest;
        return body;
    }
}

// ---- payloads ---------------------------------------------------------------------------------

public sealed record Hello(
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("deviceID")] string DeviceId,
    [property: JsonPropertyName("trustsYou")] bool TrustsYou,
    [property: JsonPropertyName("port")] int Port,
    [property: JsonPropertyName("appVersion")] string AppVersion)
{
    public byte[] Encode() => JsonSerializer.SerializeToUtf8Bytes(this);

    public static Hello Decode(ReadOnlySpan<byte> data)
    {
        try
        {
            using var doc = JsonDocument.Parse(data.ToArray());
            var r = doc.RootElement;
            var name = r.GetProperty("name").GetString() ?? "";
            return new Hello(name.Length > 80 ? name[..80] : name, r.GetProperty("deviceID").GetString() ?? "",
                r.GetProperty("trustsYou").GetBoolean(),
                r.TryGetProperty("port", out var p) && p.TryGetInt32(out var port) ? port : 0,
                r.TryGetProperty("appVersion", out var v) ? v.GetString() ?? "0" : "0");
        }
        catch (Exception e) when (e is JsonException or KeyNotFoundException or InvalidOperationException or FormatException)
        {
            throw new ProtocolException($"bad hello: {e.Message}");
        }
    }
}

public readonly record struct MouseMovePayload(float Dx, float Dy)
{
    public byte[] Encode()
    {
        var b = new byte[8];
        BinaryPrimitives.WriteSingleBigEndian(b, Dx);
        BinaryPrimitives.WriteSingleBigEndian(b.AsSpan(4), Dy);
        return b;
    }

    public static MouseMovePayload Decode(ReadOnlySpan<byte> d)
    {
        if (d.Length < 8) throw new ProtocolException("short mouse move");
        return new(BinaryPrimitives.ReadSingleBigEndian(d), BinaryPrimitives.ReadSingleBigEndian(d[4..]));
    }
}

public readonly record struct MouseButtonPayload(byte Button, bool Down, byte ClickCount)
{
    public byte[] Encode() => new[] { Button, (byte)(Down ? 1 : 0), ClickCount };

    public static MouseButtonPayload Decode(ReadOnlySpan<byte> d)
    {
        if (d.Length < 3) throw new ProtocolException("short mouse button");
        return new(d[0], d[1] != 0, d[2]);
    }
}

public readonly record struct ScrollPayload(int Dx, int Dy, bool Continuous)
{
    public byte[] Encode()
    {
        var b = new byte[9];
        BinaryPrimitives.WriteInt32BigEndian(b, Dx);
        BinaryPrimitives.WriteInt32BigEndian(b.AsSpan(4), Dy);
        b[8] = (byte)(Continuous ? 1 : 0);
        return b;
    }

    public static ScrollPayload Decode(ReadOnlySpan<byte> d)
    {
        if (d.Length < 9) throw new ProtocolException("short scroll");
        return new(BinaryPrimitives.ReadInt32BigEndian(d), BinaryPrimitives.ReadInt32BigEndian(d[4..]), d[8] != 0);
    }
}

/// <summary>KeyCode is a macOS virtual key code; Flags is a CGEventFlags bit set.</summary>
public readonly record struct KeyPayload(ushort KeyCode, bool Down, ulong Flags, bool Autorepeat)
{
    public byte[] Encode()
    {
        var b = new byte[12];
        BinaryPrimitives.WriteUInt16BigEndian(b, KeyCode);
        b[2] = (byte)(Down ? 1 : 0);
        BinaryPrimitives.WriteUInt64BigEndian(b.AsSpan(3), Flags);
        b[11] = (byte)(Autorepeat ? 1 : 0);
        return b;
    }

    public static KeyPayload Decode(ReadOnlySpan<byte> d)
    {
        if (d.Length < 12) throw new ProtocolException("short key");
        return new(BinaryPrimitives.ReadUInt16BigEndian(d), d[2] != 0, BinaryPrimitives.ReadUInt64BigEndian(d[3..]), d[11] != 0);
    }
}

public readonly record struct ControlPayload(Edge Edge, float Position)
{
    public byte[] Encode()
    {
        var b = new byte[5];
        b[0] = (byte)Edge;
        BinaryPrimitives.WriteSingleBigEndian(b.AsSpan(1), Position);
        return b;
    }

    public static ControlPayload Decode(ReadOnlySpan<byte> d)
    {
        if (d.Length < 5) throw new ProtocolException("short control");
        if (!Enum.IsDefined(typeof(Edge), d[0])) throw new ProtocolException("bad edge");
        return new((Edge)d[0], BinaryPrimitives.ReadSingleBigEndian(d[1..]));
    }
}

/// <summary>Where the sender places the receiver relative to its own screen (null = unset).</summary>
public readonly record struct LayoutPayload(Edge? PeerPosition, bool UserInitiated)
{
    public byte[] Encode() => new[] { (byte)(PeerPosition ?? 0), (byte)(UserInitiated ? 1 : 0) };

    public static LayoutPayload Decode(ReadOnlySpan<byte> d)
    {
        if (d.Length < 2) throw new ProtocolException("short layout");
        if (d[0] != 0 && !Enum.IsDefined(typeof(Edge), d[0])) throw new ProtocolException("bad edge");
        return new(d[0] == 0 ? null : (Edge)d[0], d[1] != 0);
    }
}

public sealed record FileOffer(
    [property: JsonPropertyName("id")] Guid Id,
    [property: JsonPropertyName("name")] string Name,
    [property: JsonPropertyName("size")] ulong Size,
    [property: JsonPropertyName("clipboard")] bool? Clipboard = null);
