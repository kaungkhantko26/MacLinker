import Foundation
import Network

struct DiscoveredDevice: Identifiable, Equatable {
    let id: String
    var name: String
    var endpoint: NWEndpoint
    var interface: NWInterface?
}

/// A Mac as the UI sees it: discovered, trusted, connected, or any mix.
struct Device: Identifiable, Equatable {
    enum Status: Int { case connected, pairing, connecting, nearby, offline }

    let id: String
    var name: String
    var status: Status
    var isTrusted: Bool
    var position: Edge?
    var latency: Double?
    var link: String?
}
