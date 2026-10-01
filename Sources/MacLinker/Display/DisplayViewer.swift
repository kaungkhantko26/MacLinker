import AppKit
import AVFoundation
import CoreMedia

/// The full-screen window that shows the other Mac's picture and sends this Mac's mouse and keyboard back.
final class DisplayViewer {
    var onPointer: ((DisplayPointerPayload) -> Void)?
    var onScroll: ((ScrollPayload) -> Void)?
    var onKey: ((MessageType, KeyPayload) -> Void)?
    var onKeyframeNeeded: (() -> Void)?
    /// Control+Option+Command+Esc, or the window being closed.
    var onExit: (() -> Void)?

    private var window: NSWindow?
    private var view: DisplayLayerView?
    private var format: CMVideoFormatDescription?
    private var previousPresentation: NSApplication.PresentationOptions = []
    private var cursorHidden = false

    var isOpen: Bool { window != nil }

    func open(on screen: NSScreen) {
        guard window == nil else { return }
        let w = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
        w.level = .screenSaver
        w.backgroundColor = .black
        w.isReleasedWhenClosed = false
        w.acceptsMouseMovedEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = DisplayLayerView(frame: NSRect(origin: .zero, size: screen.frame.size))
        v.onPointer = { [weak self] in self?.onPointer?($0) }
        v.onScroll = { [weak self] in self?.onScroll?($0) }
        v.onKey = { [weak self] in self?.onKey?($0, $1) }
        v.onExit = { [weak self] in self?.onExit?() }
        w.contentView = v
        w.setFrame(screen.frame, display: true)
        window = w
        view = v

        previousPresentation = NSApp.presentationOptions
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(v)
        if !cursorHidden { NSCursor.hide(); cursorHidden = true }
    }

    func close() {
        if cursorHidden { NSCursor.unhide(); cursorHidden = false }
        NSApp.presentationOptions = previousPresentation
        window?.orderOut(nil)
        window = nil
        view = nil
        format = nil
    }

    func setParameterSets(_ sets: [Data]) {
        format = makeH264FormatDescription(parameterSets: sets)
        view?.displayLayer.flushAndRemoveImage()
    }

    func show(_ frame: DisplayFramePayload) {
        guard let layer = view?.displayLayer, let format else { onKeyframeNeeded?(); return }
        if layer.status == .failed {
            layer.flush()
            onKeyframeNeeded?()
            return
        }
        guard let sample = makeSampleBuffer(frame: frame.data, format: format, timestampMs: frame.timestampMs) else { return }
        layer.enqueue(sample)
    }
}

final class DisplayLayerView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()
    var onPointer: ((DisplayPointerPayload) -> Void)?
    var onScroll: ((ScrollPayload) -> Void)?
    var onKey: ((MessageType, KeyPayload) -> Void)?
    var onExit: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resize   // the host display matches this screen's shape
        displayLayer.frame = bounds
        layer?.addSublayer(displayLayer)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    private func normalized(_ event: NSEvent) -> (Float, Float) {
        let p = convert(event.locationInWindow, from: nil)
        return (Float(p.x / max(bounds.width, 1)), Float(1 - p.y / max(bounds.height, 1)))
    }

    private func pointer(_ kind: DisplayPointerPayload.Kind, _ event: NSEvent, button: UInt8) {
        let (x, y) = normalized(event)
        onPointer?(DisplayPointerPayload(kind: kind, button: button, x: x, y: y,
                                         clickCount: UInt8(clamping: max(event.clickCount, 1))))
    }

    override func mouseMoved(with e: NSEvent) { pointer(.move, e, button: 0) }
    override func mouseDragged(with e: NSEvent) { pointer(.drag, e, button: 0) }
    override func rightMouseDragged(with e: NSEvent) { pointer(.drag, e, button: 1) }
    override func otherMouseDragged(with e: NSEvent) { pointer(.drag, e, button: UInt8(clamping: e.buttonNumber)) }
    override func mouseDown(with e: NSEvent) { pointer(.down, e, button: 0) }
    override func mouseUp(with e: NSEvent) { pointer(.up, e, button: 0) }
    override func rightMouseDown(with e: NSEvent) { pointer(.down, e, button: 1) }
    override func rightMouseUp(with e: NSEvent) { pointer(.up, e, button: 1) }
    override func otherMouseDown(with e: NSEvent) { pointer(.down, e, button: UInt8(clamping: e.buttonNumber)) }
    override func otherMouseUp(with e: NSEvent) { pointer(.up, e, button: UInt8(clamping: e.buttonNumber)) }

    override func scrollWheel(with e: NSEvent) {
        let precise = e.hasPreciseScrollingDeltas
        // Line deltas are sent as lines, precise (trackpad) ones as pixels.
        onScroll?(ScrollPayload(dx: Int32(clamping: Int(e.scrollingDeltaX.rounded())),
                                dy: Int32(clamping: Int(e.scrollingDeltaY.rounded())), continuous: precise))
    }

    private func flags(_ e: NSEvent) -> UInt64 { UInt64(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) }

    override func keyDown(with e: NSEvent) {
        let chord: NSEvent.ModifierFlags = [.control, .option, .command]
        if e.keyCode == 53, e.modifierFlags.intersection(chord) == chord { onExit?(); return }
        onKey?(.displayKey, KeyPayload(keyCode: e.keyCode, down: true, flags: flags(e), autorepeat: e.isARepeat))
    }

    override func keyUp(with e: NSEvent) {
        onKey?(.displayKey, KeyPayload(keyCode: e.keyCode, down: false, flags: flags(e), autorepeat: false))
    }

    override func flagsChanged(with e: NSEvent) {
        onKey?(.displayFlags, KeyPayload(keyCode: e.keyCode, down: true, flags: flags(e), autorepeat: false))
    }

    // Don't let the system beep for every key press.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { true }
}
