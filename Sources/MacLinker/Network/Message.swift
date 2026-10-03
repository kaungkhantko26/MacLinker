import Foundation

enum MessageType: UInt8 {
    case hello = 1
    case pairConfirm = 2
    case pairReject = 3
    case heartbeat = 4

    case mouseMove = 10
    case mouseButton = 11
    case scroll = 12
    case keyEvent = 13
    case flagsChanged = 14

    case enterControl = 20
    case releaseControl = 21
    case layout = 22

    case clipboard = 30

    case fileOffer = 40
    case fileChunk = 41
    case fileEnd = 42
    case fileAbort = 43

    case systemControl = 50
    case systemState = 51
    case systemQuery = 52
    case lockScreen = 53

    case clipboardFiles = 90
    case dragBegin = 91

    case deviceInfo = 80
    case deviceInfoQuery = 81

    /// Messages that may flow before the peer is paired/trusted.
    var isHandshakePhase: Bool {
        switch self {
        case .hello, .pairConfirm, .pairReject, .heartbeat: return true
        default: return false
        }
    }
}

struct MacLinkerMessage {
    let type: MessageType
    let sequence: UInt32
    let payload: Data
}

// MARK: - Edge

enum Edge: String, Codable, CaseIterable {
    case left, right, top, bottom

    var opposite: Edge {
        switch self {
        case .left: return .right
        case .right: return .left
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    var code: UInt8 {
        switch self {
        case .left: return 1
        case .right: return 2
        case .top: return 3
        case .bottom: return 4
        }
    }

    init?(code: UInt8) {
        switch code {
        case 1: self = .left
        case 2: self = .right
        case 3: self = .top
        case 4: self = .bottom
        default: return nil
        }
    }

    var title: String { rawValue.capitalized }
}

// MARK: - Payloads

protocol BinaryPayload {
    func encode() -> Data
    static func decode(_ data: Data) throws -> Self
}

struct HelloPayload: Codable {
    var name: String
    var deviceID: String
    /// True when the sender already trusts the receiver's identity key.
    var trustsYou: Bool
    var port: UInt16
    var appVersion: String
}

struct MouseMovePayload: BinaryPayload {
    var dx: Float
    var dy: Float

    func encode() -> Data { var w = ByteWriter(); w.f32(dx); w.f32(dy); return w.data }
    static func decode(_ data: Data) throws -> Self {
        var r = ByteReader(data)
        return Self(dx: try r.f32(), dy: try r.f32())
    }
}

struct MouseButtonPayload: BinaryPayload {
    var button: UInt8
    var down: Bool
    var clickCount: UInt8

    func encode() -> Data { var w = ByteWriter(); w.u8(button); w.bool(down); w.u8(clickCount); return w.data }
    static func decode(_ data: Data) throws -> Self {
        var r = ByteReader(data)
        return Self(button: try r.u8(), down: try r.bool(), clickCount: try r.u8())
    }
}

struct ScrollPayload: BinaryPayload {
    var dx: Int32
    var dy: Int32
    /// Continuous (trackpad/pixel) vs. line-based (notched wheel) deltas.
    var continuous: Bool

    func encode() -> Data { var w = ByteWriter(); w.i32(dx); w.i32(dy); w.bool(continuous); return w.data }
    static func decode(_ data: Data) throws -> Self {
        var r = ByteReader(data)
        return Self(dx: try r.i32(), dy: try r.i32(), continuous: try r.bool())
    }
}

struct KeyPayload: BinaryPayload {
    var keyCode: UInt16
    var down: Bool
    var flags: UInt64
    var autorepeat: Bool

    func encode() -> Data {
        var w = ByteWriter()
        w.u16(keyCode); w.bool(down); w.u64(flags); w.bool(autorepeat)
        return w.data
    }
    static func decode(_ data: Data) throws -> Self {
        var r = ByteReader(data)
        return Self(keyCode: try r.u16(), down: try r.bool(), flags: try r.u64(), autorepeat: try r.bool())
    }
}

/// `enterControl`: the controller left through `edge` at normalised position `position`.
/// `releaseControl`: control is handed back; a negative position means "no warp".
struct ControlPayload: BinaryPayload {
    var edge: Edge
    var position: Float

    func encode() -> Data { var w = ByteWriter(); w.u8(edge.code); w.f32(position); return w.data }
    static func decode(_ data: Data) throws -> Self {
        var r = ByteReader(data)
        guard let edge = Edge(code: try r.u8()) else { throw MessageError.malformed }
        return Self(edge: edge, position: try r.f32())
    }
}

struct LayoutPayload: BinaryPayload {
    /// Where the *sender* places the receiver's Mac relative to its own screen.
    var peerPosition: Edge?
    /// True when the user just changed it; false for the sync that happens on connect.
    var userInitiated: Bool

    func encode() -> Data { var w = ByteWriter(); w.u8(peerPosition?.code ?? 0); w.bool(userInitiated); return w.data }
    static func decode(_ data: Data) throws -> Self {
        var r = ByteReader(data)
        return Self(peerPosition: Edge(code: try r.u8()), userInitiated: try r.bool())
    }
}

struct FileOfferPayload: Codable {
    var id: UUID
    var name: String
    var size: UInt64
    /// True for files sent because they were copied. A Mac that isn't expecting a copied batch refuses them
    /// instead of saving them to Downloads like an ordinary received file.
    var clipboard: Bool?
}

/// Ask the receiving Mac to change one of its own settings.
struct SystemControlPayload: BinaryPayload {
    enum Kind: UInt8 { case brightness = 1, volume = 2, mute = 3 }
    var kind: Kind
    /// 0...1 for brightness and volume; 0 or 1 for mute.
    var value: Float

    func encode() -> Data { var w = ByteWriter(); w.u8(kind.rawValue); w.f32(value); return w.data }
    static func decode(_ data: Data) throws -> Self {
        var r = ByteReader(data)
        guard let kind = Kind(rawValue: try r.u8()) else { throw MessageError.malformed }
        let v = try r.f32()
        guard v.isFinite else { throw MessageError.malformed }
        return Self(kind: kind, value: min(max(v, 0), 1))
    }
}

/// What a Mac can do and its current values. Negative values mean "unknown".
struct SystemStatePayload: BinaryPayload, Equatable {
    var hasBrightness: Bool
    var hasVolume: Bool
    var brightness: Float
    var volume: Float
    var muted: Bool

    func encode() -> Data {
        var w = ByteWriter()
        w.bool(hasBrightness); w.bool(hasVolume); w.f32(brightness); w.f32(volume); w.bool(muted)
        return w.data
    }
    static func decode(_ data: Data) throws -> Self {
        var r = ByteReader(data)
        return Self(hasBrightness: try r.bool(), hasVolume: try r.bool(), brightness: try r.f32(),
                    volume: try r.f32(), muted: try r.bool())
    }
}

/// What a Mac tells its peers about itself: shown on the Home cards.
struct DeviceInfoPayload: Codable, Equatable {
    struct Peripheral: Codable, Equatable {
        var name: String
        /// "Bluetooth", "USB", "Built-in", ...
        var transport: String
        /// 0...100 when the device reports it.
        var battery: Int?
    }
    var kind: String          // "laptop" or "desktop"
    var model: String         // hardware model identifier
    var osVersion: String
    var keyboards: [Peripheral]
    var pointers: [Peripheral]
    var audioOutput: String?
    var network: String?      // "Wi-Fi", "Ethernet", "USB-C cable", ...

    static let empty = DeviceInfoPayload(kind: "desktop", model: "", osVersion: "", keyboards: [], pointers: [],
                                         audioOutput: nil, network: nil)
}
