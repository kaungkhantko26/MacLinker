import Foundation
import CryptoKit

/// This Mac's long-term identity: an Ed25519 key pair created on first launch.
/// The private key lives in Application Support with 0600 permissions. (A file rather than the
/// keychain, so ad-hoc re-signed dev builds don't trigger a keychain prompt on every rebuild.)
final class IdentityManager {
    static let shared = IdentityManager()

    let signingKey: Curve25519.Signing.PrivateKey

    init(directory: URL = K.supportDirectory) {
        let url = directory.appendingPathComponent("identity.key")
        if let raw = try? Data(contentsOf: url),
           let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) {
            signingKey = key
        } else {
            let key = Curve25519.Signing.PrivateKey()
            try? key.rawRepresentation.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            signingKey = key
        }
    }

    var publicKey: Data { signingKey.publicKey.rawRepresentation }
    var deviceID: String { Self.deviceID(for: publicKey) }
    var deviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

    /// Stable 16-hex-character ID: the first 8 bytes of SHA-256 over the public key.
    /// Because it is derived from the key, a peer cannot claim someone else's ID.
    static func deviceID(for publicKey: Data) -> String {
        Data(SHA256.hash(data: publicKey)).prefix(8).hex
    }
}
