import AppKit
import Foundation

// The iPhone app icon: the same drawing as `DaybookMark` and the Mac icon (scripts/make-icon.swift),
// five waveform bars in the brand gradient with an amber bookmark dot, drawn full-bleed at 1024 px
// because iOS applies its own mask. Writes an AppIcon.appiconset with the three appearances iOS uses:
//   icon.png         any: opaque, the deep teal tile (the App Store requires no transparency)
//   icon-dark.png    dark: the mark on transparency; the system supplies the dark backdrop
//   icon-tinted.png  tinted: a white mark on transparency; the system tints it
// Usage: swift scripts/make-ios-icon.swift <path to AppIcon.appiconset>
func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let side: CGFloat = 1024
let canvas = NSRect(x: 0, y: 0, width: side, height: side)
// The mark's proportions match the Mac icon's 412 pt tile, scaled to the full canvas.
let scale = side / 412
let barWidth = 28.84 * scale, gap = 22.66 * scale
let heights: [CGFloat] = [100, 178, 248, 158, 82].map { 412 * $0 / 512 * 0.92 * scale }
let barsWidth = barWidth * 5 + gap * 4
let barsRect = NSRect(x: canvas.midX - barsWidth / 2, y: canvas.midY - heights.max()! / 2, width: barsWidth, height: heights.max()!)
let bars = NSBezierPath()
for (index, height) in heights.enumerated() {
    let x = barsRect.minX + CGFloat(index) * (barWidth + gap)
    bars.append(NSBezierPath(roundedRect: NSRect(x: x, y: canvas.midY - height / 2, width: barWidth, height: height),
                             xRadius: barWidth / 2, yRadius: barWidth / 2))
}
let dotSize = 28.84 * scale, inset = 70 * scale
let dot = NSRect(x: canvas.maxX - inset - dotSize, y: canvas.maxY - inset - dotSize, width: dotSize, height: dotSize)

enum Appearance { case any, dark, tinted }

func draw(_ appearance: Appearance) {
    if appearance == .any {
        NSGradient(starting: rgb(0x14322E), ending: rgb(0x0A1716))!.draw(in: canvas, angle: -90)
    }
    if appearance != .tinted {
        // The neon glow: two cyan halos under the bars, then the gradient on top.
        for (alpha, blur) in [(0.35, side / 12 * 2.5 * 0.6), (0.75, side / 12 * 0.6)] {
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = rgb(0x33E1FF, alpha)
            glow.shadowBlurRadius = blur
            glow.set()
            rgb(0x33E1FF).setFill()
            bars.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGraphicsContext.saveGraphicsState()
        bars.addClip()
        NSGradient(colors: [rgb(0x3DFFD0), rgb(0x33E1FF), rgb(0xB388FF)])!.draw(in: barsRect, angle: -45)
        NSGraphicsContext.restoreGraphicsState()
        rgb(0xFFD23F).setFill()
        NSBezierPath(ovalIn: dot).fill()
    } else {
        // Tinted: one luminance, so the system's tint reads cleanly; the dot slightly dimmer.
        NSColor.white.setFill()
        bars.fill()
        NSColor(white: 1, alpha: 0.75).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }
}

func write(_ appearance: Appearance, to name: String) throws {
    // The App Store rejects an icon with an alpha channel, so `any` renders into an RGB context
    // with no alpha (`noneSkipLast`); the others keep alpha for their transparent backgrounds.
    let alpha: CGImageAlphaInfo = appearance == .any ? .noneSkipLast : .premultipliedLast
    let context = CGContext(data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    draw(appearance)
    NSGraphicsContext.restoreGraphicsState()
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    try image.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
}

try write(.any, to: "icon.png")
try write(.dark, to: "icon-dark.png")
try write(.tinted, to: "icon-tinted.png")

let contents = """
{
  "images" : [
    { "filename" : "icon.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "icon-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "icon-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
