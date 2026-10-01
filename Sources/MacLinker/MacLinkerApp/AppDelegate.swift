import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        AppState.shared.start()
        WindowManager.shared.showMain()
    }

    /// Clicking the Dock icon brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showMain()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// AppKit-managed windows: reliable for an accessory (menu-bar-only) app.
final class WindowManager {
    static let shared = WindowManager()
    private var main: NSWindow?
    private var pairingWindow: NSWindow?

    func showMain() {
        if main == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "MacLinker"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: MainView().environmentObject(AppState.shared))
            w.center()
            main = w
        }
        present(main)
    }

    func showPairing() {
        if pairingWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 300),
                             styleMask: [.titled], backing: .buffered, defer: false)
            w.title = "Pair with a Mac"
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.contentViewController = NSHostingController(rootView: PairingView().environmentObject(AppState.shared))
            w.center()
            pairingWindow = w
        }
        present(pairingWindow)
    }

    func hidePairing() { pairingWindow?.orderOut(nil) }

    private func present(_ w: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        w?.makeKeyAndOrderFront(nil)
    }
}
