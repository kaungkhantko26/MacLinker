import Foundation
import Network

/// Keeps trusted Macs connected. Dials from Bonjour results first, then from the last address
/// that worked, which is what keeps things running when a VPN breaks multicast discovery.
final class ReconnectManager {
    private let identity: IdentityManager
    private let trusted: TrustedDevices
    private let discovery: DeviceDiscoveryManager
    private let connections: ConnectionManager
    private let settings: Settings
    private let paths: NetworkPathWatcher

    private var timer: Timer?
    private var offlineSince: [String: Date] = [:]
    private var nextAttempt: [String: Date] = [:]
    private var failures: [String: Int] = [:]

    init(identity: IdentityManager, trusted: TrustedDevices, discovery: DeviceDiscoveryManager,
         connections: ConnectionManager, settings: Settings, paths: NetworkPathWatcher) {
        self.identity = identity
        self.trusted = trusted
        self.discovery = discovery
        self.connections = connections
        self.settings = settings
        self.paths = paths
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func reset(_ id: String) {
        failures[id] = nil
        nextAttempt[id] = nil
        offlineSince[id] = nil
    }

    private func tick() {
        let now = Date()
        for device in trusted.devices {
            if connections.hasSession(for: device.id) { reset(device.id); continue }
            let since = offlineSince[device.id] ?? now
            offlineSince[device.id] = since
            // The smaller ID dials immediately; the other side waits so they don't collide,
            // but still dials if the first side never shows up.
            if identity.deviceID > device.id, now.timeIntervalSince(since) < 6 { continue }
            if let next = nextAttempt[device.id], now < next { continue }
            guard let (endpoint, interface) = target(for: device) else { continue }
            connections.connect(to: endpoint, expectedID: device.id, interface: interface)
            let n = failures[device.id, default: 0]
            failures[device.id] = n + 1
            nextAttempt[device.id] = now.addingTimeInterval(min(30, 2 * pow(1.6, Double(n))))
        }
    }

    private func target(for device: TrustedDevice) -> (NWEndpoint, NWInterface?)? {
        if let found = discovery.discovered[device.id] {
            return (found.endpoint, settings.pinToLAN ? (found.interface ?? paths.lanInterface) : nil)
        }
        guard let host = device.lastHost,
              let port = NWEndpoint.Port(rawValue: device.lastPort ?? K.defaultPort) else { return nil }
        let pin = settings.pinToLAN && NetworkPathWatcher.isLANHost(host)
        return (.hostPort(host: NWEndpoint.Host(host), port: port), pin ? paths.lanInterface : nil)
    }
}
