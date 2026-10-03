import Foundation
import ServiceManagement

final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var inputSharing: Bool { didSet { defaults.set(inputSharing, forKey: "inputSharing") } }
    @Published var clipboardSharing: Bool { didSet { defaults.set(clipboardSharing, forKey: "clipboardSharing") } }
    @Published var fileSharing: Bool { didSet { defaults.set(fileSharing, forKey: "fileSharing") } }
    /// Let paired Macs change this Mac's brightness and volume.
    @Published var remoteSystemControl: Bool { didSet { defaults.set(remoteSystemControl, forKey: "remoteSystemControl") } }
    /// Let paired Macs lock this Mac's screen.
    @Published var allowRemoteLock: Bool { didSet { defaults.set(allowRemoteLock, forKey: "allowRemoteLock") } }
    /// Copy a file, folder or app here, paste it on the other Mac.
    @Published var fileClipboard: Bool { didSet { defaults.set(fileClipboard, forKey: "fileClipboard") } }
    /// Keep dragging a file, link or app across the screen edge to the other Mac.
    @Published var dragAcrossEdge: Bool { didSet { defaults.set(dragAcrossEdge, forKey: "dragAcrossEdge") } }
    /// Bind LAN connections to the physical interface so a VPN (Outline) can't swallow them.
    @Published var pinToLAN: Bool { didSet { defaults.set(pinToLAN, forKey: "pinToLAN") } }
    @Published var edgePush: Double { didSet { defaults.set(edgePush, forKey: "edgePush") } }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            if launchAtLogin { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    init() {
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
        }
        inputSharing = bool("inputSharing", true)
        clipboardSharing = bool("clipboardSharing", true)
        fileSharing = bool("fileSharing", true)
        remoteSystemControl = bool("remoteSystemControl", true)
        allowRemoteLock = bool("allowRemoteLock", true)
        fileClipboard = bool("fileClipboard", true)
        dragAcrossEdge = bool("dragAcrossEdge", true)
        pinToLAN = bool("pinToLAN", true)
        launchAtLogin = bool("launchAtLogin", false)
        let push = UserDefaults.standard.double(forKey: "edgePush")
        edgePush = push > 0 ? push : K.defaultEdgePush
    }
}
