import XCTest
import AppKit
@testable import MacLinker

final class DragHandoffTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mldrag-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func namedPasteboard() -> NSPasteboard { NSPasteboard(name: NSPasteboard.Name("maclinker-drag-\(UUID().uuidString)")) }

    // MARK: Pure logic

    func testDragDetectorNeedsThePasteboardToChangeAfterButtonDown() {
        var d = DragDetector()
        XCTAssertFalse(d.isDragging(pasteboardCount: 5), "no button down yet")
        d.buttonDown(pasteboardCount: 5)
        XCTAssertFalse(d.isDragging(pasteboardCount: 5), "button held but nothing was picked up: not a drag")
        XCTAssertTrue(d.isDragging(pasteboardCount: 6), "the drag pasteboard changed: a drag started")
        d.buttonUp()
        XCTAssertFalse(d.isDragging(pasteboardCount: 7))
    }

    func testOfferSanitisingDropsUnsafeLinksAndOversizedText() {
        let raw = DragOffer(files: nil,
                            links: ["https://example.com/a", "javascript:alert(1)", "data:text/html,hi", "file:///etc/passwd",
                                    "mailto:a@b.c", "not a url", "https://" + String(repeating: "a", count: 5000)],
                            text: nil)
        XCTAssertEqual(raw.sanitized()?.links, ["https://example.com/a", "mailto:a@b.c"])
        XCTAssertNil(DragOffer(files: nil, links: ["javascript:x"], text: String(repeating: "x", count: DragOffer.maxText + 1)).sanitized())
        XCTAssertEqual(DragOffer(files: nil, links: [], text: "hello").sanitized()?.text, "hello")
        let tooBig = ClipboardFilesOffer(batch: UUID(), items: [.init(id: UUID(), name: "a", size: K.fileClipboardLimit + 1, archive: false)])
        XCTAssertNil(DragOffer(files: tooBig, links: [], text: nil).sanitized(), "an unacceptable file batch is dropped entirely")
        let many = DragOffer(files: nil, links: (0..<50).map { "https://e.com/\($0)" }, text: nil).sanitized()
        XCTAssertEqual(many?.links.count, DragOffer.maxLinks)
    }

    func testReadingTheDragPasteboard() throws {
        let file = temp.appendingPathComponent("a.txt"); try "a".write(to: file, atomically: true, encoding: .utf8)
        let pb = namedPasteboard()
        pb.clearContents(); pb.writeObjects([file as NSURL])
        pb.addTypes([.string], owner: nil); pb.setString("a.txt", forType: .string)    // Finder also puts the name on as text
        let files = DraggedItems.read(from: pb)
        XCTAssertEqual(files.files.map(\.lastPathComponent), ["a.txt"])
        XCTAssertNil(files.text, "the file's name is not a text drag")

        pb.clearContents(); pb.writeObjects([URL(string: "https://example.com/page")! as NSURL, URL(string: "javascript:alert(1)")! as NSURL])
        let links = DraggedItems.read(from: pb)
        XCTAssertEqual(links.links.map(\.absoluteString), ["https://example.com/page"], "unsafe schemes never make it through")

        pb.clearContents(); pb.setString("just words", forType: .string)
        XCTAssertEqual(DraggedItems.read(from: pb).text, "just words")
        pb.clearContents()
        XCTAssertTrue(DraggedItems.read(from: pb).isEmpty)
    }

    func testPendingDragExpiresAndMustComeFromTheRightMac() throws {
        let side = DragSide(temp: temp)
        let payload = try JSONEncoder().encode(DragOffer(files: nil, links: ["https://example.com"], text: nil))
        side.drag.handle(payload, from: "peer")
        XCTAssertNil(side.drag.takePending(from: "someone else"), "wrong sender")
        side.drag.handle(payload, from: "peer")
        XCTAssertNil(side.drag.takePending(from: "peer", now: Date().addingTimeInterval(DragHandoff.pendingLifetime + 1)), "too old")
        side.drag.handle(payload, from: "peer")
        XCTAssertEqual(side.drag.takePending(from: "peer")?.offer.links, ["https://example.com"])
        XCTAssertNil(side.drag.takePending(from: "peer"), "it can only be used once")
    }

    // MARK: Two Macs in one process

    final class DragSide {
        let files = FileTransferManager()
        let fileClipboard: FileClipboardManager
        let dragPasteboard: NSPasteboard
        let drag: DragHandoff
        var sent: [MessageType] = []
        var skipped: String?

        init(temp: URL) {
            let id = UUID().uuidString
            fileClipboard = FileClipboardManager(files: files, pasteboard: NSPasteboard(name: NSPasteboard.Name("ml-clip-\(id)")),
                                                 cacheRoot: temp.appendingPathComponent("cache-\(id)"))
            dragPasteboard = NSPasteboard(name: NSPasteboard.Name("ml-drag-\(id)"))
            drag = DragHandoff(files: fileClipboard, dragPasteboard: dragPasteboard)
            drag.peerSupports = { _ in true }
            drag.onSkipped = { [unowned self] why in skipped = why }
            fileClipboard.peerSupports = { _ in true }
        }
    }

    private func connect(_ a: DragSide, _ b: DragSide) {
        a.drag.send = { _, type, payload in
            a.sent.append(type)
            DispatchQueue.main.async { b.drag.handle(payload, from: "peer") }
        }
        a.files.send = { type, payload, _, done in
            DispatchQueue.main.async {
                b.files.handle(message: MacLinkerMessage(type: type, sequence: 0, payload: payload), from: "peer")
                done?(nil)
            }
        }
    }

    private func spin(_ timeout: TimeInterval = 15, until condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testDraggingAFileAndAnAppAnnouncesThenDeliversThem() throws {
        let a = DragSide(temp: temp), b = DragSide(temp: temp)
        connect(a, b)
        let file = temp.appendingPathComponent("src/photo.jpg")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data((0..<300_000).map { UInt8($0 % 241) })
        try bytes.write(to: file)
        let app = temp.appendingPathComponent("src/Tool.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try "bin".write(to: app.appendingPathComponent("Contents/MacOS/tool"), atomically: true, encoding: .utf8)
        a.dragPasteboard.clearContents(); a.dragPasteboard.writeObjects([file as NSURL, app as NSURL])

        XCTAssertTrue(a.drag.beginHandoff(to: "peer"))
        XCTAssertEqual(a.sent, [.dragBegin])

        var pending: DragHandoff.Pending?
        spin { pending = b.drag.takePending(from: "peer"); return pending != nil }
        let files = try XCTUnwrap(pending?.offer.files)
        XCTAssertEqual(files.items.map(\.name).sorted(), ["Tool.app.zip", "photo.jpg"])

        // A drop asks for each item; ask from a background thread, as the system does for file promises.
        var results: [UUID: URL?] = [:]
        let lock = NSLock()
        for item in files.items {
            DispatchQueue.global().async {
                let url = b.fileClipboard.awaitItem(item.id, timeout: 20)
                lock.lock(); results[item.id] = .some(url); lock.unlock()
            }
        }
        spin { lock.lock(); defer { lock.unlock() }; return results.count == files.items.count }

        for item in files.items {
            let url = try XCTUnwrap(results[item.id] ?? nil, "\(item.name) arrived")
            if item.archive { XCTAssertEqual(url.lastPathComponent, "Tool.app")
                XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("Contents/MacOS/tool")), "bin")
            } else { XCTAssertEqual(try Data(contentsOf: url), bytes) }
        }
    }

    func testLinksAndTextTravelInTheAnnouncementAlone() throws {
        let a = DragSide(temp: temp), b = DragSide(temp: temp)
        connect(a, b)
        a.dragPasteboard.clearContents()
        a.dragPasteboard.writeObjects([URL(string: "https://example.com/story")! as NSURL])
        XCTAssertTrue(a.drag.beginHandoff(to: "peer"))
        spin(1) { false }    // let anything else that might be sent go out
        XCTAssertTrue(b.files.transfers.isEmpty, "no file traffic for a link")
        XCTAssertEqual(b.drag.takePending(from: "peer")?.offer.links, ["https://example.com/story"])
    }

    func testNothingHappensWhenDisabledUnsupportedEmptyOrTooBig() throws {
        let a = DragSide(temp: temp), b = DragSide(temp: temp)
        connect(a, b)
        let file = temp.appendingPathComponent("f.txt"); try "x".write(to: file, atomically: true, encoding: .utf8)
        a.dragPasteboard.clearContents(); a.dragPasteboard.writeObjects([file as NSURL])

        a.drag.isEnabled = { false }
        XCTAssertFalse(a.drag.beginHandoff(to: "peer"), "switched off")
        a.drag.isEnabled = { true }; a.drag.peerSupports = { _ in false }
        XCTAssertFalse(a.drag.beginHandoff(to: "peer"), "an older MacLinker on the other side")
        a.drag.peerSupports = { _ in true }; a.drag.filesAllowed = { false }
        XCTAssertFalse(a.drag.beginHandoff(to: "peer"), "file sharing is off, and a file is all that's being dragged")
        a.drag.filesAllowed = { true }
        a.dragPasteboard.clearContents()
        XCTAssertFalse(a.drag.beginHandoff(to: "peer"), "nothing is being dragged")

        let huge = temp.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let h = try FileHandle(forWritingTo: huge); try h.truncate(atOffset: K.fileClipboardLimit + 1); try h.close()
        a.dragPasteboard.writeObjects([huge as NSURL])
        XCTAssertFalse(a.drag.beginHandoff(to: "peer"), "too big to carry along")
        XCTAssertNotNil(a.skipped)
        XCTAssertTrue(a.sent.isEmpty, "nothing was announced in any of those cases")
    }

    // MARK: Handing files to a drop target

    func testDropTargetReceivesTheFileThroughThePromise() throws {
        let source = temp.appendingPathComponent("arrived.txt")
        try "payload".write(to: source, atomically: true, encoding: .utf8)
        let item = ClipboardFilesOffer.Item(id: UUID(), name: "arrived.txt", size: 7, archive: false)
        let controller = DragSessionController(offer: DragOffer(files: ClipboardFilesOffer(batch: UUID(), items: [item]), links: [], text: nil),
                                               mouse: NoMouse(), awaitItem: { _ in source })
        let provider = NSFilePromiseProvider(fileType: DragSessionController.typeIdentifier(for: item), delegate: controller)
        provider.userInfo = item.id.uuidString

        XCTAssertEqual(controller.filePromiseProvider(provider, fileNameForType: "public.plain-text"), "arrived.txt")
        let destination = temp.appendingPathComponent("dropped-here.txt")
        let done = expectation(description: "promise fulfilled")
        controller.filePromiseProvider(provider, writePromiseTo: destination) { error in
            XCTAssertNil(error); done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(try String(contentsOf: destination), "payload")

        let missing = DragSessionController(offer: DragOffer(files: ClipboardFilesOffer(batch: UUID(), items: [item]), links: [], text: nil),
                                            mouse: NoMouse(), awaitItem: { _ in nil })
        let failed = expectation(description: "reports failure when the data never arrives")
        missing.filePromiseProvider(provider, writePromiseTo: temp.appendingPathComponent("never")) { error in
            XCTAssertNotNil(error); failed.fulfill()
        }
        wait(for: [failed], timeout: 5)
    }

    func testNamingAndTypesForDraggedItems() {
        let app = ClipboardFilesOffer.Item(id: UUID(), name: "Tool.app.zip", size: 1, archive: true)
        let folder = ClipboardFilesOffer.Item(id: UUID(), name: "Photos.zip", size: 1, archive: true)
        let png = ClipboardFilesOffer.Item(id: UUID(), name: "pic.png", size: 1, archive: false)
        let bare = ClipboardFilesOffer.Item(id: UUID(), name: "README", size: 1, archive: false)
        XCTAssertEqual(DragSessionController.displayName(for: app), "Tool.app")
        XCTAssertEqual(DragSessionController.displayName(for: folder), "Photos")
        XCTAssertEqual(DragSessionController.displayName(for: png), "pic.png")
        XCTAssertEqual(DragSessionController.typeIdentifier(for: app), "com.apple.application-bundle")
        XCTAssertEqual(DragSessionController.typeIdentifier(for: folder), "public.folder")
        XCTAssertEqual(DragSessionController.typeIdentifier(for: png), "public.png")
        XCTAssertEqual(DragSessionController.typeIdentifier(for: bare), "public.data")
    }

    private final class NoMouse: MouseInjecting {
        func pressLeft(at point: CGPoint) {}
        func releaseLeft(at point: CGPoint) {}
    }
}
