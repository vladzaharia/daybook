import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = AffineTransform(scale: CGFloat(pixels) / 512)
        (transform as NSAffineTransform).concat()
        NSColor(calibratedRed: 0.17, green: 0.34, blue: 0.30, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 32, y: 32, width: 448, height: 448), xRadius: 104, yRadius: 104).fill()
        NSColor(calibratedRed: 0.94, green: 0.92, blue: 0.85, alpha: 1).setFill()
        for (index, height) in [100.0, 178, 248, 158, 82].enumerated() {
            let x = 126.0 + Double(index) * 54
            NSBezierPath(roundedRect: NSRect(x: x, y: 256 - height / 2, width: 25, height: height), xRadius: 12.5, yRadius: 12.5).fill()
        }
        NSColor(calibratedRed: 0.82, green: 0.65, blue: 0.39, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 367, y: 356, width: 26, height: 26)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
