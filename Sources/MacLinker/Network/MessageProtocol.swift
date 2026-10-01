import Foundation

enum MessageError: Error {
    case malformed
    case badMagic
    case unsupportedVersion(UInt8)
    case unknownType(UInt8)
    case frameTooLarge
}

/// Plaintext layout of one MacLinker message (this is what gets encrypted):
///
///     magic(4) version(1) type(1) sequence(4) payloadLength(4) payload(n)
enum MessageProtocol {
    static let headerSize = 14

    static func encode(type: MessageType, sequence: UInt32, payload: Data) -> Data {
        var w = ByteWriter()
        w.u32(K.protocolMagic)
        w.u8(K.protocolVersion)
        w.u8(type.rawValue)
        w.u32(sequence)
        w.u32(UInt32(payload.count))
        w.bytes(payload)
        return w.data
    }

    static func decode(_ data: Data) throws -> MacLinkerMessage {
        var r = ByteReader(data)
        guard try r.u32() == K.protocolMagic else { throw MessageError.badMagic }
        let version = try r.u8()
        guard version == K.protocolVersion else { throw MessageError.unsupportedVersion(version) }
        let rawType = try r.u8()
        guard let type = MessageType(rawValue: rawType) else { throw MessageError.unknownType(rawType) }
        let sequence = try r.u32()
        let length = Int(try r.u32())
        guard r.remaining == length else { throw MessageError.malformed }
        return MacLinkerMessage(type: type, sequence: sequence, payload: r.rest())
    }

    /// Length-prefixes a body for the TCP stream.
    static func frame(_ body: Data) -> Data {
        var w = ByteWriter()
        w.u32(UInt32(body.count))
        w.bytes(body)
        return w.data
    }
}

/// Reassembles length-prefixed frames from an arbitrary TCP byte stream.
struct FrameBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    mutating func nextFrame(limit: Int) throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let s = buffer.startIndex
        let length = Int(buffer[s]) << 24 | Int(buffer[s + 1]) << 16 | Int(buffer[s + 2]) << 8 | Int(buffer[s + 3])
        guard length <= limit else { throw MessageError.frameTooLarge }
        guard buffer.count >= 4 + length else { return nil }
        let frame = buffer.subdata(in: s + 4..<s + 4 + length)
        buffer.removeSubrange(s..<s + 4 + length)
        return frame
    }
}
