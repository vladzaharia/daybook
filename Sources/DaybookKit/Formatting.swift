import DaybookCore
import DaybookDevices
import Foundation

// Words and numbers both apps show: times on a conversation's timeline, spoken times for
// VoiceOver, date groups in the list, a row's preview line, and a conversation's people.
// `DurationLabel` ("43 min") and `Meeting.duration` live in DaybookDevices, which matches and
// formats recorder lengths with them; DaybookKit re-exports both.

/// Times on a conversation's timeline. A time before the start (a note an iPhone took before the Mac started recording)
/// has a minus sign: "−0:12". Whole seconds, toward zero, so a time less than a second before the start is "0:00".
public enum TimeLabel {
    public static func format(_ seconds: Double) -> String {
        let (value, before) = wholeSeconds(seconds)
        return (before ? "−" : "") + (value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60))
    }

    /// The interface's form, as in Voice Memos: "0:14", "12:31", "1:02:03". Model evidence and
    /// exports keep `format`.
    public static func short(_ seconds: Double) -> String {
        let (value, before) = wholeSeconds(seconds)
        return (before ? "−" : "") + (value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60))
    }

    /// The whole seconds from the start, toward zero, and whether they're before it.
    static func wholeSeconds(_ seconds: Double) -> (value: Int, before: Bool) {
        let value = Int(seconds.isFinite ? min(abs(seconds), Double(Int.max / 2)) : 0)
        return (value, seconds < 0 && value > 0)
    }
}

/// Spoken form of a time for VoiceOver: "12 minutes 31 seconds", or "12 seconds before the start" for a time before
/// it. The same whole seconds `TimeLabel` shows, so what's heard matches what's seen.
public enum SpokenTime {
    public static func format(_ seconds: TimeInterval) -> String {
        let (value, before) = TimeLabel.wholeSeconds(seconds)
        let words = Duration.seconds(value).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
        return before ? "\(words) before the start" : words
    }
}

/// Sections like Notes and Mail: Today, Yesterday, recent days, then months and years.
public struct DateGroup: Identifiable {
    public let id: String
    public let title: String
    public var meetings: [Meeting]

    public init(id: String, title: String, meetings: [Meeting]) {
        self.id = id; self.title = title; self.meetings = meetings
    }

    public static func groups(for meetings: [Meeting], now: Date = Date(), calendar: Calendar = .current) -> [DateGroup] {
        var groups: [DateGroup] = []
        for meeting in meetings {
            let title = title(for: meeting.date, now: now, calendar: calendar)
            if groups.last?.title == title { groups[groups.count - 1].meetings.append(meeting) }
            else { groups.append(DateGroup(id: title + "-\(groups.count)", title: title, meetings: [meeting])) }
        }
        return groups
    }

    public static func title(for date: Date, now: Date, calendar: Calendar) -> String {
        let today = calendar.startOfDay(for: now)
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if date > today { return "Upcoming" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0
        if days == 1 { return "Yesterday" }
        if days < 7 { return "Previous 7 Days" }
        if days < 30 { return "Previous 30 Days" }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.wide)) }
        return date.formatted(.dateTime.year())
    }
}

public enum RowDate {
    /// The time for Today and Yesterday, the weekday for the previous week, otherwise "3 Sep".
    public static func format(_ date: Date, group: String, now: Date = Date(), calendar: Calendar = .current) -> String {
        switch group {
        case "Today", "Yesterday", "Upcoming": return date.formatted(date: .omitted, time: .shortened)
        case "Previous 7 Days": return date.formatted(.dateTime.weekday(.wide))
        default:
            if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.day().month(.abbreviated)) }
            return date.formatted(.dateTime.day().month(.abbreviated).year())
        }
    }
}

/// The second line of a row when nothing is happening: the gist, else your first note, else the length.
/// A first note that only repeats the title says nothing, so the next line is used instead.
public enum RowPreview {
    public static func text(for meeting: Meeting) -> String {
        if let overview = meeting.summary?.overview, !overview.isEmpty { return overview }
        let title = normalized(meeting.title)
        // List markers ("- ", "* ", "• ") are typing, not content.
        let lines = meeting.notes.split(whereSeparator: \.isNewline)
            .map { $0.replacingOccurrences(of: #"^\s*[-*•]\s+"#, with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let line = lines.first(where: { normalized($0) != title }) { return line }
        if meeting.tracks.isEmpty { return lines.isEmpty ? "No notes" : "Notes only" }
        return meeting.duration.map(DurationLabel.format) ?? ""
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

extension Meeting {
    public func speakerIndex(_ id: String?) -> Int? { id.flatMap { id in speakers.firstIndex { $0.id == id } } }
    public func speakerName(_ id: String?) -> String? { id.flatMap { id in speakers.first { $0.id == id }?.name } }
    /// A raw microphone with an echo-cancelled copy counts as transcribed once the copy is.
    public var hasUntranscribedAudio: Bool { hasUntranscribedTranscribableAudio }
    /// Names of the people, for the byline: up to three, then "and 2 others".
    public var peopleLine: String? {
        // One person can be several speakers (recognized by voice in more than one recording): named once.
        var seen = Set<String>()
        let named = speakers.map(\.name).filter { !$0.hasPrefix("Speaker ") && seen.insert($0).inserted }
        if named.isEmpty { return speakers.count > 1 ? "\(speakers.count) speakers" : nil }
        if named.count <= 3 { return named.formatted(.list(type: .and)) }
        return named.prefix(3).joined(separator: ", ") + " and \(named.count - 3) others"
    }
}

/// Sentences both apps put in the same dialogs, so the Mac and the iPhone say the same thing.
public enum LibraryWords {
    /// New Note's title on both apps: "Note at 10:15 AM".
    public static func noteTitle(at date: Date) -> String {
        "Note at \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// An encrypted library's status in Settings: "On", or, on the device sealing its history, how much is left
    /// ("Encrypting · 12 left"), and on an iPhone off Wi‑Fi that it's waiting for it.
    public static func encryptionStatus(_ summary: SealingSummary) -> String {
        guard let progress = summary.progress, summary.isMigrator, progress.remaining > 0 else { return "On" }
        return "Encrypting · \(progress.remaining) left" + (progress.waitsForWiFi ? " · Waiting for Wi‑Fi" : "")
    }

    /// Under "Start over with a new key?" (an encrypted library whose key is lost): what's lost and what isn't.
    public static let startOverConsequence = "What’s only in iCloud is lost. Conversations on your devices stay and sync again."

    /// Under "Delete the folder “Clients”?": what happens to what's in it.
    public static func folderDeletion(conversations count: Int) -> String {
        switch count {
        case 0: return "The folder is empty."
        case 1: return "The conversation in it stays in your library."
        default: return "The \(count) conversations in it stay in your library."
        }
    }
}

extension Meeting {
    /// VoiceOver's name for a photo, on both apps: "Photo at 2 minutes, 5 seconds: Whiteboard".
    public func photoAccessibilityLabel(_ photo: MeetingPhoto) -> String {
        let time = timelineTime(of: photo).map { " at \(SpokenTime.format($0))" } ?? ""
        return "Photo\(time)" + (photo.displayCaption.map { ": \($0)" } ?? "")
    }
}
