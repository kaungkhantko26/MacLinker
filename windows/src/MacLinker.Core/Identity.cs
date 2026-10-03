using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace MacLinker.Core;

public static class AppPaths
{
    public static string ConfigDir()
    {
        var baseDir = Environment.GetEnvironmentVariable("MACLINKER_CONFIG")
                      ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MacLinker");
        Directory.CreateDirectory(baseDir);
        return baseDir;
    }

    public static string DownloadsDir()
    {
        var profile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var dir = Path.Combine(profile, "Downloads", "MacLinker");
        Directory.CreateDirectory(dir);
        return dir;
    }
}

/// <summary>This PC's long-term Ed25519 identity, created on first run and stored in the user's profile folder.</summary>
public sealed class Identity
{
    public byte[] Seed { get; }
    public byte[] PublicKey { get; }
    public string DeviceId => Keys.DeviceId(PublicKey);
    public string Name { get; }

    public Identity(string? directory = null, string? name = null)
    {
        directory ??= AppPaths.ConfigDir();
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "identity.key");
        if (File.Exists(path) && new FileInfo(path).Length == 32)
        {
            Seed = File.ReadAllBytes(path);
        }
        else
        {
            Seed = RandomNumberGenerator.GetBytes(32);
            File.WriteAllBytes(path, Seed);
            if (!OperatingSystem.IsWindows())
            {
                try { File.SetUnixFileMode(path, UnixFileMode.UserRead | UnixFileMode.UserWrite); } catch (IOException) { }
            }
        }
        PublicKey = Keys.PublicEd25519(Seed);
        Name = name ?? Environment.MachineName;
    }
}

public sealed class TrustedDevice
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("publicKey")] public string PublicKey { get; set; } = "";
    [JsonPropertyName("pairedAt")] public DateTimeOffset PairedAt { get; set; }
    /// <summary>Where this device sits relative to this screen: left, right, top or bottom.</summary>
    [JsonPropertyName("position")] public string? Position { get; set; }
    [JsonPropertyName("lastHost")] public string? LastHost { get; set; }
    [JsonPropertyName("lastPort")] public int? LastPort { get; set; }

    [JsonIgnore] public Edge? Edge => MacLinker.Core.EdgeExtensions.Parse(Position);
}

public sealed class TrustedStore
{
    private readonly string _path;
    private readonly object _lock = new();
    private readonly Dictionary<string, TrustedDevice> _devices = new();

    public TrustedStore(string? directory = null)
    {
        directory ??= AppPaths.ConfigDir();
        Directory.CreateDirectory(directory);
        _path = Path.Combine(directory, "trusted.json");
        try
        {
            if (File.Exists(_path))
                foreach (var d in JsonSerializer.Deserialize<List<TrustedDevice>>(File.ReadAllText(_path)) ?? new())
                    _devices[d.Id] = d;
        }
        catch (JsonException) { _devices.Clear(); }
    }

    public bool IsTrusted(ReadOnlySpan<byte> publicKey)
    {
        lock (_lock)
            return _devices.TryGetValue(Keys.DeviceId(publicKey), out var d)
                   && string.Equals(d.PublicKey, Convert.ToHexString(publicKey), StringComparison.OrdinalIgnoreCase);
    }

    public TrustedDevice? Get(string id) { lock (_lock) return _devices.GetValueOrDefault(id); }

    public IReadOnlyList<TrustedDevice> All() { lock (_lock) return _devices.Values.ToList(); }

    public void Trust(string id, string name, byte[] publicKey)
    {
        lock (_lock)
        {
            if (_devices.TryGetValue(id, out var existing)) { existing.Name = name; existing.PublicKey = Convert.ToHexString(publicKey).ToLowerInvariant(); }
            else _devices[id] = new TrustedDevice { Id = id, Name = name, PublicKey = Convert.ToHexString(publicKey).ToLowerInvariant(), PairedAt = DateTimeOffset.UtcNow };
            Save();
        }
    }

    public void Update(string id, Action<TrustedDevice> change)
    {
        lock (_lock)
        {
            if (!_devices.TryGetValue(id, out var d)) return;
            change(d);
            Save();
        }
    }

    public void Remove(string id) { lock (_lock) { _devices.Remove(id); Save(); } }

    /// <summary>Matches an id exactly, then a name exactly, then a name prefix (case-insensitive).</summary>
    public TrustedDevice? Find(string query)
    {
        lock (_lock)
        {
            var all = _devices.Values;
            return all.FirstOrDefault(d => d.Id == query.ToLowerInvariant() || string.Equals(d.Name, query, StringComparison.OrdinalIgnoreCase))
                   ?? all.FirstOrDefault(d => d.Name.StartsWith(query, StringComparison.OrdinalIgnoreCase));
        }
    }

    private void Save()
    {
        var tmp = _path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(_devices.Values.ToList(), new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, _path, overwrite: true);
    }
}
