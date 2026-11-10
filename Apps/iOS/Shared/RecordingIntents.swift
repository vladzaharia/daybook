import AppIntents
import DaybookDesign
import Foundation

// App Intents shared by the app and the widget extension. Both targets compile this file so each
// bundle's App Intents metadata lists the intents its surfaces use (Live Activity buttons, the
// Control Center control, the widget's buttons, Siri, Shortcuts, and the Action button).
//
// The recording intents conform to `AudioRecordingIntent` (start, stop, resume) or
// `LiveActivityIntent` (bookmark), so the system always performs them in the app's process, where
// the recorder lives, launching the app in the background when needed. An intent that starts
// recording from the background must start a Live Activity; the app does that for every recording.
// Each says what happened in a short line, which Siri speaks ("Recording.", "Saved to Daybook.").

/// What the intents ask of the app. The app registers its handler at launch; in the widget
/// extension there is none, so an intent that somehow runs there explains instead of failing silently.
@MainActor
protocol RecordingCommandHandling: AnyObject {
    var isRecordingActive: Bool { get }
    /// The microphone has never been allowed or refused: iOS asks only with Daybook on screen.
    var microphoneNeedsAsking: Bool { get }
    /// What the last stop came to.
    var lastStopResult: RecordingStopResult { get }
    func startRecording() async throws
    func stopRecording() async throws
    func resumeRecording() async throws
    @discardableResult func addBookmark() async throws -> TimeInterval
}

extension RecordingCommandHandling {
    var microphoneNeedsAsking: Bool { false }
    var lastStopResult: RecordingStopResult { .saved }
}

@MainActor
enum RecordingCommands {
    static weak var handler: (any RecordingCommandHandling)?

    static func current() throws -> any RecordingCommandHandling {
        guard let handler else { throw RecordingCommandError.appUnavailable }
        return handler
    }

    /// Before a start from the background (Control Center, the Action button, Siri, a widget) while
    /// the microphone has never been asked about: the intent continues with Daybook in front, where
    /// iOS can ask, then starts. Asked before, it starts where it is.
    static func askForMicrophoneInFront(_ intent: some AppIntent, _ commands: any RecordingCommandHandling) async throws {
        guard commands.microphoneNeedsAsking else { return }
        try await intent.continueInForeground(IntentDialog(stringLiteral: microphoneDialog), alwaysConfirm: false)
    }

    static let microphoneDialog = "Open Daybook to allow the microphone."
}

/// What a stop came to, said back by Siri and Shortcuts.
struct RecordingStopResult: Equatable, Sendable {
    /// "Saved to Daybook.", or what happened instead ("No audio was recorded.").
    var sentence: String

    static let saved = RecordingStopResult(sentence: "Saved to Daybook.")
}

enum RecordingCommandError: Error, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case notRecording
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: return "Open Daybook to record."
        case .notRecording: return "Daybook isn’t recording."
        case .failed(let reason): return "\(reason)"
        }
    }
}

/// The lines Siri and Shortcuts say after each recording command.
enum RecordingDialogs {
    static let recording = "Recording."
    static let notRecording = "Daybook isn’t recording."

    /// "Bookmarked at 12:03."
    static func bookmarked(at time: TimeInterval) -> String { "Bookmarked at \(DaybookTime.short(time))." }
}

struct StartRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Records a conversation with the microphone.")
    /// In the background as a rule; in front only when iOS has to ask for the microphone.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = try RecordingCommands.current()
        try await RecordingCommands.askForMicrophoneInFront(self, commands)
        try await commands.startRecording()
        return .result(dialog: IntentDialog(stringLiteral: RecordingDialogs.recording))
    }
}

struct StopRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the recording and saves it to your library.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = try RecordingCommands.current()
        try await commands.stopRecording()
        return .result(dialog: IntentDialog(stringLiteral: commands.lastStopResult.sentence))
    }
}

struct ResumeRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Resume Recording"
    static let description = IntentDescription("Continues a recording that a call or another app interrupted.")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await RecordingCommands.current().resumeRecording()
        return .result(dialog: IntentDialog(stringLiteral: RecordingDialogs.recording))
    }
}

struct AddBookmarkIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Add Bookmark"
    static let description = IntentDescription("Marks this moment in the recording.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let time = try await RecordingCommands.current().addBookmark()
        return .result(dialog: IntentDialog(stringLiteral: RecordingDialogs.bookmarked(at: time)))
    }
}

/// The Control Center control's action: on starts recording, off stops it.
struct ToggleRecordingIntent: SetValueIntent, AudioRecordingIntent {
    static let title: LocalizedStringResource = "Record Conversation"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Recording")
    var value: Bool

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let commands = try RecordingCommands.current()
        if value, !commands.isRecordingActive {
            try await RecordingCommands.askForMicrophoneInFront(self, commands)
            try await commands.startRecording()
            return .result(dialog: IntentDialog(stringLiteral: RecordingDialogs.recording))
        } else if !value, commands.isRecordingActive {
            try await commands.stopRecording()
            return .result(dialog: IntentDialog(stringLiteral: commands.lastStopResult.sentence))
        }
        // Already as asked.
        return .result(dialog: IntentDialog(stringLiteral: commands.isRecordingActive ? RecordingDialogs.recording : RecordingDialogs.notRecording))
    }
}
