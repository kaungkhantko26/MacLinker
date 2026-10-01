import Foundation

struct ShelfItem: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let added = Date()
    var name: String { url.lastPathComponent }
    var size: Int64 { ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.int64Value ?? 0 }
}

/// A holding area: drop files here, then send them to a Mac whenever you're ready. Items are references to the
/// original files (nothing is copied), remembered between launches, and dropped from the list if the file disappears.
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    private let defaults: UserDefaults
    private let key = "dropShelfPaths"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let paths = defaults.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }.map { ShelfItem(url: $0) }
    }

    func add(_ urls: [URL]) {
        for url in urls where url.isFileURL && !items.contains(where: { $0.url == url }) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            items.append(ShelfItem(url: url))
        }
        save()
    }

    func remove(_ item: ShelfItem) { items.removeAll { $0.id == item.id }; save() }
    func clear() { items.removeAll(); save() }

    private func save() { defaults.set(items.map { $0.url.path }, forKey: key) }
}
