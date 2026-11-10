import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

/// The Speaker Profiles window: DaybookUI's `SpeakerProfilesBrowser`, the screen the iPhone shows in Settings. A
/// conversation a profile labels opens in the library window.
struct SpeakerProfilesView: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SpeakerProfilesBrowser(library: state.library) { id in
            state.window.place = .section(.all)
            state.window.openID = id
            openWindow(id: WindowID.library)
        }
    }
}

/// Settings › Models › Speakers: how many profiles, and the window to edit them.
struct SpeakerProfilesSettingsRow: View {
    let state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LabeledContent {
            Button("Edit…") { openWindow(id: WindowID.speakerProfiles) }
        } label: {
            Text("Speaker profiles")
            Text(SpeakerProfileWords.profiles(state.speakerProfiles.count))
        }
    }
}
