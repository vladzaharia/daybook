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
    }

    var conversationID: UUID
    var title: String
}

extension RecordingActivityAttributes.ContentState {
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
