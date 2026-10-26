import ActivityKit
import AppIntents
import Foundation

/// The Live Activity for a hardware recorder (Soundcore Work): a recording this iPhone asked it to
/// make, or Listen Live. The recording lives on the recorder, so the activity says what the iPhone
/// last heard: live while connected, "as of 10:07" after it let the recorder go.
struct RecorderActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable {
            case recording
            /// Listen Live: the recorder's audio is arriving on this iPhone.
            case listening
            /// It stopped, or the iPhone no longer knows: the activity is ending.
            case ended
        }

        var phase: Phase
        /// When the recorder's recording started, on this iPhone's clock. The clock counts from it.
        var startedAt: Date?
        /// When the recorder last confirmed it's recording, while it isn't connected; nil while it is.
        var asOf: Date?
    }

    /// "Soundcore Work".
    var recorderName: String
    /// The recorder's ID for the recording.
    var recordingID: String
}

extension RecorderActivityAttributes.ContentState {
    /// Listening refreshes as audio arrives, so missing a minute and a half means the app stopped.
    static let listeningStaleAfter: TimeInterval = 90
    /// After this long without the recorder confirming it, nobody knows it's still recording (the
    /// device page stops saying so too).
    static let recordingStaleAfter: TimeInterval = 1_200
    /// The app refreshes the activity at least this often while it changes, to keep its stale date ahead.
    static let refreshInterval: TimeInterval = 60

    /// What the activity shows, from what the iPhone knows about the recorder; nil for no activity.
    /// Only a recording this iPhone started, or Listen Live, gets one: a recording someone started on
    /// the recorder's button isn't this iPhone's to show.
    static func make(isListening: Bool, isRecording: Bool, startedHere: Bool, startedAt: Date?, isLive: Bool,
                     asOf: Date) -> Self? {
        if isListening { return Self(phase: .listening, startedAt: startedAt, asOf: nil) }
        guard isRecording, startedHere else { return nil }
        return Self(phase: .recording, startedAt: startedAt, asOf: isLive ? nil : asOf)
    }

    func staleDate(from now: Date) -> Date? {
        switch phase {
        case .listening: return now.addingTimeInterval(Self.listeningStaleAfter)
        case .recording: return (asOf ?? now).addingTimeInterval(Self.recordingStaleAfter)
        case .ended: return nil
        }
    }

    /// "Listening live", "Recording", "Recording · as of 10:07 AM", or "Not confirmed" once stale.
    func title(isStale: Bool) -> String {
        switch phase {
        case .ended: return "Stopped"
        case _ where isStale: return "Not confirmed"
        case .listening: return "Listening live"
        case .recording:
            guard let asOf else { return "Recording" }
            return "Recording · as of \(asOf.formatted(date: .omitted, time: .shortened))"
        }
    }
}

/// What the recorder's Live Activity asks of the app. The app registers its handler at launch.
@MainActor
protocol RecorderCommandHandling: AnyObject {
    func stopListening()
}

@MainActor
enum RecorderCommands {
    static weak var handler: (any RecorderCommandHandling)?
}

/// The recorder's Live Activity button: ends Listen Live and keeps what arrived. The recorder keeps recording.
struct StopListeningIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop Listening"
    static let description = IntentDescription("Stops listening live to your recorder. It keeps recording.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let handler = RecorderCommands.handler else { throw RecordingCommandError.appUnavailable }
        handler.stopListening()
        return .result()
    }
}
