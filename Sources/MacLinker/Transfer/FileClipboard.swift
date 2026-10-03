import Foundation
import AppKit

/// Sent before the files themselves, so the other Mac knows a copied batch is coming and where to keep it.
struct ClipboardFilesOffer: Codable, Equatable {
    struct Item: Codable, Equatable {
        var id: UUID
        /// Name on the wire. A folder or app is sent as a zip named "<Name>.zip".
        var name: String
        var size: UInt64
        var archive: Bool
    }
    var batch: UUID
    var items: [Item]

    static let maxItems = 200
}

enum FileArchive {
    struct ArchiveError: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Folders and apps travel as a zip made with `ditto`, which keeps permissions, symlinks, code signatures and
    /// extended attributes intact (a plain zip would break an app bundle).
    static func zip(_ source: URL, to destination: URL) throws {
        try run(["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, destination.path])
    }

    /// Extracts into `directory` and returns the top-level items. Anything that ends up outside the directory
    /// (a hostile archive) is deleted and rejected.
    static func unzip(_ archive: URL, into directory: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try run(["-x", "-k", archive.path, directory.path])
        let root = directory.resolvingSymlinksInPath().path + "/"
        let top = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for url in top where !(url.resolvingSymlinksInPath().path + "/").hasPrefix(root) {
            try? fm.removeItem(at: directory)
            throw ArchiveError(message: "The archive tried to write outside its folder.")
        }
        return top
    }

    /// Total size of a file or folder, stopping early once it passes `cap` (so a huge folder isn't fully walked).
    static func totalSize(of url: URL, cap: UInt64) -> UInt64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue { return ((try? fm.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0 }
        var total: UInt64 = 0
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += UInt64(values?.fileSize ?? 0) }
            if total > cap { return total }
        }
        return total
    }

    private static func run(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw ArchiveError(message: text.isEmpty ? "ditto failed (\(p.terminationStatus))" : text)
        }
    }
}

/// Copy a file (or folder, or app) on one Mac, paste it on the other.
///
/// When files are copied here they are sent to connected Macs and kept in a cache folder there; once they have all
/// arrived, that Mac's clipboard is set to point at them, so Cmd+V in Finder pastes them.
final class FileClipboardManager {
    var isEnabled: () -> Bool = { true }
    var peerSupports: (String) -> Bool = { _ in false }
    var peerName: (String) -> String = { $0 }
    var send: ((String, MessageType, Data) -> Void)?
    /// Called right after this Mac's clipboard is rewritten, so the clipboard watcher doesn't treat it as a new copy.
    var wrotePasteboard: () -> Void = {}
    /// Copied files arrived and are on the clipboard (or, if you copied something else meanwhile, just in the cache).
    var onReceived: (([URL], String, Bool) -> Void)?
    /// Files were too big to send automatically.
    var onSkipped: (([URL], UInt64) -> Void)?

    private let files: FileTransferManager
    private let pasteboard: NSPasteboard
    private let cacheRoot: URL
    private let work = DispatchQueue(label: "maclinker.fileclipboard", qos: .utility)

    /// What a received batch is for: put on the clipboard, or handed to a drag in progress.
    enum Purpose { case clipboard, drag }

    private struct Batch {
        var peer: String
        var offer: ClipboardFilesOffer
        var dir: URL
        var pending: Set<UUID>
        var finished: [UUID: URL] = [:]
        var failed = false
        var baselineChangeCount: Int
        var purpose: Purpose
    }
    private var batches: [UUID: Batch] = [:]
    private var batchOfItem: [UUID: UUID] = [:]
    private var destinations: [UUID: URL] = [:]

    // Final location of each item of a *drag* batch, for a drop that may arrive before or after the data does.
    private let results = NSCondition()
    private var itemResults: [UUID: URL?] = [:]

    init(files: FileTransferManager, pasteboard: NSPasteboard = .general, cacheRoot: URL? = nil) {
        self.files = files
        self.pasteboard = pasteboard
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacLinker/CopiedFiles", isDirectory: true)
        files.destinationFor = { [weak self] id in self?.destinations[id] }
        files.onFinished = { [weak self] id, url, error in self?.finished(id, url: url, error: error) }
        // On launch only drop batches older than a day; recent ones may still be wanted.
        pruneCache(keeping: .max, olderThan: 24 * 3600)
    }

    // MARK: Sending

    /// One file (or one folder/app, which travels as a zip) in a batch about to be sent.
    struct Planned {
        let source: URL
        let id: UUID
        /// Name on the wire ("Folder.zip" for an archive).
        let name: String
        /// For an archive this is the *uncompressed* size, an upper bound; the real size is announced when it's sent.
        let estimatedSize: UInt64
        let archive: Bool
    }

    enum PlanResult { case ready([Planned]), tooBig(UInt64), tooMany, nothing }

    /// Decides what would be sent, without touching the disk beyond measuring sizes. Cheap enough to call at the screen edge.
    func plan(_ urls: [URL]) -> PlanResult {
        guard !urls.isEmpty else { return .nothing }
        guard urls.count <= ClipboardFilesOffer.maxItems else { return .tooMany }
        var total: UInt64 = 0
        var planned: [Planned] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            let size = FileArchive.totalSize(of: url, cap: K.fileClipboardLimit)
            total += size
            if total > K.fileClipboardLimit { return .tooBig(total) }
            planned.append(Planned(source: url, id: UUID(), name: isDir.boolValue ? url.lastPathComponent + ".zip" : url.lastPathComponent,
                                   estimatedSize: size, archive: isDir.boolValue))
        }
        return planned.isEmpty ? .nothing : .ready(planned)
    }

    static func offer(for planned: [Planned]) -> ClipboardFilesOffer {
        ClipboardFilesOffer(batch: UUID(), items: planned.map {
            ClipboardFilesOffer.Item(id: $0.id, name: $0.name, size: $0.estimatedSize, archive: $0.archive)
        })
    }

    /// Copy: announce the batch, then stream it, to every peer that can take it.
    func send(_ urls: [URL], to peers: [String]) {
        let targets = peers.filter(peerSupports)
        guard isEnabled(), !targets.isEmpty, !urls.isEmpty else { return }
        work.async {
            for peer in targets {
                switch self.plan(urls) {      // fresh ids per peer, so each transfer is tracked on its own
                case .ready(let planned):
                    guard let payload = try? JSONEncoder().encode(Self.offer(for: planned)) else { continue }
                    self.send?(peer, .clipboardFiles, payload)
                    self.transmit(planned, to: peer)
                case .tooBig(let total): DispatchQueue.main.async { self.onSkipped?(urls, total) }; return
                case .tooMany: DispatchQueue.main.async { self.onSkipped?(urls, 0) }; return
                case .nothing: return
                }
            }
        }
    }

    /// Packs folders into zips and streams every item. The announcing message must already have been sent.
    func transmit(_ planned: [Planned], to peer: String) {
        work.async {
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("maclinker-send-\(UUID().uuidString)")
            let group = DispatchGroup()
            for item in planned {
                var url = item.source
                if item.archive {
                    do {
                        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                        url = staging.appendingPathComponent(item.name)
                        try FileArchive.zip(item.source, to: url)
                    } catch {
                        Log.error("couldn't pack \(item.source.lastPathComponent): \(error.localizedDescription)")
                        self.send?(peer, .fileAbort, Data(uuidBytes(item.id)))
                        continue
                    }
                }
                group.enter()
                self.files.sendFile(url, to: peer, id: item.id, name: item.name) { _ in group.leave() }
            }
            group.notify(queue: self.work) { try? FileManager.default.removeItem(at: staging) }
        }
    }

    // MARK: Receiving

    func handleOffer(_ payload: Data, from peer: String) {
        guard isEnabled(), let offer = try? JSONDecoder().decode(ClipboardFilesOffer.self, from: payload) else { return }
        register(offer, from: peer, purpose: .clipboard)
    }

    /// Reserves cache locations for a batch we've been told to expect. Used for both copied files and drags.
    func register(_ offer: ClipboardFilesOffer, from peer: String, purpose: Purpose) {
        guard Self.isAcceptable(offer) else { return }
        pruneCache(keeping: 4, olderThan: 24 * 3600)
        let dir = cacheRoot.appendingPathComponent(offer.batch.uuidString, isDirectory: true)
        var taken = Set<String>()
        var pending = Set<UUID>()
        for item in offer.items {
            let name = Self.uniqueName(Self.sanitized(item.name), taken: &taken)
            destinations[item.id] = dir.appendingPathComponent(name)
            batchOfItem[item.id] = offer.batch
            pending.insert(item.id)
        }
        batches[offer.batch] = Batch(peer: peer, offer: offer, dir: dir, pending: pending,
                                     baselineChangeCount: pasteboard.changeCount, purpose: purpose)
        if purpose == .drag {      // forget any stale answer for these ids, so a drop waits for the real data
            results.lock()
            for item in offer.items { itemResults[item.id] = nil }
            results.unlock()
        }
    }

    static func isAcceptable(_ offer: ClipboardFilesOffer) -> Bool {
        guard !offer.items.isEmpty, offer.items.count <= ClipboardFilesOffer.maxItems else { return false }
        var total: UInt64 = 0
        for item in offer.items {
            guard item.size <= K.fileClipboardLimit else { return false }
            total += item.size
        }
        return total <= K.fileClipboardLimit
    }

    static func sanitized(_ name: String) -> String {
        let clean = (name as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\r/"))
        return clean.isEmpty ? "file" : clean
    }

    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        var candidate = name, n = 1
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        while taken.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    private func finished(_ id: UUID, url: URL?, error: String?) {
        guard let batchID = batchOfItem.removeValue(forKey: id), var batch = batches[batchID] else { return }
        destinations[id] = nil
        batch.pending.remove(id)
        if let url { batch.finished[id] = url } else { batch.failed = true }
        batches[batchID] = batch
        guard batch.pending.isEmpty else { return }
        batches[batchID] = nil
        if batch.failed {
            try? FileManager.default.removeItem(at: batch.dir)
            if batch.purpose == .drag { publish(batch.offer.items.map(\.id), results: [:]) }   // wake anyone waiting
            return
        }
        work.async { self.finalize(batch) }
    }

    private func finalize(_ batch: Batch) {
        var results: [URL] = []
        var perItem: [UUID: URL] = [:]
        for item in batch.offer.items {
            guard let url = batch.finished[item.id] else { return }
            if item.archive {
                do {
                    let extracted = try FileArchive.unzip(url, into: batch.dir.appendingPathComponent("x-\(item.id.uuidString)"))
                    try? FileManager.default.removeItem(at: url)
                    results.append(contentsOf: extracted)
                    if let first = extracted.first { perItem[item.id] = first }
                } catch {
                    Log.error("couldn't unpack copied folder: \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: batch.dir)
                    if batch.purpose == .drag { publish(batch.offer.items.map(\.id), results: [:]) }
                    return
                }
            } else {
                results.append(url)
                perItem[item.id] = url
            }
        }
        if batch.purpose == .drag {
            publish(batch.offer.items.map(\.id), results: perItem)
            return
        }
        DispatchQueue.main.async {
            // If you copied something else while this was arriving, don't overwrite it; the files stay in history.
            let untouched = self.pasteboard.changeCount == batch.baselineChangeCount
            if untouched {
                self.pasteboard.clearContents()
                self.pasteboard.writeObjects(results as [NSURL])
                self.wrotePasteboard()
            }
            self.onReceived?(results, self.peerName(batch.peer), untouched)
        }
    }

    // MARK: Waiting for a dropped item

    private func publish(_ ids: [UUID], results map: [UUID: URL]) {
        results.lock()
        for id in ids { itemResults[id] = .some(map[id]) }    // .some(nil) means "failed"
        results.broadcast()
        results.unlock()
    }

    /// Blocks (call it off the main thread) until a dragged item has arrived and is unpacked. Nil if it failed or timed out.
    func awaitItem(_ id: UUID, timeout: TimeInterval) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        results.lock(); defer { results.unlock() }
        while true {
            if let entry = itemResults[id] { return entry }          // arrived (URL) or failed (nil)
            if !results.wait(until: deadline) { return nil }
        }
    }

    /// Puts files already in the cache back on the clipboard (used from the history list).
    func putOnPasteboard(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(existing as [NSURL])
        wrotePasteboard()
    }

    // MARK: Cache

    /// Removes old batches, keeping the newest `keeping` that are younger than `olderThan` seconds.
    func pruneCache(keeping: Int, olderThan seconds: TimeInterval) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: cacheRoot, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let dated = dirs.map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        for (index, entry) in dated.enumerated()
        where index >= keeping || Date().timeIntervalSince(entry.1) > seconds {
            if batches.keys.contains(where: { cacheRoot.appendingPathComponent($0.uuidString) == entry.0 }) { continue }
            try? fm.removeItem(at: entry.0)
        }
    }
}

/// Raw 16 bytes of a UUID, the way file messages carry ids.
func uuidBytes(_ id: UUID) -> [UInt8] { withUnsafeBytes(of: id.uuid) { Array($0) } }
