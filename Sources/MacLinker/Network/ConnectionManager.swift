import Foundation
import Network

final class ConnectionManager: ObservableObject, SessionDelegate {
    struct Peer: Identifiable, Equatable {
        enum State { case connecting, pairing, connected }
        let id: String
        var name: String
        var state: State
        var latency: Double?
        /// Network interface the session runs over (for example "bridge0" for a USB-C cable, "en0" for Wi-Fi).
        var link: String?
        var linkRank: Int?
        var appVersion: String = "0"
    }

    @Published private(set) var peers: [String: Peer] = [:]

    var onMessage: ((String, MacLinkerMessage) -> Void)?
    var onConnected: ((String) -> Void)?
    var onDisconnected: ((String) -> Void)?
    var onPairingNeeded: ((Session, PeerInfo, String) -> Void)?
    var onPairingEnded: ((Session) -> Void)?

    private let identity: IdentityManager
    private let trusted: TrustedDevices
    private let queue = DispatchQueue(label: "maclinker.net", qos: .userInteractive)
    private var sessions: [UUID: Session] = [:]
    private var active: [String: Session] = [:] { didSet { publishSendable() } }
    // `send` is called from the input thread and file-transfer queue, so it reads a locked copy.
    private let sendLock = NSLock()
    private var sendable: [String: Session] = [:]

    private func publishSendable() {
        sendLock.lock(); sendable = active; sendLock.unlock()
    }
    var listenPort: () -> UInt16 = { K.defaultPort }

    init(identity: IdentityManager, trusted: TrustedDevices) {
        self.identity = identity
        self.trusted = trusted
    }

    // MARK: Opening sessions

    func connect(to endpoint: NWEndpoint, expectedID: String?, interface: NWInterface?) {
        if let expectedID, hasSession(for: expectedID) { return }
        let conn = NetworkClient.makeConnection(to: endpoint, interface: interface)
        register(conn, role: .initiator, expectedID: expectedID)
    }

    func accept(_ conn: NWConnection) {
        DispatchQueue.main.async { self.register(conn, role: .responder, expectedID: nil) }
    }

    private func register(_ conn: NWConnection, role: Session.Role, expectedID: String?) {
        let trustedRef = trusted
        let s = Session(connection: conn, role: role, expectedPeerID: expectedID, queue: queue,
                        identity: identity, isTrusted: { trustedRef.isTrusted(publicKey: $0) },
                        listenPort: listenPort)
        s.delegate = self
        sessions[s.id] = s
        s.start()
    }

    func hasSession(for deviceID: String) -> Bool {
        active[deviceID] != nil
            || sessions.values.contains { $0.expectedPeerID == deviceID && $0.state != .closed }
    }

    func isConnected(_ deviceID: String) -> Bool { peers[deviceID]?.state == .connected }
    var connectedIDs: [String] { peers.values.filter { $0.state == .connected }.map(\.id) }

    func disconnect(_ deviceID: String) { active[deviceID]?.close() }
    func disconnectAll() { sessions.values.forEach { $0.close() } }

    func session(forPairing id: UUID) -> Session? { sessions[id] }

    // MARK: Sending

    func send(_ type: MessageType, payload: Data = Data(), to deviceID: String,
              completion: ((Error?) -> Void)? = nil) {
        sendLock.lock(); let s = sendable[deviceID]; sendLock.unlock()
        guard let s else { completion?(SessionError.notConnected); return }
        s.send(type, payload: payload, completion: completion)
    }

    func broadcast(_ type: MessageType, payload: Data) {
        for id in connectedIDs { send(type, payload: payload, to: id) }
    }

    // MARK: SessionDelegate (main queue)

    func session(_ s: Session, didIdentify peer: PeerInfo) {
        guard sessions[s.id] != nil else { return }
        if let existing = active[peer.deviceID], existing !== s, existing.state != .closed {
            // Both Macs dialled each other. Both sides keep the connection initiated by the
            // smaller device ID, so they agree on the survivor without talking.
            func initiatorID(_ x: Session) -> String { x.role == .initiator ? identity.deviceID : peer.deviceID }
            if initiatorID(s) < initiatorID(existing) {
                existing.close(SessionError.duplicate)
            } else {
                s.close(SessionError.duplicate)
                return
            }
        }
        active[peer.deviceID] = s
        peers[peer.deviceID] = Peer(id: peer.deviceID, name: peer.name, state: .connecting, latency: nil, appVersion: peer.appVersion)
    }

    func session(_ s: Session, didChange state: Session.State) {
        guard let peerInfo = s.peer, active[peerInfo.deviceID] === s else { return }
        let id = peerInfo.deviceID
        switch state {
        case .awaitingPairing(let code):
            peers[id]?.state = .pairing
            onPairingNeeded?(s, peerInfo, code)
        case .connected:
            if s.needsPairing { trusted.trust(id: id, name: peerInfo.name, publicKey: peerInfo.publicKey) }
            trusted.update(id) {
                $0.name = peerInfo.name
                $0.lastConnected = Date()
                if let host = s.connection.endpoint.hostString, !host.contains(":") {
                    $0.lastHost = host
                    $0.lastPort = s.role == .initiator ? s.connection.endpoint.portValue : peerInfo.port
                }
            }
            let iface = s.connection.currentPath?.availableInterfaces.first
            peers[id]?.link = iface?.name
            peers[id]?.linkRank = iface.flatMap(NetworkPathWatcher.rank)
            peers[id]?.state = .connected
            onPairingEnded?(s)
            onConnected?(id)
        default: break
        }
    }

    func session(_ s: Session, didReceive message: MacLinkerMessage) {
        guard let id = s.peer?.deviceID, active[id] === s else { return }
        onMessage?(id, message)
    }

    func session(_ s: Session, didMeasureLatency ms: Double) {
        guard let id = s.peer?.deviceID, active[id] === s else { return }
        peers[id]?.latency = ms
    }

    func session(_ s: Session, didClose error: Error?) {
        sessions[s.id] = nil
        onPairingEnded?(s)
        if let error { Log.info("session closed: \(error)") }
        guard let id = s.peer?.deviceID, active[id] === s else { return }
        active[id] = nil
        peers[id] = nil
        onDisconnected?(id)
    }
}
