import Foundation

final class DeviceDiscoveryManager: ObservableObject {
    @Published private(set) var discovered: [String: DiscoveredDevice] = [:]
    private let browser: BonjourBrowser

    init(ownID: String) {
        browser = BonjourBrowser(ownID: ownID)
        browser.onUpdate = { [weak self] devices in
            self?.discovered = Dictionary(uniqueKeysWithValues: devices.map { ($0.id, $0) })
        }
    }

    func start() { browser.start() }
    func stop() { browser.stop() }
}
