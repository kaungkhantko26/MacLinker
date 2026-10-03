import Foundation
import AppKit

/// What a drag in progress carries, announced to the other Mac just before the pointer crosses over.
struct DragOffer: Codable, Equatable {
    /// Files, folders and apps (sent as an announced batch, like copied files).
    var files: ClipboardFilesOffer?
    /// Web links and similar. File links are never in here; they travel as files.
    var links: [String] = []
    var text: String?

    static let maxLinks = 20
    static let maxText = 100_000
    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    var isEmpty: Bool { files == nil && links.isEmpty && text == nil }

    /// Drops anything unsafe or oversized. Nil if nothing usable is left.
    func sanitized() -> DragOffer? {
        var clean = DragOffer(files: nil, links: [], text: nil)
        if let files, FileClipboardManager.isAcceptable(files) { clean.files = files }
        clean.links = links.prefix(Self.maxLinks).filter { link in
            guard let url = URL(string: link), let scheme = url.scheme?.lowercased() else { return false }
            return Self.allowedSchemes.contains(scheme) && link.count < 4096
        }
        if let text, !text.isEmpty, text.utf8.count <= Self.maxText { clean.text = text }
        return clean.isEmpty ? nil : clean
    }
}

/// The contents of the system drag pasteboard.
struct DraggedItems: Equatable {
    var files: [URL] = []
    var links: [URL] = []
    var text: String?

    var isEmpty: Bool { files.isEmpty && links.isEmpty && text == nil }

    static func read(from pasteboard: NSPasteboard) -> DraggedItems {
        let urls = (pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]) ?? []
        var items = DraggedItems()
        for url in urls {
            if url.isFileURL { items.files.append(url.standardizedFileURL) }
            else if DragOffer.allowedSchemes.contains(url.scheme?.lowercased() ?? "") { items.links.append(url) }
        }
        items.files = items.files.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        // Plain text only when the drag isn't really a file or a link (those also carry their name as text).
        if items.files.isEmpty && items.links.isEmpty, let s = pasteboard.string(forType: .string), !s.isEmpty { items.text = s }
        return items
    }
}

/// Tells a real drag apart from simply holding the button down: a drag *changes* the drag pasteboard after the
/// button went down. Used on both Macs.
struct DragDetector {
    private var countAtButtonDown: Int?

    mutating func buttonDown(pasteboardCount: Int) { countAtButtonDown = pasteboardCount }
    mutating func buttonUp() { countAtButtonDown = nil }
    func isDragging(pasteboardCount: Int) -> Bool {
        guard let start = countAtButtonDown else { return false }
        return pasteboardCount != start
    }
}

/// Something that can press and release the left mouse button on this Mac (the input system).
protocol MouseInjecting: AnyObject {
    func pressLeft(at point: CGPoint)
    func releaseLeft(at point: CGPoint)
}

/// Drag a file, link or app to the edge of one Mac and carry on dragging on the other.
///
/// Sending side: when the pointer reaches a screen edge during a drag, the dragged items are announced (`dragBegin`)
/// and files start streaming, just before control passes over.
/// Receiving side: once control arrives, a real system drag is started with those items, so the rest of the drag
/// (moving, dropping onto any app) happens natively.
final class DragHandoff {
    var isEnabled: () -> Bool = { true }
    var peerSupports: (String) -> Bool = { _ in false }
    /// Files and apps need file sharing switched on; links and text don't.
    var filesAllowed: () -> Bool = { true }
    var send: ((String, MessageType, Data) -> Void)?
    var onSkipped: ((String) -> Void)?
    weak var mouse: MouseInjecting?

    private let files: FileClipboardManager
    private let dragPasteboard: NSPasteboard

    struct Pending { let offer: DragOffer; let peer: String; let received: Date }
    private var pending: Pending?
    private var session: DragSessionController?
    static let pendingLifetime: TimeInterval = 30

    init(files: FileClipboardManager, dragPasteboard: NSPasteboard = NSPasteboard(name: .drag)) {
        self.files = files
        self.dragPasteboard = dragPasteboard
    }

    // MARK: Sending

    /// Called from the input thread when the pointer hits an edge during a drag. Returns whether the drag was announced
    /// (so control should pass over). Blocks briefly while the main thread reads the pasteboard.
    func beginHandoff(to peer: String) -> Bool {
        if Thread.isMainThread { return handoff(to: peer) }
        return DispatchQueue.main.sync { handoff(to: peer) }
    }

    private func handoff(to peer: String) -> Bool {
        guard isEnabled(), peerSupports(peer) else { return false }
        var items = DraggedItems.read(from: dragPasteboard)
        if !filesAllowed() { items.files = [] }
        guard !items.isEmpty else { return false }

        var offer = DragOffer(files: nil, links: items.links.map(\.absoluteString), text: items.text)
        var planned: [FileClipboardManager.Planned] = []
        if !items.files.isEmpty {
            switch files.plan(items.files) {
            case .ready(let p):
                planned = p
                offer.files = FileClipboardManager.offer(for: p)
            case .tooBig(let total):
                onSkipped?("That's \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file)), over the 250 MB limit for dragging. Use Send File.")
                return false
            case .tooMany:
                onSkipped?("Too many items to drag at once (the limit is \(ClipboardFilesOffer.maxItems)).")
                return false
            case .nothing: break
            }
        }
        guard !offer.isEmpty, let payload = try? JSONEncoder().encode(offer) else { return false }
        send?(peer, .dragBegin, payload)                 // must go out before the files and before control passes
        if !planned.isEmpty { files.transmit(planned, to: peer) }
        return true
    }

    // MARK: Receiving

    func handle(_ payload: Data, from peer: String) {
        guard isEnabled(), var offer = try? JSONDecoder().decode(DragOffer.self, from: payload) else { return }
        if !filesAllowed() { offer.files = nil }
        guard let offer = offer.sanitized() else { return }
        if let batch = offer.files { files.register(batch, from: peer, purpose: .drag) }
        pending = Pending(offer: offer, peer: peer, received: Date())
    }

    func takePending(from peer: String, now: Date = Date()) -> Pending? {
        defer { pending = nil }
        guard let p = pending, p.peer == peer, now.timeIntervalSince(p.received) < Self.pendingLifetime else { return nil }
        return p
    }

    /// Control has just arrived here with a drag announced: pick the drag up at `point` (global, top-left origin).
    func startIfPending(from peer: String, at point: CGPoint) {
        guard let p = takePending(from: peer), let mouse, session == nil else { return }
        let controller = DragSessionController(offer: p.offer, mouse: mouse) { [weak self] id in
            self?.files.awaitItem(id, timeout: 120)
        }
        controller.onFinish = { [weak self, controller] in
            self?.session = nil
            // The drop target asks for each file *after* the drop, possibly seconds later while data is still arriving.
            // Keep the controller (the file promises' delegate) alive well past the end of the drag.
            DispatchQueue.main.asyncAfter(deadline: .now() + 300) { _ = controller }
        }
        session = controller
        controller.begin(at: point)
    }

    /// Abandons a drag that never got going.
    func cancel() { session?.cancel(); session = nil; pending = nil }
}
