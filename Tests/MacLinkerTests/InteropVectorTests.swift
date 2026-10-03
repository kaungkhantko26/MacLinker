import XCTest
import CryptoKit
@testable import MacLinker

/// Reproducible byte-level vectors that other implementations (the Windows app) must match exactly.
/// Regenerate with: WRITE_VECTORS=1 swift test --filter InteropVectorTests
final class InteropVectorTests: XCTestCase {
    private func seed(_ b: UInt8) -> Data { Data(repeating: b, count: 32) }

    private func make() throws -> [String: String] {
        let idI = try Curve25519.Signing.PrivateKey(rawRepresentation: seed(1))
        let idR = try Curve25519.Signing.PrivateKey(rawRepresentation: seed(2))
        let ephI = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed(3))
        let ephR = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: seed(4))
        let i = Handshake(role: .initiator, identity: idI, ephemeral: ephI)
        let r = Handshake(role: .responder, identity: idR, ephemeral: ephR)
        try i.receiveHello(r.ownHello); try r.receiveHello(i.ownHello)
        let authI = try i.makeAuth(), authR = try r.makeAuth()
        let ci = try i.receiveAuth(authR), cr = try r.receiveAuth(authI)

        let plainI = MessageProtocol.encode(type: .mouseMove, sequence: 0, payload: MouseMovePayload(dx: 1.5, dy: -2).encode())
        let plainR = MessageProtocol.encode(type: .heartbeat, sequence: 7, payload: Data([1, 0, 0, 0, 0, 0, 0, 0, 9]))
        let sealedI0 = try ci.seal(plainI), sealedI1 = try ci.seal(plainI)
        let sealedR0 = try cr.seal(plainR)
        return [
            "initiator_identity_pub": idI.publicKey.rawRepresentation.hex,
            "responder_identity_pub": idR.publicKey.rawRepresentation.hex,
            "initiator_device_id": IdentityManager.deviceID(for: idI.publicKey.rawRepresentation),
            "initiator_hello": i.ownHello.hex, "responder_hello": r.ownHello.hex,
            "initiator_auth": authI.hex, "responder_auth": authR.hex,
            "sas": i.sas ?? "", "sas_responder": r.sas ?? "",
            "plain_initiator": plainI.hex, "plain_responder": plainR.hex,
            "sealed_initiator_0": sealedI0.hex, "sealed_initiator_1": sealedI1.hex,
            "sealed_responder_0": sealedR0.hex,
            "key_payload": KeyPayload(keyCode: 55, down: true, flags: 0x100000, autorepeat: false).encode().hex,
            "button_payload": MouseButtonPayload(button: 1, down: true, clickCount: 2).encode().hex,
            "scroll_payload": ScrollPayload(dx: -3, dy: 12, continuous: true).encode().hex,
            "control_payload": ControlPayload(edge: .right, position: 0.25).encode().hex,
            "layout_payload": LayoutPayload(peerPosition: .left, userInitiated: true).encode().hex,
        ]
    }

    func testVectorsMatchCommittedFile() throws {
        let vectors = try make()
        XCTAssertEqual(vectors["sas"], vectors["sas_responder"])
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("windows/tests/vectors.json")
        if ProcessInfo.processInfo.environment["WRITE_VECTORS"] == "1" {
            let data = try JSONSerialization.data(withJSONObject: vectors, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url)
            return
        }
        let committed = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        // Ed25519 signatures from CryptoKit are randomized, so they are verified by the other side rather than compared.
        let randomized: Set<String> = ["initiator_auth", "responder_auth"]
        func stable(_ d: [String: String]) -> [String: String] { d.filter { !randomized.contains($0.key) } }
        XCTAssertEqual(stable(committed), stable(vectors), "Swift output drifted from windows/tests/vectors.json")
    }
}
