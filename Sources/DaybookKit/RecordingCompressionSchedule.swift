import DaybookCore
import Foundation

/// When a Mac may first compress older recordings, and what Settings says about it. Compress Older Recordings is on by
/// default and can't be undone, so a Mac does nothing for a week after the first launch of a version that has it,
/// time for the person to see the setting first. The date is this Mac's own (its preferences), never synced.
public enum RecordingCompressionSchedule {
    public static let firstRunWait: TimeInterval = 7 * 86_400

    /// The day this Mac may start, recorded the first time it's asked for (a week from then).
    public static func startDate(in defaults: UserDefaults, key: String, now: Date = Date()) -> Date {
        if let stored = defaults.object(forKey: key) as? Date { return stored }
        let start = now.addingTimeInterval(firstRunWait)
        defaults.set(start, forKey: key)
        return start
    }

    /// The setting's choices, in the order shown.
    public static let choices: [RecordingCompressionAge] = [.after30Days, .after90Days, .never]

    public static func title(_ age: RecordingCompressionAge) -> String {
        switch age {
        case .after30Days: return "After 30 Days"
        case .after90Days: return "After 90 Days"
        case .never: return "Never"
        }
    }

    public static let label = "Compress Older Recordings"
    /// The one line under it: what can't be undone.
    public static let footer = "Compressed recordings can’t be restored to their original quality."

    /// "Starts Nov 27" until this Mac may start, nil from then (and for Never).
    public static func startsLine(_ start: Date?, age: RecordingCompressionAge, now: Date = Date()) -> String? {
        guard age != .never, let start, now < start else { return nil }
        return "Starts \(start.formatted(.dateTime.month(.abbreviated).day()))"
    }

    /// Info › Audio's words for a compressed recording: "Compressed · 14 MB".
    public static func infoLine(_ track: RecordingTrack) -> String? {
        guard let encoding = track.encoding else { return nil }
        guard let size = encoding.size, size > 0 else { return "Compressed" }
        return "Compressed · \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"
    }
}
