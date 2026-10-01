import Foundation
import ServiceManagement

final class Settings: ObservableObject {
    private let defaults = UserDefaults.standard

    @Published var inputSharing: Bool { didSet { defaults.set(inputSharing, forKey: "inputSharing") } }
    @Published var clipboardSharing: Bool { didSet { defaults.set(clipboardSharing, forKey: "clipboardSharing") } }
    @Published var fileSharing: Bool { didSet { defaults.set(fileSharing, forKey: "fileSharing") } }
    /// Let paired Macs change this Mac's brightness and volume.
    @Published var remoteSystemControl: Bool { didSet { defaults.set(remoteSystemControl, forKey: "remoteSystemControl") } }
    /// Skip the confirmation when a paired Mac asks to use this Mac's screen as its display.
    @Published var displayAutoAccept: Bool { didSet { defaults.set(displayAutoAccept, forKey: "displayAutoAccept") } }
    @Published var displayQuality: String { didSet { defaults.set(displayQuality, forKey: "displayQuality") } }
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
        displayAutoAccept = bool("displayAutoAccept", false)
        displayQuality = UserDefaults.standard.string(forKey: "displayQuality") ?? "balanced"
        pinToLAN = bool("pinToLAN", true)
        launchAtLogin = bool("launchAtLogin", false)
        let push = UserDefaults.standard.double(forKey: "edgePush")
        edgePush = push > 0 ? push : K.defaultEdgePush
    }
}
