import Foundation
import CoreGraphics
import CVirtualDisplay

/// A display that exists only in software. macOS treats it like a real monitor, so windows can be dragged
/// onto it and the pointer can move onto it; its picture is what gets streamed to the other Mac.
/// Uses CoreGraphics' private virtual-display API (the one DeskPad and BetterDisplay rely on).
/// It disappears when this object is released or the app quits.
final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    let pointsSize: CGSize
    let scale: Int
    private let display: CGVirtualDisplay

    /// `pointsWidth/Height` is the logical size; with `scale` 2 the display is HiDPI (Retina-style).
    init?(name: String, pointsWidth: Int, pointsHeight: Int, scale: Int = 2, refreshRate: Double = 60) {
        let w = max(640, min(pointsWidth, 4096)), h = max(480, min(pointsHeight, 4096))
        let desc = CGVirtualDisplayDescriptor()
        desc.name = name
        desc.maxPixelsWide = UInt32(w * scale)
        desc.maxPixelsHigh = UInt32(h * scale)
        desc.sizeInMillimeters = CGSize(width: 25.4 * Double(w) / 110, height: 25.4 * Double(h) / 110)
        desc.productID = 0x4D4C
        desc.vendorID = 0x4D4C
        desc.serialNum = UInt32.random(in: 1...UInt32.max)
        desc.queue = DispatchQueue(label: "maclinker.virtualdisplay")
        guard let display = CGVirtualDisplay(descriptor: desc) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = scale > 1 ? 1 : 0
        settings.modes = [CGVirtualDisplayMode(width: UInt(w * scale), height: UInt(h * scale), refreshRate: refreshRate)]
        guard display.applyVirtual(settings) else { return nil }

        self.display = display
        self.displayID = display.displayID
        self.pointsSize = CGSize(width: w, height: h)
        self.scale = scale
    }

    /// Where this display sits in the global desktop (points). Changes if the user rearranges displays.
    var bounds: CGRect { CGDisplayBounds(displayID) }
}
