import Foundation
import AppKit
import CoreGraphics

/// Uses another paired Mac as a second display.
///
/// - **Host** (this Mac's desktop gets extended): creates a virtual display, captures it, encodes it as H.264 and
///   streams it. The virtual display shows up in System Settings > Displays like any monitor, so windows and the
///   pointer move onto it naturally. Mouse and keyboard events from the viewer are injected here.
/// - **Viewer** (the Mac acting as the monitor): shows the stream full screen and sends its own mouse and
///   keyboard back. It must accept each request (or have auto-accept switched on).
final class DisplaySharingManager: ObservableObject {
    enum State: Equatable {
        case idle
        case offering(peer: String)     // host: waiting for the viewer's answer
        case starting(peer: String)     // host: creating the display and starting capture
        case hosting(peer: String)
        case asking(peer: String)       // viewer: the user is deciding
        case viewing(peer: String)
        case failed(String)
    }

    enum Quality: String, CaseIterable { case balanced, sharp
        var title: String { self == .balanced ? "Balanced (smooth)" : "Sharp (Retina)" }
        var captureScale: Int { self == .sharp ? 2 : 1 }
        var bitrate: Int { self == .sharp ? 20_000_000 : 8_000_000 }
    }

    @Published private(set) var state: State = .idle

    var send: ((String, MessageType, Data, ((Error?) -> Void)?) -> Void)?
    var peerName: (String) -> String = { $0 }
    var peerSupports: (String) -> Bool = { _ in false }
    var autoAccept: () -> Bool = { false }
    var quality: () -> Quality = { .balanced }

    private var virtualDisplay: VirtualDisplay?
    private var streamer: ScreenStreamer?
    private let viewer = DisplayViewer()
    private let injector = InputInjector()
    private var inflight = 0
    private let inflightLock = NSLock()
    private static let maxInflight = 2 * 1024 * 1024
    private var generation = 0   // invalidates async work from a session that has since ended

    init() {
        viewer.onPointer = { [weak self] in self?.sendToHost(.displayPointer, $0.encode()) }
        viewer.onScroll = { [weak self] in self?.sendToHost(.displayScroll, $0.encode()) }
        viewer.onKey = { [weak self] type, key in self?.sendToHost(type, key.encode()) }
        viewer.onKeyframeNeeded = { [weak self] in self?.sendToHost(.displayKeyframeRequest, Data()) }
        viewer.onExit = { [weak self] in self?.stop() }
    }

    var isBusy: Bool { state != .idle && !isFailed }
    private var isFailed: Bool { if case .failed = state { return true } else { return false } }
    private var activePeer: String? {
        switch state {
        case .offering(let p), .starting(let p), .hosting(let p), .asking(let p), .viewing(let p): return p
        default: return nil
        }
    }

    // MARK: Host side

    func startHosting(to peer: String) {
        guard !isBusy else { return }
        guard peerSupports(peer) else {
            state = .failed("\(peerName(peer)) needs MacLinker \(K.displayMinVersion) or newer.")
            return
        }
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            state = .failed("Allow Screen Recording for MacLinker in System Settings > Privacy & Security, then restart MacLinker.")
            return
        }
        state = .offering(peer: peer)
        generation += 1
        send?(peer, .displayOffer, Data(), nil)
    }

    private func begin(streamingTo peer: String, viewerPoints: CGSize, viewerScale: Int) {
        state = .starting(peer: peer)
        let gen = generation
        let quality = self.quality()
        Task { @MainActor in
            do {
                // A 2x virtual display gives Retina rendering; Balanced then downsamples the capture to 1x.
                guard let display = VirtualDisplay(name: "MacLinker – \(peerName(peer))",
                                                   pointsWidth: Int(viewerPoints.width), pointsHeight: Int(viewerPoints.height),
                                                   scale: 2) else {
                    throw NSError(domain: "MacLinker", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "macOS refused to create the virtual display."])
                }
                let pixelW = Int(display.pointsSize.width) * quality.captureScale
                let pixelH = Int(display.pointsSize.height) * quality.captureScale
                let streamer = ScreenStreamer()
                streamer.onParameterSets = { [weak self] sets in
                    self?.send?(peer, .displayConfig, DisplayConfigPayload(parameterSets: sets).encode(), nil)
                }
                streamer.onFrame = { [weak self] key, ms, data in self?.sendFrame(peer, key, ms, data) }
                streamer.onStopped = { [weak self] error in
                    DispatchQueue.main.async {
                        if let error { self?.fail("Capture stopped: \(error.localizedDescription)") }
                        self?.stop(notify: true)
                    }
                }
                try await streamer.start(displayID: display.displayID, width: pixelW, height: pixelH, fps: 60,
                                         bitrate: quality.bitrate)
                guard gen == self.generation else { await streamer.stop(); return }  // cancelled meanwhile
                self.virtualDisplay = display
                self.streamer = streamer
                self.state = .hosting(peer: peer)
                self.send?(peer, .displayStart,
                           DisplayStartPayload(width: UInt32(pixelW), height: UInt32(pixelH), fps: 60).encode(), nil)
                streamer.requestKeyframe()
            } catch {
                self.fail("Couldn't start the display: \(error.localizedDescription)")
                self.stop(notify: true, keepFailure: true)
            }
        }
    }

    /// Sends a frame unless the link is already behind. Dropping a frame breaks the chain of predicted frames, so the
    /// next one is forced to be a key frame.
    private func sendFrame(_ peer: String, _ key: Bool, _ ms: UInt64, _ data: Data) {
        inflightLock.lock()
        let behind = inflight > Self.maxInflight
        if !behind { inflight += data.count }
        inflightLock.unlock()
        if behind {
            streamer?.requestKeyframe()
            return
        }
        let size = data.count
        send?(peer, .displayFrame, DisplayFramePayload(keyframe: key, timestampMs: ms, data: data).encode()) { [weak self] _ in
            self?.inflightLock.lock(); self?.inflight -= size; self?.inflightLock.unlock()
        }
    }

    // MARK: Viewer side

    private func sendToHost(_ type: MessageType, _ payload: Data) {
        if case .viewing(let host) = state { send?(host, type, payload, nil) }
    }

    private func askToAccept(from peer: String) {
        state = .asking(peer: peer)
        DispatchQueue.main.async {
            var accept = self.autoAccept()
            if !accept {
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = "Use this screen as a display for \(self.peerName(peer))?"
                alert.informativeText = "\(self.peerName(peer)) wants to use this Mac's screen as a second display. "
                    + "Your screen will show \(self.peerName(peer))'s desktop until you stop it (Control+Option+Command+Esc)."
                alert.addButton(withTitle: "Allow")
                alert.addButton(withTitle: "Decline")
                accept = alert.runModal() == .alertFirstButtonReturn
            }
            guard case .asking = self.state else { return }   // the host gave up while the alert was open
            let screen = NSScreen.main ?? NSScreen.screens[0]
            let reply = DisplayAcceptPayload(accepted: accept, width: UInt32(screen.frame.width),
                                             height: UInt32(screen.frame.height), scale: Float(screen.backingScaleFactor))
            self.send?(peer, .displayAccept, reply.encode(), nil)
            self.state = accept ? .asking(peer: peer) : .idle
        }
    }

    // MARK: Messages

    func handle(_ message: MacLinkerMessage, from peer: String) {
        do {
            switch message.type {
            case .displayOffer:
                guard !isBusy else { send?(peer, .displayAccept, DisplayAcceptPayload(accepted: false, width: 0, height: 0, scale: 1).encode(), nil); return }
                askToAccept(from: peer)
            case .displayAccept:
                guard case .offering(let p) = state, p == peer else { return }
                let a = try DisplayAcceptPayload.decode(message.payload)
                guard a.accepted, a.width >= 320, a.height >= 240 else { fail("\(peerName(peer)) declined."); state = .idle; return }
                begin(streamingTo: peer, viewerPoints: CGSize(width: Int(a.width), height: Int(a.height)),
                      viewerScale: Int(a.scale.rounded()))
            case .displayStart:
                guard case .asking(let p) = state, p == peer else { return }
                _ = try DisplayStartPayload.decode(message.payload)
                state = .viewing(peer: peer)
                viewer.open(on: NSScreen.main ?? NSScreen.screens[0])
            case .displayConfig:
                guard case .viewing(let p) = state, p == peer else { return }
                viewer.setParameterSets(try DisplayConfigPayload.decode(message.payload).parameterSets)
            case .displayFrame:
                guard case .viewing(let p) = state, p == peer else { return }
                viewer.show(try DisplayFramePayload.decode(message.payload))
            case .displayStop:
                guard activePeer == peer else { return }
                stop(notify: false)
            case .displayKeyframeRequest:
                guard case .hosting(let p) = state, p == peer else { return }
                streamer?.requestKeyframe()
            case .displayPointer, .displayScroll, .displayKey, .displayFlags:
                guard case .hosting(let p) = state, p == peer, let display = virtualDisplay else { return }
                try inject(message, into: display)
            default: break
            }
        } catch {
            Log.error("bad display message: \(error)")
        }
    }

    /// Viewer input arrives normalised to the picture; map it onto the virtual display's current position.
    private func inject(_ message: MacLinkerMessage, into display: VirtualDisplay) throws {
        let bounds = display.bounds
        switch message.type {
        case .displayPointer:
            let p = try DisplayPointerPayload.decode(message.payload)
            let point = CGPoint(x: bounds.minX + CGFloat(p.x) * (bounds.width - 1), y: bounds.minY + CGFloat(p.y) * (bounds.height - 1))
            switch p.kind {
            case .move, .drag: injector.move(to: point, delta: .zero)
            case .down: injector.button(Int(p.button), down: true, clickCount: Int(p.clickCount), at: point)
            case .up: injector.button(Int(p.button), down: false, clickCount: Int(p.clickCount), at: point)
            }
        case .displayScroll:
            let s = try ScrollPayload.decode(message.payload)
            injector.scroll(dx: s.dx, dy: s.dy, continuous: s.continuous)
        case .displayKey:
            let k = try KeyPayload.decode(message.payload)
            injector.key(k.keyCode, down: k.down, flags: CGEventFlags(rawValue: k.flags), autorepeat: k.autorepeat)
        case .displayFlags:
            let k = try KeyPayload.decode(message.payload)
            injector.flagsChanged(k.keyCode, flags: CGEventFlags(rawValue: k.flags))
        default: break
        }
    }

    // MARK: Ending

    private func fail(_ reason: String) { state = .failed(reason) }

    /// Ends whichever side this Mac is on. Safe to call at any time, and more than once.
    func stop(notify: Bool = true, keepFailure: Bool = false) {
        let peer = activePeer
        generation += 1
        let wasFailed = isFailed
        if notify, let peer { send?(peer, .displayStop, Data(), nil) }
        if viewer.isOpen { viewer.close() }
        let streamer = self.streamer
        self.streamer = nil
        if let streamer { Task { await streamer.stop() } }
        injector.releaseAll(at: virtualDisplay?.bounds.origin ?? .zero)
        virtualDisplay = nil     // releasing it removes the display
        inflightLock.lock(); inflight = 0; inflightLock.unlock()
        if !(keepFailure && wasFailed) { state = .idle }
    }

    func peerDisconnected(_ peer: String) {
        if activePeer == peer { stop(notify: false) }
    }

    /// Dismisses an error message.
    func clearFailure() { if isFailed { state = .idle } }
}
