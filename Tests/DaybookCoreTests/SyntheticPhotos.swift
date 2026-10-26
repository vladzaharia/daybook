import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images drawn in the test, never read from a camera or the photo library: a gradient with a few
/// shapes, so different seeds give different bytes.
enum SyntheticPhotos {
    static func image(width: Int = 320, height: Int = 240, seed: Int = 0) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let hue = CGFloat(seed % 7) / 7
        context.setFillColor(CGColor(red: hue, green: 0.6, blue: 1 - hue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        for index in 0..<(3 + seed % 4) {
            context.fill(CGRect(x: 20 + index * 40, y: 30 + (seed * 13 + index * 29) % (height - 60), width: 28, height: 18))
        }
        return context.makeImage()!
    }

    /// Encoded bytes in `type` (`UTType.png`, `.jpeg`, `.heic`), with an EXIF capture date when given.
    static func data(_ type: UTType = .png, seed: Int = 0, exifDate: String? = nil, offset: String? = nil) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        var properties: [CFString: Any] = [:]
        if let exifDate {
            var exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: exifDate]
            if let offset { exif[kCGImagePropertyExifOffsetTimeOriginal] = offset }
            properties[kCGImagePropertyExifDictionary] = exif
        }
        CGImageDestinationAddImage(destination, image(seed: seed), properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func write(_ data: Data, named name: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }
}
