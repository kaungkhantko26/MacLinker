import Foundation
import Network

enum NetworkClient {
    /// TCP parameters for MacLinker. When `interface` is set the socket is bound to it
    /// (IP_BOUND_IF), which bypasses a VPN's default route for LAN traffic.
    static func parameters(interface: NWInterface?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        tcp.connectionTimeout = 8
        let params = NWParameters(tls: nil, tcp: tcp)
        // Mark as interactive so Wi-Fi (WMM) sends our small input packets ahead of bulk traffic.
        params.serviceClass = .interactiveVoice
        if let interface { params.requiredInterface = interface }
        return params
    }

    static func makeConnection(to endpoint: NWEndpoint, interface: NWInterface?) -> NWConnection {
        NWConnection(to: endpoint, using: parameters(interface: interface))
    }

    /// Parses `host`, `host:port` or `[v6]:port`.
    static func parseAddress(_ text: String) -> NWEndpoint? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        var host = t
        var port = K.defaultPort
        if t.hasPrefix("["), let close = t.firstIndex(of: "]") {
            host = String(t[t.index(after: t.startIndex)..<close])
            let rest = t[t.index(after: close)...]
            if rest.hasPrefix(":"), let p = UInt16(rest.dropFirst()) { port = p }
        } else if t.filter({ $0 == ":" }).count == 1, let idx = t.firstIndex(of: ":"),
                  let p = UInt16(t[t.index(after: idx)...]) {
            host = String(t[..<idx])
            port = p
        }
        guard !host.isEmpty, let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        return .hostPort(host: NWEndpoint.Host(host), port: nwPort)
    }
}
