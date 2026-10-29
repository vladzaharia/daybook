import DaybookCore
import DaybookKit
import SwiftUI

/// Speaker Profiles: the people Daybook knows by voice, their voiceprints, and where they speak.
/// Two profiles of one person (named two ways) merge into one.
struct SpeakerProfilesView: View {
    @ObservedObject var state: AppState
    @State private var selection: UUID?
    @State private var merging: SpeakerProfileMerge?

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
                    MergeMenu(profile: profile, others: others(than: profile.id)) { merging = $0 }
                    Divider()
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
                SpeakerProfileDetail(state: state, profile: profile, others: others(than: profile.id)) { merging = $0 }
                    .id(profile.id)
            } else {
                ContentUnavailableView("No Selection", systemImage: "person.crop.circle")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear(perform: selectFirst)
        // The library may still be opening when the window does.
        .onChange(of: profiles.map(\.id)) { _, _ in selectFirst() }
        .alert(merging.map { "Merge \($0.profile.name) into \($0.target.name)?" } ?? "", isPresented: Binding(
            get: { merging != nil }, set: { if !$0 { merging = nil } }), presenting: merging) { merge in
            Button("Merge") {
                if state.library.mergeSpeakerProfile(merge.profile.id, into: merge.target.id) { selection = merge.target.id }
                merging = nil
            }
            Button("Cancel", role: .cancel) { merging = nil }
        } message: { merge in
            Text("\(merge.profile.name)’s voiceprints and conversations move to \(merge.target.name).")
        }
        #if DEBUG
        .task(id: profiles.map(\.id)) {
            SpeakerProfilesDemo.apply(profiles: profiles, select: { selection = $0 }, merge: { merge in
                if CommandLine.arguments.contains("--confirm-merge") {
                    if state.library.mergeSpeakerProfile(merge.profile.id, into: merge.target.id) { selection = merge.target.id }
                } else {
                    merging = merge
                }
            })
        }
        #endif
    }

    private func others(than id: UUID) -> [SpeakerProfile] { profiles.filter { $0.id != id } }

    private func selectFirst() {
        if selection == nil || !profiles.contains(where: { $0.id == selection }) { selection = profiles.first?.id }
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

/// A profile to merge into another, waiting for the person to confirm.
struct SpeakerProfileMerge: Identifiable {
    var profile: SpeakerProfile
    var target: SpeakerProfile
    var id: UUID { profile.id }
}

/// Merge Into: the other profiles, each a merge of this one into it.
private struct MergeMenu: View {
    let profile: SpeakerProfile
    let others: [SpeakerProfile]
    let merge: (SpeakerProfileMerge) -> Void

    var body: some View {
        Menu("Merge Into") {
            ForEach(others) { other in
                Button(other.name) { merge(SpeakerProfileMerge(profile: profile, target: other)) }
            }
        }
        .disabled(others.isEmpty)
    }
}

/// One profile: its name, its voiceprints (each removable, with where it came from), and the
/// conversations it labels.
private struct SpeakerProfileDetail: View {
    @ObservedObject var state: AppState
    let profile: SpeakerProfile
    let others: [SpeakerProfile]
    let merge: (SpeakerProfileMerge) -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var draft = ""
    /// Another profile already has the name typed: offered as a merge.
    @State private var taken: SpeakerProfile?

    private var voiceprints: [Voiceprint] { state.libraryMetadata.voiceprints(of: profile.id) }
    private var appearances: [(meeting: Meeting, speaker: Speaker, identity: SpeakerIdentity)] { state.library.speakers(of: profile.id) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft)
                    .onSubmit(rename)
                if let taken {
                    HStack {
                        Text("Another profile is called \(taken.name).").foregroundStyle(.secondary)
                        Spacer()
                        Button("Merge Into \(taken.name)") { merge(SpeakerProfileMerge(profile: profile, target: taken)) }
                            .buttonStyle(.daybookLink)
                    }
                    .font(.caption)
                }
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
                HStack {
                    MergeMenu(profile: profile, others: others, merge: merge)
                        .menuStyle(.button)
                        .fixedSize()
                    Spacer()
                    Button("Delete Profile", role: .destructive) { state.library.deleteSpeakerProfile(profile.id) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = profile.name }
        .onChange(of: profile.name) { _, name in draft = name; taken = nil }
        .onChange(of: draft) { _, value in if let taken, SpeakerProfile.normalizedName(value) != SpeakerProfile.normalizedName(taken.name) { self.taken = nil } }
        #if DEBUG
        .task { if let typed = SpeakerProfilesDemo.typed, profile.name == SpeakerProfilesDemo.selected { draft = typed; rename() } }
        #endif
    }

    private func rename() {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != profile.name else { draft = profile.name; return }
        if let other = state.library.speakerProfile(named: name, besides: profile.id) {
            // The typed name stays, beside the merge it offers.
            taken = other
            return
        }
        if !state.library.renameSpeakerProfile(profile.id, to: name) { draft = profile.name }
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

#if DEBUG
/// Debug only, for screenshots of the window: `--speaker-profile <name>` selects a profile,
/// `--profile-name <name>` types a name into it (another profile's, to offer a merge), and
/// `--merge-into <name>` asks to merge it into that one (`--confirm-merge`: and merges).
@MainActor
enum SpeakerProfilesDemo {
    static let selected = LaunchOptions.value(after: "--speaker-profile")
    static let typed = LaunchOptions.value(after: "--profile-name")
    static let target = LaunchOptions.value(after: "--merge-into")

    static func apply(profiles: [SpeakerProfile], select: (UUID) -> Void, merge: (SpeakerProfileMerge) -> Void) {
        guard let selected, let profile = profiles.first(where: { $0.name == selected }) else { return }
        select(profile.id)
        if let target, let other = profiles.first(where: { $0.name == target }) { merge(SpeakerProfileMerge(profile: profile, target: other)) }
    }
}
#endif

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
