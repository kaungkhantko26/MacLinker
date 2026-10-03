using System.Text.Json;

namespace MacLinker.Windows;

/// <summary>Looks for a newer release on GitHub and says so. It never downloads or installs anything by itself.</summary>
internal static class UpdateChecker
{
    public const string Repo = "kaungkhantko26/MacLinker";

    public static string CurrentVersion =>
        (System.Reflection.Assembly.GetExecutingAssembly().GetName().Version ?? new Version(0, 1, 0)).ToString(3);

    public static async Task<(string Tag, string Url)?> NewerReleaseAsync()
    {
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
            http.DefaultRequestHeaders.UserAgent.ParseAdd("MacLinker-Windows");
            var json = await http.GetStringAsync($"https://api.github.com/repos/{Repo}/releases/latest");
            using var doc = JsonDocument.Parse(json);
            var tag = doc.RootElement.GetProperty("tag_name").GetString() ?? "";
            var url = doc.RootElement.GetProperty("html_url").GetString() ?? $"https://github.com/{Repo}/releases/latest";
            var hasWindowsBuild = doc.RootElement.GetProperty("assets").EnumerateArray()
                .Any(a => (a.GetProperty("name").GetString() ?? "").Contains("Windows", StringComparison.OrdinalIgnoreCase));
            return hasWindowsBuild && IsNewer(tag, CurrentVersion) ? (tag, url) : null;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException or KeyNotFoundException) { return null; }
    }

    public static bool IsNewer(string remote, string local)
    {
        static int[] Parts(string s) => s.TrimStart('v', 'V').Split('.').Select(p => int.TryParse(p, out var n) ? n : 0).ToArray();
        var (a, b) = (Parts(remote), Parts(local));
        for (var i = 0; i < Math.Max(a.Length, b.Length); i++)
        {
            int x = i < a.Length ? a[i] : 0, y = i < b.Length ? b[i] : 0;
            if (x != y) return x > y;
        }
        return false;
    }
}
