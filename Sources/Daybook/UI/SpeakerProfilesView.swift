import DaybookCore
import DaybookKit
import SwiftUI

/// Speaker Profiles: the people Daybook knows by voice, their voiceprints, and where they speak.
struct SpeakerProfilesView: View {
    @ObservedObject var state: AppState
    @State private var selection: UUID?

    private var profiles: [SpeakerProfile] { state.speakerProfiles }

    var body: some View {
        NavigationSplitView {
            List(profiles, selection: $selection) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name)
                    Text(voiceprintCount(profile.id)).font(.caption).foregroundStyle(.secondary)
                }
                .tag(profile.id)
                .contextMenu {
                    Button("Delete Profile") { delete(profile.id) }
                }
            }
            .overlay {
                if profiles.isEmpty {
                    ContentUnavailableView("No Speaker Profiles", systemImage: "person.wave.2",
                                           description: Text("Name a speaker in a conversation."))
                }
            }
            .onDeleteCommand { if let selection { delete(selection) } }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let selection, let profile = profiles.first(where: { $0.id == selection }) {
                SpeakerProfileDetail(state: state, profile: profile)
                    .id(profile.id)
            } else {
                ContentUnavailableView("No Selection", systemImage: "person.crop.circle")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { if selection == nil { selection = profiles.first?.id } }
    }

    private func voiceprintCount(_ id: UUID) -> String {
        switch state.libraryMetadata.voiceprints(of: id).count {
        case 0: return "No voiceprints"
        case 1: return "1 voiceprint"
        case let count: return "\(count) voiceprints"
        }
    }

    private func delete(_ id: UUID) {
        if selection == id { selection = nil }
        state.library.deleteSpeakerProfile(id)
    }
}

/// One profile: its name, its voiceprints (each removable, with where it came from), and the
/// conversations it labels.
private struct SpeakerProfileDetail: View {
    @ObservedObject var state: AppState
    let profile: SpeakerProfile
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    @State private var nameTaken = false

    private var voiceprints: [Voiceprint] { state.libraryMetadata.voiceprints(of: profile.id) }
    private var appearances: [(meeting: Meeting, speaker: Speaker, identity: SpeakerIdentity)] { state.library.speakers(of: profile.id) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft)
                    .onSubmit(rename)
                if nameTaken { Text("Another profile has this name.").font(.caption).foregroundStyle(.secondary) }
            }
            Section("Voiceprints") {
                if voiceprints.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(voiceprints) { print in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title(of: print.meetingID))
                            Text("\(origin(print)) · \(print.recordedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { state.library.removeVoiceprint(print.id) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .help("Remove")
                            .accessibilityLabel("Remove voiceprint from \(title(of: print.meetingID))")
                    }
                }
                if voiceprints.contains(where: { !$0.origin.isPersonChosen }) {
                    Button("Forget Learned Voiceprints") { state.library.forgetLearnedVoiceprints(of: profile.id) }
                }
            }
            Section("Conversations") {
                if appearances.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                ForEach(appearances, id: \.speaker.id) { appearance in
                    Button { show(appearance.meeting) } label: {
                        HStack {
                            Text(appearance.meeting.title).lineLimit(1)
                            Spacer()
                            Text(appearance.identity.source == .recognized ? "Recognized" : "Named").foregroundStyle(.secondary)
                            Text(appearance.meeting.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            Section {
                Button("Delete Profile", role: .destructive) { state.library.deleteSpeakerProfile(profile.id) }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = profile.name }
        .onChange(of: profile.name) { _, name in draft = name }
    }

    private func rename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != profile.name else { draft = profile.name; return }
        nameTaken = !state.library.renameSpeakerProfile(profile.id, to: name)
        if nameTaken { draft = profile.name }
    }

    private func title(of meetingID: UUID) -> String {
        state.meetings.first { $0.id == meetingID }?.title ?? "Deleted conversation"
    }

    private func origin(_ print: Voiceprint) -> String {
        switch print.origin {
        case .named: return "Named"
        case .confirmed: return "Confirmed"
        case .recognized: return "Learned"
        }
    }

    private func show(_ meeting: Meeting) {
        state.place = .section(.all)
        state.selectedID = meeting.id
        openWindow(id: WindowID.library)
    }
}

/// Settings › Models › Speakers: how many profiles, and the window to edit them.
struct SpeakerProfilesSettingsRow: View {
    @ObservedObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        LabeledContent {
            Button("Edit…") { openWindow(id: WindowID.speakerProfiles) }
        } label: {
            Text("Speaker profiles")
            Text(count)
        }
    }

    private var count: String {
        switch state.speakerProfiles.count {
        case 0: return "No profiles yet"
        case 1: return "1 profile"
        case let count: return "\(count) profiles"
        }
    }
}
