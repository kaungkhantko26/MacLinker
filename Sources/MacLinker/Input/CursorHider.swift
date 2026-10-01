import AppKit
import CoreGraphics

/// Hides the pointer on this Mac while it is driving another Mac, so only one pointer is visible.
///
/// Two layers, because macOS is picky about who may hide the cursor:
/// 1. The recipe used by Synergy/Barrier/Deskflow: tell the WindowServer this app may set the cursor
///    while in the background (private `SetsCursorInBackground`), then `CGDisplayHideCursor` on the
///    display the pointer is on.
/// 2. If MacLinker has no window open, also become the frontmost app for the duration (nothing visible
///    changes), since macOS honours "hide cursor" for the frontmost app unconditionally; focus is handed
///    back afterwards. If a MacLinker window is open it is never moved, hidden or raised.
/// Main thread only.
enum CursorHider {
    private static var hidden = false
    private static var previousApp: NSRunningApplication?
    private static var prepared = false

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias SetPropertyFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32

    /// Call once at launch, on the main thread, before the first hide.
    @discardableResult
    static func prepare() -> Bool {
        guard !prepared else { return true }
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let c = dlsym(rtldDefault, "_CGSDefaultConnection"),
              let s = dlsym(rtldDefault, "CGSSetConnectionProperty") else {
            Log.error("cursor hiding: WindowServer symbols not found")
            return false
        }
        let cid = unsafeBitCast(c, to: ConnectionFn.self)()
        let result = unsafeBitCast(s, to: SetPropertyFn.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
        Log.info("cursor hiding: background override \(result == 0 ? "enabled" : "failed (\(result))")")
        prepared = result == 0
        return prepared
    }

    /// The display the pointer is currently on (hiding is per display).
    private static var pointerDisplay: CGDirectDisplayID {
        var id = CGDirectDisplayID()
        var count: UInt32 = 0
        let p = CGEvent(source: nil)?.location ?? .zero
        CGGetDisplaysWithPoint(p, 1, &id, &count)
        return count > 0 ? id : CGMainDisplayID()
    }

    private static var hiddenOn: CGDirectDisplayID = 0

    static func hide() {
        guard !hidden else { return }
        hidden = true
        prepare()
        let me = NSRunningApplication.current
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == me.processIdentifier ? nil : front
        let ownWindowOpen = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        if !ownWindowOpen { NSApp.activate(ignoringOtherApps: true) } else { previousApp = nil }
        hiddenOn = pointerDisplay
        CGDisplayHideCursor(hiddenOn)
        NSCursor.hide()
    }

    static func show() {
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(hiddenOn)
        NSCursor.unhide()
        previousApp?.activate()
        previousApp = nil
    }

    /// Settings > "Test pointer hiding": hides the pointer for a few seconds so you can see if it works.
    static func test(seconds: Double = 5) {
        hide()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { show() }
    }
}
