import Foundation
import Network

/// Keeps this Mac's keyboard/mouse/audio/network info current and shares it with paired Macs, so each
/// Mac's card on Home can show the other's peripherals.
final class DeviceInfoManager: ObservableObject {
    @Published private(set) var local = DeviceInfoPayload.empty
    @Published private(set) var remote: [String: DeviceInfoPayload] = [:]
    @Published private(set) var updatedAt = Date()

    var send: ((String, MessageType, Data) -> Void)?
    var peerSupports: (String) -> Bool = { _ in false }
    var connectedPeers: () -> [String] = { [] }
    var link: () -> NWInterface? = { nil }

    private let queue = DispatchQueue(label: "maclinker.deviceinfo", qos: .utility)
    private var timer: Timer?
    private var lastAnnounced: DeviceInfoPayload?

    func start() {
        refreshLocal()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.refreshLocal() }
    }

    /// Re-reads this Mac and tells peers if anything changed (a keyboard connected, the audio output switched...).
    func refreshLocal() {
        let interface = link()
        queue.async {
            let info = DeviceInfoProvider.snapshot(link: interface)
            DispatchQueue.main.async {
                if info != self.local { self.local = info }
                self.updatedAt = Date()
                if info != self.lastAnnounced {
                    self.lastAnnounced = info
                    for peer in self.connectedPeers() { self.announce(to: peer) }
                }
            }
        }
    }

    /// The Refresh button: re-read this Mac and ask every peer for its current info.
    func refreshAll() {
        refreshLocal()
        for peer in connectedPeers() where peerSupports(peer) { send?(peer, .deviceInfoQuery, Data()) }
    }

    func announce(to peer: String) {
        guard peerSupports(peer), let data = try? JSONEncoder().encode(local) else { return }
        send?(peer, .deviceInfo, data)
    }

    func peerConnected(_ peer: String) {
        announce(to: peer)
        if peerSupports(peer) { send?(peer, .deviceInfoQuery, Data()) }
    }

    func peerDisconnected(_ peer: String) { remote[peer] = nil }

    func handle(_ message: MacLinkerMessage, from peer: String) {
        switch message.type {
        case .deviceInfo:
            if let info = try? JSONDecoder().decode(DeviceInfoPayload.self, from: message.payload) { remote[peer] = Self.sanitized(info) }
        case .deviceInfoQuery:
            announce(to: peer)
        default: break
        }
    }

    /// Peers are trusted, but this text ends up on screen: keep it short and free of control characters.
    static func sanitized(_ info: DeviceInfoPayload) -> DeviceInfoPayload {
        func clean(_ s: String, _ max: Int = 80) -> String { String(s.unicodeScalars.filter { !$0.properties.generalCategory.isControl }.prefix(max)) }
        func peripherals(_ list: [DeviceInfoPayload.Peripheral]) -> [DeviceInfoPayload.Peripheral] {
            list.prefix(8).map { .init(name: clean($0.name), transport: clean($0.transport, 20), battery: $0.battery.flatMap { (0...100).contains($0) ? $0 : nil }) }
        }
        return DeviceInfoPayload(kind: info.kind == "laptop" ? "laptop" : "desktop", model: clean(info.model, 40),
                                 osVersion: clean(info.osVersion, 40), keyboards: peripherals(info.keyboards),
                                 pointers: peripherals(info.pointers), audioOutput: info.audioOutput.map { clean($0) },
                                 network: info.network.map { clean($0, 30) })
    }
}

private extension Unicode.GeneralCategory {
    var isControl: Bool { self == .control || self == .format || self == .lineSeparator || self == .paragraphSeparator }
}
