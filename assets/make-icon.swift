import AppKit

// Draws the app icon and writes AppIcon.png at 1024 px: a folder with an exchange mark (two arrows, one
// each way) on a blue squircle. assets/make-icon.sh turns that into AppIcon.icns.

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
shadowed(30, -16, 0.35) { rgb(10, 80, 200).setFill(); squircle.fill() }
NSGradient(colors: [rgb(84, 190, 255), rgb(22, 110, 235), rgb(12, 74, 205)], atLocations: [0, 0.55, 1],
           colorSpace: .deviceRGB)!.draw(in: squircle, angle: -90)
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// Folder: a back panel with the tab, and a front panel in front of it.
let fx: CGFloat = 196, fw: CGFloat = 632
let back = NSBezierPath(roundedRect: NSRect(x: fx, y: 330, width: fw, height: 372), xRadius: 58, yRadius: 58)
let tab = NSBezierPath(roundedRect: NSRect(x: fx, y: 640, width: 262, height: 104), xRadius: 46, yRadius: 46)
let backAll = NSBezierPath()
backAll.append(back); backAll.append(tab)
shadowed(22, -8, 0.22) { rgb(255, 255, 255, 0.55).setFill(); backAll.fill() }
NSGradient(colors: [rgb(255, 255, 255, 0.78), rgb(214, 232, 255, 0.78)])!.draw(in: backAll, angle: -90)

let front = NSBezierPath(roundedRect: NSRect(x: fx, y: 262, width: fw, height: 372), xRadius: 58, yRadius: 58)
shadowed(30, -14, 0.30) { NSColor.white.setFill(); front.fill() }
NSGradient(colors: [rgb(255, 255, 255), rgb(226, 238, 255)])!.draw(in: front, angle: -90)

// Exchange mark on the front panel: one arrow each way.
func arrow(from a: CGPoint, to b: CGPoint, head: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.lineWidth = 50
    p.lineCapStyle = .round
    p.lineJoinStyle = .round
    p.move(to: a); p.line(to: b)
    let dir: CGFloat = b.x > a.x ? -1 : 1
    p.move(to: CGPoint(x: b.x + dir * head, y: b.y + head))
    p.line(to: b)
    p.line(to: CGPoint(x: b.x + dir * head, y: b.y - head))
    return p
}
let midX = fx + fw / 2
let top = arrow(from: CGPoint(x: midX - 150, y: 522), to: CGPoint(x: midX + 150, y: 522), head: 66)
let bottom = arrow(from: CGPoint(x: midX + 150, y: 374), to: CGPoint(x: midX - 150, y: 374), head: 66)
for (path, c1, c2) in [(top, rgb(40, 150, 255), rgb(18, 100, 232)), (bottom, rgb(22, 110, 235), rgb(12, 80, 210))] {
    shadowed(6, -4, 0.18) {
        c2.setStroke()
        path.stroke()
    }
    c1.setStroke()
    path.stroke()
}

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
