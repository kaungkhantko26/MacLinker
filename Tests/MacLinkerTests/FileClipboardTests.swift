import XCTest
import AppKit
import CryptoKit
@testable import MacLinker

final class FileClipboardTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("mlfc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func makeApp(named name: String = "Demo.app") throws -> URL {
        let app = temp.appendingPathComponent("src").appendingPathComponent(name)
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        let exe = macos.appendingPathComponent("demo")
        try "#!/bin/sh\necho hi\n".write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        try "plist".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: app.appendingPathComponent("Contents/link").path, withDestinationPath: "Info.plist")
        return app
    }

    // MARK: Pure helpers

    func testOfferValidationNamesAndJSON() throws {
        let item = { (size: UInt64) in ClipboardFilesOffer.Item(id: UUID(), name: "a.txt", size: size, archive: false) }
        XCTAssertTrue(FileClipboardManager.isAcceptable(ClipboardFilesOffer(batch: UUID(), items: [item(10)])))
        XCTAssertFalse(FileClipboardManager.isAcceptable(ClipboardFilesOffer(batch: UUID(), items: [])))
        XCTAssertFalse(FileClipboardManager.isAcceptable(ClipboardFilesOffer(batch: UUID(), items: [item(K.fileClipboardLimit + 1)])))
        XCTAssertFalse(FileClipboardManager.isAcceptable(ClipboardFilesOffer(
            batch: UUID(), items: [item(K.fileClipboardLimit / 2 + 1), item(K.fileClipboardLimit / 2 + 1)])), "total counts, not just each file")
        XCTAssertFalse(FileClipboardManager.isAcceptable(ClipboardFilesOffer(
            batch: UUID(), items: Array(repeating: item(1), count: ClipboardFilesOffer.maxItems + 1))))
        XCTAssertEqual(FileClipboardManager.sanitized("../../etc/passwd"), "passwd")
        XCTAssertEqual(FileClipboardManager.sanitized("..."), "file")
        var taken = Set<String>()
        XCTAssertEqual(FileClipboardManager.uniqueName("a.txt", taken: &taken), "a.txt")
        XCTAssertEqual(FileClipboardManager.uniqueName("A.txt", taken: &taken), "A 1.txt", "names clash case-insensitively on macOS")
        let offer = ClipboardFilesOffer(batch: UUID(), items: [item(5)])
        XCTAssertEqual(try JSONDecoder().decode(ClipboardFilesOffer.self, from: JSONEncoder().encode(offer)), offer)
    }

    func testArchiveKeepsAnAppBundleIntact() throws {
        let app = try makeApp()
        let zip = temp.appendingPathComponent("Demo.app.zip")
        try FileArchive.zip(app, to: zip)
        let out = temp.appendingPathComponent("out")
        let top = try FileArchive.unzip(zip, into: out)
        XCTAssertEqual(top.map(\.lastPathComponent), ["Demo.app"])
        let exe = out.appendingPathComponent("Demo.app/Contents/MacOS/demo")
        XCTAssertEqual(try String(contentsOf: exe), "#!/bin/sh\necho hi\n")
        let perms = try FileManager.default.attributesOfItem(atPath: exe.path)[.posixPermissions] as? NSNumber
        XCTAssertNotEqual((perms?.intValue ?? 0) & 0o100, 0, "still executable")
        let link = out.appendingPathComponent("Demo.app/Contents/link").path
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link), "Info.plist", "symlinks survive")
    }

    func testTotalSizeStopsEarly() throws {
        let dir = temp.appendingPathComponent("big")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for i in 0..<5 { try Data(count: 1000).write(to: dir.appendingPathComponent("f\(i)")) }
        XCTAssertEqual(FileArchive.totalSize(of: dir, cap: 1_000_000), 5000)
        XCTAssertGreaterThan(FileArchive.totalSize(of: dir, cap: 1500), 1500, "returns as soon as the cap is passed")
        XCTAssertEqual(FileArchive.totalSize(of: temp.appendingPathComponent("missing"), cap: 10), 0)
    }

    func testHostileArchiveCannotWriteOutsideItsFolder() throws {
        let python = "/usr/bin/python3"
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: python), "python3 not available")
        let zip = temp.appendingPathComponent("evil.zip")
        let script = "import zipfile,sys; z=zipfile.ZipFile(sys.argv[1],'w'); z.writestr('../escaped.txt','x'); z.writestr('ok.txt','y'); z.close()"
        let p = Process(); p.executableURL = URL(fileURLWithPath: python); p.arguments = ["-c", script, zip.path]
        try p.run(); p.waitUntilExit()
        let out = temp.appendingPathComponent("sandbox")
        _ = try? FileArchive.unzip(zip, into: out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("escaped.txt").path),
                       "nothing may land beside the extraction folder")
    }

    // MARK: Two Macs in one process

    private final class Side {
        let files = FileTransferManager()
        let manager: FileClipboardManager
        let pasteboard: NSPasteboard
        var received: [(urls: [URL], from: String, onClipboard: Bool)] = []
        var skipped: UInt64?

        init(cache: URL) {
            pasteboard = NSPasteboard(name: NSPasteboard.Name("maclinker-test-\(UUID().uuidString)"))
            manager = FileClipboardManager(files: files, pasteboard: pasteboard, cacheRoot: cache)
            manager.peerSupports = { _ in true }
            manager.peerName = { _ in "Other Mac" }
            manager.onReceived = { [unowned self] urls, from, on in received.append((urls, from, on)) }
            manager.onSkipped = { [unowned self] _, total in skipped = total }
        }
    }

    private func connect(_ a: Side, _ b: Side) {
        func route(from: Side, to: Side) {
            from.manager.send = { _, _, payload in
                DispatchQueue.main.async { to.manager.handleOffer(payload, from: "peer") }
            }
            from.files.send = { type, payload, _, done in
                DispatchQueue.main.async {
                    to.files.handle(message: MacLinkerMessage(type: type, sequence: 0, payload: payload), from: "peer")
                    done?(nil)
                }
            }
        }
        route(from: a, to: b); route(from: b, to: a)
    }

    private func waitUntil(_ timeout: TimeInterval = 15, _ condition: () -> Bool) {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testCopyFileAndAppOnOneMacPasteOnTheOther() throws {
        let a = Side(cache: temp.appendingPathComponent("cacheA")), b = Side(cache: temp.appendingPathComponent("cacheB"))
        connect(a, b)
        let file = temp.appendingPathComponent("src/report.txt")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let big = Data((0..<500_000).map { UInt8($0 % 251) })       // spans several chunks
        try big.write(to: file)
        let app = try makeApp()

        a.manager.send([file, app], to: ["peer"])
        waitUntil { !b.received.isEmpty }

        let got = try XCTUnwrap(b.received.first)
        XCTAssertTrue(got.onClipboard)
        XCTAssertEqual(got.urls.map(\.lastPathComponent).sorted(), ["Demo.app", "report.txt"])
        let pasted = b.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        XCTAssertEqual(pasted.map(\.lastPathComponent).sorted(), ["Demo.app", "report.txt"], "Cmd+V on the other Mac sees both")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(pasted.first { $0.lastPathComponent == "report.txt" })), big)
        let exe = try XCTUnwrap(pasted.first { $0.lastPathComponent == "Demo.app" }).appendingPathComponent("Contents/MacOS/demo")
        XCTAssertEqual(try String(contentsOf: exe), "#!/bin/sh\necho hi\n")
    }

    func testDoesNotOverwriteAClipboardYouChangedMeanwhile() throws {
        let b = Side(cache: temp.appendingPathComponent("cacheB"))
        let fileID = UUID(), batch = UUID()
        let body = Data("hello".utf8)
        let offer = ClipboardFilesOffer(batch: batch, items: [.init(id: fileID, name: "note.txt", size: UInt64(body.count), archive: false)])
        b.manager.handleOffer(try JSONEncoder().encode(offer), from: "peer")        // "files are coming"

        b.pasteboard.clearContents()                                                  // you copy something else meanwhile
        b.pasteboard.setString("something newer", forType: .string)

        func deliver(_ type: MessageType, _ payload: Data) { b.files.handle(message: MacLinkerMessage(type: type, sequence: 0, payload: payload), from: "peer") }
        let idBytes = withUnsafeBytes(of: fileID.uuid) { Data($0) }
        deliver(.fileOffer, try JSONEncoder().encode(FileOfferPayload(id: fileID, name: "note.txt", size: UInt64(body.count))))
        deliver(.fileChunk, idBytes + body)
        deliver(.fileEnd, idBytes + Data(SHA256.hash(data: body)))
        waitUntil { !b.received.isEmpty }

        XCTAssertEqual(b.received.first?.onClipboard, false, "reported as not placed on the clipboard")
        XCTAssertEqual(b.pasteboard.string(forType: .string), "something newer", "your newer copy wins")
        XCTAssertEqual(try String(contentsOf: try XCTUnwrap(b.received.first?.urls.first)), "hello", "but the files are still kept")
    }

    func testTooBigIsSkippedNotSent() throws {
        let a = Side(cache: temp.appendingPathComponent("cacheA")), b = Side(cache: temp.appendingPathComponent("cacheB"))
        connect(a, b)
        let sparse = temp.appendingPathComponent("huge.bin")
        FileManager.default.createFile(atPath: sparse.path, contents: nil)
        let h = try FileHandle(forWritingTo: sparse)
        try h.truncate(atOffset: K.fileClipboardLimit + 1024); try h.close()      // sparse: no real disk use
        a.manager.send([sparse], to: ["peer"])
        waitUntil(5) { a.skipped != nil }
        XCTAssertGreaterThan(a.skipped ?? 0, K.fileClipboardLimit)
        XCTAssertTrue(b.received.isEmpty && b.files.transfers.isEmpty)
    }

    func testDisabledOrUnsupportedPeersGetNothing() throws {
        let a = Side(cache: temp.appendingPathComponent("cacheA")), b = Side(cache: temp.appendingPathComponent("cacheB"))
        connect(a, b)
        let file = temp.appendingPathComponent("x.txt"); try "x".write(to: file, atomically: true, encoding: .utf8)
        a.manager.peerSupports = { _ in false }                        // an older MacLinker on the other side
        a.manager.send([file], to: ["peer"])
        b.manager.isEnabled = { false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(b.received.isEmpty && b.files.transfers.isEmpty)
        // a receiver with the feature switched off ignores an offer outright
        a.manager.peerSupports = { _ in true }
        a.manager.send([file], to: ["peer"])
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(b.received.isEmpty)
    }

    func testCachePruningKeepsRecentBatches() throws {
        let cache = temp.appendingPathComponent("cache")
        let side = Side(cache: cache)
        for i in 0..<6 {
            let d = cache.appendingPathComponent("batch\(i)")
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(Double(-i * 60))], ofItemAtPath: d.path)
        }
        let old = cache.appendingPathComponent("ancient")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: old.path)
        side.manager.pruneCache(keeping: 3, olderThan: 24 * 3600)
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: cache.path))
        XCTAssertEqual(left, ["batch0", "batch1", "batch2"])
    }
}

final class CopiedFileRefusalTests: XCTestCase {
    func testCopiedFileNobodyAnnouncedIsRefusedNotSavedToDownloads() throws {
        let files = FileTransferManager()
        var sent: [MessageType] = []
        files.send = { type, _, _, _ in sent.append(type) }
        let offer = FileOfferPayload(id: UUID(), name: "sneaky.txt", size: 3, clipboard: true)
        files.handle(message: MacLinkerMessage(type: .fileOffer, sequence: 0, payload: try JSONEncoder().encode(offer)), from: "peer")
        XCTAssertEqual(sent, [.fileAbort])
        XCTAssertTrue(files.transfers.isEmpty, "nothing was created")
        XCTAssertFalse(FileManager.default.fileExists(atPath: K.downloadsDirectory.appendingPathComponent("sneaky.txt").path))
    }

    func testOldOffersWithoutTheFlagStillDecode() throws {
        let legacy = Data(#"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","name":"a.txt","size":3}"#.utf8)
        let offer = try JSONDecoder().decode(FileOfferPayload.self, from: legacy)
        XCTAssertNil(offer.clipboard)
    }
}
