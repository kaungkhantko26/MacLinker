import Foundation
import AppKit
import ApplicationServices

final class PermissionManager: ObservableObject {
    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    private var timer: Timer?

    var allGranted: Bool { accessibility && inputMonitoring }

    func start() {
        refresh()
        // Asking registers MacLinker in the privacy lists so it shows up there to be switched on.
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        if !AXIsProcessTrusted() { requestAccessibility() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func refresh() {
        let a = AXIsProcessTrusted()
        let i = CGPreflightListenEventAccess()
        if a != accessibility { accessibility = a }
        if i != inputMonitoring { inputMonitoring = i }
    }

    func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    func requestInputMonitoring() { _ = CGRequestListenEventAccess() }

    /// Tries the current Settings deep link, then the older one, then just opens System Settings.
    func openPrivacySettings(_ pane: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
            "x-apple.systempreferences:com.apple.preference.security?\(pane)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
        ].compactMap(URL.init(string:))
        func attempt(_ i: Int) {
            guard i < candidates.count else {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                return
            }
            NSWorkspace.shared.open(candidates[i], configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if error != nil { DispatchQueue.main.async { attempt(i + 1) } }
            }
        }
        attempt(0)
    }
}
