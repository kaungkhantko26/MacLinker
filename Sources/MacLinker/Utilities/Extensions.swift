import Foundation
import Network

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

enum ByteError: Error { case truncated }

struct ByteWriter {
    private(set) var data = Data()
    init() {}

    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func bool(_ v: Bool) { data.append(v ? 1 : 0) }
    mutating func u16(_ v: UInt16) { put(v.bigEndian) }
    mutating func u32(_ v: UInt32) { put(v.bigEndian) }
    mutating func u64(_ v: UInt64) { put(v.bigEndian) }
    mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }

    private mutating func put<T>(_ v: T) {
        var v = v
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }
}

struct ByteReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    var remaining: Int { data.endIndex - offset }

    private mutating func uint<T: FixedWidthInteger & UnsignedInteger>(_: T.Type) throws -> T {
        let n = MemoryLayout<T>.size
        guard remaining >= n else { throw ByteError.truncated }
        var v: T = 0
        for i in 0..<n { v = (v << 8) | T(data[offset + i]) }
        offset += n
        return v
    }

    mutating func u8() throws -> UInt8 { try uint(UInt8.self) }
    mutating func bool() throws -> Bool { try u8() != 0 }
    mutating func u16() throws -> UInt16 { try uint(UInt16.self) }
    mutating func u32() throws -> UInt32 { try uint(UInt32.self) }
    mutating func u64() throws -> UInt64 { try uint(UInt64.self) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    mutating func f32() throws -> Float { Float(bitPattern: try u32()) }

    mutating func bytes(_ n: Int) throws -> Data {
        guard n >= 0, remaining >= n else { throw ByteError.truncated }
        defer { offset += n }
        return data.subdata(in: offset..<offset + n)
    }

    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }
}

extension NWEndpoint {
    /// Host portion of a host/port endpoint without any interface scope suffix (`%en0`).
    var hostString: String? {
        guard case .hostPort(let host, _) = self else { return nil }
        let s = "\(host)"
        return s.split(separator: "%").first.map(String.init)
    }

    var portValue: UInt16? {
        guard case .hostPort(_, let port) = self else { return nil }
        return port.rawValue
    }
}
