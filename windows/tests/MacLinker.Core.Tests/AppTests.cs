using System.Text;
using System.Text.Json;
using MacLinker.Core;
using Xunit;

namespace MacLinker.Core.Tests;

public class ClipboardTests
{
    private sealed class FakeClipboard : IClipboardBackend
    {
        public long ChangeToken { get; set; } = 1;
        public bool IsSensitive { get; set; }
        public string? Text { get; set; }
        public byte[]? Png { get; set; }
        public string? ReadText() => Text;
        public byte[]? ReadPng() => Png;
        public void WriteText(string text) { Text = text; ChangeToken++; }
        public void WritePng(byte[] png) { Png = png; ChangeToken++; }
    }

    [Fact]
    public void MessageFormatMatchesWhatSwiftCodableProduces()
    {
        var json = Encoding.UTF8.GetString(ClipboardCodec.Encode(new Dictionary<string, byte[]> { [ClipboardCodec.Text] = Encoding.UTF8.GetBytes("hi") }));
        Assert.Equal("""{"entries":[{"type":"public.utf8-plain-text","data":"aGk="}]}""", json);
        var swift = """{"entries":[{"data":"aGk=","type":"public.utf8-plain-text"}]}"""u8.ToArray();
        Assert.Equal("hi", Encoding.UTF8.GetString(ClipboardCodec.Decode(swift)[ClipboardCodec.Text]));
        Assert.Empty(ClipboardCodec.Decode("not json"u8.ToArray()));
    }

    [Fact]
    public void SendsOnceSkipsSensitiveAndDoesNotEchoWhatItReceived()
    {
        var sent = new List<byte[]>();
        var cb = new FakeClipboard { Text = "hello" };
        var sync = new ClipboardSync(cb, sent.Add, () => true);
        cb.ChangeToken++; sync.Poll(); sync.Poll();
        Assert.Single(sent);
        cb.IsSensitive = true; cb.Text = "hunter2"; cb.ChangeToken++; sync.Poll();
        Assert.Single(sent);                                   // a password-manager item never leaves this PC
        cb.IsSensitive = false;
        sync.Receive(ClipboardCodec.Encode(new Dictionary<string, byte[]> { [ClipboardCodec.Text] = Encoding.UTF8.GetBytes("from the Mac") }));
        Assert.Equal("from the Mac", cb.Text);
        sync.Poll();
        Assert.Single(sent);                                   // not sent straight back
    }

    [Fact]
    public void ImagesPreferredAndDisabledMeansSilent()
    {
        var sent = new List<byte[]>();
        var cb = new FakeClipboard { Text = "t", Png = new byte[] { 0x89, 0x50, 0x4E, 0x47 } };
        var enabled = true;
        var sync = new ClipboardSync(cb, sent.Add, () => enabled);
        cb.ChangeToken++; sync.Poll();
        Assert.Contains("public.png", Encoding.UTF8.GetString(sent[0]));
        enabled = false;
        cb.Png = null; cb.Text = "other"; cb.ChangeToken++; sync.Poll();
        Assert.Single(sent);
        sync.Receive(ClipboardCodec.Encode(new Dictionary<string, byte[]> { [ClipboardCodec.Text] = new byte[] { 65 } }));
        Assert.Equal("other", cb.Text);                       // switched off: ignores incoming too
    }
}

public class FileTransferTests
{
    [Fact]
    public void NamesAreSanitisedAndNeverOverwrite()
    {
        Assert.Equal("passwd", FileTransfer.SafeName("../../etc/passwd"));
        Assert.Equal("win.ini", FileTransfer.SafeName("..\\..\\win.ini"));
        Assert.Equal("file", FileTransfer.SafeName("..."));
        Assert.Equal("a_b.txt", FileTransfer.SafeName("a:b.txt"));
        Assert.Equal("_CON.txt", FileTransfer.SafeName("CON.txt"));
        Assert.Equal("_nul", FileTransfer.SafeName("nul"));
        Assert.Equal("report.pdf", FileTransfer.SafeName("C:\\Users\\me\\report.pdf"));
        Assert.Equal("file", FileTransfer.SafeName("   "));
        var dir = Wait.TempDir();
        File.WriteAllText(Path.Combine(dir, "a.txt"), "x");
        Assert.Equal(Path.Combine(dir, "a 1.txt"), FileTransfer.UniquePath(dir, "a.txt"));
    }

    [Fact]
    public void ReceivesAMacFormattedTransferAndVerifiesTheChecksum()
    {
        var dir = Wait.TempDir();
        var sent = new List<MsgType>();
        var ft = new FileTransfer((_, t, _) => { sent.Add(t); return true; }, () => true, dir);
        var id = Guid.NewGuid();
        var body = Enumerable.Range(0, 5000).Select(i => (byte)(i % 251)).ToArray();
        // The Mac's JSON uses an upper-case UUID string, and its chunks carry the id as 16 raw big-endian bytes.
        var offer = Encoding.UTF8.GetBytes($$"""{"id":"{{id.ToString().ToUpperInvariant()}}","name":"../photo.png","size":{{body.Length}}}""");
        ft.OnMessage("mac", "Mac", new Message(MsgType.FileOffer, 0, offer));
        var idBytes = id.ToByteArray(bigEndian: true);
        for (var i = 0; i < body.Length; i += 1500)
            ft.OnMessage("mac", "Mac", new Message(MsgType.FileChunk, 0, idBytes.Concat(body.Skip(i).Take(1500)).ToArray()));
        var digest = System.Security.Cryptography.SHA256.HashData(body);
        ft.OnMessage("mac", "Mac", new Message(MsgType.FileEnd, 0, idBytes.Concat(digest).ToArray()));
        Assert.Equal(body, File.ReadAllBytes(Path.Combine(dir, "photo.png")));
        Assert.Equal("done", ft.Log[0].Status);

        var bad = Guid.NewGuid();
        ft.OnMessage("mac", "Mac", new Message(MsgType.FileOffer, 0, Encoding.UTF8.GetBytes($$"""{"id":"{{bad}}","name":"x.bin","size":3}""")));
        ft.OnMessage("mac", "Mac", new Message(MsgType.FileChunk, 0, bad.ToByteArray(bigEndian: true).Concat(new byte[] { 1, 2, 3 }).ToArray()));
        ft.OnMessage("mac", "Mac", new Message(MsgType.FileEnd, 0, bad.ToByteArray(bigEndian: true).Concat(new byte[32]).ToArray()));
        Assert.False(File.Exists(Path.Combine(dir, "x.bin")));
        Assert.StartsWith("failed", ft.Log[0].Status);
    }

    [Fact]
    public void RefusesCopiedFileBatchesAndDisabledSharing()
    {
        var dir = Wait.TempDir();
        var sent = new List<MsgType>();
        var enabled = true;
        var ft = new FileTransfer((_, t, _) => { sent.Add(t); return true; }, () => enabled, dir);
        var clipboardOffer = Encoding.UTF8.GetBytes($$"""{"id":"{{Guid.NewGuid()}}","name":"c.txt","size":1,"clipboard":true}""");
        ft.OnMessage("mac", "Mac", new Message(MsgType.FileOffer, 0, clipboardOffer));
        enabled = false;
        ft.OnMessage("mac", "Mac", new Message(MsgType.FileOffer, 0, Encoding.UTF8.GetBytes($$"""{"id":"{{Guid.NewGuid()}}","name":"d.txt","size":1}""")));
        Assert.Equal(new[] { MsgType.FileAbort, MsgType.FileAbort }, sent);
        Assert.Empty(Directory.GetFiles(dir));
    }
}

public class AppTests
{
    private static MacLinkerApp NewApp(string name, FakeInjector? injector = null)
    {
        var dir = Wait.TempDir();
        return new MacLinkerApp(new AppOptions { Port = 0, UseDiscovery = false, ConfigDir = dir, Name = name, DownloadsDir = Path.Combine(dir, "dl") },
                                injector ?? new FakeInjector(), (1000, 800));
    }

    [Fact]
    public void LayoutSyncRules()
    {
        var store = new TrustedStore(Wait.TempDir());
        store.Trust("bbbb", "B", new byte[32]);
        Assert.True(MacLinkerApp.ApplyRemoteLayout(store, "aaaa", "bbbb", new LayoutPayload(Edge.Right, true)));
        Assert.Equal("left", store.Get("bbbb")!.Position);
        Assert.False(MacLinkerApp.ApplyRemoteLayout(store, "aaaa", "bbbb", new LayoutPayload(Edge.Top, false)));   // larger sender loses
        Assert.True(MacLinkerApp.ApplyRemoteLayout(store, "cccc", "bbbb", new LayoutPayload(Edge.Top, false)));    // smaller sender wins
        Assert.Equal("bottom", store.Get("bbbb")!.Position);
        Assert.False(MacLinkerApp.ApplyRemoteLayout(store, "aaaa", "bbbb", new LayoutPayload(null, false)));
    }

    [Fact]
    public async Task TwoAppsPairMirrorLayoutHandControlAndTransferAFile()
    {
        var injA = new FakeInjector();
        var injB = new FakeInjector();
        using var a = NewApp("PC-A", injA);
        using var b = NewApp("PC-B", injB);
        a.Start(); b.Start();
        a.PairingRequested += p => { _ = Task.Run(() => a.ConfirmPairing(true)); };
        b.PairingRequested += p => { _ = Task.Run(() => b.ConfirmPairing(true)); };

        Assert.Contains("connecting", await a.ConnectAsync("127.0.0.1", b.Port));
        await Wait.Until(() => a.Devices().Any(d => d.Connected) && b.Devices().Any(d => d.Connected));
        Assert.True(a.Trusted.Get(b.Identity.DeviceId) is not null && b.Trusted.Get(a.Identity.DeviceId) is not null);

        // A says B sits to its right -> B records A on its left, and control can pass across.
        a.SetPosition(b.Identity.DeviceId, Edge.Right);
        await Wait.Until(() => b.Trusted.Get(a.Identity.DeviceId)!.Position == "left");
        Assert.Equal(b.Identity.DeviceId, a.Control.EdgePeers[Edge.Right]);
        a.Control.Toggle();
        await Wait.Until(() => b.Control.State.Kind == ControlKind.Controlled);
        a.Control.OnLocalMotion((10, 10), 5, 0);
        a.Control.OnLocalButton(MouseButtonKind.Left, true);
        await Wait.Until(() => injB.Events.Contains("button Left down"));
        a.Control.ReleaseToLocal();
        await Wait.Until(() => b.Control.State.Kind == ControlKind.Local);

        // a file A -> B
        var src = Path.Combine(Wait.TempDir(), "note.txt");
        File.WriteAllText(src, "hello from A");
        Assert.Equal("done", await a.SendFileAsync(b.Identity.DeviceId, src));
        await Wait.Until(() => b.Files.Log.Count > 0 && b.Files.Log[0].Status == "done");
        Assert.Equal("hello from A", File.ReadAllText(Path.Combine(b.Options.DownloadsDir!, "note.txt")));
    }

    [Fact]
    public async Task ReconnectsWithoutPairingAgain()
    {
        using var a = NewApp("PC-A");
        using var b = NewApp("PC-B");
        a.Start(); b.Start();
        var prompts = 0;
        a.PairingRequested += p => { Interlocked.Increment(ref prompts); _ = Task.Run(() => a.ConfirmPairing(true)); };
        b.PairingRequested += p => { _ = Task.Run(() => b.ConfirmPairing(true)); };
        await a.ConnectAsync("127.0.0.1", b.Port);
        await Wait.Until(() => a.Devices().Any(d => d.Connected));
        await a.ForgetAsync(b.Identity.DeviceId);                       // drops the link and unpairs on A only
        await Wait.Until(() => !a.Devices().Any(d => d.Connected));
        await a.ConnectAsync("127.0.0.1", b.Port);                      // B still trusts A, A forgot B: needs a code again
        await Wait.Until(() => a.Devices().Any(d => d.Connected));
        Assert.Equal(2, prompts);
    }
}
