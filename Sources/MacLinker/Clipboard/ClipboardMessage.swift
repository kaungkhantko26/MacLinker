import Foundation
import AppKit

struct ClipboardMessage: Codable {
    struct Entry: Codable {
        let type: String
        let data: Data
    }
    var entries: [Entry]

    /// Only these pasteboard types are ever sent or accepted.
    static let allowed: [NSPasteboard.PasteboardType] = [.string, .rtf, .png, .URL]

    var totalSize: Int { entries.reduce(0) { $0 + $1.data.count } }
}
