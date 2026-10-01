// Renders the 🔗 emoji on a gray rounded square into Resources/AppIcon.icns
import AppKit

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let dir = "build/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let rect = NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.2, yRadius: s * 0.2)
    NSGradient(starting: NSColor(white: 0.62, alpha: 1), ending: NSColor(white: 0.42, alpha: 1))!.draw(in: path, angle: -90)
    let font = NSFont(name: "Apple Color Emoji", size: s * 0.55) ?? NSFont.systemFont(ofSize: s * 0.55)
    let str = NSAttributedString(string: "🔗", attributes: [.font: font])
    let size = str.size()
    str.draw(at: NSPoint(x: (s - size.width) / 2, y: (s - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in sizes {
    let data = render(px)
    if px <= 512 { try! data.write(to: URL(fileURLWithPath: "\(dir)/icon_\(px)x\(px).png")) }
    if px >= 32 { try! data.write(to: URL(fileURLWithPath: "\(dir)/icon_\(px / 2)x\(px / 2)@2x.png")) }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
