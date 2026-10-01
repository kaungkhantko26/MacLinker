import XCTest
import CryptoKit
@testable import MacLinker

final class HandshakeTests: XCTestCase {
    private func pair() throws -> (Handshake, Handshake, SecureCodec, SecureCodec) {
        let a = Handshake(role: .initiator, identity: Curve25519.Signing.PrivateKey())
        let b = Handshake(role: .responder, identity: Curve25519.Signing.PrivateKey())
        try a.receiveHello(b.ownHello)
        try b.receiveHello(a.ownHello)
        let ca = try a.receiveAuth(try b.makeAuth())
        let cb = try b.receiveAuth(try a.makeAuth())
        return (a, b, ca, cb)
    }

    func testBothSidesDeriveSameSASAndTalk() throws {
        let (a, b, ca, cb) = try pair()
        XCTAssertEqual(a.sas, b.sas)
        XCTAssertEqual(a.sas?.count, 6)
        XCTAssertEqual(try cb.open(try ca.seal(Data("hi".utf8))), Data("hi".utf8))
        XCTAssertEqual(try ca.open(try cb.seal(Data("yo".utf8))), Data("yo".utf8))
    }

    func testReplayAndReflectionAreRejected() throws {
        let (_, _, ca, cb) = try pair()
        let frame = try ca.seal(Data("once".utf8))
        _ = try cb.open(frame)
        XCTAssertThrowsError(try cb.open(frame))           // replay
        XCTAssertThrowsError(try ca.open(try ca.seal(Data("x".utf8))))  // reflected to sender
    }

    func testTamperingIsRejected() throws {
        let (_, _, ca, cb) = try pair()
        var frame = try ca.seal(Data("payload".utf8))
        frame[frame.startIndex] ^= 1
        XCTAssertThrowsError(try cb.open(frame))
    }

    func testForgedSignatureIsRejected() throws {
        let a = Handshake(role: .initiator, identity: Curve25519.Signing.PrivateKey())
        let b = Handshake(role: .responder, identity: Curve25519.Signing.PrivateKey())
        try a.receiveHello(b.ownHello)
        try b.receiveHello(a.ownHello)
        let attacker = Curve25519.Signing.PrivateKey()
        let forged = try attacker.signature(for: Data(repeating: 1, count: 33))
        XCTAssertThrowsError(try a.receiveAuth(forged))
    }

    func testManInTheMiddleSeesDifferentSAS() throws {
        let alice = Handshake(role: .initiator, identity: Curve25519.Signing.PrivateKey())
        let bob = Handshake(role: .responder, identity: Curve25519.Signing.PrivateKey())
        let mitmToAlice = Handshake(role: .responder, identity: Curve25519.Signing.PrivateKey())
        let mitmToBob = Handshake(role: .initiator, identity: Curve25519.Signing.PrivateKey())
        try alice.receiveHello(mitmToAlice.ownHello); try mitmToAlice.receiveHello(alice.ownHello)
        try bob.receiveHello(mitmToBob.ownHello); try mitmToBob.receiveHello(bob.ownHello)
        XCTAssertNotEqual(alice.sas, bob.sas)
    }

    func testDeviceIDDerivedFromKey() {
        let k = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertEqual(IdentityManager.deviceID(for: k).count, 16)
        XCTAssertEqual(IdentityManager.deviceID(for: k), IdentityManager.deviceID(for: k))
    }
}

final class ProtocolTests: XCTestCase {
    func testMessageRoundTrip() throws {
        let payload = MouseMovePayload(dx: 1.5, dy: -2).encode()
        let data = MessageProtocol.encode(type: .mouseMove, sequence: 7, payload: payload)
        let msg = try MessageProtocol.decode(data)
        XCTAssertEqual(msg.type, .mouseMove)
        XCTAssertEqual(msg.sequence, 7)
        let p = try MouseMovePayload.decode(msg.payload)
        XCTAssertEqual(p.dx, 1.5); XCTAssertEqual(p.dy, -2)
    }

    func testBadMagicRejected() {
        var data = MessageProtocol.encode(type: .heartbeat, sequence: 0, payload: Data())
        data[data.startIndex] = 0
        XCTAssertThrowsError(try MessageProtocol.decode(data))
    }

    func testFrameBufferHandlesSplitAndCoalescedReads() throws {
        let f1 = MessageProtocol.frame(Data([1, 2, 3])), f2 = MessageProtocol.frame(Data([4, 5]))
        var buf = FrameBuffer()
        let all = f1 + f2
        buf.append(all.prefix(2))
        XCTAssertNil(try buf.nextFrame(limit: 100))
        buf.append(all.dropFirst(2))
        XCTAssertEqual(try buf.nextFrame(limit: 100), Data([1, 2, 3]))
        XCTAssertEqual(try buf.nextFrame(limit: 100), Data([4, 5]))
        XCTAssertNil(try buf.nextFrame(limit: 100))
    }

    func testOversizeFrameRejected() {
        var buf = FrameBuffer()
        buf.append(MessageProtocol.frame(Data(count: 2000)))
        XCTAssertThrowsError(try buf.nextFrame(limit: K.maxHandshakeFrameSize))
    }
}

final class NetworkHelperTests: XCTestCase {
    func testLANDetectionExcludesMeshVPNRange() {
        XCTAssertTrue(NetworkPathWatcher.isLANHost("192.168.1.6"))
        XCTAssertTrue(NetworkPathWatcher.isLANHost("10.0.0.2"))
        XCTAssertTrue(NetworkPathWatcher.isLANHost("172.20.1.1"))
        XCTAssertTrue(NetworkPathWatcher.isLANHost("mini.local"))
        XCTAssertFalse(NetworkPathWatcher.isLANHost("172.32.0.1"))
        XCTAssertFalse(NetworkPathWatcher.isLANHost("100.101.102.103"))
        XCTAssertFalse(NetworkPathWatcher.isLANHost("example.com"))
    }

    func testAddressParsing() {
        XCTAssertEqual(NetworkClient.parseAddress("192.168.1.6")?.portValue, K.defaultPort)
        XCTAssertEqual(NetworkClient.parseAddress("192.168.1.6:9000")?.portValue, 9000)
        XCTAssertEqual(NetworkClient.parseAddress("mini.local:1234")?.hostString, "mini.local")
        XCTAssertNil(NetworkClient.parseAddress("  "))
    }

    func testEdgeGeometry() {
        let b = CGRect(x: 0, y: 0, width: 1000, height: 800)
        var d = ScreenEdgeDetector(threshold: 10)
        XCTAssertNil(d.update(location: CGPoint(x: 999, y: 400), delta: CGPoint(x: 4, y: 0), bounds: b, edges: [.right]))
        XCTAssertNil(d.update(location: CGPoint(x: 999, y: 400), delta: CGPoint(x: 4, y: 0), bounds: b, edges: [.right]))
        let hit = d.update(location: CGPoint(x: 999, y: 400), delta: CGPoint(x: 4, y: 0), bounds: b, edges: [.right])
        XCTAssertEqual(hit?.edge, .right)
        XCTAssertEqual(hit?.position ?? 0, 0.5, accuracy: 0.01)
        // Moving away resets the push.
        XCTAssertNil(d.update(location: CGPoint(x: 500, y: 400), delta: CGPoint(x: 4, y: 0), bounds: b, edges: [.right]))
    }
}
