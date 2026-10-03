import Foundation

enum K {
    static let appName = "MacLinker"
    static var appVersion: String { (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0" }
    /// First version that understands the brightness/volume messages. Older peers must never be sent them.
    static let systemControlMinVersion = "1.2.0"
    /// First version that understands device-info and lock-screen messages.
    static let hubMinVersion = "1.5.0"
    /// First version that understands copied-files messages.
    static let fileClipboardMinVersion = "1.6.0"
    /// Copied files are sent automatically only up to this total size; anything bigger needs Send File.
    static let fileClipboardLimit: UInt64 = 250 * 1024 * 1024
    static let bundleID = "com.maclinker.app"
    static let serviceType = "_maclinker._tcp"
    static let defaultPort: UInt16 = 52845

    static let protocolMagic: UInt32 = 0x4D4C_4E4B  // "MLNK"
    static let protocolVersion: UInt8 = 1

    /// Upper bound for one encrypted frame on the wire.
    static let maxFrameSize = 16 * 1024 * 1024
    /// Handshake frames are tiny; anything bigger before the channel is secure is hostile.
    static let maxHandshakeFrameSize = 1024

    static let heartbeatInterval: TimeInterval = 2
    static let heartbeatTimeout: TimeInterval = 8
    static let pairingTimeout: TimeInterval = 90

    static let fileChunkSize = 192 * 1024
    static let clipboardLimit = 8 * 1024 * 1024

    /// Points of outward pointer travel against a screen edge before control is handed over.
    static let defaultEdgePush: Double = 12
    /// Tags events we synthesised so our own event tap ignores them.
    static let injectedMarker: Int64 = 0x4B4C_494E

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacLinker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }

    static var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MacLinker", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
