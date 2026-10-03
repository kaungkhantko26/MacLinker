using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using Makaretu.Dns;

namespace MacLinker.Core;

public sealed record FoundDevice(string Id, string Name, string Host, int Port);

/// <summary>Bonjour / mDNS: finds Macs advertising _maclinker._tcp and advertises this PC the same way.</summary>
public sealed class Discovery : IDisposable
{
    public const string ServiceType = "_maclinker._tcp";

    private sealed class Partial
    {
        public int Port;
        public string? Target;
        public string? Id;
        public string Name = "";
        public bool Reported;
    }

    private readonly string _ownId;
    private readonly object _lock = new();
    private readonly Dictionary<string, Partial> _instances = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, List<IPAddress>> _addresses = new(StringComparer.OrdinalIgnoreCase);
    private MulticastService? _mdns;
    private ServiceDiscovery? _sd;

    public event Action<FoundDevice>? Found;
    public event Action<string>? Lost;
    public event Action<string>? Log;

    public Discovery(string ownDeviceId) => _ownId = ownDeviceId;

    public void Start(string instanceName, string deviceId, int port)
    {
        _mdns = new MulticastService();
        _sd = new ServiceDiscovery(_mdns);
        var profile = new ServiceProfile(SafeLabel(instanceName), ServiceType, (ushort)port);
        profile.AddProperty("id", deviceId);
        profile.AddProperty("v", "1");
        _sd.Advertise(profile);
        _mdns.NetworkInterfaceDiscovered += (_, _) => _sd.QueryServiceInstances(ServiceType);
        _sd.ServiceInstanceDiscovered += (_, e) =>
        {
            _mdns.SendQuery(e.ServiceInstanceName, type: DnsType.SRV);
            _mdns.SendQuery(e.ServiceInstanceName, type: DnsType.TXT);
        };
        _sd.ServiceInstanceShutdown += (_, e) =>
        {
            string? id;
            lock (_lock) { _instances.TryGetValue(e.ServiceInstanceName.ToString(), out var p); id = p?.Id; _instances.Remove(e.ServiceInstanceName.ToString()); }
            if (id is not null) Lost?.Invoke(id);
        };
        _mdns.AnswerReceived += (_, e) => OnAnswer(e.Message);
        try { _mdns.Start(); }
        catch (Exception ex) when (ex is SocketException or IOException)
        {
            Log?.Invoke($"discovery unavailable: {ex.Message}");
        }
    }

    /// <summary>mDNS labels can't contain dots; spaces and unicode are fine.</summary>
    public static string SafeLabel(string name)
    {
        var clean = name.Replace(".", " ").Trim();
        return string.IsNullOrEmpty(clean) ? "Windows PC" : (clean.Length > 60 ? clean[..60] : clean);
    }

    private void OnAnswer(Makaretu.Dns.Message message)
    {
        var records = message.Answers.Concat(message.AdditionalRecords).ToList();
        var toReport = new List<FoundDevice>();
        lock (_lock)
        {
            foreach (var srv in records.OfType<SRVRecord>().Where(r => r.Name.ToString().Contains(ServiceType)))
            {
                var p = _instances.TryGetValue(srv.Name.ToString(), out var existing) ? existing : _instances[srv.Name.ToString()] = new Partial();
                p.Port = srv.Port;
                p.Target = srv.Target.ToString();
                p.Name = srv.Name.Labels.FirstOrDefault() ?? "";
                _mdns?.SendQuery(srv.Target, type: DnsType.A);
            }
            foreach (var txt in records.OfType<TXTRecord>().Where(r => r.Name.ToString().Contains(ServiceType)))
            {
                var p = _instances.TryGetValue(txt.Name.ToString(), out var existing) ? existing : _instances[txt.Name.ToString()] = new Partial();
                p.Id = txt.Strings.Select(s => s.Split('=', 2)).Where(kv => kv.Length == 2 && kv[0] == "id").Select(kv => kv[1]).FirstOrDefault() ?? p.Id;
                p.Name = txt.Name.Labels.FirstOrDefault() ?? p.Name;
            }
            foreach (var a in records.OfType<AddressRecord>().Where(r => r.Address.AddressFamily == AddressFamily.InterNetwork))
            {
                var key = a.Name.ToString();
                if (!_addresses.TryGetValue(key, out var list)) _addresses[key] = list = new List<IPAddress>();
                if (!list.Contains(a.Address)) list.Add(a.Address);
            }
            foreach (var p in _instances.Values)
            {
                if (p.Reported || p.Id is null || p.Id == _ownId || p.Port == 0 || p.Target is null) continue;
                if (!_addresses.TryGetValue(p.Target, out var addrs) || addrs.Count == 0) continue;
                var host = PickAddress(addrs, LocalIPv4());
                if (host is null) continue;
                p.Reported = true;
                toReport.Add(new FoundDevice(p.Id, p.Name, host.ToString(), p.Port));
            }
        }
        foreach (var d in toReport) Found?.Invoke(d);
    }

    public static List<IPAddress> LocalIPv4()
    {
        var list = new List<IPAddress>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up))
                foreach (var ua in nic.GetIPProperties().UnicastAddresses.Where(u => u.Address.AddressFamily == AddressFamily.InterNetwork))
                    if (!IPAddress.IsLoopback(ua.Address)) list.Add(ua.Address);
        }
        catch (NetworkInformationException) { }
        return list;
    }

    /// <summary>Prefers an address on the same /16 as one of ours, so a direct cable link (169.254.x.x) beats routing out and back.</summary>
    public static IPAddress? PickAddress(IReadOnlyList<IPAddress> candidates, IReadOnlyList<IPAddress> local)
    {
        if (candidates.Count == 0) return null;
        foreach (var c in candidates)
            foreach (var l in local)
            {
                var (a, b) = (c.GetAddressBytes(), l.GetAddressBytes());
                if (a[0] == b[0] && a[1] == b[1]) return c;
            }
        return candidates[0];
    }

    public void Dispose()
    {
        try { _sd?.Unadvertise(); } catch { }
        _sd?.Dispose();
        _mdns?.Dispose();
    }
}
