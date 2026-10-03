using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math.EC.Rfc7748;
using Org.BouncyCastle.Math.EC.Rfc8032;

namespace MacLinker.Core;

public class HandshakeException : Exception
{
    public HandshakeException(string message) : base(message) { }
}

public static class Keys
{
    public static byte[] PublicEd25519(byte[] seed)
    {
        var pk = new byte[Ed25519.PublicKeySize];
        Ed25519.GeneratePublicKey(seed, 0, pk, 0);
        return pk;
    }

    public static byte[] PublicX25519(byte[] secret)
    {
        var pk = new byte[X25519.PointSize];
        X25519.ScalarMultBase(secret, 0, pk, 0);
        return pk;
    }

    /// <summary>First 8 bytes of SHA-256 over the identity public key, hex. A peer can't claim someone else's id.</summary>
    public static string DeviceId(ReadOnlySpan<byte> publicKey) => Convert.ToHexString(SHA256.HashData(publicKey)[..8]).ToLowerInvariant();
}

/// <summary>ChaCha20-Poly1305 with an implicit, strictly increasing counter nonce (replay and reorder safe).</summary>
public sealed class SecureCodec
{
    private readonly byte[] _sendKey, _receiveKey;
    private ulong _sendCounter, _receiveCounter;
    private readonly object _lock = new();

    public SecureCodec(byte[] sendKey, byte[] receiveKey)
    {
        _sendKey = sendKey;
        _receiveKey = receiveKey;
    }

    private static byte[] Nonce(ulong counter)
    {
        var n = new byte[12];
        BinaryPrimitives.WriteUInt64BigEndian(n.AsSpan(4), counter);
        return n;
    }

    private static byte[] Run(bool encrypt, byte[] key, byte[] nonce, byte[] input)
    {
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        cipher.Init(encrypt, new AeadParameters(new KeyParameter(key), 128, nonce, null));
        var output = new byte[cipher.GetOutputSize(input.Length)];
        var n = cipher.ProcessBytes(input, 0, input.Length, output, 0);
        cipher.DoFinal(output, n);
        return output;
    }

    public byte[] Seal(byte[] plaintext)
    {
        lock (_lock) return Run(true, _sendKey, Nonce(_sendCounter++), plaintext);
    }

    public byte[] Open(byte[] data)
    {
        if (data.Length < 16) throw new HandshakeException("ciphertext too short");
        lock (_lock)
        {
            try
            {
                var plain = Run(false, _receiveKey, Nonce(_receiveCounter), data);
                _receiveCounter++;
                return plain;
            }
            catch (Org.BouncyCastle.Crypto.InvalidCipherTextException)
            {
                throw new HandshakeException("authentication failed");
            }
        }
    }
}

/// <summary>
/// Authenticated key exchange, byte-compatible with the macOS app: both sides send
/// hello = "MLNK" | version | identityPub(32) | ephemeralPub(32); each signs the transcript with its identity key;
/// session keys come from X25519 via HKDF-SHA256 salted with the transcript; a short code derived from the
/// transcript lets both users confirm there is no man-in-the-middle.
/// </summary>
public sealed class Handshake
{
    public const byte Initiator = 1, Responder = 2;
    public const int HelloLength = 4 + 1 + 32 + 32;

    private readonly byte _role;
    private readonly byte[] _identitySeed;
    private readonly byte[] _ephemeral;
    private byte[]? _peerEphemeral;
    private byte[]? _transcript;

    public byte[] OwnHello { get; }
    public byte[]? PeerIdentity { get; private set; }
    public string? PeerDeviceId => PeerIdentity is null ? null : Keys.DeviceId(PeerIdentity);

    public Handshake(byte role, byte[] identitySeed, byte[]? ephemeralSecret = null)
    {
        _role = role;
        _identitySeed = identitySeed;
        _ephemeral = ephemeralSecret ?? RandomNumberGenerator.GetBytes(32);
        var hello = new byte[HelloLength];
        BinaryPrimitives.WriteUInt32BigEndian(hello, Wire.Magic);
        hello[4] = Wire.Version;
        Keys.PublicEd25519(identitySeed).CopyTo(hello, 5);
        Keys.PublicX25519(_ephemeral).CopyTo(hello, 37);
        OwnHello = hello;
    }

    public void ReceiveHello(byte[] data)
    {
        if (data.Length != HelloLength || BinaryPrimitives.ReadUInt32BigEndian(data) != Wire.Magic || data[4] != Wire.Version)
            throw new HandshakeException("malformed hello");
        PeerIdentity = data[5..37];
        _peerEphemeral = data[37..69];
        var initiatorHello = _role == Initiator ? OwnHello : data;
        var responderHello = _role == Initiator ? data : OwnHello;
        _transcript = SHA256.HashData(Concat(Encoding.UTF8.GetBytes("maclinker-v1-transcript"), initiatorHello, responderHello));
    }

    public byte[] MakeAuth()
    {
        if (_transcript is null) throw new HandshakeException("out of order");
        var message = Concat(_transcript, new[] { _role });
        var sig = new byte[Ed25519.SignatureSize];
        Ed25519.Sign(_identitySeed, 0, message, 0, message.Length, sig, 0);
        return sig;
    }

    public SecureCodec ReceiveAuth(byte[] signature)
    {
        if (_transcript is null || PeerIdentity is null || _peerEphemeral is null) throw new HandshakeException("out of order");
        var other = _role == Initiator ? Responder : Initiator;
        var message = Concat(_transcript, new[] { other });
        if (signature.Length != Ed25519.SignatureSize || !Ed25519.Verify(signature, 0, PeerIdentity, 0, message, 0, message.Length))
            throw new HandshakeException("bad signature");
        var shared = new byte[X25519.PointSize];
        if (!X25519.CalculateAgreement(_ephemeral, 0, _peerEphemeral, 0, shared, 0))
            throw new HandshakeException("weak shared secret"); // low-order point
        var i2r = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, _transcript, Encoding.UTF8.GetBytes("maclinker-v1-initiator-to-responder"));
        var r2i = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, _transcript, Encoding.UTF8.GetBytes("maclinker-v1-responder-to-initiator"));
        return _role == Initiator ? new SecureCodec(i2r, r2i) : new SecureCodec(r2i, i2r);
    }

    /// <summary>Six digits both users compare when pairing. Null until the hello has been received.</summary>
    public string? Sas
    {
        get
        {
            if (_transcript is null) return null;
            var digest = SHA256.HashData(Concat(Encoding.UTF8.GetBytes("maclinker-v1-sas"), _transcript));
            return (BinaryPrimitives.ReadUInt32BigEndian(digest) % 1_000_000).ToString("D6");
        }
    }

    private static byte[] Concat(params byte[][] parts)
    {
        var result = new byte[parts.Sum(p => p.Length)];
        var offset = 0;
        foreach (var p in parts) { p.CopyTo(result, offset); offset += p.Length; }
        return result;
    }
}
