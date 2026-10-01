import Foundation
import Network

final class BonjourBrowser {
    var onUpdate: (([DiscoveredDevice]) -> Void)?

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "maclinker.browser")
    private var running = false
    private let ownID: String

    init(ownID: String) { self.ownID = ownID }

    func start() {
        running = true
        launch()
    }

    func stop() {
        running = false
        browser?.cancel()
        browser = nil
    }

    private func launch() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: K.serviceType, domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            var found: [String: DiscoveredDevice] = [:]
            for r in results {
                guard case .service(let name, _, _, _) = r.endpoint,
                      case .bonjour(let txt) = r.metadata,
                      let id = txt["id"], id != self.ownID else { continue }
                // The same Mac can be seen on several links; keep the best one (cable over Wi-Fi).
                let best = r.interfaces.compactMap { i in NetworkPathWatcher.rank(i).map { (i, $0) } }.min { $0.1 < $1.1 }?.0
                if let current = found[id], let ci = current.interface, let bi = best,
                   (NetworkPathWatcher.rank(ci) ?? 9) <= (NetworkPathWatcher.rank(bi) ?? 9) { continue }
                found[id] = DiscoveredDevice(id: id, name: name, endpoint: r.endpoint, interface: best)
            }
            DispatchQueue.main.async { self.onUpdate?(Array(found.values)) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .failed(let e) = state {
                Log.error("browser failed: \(e)")
                browser.cancel()
                self.queue.asyncAfter(deadline: .now() + 3) { if self.running { self.launch() } }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }
}
