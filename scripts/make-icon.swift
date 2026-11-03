// Draws the MXCtl app icon and writes AppIcon.appiconset: a light mouse with a glowing wheel and
// a white "MX" keycap in front of it, on a dark graphite square (the MX Keys / MX Master look).
// Usage: swift scripts/make-icon.swift MXCtl/Assets.xcassets/AppIcon.appiconset [preview.png]
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let accent = NSColor(calibratedRed: 0.20, green: 0.78, blue: 0.95, alpha: 1)

func withShadow(_ s: CGFloat, alpha: CGFloat = 0.45, offset: CGFloat = 22, blur: CGFloat = 44, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: alpha)
    shadow.shadowOffset = NSSize(width: 0, height: -offset * s)
    shadow.shadowBlurRadius = blur * s
    shadow.set()
    draw()
    NSGraphicsContext.restoreGraphicsState()
}

func drawMouse(_ s: CGFloat) {
    // Body: a tall rounded shape, slightly wider at the bottom like the MX Master.
    let body = NSBezierPath()
    let left: CGFloat = 250, right: CGFloat = 610, bottom: CGFloat = 250, top: CGFloat = 830
    body.move(to: NSPoint(x: (left + right) / 2 * s, y: top * s))
    body.curve(to: NSPoint(x: right * s, y: 560 * s),
               controlPoint1: NSPoint(x: (right - 10) * s, y: top * s),
               controlPoint2: NSPoint(x: right * s, y: 700 * s))
    body.curve(to: NSPoint(x: (left + right) / 2 * s, y: bottom * s),
               controlPoint1: NSPoint(x: right * s, y: 360 * s),
               controlPoint2: NSPoint(x: (right - 60) * s, y: bottom * s))
    body.curve(to: NSPoint(x: left * s, y: 560 * s),
               controlPoint1: NSPoint(x: (left + 60) * s, y: bottom * s),
               controlPoint2: NSPoint(x: left * s, y: 360 * s))
    body.curve(to: NSPoint(x: (left + right) / 2 * s, y: top * s),
               controlPoint1: NSPoint(x: left * s, y: 700 * s),
               controlPoint2: NSPoint(x: (left + 10) * s, y: top * s))
    body.close()

    withShadow(s) {
        NSColor(calibratedWhite: 0.75, alpha: 1).setFill()
        body.fill()
    }
    NSGradient(starting: NSColor(calibratedWhite: 0.97, alpha: 1), ending: NSColor(calibratedWhite: 0.72, alpha: 1))!
        .draw(in: body, angle: -90)

    // The split between the two buttons, down to the wheel and below it.
    let mid = (left + right) / 2 * s
    let split = NSBezierPath()
    split.move(to: NSPoint(x: mid, y: top * s))
    split.line(to: NSPoint(x: mid, y: 560 * s))
    split.lineWidth = 9 * s
    NSColor(calibratedWhite: 0.45, alpha: 0.8).setStroke()
    split.stroke()

    // The wheel, glowing.
    let wheel = NSBezierPath(roundedRect: NSRect(x: mid - 30 * s, y: 600 * s, width: 60 * s, height: 150 * s),
                             xRadius: 30 * s, yRadius: 30 * s)
    NSGraphicsContext.saveGraphicsState()
    let glow = NSShadow()
    glow.shadowColor = accent.withAlphaComponent(0.9)
    glow.shadowOffset = .zero
    glow.shadowBlurRadius = 34 * s
    glow.set()
    NSColor(calibratedWhite: 0.18, alpha: 1).setFill()
    wheel.fill()
    NSGraphicsContext.restoreGraphicsState()
    for i in 0..<5 {
        let y = (618 + CGFloat(i) * 26) * s
        let rib = NSBezierPath(roundedRect: NSRect(x: mid - 20 * s, y: y, width: 40 * s, height: 9 * s), xRadius: 4 * s, yRadius: 4 * s)
        accent.withAlphaComponent(0.55 + 0.1 * CGFloat(i % 2)).setFill()
        rib.fill()
    }
}

func drawKeycap(_ rect: NSRect, s: CGFloat) {
    withShadow(s, alpha: 0.5, offset: 20, blur: 40) {
        NSColor(calibratedRed: 0.70, green: 0.73, blue: 0.80, alpha: 1).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 64 * s, yRadius: 64 * s).fill()
    }
    let topRect = NSRect(x: rect.minX + 24 * s, y: rect.minY + 40 * s, width: rect.width - 48 * s, height: rect.height - 60 * s)
    NSGradient(starting: .white, ending: NSColor(calibratedRed: 0.90, green: 0.92, blue: 0.96, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: topRect, xRadius: 48 * s, yRadius: 48 * s), angle: -90)

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 132 * s, weight: .heavy),
        .foregroundColor: NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.19, alpha: 1),
        .kern: -4 * s,
    ]
    let text = NSAttributedString(string: "MX", attributes: attributes)
    let size = text.size()
    text.draw(at: NSPoint(x: topRect.midX - size.width / 2, y: topRect.midY - size.height / 2 + 4 * s))
    // A small accent line under the letters, like a backlit key.
    let line = NSBezierPath(roundedRect: NSRect(x: topRect.midX - 46 * s, y: topRect.minY + 30 * s, width: 92 * s, height: 10 * s),
                            xRadius: 5 * s, yRadius: 5 * s)
    accent.setFill()
    line.fill()
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024

    // Background: macOS-style rounded square, graphite, inset like system icons.
    let inset = 100 * s
    let bgRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let bg = NSBezierPath(roundedRect: bgRect, xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedRed: 0.27, green: 0.29, blue: 0.34, alpha: 1),
               ending: NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.14, alpha: 1))!
        .draw(in: bg, angle: -90)
    // A faint accent glow behind the mouse.
    NSGraphicsContext.saveGraphicsState()
    bg.addClip()
    NSGradient(starting: accent.withAlphaComponent(0.28), ending: accent.withAlphaComponent(0))!
        .draw(fromCenter: NSPoint(x: 430 * s, y: 600 * s), radius: 0,
              toCenter: NSPoint(x: 430 * s, y: 600 * s), radius: 420 * s, options: [])
    NSGraphicsContext.restoreGraphicsState()

    drawMouse(s)
    drawKeycap(NSRect(x: 560 * s, y: 170 * s, width: 300 * s, height: 280 * s), s: s)

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        let data = drawIcon(size: CGFloat(pixels)).representation(using: .png, properties: [:])!
        try data.write(to: outDir.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
if CommandLine.arguments.count > 2 {
    try drawIcon(size: 1024).representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
print("Wrote \(images.count) icons to \(outDir.path)")
