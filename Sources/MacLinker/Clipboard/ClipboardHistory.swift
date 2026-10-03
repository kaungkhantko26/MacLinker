import Foundation

struct ClipboardEntry: Identifiable, Equatable {
    enum Kind { case text, image, files, note }
    let id = UUID()
    let date = Date()
    /// "This Mac" or the name of the Mac it came from.
    let source: String
    let kind: Kind
    let preview: String
    let byteCount: Int
    /// Kept so the item can be copied or sent again. Nil when it was too large to keep.
    let message: ClipboardMessage?
    /// For copied files: where they are on this Mac (the original, or the cache for files that arrived).
    var fileURLs: [URL] = []

    static func == (a: ClipboardEntry, b: ClipboardEntry) -> Bool { a.id == b.id }
}

/// Recent clipboard items (local and received). In memory only: nothing is written to disk.
final class ClipboardHistory: ObservableObject {
    static let limit = 30
    static let keepLimit = 2 * 1024 * 1024

    @Published private(set) var entries: [ClipboardEntry] = []

    func add(_ message: ClipboardMessage, source: String) {
        guard let entry = Self.entry(for: message, source: source) else { return }
        // Don't list the same thing twice in a row (copying it here, then it echoing back).
        if let last = entries.first, last.kind == entry.kind, last.preview == entry.preview, last.byteCount == entry.byteCount { return }
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func addFiles(_ urls: [URL], source: String) {
        guard !urls.isEmpty else { return }
        let names = urls.map(\.lastPathComponent)
        let preview = names.count == 1 ? names[0] : "\(names[0]) and \(names.count - 1) more"
        insert(ClipboardEntry(source: source, kind: .files, preview: preview, byteCount: 0, message: nil, fileURLs: urls))
    }

    /// A line of explanation in the list, e.g. why copied files weren't sent.
    func addNote(_ text: String, source: String) {
        insert(ClipboardEntry(source: source, kind: .note, preview: text, byteCount: 0, message: nil))
    }

    private func insert(_ entry: ClipboardEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func clear() { entries.removeAll() }

    static func entry(for message: ClipboardMessage, source: String) -> ClipboardEntry? {
        let keep = message.totalSize <= keepLimit ? message : nil
        if let png = message.entries.first(where: { $0.type == "public.png" }) {
            return ClipboardEntry(source: source, kind: .image, preview: "Image", byteCount: png.data.count, message: keep)
        }
        for type in ["public.utf8-plain-text", "public.url"] {
            if let e = message.entries.first(where: { $0.type == type }), let text = String(data: e.data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return ClipboardEntry(source: source, kind: .text, preview: String(trimmed.prefix(400)),
                                      byteCount: e.data.count, message: keep)
            }
        }
        return nil
    }
}
