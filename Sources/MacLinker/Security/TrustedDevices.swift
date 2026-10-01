import Foundation

struct TrustedDevice: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var publicKey: Data
    var pairedAt: Date
    var lastConnected: Date?
    /// Where this Mac sits relative to ours; nil means keyboard/mouse sharing is not positioned.
    var position: Edge?
    /// Last address we reached it at. Lets us reconnect when Bonjour is blocked (e.g. by a VPN).
    var lastHost: String?
    var lastPort: UInt16?
}

final class TrustedDevices: ObservableObject {
    @Published private(set) var devices: [TrustedDevice] = []

    private let fileURL: URL
    private let lock = NSLock()
    private var keysByID: [String: Data] = [:]

    init(directory: URL = K.supportDirectory) {
        fileURL = directory.appendingPathComponent("trusted-devices.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.maclinker.decode([TrustedDevice].self, from: data) {
            devices = decoded
        }
        refreshLookup()
    }

    /// Safe to call from any thread (used by the network queue during the handshake).
    func isTrusted(publicKey: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keysByID[IdentityManager.deviceID(for: publicKey)] == publicKey
    }

    func device(_ id: String) -> TrustedDevice? { devices.first { $0.id == id } }

    func trust(id: String, name: String, publicKey: Data) {
        if let i = devices.firstIndex(where: { $0.id == id }) {
            devices[i].name = name
            devices[i].publicKey = publicKey
        } else {
            devices.append(TrustedDevice(id: id, name: name, publicKey: publicKey, pairedAt: Date()))
        }
        persist()
    }

    func update(_ id: String, _ change: (inout TrustedDevice) -> Void) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        var copy = devices[i]
        change(&copy)
        guard copy != devices[i] else { return }
        devices[i] = copy
        persist()
    }

    func remove(_ id: String) {
        devices.removeAll { $0.id == id }
        persist()
    }

    private func persist() {
        refreshLookup()
        if let data = try? JSONEncoder.maclinker.encode(devices) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func refreshLookup() {
        lock.lock(); defer { lock.unlock() }
        keysByID = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0.publicKey) })
    }
}

extension JSONEncoder {
    static let maclinker: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
}

extension JSONDecoder {
    static let maclinker: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}
