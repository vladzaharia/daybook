import AppKit
import Foundation

// The layers of Daybook's app icon, Resources/Daybook.icon, the Icon Composer document the Mac and iPhone apps both
// use. The same drawing as `DaybookMark` (Sources/DaybookDesign/Marks.swift): five waveform bars in the brand gradient
// with a cyan glow, and an amber bookmark dot, on a deep teal tile. The tile is the document's background fill
// (icon.json), so the system masks the shape, adds its own edges and shadow, and draws the Default, Dark, Clear, and
// Tinted appearances. Each layer is drawn full-bleed on the 1024 pt canvas, in DaybookMark's proportions of its tile:
//   glow.png   the bars' two cyan halos, under them
//   bars.png   the bars, in the brand gradient from corner to corner
//   dot.png    the amber dot
// Change the drawing here and in DaybookMark together, then run it again and check the result in Icon Composer
// (or `ictool Resources/Daybook.icon --export-image …`).
//
// Usage: swift scripts/make-icon.swift [<directory>]    (default: Resources/Daybook.icon/Assets)
func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let script = URL(fileURLWithPath: #filePath)
let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : script.deletingLastPathComponent().appendingPathComponent("../Resources/Daybook.icon/Assets", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// DaybookMark's geometry for a tile of side `side`: bars 7% wide with 5.5% between them, heights from the waveform,
// and a 7% dot inset 17% from the top-trailing corner.
let side: CGFloat = 1024
let canvas = NSRect(x: 0, y: 0, width: side, height: side)
let barWidth = side * 0.07, gap = side * 0.055
let heights: [CGFloat] = [100, 178, 248, 158, 82].map { side * $0 / 512 * 0.92 }
let barsWidth = barWidth * 5 + gap * 4
let barsRect = NSRect(x: canvas.midX - barsWidth / 2, y: canvas.midY - heights.max()! / 2, width: barsWidth, height: heights.max()!)
let bars = NSBezierPath()
for (index, height) in heights.enumerated() {
    let x = barsRect.minX + CGFloat(index) * (barWidth + gap)
    bars.append(NSBezierPath(roundedRect: NSRect(x: x, y: canvas.midY - height / 2, width: barWidth, height: height),
                             xRadius: barWidth / 2, yRadius: barWidth / 2))
}
let dotSize = side * 0.07, inset = side * 0.17
let dot = NSRect(x: canvas.maxX - inset - dotSize, y: canvas.maxY - inset - dotSize, width: dotSize, height: dotSize)
// DaybookMark's glow radius (`daybookGlow(neonCyan, radius: size / 12)`): a halo at that blur, and a fainter one at 2.5×.
let glowRadius = side / 12

func glow() {
    for (alpha, blur) in [(0.35, glowRadius * 2.5), (0.75, glowRadius)] {
        NSGraphicsContext.saveGraphicsState()
        let halo = NSShadow()
        halo.shadowColor = rgb(0x33E1FF, alpha)
        halo.shadowBlurRadius = blur
        halo.set()
        rgb(0x33E1FF).setFill()
        bars.fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    // Only the halos: the bars' own shape belongs to bars.png.
    NSGraphicsContext.current?.compositingOperation = .clear
    bars.fill()
}

func gradientBars() {
    bars.addClip()
    NSGradient(colors: [rgb(0x3DFFD0), rgb(0x33E1FF), rgb(0xB388FF)])!.draw(in: barsRect, angle: -45)
}

func amberDot() {
    rgb(0xFFD23F).setFill()
    NSBezierPath(ovalIn: dot).fill()
}

func write(_ name: String, _ draw: () -> Void) throws {
    let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

try write("glow.png", glow)
try write("bars.png", gradientBars)
try write("dot.png", amberDot)
