// Draws the installer window background (660x400 pt, saved at 2x) to Resources/dmg-background.png
import AppKit

let w = 660, h = 400, scale = 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w * scale, pixelsHigh: h * scale, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: w, height: h)   // 144 dpi so Finder shows it at 660x400 points
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Mid-tone gradient from the icon's palette: readable with both light and dark Finder label colours.
NSGradient(colors: [NSColor(red: 0.36, green: 0.52, blue: 1.0, alpha: 1),
                    NSColor(red: 0.55, green: 0.40, blue: 0.95, alpha: 1),
                    NSColor(red: 0.85, green: 0.45, blue: 0.80, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -35)

// Soft glass panel behind the two icons.
let panel = NSBezierPath(roundedRect: NSRect(x: 40, y: 95, width: 580, height: 210), xRadius: 28, yRadius: 28)
NSColor(white: 1, alpha: 0.16).setFill(); panel.fill()
NSColor(white: 1, alpha: 0.35).setStroke(); panel.lineWidth = 1.5; panel.stroke()

// Arrow between the app icon (x=170) and the Applications folder (x=490), at icon-centre height.
let arrowY: CGFloat = 215   // flipped: Finder y=190 from the top -> 400-190+... icons sit around this line
NSColor.white.setStroke(); NSColor.white.setFill()
let shaft = NSBezierPath(); shaft.lineWidth = 7; shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 262, y: arrowY)); shaft.line(to: NSPoint(x: 380, y: arrowY)); shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 398, y: arrowY)); head.line(to: NSPoint(x: 372, y: arrowY + 20)); head.line(to: NSPoint(x: 372, y: arrowY - 20)); head.close(); head.fill()

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, y: CGFloat, alpha: CGFloat = 1) {
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: NSColor(white: 1, alpha: alpha), .paragraphStyle: p]
    NSAttributedString(string: s, attributes: attrs).draw(in: NSRect(x: 0, y: y, width: CGFloat(w), height: size + 10))
}
text("Install MacLinker", size: 30, weight: .bold, y: 330)
text("Drag MacLinker onto Applications", size: 15, weight: .medium, y: 300, alpha: 0.92)
text("One keyboard and mouse across your Macs", size: 12, weight: .regular, y: 40, alpha: 0.8)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Resources/dmg-background.png"))
