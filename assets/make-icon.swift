import AppKit

// Draws the app icon (a folder with a sync mark on a blue squircle) and writes AppIcon.png at 1024 px.
// assets/make-icon.sh turns that into AppIcon.icns.

let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor(red: 0.12, green: 0.45, blue: 0.9, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

NSGradient(colors: [NSColor(red: 0.30, green: 0.72, blue: 1.0, alpha: 1), NSColor(red: 0.08, green: 0.36, blue: 0.86, alpha: 1)])!
    .draw(in: shape, angle: -90)

func symbol(_ name: String, points: CGFloat, color: NSColor) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: points, weight: .semibold)
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let out = NSImage(size: base.size)
    out.lockFocus()
    base.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    color.set()
    NSRect(origin: .zero, size: base.size).fill(using: .sourceAtop)
    out.unlockFocus()
    return out
}

let folder = symbol("folder.fill", points: 520, color: .white)
let fr = NSRect(x: CGFloat(side) / 2 - folder.size.width / 2, y: CGFloat(side) / 2 - folder.size.height / 2 + 10,
                width: folder.size.width, height: folder.size.height)
NSGraphicsContext.saveGraphicsState()
let s2 = NSShadow()
s2.shadowColor = NSColor.black.withAlphaComponent(0.25)
s2.shadowOffset = NSSize(width: 0, height: -10)
s2.shadowBlurRadius = 18
s2.set()
folder.draw(in: fr)
NSGraphicsContext.restoreGraphicsState()

let mark = symbol("arrow.triangle.2.circlepath", points: 230, color: NSColor(red: 0.10, green: 0.42, blue: 0.88, alpha: 1))
mark.draw(at: NSPoint(x: CGFloat(side) / 2 - mark.size.width / 2, y: fr.midY - mark.size.height / 2 - 28),
          from: .zero, operation: .sourceOver, fraction: 1)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
