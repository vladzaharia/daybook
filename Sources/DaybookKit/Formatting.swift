import DaybookCore
import DaybookDevices
import Foundation

// Words and numbers both apps show: times on a conversation's timeline, spoken times for
// VoiceOver, date groups in the list, a row's preview line, and a conversation's people.
// `DurationLabel` ("43 min") and `Meeting.duration` live in DaybookDevices, which matches and
// formats recorder lengths with them; DaybookKit re-exports both.

public enum TimeLabel {
    public static func format(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(abs(seconds), Double(Int.max / 2)) : 0
        let value = Int(safe), sign = seconds < 0 ? "−" : ""
        return sign + (value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60))
    }

    /// The interface's form, as in Voice Memos: "0:14", "12:31", "1:02:03". Model evidence and
    /// exports keep `format`.
    public static func short(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(abs(seconds), Double(Int.max / 2)) : 0
        let value = Int(safe), sign = seconds < 0 ? "−" : ""
        return sign + (value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60))
    }
}

/// Spoken form of a time for VoiceOver: "12 minutes 31 seconds".
public enum SpokenTime {
    public static func format(_ seconds: TimeInterval) -> String {
        Duration.seconds(max(0, seconds.rounded())).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
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
        let named = speakers.map(\.name).filter { !$0.hasPrefix("Speaker ") }
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
