import Foundation
import CoreGraphics

enum ScreenGeometry {
    private static var cached: CGRect?
    private static var registered = false
    fileprivate static let lock = NSLock()

    /// Union of all active displays in global (top-left origin) coordinates.
    /// Cached: this is read on every mouse event, and enumerating displays each time is slow.
    static var bounds: CGRect {
        lock.lock(); defer { lock.unlock() }
        if !registered {
            registered = true
            CGDisplayRegisterReconfigurationCallback({ _, _, _ in ScreenGeometry.lock.lock(); ScreenGeometry.cached = nil; ScreenGeometry.lock.unlock() }, nil)
        }
        if let cached { return cached }
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(max(count, 1)))
        CGGetActiveDisplayList(count, &ids, &count)
        let b = ids.prefix(Int(count)).map { CGDisplayBounds($0) }.reduce(CGRect.null) { $0.union($1) }
        cached = b
        return b
    }
}

extension Edge {
    private static let slop: CGFloat = 1.5

    /// Is the pointer on this edge and moving outward?
    func isPushing(at p: CGPoint, delta: CGPoint, in b: CGRect) -> Bool {
        switch self {
        case .right: return p.x >= b.maxX - Self.slop && delta.x > 0
        case .left: return p.x <= b.minX + Self.slop && delta.x < 0
        case .bottom: return p.y >= b.maxY - Self.slop && delta.y > 0
        case .top: return p.y <= b.minY + Self.slop && delta.y < 0
        }
    }

    func outward(_ d: CGPoint) -> Double {
        switch self {
        case .right: return Double(d.x)
        case .left: return Double(-d.x)
        case .bottom: return Double(d.y)
        case .top: return Double(-d.y)
        }
    }

    /// 0...1 along the edge.
    func normalizedPosition(of p: CGPoint, in b: CGRect) -> Float {
        let v: CGFloat
        switch self {
        case .left, .right: v = (p.y - b.minY) / max(b.height, 1)
        case .top, .bottom: v = (p.x - b.minX) / max(b.width, 1)
        }
        return Float(min(max(v, 0), 1))
    }

    /// A point just inside this edge at the given normalised position.
    func point(at position: Float, inset: CGFloat, in b: CGRect) -> CGPoint {
        let t = CGFloat(min(max(position, 0), 1))
        switch self {
        case .left: return CGPoint(x: b.minX + inset, y: b.minY + t * (b.height - 1))
        case .right: return CGPoint(x: b.maxX - 1 - inset, y: b.minY + t * (b.height - 1))
        case .top: return CGPoint(x: b.minX + t * (b.width - 1), y: b.minY + inset)
        case .bottom: return CGPoint(x: b.minX + t * (b.width - 1), y: b.maxY - 1 - inset)
        }
    }
}

/// Requires sustained outward pressure against an edge before reporting a crossing,
/// so a pointer merely grazing the edge doesn't hand control to the other Mac.
struct ScreenEdgeDetector {
    struct Hit { let edge: Edge; let position: Float }

    var threshold: Double
    private var accumulated = 0.0
    private var current: Edge?

    init(threshold: Double = K.defaultEdgePush) { self.threshold = threshold }

    mutating func reset() { accumulated = 0; current = nil }

    mutating func update(location: CGPoint, delta: CGPoint, bounds: CGRect, edges: Set<Edge>) -> Hit? {
        guard let edge = edges.first(where: { $0.isPushing(at: location, delta: delta, in: bounds) }) else {
            reset()
            return nil
        }
        if current != edge { current = edge; accumulated = 0 }
        accumulated += edge.outward(delta)
        guard accumulated >= threshold else { return nil }
        let hit = Hit(edge: edge, position: edge.normalizedPosition(of: location, in: bounds))
        reset()
        return hit
    }
}
