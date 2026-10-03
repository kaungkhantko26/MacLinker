import AppKit
import UniformTypeIdentifiers

/// Starts a genuine system drag session on this Mac, carrying items that came from the other Mac.
///
/// A drag can only begin from a mouse-down inside one of our own windows. So: show a nearly invisible window under
/// the pointer, inject a left-button press, and when the window sees it, start the drag. The rest of the other Mac's
/// mouse movement is injected as drag events, and its button release performs the drop.
final class DragSessionController: NSObject, NSDraggingSource, NSFilePromiseProviderDelegate {
    var onFinish: (() -> Void)?

    private let offer: DragOffer
    private let awaitItem: (UUID) -> URL?
    private weak var mouse: MouseInjecting?
    private var window: NSWindow?
    private var cursor = CGPoint.zero
    private var started = false
    private var finished = false
    private let fileItems: [UUID: ClipboardFilesOffer.Item]
    private let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    init(offer: DragOffer, mouse: MouseInjecting, awaitItem: @escaping (UUID) -> URL?) {
        self.offer = offer
        self.mouse = mouse
        self.awaitItem = awaitItem
        self.fileItems = Dictionary(uniqueKeysWithValues: (offer.files?.items ?? []).map { ($0.id, $0) })
    }

    // MARK: Starting

    func begin(at point: CGPoint) {
        cursor = point
        let size: CGFloat = 240
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: point.x - size / 2, y: screenHeight - point.y - size / 2, width: size, height: size)
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = NSColor.black.withAlphaComponent(0.01)   // fully clear windows aren't hit-tested
        w.hasShadow = false
        w.level = .popUpMenu
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let view = DragSourceView(frame: NSRect(origin: .zero, size: frame.size))
        view.onMouseDown = { [weak self] event, view in self?.startDragging(event, in: view) }
        w.contentView = view
        w.orderFrontRegardless()
        window = w

        // Give the window a moment to appear under the pointer, then press the button.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07) { [weak self] in
            guard let self, !self.finished else { return }
            self.mouse?.pressLeft(at: self.cursor)
        }
        // If the system never starts the drag, undo everything rather than leave a button held down.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, !self.started, !self.finished else { return }
            Log.error("drag handoff: the system didn't start a drag; cancelling")
            self.cancel()
        }
    }

    func cancel() {
        guard !finished else { return }
        if !started { mouse?.releaseLeft(at: cursor) }
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        window?.orderOut(nil)
        window = nil
        onFinish?()
    }

    private func startDragging(_ event: NSEvent, in view: NSView) {
        guard !started, !finished else { return }
        started = true
        let location = view.convert(event.locationInWindow, from: nil)
        let frame = NSRect(x: location.x - 24, y: location.y - 24, width: 48, height: 48)
        var items: [NSDraggingItem] = []

        for item in offer.files?.items ?? [] {
            let provider = NSFilePromiseProvider(fileType: Self.typeIdentifier(for: item), delegate: self)
            provider.userInfo = item.id.uuidString
            let dragItem = NSDraggingItem(pasteboardWriter: provider)
            dragItem.setDraggingFrame(frame, contents: Self.icon(for: item))
            items.append(dragItem)
        }
        for link in offer.links {
            guard let url = URL(string: link) else { continue }
            // NSURL supplies every pasteboard flavour a browser, Mail or Notes expects for a dropped link.
            let dragItem = NSDraggingItem(pasteboardWriter: url as NSURL)
            dragItem.setDraggingFrame(frame, contents: NSImage(systemSymbolName: "link", accessibilityDescription: nil))
            items.append(dragItem)
        }
        if let text = offer.text {
            let dragItem = NSDraggingItem(pasteboardWriter: text as NSString)
            dragItem.setDraggingFrame(frame, contents: NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil))
            items.append(dragItem)
        }
        guard !items.isEmpty else { cancel(); return }
        view.beginDraggingSession(with: items, event: event, source: self)
        window?.ignoresMouseEvents = true      // the drop must land on what's underneath, not on this window
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        finish()
    }

    // MARK: NSFilePromiseProviderDelegate

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        guard let item = item(for: provider) else { return "file" }
        return Self.displayName(for: item)
    }

    /// Called on our own queue when the drop target asks for the file. Waits for the data to arrive, then copies it.
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        guard let item = item(for: provider), let source = awaitItem(item.id) else {
            completionHandler(NSError(domain: "MacLinker", code: 2, userInfo: [NSLocalizedDescriptionKey: "The dragged item never arrived."]))
            return
        }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            try FileManager.default.copyItem(at: source, to: url)
            completionHandler(nil)
        } catch {
            completionHandler(error)
        }
    }

    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { promiseQueue }

    private func item(for provider: NSFilePromiseProvider) -> ClipboardFilesOffer.Item? {
        (provider.userInfo as? String).flatMap(UUID.init(uuidString:)).flatMap { fileItems[$0] }
    }

    // MARK: Naming and icons

    static func displayName(for item: ClipboardFilesOffer.Item) -> String {
        guard item.archive, item.name.lowercased().hasSuffix(".zip") else { return item.name }
        return String(item.name.dropLast(4))
    }

    static func typeIdentifier(for item: ClipboardFilesOffer.Item) -> String {
        let name = displayName(for: item)
        let ext = (name as NSString).pathExtension
        if item.archive { return ext.lowercased() == "app" ? UTType.applicationBundle.identifier : UTType.folder.identifier }
        return (ext.isEmpty ? nil : UTType(filenameExtension: ext))?.identifier ?? UTType.data.identifier
    }

    static func icon(for item: ClipboardFilesOffer.Item) -> NSImage {
        let type = UTType(typeIdentifier(for: item)) ?? .data
        let icon = NSWorkspace.shared.icon(for: type)
        icon.size = NSSize(width: 48, height: 48)
        return icon
    }
}

/// The nearly invisible view that receives the injected button press and turns it into a drag.
final class DragSourceView: NSView {
    var onMouseDown: ((NSEvent, NSView) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouseDown?(event, self) }
}
