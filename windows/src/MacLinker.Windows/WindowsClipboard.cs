using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using MacLinker.Core;
using static MacLinker.Windows.NativeMethods;

namespace MacLinker.Windows;

/// <summary>The Windows clipboard for text and images. Use it from the UI thread (the clipboard needs an STA thread).</summary>
internal sealed class WindowsClipboard : IClipboardBackend
{
    public long ChangeToken => GetClipboardSequenceNumber();

    /// <summary>Password managers mark their copies so Windows keeps them out of clipboard history; we honour the same flags.</summary>
    public bool IsSensitive
    {
        get
        {
            var data = TryGet(Clipboard.GetDataObject);
            return data is not null && (data.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing")
                                        || data.GetDataPresent("Clipboard Viewer Ignore"));
        }
    }

    public string? ReadText() => TryGet(() => Clipboard.ContainsText(TextDataFormat.UnicodeText) ? Clipboard.GetText(TextDataFormat.UnicodeText) : null);

    public byte[]? ReadPng() => TryGet(() =>
    {
        if (!Clipboard.ContainsImage()) return null;
        using var image = Clipboard.GetImage();
        if (image is null) return null;
        using var ms = new MemoryStream();
        image.Save(ms, ImageFormat.Png);
        return ms.ToArray();
    });

    public void WriteText(string text) => TryRun(() => Clipboard.SetText(text, TextDataFormat.UnicodeText));

    public void WritePng(byte[] png) => TryRun(() =>
    {
        using var ms = new MemoryStream(png);
        using var image = Image.FromStream(ms);
        Clipboard.SetImage(image);
    });

    // The clipboard can be locked by another app for a moment; retry briefly instead of failing.
    private static T? TryGet<T>(Func<T?> read)
    {
        for (var i = 0; i < 5; i++)
        {
            try { return read(); }
            catch (ExternalException) { Thread.Sleep(20); }
            catch (ThreadStateException) { return default; }
        }
        return default;
    }

    private static void TryRun(Action write) => TryGet<object>(() => { write(); return null; });
}
