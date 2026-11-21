import DaybookCore
import DaybookDesign
import DaybookKit
import SwiftUI

/// Info › People on both apps: each person in the conversation (`Meeting.peopleSpeakers`: a voice heard only in
/// background audio isn't one), in their speaker ink, with how much of the talking they did, and under the name what
/// Daybook made of their voice.
struct PeopleSection: View {
    let library: LibraryController
    let meeting: Meeting
    /// Whether this device finds speakers (Tell speakers apart); a conversation made without that has none to show.
    var findsSpeakers = true
    /// Finds the speakers of this conversation once, whatever Tell speakers apart says; nil leaves it out.
    var identify: (() -> Void)?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let people = meeting.peopleSpeakers
        if people.isEmpty {
            Text(findsSpeakers ? "No speakers yet" : "Speakers off").foregroundStyle(DaybookPalette.Ink.secondary)
            if !findsSpeakers, let identify, !meeting.transcripts.isEmpty, !meeting.presentTracks.isEmpty {
                Button(ProcessingWords.identifySpeakers, action: identify)
                    .buttonStyle(.daybookLink)
                    .font(.footnote)
            }
        } else {
            ForEach(people) { person in
                SpeakerRow(person: person, profiles: library.speakerProfiles, me: library.ownerProfileID, thisIsMe: thisIsMe(person)) { name, picked in
                    // One person found more than once is renamed as one, so they stay one person.
                    library.renameSpeakers(person.speakerIDs, to: name, picked: picked, in: meeting.id, undoManager: undoManager)
                } identity: {
                    SpeakerIdentityLine(library: library, meeting: meeting, speakerIDs: person.speakerIDs)
                }
                .contextMenu { meMenu(person) }
                #if DEBUG
                .onAppear {
                    // `--speaker-name-me`: the first person is the person's own profile, for the You mark.
                    if SpeakerNamePickerDemo.marksFirstAsMe, person.index == 0, library.canMarkSpeakerAsMe(person.speakerIDs, in: meeting.id) {
                        library.markSpeakerAsMe(person.speakerIDs, in: meeting.id)
                    }
                }
                #endif
            }
        }
    }
}

extension PeopleSection {
    /// This Is Me on a person it does something for (`LibraryController.canMarkSpeakerAsMe`). Taking it back is the
    /// row's own Not <name>; the library-wide Not Me is on the profile.
    @ViewBuilder fileprivate func meMenu(_ person: MeetingPerson) -> some View {
        if library.canMarkSpeakerAsMe(person.speakerIDs, in: meeting.id) {
            Button(SpeakerProfileWords.thisIsMe) { library.markSpeakerAsMe(person.speakerIDs, in: meeting.id, undoManager: undoManager) }
        }
    }

    /// This Is Me on the row, for the person it is most likely to be: while the library has no profile that is the
    /// person's own, anyone it does something for, and the microphone's "Me" when it does. With nothing to go by yet
    /// (the "Me" speaker has no name), it takes the person to the name, which is what it needs.
    fileprivate func thisIsMe(_ person: MeetingPerson) -> (() -> Bool)? {
        let isMicrophone = person.speaker.name == FusionOptions().ownerName
        let noneYet = library.ownerProfileID == nil
        let offered = library.canMarkSpeakerAsMe(person.speakerIDs, in: meeting.id) ? (noneYet || isMicrophone) : (noneYet && isMicrophone)
        guard offered else { return nil }
        let (ids, id, undoManager) = (person.speakerIDs, meeting.id, undoManager)
        return { library.markSpeakerAsMe(ids, in: id, undoManager: undoManager) }
    }
}

/// A person: their ink, their name (edit to rename them everywhere in the conversation), and their share of the
/// talking; under the name, `identity`.
struct SpeakerRow<Identity: View>: View {
    let person: MeetingPerson
    let profiles: [SpeakerProfile]
    let me: UUID?
    /// This Is Me under the name; false from it means there was nothing to go by, and the name takes focus.
    var thisIsMe: (() -> Bool)?
    /// The name, and the profile when it's a row of the name list that was picked.
    let save: (String, UUID?) -> Void
    @ViewBuilder var identity: Identity
    @State private var draft = ""
    @FocusState private var focused: Bool
    @Environment(\.daybookDensity) private var density
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var touch: Bool { density == .touch }
    private var ink: Color { DaybookPalette.speakerInk(person.index) }
    private var dot: CGFloat { touch ? 10 : 8 }
    private var gap: CGFloat { touch ? 10 : 8 }
    private var bar: CGFloat { touch ? 52 : 44 }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if dynamicTypeSize.isAccessibilitySize {
                // The largest sizes: the name a line of its own, then the share and the time under it.
                HStack(alignment: .firstTextBaseline, spacing: gap) { inkDot; name }
                HStack(spacing: gap) { share; time }.padding(.leading, dot + gap)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: gap) {
                    inkDot
                    name
                    Spacer(minLength: 8)
                    share
                    time.frame(minWidth: bar, alignment: .trailing)
                }
            }
            // Lined up with the name, past the ink dot.
            identity.padding(.leading, dot + gap)
            if let thisIsMe {
                Button(SpeakerProfileWords.thisIsMe) { if !thisIsMe() { focused = true } }
                    .buttonStyle(.daybookLink)
                    .font(touch ? .footnote : .caption)
                    .padding(.leading, dot + gap)
            }
        }
        .onAppear {
            draft = person.speaker.name
            #if DEBUG
            if SpeakerNamePickerDemo.focusesInfo, person.index == 0 {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    focused = true
                    if let typed = SpeakerNamePickerDemo.draft { draft = typed }
                }
            }
            #endif
        }
        .onChange(of: person.speaker.name) { _, value in if !focused { draft = value } }
    }

    private var inkDot: some View {
        Circle().fill(ink).frame(width: dot, height: dot).accessibilityHidden(true)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }

    private var share: some View {
        Capsule().fill(Color.primary.opacity(0.08)).frame(width: bar, height: touch ? 5 : 4)
            .overlay(alignment: .leading) { Capsule().fill(ink).frame(width: max(touch ? 5 : 4, bar * person.share), height: touch ? 5 : 4) }
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityLabel("\(Int((person.share * 100).rounded())) percent of the talking")
    }

    private var time: some View {
        Text(DurationLabel.format(person.talkTime))
            .font(touch ? .subheadline.monospacedDigit() : .body.monospacedDigit())
            .foregroundStyle(DaybookPalette.Ink.secondary)
    }

    private var name: some View {
        SpeakerNameField(current: person.speaker.name, draft: $draft, isFocused: focused, profiles: profiles, me: me,
                         commit: commit) { nameField }
    }

    private var nameField: some View {
        let field = TextField("Speaker", text: $draft)
            .labelsHidden()
            .foregroundStyle(ink)
            .fontWeight(.semibold)
            .focused($focused)
            #if os(macOS)
            // Escape leaves the field with the name it had.
            .onExitCommand { draft = person.speaker.name; focused = false }
            #endif
            .onChange(of: focused) { _, active in if !active { commit(draft, nil) } }
            .accessibilityLabel("Speaker name")
            .accessibilityHint("Edit to rename this speaker everywhere in the conversation.")
        #if os(iOS)
        // The row's separator starts under the name, not under the first text after it (the time).
        return field
            .textInputAutocapitalization(.words)
            .submitLabel(.done)
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        #else
        return field
            .textFieldStyle(.plain)
            .help("Click to rename")
        #endif
    }

    private func commit(_ name: String, _ picked: UUID?) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = value.isEmpty ? person.speaker.name : value
        if !value.isEmpty, value != person.speaker.name { save(value, picked) }
        focused = false
    }
}

/// Under a speaker: a name Daybook gave by voice reads Recognized, with Not <name> to take it back; a profile the
/// voice resembles reads Maybe <name>, with Yes and No. Nothing for names the person gave. On the Mac, how alike the
/// voices are is in the tooltip; under touch, each answer has a 44 pt target. A person found more than once
/// (`MeetingPerson.speakerIDs`) reads Recognized while Daybook named any of those speakers, and Not <name> takes back
/// every label Daybook gave them, which separates those speakers again.
struct SpeakerIdentityLine: View {
    let library: LibraryController
    let meeting: Meeting
    let speakerIDs: [String]
    @Environment(\.daybookDensity) private var density

    /// The first of the speakers with a label or suggestion from Daybook.
    private var shown: (speakerID: String, identity: SpeakerIdentity)? {
        for id in speakerIDs {
            if let identity = meeting.speakerIdentity(id), identity.$source.isKnown,
               identity.source == .recognized || identity.source == .suggested { return (id, identity) }
        }
        return nil
    }

    var body: some View {
        if let shown, let profile = shown.identity.profileID.flatMap({ library.metadata.speakerProfile($0) }) {
            let identity = shown.identity, speakerID = shown.speakerID
            switch identity.source {
            case .recognized:
                line(identity) {
                    Label("Recognized", systemImage: "waveform")
                } answers: {
                    answer("Not \(profile.name)") {
                        for id in speakerIDs where meeting.speakerIdentity(id)?.source == .recognized {
                            library.rejectSpeakerProfile(id, in: meeting.id)
                        }
                    }
                }
            case .suggested:
                line(identity) {
                    Text("Maybe \(profile.name)")
                } answers: {
                    answer("Yes", label: "This is \(profile.name)") { library.confirmSpeakerProfile(speakerID, in: meeting.id) }
                    answer("No", label: "Not \(profile.name)") { library.rejectSpeakerProfile(speakerID, in: meeting.id) }
                }
            default:
                EmptyView()
            }
        }
    }

    /// The words, then the answers at the end of the line; the answers under the words when they don't fit beside.
    private func line<Words: View, Answers: View>(_ identity: SpeakerIdentity, @ViewBuilder _ words: () -> Words,
                                                  @ViewBuilder answers: () -> Answers) -> some View {
        // Under touch the answers sit far enough apart that their 44 pt targets don't overlap.
        let spacing: CGFloat = density == .touch ? 18 : 6
        let words = words(), answers = answers()
        let row = ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) {
                words.fixedSize()
                Spacer(minLength: 8)
                answers.fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                words
                HStack(spacing: spacing) { answers }
            }
        }
            .font(density == .touch ? .footnote : .caption)
            .foregroundStyle(DaybookPalette.Ink.secondary)
            .labelStyle(IdentityLabelStyle())
        #if os(macOS)
        return row.help(identity.similarity.map { "\(Int(($0 * 100).rounded()))% alike" } ?? "")
        #else
        return row
        #endif
    }

    private func answer(_ title: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.daybookLink)
            .accessibilityLabel(label ?? title)
    }
}

/// A glyph and its words, close together.
private struct IdentityLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}
