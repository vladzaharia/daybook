import ActivityKit
import Foundation

/// The Live Activity and Dynamic Island for a recording in progress.
///
/// The clock counts itself from `timerStart` (`Text(timerInterval:)`), so the app updates the
/// activity only when something changes: pause, resume, a bookmark, or the coarse input level.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording
            /// Interrupted (a call, Siri, an alarm). Resume or Stop.
            case paused
            /// Stopped; the recording is being saved to the library.
            case saved
        }

        var phase: Phase
        /// The conversation's first second on the wall clock. The recording's timeline keeps running
        /// through an interruption, so the clock never jumps back.
        var timerStart: Date
        /// Seconds into the conversation when it paused or stopped; the clock shows this frozen.
        var frozenElapsed: TimeInterval?
        /// Input level, 0…1, in coarse steps so updates stay rare.
        var level: Double
        var bookmarkCount: Int
        /// Multipoint: "Also on Studio Mac" or "With Studio Mac" while a Mac records this conversation
        /// too. Optional, so activities started by an earlier build still decode.
        var multipoint: String? = nil
        /// The newest live caption, short (`captionLine`), while captions are on and one is showing;
        /// nil otherwise. What was said is private: hidden while the iPhone is locked. Optional, so
        /// activities started by an earlier build still decode.
        var caption: String? = nil
    }

    var conversationID: UUID
    var title: String
}

extension RecordingActivityAttributes.ContentState {
    /// How often the app refreshes the activity while it records, even when nothing changed, so
    /// its stale date keeps rolling forward.
    static let refreshInterval: TimeInterval = 60
    /// Without a refresh for this long the activity is stale: the app may have been stopped (a
    /// crash, the system ending it), and it shows "Not confirmed" rather than a clock that runs on.
    static let staleAfter: TimeInterval = 90
    /// A pause changes nothing until the person acts, and the app may be suspended through a call.
    static let pausedStaleAfter: TimeInterval = 2 * 3_600

    /// The stale date for content sent at `now`. A saved recording never goes stale.
    func staleDate(from now: Date) -> Date? {
        switch phase {
        case .recording: return now.addingTimeInterval(Self.staleAfter)
        case .paused: return now.addingTimeInterval(Self.pausedStaleAfter)
        case .saved: return nil
        }
    }

    /// "Recording", "Paused", "Saved", or "Not confirmed" once the system marks it stale.
    func title(isStale: Bool) -> String {
        switch phase {
        case .saved: return "Saved"
        case _ where isStale: return "Not confirmed"
        case .recording: return "Recording"
        case .paused: return "Paused"
        }
    }

    /// A new caption alone updates the activity at most this often: the system budgets Live Activity
    /// updates, and a line that changes faster can't be read at a glance anyway.
    static let captionInterval: TimeInterval = 5
    /// The longest caption line, in characters.
    static let captionLength = 80

    /// The caption line for the newest caption's text: spaces collapsed and, when it's long, its newest
    /// words after an ellipsis, so the line ends with what was just said. Nil when there's nothing to say.
    static func captionLine(_ text: String?) -> String? {
        let words = (text ?? "").split(whereSeparator: \.isWhitespace)
        guard let last = words.last else { return nil }
        var kept: [Substring] = []
        var length = 0
        for word in words.reversed() {
            let added = kept.isEmpty ? word.count : length + 1 + word.count
            if added > captionLength - 1, !kept.isEmpty { return "…" + kept.reversed().joined(separator: " ") }
            kept.append(word)
            length = added
        }
        let line = kept.reversed().joined(separator: " ")
        return line.count > captionLength ? "…" + String(last.suffix(captionLength - 1)) : line
    }

    /// Steps the input level into four buckets (silent, quiet, speech, loud).
    static func levelBucket(_ meter: Double) -> Double {
        switch meter {
        case ..<0.15: return 0
        case ..<0.4: return 0.33
        case ..<0.7: return 0.66
        default: return 1
        }
    }
}
