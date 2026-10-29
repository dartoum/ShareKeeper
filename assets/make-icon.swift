import AppKit

// Draws the app icon at 1024 px: a folder with a sync mark on a blue background.
// assets/make-icon.sh turns the PNG into AppIcon.icns.

let side = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}

func shadowed(_ blur: CGFloat, _ dy: CGFloat, _ alpha: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let s = NSShadow()
    s.shadowColor = NSColor.black.withAlphaComponent(alpha)
    s.shadowOffset = NSSize(width: 0, height: dy)
    s.shadowBlurRadius = blur
    s.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

// Squircle background with a soft top light.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 190, yRadius: 190)
shadowed(30, -16, 0.35) { rgb(30, 83, 154).setFill(); squircle.fill() }
NSGradient(colors: [rgb(106, 186, 229), rgb(46, 125, 195), rgb(32, 75, 150)], atLocations: [0, 0.55, 1],
           colorSpace: .deviceRGB)!.draw(in: squircle, angle: -90)
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.12), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// A single folder silhouette with a raised front: fewer competing shapes at small sizes.
let back = NSBezierPath()
back.move(to: NSPoint(x: 218, y: 312))
back.line(to: NSPoint(x: 218, y: 686))
back.curve(to: NSPoint(x: 260, y: 728), controlPoint1: NSPoint(x: 218, y: 710), controlPoint2: NSPoint(x: 236, y: 728))
back.line(to: NSPoint(x: 405, y: 728))
back.curve(to: NSPoint(x: 451, y: 700), controlPoint1: NSPoint(x: 425, y: 728), controlPoint2: NSPoint(x: 438, y: 720))
back.line(to: NSPoint(x: 466, y: 680))
back.line(to: NSPoint(x: 758, y: 680))
back.curve(to: NSPoint(x: 806, y: 632), controlPoint1: NSPoint(x: 784, y: 680), controlPoint2: NSPoint(x: 806, y: 658))
back.line(to: NSPoint(x: 806, y: 312))
back.close()
shadowed(28, -14, 0.24) { rgb(184, 211, 235).setFill(); back.fill() }
NSGradient(colors: [rgb(222, 239, 251), rgb(169, 203, 229)])!.draw(in: back, angle: -90)

let front = NSBezierPath(roundedRect: NSRect(x: 218, y: 278, width: 588, height: 368), xRadius: 48, yRadius: 48)
shadowed(20, -9, 0.16) { NSColor.white.setFill(); front.fill() }
NSGradient(colors: [rgb(255, 255, 255), rgb(225, 239, 249)])!.draw(in: front, angle: -90)

// SF Symbols provides the optically balanced, scalable sync mark.
let configuration = NSImage.SymbolConfiguration(pointSize: 216, weight: .medium)
if let symbol = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)?
    .withSymbolConfiguration(configuration) {
    let colored = NSImage(size: symbol.size, flipped: false) { rect in
        symbol.draw(in: rect)
        rgb(43, 112, 179).setFill()
        rect.fill(using: .sourceAtop)
        return true
    }
    let size = colored.size
    colored.draw(in: NSRect(x: 512 - size.width / 2, y: 462 - size.height / 2,
                            width: size.width, height: size.height))
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
