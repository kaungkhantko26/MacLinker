import Foundation
import Network

final class NetworkServer {
    var onConnection: ((NWConnection) -> Void)?
    private(set) var port: UInt16 = K.defaultPort

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "maclinker.listener")
    private var identity: IdentityManager?
    private var stopped = false

    func start(identity: IdentityManager) {
        self.identity = identity
        stopped = false
        launch(preferredPort: K.defaultPort)
    }

    func stop() {
        stopped = true
        listener?.cancel()
        listener = nil
    }

    private func launch(preferredPort: UInt16?) {
        guard let identity else { return }
        let params = NetworkClient.parameters(interface: nil)
        let made: NWListener?
        if let preferredPort, let p = NWEndpoint.Port(rawValue: preferredPort) {
            made = try? NWListener(using: params, on: p)
        } else {
            made = try? NWListener(using: params)
        }
        guard let listener = made else {
            // Fixed port unavailable (another instance?): fall back to any free port.
            if preferredPort != nil { launch(preferredPort: nil) }
            return
        }
        listener.service = BonjourAdvertiser.service(name: identity.deviceName, deviceID: identity.deviceID)
        listener.newConnectionHandler = { [weak self] conn in self?.onConnection?(conn) }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            switch state {
            case .ready:
                if let p = listener.port?.rawValue { self.port = p }
                Log.info("listening on port \(self.port)")
            case .failed(let e):
                Log.error("listener failed: \(e)")
                listener.cancel()
                self.queue.asyncAfter(deadline: .now() + 2) {
                    if !self.stopped { self.launch(preferredPort: K.defaultPort) }
                }
            default: break
            }
        }
        self.listener = listener
        listener.start(queue: queue)
    }
}
