// Builds Resources/AppIcon.icns from Resources/AppIconSource.webp (the artwork has a white margin and
// no transparency, so this finds the rounded square, masks it, and lays it out on the macOS icon grid).
import AppKit

let srcPath = "Resources/AppIconSource.webp"
guard let nsImage = NSImage(contentsOfFile: srcPath),
      let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot read \(srcPath)\n", stderr); exit(1)
}
let W = cg.width

// The tile inside the 1254 px artwork (white margin and soft glow excluded). It is 1078 x 1050, so it is
// scaled to a square icon with a ~3% stretch, which is not visible.
let scale = CGFloat(W) / 1254
let crop = CGRect(x: 88 * scale, y: 85 * scale, width: 1078 * scale, height: 1050 * scale).integral
guard let tile = cg.cropping(to: crop) else { fputs("crop failed\n", stderr); exit(1) }

let dir = "build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    g.cgContext.interpolationQuality = .high
    let s = CGFloat(px)
    let art = s * 824 / 1024                       // macOS icon grid: artwork is 80.5% of the canvas
    let rect = CGRect(x: (s - art) / 2, y: (s - art) / 2, width: art, height: art)
    g.cgContext.saveGState()
    g.cgContext.addPath(CGPath(roundedRect: rect, cornerWidth: art * 0.2237, cornerHeight: art * 0.2237, transform: nil))
    g.cgContext.clip()
    g.cgContext.draw(tile, in: rect)
    g.cgContext.restoreGState()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for px in [16, 32, 64, 128, 256, 512, 1024] {
    let data = render(px)
    if px <= 512 { try! data.write(to: URL(fileURLWithPath: "\(dir)/icon_\(px)x\(px).png")) }
    if px >= 32 { try! data.write(to: URL(fileURLWithPath: "\(dir)/icon_\(px / 2)x\(px / 2)@2x.png")) }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
exit(p.terminationStatus)
