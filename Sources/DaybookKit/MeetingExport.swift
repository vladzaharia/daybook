import DaybookCore
import Foundation

/// A conversation as Markdown, for Export and the share sheet.
public enum MeetingExport {
    public static func markdown(_ meeting: Meeting) -> String {
        var lines = ["# \(meeting.title)", "", "\(meeting.date.formatted()) · \(meeting.displayKind.title)", ""]
        if let summary = meeting.summary {
            lines += [summary.overview, ""]
            for section in summary.sections { lines += ["## \(section.heading)", "", section.body, ""] }
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
}
