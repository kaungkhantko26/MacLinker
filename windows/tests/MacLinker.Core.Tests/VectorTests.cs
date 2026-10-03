using System.Text.Json;
using MacLinker.Core;
using Xunit;

namespace MacLinker.Core.Tests;

/// <summary>The C# implementation must produce, and accept, exactly the bytes the macOS app's Swift code does.</summary>
public class VectorTests
{
    private static readonly Dictionary<string, string> V =
        JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText("vectors.json"))!;

    private static byte[] H(string key) => Convert.FromHexString(V[key]);
    private static byte[] Seed(byte b) => Enumerable.Repeat(b, 32).ToArray();

    private static (Handshake i, Handshake r) Pair() =>
        (new Handshake(Handshake.Initiator, Seed(1), Seed(3)), new Handshake(Handshake.Responder, Seed(2), Seed(4)));

    [Fact]
    public void HelloAndSasMatchSwift()
    {
        var (i, r) = Pair();
        Assert.Equal(V["initiator_hello"], Convert.ToHexString(i.OwnHello).ToLowerInvariant());
        Assert.Equal(V["responder_hello"], Convert.ToHexString(r.OwnHello).ToLowerInvariant());
        i.ReceiveHello(r.OwnHello);
        r.ReceiveHello(i.OwnHello);
        Assert.Equal(V["sas"], i.Sas);
        Assert.Equal(V["sas"], r.Sas);
        Assert.Equal(V["initiator_device_id"], Keys.DeviceId(H("initiator_identity_pub")));
        Assert.Equal(Keys.DeviceId(H("responder_identity_pub")), i.PeerDeviceId);
    }

    [Fact]
    public void SwiftSignaturesVerifyAndCiphertextMatchesByteForByte()
    {
        var (i, r) = Pair();
        i.ReceiveHello(r.OwnHello);
        r.ReceiveHello(i.OwnHello);
        // CryptoKit's Ed25519 signatures are randomized, so they are verified rather than compared.
        var ci = i.ReceiveAuth(H("responder_auth"));
        var cr = r.ReceiveAuth(H("initiator_auth"));
        var plainI = H("plain_initiator");
        Assert.Equal(V["sealed_initiator_0"], Convert.ToHexString(ci.Seal(plainI)).ToLowerInvariant());
        Assert.Equal(V["sealed_initiator_1"], Convert.ToHexString(ci.Seal(plainI)).ToLowerInvariant());
        Assert.Equal(V["sealed_responder_0"], Convert.ToHexString(cr.Seal(H("plain_responder"))).ToLowerInvariant());
        // ...and what Swift sealed, we can open.
        Assert.Equal(plainI, cr.Open(H("sealed_initiator_0")));
        Assert.Equal(plainI, cr.Open(H("sealed_initiator_1")));
        Assert.Equal(H("plain_responder"), ci.Open(H("sealed_responder_0")));
    }

    [Fact]
    public void OurOwnSignaturesAreAcceptedAndEncryptionRoundTrips()
    {
        var a = new Handshake(Handshake.Initiator, Seed(5));
        var b = new Handshake(Handshake.Responder, Seed(6));
        a.ReceiveHello(b.OwnHello);
        b.ReceiveHello(a.OwnHello);
        var ca = a.ReceiveAuth(b.MakeAuth());
        var cb = b.ReceiveAuth(a.MakeAuth());
        Assert.Equal(a.Sas, b.Sas);
        Assert.Equal(new byte[] { 1, 2, 3 }, cb.Open(ca.Seal(new byte[] { 1, 2, 3 })));
    }

    [Fact]
    public void ForgedSignatureReplayAndTamperingAreRejected()
    {
        var (i, r) = Pair();
        i.ReceiveHello(r.OwnHello);
        r.ReceiveHello(i.OwnHello);
        Assert.Throws<HandshakeException>(() => i.ReceiveAuth(new byte[64]));
        var ci = i.ReceiveAuth(H("responder_auth"));
        var cr = r.ReceiveAuth(H("initiator_auth"));
        var frame = ci.Seal(new byte[] { 9 });
        cr.Open(frame);
        Assert.Throws<HandshakeException>(() => cr.Open(frame));              // replay
        var bad = ci.Seal(new byte[] { 9 });
        bad[0] ^= 1;
        Assert.Throws<HandshakeException>(() => cr.Open(bad));                // tampered
    }

    [Fact]
    public void ManInTheMiddleSeesADifferentCode()
    {
        var alice = new Handshake(Handshake.Initiator, Seed(1));
        var bob = new Handshake(Handshake.Responder, Seed(2));
        var toAlice = new Handshake(Handshake.Responder, Seed(7));
        var toBob = new Handshake(Handshake.Initiator, Seed(8));
        alice.ReceiveHello(toAlice.OwnHello); toAlice.ReceiveHello(alice.OwnHello);
        bob.ReceiveHello(toBob.OwnHello); toBob.ReceiveHello(bob.OwnHello);
        Assert.NotEqual(alice.Sas, bob.Sas);
    }

    [Fact]
    public void PayloadEncodingsMatchSwift()
    {
        Assert.Equal(V["plain_initiator"], Convert.ToHexString(Wire.EncodeMessage(MsgType.MouseMove, 0, new MouseMovePayload(1.5f, -2f).Encode())).ToLowerInvariant());
        Assert.Equal(V["plain_responder"], Convert.ToHexString(Wire.EncodeMessage(MsgType.Heartbeat, 7, new byte[] { 1, 0, 0, 0, 0, 0, 0, 0, 9 })).ToLowerInvariant());
        Assert.Equal(V["key_payload"], Convert.ToHexString(new KeyPayload(55, true, 0x100000, false).Encode()).ToLowerInvariant());
        Assert.Equal(V["button_payload"], Convert.ToHexString(new MouseButtonPayload(1, true, 2).Encode()).ToLowerInvariant());
        Assert.Equal(V["scroll_payload"], Convert.ToHexString(new ScrollPayload(-3, 12, true).Encode()).ToLowerInvariant());
        Assert.Equal(V["control_payload"], Convert.ToHexString(new ControlPayload(Edge.Right, 0.25f).Encode()).ToLowerInvariant());
        Assert.Equal(V["layout_payload"], Convert.ToHexString(new LayoutPayload(Edge.Left, true).Encode()).ToLowerInvariant());
    }

    [Fact]
    public void DecodeRoundTripsAndRejectsGarbage()
    {
        Assert.Equal(new KeyPayload(55, true, 0x100000, true), KeyPayload.Decode(new KeyPayload(55, true, 0x100000, true).Encode()));
        Assert.Equal(Edge.Top, ControlPayload.Decode(new ControlPayload(Edge.Top, 0.5f).Encode()).Edge);
        Assert.Null(LayoutPayload.Decode(new LayoutPayload(null, false).Encode()).PeerPosition);
        Assert.Throws<ProtocolException>(() => KeyPayload.Decode(new byte[3]));
        Assert.Throws<ProtocolException>(() => ControlPayload.Decode(new byte[] { 9, 0, 0, 0, 0 }));
        var msg = Wire.EncodeMessage(MsgType.Heartbeat, 1, Array.Empty<byte>());
        msg[5] = 250;
        Assert.Throws<UnknownMessageTypeException>(() => Wire.DecodeMessage(msg));
        msg[0] = 0;
        Assert.Throws<ProtocolException>(() => Wire.DecodeMessage(msg));
    }

    [Fact]
    public void FrameBufferHandlesSplitCoalescedAndOversizeFrames()
    {
        var buf = new FrameBuffer();
        var all = Wire.Frame(new byte[] { 1, 2, 3 }).Concat(Wire.Frame(new byte[] { 4, 5 })).ToArray();
        buf.Feed(all.AsSpan(0, 2));
        Assert.Null(buf.NextFrame(100));
        buf.Feed(all.AsSpan(2));
        Assert.Equal(new byte[] { 1, 2, 3 }, buf.NextFrame(100));
        Assert.Equal(new byte[] { 4, 5 }, buf.NextFrame(100));
        Assert.Null(buf.NextFrame(100));
        buf.Feed(Wire.Frame(new byte[2000]));
        Assert.Throws<ProtocolException>(() => buf.NextFrame(Wire.MaxHandshakeFrame));
    }

    [Fact]
    public void HelloJsonMatchesWhatTheMacAppSends()
    {
        var swiftStyle = """{"appVersion":"1.7.0","deviceID":"34750f98bd59fcfc","name":"K’s Mac Mini","port":52845,"trustsYou":false}"""u8.ToArray();
        var hello = Hello.Decode(swiftStyle);
        Assert.Equal(("K’s Mac Mini", "34750f98bd59fcfc", false, 52845, "1.7.0"), (hello.Name, hello.DeviceId, hello.TrustsYou, hello.Port, hello.AppVersion));
        var roundTrip = Hello.Decode(hello.Encode());
        Assert.Equal(hello, roundTrip);
        Assert.Throws<ProtocolException>(() => Hello.Decode("{}"u8.ToArray()));
    }
}
