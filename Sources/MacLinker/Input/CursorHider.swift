import AppKit
import CoreGraphics

/// Hides the pointer on this Mac while it is driving another Mac.
///
/// macOS only honours "hide cursor" from the frontmost app, and the private background override
/// isn't reliable on newer releases. So while controlling, MacLinker briefly becomes the frontmost
/// app (its own windows are tucked away so nothing pops up), hides the cursor, and on release puts
/// everything back and re-activates whichever app you were using.
/// Main thread only.
enum CursorHider {
    private static var hidden = false
    private static var previousApp: NSRunningApplication?

    static func hide() {
        guard !hidden else { return }
        hidden = true
        let me = NSRunningApplication.current
        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == me.processIdentifier ? nil : front
        WindowManager.shared.suspendForControl()
        NSApp.activate(ignoringOtherApps: true)
        CGDisplayHideCursor(CGMainDisplayID())
        NSCursor.hide()
    }

    static func show() {
        guard hidden else { return }
        hidden = false
        CGDisplayShowCursor(CGMainDisplayID())
        NSCursor.unhide()
        WindowManager.shared.resumeAfterControl()
        previousApp?.activate()
        previousApp = nil
    }
}
