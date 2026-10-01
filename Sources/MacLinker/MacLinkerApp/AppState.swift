import Foundation
import AppKit
import Combine
import Network

/// Composition root: owns every service and routes messages between them.
final class AppState: ObservableObject {
    static let shared = AppState()

    let identity = IdentityManager.shared
    var settings = Settings()
    let trusted = TrustedDevices()
    let permissions = PermissionManager()
    let paths = NetworkPathWatcher()
    let pairing = PairingManager()
    let input = InputManager()
    let clipboard = ClipboardManager()
    let files = FileTransferManager()
    let server = NetworkServer()
    let updater = Updater()
    let system = RemoteSystemManager()
    let deviceInfo = DeviceInfoManager()
    let shelf = ShelfStore()
    let discovery: DeviceDiscoveryManager
    let connections: ConnectionManager
    let reconnect: ReconnectManager

    @Published var lastError: String?
    @Published private(set) var isRefreshing = false
    private var bag = Set<AnyCancellable>()

    init() {
        discovery = DeviceDiscoveryManager(ownID: identity.deviceID)
        connections = ConnectionManager(identity: identity, trusted: trusted)
        reconnect = ReconnectManager(identity: identity, trusted: trusted, discovery: discovery,
                                     connections: connections, settings: settings, paths: paths)
        wire()
    }

    // MARK: Derived

    var devices: [Device] {
        DeviceManager.merge(discovered: discovery.discovered, trusted: trusted.devices, peers: connections.peers)
    }

    var connectedCount: Int { connections.connectedIDs.count }
    var isControlling: Bool { if case .local = input.state { return false } else { return true } }

    // MARK: Wiring

    private func wire() {
        // Re-render SwiftUI when any child changes.
        let changes: [AnyPublisher<Void, Never>] = [
            settings.objectWillChange.eraseToAnyPublisher(), trusted.objectWillChange.eraseToAnyPublisher(),
            permissions.objectWillChange.eraseToAnyPublisher(), paths.objectWillChange.eraseToAnyPublisher(),
            pairing.objectWillChange.eraseToAnyPublisher(), input.objectWillChange.eraseToAnyPublisher(),
            files.objectWillChange.eraseToAnyPublisher(), discovery.objectWillChange.eraseToAnyPublisher(),
            connections.objectWillChange.eraseToAnyPublisher(), updater.objectWillChange.eraseToAnyPublisher(), system.objectWillChange.eraseToAnyPublisher(), deviceInfo.objectWillChange.eraseToAnyPublisher(),
            shelf.objectWillChange.eraseToAnyPublisher(), clipboard.history.objectWillChange.eraseToAnyPublisher(),
        ].map { $0.map { _ in () }.eraseToAnyPublisher() }
        changes.forEach { $0.receive(on: DispatchQueue.main).sink { [weak self] in
            self?.objectWillChange.send()
            self?.syncInput()
        }.store(in: &bag) }

        server.onConnection = { [weak self] in self?.connections.accept($0) }
        connections.listenPort = { [weak self] in self?.server.port ?? K.defaultPort }

        connections.onMessage = { [weak self] id, msg in self?.route(msg, from: id) }
        connections.onPairingNeeded = { [weak self] session, peer, code in
            self?.pairing.present(session: session, peer: peer, code: code)
        }
        connections.onPairingEnded = { [weak self] in self?.pairing.dismiss(session: $0) }
        connections.onConnected = { [weak self] id in self?.peerConnected(id) }
        connections.onDisconnected = { [weak self] id in
            self?.input.peerDisconnected(id)
            self?.files.peerDisconnected()
            self?.system.peerDisconnected(id)
            self?.deviceInfo.peerDisconnected(id)
        }
        pairing.onPresent = { WindowManager.shared.showPairing() }

        input.send = { [weak self] id, type, payload in self?.connections.send(type, payload: payload, to: id) }

        clipboard.isEnabled = { [weak self] in self?.settings.clipboardSharing ?? false }
        clipboard.broadcast = { [weak self] payload in self?.connections.broadcast(.clipboard, payload: payload) }

        system.isAllowed = { [weak self] in self?.settings.remoteSystemControl ?? false }
        system.peerSupports = { [weak self] id in
            guard let v = self?.connections.peers[id]?.appVersion else { return false }
            return !Updater.isNewer(K.systemControlMinVersion, than: v)
        }
        system.peerSupportsLock = { [weak self] id in self?.peerSupportsHub(id) ?? false }
        system.lockAllowed = { [weak self] in self?.settings.allowRemoteLock ?? false }
        deviceInfo.send = { [weak self] id, type, payload in self?.connections.send(type, payload: payload, to: id) }
        deviceInfo.peerSupports = { [weak self] id in self?.peerSupportsHub(id) ?? false }
        deviceInfo.connectedPeers = { [weak self] in self?.connections.connectedIDs ?? [] }
        deviceInfo.link = { [weak self] in self?.paths.lanInterface }
        system.send = { [weak self] id, type, payload in self?.connections.send(type, payload: payload, to: id) }

        files.isEnabled = { [weak self] in self?.settings.fileSharing ?? false }
        files.peerName = { [weak self] id in self?.trusted.device(id)?.name ?? id }
        files.send = { [weak self] type, payload, id, done in
            self?.connections.send(type, payload: payload, to: id, completion: done)
        }

        settings.$inputSharing.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.syncInput(); self?.input.abortIfNeeded() }
        }.store(in: &bag)
        permissions.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            DispatchQueue.main.async { self?.startInputIfPossible() }
        }.store(in: &bag)
    }

    func start() {
        CursorHider.prepare()
        paths.start()
        permissions.start()
        server.start(identity: identity)
        discovery.start()
        reconnect.start()
        clipboard.start()
        updater.start()
        deviceInfo.start()
        startInputIfPossible()
        Log.info("started as \(identity.deviceName) [\(identity.deviceID)]")
    }

    private func startInputIfPossible() {
        if !input.isTapRunning { input.startMonitoring() }
    }

    /// Pushes the current settings and layout to the input thread (which owns them while running).
    private func syncInput() {
        var map: [Edge: String] = [:]
        for t in trusted.devices {
            if let edge = t.position, connections.isConnected(t.id) { map[edge] = t.id }
        }
        input.configure(enabled: settings.inputSharing, push: settings.edgePush, edgePeers: map)
    }

    // MARK: Routing

    private func route(_ msg: MacLinkerMessage, from id: String) {
        switch msg.type {
        case .mouseMove, .mouseButton, .scroll, .keyEvent, .flagsChanged, .enterControl, .releaseControl:
            input.handle(message: msg, from: id)
        case .clipboard:
            clipboard.receive(msg.payload, from: connections.peers[id]?.name ?? trusted.device(id)?.name ?? "Another Mac")
        case .fileOffer, .fileChunk, .fileEnd, .fileAbort:
            files.handle(message: msg, from: id)
        case .deviceInfo, .deviceInfoQuery:
            deviceInfo.handle(msg, from: id)
        case .lockScreen, .systemControl, .systemState, .systemQuery:
            system.handle(msg, from: id)
        case .layout:
            if let p = try? LayoutPayload.decode(msg.payload) { applyRemoteLayout(p, from: id) }
        default: break
        }
    }

    private func peerConnected(_ id: String) {
        reconnect.reset(id)
        deviceInfo.peerConnected(id)
        system.announce(to: id)
        system.refresh(id)
        if let pos = trusted.device(id)?.position {
            send(layout: pos, userInitiated: false, to: id)
        }
        syncInput()
    }

    // MARK: Layout

    func setPosition(_ edge: Edge?, for id: String) {
        trusted.update(id) { $0.position = edge }
        send(layout: edge, userInitiated: true, to: id)
        syncInput()
    }

    private func send(layout: Edge?, userInitiated: Bool, to id: String) {
        connections.send(.layout, payload: LayoutPayload(peerPosition: layout, userInitiated: userInitiated).encode(), to: id)
    }

    /// The peer says where *it* puts us; we mirror it. On connect, the Mac with the smaller ID wins
    /// so two inconsistent configurations converge instead of swapping.
    private func applyRemoteLayout(_ p: LayoutPayload, from id: String) {
        let mine = trusted.device(id)?.position
        if !p.userInitiated {
            guard p.peerPosition != nil else { return }
            let senderWins = id < identity.deviceID
            guard senderWins || mine == nil else { return }
        }
        trusted.update(id) { $0.position = p.peerPosition?.opposite }
        syncInput()
    }

    // MARK: Actions

    func connect(_ device: Device) {
        if let found = discovery.discovered[device.id] {
            connections.connect(to: found.endpoint, expectedID: nil,
                                interface: settings.pinToLAN ? (found.interface ?? paths.lanInterface) : nil)
        } else if let t = trusted.device(device.id), let host = t.lastHost,
                  let ep = NetworkClient.parseAddress("\(host):\(t.lastPort ?? K.defaultPort)") {
            connect(address: ep)
        }
    }

    func connect(address text: String) {
        guard let ep = NetworkClient.parseAddress(text) else { lastError = "Couldn't read \"\(text)\" as an address."; return }
        lastError = nil
        connect(address: ep)
    }

    private func connect(address ep: NWEndpoint) {
        let pin = settings.pinToLAN && (ep.hostString.map(NetworkPathWatcher.isLANHost) ?? false)
        connections.connect(to: ep, expectedID: nil, interface: pin ? paths.lanInterface : nil)
    }

    func peerSupportsHub(_ id: String) -> Bool {
        guard let v = connections.peers[id]?.appVersion else { return false }
        return !Updater.isNewer(K.hubMinVersion, than: v)
    }

    /// The Refresh button: browse again, retry offline Macs now, and re-read this Mac and every peer's info.
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        discovery.restart()
        reconnect.retryNow()
        permissions.refresh()
        deviceInfo.refreshAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.isRefreshing = false }
    }

    func lock(_ id: String) { system.lock(id) }

    func sendClipboard(to id: String) {
        guard let payload = clipboard.payloadForSendNow() else { return }
        connections.send(.clipboard, payload: payload, to: id)
    }

    func send(_ entry: ClipboardEntry, to id: String) {
        guard let message = entry.message, let payload = try? JSONEncoder().encode(message) else { return }
        connections.send(.clipboard, payload: payload, to: id)
    }

    func disconnect(_ id: String) { connections.disconnect(id) }

    func forget(_ id: String) {
        connections.disconnect(id)
        trusted.remove(id)
        syncInput()
    }

    func sendFiles(_ urls: [URL], to id: String) {
        guard settings.fileSharing else { return }
        files.sendFiles(urls, to: id)
    }

    func pickAndSendFiles(to id: String) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { sendFiles(panel.urls, to: id) }
    }
}
