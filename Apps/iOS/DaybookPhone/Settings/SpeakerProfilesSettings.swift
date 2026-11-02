import DaybookKit
import DaybookUI
import SwiftUI

// MARK: Speaker Profiles

/// Settings › Speaker Profiles: DaybookUI's list, the screen the Mac shows in its Speaker Profiles window. Each
/// profile pushes its `SpeakerProfileScreen` (docs/architecture.md, "Speakers and profiles").
struct SpeakerProfilesScreen: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        SpeakerProfileList(library: model.library.controller, route: SettingsRoute.speakerProfile) {
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Speaker Profiles")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Settings' row: "No profiles yet", "1 profile", "3 profiles", as on the Mac.
    static func summary(_ count: Int) -> String { SpeakerProfileWords.profiles(count) }
}

/// One profile (DaybookUI's `SpeakerProfileDetail`). A conversation it labels closes Settings and opens on the
/// page; once the profile is merged or deleted, the screen goes back to the list.
struct SpeakerProfileScreen: View {
    let profileID: UUID
    @Environment(PhoneAppModel.self) private var model
    @Environment(ReadingSession.self) private var session
    @Environment(\.closeSettings) private var closeSettings
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SpeakerProfileDetail(library: model.library.controller, profileID: profileID, openConversation: open) { _ in dismiss() }
            .settingsScrollEnd()
    }

    private func open(_ id: UUID) {
        closeSettings?()
        session.open(id, mode: .summary)
    }
}

extension EnvironmentValues {
    /// Closes Settings wherever it shows (a sheet in the hand, the open Duo's two pages), for a screen in it that
    /// opens a conversation. `SettingsScreen` sets it.
    @Entry var closeSettings: (() -> Void)? = nil
}
