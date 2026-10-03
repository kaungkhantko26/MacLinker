import Foundation
import AppKit
import CoreGraphics

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
    /// Called on the input thread when the pointer reaches an edge during a drag; announces the dragged items to the peer.
    /// Returns true if they were announced (and control should pass over).
    var dragProbe: ((String) -> Bool)?
    /// Called on the main thread when control has just moved to this Mac (or back), with the point to pick a drag up at.
    var dragReceiver: ((String, CGPoint) -> Void)?

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
    private var dragEnabled = true
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var dragDetector = DragDetector()          // drags that start on this Mac's own mouse
    private var injectedDragDetector = DragDetector()  // drags the controlling Mac starts here
    /// True while a drag handed over from the other Mac is being held by an injected button press.
    private var handoffButtonHeld = false

    init() {
        monitor = InputMonitor(runLoop: thread.runLoop)
        monitor.onPassive = { [weak self] type, event in self?.handleLocal(type, event) }
        monitor.onActive = { [weak self] type, event in self?.handleActive(type, event) ?? false }
    }

    var isTapRunning: Bool { monitor.isRunning }
    @discardableResult func startMonitoring() -> Bool { monitor.start() }

    /// Thread-safe: settings and layout changes are applied on the input thread, in order.
    func configure(enabled: Bool, push: Double, edgePeers: [Edge: String], dragEnabled: Bool = true) {
        thread.perform {
            self.dragEnabled = dragEnabled
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
        // Remember the drag pasteboard when the button goes down: a real drag is when it changes afterwards.
        if type == .leftMouseDown { dragDetector.buttonDown(pasteboardCount: dragPasteboard.changeCount); return }
        if type == .leftMouseUp { dragDetector.buttonUp(); return }
        guard case .local = controlState, type == .mouseMoved || type == .leftMouseDragged
                || type == .rightMouseDragged || type == .otherMouseDragged,
              enabled, !edgePeers.isEmpty else { return }
        let delta = CGPoint(x: event.getDoubleValueField(.mouseEventDeltaX),
                            y: event.getDoubleValueField(.mouseEventDeltaY))
        detector.threshold = push
        if let hit = detector.update(location: event.location, delta: delta,
                                     bounds: ScreenGeometry.bounds, edges: Set(edgePeers.keys)),
           let peer = edgePeers[hit.edge] {
            let buttons = NSEvent.pressedMouseButtons
            if buttons == 0 {
                beginControlling(peer: peer, edge: hit.edge, position: hit.position)
            } else if buttons == 1, dragEnabled, type == .leftMouseDragged,
                      dragDetector.isDragging(pasteboardCount: dragPasteboard.changeCount),
                      dragProbe?(peer) == true {
                // A drag is in progress and its items have been announced: pass control over carrying the drag.
                beginControlling(peer: peer, edge: hit.edge, position: hit.position, abandoningLocalDrag: true)
            }
        }
    }

    /// Active tap (only enabled while controlling): swallow local input and stream it to the peer.
    private func handleActive(_ type: CGEventType, _ event: CGEvent) -> Bool {
        guard case .controlling(let peer, _) = controlState else { return false }
        return forward(type, event, to: peer)
    }

    private func beginControlling(peer: String, edge: Edge, position: Float, abandoningLocalDrag: Bool = false) {
        setState(.controlling(peer: peer, edge: edge))
        monitor.setActive(true)
        CGAssociateMouseAndMouseCursorPosition(0)
        setCursorHidden(true)
        send?(peer, .enterControl, ControlPayload(edge: edge, position: position).encode())
        // The drag continues on the other Mac; cancel the one here, or it would sit frozen waiting for a mouse-up
        // that this Mac will never see.
        if abandoningLocalDrag { injector.cancelDrag() }
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
                let arrival = virtualCursor
                DispatchQueue.main.async { self.dragReceiver?(peer, arrival) }   // starts a drag if one was announced
            case .releaseControl:
                let p = try ControlPayload.decode(message.payload)
                switch controlState {
                case .controlling(let controlled, let edge) where controlled == peer:
                    let warp = p.position >= 0 ? p.position : nil
                    endControlling(warpTo: warp)
                    if let warp, dragEnabled {
                        let point = edge.point(at: warp, inset: 6, in: ScreenGeometry.bounds)
                        DispatchQueue.main.async { self.dragReceiver?(peer, point) }   // a drag may be coming back
                    }
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
                    // A drag that began on this Mac goes back with the pointer; abandon it here.
                    if dragEnabled, injector.isButtonDown(0),
                       injectedDragDetector.isDragging(pasteboardCount: dragPasteboard.changeCount),
                       dragProbe?(peer) == true {
                        injector.cancelDrag()
                    }
                    send?(peer, .releaseControl, ControlPayload(edge: returnEdge, position: hit.position).encode())
                    endControlled()
                }
            case .mouseButton:
                guard isControlled(by: peer) else { return }
                let p = try MouseButtonPayload.decode(message.payload)
                if p.button == 0 {
                    if p.down { injectedDragDetector.buttonDown(pasteboardCount: dragPasteboard.changeCount) }
                    else { injectedDragDetector.buttonUp(); handoffButtonHeld = false }
                }
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
        // Leaving while a handed-over drag is still held: cancel it rather than drop it on whatever is at the edge.
        if handoffButtonHeld { injector.cancelDrag(); handoffButtonHeld = false }
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

/// Lets the drag handoff press and release the left button on this Mac through the input thread.
extension InputManager: MouseInjecting {
    func pressLeft(at point: CGPoint) {
        thread.perform {
            // While another Mac is driving, use the live pointer position rather than where it was a moment ago.
            var target = point
            if case .controlled = self.controlState { target = self.virtualCursor }
            self.injector.button(0, down: true, clickCount: 1, at: target)
            self.handoffButtonHeld = true
        }
    }

    func releaseLeft(at point: CGPoint) {
        thread.perform {
            self.injector.button(0, down: false, clickCount: 1, at: point)
            self.handoffButtonHeld = false
        }
    }
}
