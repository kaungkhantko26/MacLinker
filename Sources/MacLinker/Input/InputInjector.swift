import Foundation
import CoreGraphics

/// Turns received input messages into real events on this Mac (the Mouse/KeyboardInjector pair).
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var downButtons = Set<Int>()
    private var downKeys = Set<UInt16>()

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: K.injectedMarker)
        event.post(tap: .cghidEventTap)
    }

    func warp(to p: CGPoint) {
        CGWarpMouseCursorPosition(p)
        move(to: p, delta: .zero)
    }

    func move(to p: CGPoint, delta: CGPoint) {
        let type: CGEventType
        let button: CGMouseButton
        if downButtons.contains(0) { type = .leftMouseDragged; button = .left }
        else if downButtons.contains(1) { type = .rightMouseDragged; button = .right }
        else if let n = downButtons.first { type = .otherMouseDragged; button = CGMouseButton(rawValue: UInt32(n)) ?? .center }
        else { type = .mouseMoved; button = .left }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        e?.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
        e?.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
        post(e)
    }

    func button(_ n: Int, down: Bool, clickCount: Int, at p: CGPoint) {
        let type: CGEventType
        switch (n, down) {
        case (0, true): type = .leftMouseDown
        case (0, false): type = .leftMouseUp
        case (1, true): type = .rightMouseDown
        case (1, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        case (_, false): type = .otherMouseUp
        }
        if down { downButtons.insert(n) } else { downButtons.remove(n) }
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p,
                        mouseButton: CGMouseButton(rawValue: UInt32(n)) ?? .center)
        e?.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        post(e)
    }

    func isButtonDown(_ n: Int) -> Bool { downButtons.contains(n) }

    /// Presses and releases Escape, which cancels a drag in progress without dropping anything.
    func cancelDrag() {
        key(53, down: true, flags: [], autorepeat: false)
        key(53, down: false, flags: [], autorepeat: false)
    }

    func scroll(dx: Int32, dy: Int32, continuous: Bool) {
        post(CGEvent(scrollWheelEvent2Source: source, units: continuous ? .pixel : .line,
                     wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
    }

    func key(_ code: UInt16, down: Bool, flags: CGEventFlags, autorepeat: Bool) {
        if down { downKeys.insert(code) } else { downKeys.remove(code) }
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        e?.flags = flags
        e?.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
        post(e)
    }

    func flagsChanged(_ code: UInt16, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: true)
        e?.type = .flagsChanged
        e?.flags = flags
        post(e)
    }

    /// Releases anything still held, so a dropped connection can't leave a stuck button or key.
    func releaseAll(at p: CGPoint) {
        for n in downButtons { button(n, down: false, clickCount: 1, at: p) }
        for k in downKeys { key(k, down: false, flags: [], autorepeat: false) }
        flagsChanged(0, flags: [])
    }
}
