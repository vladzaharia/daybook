import Foundation
import ImageIO

/// What an image file says about itself: when it was taken and its size. Read with ImageIO, which
/// never decodes the pixels for this.
public struct PhotoMetadata: Equatable, Sendable {
    /// The capture moment from EXIF (`DateTimeOriginal`, else `DateTimeDigitized`, else TIFF `DateTime`),
    /// with the file's own UTC offset when it has one, else read in `timeZone`.
    public var capturedAt: Date?
    public var pixelWidth: Int?
    public var pixelHeight: Int?

    public init(capturedAt: Date? = nil, pixelWidth: Int? = nil, pixelHeight: Int? = nil) {
        self.capturedAt = capturedAt; self.pixelWidth = pixelWidth; self.pixelHeight = pixelHeight
    }

    public static func read(_ url: URL, timeZone: TimeZone = .current) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
        else { return PhotoMetadata() }
        return read(properties: properties, timeZone: timeZone)
    }

    public static func read(_ data: Data, timeZone: TimeZone = .current) -> PhotoMetadata {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any]
        else { return PhotoMetadata() }
        return read(properties: properties, timeZone: timeZone)
    }

    static func read(properties: [CFString: Any], timeZone: TimeZone) -> PhotoMetadata {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let candidates: [(CFString, CFString?, CFString?, [CFString: Any])] = [
            (kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifSubsecTimeOriginal, exif),
            (kCGImagePropertyExifDateTimeDigitized, kCGImagePropertyExifOffsetTimeDigitized, kCGImagePropertyExifSubsecTimeDigitized, exif),
            (kCGImagePropertyTIFFDateTime, kCGImagePropertyExifOffsetTime, nil, tiff)
        ]
        var date: Date?
        for (key, offsetKey, subsecondKey, dictionary) in candidates {
            guard let text = dictionary[key] as? String else { continue }
            let offset = offsetKey.flatMap { (exif[$0] as? String) }
            let subseconds = subsecondKey.flatMap { (exif[$0] as? String) }
            if let parsed = exifDate(text, offset: offset, subseconds: subseconds, timeZone: timeZone) { date = parsed; break }
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        let rotated = (5...8).contains(properties[kCGImagePropertyOrientation] as? Int ?? 1)
        return PhotoMetadata(capturedAt: date, pixelWidth: rotated ? height : width,
                             pixelHeight: rotated ? width : height)
    }

    /// "2026:10:24 14:03:12" with an optional "+02:00" offset and "045" fraction of a second.
    public static func exifDate(_ text: String, offset: String? = nil, subseconds: String? = nil, timeZone: TimeZone = .current) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = offset.flatMap(Self.timeZone(offset:)) ?? timeZone
        guard var date = formatter.date(from: text.trimmingCharacters(in: .whitespaces)) else { return nil }
        if let subseconds, !subseconds.isEmpty, subseconds.allSatisfy(\.isNumber), let value = Double("0." + subseconds) {
            date = date.addingTimeInterval(value)
        }
        return date
    }

    /// "+02:00", "-0530", "Z".
    static func timeZone(offset: String) -> TimeZone? {
        let text = offset.trimmingCharacters(in: .whitespaces)
        if text == "Z" { return TimeZone(secondsFromGMT: 0) }
        guard let sign = text.first, sign == "+" || sign == "-" else { return nil }
        let digits = text.dropFirst().filter(\.isNumber)
        guard digits.count == 4, let hours = Int(digits.prefix(2)), hours < 24,
              let minutes = Int(digits.suffix(2)), minutes < 60 else { return nil }
        return TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
    }
}
