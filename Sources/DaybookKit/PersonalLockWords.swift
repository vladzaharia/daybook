import Foundation

/// The lock for Personal conversations, in words both apps say (`PersonalLock`): what a hidden row shows, Settings'
/// switch and its one footer line, the reason the system's prompt gives, and the Focus filter's summary. Settings'
/// label is in sentence case; the iPhone title-cases it where it draws it (`SettingsWords.titleCased`).
public enum PersonalLockWords {
    /// A Personal conversation's title in every list while the lock is on: the library, search, Floating Notes'
    /// Recent, and the Trash. No gist and no tags go with it.
    public static let hiddenTitle = "Personal conversation"
    /// A locked page's button, and a locked row's menu.
    public static let unlock = "Unlock"
    /// What VoiceOver adds to a hidden row, and says of the Personal place while it's locked.
    public static let locked = "Locked"
    /// The Personal place's symbol while it's locked, and a locked page's.
    public static let symbol = "lock"

    /// What the device unlocks with, as a label names it: "Touch ID", "password".
    public static func method(_ method: PersonalLockMethod) -> String {
        switch method {
        case .touchID: return "Touch ID"
        case .faceID: return "Face ID"
        case .opticID: return "Optic ID"
        case .password: return "password"
        case .passcode: return "passcode"
        }
    }

    /// Settings' switch: "Require Touch ID for Personal" on the Mac, "Require Face ID for Personal" on the iPhone.
    public static func requirement(_ method: PersonalLockMethod) -> String {
        "Require \(Self.method(method)) for Personal"
    }

    /// The switch's one footer line: what the lock covers.
    public static let footer = "Personal conversations stay hidden until you unlock them."

    /// The reason the system's prompt gives. The Mac's prompt reads "“Daybook” is trying to …", so it continues that
    /// sentence; the iPhone's shows it as a line of its own.
    public static func reason(_ platform: ConversationAction.Platform) -> String {
        platform == .mac ? "show Personal conversations" : "Show Personal conversations"
    }

    // MARK: Focus filter

    /// The filter's name in Settings › Focus, and its two switches. Each app's `DaybookFocusFilter` writes them as
    /// literals, since the system reads them from the app's metadata; a test keeps the two the same.
    public static let focusFilter = "Daybook"
    public static let showPersonal = "Show Personal"
    public static let askToRecord = "Ask to Record Meetings"

    /// What a Focus's filter does, under its name: "Hides Personal · Doesn’t ask to record", or "Shows everything".
    public static func focusSummary(_ focus: PersonalFocus) -> String {
        let parts = [focus.showsPersonal ? nil : "Hides Personal", focus.asksToRecord ? nil : "Doesn’t ask to record"].compactMap { $0 }
        return parts.isEmpty ? "Shows everything" : parts.joined(separator: " · ")
    }
}
