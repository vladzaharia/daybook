import DaybookCore
import Foundation

/// A conversation as Markdown, for Export and the share sheet.
public enum MeetingExport {
    /// `photoLinks` maps photos to the relative links written beside the Markdown (`write(_:to:photoFile:)`);
    /// a photo without one is described by its caption only.
    public static func markdown(_ meeting: Meeting, photoLinks: [UUID: String] = [:]) -> String {
        var lines = ["# \(meeting.title)", "", "\(meeting.date.formatted()) · \(meeting.displayKind.title)", ""]
        func image(_ photo: MeetingPhoto) -> [String] {
            guard let link = photoLinks[photo.id] else { return [] }
            return ["![\(altText(photo))](\(link))"]
        }
        if let summary = meeting.summary {
            lines += [summary.overview, ""]
            for section in summary.sections {
                lines += ["## \(section.heading)", "", section.body, ""]
                let pictures = meeting.photos(in: section).flatMap(image)
                if !pictures.isEmpty { lines += pictures + [""] }
            }
            if !summary.actionItems.isEmpty {
                lines += ["## Actions", ""]
                lines += summary.actionItems.map { "- [\($0.completed ? "x" : " ")] \($0.owner.map { $0 + ": " } ?? "")\($0.text)" }
            }
        }
        if !meeting.notes.isEmpty { lines += ["", "## My notes", "", meeting.notes] }
        lines += ["", "## Transcript", ""]
        lines += MeetingTimelineItem.items(in: meeting).map { item in
            switch item {
            case .speech(let segment):
                let name = meeting.speakers.first { $0.id == segment.speakerID }?.name ?? "Speaker"
                return "[\(TimeLabel.format(segment.start))] **\(name):** \(segment.text)"
            case .note(let note): return "[\(TimeLabel.format(note.time ?? 0))] **Your note:** \(note.text)"
            case .highlight(let highlight, let time): return "[\(TimeLabel.format(time))] **Bookmark:** \(highlight.text)"
            case .photo(let photo, let time):
                return "[\(TimeLabel.format(time))] **Photo:** \(photo.displayCaption ?? photo.fileName)"
            }
        }
        let photos = meeting.visiblePhotos
        if !photos.isEmpty {
            lines += ["", "## Photos", ""]
            for photo in photos {
                let when = meeting.timelineTime(of: photo).map { "[\(TimeLabel.format($0))] " } ?? ""
                lines += ["\(when)\(photo.displayCaption ?? photo.fileName) · \(photo.capturedAt.formatted(date: .abbreviated, time: .standard))"]
                lines += image(photo) + [""]
            }
        }
        if let highlights = MeetingEvidence.highlights(meeting) { lines += ["", "## Bookmarks and what was said", "", highlights] }
        for report in meeting.alignmentReports where report.method == .unaligned {
            let track = meeting.tracks.first { $0.id == report.trackID }
            lines += ["", "## Unaligned source: \(track?.fileName ?? report.trackID.uuidString)", "", report.explanation, ""]
            lines += meeting.transcripts.filter { $0.trackID == report.trackID }.max { $0.createdAt < $1.createdAt }?.segments.map { "[\(TimeLabel.format($0.start))] \($0.text)" } ?? []
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Title, byline, overview, next steps, and sections, for Copy Summary.
    public static func summaryMarkdown(_ meeting: Meeting) -> String {
        var lines = ["# \(meeting.title)", "", meeting.date.formatted(date: .long, time: .shortened)]
        guard let summary = meeting.summary else { return lines.joined(separator: "\n") + "\n" }
        lines += ["", summary.overview]
        if !summary.actionItems.isEmpty {
            lines += ["", "## Next steps", ""]
            lines += summary.actionItems.map { "- [\($0.completed ? "x" : " ")] \($0.text)\($0.owner.map { " (\($0))" } ?? "")" }
        }
        for section in summary.sections { lines += ["", "## \(section.heading)", "", section.body] }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes `<name>.md` into `folder` and, when the conversation has photos, copies their originals
    /// into `<name> Photos/` beside it, linked from the Markdown by relative path. `photoFile` gives each
    /// photo's original (nil skips one that isn't on this device). Returns the Markdown file and the
    /// photos folder, if any.
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
            for (index, photo) in photos.enumerated() {
                guard let source = photoFile(photo), fm.fileExists(atPath: source.path) else { continue }
                let ext = (photo.relativePath as NSString).pathExtension
                let file = String(format: "Photo %02d", index + 1) + (ext.isEmpty ? "" : ".\(ext)")
                try fm.copyItem(at: source, to: destination.appendingPathComponent(file))
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
        (photo.displayCaption ?? "Photo").replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
            .replacingOccurrences(of: "\n", with: " ")
    }
}
