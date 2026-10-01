import Foundation

struct PairingRequest: Identifiable, Equatable {
    let id: UUID  // session id
    let deviceName: String
    let code: String
    var formattedCode: String { String(code.prefix(3)) + " " + String(code.suffix(3)) }
}

final class PairingManager: ObservableObject {
    @Published private(set) var pending: PairingRequest?
    var onPresent: (() -> Void)?
    private var session: Session?

    func present(session: Session, peer: PeerInfo, code: String) {
        self.session = session
        pending = PairingRequest(id: session.id, deviceName: peer.name, code: code)
        onPresent?()
    }

    func dismiss(session: Session) {
        guard self.session === session else { return }
        self.session = nil
        pending = nil
    }

    func confirm() { session?.confirmPairing() }
    func reject() { session?.rejectPairing() }
}
