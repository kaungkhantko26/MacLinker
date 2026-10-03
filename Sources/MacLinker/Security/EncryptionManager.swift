import Foundation
import CryptoKit

enum HandshakeError: Error {
    case malformedHello
    case wrongRole
    case badSignature
    case weakSharedSecret
    case outOfOrder
}

/// Authenticated key exchange used before any MacLinker message is exchanged.
///
/// 1. Both sides send `Hello = "MLNK" | version | identityPub(32) | ephemeralPub(32)`.
/// 2. Each side hashes `initiatorHello || responderHello` into a transcript and signs it with its
///    long-term Ed25519 identity key (plus a role byte so the two signatures can't be swapped).
/// 3. Session keys come from X25519(ephemeral, ephemeral) via HKDF, salted with the transcript.
///    One key per direction, so a reflected frame never decrypts.
/// 4. A short authentication string (SAS) is derived from the transcript. For first-time pairing both
///    users compare it; a man-in-the-middle ends up with different transcripts and therefore a
///    different code on each Mac.
final class Handshake {
    enum Role: UInt8 { case initiator = 1, responder = 2
        var other: Role { self == .initiator ? .responder : .initiator }
    }

    static let helloLength = 4 + 1 + 32 + 32

    let role: Role
    private let identity: Curve25519.Signing.PrivateKey
    private let ephemeral: Curve25519.KeyAgreement.PrivateKey

    let ownHello: Data
    private(set) var peerIdentity: Data?
    private var peerEphemeral: Data?
    private var transcript: Data?

    /// `ephemeral` is injectable only so tests can produce reproducible vectors; production uses a fresh key.
    init(role: Role, identity: Curve25519.Signing.PrivateKey,
         ephemeral: Curve25519.KeyAgreement.PrivateKey = Curve25519.KeyAgreement.PrivateKey()) {
        self.role = role
        self.identity = identity
        self.ephemeral = ephemeral
        var w = ByteWriter()
        w.u32(K.protocolMagic)
        w.u8(K.protocolVersion)
        w.bytes(identity.publicKey.rawRepresentation)
        w.bytes(ephemeral.publicKey.rawRepresentation)
        ownHello = w.data
    }

    var peerDeviceID: String? { peerIdentity.map(IdentityManager.deviceID(for:)) }

    func receiveHello(_ data: Data) throws {
        guard data.count == Self.helloLength else { throw HandshakeError.malformedHello }
        var r = ByteReader(data)
        guard try r.u32() == K.protocolMagic, try r.u8() == K.protocolVersion else {
            throw HandshakeError.malformedHello
        }
        peerIdentity = try r.bytes(32)
        peerEphemeral = try r.bytes(32)
        let initiatorHello = role == .initiator ? ownHello : data
        let responderHello = role == .initiator ? data : ownHello
        var t = Data("maclinker-v1-transcript".utf8)
        t.append(initiatorHello)
        t.append(responderHello)
        transcript = Data(SHA256.hash(data: t))
    }

    /// Our signature over the transcript. Only valid after `receiveHello`.
    func makeAuth() throws -> Data {
        guard let transcript else { throw HandshakeError.outOfOrder }
        return try identity.signature(for: transcript + [role.rawValue])
    }

    /// Verifies the peer's signature and returns the symmetric channel.
    func receiveAuth(_ signature: Data) throws -> SecureCodec {
        guard let transcript, let peerIdentity, let peerEphemeral else { throw HandshakeError.outOfOrder }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: peerIdentity)
        guard key.isValidSignature(signature, for: transcript + [role.other.rawValue]) else {
            throw HandshakeError.badSignature
        }
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerEphemeral)
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: peerKey)
        // X25519 with a low-order point yields all zeroes; refuse it.
        guard secret.withUnsafeBytes({ $0.contains(where: { $0 != 0 }) }) else {
            throw HandshakeError.weakSharedSecret
        }
        func derive(_ label: String) -> SymmetricKey {
            secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: transcript,
                                           sharedInfo: Data(label.utf8), outputByteCount: 32)
        }
        let i2r = derive("maclinker-v1-initiator-to-responder")
        let r2i = derive("maclinker-v1-responder-to-initiator")
        return role == .initiator ? SecureCodec(sendKey: i2r, receiveKey: r2i)
                                  : SecureCodec(sendKey: r2i, receiveKey: i2r)
    }

    /// Six-digit code both users compare when pairing. Nil until `receiveHello` has run.
    var sas: String? {
        guard let transcript else { return nil }
        let digest = SHA256.hash(data: Data("maclinker-v1-sas".utf8) + transcript)
        let value = digest.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return String(format: "%06d", value % 1_000_000)
    }
}

enum CodecError: Error { case tooShort }

/// ChaCha20-Poly1305 with an implicit, strictly increasing counter nonce.
/// TCP is ordered, so the counter doubles as replay/reorder protection: a frame that isn't the
/// next expected one fails authentication.
final class SecureCodec {
    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    private static func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce {
        var w = ByteWriter()
        w.u32(0)
        w.u64(counter)
        return try ChaChaPoly.Nonce(data: w.data)
    }

    func seal(_ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: sendKey, nonce: Self.nonce(sendCounter))
        sendCounter += 1
        return box.ciphertext + box.tag
    }

    func open(_ data: Data) throws -> Data {
        guard data.count >= 16 else { throw CodecError.tooShort }
        let split = data.endIndex - 16
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter),
                                           ciphertext: data[data.startIndex..<split],
                                           tag: data[split...])
        receiveCounter += 1
        return try ChaChaPoly.open(box, using: receiveKey)
    }
}
