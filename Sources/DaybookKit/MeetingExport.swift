import DaybookCore
import DaybookDevices
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A conversation as Markdown, for Export and the share sheet.
///
/// What models wrote (the title, the summary, photo captions, the transcript) is escaped
/// (`ModelText.escapingMarkdown`): a prompt-injected summary can't add a link, or an image that a
/// Markdown viewer fetches with the summary in its URL. The person's own notes and bookmarks are
/// written as they typed them.
public enum MeetingExport {
    /// `photoLinks` maps photos to the relative links written beside the Markdown (`write(_:to:photoFile:)`);
    /// a photo without one is described by its caption only.
    public static func markdown(_ meeting: Meeting, photoLinks: [UUID: String] = [:]) -> String {
        let safe = ModelText.escapingMarkdown
        let photoNames = photoNames(meeting)
        var lines = ["# \(safe(meeting.title))", "", "\(meeting.date.formatted()) · \(meeting.displayKind.title)", ""]
        func image(_ photo: MeetingPhoto) -> [String] {
            guard let link = photoLinks[photo.id] else { return [] }
            return ["![\(altText(photo))](\(link))"]
        }
        // The caption, else "Photo 01": never the name the file arrived with ("IMG_0412.HEIC").
        func describe(_ photo: MeetingPhoto) -> String { photo.displayCaption.map(safe) ?? photoNames[photo.id] ?? "Photo" }
        if let summary = meeting.summary {
            lines += [safe(summary.overview), ""]
            for section in summary.sections {
                lines += ["## \(safe(section.heading))", "", safe(section.body), ""]
                let pictures = meeting.photos(in: section).flatMap(image)
                if !pictures.isEmpty { lines += pictures + [""] }
            }
            if !summary.actionItems.isEmpty {
                lines += ["## Actions", ""]
                lines += summary.actionItems.map { "- [\($0.completed ? "x" : " ")] \($0.owner.map { safe($0) + ": " } ?? "")\(safe($0.text))" }
            }
        }
        if !meeting.notes.isEmpty { lines += ["", "## My notes", "", meeting.notes] }
        lines += ["", "## Transcript", ""]
        lines += MeetingTimelineItem.items(in: meeting).map { item in
            switch item {
            case .speech(let segment):
                let name = meeting.speakers.first { $0.id == segment.speakerID }?.name ?? "Speaker"
                return "[\(TimeLabel.format(segment.start))] **\(safe(name)):** \(safe(segment.text))"
            case .note(let note): return "[\(TimeLabel.format(note.time ?? 0))] **Your note:** \(note.text)"
            case .highlight(let highlight, let time): return "[\(TimeLabel.format(time))] **Bookmark:** \(highlight.text)"
            case .photo(let photo, let time):
                return "[\(TimeLabel.format(time))] **Photo:** \(describe(photo))"
            }
        }
        let photos = meeting.visiblePhotos
        if !photos.isEmpty {
            lines += ["", "## Photos", ""]
            for photo in photos {
                let when = meeting.timelineTime(of: photo).map { "[\(TimeLabel.format($0))] " } ?? ""
                lines += ["\(when)\(describe(photo)) · \(photo.capturedAt.formatted(date: .abbreviated, time: .standard))"]
                lines += image(photo) + [""]
            }
        }
        if let highlights = MeetingEvidence.highlights(meeting) { lines += ["", "## Bookmarks and what was said", "", safe(highlights)] }
        for report in meeting.alignmentReports where report.method == .unaligned {
            let name = meeting.tracks.first { $0.id == report.trackID }.map { sourceName(of: $0, in: meeting) } ?? "Recording"
            lines += ["", "## Unaligned source: \(safe(name))", "", report.explanation, ""]
            lines += meeting.transcripts.filter { $0.trackID == report.trackID }.max { $0.createdAt < $1.createdAt }?.segments.map { "[\(TimeLabel.format($0.start))] \(safe($0.text))" } ?? []
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Title, byline, overview, next steps, and sections, for Copy Summary.
    public static func summaryMarkdown(_ meeting: Meeting) -> String {
        let safe = ModelText.escapingMarkdown
        var lines = ["# \(safe(meeting.title))", "", meeting.date.formatted(date: .long, time: .shortened)]
        guard let summary = meeting.summary else { return lines.joined(separator: "\n") + "\n" }
        lines += ["", safe(summary.overview)]
        if !summary.actionItems.isEmpty {
            lines += ["", "## Next steps", ""]
            lines += summary.actionItems.map { "- [\($0.completed ? "x" : " ")] \(safe($0.text))\($0.owner.map { " (\(safe($0)))" } ?? "")" }
        }
        for section in summary.sections { lines += ["", "## \(safe(section.heading))", "", safe(section.body)] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// What an export calls a recording: where it came from ("Soundcore Work", "iPhone",
    /// "Microphone", "Imported recording"), how Daybook derived it ("Microphone, echo removed"), and
    /// a number when two would read the same. Never the name its file arrived with, which can say
    /// more than the person meant to share.
    public static func sourceName(of track: RecordingTrack, in meeting: Meeting) -> String {
        let name = plainSourceName(track)
        let alike = meeting.tracks.filter { plainSourceName($0) == name }
        guard alike.count > 1, let index = alike.firstIndex(where: { $0.id == track.id }) else { return name }
        return "\(name) \(index + 1)"
    }

    private static func plainSourceName(_ track: RecordingTrack) -> String {
        var name = track.deviceKind == DaybookPhoneIntegration.id ? "iPhone" : track.source.title
        if track.derivedFrom != nil {
            name += track.processing == RecordingTrack.echoCancelledProcessing ? ", echo removed" : ", processed"
        }
        return name
    }

    /// "Photo 01", "Photo 02", … in the order of `visiblePhotos`, for the exported files and for a
    /// photo without a caption.
    public static func photoNames(_ meeting: Meeting) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: meeting.visiblePhotos.enumerated().map { ($1.id, String(format: "Photo %02d", $0 + 1)) })
    }

    /// Writes `<name>.md` into `folder` and, when the conversation has photos, writes them into
    /// `<name> Photos/` beside it as "Photo 01" and so on, linked from the Markdown by relative path.
    /// Each is re-encoded with only its orientation and capture time (`ExportPhoto`), so it carries no
    /// location or camera details; the library's original stays byte for byte. `photoFile` gives each
    /// photo's original (nil skips one that isn't on this device, as does one that can't be read).
    /// Returns the Markdown file and the photos folder, if any.
    @discardableResult
    public static func write(_ meeting: Meeting, to folder: URL, name: String,
                             photoFile: (MeetingPhoto) -> URL?) throws -> (markdown: URL, photos: URL?) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw LibraryError.unsafePath(name)
        }
        return try write(meeting, markdownURL: folder.appendingPathComponent(name + ".md"), photoFile: photoFile)
    }

    /// Uses the exact file chosen in a save panel. Existing sibling folders are never replaced.
    @discardableResult
    public static func write(_ meeting: Meeting, markdownURL url: URL,
                             photoFile: (MeetingPhoto) -> URL?) throws -> (markdown: URL, photos: URL?) {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var links: [UUID: String] = [:]
        var photosFolder: URL?
        var completed = false
        defer {
            if !completed, let photosFolder { try? fm.removeItem(at: photosFolder) }
        }
        let photos = meeting.visiblePhotos
        if !photos.isEmpty {
            var folderName = "\(name) Photos"
            if fm.fileExists(atPath: folder.appendingPathComponent(folderName).path) {
                folderName += " \(UUID().uuidString)"
            }
            let destination = folder.appendingPathComponent(folderName, isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            photosFolder = destination
            let names = photoNames(meeting)
            for photo in photos {
                guard let source = photoFile(photo), fm.fileExists(atPath: source.path), let name = names[photo.id],
                      let file = ExportPhoto.write(source, to: destination, name: name) else { continue }
                links[photo.id] = relativeLink(folderName, file)
            }
            if links.isEmpty { try fm.removeItem(at: destination); photosFolder = nil }
        }
        try markdown(meeting, photoLinks: links).write(to: url, atomically: true, encoding: .utf8)
        completed = true
        return (url, photosFolder)
    }

    /// A Markdown link path with each component percent-encoded, so spaces don't end it.
    static func relativeLink(_ components: String...) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0 }
            .joined(separator: "/")
    }

    private static func altText(_ photo: MeetingPhoto) -> String {
        ModelText.escapingMarkdown((photo.displayCaption ?? "Photo").replacingOccurrences(of: "\n", with: " "))
    }
}

/// A photo as it leaves Daybook in an export: the same picture, re-encoded with only its orientation
/// and when it was taken. GPS, maker notes (`{MakerApple}` and the like), the camera and lens, editing
/// software, and everything else in its metadata stay behind.
public enum ExportPhoto {
    /// Writes `source` as `<name>.<ext>` in `folder` and returns the file's name, or nil when it isn't
    /// an image this device can read and write (nothing is left behind then). HEIC that can't be
    /// encoded here becomes JPEG; PNG stays PNG.
    public static func write(_ source: URL, to folder: URL, name: String) -> String? {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(image) as String?,
              let picture = CGImageSourceCreateImageAtIndex(image, 0, nil) else { return nil }
        var properties = kept(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any] ?? [:])
        properties[kCGImageDestinationLossyCompressionQuality] = 0.92
        for output in outputTypes(for: type) {
            let ext = output == UTType.jpeg.identifier ? "jpg" : UTType(output)?.preferredFilenameExtension ?? "png"
            let file = folder.appendingPathComponent("\(name).\(ext)")
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, output as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
            if CGImageDestinationFinalize(destination) { return file.lastPathComponent }
            try? FileManager.default.removeItem(at: file)
        }
        return nil
    }

    static func outputTypes(for type: String) -> [String] {
        switch type {
        case UTType.heic.identifier, UTType.heif.identifier: return [UTType.heic.identifier, UTType.jpeg.identifier]
        case UTType.jpeg.identifier: return [UTType.jpeg.identifier]
        default: return [UTType.png.identifier]
        }
    }

    /// Orientation, and the capture time with its offset and fraction of a second: nothing else.
    static func kept(_ properties: [CFString: Any]) -> [CFString: Any] {
        var kept: [CFString: Any] = [:]
        if let orientation = properties[kCGImagePropertyOrientation] { kept[kCGImagePropertyOrientation] = orientation }
        let exifKeys: Set<CFString> = [kCGImagePropertyExifDateTimeOriginal, kCGImagePropertyExifDateTimeDigitized,
                                       kCGImagePropertyExifOffsetTimeOriginal, kCGImagePropertyExifOffsetTimeDigitized,
                                       kCGImagePropertyExifOffsetTime, kCGImagePropertyExifSubsecTimeOriginal,
                                       kCGImagePropertyExifSubsecTimeDigitized]
        let exif = (properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]).filter { exifKeys.contains($0.key) }
        if !exif.isEmpty { kept[kCGImagePropertyExifDictionary] = exif }
        let tiffKeys: Set<CFString> = [kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFDateTime]
        let tiff = (properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]).filter { tiffKeys.contains($0.key) }
        if !tiff.isEmpty { kept[kCGImagePropertyTIFFDictionary] = tiff }
        return kept
    }
}
