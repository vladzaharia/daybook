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
        // Background audio (a TV, music) stays out here too, as it does the unified transcript.
        let background = meeting.alignmentReports.contains { $0.method == .unaligned } ? meeting.backgroundSegmentKinds() : [:]
        for report in meeting.alignmentReports where report.method == .unaligned {
            let name = meeting.tracks.first { $0.id == report.trackID }.map { sourceName(of: $0, in: meeting) } ?? "Recording"
            lines += ["", "## Unaligned source: \(safe(name))", "", report.explanation, ""]
            lines += meeting.transcripts.filter { $0.trackID == report.trackID }.max { $0.createdAt < $1.createdAt }?.segments
                .filter { background[$0.id] == nil }.map { "[\(TimeLabel.format($0.start))] \(safe($0.text))" } ?? []
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The most a file name made from a title may take, in UTF-8 bytes: room under the 255 a volume allows for what
    /// an export adds to it (" 2", ".md", " Photos", a recording's " (Soundcore Work).m4a").
    public static let fileNameBytes = 200

    /// A conversation's title as an export's file name, the same on both apps: no folder separators, nothing Files,
    /// Finder, or Mail refuse (`\ ? % * | " < >`, line breaks, control characters), no leading or trailing dots or
    /// spaces (a leading dot would hide the file), and at most `maxBytes` UTF-8 bytes, cut between characters and
    /// words where it can. Never empty: "Conversation".
    public static func fileName(for title: String, maxBytes: Int = fileNameBytes) -> String {
        let refused = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.newlines).union(.controlCharacters)
        let edges = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))
        var name = title.unicodeScalars.map { refused.contains($0) ? "-" : String($0) }.joined()
            .trimmingCharacters(in: edges)
        if name.utf8.count > maxBytes {
            var cut = ""
            for character in name {
                guard cut.utf8.count + character.utf8.count <= maxBytes else { break }
                cut.append(character)
            }
            // A cut mid-word steps back to the last space, unless that leaves too little.
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= cut.count / 2 {
                cut = String(cut[..<space])
            }
            name = cut.trimmingCharacters(in: edges)
        }
        return name.isEmpty ? "Conversation" : name
    }

    /// The same for a conversation.
    public static func fileName(for meeting: Meeting) -> String { fileName(for: meeting.title) }

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
    /// Nothing in `folder` is replaced: when `<name>.md` or `<name> Photos` is taken, the export is
    /// `<name> 2`, `<name> 3`, and so on (`availableName`). This is the Mac's export with photos, into a
    /// folder the person chose, which in the App Sandbox is the only place it may create the photos folder.
    /// Returns the Markdown file and the photos folder, if any.
    @discardableResult
    public static func write(_ meeting: Meeting, to folder: URL, name: String,
                             photoFile: (MeetingPhoto) -> URL?) throws -> (markdown: URL, photos: URL?) {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\") else {
            throw LibraryError.unsafePath(name)
        }
        let available = availableName(name, in: folder, withPhotos: !meeting.visiblePhotos.isEmpty)
        return try write(meeting, markdownURL: folder.appendingPathComponent(available + ".md"), photoFile: photoFile)
    }

    /// `name`, or `name 2`, `name 3`, …: the first for which neither `<name>.md` nor, with photos,
    /// `<name> Photos` exists in `folder`.
    public static func availableName(_ name: String, in folder: URL, withPhotos: Bool) -> String {
        let fm = FileManager.default
        func taken(_ candidate: String) -> Bool {
            fm.fileExists(atPath: folder.appendingPathComponent(candidate + ".md").path)
                || (withPhotos && fm.fileExists(atPath: folder.appendingPathComponent(candidate + " Photos").path))
        }
        guard taken(name) else { return name }
        var number = 2
        while taken("\(name) \(number)") { number += 1 }
        return "\(name) \(number)"
    }

    /// Uses the exact file chosen in a save panel. Existing sibling folders are never replaced.
    @discardableResult
    public static func write(_ meeting: Meeting, markdownURL url: URL,
                             photoFile: (MeetingPhoto) -> URL?) throws -> (markdown: URL, photos: URL?) {
        let fm = FileManager.default
        let folder = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        // Only a missing folder is created: in the App Sandbox the chosen folder is writable, but its parents aren't.
        if !fm.fileExists(atPath: folder.path) { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
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

    /// The conversation's full data, as the Mac's Export › Full Data (JSON)… saves it: every field, keys sorted.
    public static func json(_ meeting: Meeting) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(meeting)
    }
}

/// Files handed to the share sheet (the iPhone's, and the Mac's sharing picker): the conversation as Markdown or JSON,
/// a photo, or a recording, each named after the conversation (`MeetingExport.fileName`). They wait in
/// `<temporary folder>/Daybook Export/`, each in a folder of its own, until the share is done with them; whatever is
/// left there is cleared at the next launch, or by the next share on the Mac.
public enum ExportFiles {
    public static func root(in directory: URL = FileManager.default.temporaryDirectory) -> URL {
        directory.appendingPathComponent("Daybook Export", isDirectory: true)
    }

    /// Removes the export folders holding `urls`, or every export when nil. A URL outside the export folder (a library
    /// original) is never touched.
    public static func clear(_ urls: [URL]? = nil, in directory: URL = FileManager.default.temporaryDirectory) {
        let root = root(in: directory)
        guard let urls else { try? FileManager.default.removeItem(at: root); return }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for url in urls where url.isFileURL {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            guard path.count > rootPath.count, Array(path.prefix(rootPath.count)) == rootPath else { continue }
            try? FileManager.default.removeItem(at: root.appendingPathComponent(path[rootPath.count], isDirectory: true))
        }
    }

    /// The Markdown, or with photos one ZIP of the Markdown and its photos, so sharing keeps the relative links.
    /// `originals` gives each photo's file on this device.
    public static func markdownWithPhotos(_ meeting: Meeting, originals: [UUID: URL],
                                          in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        guard !meeting.visiblePhotos.isEmpty else { return try markdown(meeting, in: directory) }
        let name = MeetingExport.fileName(for: meeting)
        let folder = root(in: directory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = folder.appendingPathComponent(name, isDirectory: true)
        try MeetingExport.write(meeting, to: package, name: name) { originals[$0.id] }
        let archive = folder.appendingPathComponent(name + ".zip")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: package, options: .forUploading, error: &coordinationError) { uploaded in
            do { try FileManager.default.copyItem(at: uploaded, to: archive) }
            catch { copyError = error }
        }
        if let error = coordinationError ?? copyError as NSError? { throw error }
        return archive
    }

    public static func markdown(_ meeting: Meeting, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = try folder(for: meeting.id, in: directory).appendingPathComponent(MeetingExport.fileName(for: meeting) + ".md")
        try MeetingExport.markdown(meeting).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The full data, as `MeetingExport.json`.
    public static func json(_ meeting: Meeting, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = try folder(for: meeting.id, in: directory).appendingPathComponent(MeetingExport.fileName(for: meeting) + ".json")
        try MeetingExport.json(meeting).write(to: url, options: .atomic)
        return url
    }

    /// One photo, named after its caption and re-encoded with only its orientation and capture time (`ExportPhoto`):
    /// no location or camera details. The library's original stays.
    public static func photo(_ original: URL, caption: String?, in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = root(in: directory).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let file = ExportPhoto.write(original, to: folder, name: MeetingExport.fileName(for: caption.map { String($0.prefix(60)) } ?? "Photo")) else {
            try? FileManager.default.removeItem(at: folder)
            throw CocoaError(.fileReadCorruptFile)
        }
        return folder.appendingPathComponent(file)
    }

    /// What a shared recording is called: the conversation's name, so the share sheet doesn't offer
    /// "iPhone recording.m4a"; of several recordings, each says which it is ("Weekly sync (Soundcore Work).m4a", its
    /// name as Info › Audio says it).
    @MainActor
    public static func audioName(_ meeting: Meeting, track: RecordingTrack, fileExtension: String) -> String {
        let suffix = meeting.tracks.count > 1 ? " (\(MeetingExport.fileName(for: RecordingWords.name(track, in: meeting))))" : ""
        return MeetingExport.fileName(for: meeting) + suffix + "." + (fileExtension.isEmpty ? "m4a" : fileExtension)
    }

    /// A copy of the recording at `source`, called `name` (`audioName`). A copy on the same volume is a clone, but it's
    /// still file work: do it off the main actor.
    public static func audio(_ source: URL, named name: String, meetingID: UUID,
                             in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = try folder(for: meetingID, in: directory).appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.copyItem(at: source, to: url)
        return url
    }

    /// The recording named as `audioName` says.
    @MainActor
    public static func audio(_ source: URL, meeting: Meeting, track: RecordingTrack,
                             in directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        try audio(source, named: audioName(meeting, track: track, fileExtension: source.pathExtension), meetingID: meeting.id, in: directory)
    }

    /// The conversation's own folder in the exports.
    private static func folder(for id: UUID, in directory: URL) throws -> URL {
        let folder = root(in: directory).appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
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
