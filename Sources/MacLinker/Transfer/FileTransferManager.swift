import Foundation
import CryptoKit

struct TransferItem: Identifiable {
    enum Direction { case sending, receiving }
    enum Status: Equatable { case active, done, failed(String) }
    let id: UUID
    let name: String
    let size: UInt64
    let direction: Direction
    let peerName: String
    var transferred: UInt64 = 0
    var status: Status = .active
    var url: URL?
}

final class FileTransferManager: ObservableObject {
    @Published private(set) var transfers: [TransferItem] = []

    var isEnabled: () -> Bool = { true }
    var peerName: (String) -> String = { $0 }
    var send: ((MessageType, Data, String, ((Error?) -> Void)?) -> Void)?

    private struct Incoming {
        let handle: FileHandle
        let url: URL
        var hasher = SHA256()
        var received: UInt64 = 0
        let expected: UInt64
    }
    private var incoming: [UUID: Incoming] = [:]
    private var cancelled = Set<UUID>()
    private let cancelLock = NSLock()
    private func markCancelled(_ id: UUID) { cancelLock.lock(); cancelled.insert(id); cancelLock.unlock() }
    private func takeCancelled(_ id: UUID) -> Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }
        return cancelled.remove(id) != nil
    }
    private let io = DispatchQueue(label: "maclinker.files")

    private func update(_ id: UUID, _ change: @escaping (inout TransferItem) -> Void) {
        DispatchQueue.main.async {
            if let i = self.transfers.firstIndex(where: { $0.id == id }) { change(&self.transfers[i]) }
        }
    }

    // MARK: Sending

    func sendFiles(_ urls: [URL], to peer: String) {
        for url in urls where url.isFileURL {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            io.async { self.sendFile(url, to: peer) }
        }
    }

    private func sendFile(_ url: URL, to peer: String) {
        let id = UUID()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        let item = TransferItem(id: id, name: url.lastPathComponent, size: size, direction: .sending,
                                peerName: peerName(peer))
        DispatchQueue.main.async { self.transfers.insert(item, at: 0) }

        guard let offer = try? JSONEncoder().encode(FileOfferPayload(id: id, name: url.lastPathComponent, size: size)) else { return }
        send?(.fileOffer, offer, peer, nil)

        var hasher = SHA256()
        var sent: UInt64 = 0
        func finish(_ error: String?) {
            try? handle.close()
            update(id) { $0.status = error.map { .failed($0) } ?? .done }
        }
        func next() {
            if takeCancelled(id) { finish("Cancelled by receiver"); return }
            let chunk = (try? handle.read(upToCount: K.fileChunkSize)) ?? Data()
            if chunk.isEmpty {
                var w = ByteWriter()
                w.bytes(id.data); w.bytes(Data(hasher.finalize()))
                send?(.fileEnd, w.data, peer) { err in self.io.async { finish(err.map { "\($0)" }) } }
                return
            }
            hasher.update(data: chunk)
            var w = ByteWriter()
            w.bytes(id.data); w.bytes(chunk)
            sent += UInt64(chunk.count)
            let progress = sent
            update(id) { $0.transferred = progress }
            // Send the next chunk only once this one is on the wire: natural backpressure.
            send?(.fileChunk, w.data, peer) { err in
                self.io.async { if let err { finish("\(err)") } else { next() } }
            }
        }
        next()
    }

    // MARK: Receiving

    func handle(message: MacLinkerMessage, from peer: String) {
        do {
            switch message.type {
            case .fileOffer:
                let offer = try JSONDecoder().decode(FileOfferPayload.self, from: message.payload)
                guard isEnabled() else { send?(.fileAbort, offer.id.data, peer, nil); return }
                let url = uniqueURL(for: offer.name)
                FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
                guard let handle = try? FileHandle(forWritingTo: url) else {
                    send?(.fileAbort, offer.id.data, peer, nil); return
                }
                incoming[offer.id] = Incoming(handle: handle, url: url, expected: offer.size)
                var item = TransferItem(id: offer.id, name: url.lastPathComponent, size: offer.size,
                                        direction: .receiving, peerName: peerName(peer))
                item.url = url
                transfers.insert(item, at: 0)
            case .fileChunk:
                var r = ByteReader(message.payload)
                let id = try r.uuid()
                guard var f = incoming[id] else { return }
                let chunk = r.rest()
                f.received += UInt64(chunk.count)
                guard f.received <= f.expected else { abort(id, "More data than announced"); return }
                try f.handle.write(contentsOf: chunk)
                f.hasher.update(data: chunk)
                incoming[id] = f
                update(id) { $0.transferred = f.received }
            case .fileEnd:
                var r = ByteReader(message.payload)
                let id = try r.uuid()
                let digest = try r.bytes(32)
                guard let f = incoming.removeValue(forKey: id) else { return }
                try? f.handle.close()
                var hasher = f.hasher
                if Data(hasher.finalize()) == digest, f.received == f.expected {
                    update(id) { $0.status = .done; $0.transferred = $0.size }
                } else {
                    try? FileManager.default.removeItem(at: f.url)
                    update(id) { $0.status = .failed("Checksum mismatch") }
                }
            case .fileAbort:
                var r = ByteReader(message.payload)
                let id = try r.uuid()
                markCancelled(id)
                if incoming[id] != nil { abort(id, "Cancelled by sender") }
            default: break
            }
        } catch {
            Log.error("file transfer error: \(error)")
        }
    }

    private func abort(_ id: UUID, _ reason: String) {
        if let f = incoming.removeValue(forKey: id) {
            try? f.handle.close()
            try? FileManager.default.removeItem(at: f.url)
        }
        update(id) { $0.status = .failed(reason) }
    }

    func peerDisconnected() {
        for id in Array(incoming.keys) { abort(id, "Connection lost") }
    }

    /// Strips path components and hidden-file dots; never overwrites an existing file.
    private func uniqueURL(for name: String) -> URL {
        var clean = (name as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: ". \n\r/"))
        if clean.isEmpty { clean = "file" }
        let dir = K.downloadsDirectory
        var url = dir.appendingPathComponent(clean)
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }
}

private extension UUID {
    var data: Data { withUnsafeBytes(of: uuid) { Data($0) } }
}

private extension ByteReader {
    mutating func uuid() throws -> UUID {
        let d = try bytes(16)
        return d.withUnsafeBytes { UUID(uuid: $0.loadUnaligned(as: uuid_t.self)) }
    }
}
