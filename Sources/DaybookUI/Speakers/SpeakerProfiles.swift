import DaybookDesign
import DaybookKit
import SwiftUI

// Speaker Profiles, one screen for both apps (docs/interface.md, "Speaker Profiles"): the people Daybook knows by
// voice, each with its name, its voiceprints and where they came from, and the conversations it labels. The Mac
// shows it as a window of two columns (`SpeakerProfilesBrowser`); the iPhone pushes the list and then a profile
// inside Settings (`SpeakerProfileList`, `SpeakerProfileDetail`). Edits go to `LibraryController`, so they sync as
// library settings. Deleting a profile, removing a voiceprint, and forgetting what a profile learned each ask first,
// with what they cost and Cancel the default, and each can be undone.

/// The Mac's Speaker Profiles window: the profiles in a sidebar, the chosen one beside them. Delete (⌫) asks to
/// delete the selected profile.
public struct SpeakerProfilesBrowser: View {
    let library: LibraryController
    let openConversation: @MainActor (UUID) -> Void
    @State private var selection: UUID?
    @State private var request: SpeakerProfileRequest?

    public init(library: LibraryController, openConversation: @escaping @MainActor (UUID) -> Void) {
        self.library = library
        self.openConversation = openConversation
    }

    private var profiles: [SpeakerProfile] { library.speakerProfiles }

    public var body: some View {
        NavigationSplitView {
            List(profiles, selection: $selection) { profile in
                SpeakerProfileRow(library: library, profile: profile)
                    .tag(profile.id)
                    .contextMenu { SpeakerProfileMenu(library: library, profile: profile, request: $request) }
            }
            .overlay { if profiles.isEmpty { SpeakerProfilesEmpty() } }
            #if os(macOS)
            .onDeleteCommand { if let profile = profiles.first(where: { $0.id == selection }) { request = .delete(profile) } }
            #endif
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let selection, profiles.contains(where: { $0.id == selection }) {
                SpeakerProfileDetail(library: library, profileID: selection, openConversation: openConversation) { next in
                    self.selection = next ?? profiles.first { $0.id != selection }?.id
                }
                .id(selection)
            } else {
                ContentUnavailableView("No Selection", systemImage: "person.crop.circle")
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear(perform: selectFirst)
        // The library may still be opening when the window does.
        .onChange(of: profiles.map(\.id)) { _, _ in selectFirst() }
        .speakerProfileConfirmations(library: library, request: $request) { left, next in
            if selection == left { selection = next ?? profiles.first { $0.id != left }?.id }
        }
        #if DEBUG
        .task(id: profiles.map(\.id)) {
            guard let name = SpeakerProfileDemo.selectedProfile, let profile = profiles.first(where: { $0.name == name }) else { return }
            selection = profile.id
        }
        #endif
    }

    private func selectFirst() {
        if selection == nil || !profiles.contains(where: { $0.id == selection }) { selection = profiles.first?.id }
    }
}

/// The profiles as a list whose rows push a profile (`route`): the iPhone's Settings › Speaker Profiles. A row's
/// swipe deletes it, after asking; a full swipe never does. `trailing` closes the list (a screen's own rows).
public struct SpeakerProfileList<Route: Hashable, Trailing: View>: View {
    let library: LibraryController
    let route: (UUID) -> Route
    let trailing: Trailing
    @State private var request: SpeakerProfileRequest?

    public init(library: LibraryController, route: @escaping (UUID) -> Route, @ViewBuilder trailing: () -> Trailing) {
        self.library = library
        self.route = route
        self.trailing = trailing()
    }

    public var body: some View {
        let profiles = library.speakerProfiles
        List {
            if profiles.isEmpty {
                SpeakerProfilesEmpty().listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(profiles) { profile in
                        NavigationLink(value: route(profile.id)) {
                            SpeakerProfileRow(library: library, profile: profile)
                        }
                        .contextMenu { SpeakerProfileMenu(library: library, profile: profile, request: $request) }
                        .swipeActions(allowsFullSwipe: false) {
                            // Not the destructive role, which takes the row away before the person has answered.
                            Button { request = .delete(profile) } label: { Label("Delete", systemImage: "trash") }
                                .tint(DaybookPalette.Ink.error)
                        }
                    }
                }
            }
            trailing
        }
        .speakerProfileConfirmations(library: library, request: $request) { _, _ in }
    }
}

extension SpeakerProfileList where Trailing == EmptyView {
    public init(library: LibraryController, route: @escaping (UUID) -> Route) {
        self.init(library: library, route: route) { EmptyView() }
    }
}

/// One profile: its name (another profile's name offers a merge), its voiceprints and where each came from, the
/// conversations it labels (each opens), then Merge Into and Delete Profile. `didLeave` follows the profile once
/// it's gone: merged (into that profile) or deleted (nil).
public struct SpeakerProfileDetail: View {
    let library: LibraryController
    let profileID: UUID
    let openConversation: @MainActor (UUID) -> Void
    let didLeave: @MainActor (_ mergedInto: UUID?) -> Void
    @State private var draft = ""
    /// Another profile already has the name typed: offered as a merge.
    @State private var taken: SpeakerProfile?
    @State private var request: SpeakerProfileRequest?
    @FocusState private var naming: Bool
    @Environment(\.daybookDensity) private var density

    public init(library: LibraryController, profileID: UUID, openConversation: @escaping @MainActor (UUID) -> Void,
                didLeave: @escaping @MainActor (_ mergedInto: UUID?) -> Void) {
        self.library = library
        self.profileID = profileID
        self.openConversation = openConversation
        self.didLeave = didLeave
    }

    public var body: some View {
        if let profile = library.speakerProfiles.first(where: { $0.id == profileID }) {
            form(profile)
        } else {
            ContentUnavailableView("Profile Removed", systemImage: "person.wave.2")
        }
    }

    private func form(_ profile: SpeakerProfile) -> some View {
        let voiceprints = library.metadata.voiceprints(of: profile.id)
        let appearances = library.speakers(of: profile.id)
        return Form {
            Section {
                TextField("Name", text: $draft)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    #endif
                    .focused($naming)
                    .onSubmit { rename(profile) }
                    .accessibilityLabel("Name")
                if let taken {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: DaybookSpacing.s2) { nameTaken(taken, profile: profile) }
                        VStack(alignment: .leading, spacing: DaybookSpacing.s1) { nameTaken(taken, profile: profile) }
                    }
                    .font(density == .touch ? .footnote : .caption)
                }
            } header: {
                if density == .touch { Text("Name") }
            }
            Section("Voiceprints") {
                if voiceprints.isEmpty { Text("None yet").foregroundStyle(DaybookPalette.Ink.secondary) }
                ForEach(voiceprints) { print in voiceprintRow(print, profile: profile) }
                if voiceprints.contains(where: { !$0.origin.isPersonChosen }) {
                    Button(SpeakerProfileWords.forgetLearned + "…", role: .destructive) { request = .forget(profile) }
                        .foregroundStyle(DaybookPalette.Ink.error)
                        .buttonStyle(.plain)
                }
            }
            Section("Conversations") {
                if appearances.isEmpty { Text("None yet").foregroundStyle(DaybookPalette.Ink.secondary) }
                ForEach(appearances, id: \.speaker.id) { appearance in
                    Button { openConversation(appearance.meeting.id) } label: {
                        conversationRow(appearance.meeting, identity: appearance.identity)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the conversation")
                }
            }
            Section {
                SpeakerProfileActions(library: library, profile: profile, request: $request)
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .navigationTitle(profile.name)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { draft = profile.name }
        .onChange(of: profile.name) { _, name in draft = name; taken = nil }
        .onChange(of: naming) { _, active in if !active { rename(profile) } }
        .onChange(of: draft) { _, value in
            if let taken, SpeakerProfile.normalizedName(value) != SpeakerProfile.normalizedName(taken.name) { self.taken = nil }
        }
        .speakerProfileConfirmations(library: library, request: $request) { left, next in
            if left == profileID { didLeave(next) }
        }
        #if DEBUG
        .task {
            if let typed = SpeakerProfileDemo.typedName { draft = typed; rename(profile) }
            if let target = SpeakerProfileDemo.mergeTarget, let other = library.speakerProfiles.first(where: { $0.name == target && $0.id != profile.id }) {
                if SpeakerProfileDemo.confirmsMerge {
                    if library.mergeSpeakerProfile(profile.id, into: other.id) { didLeave(other.id) }
                } else {
                    request = .merge(profile, into: other)
                }
            }
            if SpeakerProfileDemo.asksToDelete { request = .delete(profile) }
        }
        #endif
    }

    @ViewBuilder private func nameTaken(_ taken: SpeakerProfile, profile: SpeakerProfile) -> some View {
        Text(SpeakerProfileWords.nameTaken(by: taken.name)).foregroundStyle(DaybookPalette.Ink.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Spacer(minLength: 0)
        Button(SpeakerProfileWords.mergeInto(taken.name)) { request = .merge(profile, into: taken) }
            .buttonStyle(.daybookLink)
    }

    private func voiceprintRow(_ print: Voiceprint, profile: SpeakerProfile) -> some View {
        let title = title(of: print.meetingID)
        return HStack(spacing: DaybookSpacing.s2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(DaybookPalette.Ink.title)
                Text("\(SpeakerProfileWords.origin(print)) · \(print.recordedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(density == .touch ? .footnote : .caption).foregroundStyle(DaybookPalette.Ink.secondary)
            }
            .accessibilityElement(children: .combine)
            #if os(macOS)
            Spacer()
            Button { request = .removeVoiceprint(print, title: title, profile: profile) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help(SpeakerProfileWords.removeVoiceprint)
                .accessibilityLabel("Remove voiceprint from \(title)")
            #endif
        }
        .swipeActions(allowsFullSwipe: false) {
            Button { request = .removeVoiceprint(print, title: title, profile: profile) } label: {
                Label("Remove", systemImage: "minus.circle")
            }
            .tint(DaybookPalette.Ink.error)
        }
        .contextMenu {
            Button(SpeakerProfileWords.removeVoiceprint + "…", role: .destructive) {
                request = .removeVoiceprint(print, title: title, profile: profile)
            }
        }
    }

    private func conversationRow(_ meeting: Meeting, identity: SpeakerIdentity) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DaybookSpacing.s2) {
                Text(meeting.title).lineLimit(1).foregroundStyle(DaybookPalette.Ink.title)
                Spacer(minLength: DaybookSpacing.s2)
                conversationFacts(meeting, identity: identity)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.title).foregroundStyle(DaybookPalette.Ink.title)
                HStack(spacing: DaybookSpacing.s2) { conversationFacts(meeting, identity: identity) }
                    .font(density == .touch ? .footnote : .caption)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func conversationFacts(_ meeting: Meeting, identity: SpeakerIdentity) -> some View {
        Text(SpeakerProfileWords.appearance(identity)).foregroundStyle(DaybookPalette.Ink.secondary)
        Text(meeting.date.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(DaybookPalette.Ink.secondary)
            .monospacedDigit()
    }

    private func rename(_ profile: SpeakerProfile) {
        let name = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != profile.name else { draft = profile.name; return }
        if let other = library.speakerProfile(named: name, besides: profile.id) {
            // The typed name stays, beside the merge it offers.
            taken = other
            return
        }
        if !library.renameSpeakerProfile(profile.id, to: name) { draft = profile.name }
    }

    private func title(of meetingID: UUID) -> String {
        library.meeting(meetingID)?.title ?? SpeakerProfileWords.deletedConversation
    }
}

// MARK: - Pieces

/// A profile in the list: its name and how many voiceprints it has.
struct SpeakerProfileRow: View {
    let library: LibraryController
    let profile: SpeakerProfile
    @Environment(\.daybookDensity) private var density

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.name).foregroundStyle(DaybookPalette.Ink.title)
            Text(SpeakerProfileWords.voiceprints(library.metadata.voiceprints(of: profile.id).count))
                .font(density == .touch ? .footnote : .caption).foregroundStyle(DaybookPalette.Ink.secondary)
        }
        .padding(.vertical, 1)
        .accessibilityElement(children: .combine)
    }
}

/// When there are no profiles: how one comes about.
struct SpeakerProfilesEmpty: View {
    var body: some View {
        ContentUnavailableView("No Speaker Profiles", systemImage: "person.wave.2", description: Text("Name a speaker in a conversation."))
    }
}

/// A profile's menu: Merge Into ▸ the others, then Delete Profile….
struct SpeakerProfileMenu: View {
    let library: LibraryController
    let profile: SpeakerProfile
    @Binding var request: SpeakerProfileRequest?

    var body: some View {
        MergeMenu(library: library, profile: profile, request: $request)
        Divider()
        Button(SpeakerProfileWords.deleteProfile + "…", role: .destructive) { request = .delete(profile) }
    }
}

/// Merge Into ▸ the other profiles, each a merge of this one into it, confirmed first.
struct MergeMenu: View {
    let library: LibraryController
    let profile: SpeakerProfile
    @Binding var request: SpeakerProfileRequest?

    var body: some View {
        let others = library.speakerProfiles.filter { $0.id != profile.id }
        Menu(SpeakerProfileWords.mergeMenu) {
            ForEach(others) { other in Button(other.name) { request = .merge(profile, into: other) } }
        }
        .disabled(others.isEmpty)
    }
}

/// The detail's foot: Merge Into, then Delete Profile… in the destructive ink.
struct SpeakerProfileActions: View {
    let library: LibraryController
    let profile: SpeakerProfile
    @Binding var request: SpeakerProfileRequest?
    @Environment(\.daybookDensity) private var density

    var body: some View {
        if density == .touch {
            MergeMenu(library: library, profile: profile, request: $request)
                .foregroundStyle(DaybookPalette.Ink.link)
            delete
        } else {
            HStack {
                MergeMenu(library: library, profile: profile, request: $request)
                    .menuStyle(.button)
                    .fixedSize()
                Spacer()
                delete
            }
        }
    }

    /// Destructive text takes the error ink (red is the recording's); on the Mac a plain text button, as Move to
    /// Trash… is, since a bordered button keeps its label ink.
    @ViewBuilder private var delete: some View {
        let button = Button(SpeakerProfileWords.deleteProfile + "…", role: .destructive) { request = .delete(profile) }
            .foregroundStyle(DaybookPalette.Ink.error)
        if density == .touch { button } else { button.buttonStyle(.plain) }
    }
}

/// Something asked for in Speaker Profiles that waits for the person to confirm it.
enum SpeakerProfileRequest: Identifiable {
    case delete(SpeakerProfile)
    case merge(SpeakerProfile, into: SpeakerProfile)
    case removeVoiceprint(Voiceprint, title: String, profile: SpeakerProfile)
    case forget(SpeakerProfile)

    var id: String {
        switch self {
        case .delete(let profile): return "delete:\(profile.id)"
        case .merge(let profile, let target): return "merge:\(profile.id):\(target.id)"
        case .removeVoiceprint(let print, _, _): return "voiceprint:\(print.id)"
        case .forget(let profile): return "forget:\(profile.id)"
        }
    }

    var isMerge: Bool {
        if case .merge = self { return true }
        return false
    }
}

extension View {
    /// Asks before a request in `request` acts, in an alert: a merge, and the destructive ones with what they cost,
    /// each with Cancel the default. `left` reports a profile that went (deleted: `next` nil; merged:
    /// the profile it went into).
    func speakerProfileConfirmations(library: LibraryController, request: Binding<SpeakerProfileRequest?>,
                                     left: @escaping @MainActor (_ profile: UUID, _ next: UUID?) -> Void) -> some View {
        modifier(SpeakerProfileConfirmations(library: library, request: request, left: left))
    }
}

private struct SpeakerProfileConfirmations: ViewModifier {
    let library: LibraryController
    @Binding var request: SpeakerProfileRequest?
    let left: @MainActor (UUID, UUID?) -> Void
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .alert(mergeTitle, isPresented: Binding(get: { request?.isMerge == true }, set: { if !$0 { request = nil } }),
                   presenting: request) { request in
                if case .merge(let profile, let target) = request {
                    Button("Merge") {
                        self.request = nil
                        if library.mergeSpeakerProfile(profile.id, into: target.id) { left(profile.id, target.id) }
                    }
                    Button("Cancel", role: .cancel) { self.request = nil }
                        .keyboardShortcut(.defaultAction)
                }
            } message: { request in
                if case .merge(let profile, let target) = request { Text(SpeakerProfileWords.mergeMessage(profile.name, into: target.name)) }
            }
            // An alert, not a dialog: on the iPhone a dialog is a popover pointing at the whole screen.
            .alert(destructiveTitle, isPresented: Binding(get: { request.map { !$0.isMerge } ?? false },
                                                          set: { if !$0 { request = nil } }),
                   presenting: request) { request in
                Button(confirmTitle(request), role: .destructive) { perform(request) }
                Button("Cancel", role: .cancel) { self.request = nil }
                    .keyboardShortcut(.defaultAction)
            } message: { request in
                Text(message(request))
            }
    }

    private var mergeTitle: String {
        guard case .merge(let profile, let target)? = request else { return "" }
        return SpeakerProfileWords.mergeTitle(profile.name, into: target.name)
    }

    private var destructiveTitle: String {
        switch request {
        case .delete(let profile)?: return SpeakerProfileWords.deleteTitle(profile.name)
        case .removeVoiceprint?: return SpeakerProfileWords.removeVoiceprintTitle
        case .forget(let profile)?: return SpeakerProfileWords.forgetTitle(profile.name)
        case .merge?, nil: return ""
        }
    }

    private func confirmTitle(_ request: SpeakerProfileRequest) -> String {
        switch request {
        case .delete: return SpeakerProfileWords.deleteProfile
        case .removeVoiceprint: return SpeakerProfileWords.removeVoiceprint
        case .forget: return SpeakerProfileWords.forgetLearned
        case .merge: return "Merge"
        }
    }

    private func message(_ request: SpeakerProfileRequest) -> String {
        switch request {
        case .delete: return SpeakerProfileWords.deleteMessage
        case .removeVoiceprint(_, let title, let profile): return SpeakerProfileWords.removeVoiceprintMessage(profile.name, from: title)
        case .forget: return SpeakerProfileWords.forgetMessage
        case .merge(let profile, let target): return SpeakerProfileWords.mergeMessage(profile.name, into: target.name)
        }
    }

    private func perform(_ request: SpeakerProfileRequest) {
        self.request = nil
        switch request {
        case .delete(let profile):
            library.deleteSpeakerProfile(profile.id, undoManager: undoManager)
            left(profile.id, nil)
        case .removeVoiceprint(let print, _, _):
            library.removeVoiceprint(print.id, undoManager: undoManager)
        case .forget(let profile):
            library.forgetLearnedVoiceprints(of: profile.id, undoManager: undoManager)
        case .merge:
            break
        }
    }
}
