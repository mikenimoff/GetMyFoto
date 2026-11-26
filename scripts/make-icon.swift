import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
NSColor.clear.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
let background = NSBezierPath(roundedRect: NSRect(x: 60, y: 60, width: 904, height: 904), xRadius: 208, yRadius: 208)
NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.24, blue: 0.28, alpha: 1), ending: NSColor(calibratedRed: 0.035, green: 0.10, blue: 0.16, alpha: 1))!.draw(in: background, angle: -65)

// A tilted photo, with a USB cable becoming its lower edge.
NSGraphicsContext.saveGraphicsState()
let transform = NSAffineTransform()
transform.translateX(by: 512, yBy: 555)
transform.concat()
let rotation = NSAffineTransform()
rotation.rotate(byDegrees: -8)
rotation.concat()
let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -18); shadow.set()
NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: -265, y: -202, width: 530, height: 404), xRadius: 54, yRadius: 54).fill()
NSShadow().set()
let inner = NSBezierPath(roundedRect: NSRect(x: -226, y: -151, width: 452, height: 312), xRadius: 25, yRadius: 25)
NSGradient(starting: NSColor(calibratedRed: 0.54, green: 0.93, blue: 0.77, alpha: 1), ending: NSColor(calibratedRed: 0.18, green: 0.58, blue: 0.54, alpha: 1))!.draw(in: inner, angle: -90)
inner.addClip()
NSColor(calibratedRed: 0.07, green: 0.38, blue: 0.39, alpha: 1).setFill()
let mountains = NSBezierPath(); mountains.move(to: NSPoint(x: -270, y: -170)); mountains.line(to: NSPoint(x: -90, y: 50)); mountains.line(to: NSPoint(x: 40, y: -80)); mountains.line(to: NSPoint(x: 135, y: 10)); mountains.line(to: NSPoint(x: 280, y: -170)); mountains.close(); mountains.fill()
NSColor(calibratedRed: 0.96, green: 1, blue: 0.87, alpha: 1).setFill(); NSBezierPath(ovalIn: NSRect(x: 108, y: 65, width: 53, height: 53)).fill()
NSGraphicsContext.restoreGraphicsState()

let cable = NSBezierPath(); cable.lineWidth = 34; cable.lineCapStyle = .round
cable.move(to: NSPoint(x: 375, y: 327)); cable.curve(to: NSPoint(x: 538, y: 225), controlPoint1: NSPoint(x: 367, y: 240), controlPoint2: NSPoint(x: 403, y: 225)); cable.line(to: NSPoint(x: 644, y: 225))
NSColor(calibratedRed: 0.50, green: 0.95, blue: 0.77, alpha: 1).setStroke(); cable.stroke()
NSColor(calibratedWhite: 0.96, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 618, y: 181, width: 106, height: 88), xRadius: 20, yRadius: 20).fill()
NSColor(calibratedRed: 0.63, green: 0.73, blue: 0.76, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 715, y: 197, width: 62, height: 56), xRadius: 9, yRadius: 9).fill()
NSColor(calibratedRed: 0.13, green: 0.26, blue: 0.30, alpha: 1).setFill(); NSBezierPath(roundedRect: NSRect(x: 738, y: 209, width: 13, height: 32), xRadius: 4, yRadius: 4).fill()
image.unlockFocus()
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels)); NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
