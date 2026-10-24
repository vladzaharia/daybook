import AppIntents
import Foundation

// App Intents shared by the app and the widget extension. Both targets compile this file so each
// bundle's App Intents metadata lists the intents its surfaces use (Live Activity buttons, the
// Control Center control, the widget's buttons, Siri, Shortcuts, and the Action button).
//
// The recording intents conform to `AudioRecordingIntent` (start, stop, resume) or
// `LiveActivityIntent` (bookmark), so the system always performs them in the app's process, where
// the recorder lives, launching the app in the background when needed. An intent that starts
// recording from the background must start a Live Activity; the app does that for every recording.

/// What the intents ask of the app. The app registers its handler at launch; in the widget
/// extension there is none, so an intent that somehow runs there explains instead of failing silently.
@MainActor
protocol RecordingCommandHandling: AnyObject {
    var isRecordingActive: Bool { get }
    func startRecording() async throws
    func stopRecording() async throws
    func resumeRecording() async throws
    @discardableResult func addBookmark() async throws -> TimeInterval
}

@MainActor
enum RecordingCommands {
    static weak var handler: (any RecordingCommandHandling)?

    static func current() throws -> any RecordingCommandHandling {
        guard let handler else { throw RecordingCommandError.appUnavailable }
        return handler
    }
}

enum RecordingCommandError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case notRecording
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: return "Open Daybook to record."
        case .notRecording: return "Daybook isn't recording."
        case .failed(let reason): return "\(reason)"
        }
    }
}

struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Records a conversation with the iPhone's microphone.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await RecordingCommands.current().startRecording()
        return .result()
    }
}

struct StopRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the recording and saves it to your library.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await RecordingCommands.current().stopRecording()
        return .result()
    }
}

struct ResumeRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Resume Recording"
    static let description = IntentDescription("Continues a recording that a call or another app interrupted.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await RecordingCommands.current().resumeRecording()
        return .result()
    }
}

struct AddBookmarkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add Bookmark"
    static let description = IntentDescription("Marks this moment in the recording.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await RecordingCommands.current().addBookmark()
        return .result()
    }
}

/// The Control Center control's action: on starts recording, off stops it.
struct ToggleRecordingIntent: SetValueIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record Conversation"
    static let isDiscoverable = false

    @Parameter(title: "Recording")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        let commands = try RecordingCommands.current()
        if value, !commands.isRecordingActive {
            try await commands.startRecording()
        } else if !value, commands.isRecordingActive {
            try await commands.stopRecording()
        }
        return .result()
    }
}
