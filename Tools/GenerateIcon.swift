import AppKit

// Original vector artwork. Coordinates use a 1024-point design canvas.
// Run: swift Tools/GenerateIcon.swift output.iconset preview.png
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
}
func drawIcon() {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    let tile = rounded(NSRect(x: 72, y: 72, width: 880, height: 880), 196)
    color(11, 112, 125).setFill(); tile.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(38, 193, 182), ending: color(12, 104, 140))!.draw(in: tile, angle: -55)

    // Paper rises from the rear of a compact photo printer.
    NSGraphicsContext.saveGraphicsState()
    let paperShadow = NSShadow()
    paperShadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    paperShadow.shadowBlurRadius = 18
    paperShadow.shadowOffset = NSSize(width: 0, height: -8)
    paperShadow.set()
    let paper = rounded(NSRect(x: 294, y: 500, width: 436, height: 316), 24)
    color(247, 255, 254).setFill(); paper.fill()
    NSGraphicsContext.restoreGraphicsState()
    color(189, 224, 225).setFill()
    rounded(NSRect(x: 344, y: 734, width: 190, height: 14), 7).fill()
    rounded(NSRect(x: 344, y: 698, width: 302, height: 14), 7).fill()

    NSGraphicsContext.saveGraphicsState()
    let bodyShadow = NSShadow()
    bodyShadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    bodyShadow.shadowBlurRadius = 28
    bodyShadow.shadowOffset = NSSize(width: 0, height: -16)
    bodyShadow.set()
    let body = rounded(NSRect(x: 202, y: 272, width: 620, height: 326), 64)
    color(235, 248, 248).setFill(); body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(255, 255, 255), ending: color(208, 234, 235))!.draw(in: body, angle: -90)
    color(24, 72, 91).setFill()
    rounded(NSRect(x: 264, y: 342, width: 496, height: 88), 22).fill()

    // Output sheet and a subtle photo-color signature.
    NSGraphicsContext.saveGraphicsState()
    let outputShadow = NSShadow()
    outputShadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
    outputShadow.shadowBlurRadius = 12
    outputShadow.shadowOffset = NSSize(width: 0, height: -7)
    outputShadow.set()
    let output = rounded(NSRect(x: 314, y: 210, width: 396, height: 178), 20)
    NSColor.white.setFill(); output.fill()
    NSGraphicsContext.restoreGraphicsState()
    let inks = [color(42, 190, 211), color(131, 220, 232), color(226, 86, 156), color(244, 164, 197), color(246, 202, 59), color(43, 69, 84)]
    for (index, ink) in inks.enumerated() {
        ink.setFill()
        rounded(NSRect(x: 351 + index * 55, y: 265, width: 47, height: 30), 9).fill()
    }

    // Wi-Fi waves are part of the printer's front panel, rather than a badge.
    let center = NSPoint(x: 700, y: 492)
    color(13, 137, 140).setStroke()
    for radius: CGFloat in [33, 58] {
        let wave = NSBezierPath()
        wave.appendArc(withCenter: center, radius: radius, startAngle: 44, endAngle: 136)
        wave.lineWidth = 12
        wave.lineCapStyle = .round
        wave.stroke()
    }
    color(13, 137, 140).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 7, y: center.y - 3, width: 14, height: 14)).fill()
}

func png(size: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 3 else { fatalError("Usage: GenerateIcon.swift output.iconset preview.png") }
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let suffix = scale == 2 ? "@2x" : ""
        try png(size: base * scale).write(to: directory.appendingPathComponent("icon_\(base)x\(base)\(suffix).png"))
    }
}
try png(size: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
