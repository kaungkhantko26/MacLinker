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

    private struct Batch {
        var peer: String
        var offer: ClipboardFilesOffer
        var dir: URL
        var pending: Set<UUID>
        var finished: [UUID: URL] = [:]
        var failed = false
        var baselineChangeCount: Int
    }
    private var batches: [UUID: Batch] = [:]
    private var batchOfItem: [UUID: UUID] = [:]
    private var destinations: [UUID: URL] = [:]

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

    func send(_ urls: [URL], to peers: [String]) {
        let targets = peers.filter(peerSupports)
        guard isEnabled(), !targets.isEmpty, !urls.isEmpty else { return }
        guard urls.count <= ClipboardFilesOffer.maxItems else {
            DispatchQueue.main.async { self.onSkipped?(urls, 0) }
            return
        }
        work.async { self.prepareAndSend(urls, to: targets) }
    }

    private func prepareAndSend(_ urls: [URL], to targets: [String]) {
        var total: UInt64 = 0
        for url in urls {
            total += FileArchive.totalSize(of: url, cap: K.fileClipboardLimit)
            if total > K.fileClipboardLimit { break }
        }
        guard total <= K.fileClipboardLimit else {
            DispatchQueue.main.async { self.onSkipped?(urls, total) }
            return
        }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("maclinker-send-\(UUID().uuidString)")
        var prepared: [(url: URL, name: String, size: UInt64, archive: Bool)] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                do {
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    let archive = staging.appendingPathComponent(url.lastPathComponent + ".zip")
                    try FileArchive.zip(url, to: archive)
                    let size = ((try? FileManager.default.attributesOfItem(atPath: archive.path)[.size]) as? NSNumber)?.uint64Value ?? 0
                    prepared.append((archive, archive.lastPathComponent, size, true))
                } catch {
                    Log.error("couldn't pack \(url.lastPathComponent): \(error.localizedDescription)")
                }
            } else {
                let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0
                prepared.append((url, url.lastPathComponent, size, false))
            }
        }
        guard !prepared.isEmpty else { return }

        let group = DispatchGroup()
        for peer in targets {
            // Separate ids per peer, so each transfer is tracked on its own.
            let items = prepared.map { ClipboardFilesOffer.Item(id: UUID(), name: $0.name, size: $0.size, archive: $0.archive) }
            guard let payload = try? JSONEncoder().encode(ClipboardFilesOffer(batch: UUID(), items: items)) else { continue }
            send?(peer, .clipboardFiles, payload)
            for (file, item) in zip(prepared, items) {
                group.enter()
                files.sendFile(file.url, to: peer, id: item.id, name: item.name) { _ in group.leave() }
            }
        }
        group.notify(queue: work) { try? FileManager.default.removeItem(at: staging) }
    }

    // MARK: Receiving

    func handleOffer(_ payload: Data, from peer: String) {
        guard isEnabled(), let offer = try? JSONDecoder().decode(ClipboardFilesOffer.self, from: payload),
              Self.isAcceptable(offer) else { return }
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
                                     baselineChangeCount: pasteboard.changeCount)
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
            return
        }
        work.async { self.finalize(batch) }
    }

    private func finalize(_ batch: Batch) {
        var results: [URL] = []
        for item in batch.offer.items {
            guard let url = batch.finished[item.id] else { return }
            if item.archive {
                do {
                    let extracted = try FileArchive.unzip(url, into: batch.dir.appendingPathComponent("x-\(item.id.uuidString)"))
                    try? FileManager.default.removeItem(at: url)
                    results.append(contentsOf: extracted)
                } catch {
                    Log.error("couldn't unpack copied folder: \(error.localizedDescription)")
                    try? FileManager.default.removeItem(at: batch.dir)
                    return
                }
            } else {
                results.append(url)
            }
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
