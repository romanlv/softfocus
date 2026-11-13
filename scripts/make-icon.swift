// Draws Softfocus's app icon into an .iconset folder: swift scripts/make-icon.swift <out.iconset>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: body.width * 0.225, yRadius: body.width * 0.225)
    NSGradient(starting: NSColor(srgbRed: 0.10, green: 0.16, blue: 0.20, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.07, blue: 0.09, alpha: 1))!.draw(in: shape, angle: -90)
    let c = NSPoint(x: s / 2, y: s / 2)
    let r = body.width * 0.30
    let ring = NSBezierPath()
    ring.appendArc(withCenter: c, radius: r, startAngle: 0, endAngle: 360)
    ring.lineWidth = body.width * 0.07
    NSColor(white: 1, alpha: 0.14).setStroke()
    ring.stroke()
    let arc = NSBezierPath()
    arc.appendArc(withCenter: c, radius: r, startAngle: 90, endAngle: -150, clockwise: true)
    arc.lineWidth = body.width * 0.07
    arc.lineCapStyle = .round
    NSColor(srgbRed: 0.27, green: 0.80, blue: 0.72, alpha: 1).setStroke()
    arc.stroke()
    let dot = r * 0.28
    NSColor(srgbRed: 0.27, green: 0.80, blue: 0.72, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: c.x - dot, y: c.y - dot, width: 2 * dot, height: 2 * dot)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
