import AppKit
import Foundation

// The same drawing as `DaybookMark` in Sources/Daybook/UI/DaybookStyle.swift: five waveform bars in the
// brand gradient with a cyan glow, on a deep teal tile, with an amber bookmark dot. Drawn on a 512 pt
// canvas using the macOS icon grid (an 412 pt tile, inset 50 pt).
func rgb(_ hex: Int) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let tile = NSRect(x: 50, y: 50, width: 412, height: 412)
let side = tile.width
let barWidth = side * 0.07, gap = side * 0.055
let heights: [CGFloat] = [100, 178, 248, 158, 82].map { side * $0 / 512 * 0.92 }
let barsWidth = barWidth * 5 + gap * 4
let barsRect = NSRect(x: tile.midX - barsWidth / 2, y: tile.midY - heights.max()! / 2, width: barsWidth, height: heights.max()!)
let bars = NSBezierPath()
for (index, height) in heights.enumerated() {
    let x = barsRect.minX + CGFloat(index) * (barWidth + gap)
    bars.append(NSBezierPath(roundedRect: NSRect(x: x, y: tile.midY - height / 2, width: barWidth, height: height),
                             xRadius: barWidth / 2, yRadius: barWidth / 2))
}
let dotSize = side * 0.07, inset = side * 0.17
let dot = NSRect(x: tile.maxX - inset - dotSize, y: tile.maxY - inset - dotSize, width: dotSize, height: dotSize)

func draw() {
    let shape = NSBezierPath(roundedRect: tile, xRadius: side * 0.225, yRadius: side * 0.225)

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.3)
    drop.shadowBlurRadius = 10
    drop.shadowOffset = NSSize(width: 0, height: -6)
    drop.set()
    rgb(0x0A1716).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: rgb(0x14322E), ending: rgb(0x0A1716))!.draw(in: shape, angle: -90)

    // The neon glow: two cyan halos under the bars, then the gradient on top.
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    for (alpha, blur) in [(0.35, side / 12 * 2.5), (0.75, side / 12)] {
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = rgb(0x33E1FF).withAlphaComponent(alpha)
        glow.shadowBlurRadius = blur
        glow.set()
        rgb(0x33E1FF).setFill()
        bars.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    bars.addClip()
    NSGradient(colors: [rgb(0x3DFFD0), rgb(0x33E1FF), rgb(0xB388FF)])!.draw(in: barsRect, angle: -45)
    NSGraphicsContext.restoreGraphicsState()

    rgb(0xFFD23F).setFill()
    NSBezierPath(ovalIn: dot).fill()
}

for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 512)
        (transform as NSAffineTransform).concat()
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
