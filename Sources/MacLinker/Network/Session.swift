import Foundation
import Network
import CryptoKit

struct PeerInfo: Equatable {
    var deviceID: String
    var name: String
    var publicKey: Data
    var port: UInt16
    /// Peers older than 1.0.3 reported a fixed "1.0", which is fine: it just means "old".
    var appVersion: String = "0"
}

enum SessionError: Error {
    case notConnected, timeout, pairingRejected, pairingTimeout, unexpectedPeer, selfConnection, duplicate
    case protocolViolation(String)
}

/// All delegate callbacks arrive on the main queue.
protocol SessionDelegate: AnyObject {
    func session(_ s: Session, didIdentify peer: PeerInfo)
    func session(_ s: Session, didChange state: Session.State)
    func session(_ s: Session, didReceive message: MacLinkerMessage)
    func session(_ s: Session, didMeasureLatency ms: Double)
    func session(_ s: Session, didClose error: Error?)
}

/// One TCP connection to one peer: handshake, pairing, encryption, heartbeat.
final class Session {
    enum Role { case initiator, responder }
    enum State: Equatable { case connecting, handshaking, awaitingPairing(code: String), connected, closed }
    private enum Stage { case awaitHello, awaitAuth, secure }

    let id = UUID()
    let role: Role
    let expectedPeerID: String?
    let connection: NWConnection
    weak var delegate: SessionDelegate?

    private let queue: DispatchQueue
    private let identity: IdentityManager
    private let isTrusted: (Data) -> Bool
    private let listenPort: () -> UInt16
    private let handshake: Handshake

    private var stage: Stage = .awaitHello
    private var codec: SecureCodec?
    private var buffer = FrameBuffer()
    private var sendSequence: UInt32 = 0
    private var lastReceived = Date()
    private var heartbeat: DispatchSourceTimer?
    private var started = false

    private(set) var state: State = .connecting
    private(set) var peer: PeerInfo?
    /// True when this session needed the user to confirm a pairing code.
    private(set) var needsPairing = false
    private var localConfirmed = false
    private var remoteConfirmed = false

    init(connection: NWConnection, role: Role, expectedPeerID: String?, queue: DispatchQueue,
         identity: IdentityManager, isTrusted: @escaping (Data) -> Bool, listenPort: @escaping () -> UInt16) {
        self.connection = connection
        self.role = role
        self.expectedPeerID = expectedPeerID
        self.queue = queue
        self.identity = identity
        self.isTrusted = isTrusted
        self.listenPort = listenPort
        self.handshake = Handshake(role: role == .initiator ? .initiator : .responder,
                                   identity: identity.signingKey)
    }

    // MARK: Lifecycle

    func start() {
        connection.stateUpdateHandler = { [weak self] st in self?.connectionStateChanged(st) }
        connection.start(queue: queue)
    }

    func close(_ error: Error? = nil) {
        queue.async { self.closeOnQueue(error) }
    }

    private func closeOnQueue(_ error: Error?) {
        guard state != .closed else { return }
        state = .closed
        heartbeat?.cancel()
        connection.stateUpdateHandler = nil
        connection.cancel()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.session(self, didChange: .closed)
            self.delegate?.session(self, didClose: error)
        }
    }

    private func connectionStateChanged(_ st: NWConnection.State) {
        switch st {
        case .ready:
            guard !started else { return }
            started = true
            setState(.handshaking)
            sendRaw(handshake.ownHello)
            startHeartbeat()
            receiveLoop()
        case .failed(let e): closeOnQueue(e)
        // Network.framework would retry forever; ReconnectManager owns retry policy instead.
        case .waiting(let e): closeOnQueue(e)
        case .cancelled: closeOnQueue(nil)
        default: break
        }
    }

    private func setState(_ new: State) {
        guard state != new, state != .closed else { return }
        state = new
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.session(self, didChange: new)
        }
    }

    // MARK: Receive

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, complete, error in
            guard let self, self.state != .closed else { return }
            if let data, !data.isEmpty {
                self.lastReceived = Date()
                do { try self.ingest(data) } catch { self.closeOnQueue(error); return }
            }
            if let error { self.closeOnQueue(error); return }
            if complete { self.closeOnQueue(nil); return }
            self.receiveLoop()
        }
    }

    private func ingest(_ data: Data) throws {
        buffer.append(data)
        while state != .closed {
            let limit = stage == .secure ? K.maxFrameSize : K.maxHandshakeFrameSize
            guard let frame = try buffer.nextFrame(limit: limit) else { break }
            try handle(frame: frame)
        }
    }

    private func handle(frame: Data) throws {
        switch stage {
        case .awaitHello:
            try handshake.receiveHello(frame)
            sendRaw(try handshake.makeAuth())
            stage = .awaitAuth
        case .awaitAuth:
            codec = try handshake.receiveAuth(frame)
            stage = .secure
            guard let pub = handshake.peerIdentity, let pid = handshake.peerDeviceID else {
                throw SessionError.protocolViolation("missing identity")
            }
            if pid == identity.deviceID { throw SessionError.selfConnection }
            if let expected = expectedPeerID, expected != pid { throw SessionError.unexpectedPeer }
            peer = PeerInfo(deviceID: pid, name: "", publicKey: pub, port: 0)
            let hello = HelloPayload(name: identity.deviceName, deviceID: identity.deviceID,
                                     trustsYou: isTrusted(pub), port: listenPort(),
                                     appVersion: K.appVersion)
            try sendOnQueue(.hello, payload: JSONEncoder().encode(hello))
        case .secure:
            guard let codec else { throw SessionError.notConnected }
            let plain = try codec.open(frame)
            let message: MacLinkerMessage
            do { message = try MessageProtocol.decode(plain) }
            catch MessageError.unknownType(let t) {
                // A newer peer sent something we don't know. Skip it instead of dropping the link.
                Log.info("ignoring unknown message type \(t)")
                return
            }
            try handle(message: message)
        }
    }

    private func handle(message: MacLinkerMessage) throws {
        if !message.type.isHandshakePhase && state != .connected {
            throw SessionError.protocolViolation("data before pairing completed")
        }
        switch message.type {
        case .hello:
            guard var info = peer, let sas = handshake.sas else { throw SessionError.protocolViolation("hello") }
            let hello = try JSONDecoder().decode(HelloPayload.self, from: message.payload)
            guard hello.deviceID == info.deviceID else { throw SessionError.protocolViolation("id mismatch") }
            info.name = String(hello.name.prefix(80))
            info.port = hello.port
            info.appVersion = hello.appVersion
            peer = info
            let iTrustPeer = isTrusted(info.publicKey)
            needsPairing = !(iTrustPeer && hello.trustsYou)
            let delegate = self.delegate
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                delegate?.session(self, didIdentify: info)
            }
            if needsPairing {
                setState(.awaitingPairing(code: sas))
                queue.asyncAfter(deadline: .now() + K.pairingTimeout) { [weak self] in
                    guard let self, case .awaitingPairing = self.state else { return }
                    self.closeOnQueue(SessionError.pairingTimeout)
                }
            } else {
                localConfirmed = true
                try sendOnQueue(.pairConfirm)
                completeIfReady()
            }
        case .pairConfirm:
            remoteConfirmed = true
            completeIfReady()
        case .pairReject:
            closeOnQueue(SessionError.pairingRejected)
        case .heartbeat:
            var r = ByteReader(message.payload)
            let kind = try r.u8(), stamp = try r.u64()
            if kind == 0 {
                var w = ByteWriter(); w.u8(1); w.u64(stamp)
                try sendOnQueue(.heartbeat, payload: w.data)
            } else {
                let now = UInt64(Date().timeIntervalSince1970 * 1000)
                let rtt = Double(now &- stamp)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.session(self, didMeasureLatency: rtt)
                }
            }
        default:
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.session(self, didReceive: message)
            }
        }
    }

    private func completeIfReady() {
        guard localConfirmed, remoteConfirmed, state != .connected, state != .closed else { return }
        setState(.connected)
    }

    // MARK: Pairing decisions (called from the UI)

    func confirmPairing() {
        queue.async {
            guard case .awaitingPairing = self.state, !self.localConfirmed else { return }
            self.localConfirmed = true
            do { try self.sendOnQueue(.pairConfirm) } catch { self.closeOnQueue(error) }
            self.completeIfReady()
        }
    }

    func rejectPairing() {
        queue.async {
            try? self.sendOnQueue(.pairReject)
            // Give the reject a moment to flush before tearing the connection down.
            self.queue.asyncAfter(deadline: .now() + 0.2) { self.closeOnQueue(SessionError.pairingRejected) }
        }
    }

    // MARK: Send

    func send(_ type: MessageType, payload: Data = Data(), completion: ((Error?) -> Void)? = nil) {
        queue.async {
            do { try self.sendOnQueue(type, payload: payload, completion: completion) }
            catch {
                completion?(error)
                if case SessionError.notConnected = error { return }
                self.closeOnQueue(error)
            }
        }
    }

    private func sendOnQueue(_ type: MessageType, payload: Data = Data(),
                             completion: ((Error?) -> Void)? = nil) throws {
        guard state != .closed, let codec else { throw SessionError.notConnected }
        if !type.isHandshakePhase && state != .connected { throw SessionError.notConnected }
        let plain = MessageProtocol.encode(type: type, sequence: sendSequence, payload: payload)
        sendSequence &+= 1
        let sealed = try codec.seal(plain)
        connection.send(content: MessageProtocol.frame(sealed), completion: .contentProcessed { [weak self] err in
            completion?(err)
            if let err { self?.closeOnQueue(err) }
        })
    }

    private func sendRaw(_ body: Data) {
        connection.send(content: MessageProtocol.frame(body), completion: .contentProcessed { [weak self] err in
            if let err { self?.closeOnQueue(err) }
        })
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + K.heartbeatInterval, repeating: K.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self, self.state != .closed else { return }
            if Date().timeIntervalSince(self.lastReceived) > K.heartbeatTimeout {
                self.closeOnQueue(SessionError.timeout)
                return
            }
            guard self.stage == .secure, self.peer != nil else { return }
            var w = ByteWriter()
            w.u8(0); w.u64(UInt64(Date().timeIntervalSince1970 * 1000))
            try? self.sendOnQueue(.heartbeat, payload: w.data)
        }
        timer.resume()
        heartbeat = timer
    }
}
