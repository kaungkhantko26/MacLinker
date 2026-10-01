import Foundation

/// Lets a paired Mac change this Mac's brightness and volume, and tracks the same for each peer.
final class RemoteSystemManager: ObservableObject {
    /// Last state each connected peer reported (or that we optimistically set).
    @Published private(set) var states: [String: SystemStatePayload] = [:]

    var isAllowed: () -> Bool = { true }
    var lockAllowed: () -> Bool = { true }
    /// Lock messages need MacLinker 1.5.0+, newer than the brightness/volume check above.
    var peerSupportsLock: (String) -> Bool = { _ in false }
    var send: ((String, MessageType, Data) -> Void)?
    /// Whether the peer is new enough to understand brightness/volume messages.
    var peerSupports: (String) -> Bool = { _ in false }

    private let controller = SystemController()
    /// DDC writes are slow and blocking, so they never run on the main thread.
    private let queue = DispatchQueue(label: "maclinker.system", qos: .userInitiated)
    private var pending: [String: [SystemControlPayload.Kind: Float]] = [:]
    private var flushScheduled = Set<String>()

    // MARK: Telling peers about this Mac

    func announce(to peer: String) {
        guard peerSupports(peer) else { return }
        queue.async {
            let state = self.controller.state()
            self.send?(peer, .systemState, state.encode())
        }
    }

    func peerDisconnected(_ peer: String) {
        states[peer] = nil
        pending[peer] = nil
    }

    // MARK: Messages from peers

    func handle(_ message: MacLinkerMessage, from peer: String) {
        switch message.type {
        case .systemQuery:
            announce(to: peer)  // (already gated on the peer's version)
        case .systemState:
            if let s = try? SystemStatePayload.decode(message.payload) { states[peer] = s }
        case .lockScreen:
            guard lockAllowed() else { return }
            queue.async { _ = self.controller.lockScreen() }
        case .systemControl:
            guard isAllowed(), let req = try? SystemControlPayload.decode(message.payload) else { return }
            queue.async {
                switch req.kind {
                case .brightness: self.controller.setBrightness(req.value)
                case .volume: self.controller.setVolume(req.value)
                case .mute: self.controller.setMuted(req.value >= 0.5)
                }
                self.send?(peer, .systemState, self.controller.state().encode())
            }
        default: break
        }
    }

    // MARK: Controlling a peer

    func lock(_ peer: String) {
        guard peerSupportsLock(peer) else { return }
        send?(peer, .lockScreen, Data())
    }

    func refresh(_ peer: String) {
        guard peerSupports(peer) else { return }
        send?(peer, .systemQuery, Data())
    }

    /// Called as a slider moves; sends at most one update per ~80 ms and always the latest value.
    func set(_ kind: SystemControlPayload.Kind, _ value: Float, on peer: String) {
        if var s = states[peer] {
            switch kind {
            case .brightness: s.brightness = value
            case .volume: s.volume = value
            case .mute: s.muted = value >= 0.5
            }
            states[peer] = s
        }
        guard peerSupports(peer) else { return }
        pending[peer, default: [:]][kind] = value
        guard !flushScheduled.contains(peer) else { return }
        flushScheduled.insert(peer)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self else { return }
            self.flushScheduled.remove(peer)
            for (k, v) in self.pending.removeValue(forKey: peer) ?? [:] {
                self.send?(peer, .systemControl, SystemControlPayload(kind: k, value: v).encode())
            }
        }
    }
}
