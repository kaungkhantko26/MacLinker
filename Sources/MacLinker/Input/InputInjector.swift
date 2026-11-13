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

    func scroll(dx: Int32, dy: Int32, continuous: Bool, phase: UInt8 = 0, momentum: UInt8 = 0) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: continuous ? .pixel : .line,
                              wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        if continuous {
            // Trackpad scrolling: carry the phases so apps treat it as a finger scroll (inertia, overscroll, swipe navigation).
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase))
            e.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum))
        }
        post(e)
    }

    /// Replays a trackpad gesture. Pinch and rotate are posted as real gesture events (the same private fields
    /// AppKit reads them from); swipes become the back/forward shortcut every browser and Finder understands.
    func gesture(_ g: GesturePayload, at p: CGPoint) {
        switch g.kind {
        case .magnify: postGesture(hidType: 8, valueField: 113, value: Double(g.value), phase: g.phase, at: p)
        case .rotate: postGesture(hidType: 5, valueField: 114, value: Double(g.value), phase: g.phase, at: p)
        case .swipe:
            // Swipe right (deltaX -1) goes back, swipe left (deltaX 1) goes forward. 33 is "[", 30 is "]".
            guard g.value != 0 else { return }
            let code: UInt16 = g.value < 0 ? 33 : 30
            key(code, down: true, flags: .maskCommand, autorepeat: false)
            key(code, down: false, flags: .maskCommand, autorepeat: false)
        case .smartMagnify: break
        }
    }

    private func postGesture(hidType: Int64, valueField: UInt32, value: Double, phase: UInt8, at p: CGPoint) {
        let gestureType: CGEventType? = CGEventType(rawValue: 29)       // NSEventTypeGesture
        let hidField: CGEventField? = CGEventField(rawValue: 110)
        let amount: CGEventField? = CGEventField(rawValue: valueField)
        let phaseField: CGEventField? = CGEventField(rawValue: 132)
        guard let gestureType, let hidField, let amount, let phaseField,
              let e = CGEvent(source: source) else { return }
        e.type = gestureType
        e.location = p
        e.setIntegerValueField(hidField, value: hidType)
        e.setDoubleValueField(amount, value: value)
        e.setIntegerValueField(phaseField, value: Int64(phase))
        e.setIntegerValueField(.eventSourceUserData, value: K.injectedMarker)
        e.post(tap: .cgSessionEventTap)
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
