import Foundation
import CoreGraphics

/// Two session-wide event taps:
///
/// - **passive** (listen-only, always on): used while the pointer is on this Mac. A listen-only tap
///   never sits in the event path, so it adds zero latency to normal mouse and keyboard use.
/// - **active** (can swallow events, enabled only while controlling another Mac): blocks local
///   input and forwards it to the peer.
final class InputMonitor {
    var onPassive: ((CGEventType, CGEvent) -> Void)?
    /// Return true to swallow the event.
    var onActive: ((CGEventType, CGEvent) -> Bool)?

    fileprivate final class Context {
        unowned let monitor: InputMonitor
        let isActive: Bool
        init(_ m: InputMonitor, active: Bool) { monitor = m; isActive = active }
    }

    private let runLoop: CFRunLoop
    init(runLoop: CFRunLoop) { self.runLoop = runLoop }

    private var passiveTap: CFMachPort?
    private var activeTap: CFMachPort?
    private var sources: [CFRunLoopSource] = []
    private var contexts: [Context] = []

    var isRunning: Bool { passiveTap != nil && activeTap != nil }

    private static let types: [CGEventType] = [
        .mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged,
        .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged,
        .scrollWheel, .keyDown, .keyUp, .flagsChanged,
    ]

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = Self.types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        func make(active: Bool) -> CFMachPort? {
            let ctx = Context(self, active: active)
            contexts.append(ctx)
            return CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                     options: active ? .defaultTap : .listenOnly, eventsOfInterest: mask,
                                     callback: inputTapCallback, userInfo: Unmanaged.passUnretained(ctx).toOpaque())
        }
        guard let passive = make(active: false), let active = make(active: true) else {
            contexts.removeAll()
            return false  // Accessibility / Input Monitoring not granted yet
        }
        for tap in [passive, active] {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)!
            CFRunLoopAddSource(runLoop, source, .commonModes)
            sources.append(source)
        }
        CGEvent.tapEnable(tap: passive, enable: true)
        CGEvent.tapEnable(tap: active, enable: false)
        passiveTap = passive
        activeTap = active
        return true
    }

    /// Turn the swallowing tap on only while another Mac is being driven.
    func setActive(_ on: Bool) {
        if let activeTap { CGEvent.tapEnable(tap: activeTap, enable: on) }
    }

    fileprivate func reenable(_ ctx: Context) {
        if ctx.isActive { return }  // the active tap is re-enabled by the control state, not by the OS
        if let passiveTap { CGEvent.tapEnable(tap: passiveTap, enable: true) }
    }
}

private func inputTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                              refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let ctx = Unmanaged<InputMonitor.Context>.fromOpaque(refcon).takeUnretainedValue()
    let monitor = ctx.monitor
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        monitor.reenable(ctx)
        return Unmanaged.passUnretained(event)
    }
    // Ignore events we injected ourselves.
    if event.getIntegerValueField(.eventSourceUserData) == K.injectedMarker {
        return Unmanaged.passUnretained(event)
    }
    if ctx.isActive {
        return (monitor.onActive?(type, event) ?? false) ? nil : Unmanaged.passUnretained(event)
    }
    monitor.onPassive?(type, event)
    return Unmanaged.passUnretained(event)
}
