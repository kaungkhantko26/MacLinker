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

final class UpdaterTests: XCTestCase {
    func testVersionComparison() {
        XCTAssertTrue(Updater.isNewer("v1.0.3", than: "1.0.2"))
        XCTAssertTrue(Updater.isNewer("1.1.0", than: "1.0.9"))
        XCTAssertTrue(Updater.isNewer("2", than: "1.9.9"))
        XCTAssertFalse(Updater.isNewer("1.0.2", than: "1.0.2"))
        XCTAssertFalse(Updater.isNewer("v1.0.1", than: "1.0.2"))
    }

    func testInstallDestinationAvoidsTranslocatedCopy() {
        let translocated = URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/ABC/d/MacLinker.app")
        let dest = Updater.installDestination(current: translocated)
        XCTAssertNotEqual(dest.path, translocated.path)
        XCTAssertEqual(dest.lastPathComponent, "MacLinker.app")
    }

    func testInstallDestinationKeepsWritableLocation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let app = dir.appendingPathComponent("MacLinker.app")
        XCTAssertEqual(Updater.installDestination(current: app).path, app.path)
    }

    func testInstallScriptSwapsAppAndRestoresOnFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fm = FileManager.default
        let staged = root.appendingPathComponent("new/X.app/Contents"), dest = root.appendingPathComponent("dest/X.app/Contents")
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try "new".write(to: staged.appendingPathComponent("v"), atomically: true, encoding: .utf8)
        try "old".write(to: dest.appendingPathComponent("v"), atomically: true, encoding: .utf8)

        // Use a harmless stand-in for `open` so the test doesn't launch anything.
        var script = Updater.installScript(pid: 99_999_999, staged: root.appendingPathComponent("new/X.app").path,
                                           dest: root.appendingPathComponent("dest/X.app").path)
        script = script.replacingOccurrences(of: "/usr/bin/open", with: "/usr/bin/true")
        let file = root.appendingPathComponent("install.sh")
        try script.write(to: file, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [file.path]
        p.environment = ["HOME": root.path]
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("v")), "new")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("dest/X.app.old").path))
    }
}

final class StorageAndModelTests: XCTestCase {
    func testTrustedDevicesPersistAndLookup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        let id = IdentityManager.deviceID(for: key)
        let a = TrustedDevices(directory: dir)
        XCTAssertFalse(a.isTrusted(publicKey: key))
        a.trust(id: id, name: "Mini", publicKey: key)
        a.update(id) { $0.position = .right }
        XCTAssertTrue(a.isTrusted(publicKey: key))
        let b = TrustedDevices(directory: dir)  // reload from disk
        XCTAssertEqual(b.device(id)?.position, .right)
        XCTAssertFalse(b.isTrusted(publicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
        b.remove(id)
        XCTAssertFalse(b.isTrusted(publicKey: key))
    }

    func testIdentityIsStableAcrossLaunches() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertEqual(IdentityManager(directory: dir).deviceID, IdentityManager(directory: dir).deviceID)
    }

    func testEdgeCodesAndGeometry() {
        for e in Edge.allCases { XCTAssertEqual(Edge(code: e.code), e); XCTAssertEqual(e.opposite.opposite, e) }
        XCTAssertNil(Edge(code: 0))
        let b = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(Edge.left.point(at: 0.5, inset: 2, in: b).x, 2)
        XCTAssertEqual(Edge.right.point(at: 0, inset: 2, in: b).x, 997)
        XCTAssertEqual(Edge.top.point(at: 1, inset: 2, in: b).y, 2)
    }

    func testBinaryPayloadsRoundTripAndRejectTruncation() throws {
        let key = KeyPayload(keyCode: 55, down: true, flags: 0x100000, autorepeat: false)
        let decoded = try KeyPayload.decode(key.encode())
        XCTAssertEqual(decoded.keyCode, 55); XCTAssertEqual(decoded.flags, 0x100000)
        XCTAssertThrowsError(try KeyPayload.decode(key.encode().prefix(3)))
        let c = try ControlPayload.decode(ControlPayload(edge: .top, position: 0.25).encode())
        XCTAssertEqual(c.edge, .top); XCTAssertEqual(c.position, 0.25)
        let l = try LayoutPayload.decode(LayoutPayload(peerPosition: nil, userInitiated: true).encode())
        XCTAssertNil(l.peerPosition); XCTAssertTrue(l.userInitiated)
    }

    func testDeviceMergeOrdersConnectedFirst() {
        let trusted = [TrustedDevice(id: "b", name: "B", publicKey: Data(), pairedAt: Date()),
                       TrustedDevice(id: "a", name: "A", publicKey: Data(), pairedAt: Date())]
        let peers = ["b": ConnectionManager.Peer(id: "b", name: "B", state: .connected, latency: 2, link: "bridge0", linkRank: 0)]
        let merged = DeviceManager.merge(discovered: [:], trusted: trusted, peers: peers)
        XCTAssertEqual(merged.map(\.id), ["b", "a"])
        XCTAssertEqual(merged.first?.status, .connected)
        XCTAssertEqual(merged.first?.link, "bridge0")
        XCTAssertEqual(merged.last?.status, .offline)
    }

    func testClipboardRejectsOversizeAndUnknownTypes() {
        let big = ClipboardMessage(entries: [.init(type: "public.utf8-plain-text", data: Data(count: K.clipboardLimit + 1))])
        XCTAssertGreaterThan(big.totalSize, K.clipboardLimit)
        XCTAssertFalse(ClipboardMessage.allowed.contains(.init("public.file-url")))
    }
}

final class SystemControlTests: XCTestCase {
    func testControlPayloadClampsAndRejectsGarbage() throws {
        let hi = try SystemControlPayload.decode(SystemControlPayload(kind: .volume, value: 7).encode())
        XCTAssertEqual(hi.value, 1)
        XCTAssertThrowsError(try SystemControlPayload.decode(Data([9, 0, 0, 0, 0])))   // unknown kind
        XCTAssertThrowsError(try SystemControlPayload.decode(SystemControlPayload(kind: .brightness, value: .nan).encode()))
    }

    func testStatePayloadRoundTrip() throws {
        let s = SystemStatePayload(hasBrightness: true, hasVolume: false, brightness: 0.4, volume: -1, muted: true)
        XCTAssertEqual(try SystemStatePayload.decode(s.encode()), s)
    }

    func testDDCPacketChecksum() {
        // Set brightness (VCP 0x10) to 50: checksum = 0x6E ^ 0x51 ^ all preceding bytes.
        XCTAssertEqual(SystemController.ddcPacket(code: 0x10, value: 50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
        XCTAssertEqual(SystemController.ddcPacket(code: 0x10, value: 0x0100).prefix(5), [0x84, 0x03, 0x10, 0x01, 0x00])
    }

    func testReadingStateNeverCrashes() {
        let s = SystemController().state()   // read-only: reports what this Mac supports
        XCTAssertTrue(s.volume == -1 || (0...1).contains(s.volume))
    }
}

final class CompatibilityTests: XCTestCase {
    func testOlderPeersAreNotSentNewMessages() {
        func supports(_ v: String) -> Bool { !Updater.isNewer(K.systemControlMinVersion, than: v) }
        XCTAssertFalse(supports("1.0"))     // old builds report a fixed "1.0"
        XCTAssertFalse(supports("1.1.1"))
        XCTAssertFalse(supports("0"))
        XCTAssertTrue(supports("1.2.0"))
        XCTAssertTrue(supports("1.3.0"))
    }

    func testUnknownMessageTypeIsReportedNotCrashing() {
        let data = MessageProtocol.encode(type: .heartbeat, sequence: 1, payload: Data())
        var bad = data
        bad[bad.startIndex + 5] = 250   // type byte
        XCTAssertThrowsError(try MessageProtocol.decode(bad)) { error in
            guard case MessageError.unknownType(250) = error else { return XCTFail("wrong error \(error)") }
        }
    }
}

import VideoToolbox
import CoreMedia
import AVFoundation

final class DisplayStreamTests: XCTestCase {
    func testPayloadsRoundTripAndRejectGarbage() throws {
        let acc = DisplayAcceptPayload(accepted: true, width: 1440, height: 900, scale: 2)
        XCTAssertEqual(try DisplayAcceptPayload.decode(acc.encode()), acc)
        let start = DisplayStartPayload(width: 2880, height: 1800, fps: 60)
        XCTAssertEqual(try DisplayStartPayload.decode(start.encode()), start)
        let cfg = DisplayConfigPayload(parameterSets: [Data([1, 2, 3]), Data([4, 5])])
        XCTAssertEqual(try DisplayConfigPayload.decode(cfg.encode()), cfg)
        XCTAssertThrowsError(try DisplayConfigPayload.decode(Data([0])))                  // zero sets
        XCTAssertThrowsError(try DisplayConfigPayload.decode(Data([1, 0, 0, 0xFF, 0xFF]))) // absurd length
        let frame = DisplayFramePayload(keyframe: true, timestampMs: 123, data: Data([9, 9]))
        XCTAssertEqual(try DisplayFramePayload.decode(frame.encode()), frame)
        XCTAssertThrowsError(try DisplayFramePayload.decode(Data([1, 0, 0, 0, 0, 0, 0, 0, 0])))  // no video data
        let ptr = DisplayPointerPayload(kind: .drag, button: 1, x: 0.25, y: 1.5, clickCount: 2)
        XCTAssertEqual(try DisplayPointerPayload.decode(ptr.encode()).y, 1)               // clamped to the picture
        XCTAssertThrowsError(try DisplayPointerPayload.decode(Data([9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])))
    }

    func testDisplayPeersMustBeNewEnough() {
        func supports(_ v: String) -> Bool { !Updater.isNewer(K.displayMinVersion, than: v) }
        XCTAssertFalse(supports("1.3.0"))
        XCTAssertTrue(supports("1.4.0"))
    }

    /// Real hardware encoder -> real decoder: what the host sends is something the viewer can decode.
    func testEncodedVideoDecodesBack() throws {
        let width = 320, height = 240
        let encoder = try VideoEncoder(width: width, height: height, fps: 30, bitrate: 2_000_000)
        var sets: [Data] = []
        var frames: [(key: Bool, ms: UInt64, data: Data)] = []
        let lock = NSLock()
        encoder.onParameterSets = { lock.lock(); sets = $0; lock.unlock() }
        encoder.onFrame = { key, ms, data in lock.lock(); frames.append((key, ms, data)); lock.unlock() }

        for i in 0..<20 {
            var pb: CVPixelBuffer?
            let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs, &pb), kCVReturnSuccess)
            let buffer = try XCTUnwrap(pb)
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<CVPixelBufferGetPlaneCount(buffer) {
                if let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) {
                    memset(base, Int32((i * 12 + plane * 60) % 255), CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            encoder.encode(buffer, pts: CMTime(value: Int64(i), timescale: 30))
        }
        encoder.flush()
        encoder.invalidate()

        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(sets.count, 2, "expected SPS and PPS")
        XCTAssertGreaterThan(frames.count, 10)
        XCTAssertTrue(try XCTUnwrap(frames.first).key, "stream must begin with a key frame")

        let format = try XCTUnwrap(makeH264FormatDescription(parameterSets: sets))
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        XCTAssertEqual(Int(dims.width), width); XCTAssertEqual(Int(dims.height), height)

        var decoded = 0
        var session: VTDecompressionSession?
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                    imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session), noErr)
        let decoder = try XCTUnwrap(session)
        for f in frames {
            let sample = try XCTUnwrap(makeSampleBuffer(frame: f.data, format: format, timestampMs: f.ms, displayImmediately: false))
            let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                if status == noErr, let image, CVPixelBufferGetWidth(image) == width { decoded += 1 }
            }
            XCTAssertEqual(status, noErr)
        }
        // The viewer's display layer must accept the same frames without failing.
        let layer = AVSampleBufferDisplayLayer()
        for f in frames {
            let sample = try XCTUnwrap(makeSampleBuffer(frame: f.data, format: format, timestampMs: f.ms))
            layer.enqueue(sample)
        }
        XCTAssertNotEqual(layer.status, .failed, "display layer rejected the stream: \(String(describing: layer.error))")
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        VTDecompressionSessionInvalidate(decoder)
        XCTAssertEqual(decoded, frames.count, "every frame the encoder produced should decode")
    }
}
