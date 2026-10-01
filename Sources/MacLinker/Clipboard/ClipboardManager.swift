import Foundation
import AppKit

final class ClipboardManager {
    var isEnabled: () -> Bool = { true }
    var broadcast: ((Data) -> Void)?
    let history = ClipboardHistory()

    private let monitor = ClipboardMonitor()
    private let pasteboard = NSPasteboard.general

    /// Password managers flag secrets with these; never forward them.
    private let sensitive: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"), .init("org.nspasteboard.TransientType"),
        .init("com.agilebits.onepassword"),
    ]

    func start() {
        monitor.onChange = { [weak self] in self?.localChanged() }
        monitor.start()
    }

    /// The current clipboard as a message, or nil if it's empty, too big, or marked sensitive by a password manager.
    func currentMessage() -> ClipboardMessage? {
        let types = Set(pasteboard.types ?? [])
        guard types.isDisjoint(with: sensitive) else { return nil }
        var entries: [ClipboardMessage.Entry] = []
        if let png = pasteboard.data(forType: .png) ?? tiffAsPNG() {
            entries.append(.init(type: NSPasteboard.PasteboardType.png.rawValue, data: png))
        } else {
            for t in [NSPasteboard.PasteboardType.string, .rtf, .URL] {
                if let d = pasteboard.data(forType: t) { entries.append(.init(type: t.rawValue, data: d)) }
            }
        }
        let message = ClipboardMessage(entries: entries)
        return entries.isEmpty || message.totalSize > K.clipboardLimit ? nil : message
    }

    private func localChanged() {
        guard let message = currentMessage() else { return }
        history.add(message, source: "This Mac")
        guard isEnabled(), let payload = try? JSONEncoder().encode(message) else { return }
        broadcast?(payload)
    }

    /// Sends whatever is on the clipboard right now, even if automatic sharing is off.
    func payloadForSendNow() -> Data? {
        currentMessage().flatMap { try? JSONEncoder().encode($0) }
    }

    /// Puts an item from the history back on this Mac's clipboard.
    func copy(_ message: ClipboardMessage) {
        write(message)
    }

    private func tiffAsPNG() -> Data? {
        guard let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    func receive(_ payload: Data, from source: String) {
        guard isEnabled(), let message = try? JSONDecoder().decode(ClipboardMessage.self, from: payload),
              message.totalSize <= K.clipboardLimit else { return }
        history.add(message, source: source)
        write(message)
    }

    private func write(_ message: ClipboardMessage) {
        let items = message.entries.compactMap { e -> (NSPasteboard.PasteboardType, Data)? in
            let t = NSPasteboard.PasteboardType(e.type)
            return ClipboardMessage.allowed.contains(t) ? (t, e.data) : nil
        }
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        for (t, d) in items { pasteboard.setData(d, forType: t) }
        monitor.acknowledgeOwnWrite()
    }
}
