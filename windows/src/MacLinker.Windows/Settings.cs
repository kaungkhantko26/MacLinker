using System.Text.Json;
using MacLinker.Core;
using Microsoft.Win32;

namespace MacLinker.Windows;

/// <summary>User settings, saved next to the identity in %APPDATA%\MacLinker\settings.json.</summary>
internal sealed class UserSettings
{
    public bool InputSharing { get; set; } = true;
    public bool ClipboardSharing { get; set; } = true;
    public bool FileSharing { get; set; } = true;
    public bool SwapModifiers { get; set; } = true;
    /// <summary>Scales this PC's mouse movement on the Mac. Raw device counts feel slower than Windows' accelerated pointer.</summary>
    public double MouseSpeed { get; set; } = 1.5;

    private static string FilePath => Path.Combine(AppPaths.ConfigDir(), "settings.json");

    public static UserSettings Load()
    {
        try { if (File.Exists(FilePath)) return JsonSerializer.Deserialize<UserSettings>(File.ReadAllText(FilePath)) ?? new(); }
        catch (Exception e) when (e is JsonException or IOException) { }
        return new();
    }

    public void Save()
    {
        try { File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true })); }
        catch (IOException) { }
    }

    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public static bool StartsWithWindows
    {
        get { using var k = Registry.CurrentUser.OpenSubKey(RunKey); return k?.GetValue("MacLinker") is string; }
        set
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
            if (k is null) return;
            if (value) k.SetValue("MacLinker", $"\"{Environment.ProcessPath}\" --minimized");
            else k.DeleteValue("MacLinker", throwOnMissingValue: false);
        }
    }
}
