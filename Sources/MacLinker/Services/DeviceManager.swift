import Foundation

enum DeviceManager {
    /// Merges what Bonjour sees, what we've paired with, and what is connected into one list.
    static func merge(discovered: [String: DiscoveredDevice], trusted: [TrustedDevice],
                      peers: [String: ConnectionManager.Peer]) -> [Device] {
        var out: [String: Device] = [:]
        for t in trusted {
            out[t.id] = Device(id: t.id, name: t.name, status: .offline, isTrusted: true,
                               position: t.position, latency: nil)
        }
        for d in discovered.values {
            if out[d.id] != nil { out[d.id]?.status = .nearby }
            else { out[d.id] = Device(id: d.id, name: d.name, status: .nearby, isTrusted: false, position: nil, latency: nil) }
        }
        for p in peers.values {
            var dev = out[p.id] ?? Device(id: p.id, name: p.name, status: .offline, isTrusted: false,
                                          position: nil, latency: nil)
            dev.name = p.name.isEmpty ? dev.name : p.name
            dev.latency = p.latency
            switch p.state {
            case .connected: dev.status = .connected
            case .pairing: dev.status = .pairing
            case .connecting: dev.status = .connecting
            }
            out[p.id] = dev
        }
        return out.values.sorted {
            $0.status.rawValue != $1.status.rawValue ? $0.status.rawValue < $1.status.rawValue
                                                     : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}
