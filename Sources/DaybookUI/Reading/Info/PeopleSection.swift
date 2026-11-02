import DaybookDesign
import DaybookKit
import SwiftUI

/// Info › People on both apps: each person in the conversation (`Meeting.peopleSpeakers`: a voice heard only in
/// background audio isn't one), in their speaker ink, with how much of the talking they did, and under the name what
/// Daybook made of their voice.
struct PeopleSection: View {
    let library: LibraryController
    let meeting: Meeting
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let people = meeting.peopleSpeakers
        if people.isEmpty {
            Text("No speakers yet").foregroundStyle(DaybookPalette.Ink.secondary)
        } else {
            ForEach(people) { person in
                SpeakerRow(person: person) { name in
                    library.update(meeting.id, actionName: "Rename Speaker", undoManager: undoManager) {
                        $0.renameSpeaker(id: person.speaker.id, name: name)
                    }
                } identity: {
                    SpeakerIdentityLine(library: library, meeting: meeting, speakerID: person.speaker.id)
                }
            }
        }
    }
}

/// A person: their ink, their name (edit to rename them everywhere in the conversation), and their share of the
/// talking; under the name, `identity`.
struct SpeakerRow<Identity: View>: View {
    let person: MeetingPerson
    let save: (String) -> Void
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
                HStack(spacing: gap) { inkDot; name }
                HStack(spacing: gap) { share; time }.padding(.leading, dot + gap)
            } else {
                HStack(spacing: gap) {
                    inkDot
                    name
                    Spacer(minLength: 8)
                    share
                    time.frame(minWidth: bar, alignment: .trailing)
                }
            }
            // Lined up with the name, past the ink dot.
            identity.padding(.leading, dot + gap)
        }
        .onAppear { draft = person.speaker.name }
        .onChange(of: person.speaker.name) { _, value in if !focused { draft = value } }
    }

    private var inkDot: some View {
        Circle().fill(ink).frame(width: dot, height: dot).accessibilityHidden(true)
    }

    private var share: some View {
        Capsule().fill(Color.primary.opacity(0.08)).frame(width: bar, height: touch ? 5 : 4)
            .overlay(alignment: .leading) { Capsule().fill(ink).frame(width: max(touch ? 5 : 4, bar * person.share), height: touch ? 5 : 4) }
            .accessibilityLabel("\(Int((person.share * 100).rounded())) percent of the talking")
    }

    private var time: some View {
        Text(DurationLabel.format(person.talkTime))
            .font(touch ? .subheadline.monospacedDigit() : .body.monospacedDigit())
            .foregroundStyle(DaybookPalette.Ink.secondary)
    }

    private var name: some View {
        let field = TextField("Speaker", text: $draft)
            .labelsHidden()
            .foregroundStyle(ink)
            .fontWeight(.semibold)
            .focused($focused)
            .onSubmit(commit)
            .onChange(of: focused) { _, active in if !active { commit() } }
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

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { draft = person.speaker.name } else if value != person.speaker.name { save(value) }
    }
}

/// Under a speaker: a name Daybook gave by voice reads Recognized, with Not <name> to take it back; a profile the
/// voice resembles reads Maybe <name>, with Yes and No. Nothing for names the person gave. On the Mac, how alike the
/// voices are is in the tooltip; under touch, each answer has a 44 pt target.
struct SpeakerIdentityLine: View {
    let library: LibraryController
    let meeting: Meeting
    let speakerID: String
    @Environment(\.daybookDensity) private var density

    var body: some View {
        if let identity = meeting.speakerIdentity(speakerID), identity.$source.isKnown,
           let profile = identity.profileID.flatMap({ library.metadata.speakerProfile($0) }) {
            switch identity.source {
            case .recognized:
                line(identity) {
                    Label("Recognized", systemImage: "waveform")
                } answers: {
                    answer("Not \(profile.name)") { library.rejectSpeakerProfile(speakerID, in: meeting.id) }
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
