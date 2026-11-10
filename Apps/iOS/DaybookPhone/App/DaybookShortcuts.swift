import AppIntents

/// Siri phrases and Shortcuts actions. The same intents back the Action button (choose Shortcut, or
/// the Record Conversation control) and Spotlight. An action the Mac has too is said as it is there
/// (`ShortcutPhrasesTests` holds them together).
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
                              "Start a note in \(.applicationName)"],
                    shortTitle: "New Note", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenConversationIntent(),
                    phrases: ["Open \(\.$target) in \(.applicationName)",
                              "Open a conversation in \(.applicationName)"],
                    shortTitle: "Open Conversation", systemImageName: "text.page")
    }

    static let shortcutTileColor: ShortcutTileColor = .red
}
