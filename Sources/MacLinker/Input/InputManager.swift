import Foundation
import AppKit
import CoreGraphics

// Private WindowServer calls (the same ones Synergy/Barrier use) that allow hiding the cursor
// while this app is not frontmost. Without them the cursor stays frozen on screen.
@_silgen_name("CGSDefaultConnectionForThread") private func CGSDefaultConnectionForThread() -> Int32
@_silgen_name("CGSSetConnectionProperty")
private func CGSSetConnectionProperty(_ cid: Int32, _ target: Int32, _ key: CFString, _ value: CFTypeRef) -> Int32

private let allowBackgroundCursor: Void = {
    let cid = CGSDefaultConnectionForThread()
    _ = CGSSetConnectionProperty(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
}()

/// Owns "who is driving": this Mac's own devices, or a peer's.
///
/// - `.controlling`: our pointer crossed a screen edge. Local events are swallowed and streamed to the peer.
/// - `.controlled`: a peer is driving us. Its events are injected, and pushing against the
///   edge we were entered from hands control back.
final class InputManager: ObservableObject {
    enum ControlState: Equatable {
        case local
        case controlling(peer: String, edge: Edge)
        case controlled(peer: String, returnEdge: Edge)
    }

    /// Mirror of the real state for the UI. The real state lives on the input thread.
    @Published private(set) var state: ControlState = .local
    var send: ((String, MessageType, Data) -> Void)?

    // Everything below is owned by the input thread; the public methods hop onto it.
    private let thread = InputThread()
    private let monitor: InputMonitor
    private var controlState: ControlState = .local
    private var enabled = true
    private var push = K.defaultEdgePush
    /// Connected peers positioned relative to this Mac, keyed by the edge they sit on.
    private var edgePeers: [Edge: String] = [:]
    private let injector = InputInjector()
    private var detector = ScreenEdgeDetector()
    private var returnDetector = ScreenEdgeDetector()
    private var virtualCursor = CGPoint.zero
    private var cursorHidden = false
    private var pendingMove = CGPoint.zero
    private var flushTimer: CFRunLoopTimer?

    init() {
        monitor = InputMonitor(runLoop: thread.runLoop)
        monitor.onPassive = { [weak self] type, event in self?.handleLocal(type, event) }
        monitor.onActive = { [weak self] type, event in self?.handleActive(type, event) ?? false }
    }

    var isTapRunning: Bool { monitor.isRunning }
    @discardableResult func startMonitoring() -> Bool { monitor.start() }

    /// Thread-safe: settings and layout changes are applied on the input thread, in order.
    func configure(enabled: Bool, push: Double, edgePeers: [Edge: String]) {
        thread.perform {
            self.enabled = enabled
            self.push = push
            self.edgePeers = edgePeers
        }
    }

    /// Cursor visibility must be changed from the main thread, and only after the connection has been
    /// allowed to set it from the background. Calls are issued in order, and balanced (hide/show counts stack).
    private func setCursorHidden(_ hidden: Bool) {
        guard hidden != cursorHidden else { return }
        cursorHidden = hidden
        DispatchQueue.main.async {
            _ = allowBackgroundCursor  // best effort; CursorHider does the reliable part
            if hidden { CursorHider.hide() } else { CursorHider.show() }
        }
    }

    private func setState(_ new: ControlState) {
        controlState = new
        DispatchQueue.main.async { self.state = new }
    }

    // MARK: Local events (controller side)

    /// Passive tap: the pointer is on this Mac. Only watches for the edge push.
    private func handleLocal(_ type: CGEventType, _ event: CGEvent) {
        guard case .local = controlState, type == .mouseMoved || type == .leftMouseDragged
                || type == .rightMouseDragged || type == .otherMouseDragged,
              enabled, !edgePeers.isEmpty else { return }
        let delta = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX),
                            y: event.getDoubleValueField(.mouseEventDeltaY))
        detector.threshold = push
        if let hit = detector.update(location: event.location, delta: delta,
                                     bounds: ScreenGeometry.bounds, edges: Set(edgePeers.keys)),
           let peer = edgePeers[hit.edge], NSEvent.pressedMouseButtons == 0 {
            beginControlling(peer: peer, edge: hit.edge, position: hit.position)
        }
    }

    /// Active tap (only enabled while controlling): swallow local input and stream it to the peer.
    private func handleActive(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard case .controlling(let peer, _) = controlState else { return false }
        return forward(type, event, to: peer)
    }

    private func beginControlling(peer: String, edge: Edge, position: Float) {
        setState(.controlling(peer: peer, edge: edge))
        monitor.setActive(true)
        CGAssociateMouseAndMouseCursorPosition(0)
        setCursorHidden(true)
        send?(peer, .enterControl, ControlPayload(edge: edge, position: position).encode())
        startFlushing(to: peer)
    }

    /// Mice report up to 1000 Hz. Sending each report separately floods the link and the
    /// receiver, which is what makes the remote pointer lag. Batch movement at ~250 Hz instead.
    private func startFlushing(to peer: String) {
        pendingMove = .zero
        let t = CFRunLoopTimerCreateWithHandler(kCFAllocatorDefault, CFAbsoluteTimeGetCurrent(), 0.003, 0, 0) { [weak self] _ in
            self?.flushMove(to: peer)
        }
        CFRunLoopAddTimer(CFRunLoopGetCurrent(), t, .commonModes)
        flushTimer = t
    }

    private func flushMove(to peer: String) {
        guard pendingMove != .zero else { return }
        let p = MouseMovePayload(dx: Float(pendingMove.x), dy: Float(pendingMove.y))
        pendingMove = .zero
        send?(peer, .mouseMove, p.encode())
    }

    private func endControlling(warpTo position: Float?) {
        guard case .controlling(_, let edge) = controlState else { return }
        monitor.setActive(false)
        if let t = flushTimer { CFRunLoopTimerInvalidate(t) }
        flushTimer = nil
        pendingMove = .zero
        if let position {
            CGWarpMouseCursorPosition(edge.point(at: position, inset: 6, in: ScreenGeometry.bounds))
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        setCursorHidden(false)
        detector.reset()
        setState(.local)
    }

    /// Emergency exit: Control + Option + Command + Esc.
    private func isEscapeChord(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard type == .keyDown, event.getIntegerValueField(.keyboardEventKeycode) == 53 else { return false }
        let need: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand]
        return event.flags.intersection(need) == need
    }

    private func forward(_ type: CGEventType, _ event: CGEvent, to peer: String) -> Bool {
        if isEscapeChord(type, event) {
            send?(peer, .releaseControl, ControlPayload(edge: .left, position: -1).encode())
            endControlling(warpTo: nil)
            return true
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: break
        default: flushMove(to: peer)  // keep movement ordered before clicks/keys
        }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            pendingMove.x += event.getDoubleValueField(.mouseEventDeltaX)
            pendingMove.y += event.getDoubleValueField(.mouseEventDeltaY)
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp:
            let down = type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
            let p = MouseButtonPayload(button: UInt8(clamping: event.getIntegerValueField(.mouseEventButtonNumber)),
                                       down: down,
                                       clickCount: UInt8(clamping: event.getIntegerValueField(.mouseEventClickState)))
            send?(peer, .mouseButton, p.encode())
        case .scrollWheel:
            let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let dy = continuous ? event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
                                : event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let dx = continuous ? event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
                                : event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            send?(peer, .scroll, ScrollPayload(dx: Int32(clamping: dx), dy: Int32(clamping: dy),
                                               continuous: continuous).encode())
        case .keyDown, .keyUp:
            let p = KeyPayload(keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                               down: type == .keyDown, flags: event.flags.rawValue,
                               autorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
            send?(peer, .keyEvent, p.encode())
        case .flagsChanged:
            let p = KeyPayload(keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)),
                               down: true, flags: event.flags.rawValue, autorepeat: false)
            send?(peer, .flagsChanged, p.encode())
        default:
            return false
        }
        return true
    }

    // MARK: Remote messages

    func handle(message: MacLinkerMessage, from peer: String) {
        thread.perform { self.process(message, from: peer) }
    }

    private func process(_ message: MacLinkerMessage, from peer: String) {
        do {
            switch message.type {
            case .enterControl:
                guard enabled, case .local = controlState else {
                    send?(peer, .releaseControl, ControlPayload(edge: .left, position: -1).encode())
                    return
                }
                let p = try ControlPayload.decode(message.payload)
                let returnEdge = p.edge.opposite
                virtualCursor = returnEdge.point(at: p.position, inset: 2, in: ScreenGeometry.bounds)
                returnDetector = ScreenEdgeDetector(threshold: push)
                setState(.controlled(peer: peer, returnEdge: returnEdge))
                injector.warp(to: virtualCursor)
            case .releaseControl:
                let p = try ControlPayload.decode(message.payload)
                switch controlState {
                case .controlling(let controlled, _) where controlled == peer:
                    endControlling(warpTo: p.position >= 0 ? p.position : nil)
                case .controlled(let controller, _) where controller == peer:
                    endControlled()
                default: break
                }
            case .mouseMove:
                guard case .controlled(let controller, let returnEdge) = controlState, controller == peer else { return }
                let p = try MouseMovePayload.decode(message.payload)
                let delta = CGPoint(x: CGFloat(p.dx), y: CGFloat(p.dy))
                let b = ScreenGeometry.bounds
                virtualCursor = CGPoint(x: min(max(virtualCursor.x + delta.x, b.minX), b.maxX - 1),
                                        y: min(max(virtualCursor.y + delta.y, b.minY), b.maxY - 1))
                injector.move(to: virtualCursor, delta: delta)
                if let hit = returnDetector.update(location: virtualCursor, delta: delta, bounds: b, edges: [returnEdge]) {
                    send?(peer, .releaseControl, ControlPayload(edge: returnEdge, position: hit.position).encode())
                    endControlled()
                }
            case .mouseButton:
                guard isControlled(by: peer) else { return }
                let p = try MouseButtonPayload.decode(message.payload)
                injector.button(Int(p.button), down: p.down, clickCount: Int(p.clickCount), at: virtualCursor)
            case .scroll:
                guard isControlled(by: peer) else { return }
                let p = try ScrollPayload.decode(message.payload)
                injector.scroll(dx: p.dx, dy: p.dy, continuous: p.continuous)
            case .keyEvent:
                guard isControlled(by: peer) else { return }
                let p = try KeyPayload.decode(message.payload)
                injector.key(p.keyCode, down: p.down, flags: CGEventFlags(rawValue: p.flags), autorepeat: p.autorepeat)
            case .flagsChanged:
                guard isControlled(by: peer) else { return }
                let p = try KeyPayload.decode(message.payload)
                injector.flagsChanged(p.keyCode, flags: CGEventFlags(rawValue: p.flags))
            default: break
            }
        } catch {
            Log.error("bad input message: \(error)")
        }
    }

    private func isControlled(by peer: String) -> Bool {
        if case .controlled(let c, _) = controlState { return c == peer }
        return false
    }

    private func endControlled() {
        injector.releaseAll(at: virtualCursor)
        returnDetector.reset()
        setState(.local)
    }

    /// A peer vanished: never leave the pointer frozen or keys stuck.
    func peerDisconnected(_ peer: String) {
        thread.perform { self.handleDisconnect(peer) }
    }

    private func handleDisconnect(_ peer: String) {
        switch controlState {
        case .controlling(let p, _) where p == peer: endControlling(warpTo: 0.5)
        case .controlled(let p, _) where p == peer: endControlled()
        default: break
        }
    }

    /// Sharing was switched off or the peer layout changed under us.
    func abortIfNeeded() {
        thread.perform {
            if case .controlling(let peer, _) = self.controlState, !self.enabled {
                self.send?(peer, .releaseControl, ControlPayload(edge: .left, position: -1).encode())
                self.endControlling(warpTo: nil)
            }
            if case .controlled = self.controlState, !self.enabled { self.endControlled() }
        }
    }
}
