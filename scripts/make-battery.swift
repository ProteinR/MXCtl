// Draws the low-battery pictures for the notifications: a glassy white battery on a dark tile,
// a red cell at the bottom with a glow and a red lightning bolt. Two levels: warning (a third
// full) and critical (a thin cell, brighter bolt).
// Usage: swift scripts/make-battery.swift MXCtl/Resources
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let red = NSColor(calibratedRed: 0.96, green: 0.13, blue: 0.20, alpha: 1)
let redDark = NSColor(calibratedRed: 0.72, green: 0.04, blue: 0.10, alpha: 1)

func glow(_ color: NSColor, _ blur: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color
    shadow.shadowOffset = .zero
    shadow.shadowBlurRadius = blur
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func draw(size: CGFloat, fill: CGFloat, boltGlow: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 512

    // Tile: dark graphite with a faint red light from below.
    let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 110 * s, yRadius: 110 * s)
    NSGradient(starting: NSColor(calibratedWhite: 0.17, alpha: 1), ending: NSColor(calibratedWhite: 0.08, alpha: 1))!
        .draw(in: tile, angle: -90)
    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(starting: red.withAlphaComponent(0.35 * boltGlow), ending: red.withAlphaComponent(0))!
        .draw(fromCenter: NSPoint(x: 256 * s, y: 120 * s), radius: 0,
              toCenter: NSPoint(x: 256 * s, y: 120 * s), radius: 260 * s, options: [])
    NSGraphicsContext.restoreGraphicsState()

    // Battery body and cap.
    let body = NSRect(x: 156 * s, y: 70 * s, width: 200 * s, height: 340 * s)
    let outline = NSBezierPath(roundedRect: body, xRadius: 40 * s, yRadius: 40 * s)
    outline.lineWidth = 16 * s
    glow(NSColor(calibratedWhite: 1, alpha: 0.25), 18 * s) {
        NSColor(calibratedWhite: 0.97, alpha: 1).setStroke()
        outline.stroke()
    }
    let cap = NSBezierPath(roundedRect: NSRect(x: 216 * s, y: 410 * s, width: 80 * s, height: 30 * s), xRadius: 12 * s, yRadius: 12 * s)
    NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
    cap.fill()

    // The red cell, a glowing gradient.
    let inner = body.insetBy(dx: 26 * s, dy: 26 * s)
    let cell = NSRect(x: inner.minX, y: inner.minY, width: inner.width, height: max(26 * s, inner.height * fill))
    let cellPath = NSBezierPath(roundedRect: cell, xRadius: 18 * s, yRadius: 18 * s)
    glow(red.withAlphaComponent(0.9), 30 * s) {
        red.setFill()
        cellPath.fill()
    }
    NSGradient(starting: red, ending: redDark)!.draw(in: cellPath, angle: -90)
    // Glass highlight on the cell.
    let shine = NSBezierPath(roundedRect: NSRect(x: cell.minX + 10 * s, y: cell.maxY - 14 * s, width: cell.width - 20 * s, height: 6 * s),
                             xRadius: 3 * s, yRadius: 3 * s)
    NSColor(calibratedWhite: 1, alpha: 0.35).setFill()
    shine.fill()

    // Glass streaks on the battery: a long one at the top right, a short one at the bottom left.
    NSColor(calibratedWhite: 1, alpha: 0.45).setFill()
    NSBezierPath(roundedRect: NSRect(x: inner.maxX - 18 * s, y: inner.maxY - 110 * s, width: 10 * s, height: 100 * s),
                 xRadius: 5 * s, yRadius: 5 * s).fill()
    NSColor(calibratedWhite: 1, alpha: 0.30).setFill()
    NSBezierPath(roundedRect: NSRect(x: inner.minX + 10 * s, y: inner.minY + 12 * s, width: 10 * s, height: max(40 * s, cell.height - 24 * s)),
                 xRadius: 5 * s, yRadius: 5 * s).fill()

    // Lightning bolt in the middle of the empty part.
    let cx = 256 * s, cy = (cell.maxY + inner.maxY) / 2 + 4 * s
    let bolt = NSBezierPath()
    let points: [(CGFloat, CGFloat)] = [(18, 92), (-46, -6), (-6, -6), (-20, -92), (46, 10), (6, 10)]
    bolt.move(to: NSPoint(x: cx + points[0].0 * s, y: cy + points[0].1 * s))
    for point in points.dropFirst() { bolt.line(to: NSPoint(x: cx + point.0 * s, y: cy + point.1 * s)) }
    bolt.close()
    glow(red.withAlphaComponent(boltGlow), 34 * s * boltGlow) {
        red.setFill()
        bolt.fill()
    }
    NSGradient(starting: NSColor(calibratedRed: 1, green: 0.35, blue: 0.38, alpha: 1), ending: red)!.draw(in: bolt, angle: -90)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for (name, fill, boltGlow) in [("battery-warning", CGFloat(0.33), CGFloat(0.6)), ("battery-critical", CGFloat(0.08), CGFloat(1.0))] {
    let data = draw(size: 512, fill: fill, boltGlow: boltGlow).representation(using: .png, properties: [:])!
    try data.write(to: outDir.appendingPathComponent("\(name).png"))
}
print("Wrote battery pictures to \(outDir.path)")
