import DaybookKit
import SwiftUI

// MARK: Speaker Profiles

/// Speaker Profiles: the people Daybook knows by voice, edited through `LibraryController`, so the
/// changes sync like any library setting and the Mac labels speakers with them
/// (docs/architecture.md, "Speakers and profiles"). The Mac's Speaker Profiles window, as screens.
struct SpeakerProfilesScreen: View {
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        let controller = model.library.controller
        let _ = model.library.revision
        let profiles = controller.speakerProfiles
        List {
            if profiles.isEmpty {
                ContentUnavailableView {
                    Label("No Speaker Profiles", systemImage: "person.wave.2")
                } description: {
                    Text("Name a speaker in a conversation.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(profiles) { profile in
                        NavigationLink(value: SettingsRoute.speakerProfile(profile.id)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name).foregroundStyle(PhoneStyle.Ink.title)
                                Text(Self.voiceprints(controller.metadata.voiceprints(of: profile.id).count))
                                    .font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                            }
                            .padding(.vertical, 1)
                            .accessibilityElement(children: .combine)
                        }
                        .swipeActions {
                            Button(role: .destructive) { controller.deleteSpeakerProfile(profile.id) } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                }
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle("Speaker Profiles")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func voiceprints(_ count: Int) -> String {
        count == 0 ? "No voiceprints" : count == 1 ? "1 voiceprint" : "\(count) voiceprints"
    }

    static func summary(_ count: Int) -> String {
        count == 0 ? "None yet" : count == 1 ? "1 profile" : "\(count) profiles"
    }
}

/// One profile: its name, its voiceprints and where they came from, the conversations it's given
/// to, and merging it into another profile of the same person or deleting it.
struct SpeakerProfileScreen: View {
    let profileID: UUID
    @Environment(PhoneAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    /// Another profile already has the name typed: offered as a merge.
    @State private var taken: SpeakerProfile?
    @State private var merging: SpeakerProfile?
    @FocusState private var naming: Bool

    var body: some View {
        let controller = model.library.controller
        let _ = model.library.revision
        if let profile = controller.speakerProfiles.first(where: { $0.id == profileID }) {
            form(profile, controller)
        } else {
            ContentUnavailableView("Profile Removed", systemImage: "person.wave.2")
        }
    }

    private func form(_ profile: SpeakerProfile, _ controller: LibraryController) -> some View {
        let voiceprints = controller.metadata.voiceprints(of: profile.id)
        let appearances = controller.speakers(of: profile.id)
        let others = controller.speakerProfiles.filter { $0.id != profile.id }
        return Form {
            Section("Name") {
                TextField("Name", text: $draft)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($naming)
                    .onSubmit { rename(profile, controller) }
                if let taken {
                    HStack(spacing: 8) {
                        Text("Another profile is called \(taken.name).").foregroundStyle(PhoneStyle.Ink.secondary)
                        Spacer(minLength: 4)
                        Button("Merge") { merging = taken }
                            .buttonStyle(.borderless)
                            .foregroundStyle(PhoneStyle.Ink.link)
                            .accessibilityLabel("Merge into \(taken.name)")
                    }
                    .font(.footnote)
                }
            }
            Section("Voiceprints") {
                if voiceprints.isEmpty { Text("None yet").foregroundStyle(PhoneStyle.Ink.secondary) }
                ForEach(voiceprints) { print in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(of: print.meetingID, controller)).foregroundStyle(PhoneStyle.Ink.title)
                        Text("\(Self.origin(print)) · \(print.recordedAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.footnote).foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .swipeActions {
                        Button(role: .destructive) { controller.removeVoiceprint(print.id) } label: { Label("Remove", systemImage: "minus.circle") }
                    }
                }
                if voiceprints.contains(where: { !$0.origin.isPersonChosen }) {
                    Button("Forget Learned Voiceprints") { controller.forgetLearnedVoiceprints(of: profile.id) }
                        .foregroundStyle(PhoneStyle.Ink.link)
                }
            }
            Section("Conversations") {
                if appearances.isEmpty { Text("None yet").foregroundStyle(PhoneStyle.Ink.secondary) }
                ForEach(appearances, id: \.speaker.id) { appearance in
                    HStack {
                        Text(appearance.meeting.title).lineLimit(1).foregroundStyle(PhoneStyle.Ink.title)
                        Spacer(minLength: 8)
                        Text(appearance.identity.source == .recognized ? "Recognized" : "Named").foregroundStyle(PhoneStyle.Ink.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Section {
                Menu {
                    ForEach(others) { other in Button(other.name) { merging = other } }
                } label: {
                    Text("Merge Into…").foregroundStyle(others.isEmpty ? PhoneStyle.Ink.faint : PhoneStyle.Ink.link)
                }
                .disabled(others.isEmpty)
                Button("Delete Profile", role: .destructive) {
                    controller.deleteSpeakerProfile(profile.id)
                    dismiss()
                }
            }
            SettingsScrollEndMarker()
        }
        .settingsScrollEnd()
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { draft = profile.name }
        .onChange(of: profile.name) { _, name in draft = name; taken = nil }
        .onChange(of: naming) { _, active in if !active { rename(profile, controller) } }
        .onChange(of: draft) { _, value in
            if let taken, SpeakerProfile.normalizedName(value) != SpeakerProfile.normalizedName(taken.name) { self.taken = nil }
        }
        .alert(merging.map { "Merge \(profile.name) into \($0.name)?" } ?? "", isPresented: Binding(
            get: { merging != nil }, set: { if !$0 { merging = nil } }), presenting: merging) { target in
            Button("Merge") {
                merging = nil
                if controller.mergeSpeakerProfile(profile.id, into: target.id) { dismiss() }
            }
            Button("Cancel", role: .cancel) { merging = nil }
        } message: { target in
            Text("\(profile.name)’s voiceprints and conversations move to \(target.name).")
        }
        #if DEBUG
        .task {
            SpeakerProfileScreenDemo.apply(profile: profile, others: others, type: { draft = $0; rename(profile, controller) }, merge: { target in
                if CommandLine.arguments.contains("--confirm-merge") {
                    if controller.mergeSpeakerProfile(profile.id, into: target.id) { dismiss() }
                } else {
                    merging = target
                }
            })
        }
        #endif
    }

    private func rename(_ profile: SpeakerProfile, _ controller: LibraryController) {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != profile.name else { draft = profile.name; return }
        if let other = controller.speakerProfile(named: name, besides: profile.id) {
            // The typed name stays, beside the merge it offers.
            taken = other
            return
        }
        if !controller.renameSpeakerProfile(profile.id, to: name) { draft = profile.name }
    }

    private func title(of meetingID: UUID, _ controller: LibraryController) -> String {
        controller.meeting(meetingID)?.title ?? "Deleted conversation"
    }

    static func origin(_ print: Voiceprint) -> String {
        switch print.origin {
        case .named: return "Named"
        case .confirmed: return "Confirmed"
        case .recognized: return "Learned"
        }
    }
}

#if DEBUG
/// Debug only, for screenshots: `--open-settings speaker-profile:<name>` opens a profile;
/// `--profile-name <name>` types a name into it (another profile's, to offer a merge), and
/// `--merge-into <name>` asks to merge it into that one (`--confirm-merge`: and merges).
@MainActor
enum SpeakerProfileScreenDemo {
    static func apply(profile: SpeakerProfile, others: [SpeakerProfile], type: (String) -> Void, merge: (SpeakerProfile) -> Void) {
        func value(_ flag: String) -> String? {
            guard let index = CommandLine.arguments.firstIndex(of: flag), CommandLine.arguments.indices.contains(index + 1) else { return nil }
            return CommandLine.arguments[index + 1]
        }
        if let typed = value("--profile-name") { type(typed) }
        if let target = value("--merge-into"), let other = others.first(where: { $0.name == target }) { merge(other) }
    }
}
#endif
