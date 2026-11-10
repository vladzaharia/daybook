import AppIntents
import DaybookKit
import Foundation

/// Daybook's Focus filter (Settings › Focus › a Focus › Focus Filters › Daybook), the Mac's too
/// (Sources/Daybook/App/Intents/DaybookFocusFilter.swift): in this Focus, whether Personal conversations show in the
/// library's lists and search, and whether a meeting's reminder asks to record it as it starts. The system runs it as
/// the Focus starts, and again as it ends with both back on, waking Daybook in the background if it must. What it chose
/// is kept in this iPhone's preferences (`PersonalFocus`), where the lock reads it (`PersonalLock.focus`) and the
/// reminders do (`remindMeetings`). The words are `PersonalLockWords`', written here as literals because the system
/// reads them from the app's metadata.
struct DaybookFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Daybook"

    @Parameter(title: "Show Personal", default: true)
    var showsPersonal: Bool

    @Parameter(title: "Ask to Record Meetings", default: true)
    var asksToRecord: Bool

    var focus: PersonalFocus { PersonalFocus(showsPersonal: showsPersonal, asksToRecord: asksToRecord) }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Daybook", subtitle: "\(PersonalLockWords.focusSummary(focus))")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PersonalFocus.set(focus)
        // The meetings' reminders are scheduled ahead: they follow the Focus now.
        AppDestinations.model?.remindMeetings()
        return .result()
    }

    /// At launch, the Focus that's on now, in case it changed while Daybook wasn't running; with none, both on.
    @MainActor
    static func catchUp(_ lock: PersonalLock) async {
        let current = try? await DaybookFocusFilter.current
        lock.apply(current?.focus ?? PersonalFocus())
    }
}
