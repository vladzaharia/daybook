import ActivityKit
import Foundation

/// The Live Activity and Dynamic Island for a recording in progress.
///
/// The clock counts itself from `timerStart` (`Text(timerInterval:)`), so the app updates the
/// activity only when something the person needs changes: pause, resume, a bookmark, the microphone
/// going silent, a caption, or the recording ending.
struct RecordingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording
            /// Interrupted (a call, Siri, an alarm). Resume (once the call is over) or Stop.
            case paused
            /// Stop was pressed and the recorder is finishing: the clock frozen where it stopped, and no
            /// buttons, so it can't be stopped twice. It ends as saved or stopped once the recorder has finished.
            case saving
            /// Stopped, with a recording, which goes into the library.
            case saved
            /// It stopped by itself (storage couldn't keep up, the encoder failed): everything up to
            /// the frozen time is saved, and nothing records any more.
            case stopped
        }

        var phase: Phase
        /// The conversation's first second on the wall clock. The recording's timeline keeps running
        /// through an interruption, so the clock never jumps back.
        var timerStart: Date
        /// Seconds into the conversation when it paused or stopped; the clock shows this frozen.
        var frozenElapsed: TimeInterval?
        /// Whether the microphone hears anything: 1, or 0 once it has heard nothing for a few seconds
        /// (muted, unplugged, blocked) or while paused. It changes only then, never with the voice, so
        /// it costs no updates while people talk.
        var level: Double
        var bookmarkCount: Int
        /// Multipoint: "Also on Studio Mac" or "With Studio Mac" while a Mac records this conversation
        /// too. Optional, so activities started by an earlier build still decode.
        var multipoint: String? = nil
        /// The newest live caption, short (`captionLine`), while captions are on and one is showing;
        /// nil otherwise. What was said is private: hidden while the iPhone is locked. Optional, so
        /// activities started by an earlier build still decode.
        var caption: String? = nil
        /// Paused, whether recording can continue now: false during the call, when only Stop is
        /// offered. Nil from an earlier build, which offered Resume.
        var canResume: Bool? = nil
    }

    var conversationID: UUID
    var title: String
}

extension RecordingActivityAttributes.ContentState {
    /// How often the app refreshes the activity while it records, even when nothing changed, so
    /// its stale date keeps rolling forward.
    static let refreshInterval: TimeInterval = 60
    /// Without a refresh for this long the activity is stale: the app may have been stopped (a
    /// crash, the system ending it), and it asks to open Daybook rather than show a clock that runs on.
    static let staleAfter: TimeInterval = 90
    /// A pause changes nothing until the person acts, and the app may be suspended through a call.
    static let pausedStaleAfter: TimeInterval = 2 * 3_600

    /// The stale date for content sent at `now`. A recording that ended never goes stale. One being saved
    /// does, as a recording does, in case Daybook stops before it has finished.
    func staleDate(from now: Date) -> Date? {
        switch phase {
        case .recording, .saving: return now.addingTimeInterval(Self.staleAfter)
        case .paused: return now.addingTimeInterval(Self.pausedStaleAfter)
        case .saved, .stopped: return nil
        }
    }

    /// "Recording", "Paused", "Saving…", "Saved", "Recording stopped", or "Open Daybook to check" once the
    /// system marks it stale.
    func title(isStale: Bool) -> String {
        switch phase {
        case .saved: return "Saved"
        case .stopped: return "Recording stopped"
        case _ where isStale: return SharedRecordingState.unconfirmedLine
        case .recording: return "Recording"
        case .paused: return "Paused"
        case .saving: return "Saving…"
        }
    }

    /// The recording has ended, by Stop (being saved, or saved) or by itself: no buttons, the time frozen.
    var hasEnded: Bool { phase == .saving || phase == .saved || phase == .stopped }

    /// Paused, with Resume offered: only once recording can continue.
    var offersResume: Bool { phase == .paused && canResume != false }

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

    /// The activity's `level`: whether the microphone hears anything.
    static func level(hearing: Bool) -> Double { hearing ? 1 : 0 }

    /// What the Lock Screen says once a recording has ended: "Saved to Daybook", or that everything up
    /// to the frozen time is.
    var endLine: String? {
        switch phase {
        case .saved: return "Saved to Daybook"
        case .stopped: return (frozenElapsed ?? 0) > 0 ? "Everything up to then is saved" : "No audio was recorded"
        case .recording, .paused, .saving: return nil
        }
    }
}
