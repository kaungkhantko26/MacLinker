import Foundation
import CoreGraphics

/// Session-wide event tap for mouse and keyboard (the "MouseMonitor + KeyboardMonitor" in one,
/// because macOS delivers both through a single tap). Runs on the main run loop.
final class InputMonitor {
    /// Return true to swallow the event.
    var handler: ((CGEventType, CGEvent) -> Bool)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    private static let types: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged,
    ]

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = Self.types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: inputTapCallback, userInfo: refcon) else {
            return false  // Accessibility / Input Monitoring not granted yet
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    fileprivate func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenable()
        return Unmanaged.passUnretained(event)
    }
    // Ignore events MacLinker itself injected.
    if event.getIntegerValueField(.eventSourceUserData) == K.injectedMarker {
        return Unmanaged.passUnretained(event)
    }
    let swallow = monitor.handler?(type, event) ?? false
    return swallow ? nil : Unmanaged.passUnretained(event)
}
