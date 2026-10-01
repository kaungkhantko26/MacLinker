import Foundation
import Network
import Darwin

/// Tracks which physical interface the LAN is on and whether a VPN tunnel (such as Outline) is up.
///
/// Why this matters: Outline installs a system-wide tunnel (`utun*`) and routes default traffic
/// through it. Local-network traffic between two Macs must not go through that tunnel, so MacLinker pins
/// its LAN connections to the physical Wi-Fi/Ethernet interface instead of trusting the routing table.
final class NetworkPathWatcher: ObservableObject {
    @Published private(set) var lanInterface: NWInterface?
    @Published private(set) var vpnActive = false
    @Published private(set) var vpnInterfaces: [String] = []

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "maclinker.path")
    private let lock = NSLock()
    private var _lan: NWInterface?

    /// Thread-safe snapshot for use off the main queue.
    var currentLANInterface: NWInterface? { lock.lock(); defer { lock.unlock() }; return _lan }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in self?.update(path) }
        monitor.start(queue: queue)
    }

    private func update(_ path: NWPath) {
        // availableInterfaces is in the system's service-order preference.
        let lan = path.availableInterfaces.compactMap { i in Self.rank(i).map { (i, $0) } }
            .min { $0.1 < $1.1 }?.0
        let tunnels = Self.activeTunnelInterfaces()
        lock.lock(); _lan = lan; lock.unlock()
        DispatchQueue.main.async {
            self.lanInterface = lan
            self.vpnInterfaces = tunnels
            self.vpnActive = !tunnels.isEmpty
        }
    }

    /// Lower is better; nil means "not a usable LAN link" (VPN tunnels, AWDL, loopback...).
    /// A direct USB-C/Thunderbolt cable (`bridge*` or wired Ethernet) beats Wi-Fi: lower latency, no jitter.
    static func rank(_ i: NWInterface) -> Int? {
        if i.name.hasPrefix("bridge") { return 0 }
        switch i.type {
        case .wiredEthernet: return 1
        case .wifi: return 2
        default: return nil
        }
    }

    /// `utunN` interfaces that carry an IPv4 address. macOS keeps several utun devices around for
    /// system services, but those only have IPv6 link-local addresses; a VPN client adds IPv4.
    static func activeTunnelInterfaces() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var names = Set<String>()
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("utun"), let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            names.insert(name)
        }
        return names.sorted()
    }

    /// Whether `host` is a private/link-local/mDNS address that should stay on the physical LAN.
    /// Deliberately excludes 100.64/10 (CGNAT, used by mesh VPNs such as Tailscale), which lives on a tunnel.
    static func isLANHost(_ host: String) -> Bool {
        if host.hasSuffix(".local") || host.hasPrefix("fe80:") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
