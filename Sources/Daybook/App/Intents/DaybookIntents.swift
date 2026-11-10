import AppIntents
import AppKit
import Foundation

// The Mac's App Intents: Start Recording, Stop Recording, Add Bookmark, New Note, Show Floating Notes, and Open
// Conversation (ConversationEntity.swift), for Shortcuts, Spotlight, and Siri. The iPhone has the same recording
// intents with the same titles and phrases (Apps/iOS/Shared/RecordingIntents.swift); there they're
// AudioRecordingIntent and LiveActivityIntent, which the Mac doesn't have, so these are the Mac's own. Each runs in
// the app, on its state (`IntentState`), launching Daybook when it isn't running.

/// The app's state, for intents and Spotlight: the app hands it over once its library window is up
/// (`SystemEntryPoints`). An intent that runs before then (Shortcuts launching Daybook) waits for it a little.
@MainActor
enum IntentState {
    private static weak var current: AppState?
    /// Opens the library window and brings Daybook forward.
    private(set) static var openLibrary: () -> Void = { NSApp.activate() }
    private static var waiting: [UUID: CheckedContinuation<AppState?, Never>] = [:]

    static func register(_ state: AppState, openLibrary: @escaping () -> Void) {
        current = state
        self.openLibrary = openLibrary
        let all = waiting
        waiting = [:]
        for continuation in all.values { continuation.resume(returning: state) }
    }

    /// The app's state once its library is open. Throws when Daybook can't be reached in `limit`, or its library won't
    /// open by itself (a library move to answer, or a library that couldn't open), which the window then says.
    static func ready(within limit: Duration = .seconds(10)) async throws -> AppState {
        let state: AppState
        if let current {
            state = current
        } else {
            let token = UUID()
            let found: AppState? = await withCheckedContinuation { continuation in
                waiting[token] = continuation
                Task { @MainActor in
                    try? await Task.sleep(for: limit)
                    waiting.removeValue(forKey: token)?.resume(returning: nil)
                }
            }
            guard let found else { throw DaybookIntentError.appUnavailable }
            state = found
        }
        guard await LibraryOpening.opens(state) else { throw DaybookIntentError.libraryUnavailable }
        return state
    }

    /// Forgets the state (tests).
    static func reset() {
        current = nil
        openLibrary = { NSApp.activate() }
    }
}

/// What an intent says when it can't do what it was asked, in the iPhone's words where it's the same thing.
enum DaybookIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case appUnavailable
    case libraryUnavailable
    case notRecording
    case conversationGone
    case failed(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .appUnavailable: return "Open Daybook to record."
        case .libraryUnavailable: return "Open Daybook to see what its library needs."
        case .notRecording: return "Daybook isn’t recording."
        case .conversationGone: return "That conversation isn’t in Daybook anymore."
        case .failed(let reason): return "\(reason)"
        }
    }
}

/// What the intents do, on the app's state: one place each, so a test can run them without the system.
@MainActor
enum IntentActions {
    /// Starts recording a new conversation; already recording, nothing changes.
    static func startRecording(_ state: AppState) async throws {
        guard state.recordingID == nil, !state.isStartingRecording else { return }
        await state.startRecording(from: .elsewhere)
        // A start that failed says why in the window's alert; Shortcuts says it too.
        guard state.recordingID != nil else {
            throw DaybookIntentError.failed(state.problem?.message ?? "Recording couldn’t start.")
        }
    }

    static func stopRecording(_ state: AppState) async throws {
        guard state.recordingID != nil else { throw DaybookIntentError.notRecording }
        await state.stopRecording()
    }

    static func addBookmark(_ state: AppState) throws {
        guard let id = state.recordingID else { throw DaybookIntentError.notRecording }
        state.addHighlight(id)
    }

    /// A conversation that's only your notes, open in the library, as File › New Note does.
    @discardableResult static func newNote(_ state: AppState) -> UUID {
        if state.place.isDevice { state.place = .section(.all) }
        let id = state.newNote()
        IntentState.openLibrary()
        return id
    }

    /// The recording's, else the panel's home.
    static func showFloatingNotes(_ state: AppState) {
        state.showFloatingNotes(focus: state.recordingID)
    }

    static func open(_ id: UUID, in state: AppState) throws {
        guard state.meetings.contains(where: { $0.id == id }) else { throw DaybookIntentError.conversationGone }
        state.showConversation(id)
        IntentState.openLibrary()
    }
}

struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Records a conversation, with a call’s audio when there is one.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentActions.startRecording(try await IntentState.ready())
        return .result()
    }
}

struct StopRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Recording"
    static let description = IntentDescription("Stops the recording and saves it to your library.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try await IntentActions.stopRecording(try await IntentState.ready())
        return .result()
    }
}

struct AddBookmarkIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Bookmark"
    static let description = IntentDescription("Marks this moment in the recording.")

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentActions.addBookmark(try await IntentState.ready())
        return .result()
    }
}

struct NewNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "New Note"
    static let description = IntentDescription("Starts a conversation that’s only your notes.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentActions.newNote(try await IntentState.ready())
        return .result()
    }
}

struct ShowFloatingNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Floating Notes"
    static let description = IntentDescription("Shows your notes over other apps: the recording’s, or recent conversations.")

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentActions.showFloatingNotes(try await IntentState.ready())
        return .result()
    }
}

/// Siri phrases and Spotlight's actions. The recording phrases are the iPhone's (DaybookShortcuts there).
struct DaybookShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartRecordingIntent(),
                    phrases: ["Start recording in \(.applicationName)",
                              "Record a conversation with \(.applicationName)",
                              "Start a \(.applicationName) recording"],
                    shortTitle: "Start Recording", systemImageName: "record.circle")
        AppShortcut(intent: StopRecordingIntent(),
                    phrases: ["Stop recording in \(.applicationName)",
                              "Stop the \(.applicationName) recording"],
                    shortTitle: "Stop Recording", systemImageName: "stop.circle")
        AppShortcut(intent: AddBookmarkIntent(),
                    phrases: ["Bookmark this in \(.applicationName)",
                              "Add a bookmark in \(.applicationName)",
                              "Mark this moment in \(.applicationName)"],
                    shortTitle: "Add Bookmark", systemImageName: "bookmark")
        AppShortcut(intent: NewNoteIntent(),
                    phrases: ["New note in \(.applicationName)",
                              "Start a \(.applicationName) note"],
                    shortTitle: "New Note", systemImageName: "square.and.pencil")
        AppShortcut(intent: ShowFloatingNotesIntent(),
                    phrases: ["Show floating notes in \(.applicationName)",
                              "Show my \(.applicationName) notes"],
                    shortTitle: "Show Floating Notes", systemImageName: "note.text")
    }

    static let shortcutTileColor: ShortcutTileColor = .red
}
