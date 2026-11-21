import Foundation

/// What the watch's one screen says, apart from the screen so the Mac can test it (docs/watch.md, "The screen").
public enum WatchWords {
    /// The microphone is refused: the watch can't open Settings, so it says where to go.
    public static let microphoneOff = "Microphone is off"
    public static let microphoneOffWhere = "Settings › Privacy & Security › Microphone"
    /// The iPhone's words when the watch tells it the microphone is refused.
    public static let microphoneOffPhone = "Turn on the microphone for Daybook on your Apple Watch."
    public static let couldntResume = "Couldn’t resume"
    public static let starting = "Starting…"
    public static let stoppedTitle = "Recording stopped"
    public static let pausedTitle = "Recording paused"
    public static let pausedBody = "Open Daybook to resume recording."

    /// What the status line is built from.
    public struct Status: Equatable, Sendable {
        public var problem: String?
        public var starting: Bool
        public var isRecording: Bool
        public var isCapturing: Bool
        public var isJoined: Bool
        public var isReachable: Bool
        public var isSending: Bool

        public init(problem: String? = nil, starting: Bool = false, isRecording: Bool = false, isCapturing: Bool = false,
                    isJoined: Bool = false, isReachable: Bool = false, isSending: Bool = false) {
            self.problem = problem
            self.starting = starting
            self.isRecording = isRecording
            self.isCapturing = isCapturing
            self.isJoined = isJoined
            self.isReachable = isReachable
            self.isSending = isSending
        }
    }

    /// The words under the button: what's true now, and nothing when nothing is.
    public static func statusLine(_ status: Status) -> String? {
        if let problem = status.problem { return problem }
        if status.starting { return starting }
        if status.isRecording {
            if !status.isCapturing { return "Paused" }
            if status.isJoined { return "With iPhone" }
            return status.isReachable ? "On Watch" : "Sends later"
        }
        if status.isSending { return status.isReachable ? "Sending to iPhone…" : "Waiting for iPhone" }
        return nil
    }

    /// The body of "Recording stopped": the reason, as a sentence.
    public static func stoppedBody(_ reason: String) -> String {
        reason.isEmpty || reason.hasSuffix(".") ? reason : reason + "."
    }

    /// The elapsed time, `m:ss` (`h:mm:ss` from an hour).
    public static func clock(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds))
        let (hours, minutes, secs) = (whole / 3600, whole % 3600 / 60, whole % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}
