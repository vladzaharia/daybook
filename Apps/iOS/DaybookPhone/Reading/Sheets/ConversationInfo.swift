import DaybookKit
import SwiftUI

/// The Mac's inspector, as a sheet: where the conversation is filed, who spoke, its recordings
/// and how they were lined up, and how it was processed.
struct ConversationInfo: View {
    @ObservedObject var library: LibraryController
    let meetingID: UUID
    private let dismiss = SheetDismiss()
    @Environment(ReadingSession.self) private var session
    @Environment(\.summaryPlacement) private var placement
    @State private var detent: PresentationDetent = Self.launchDetent

    var body: some View {
        NavigationStack {
            Group {
                if let meeting = library.meeting(meetingID) {
                    ScrollViewReader { proxy in
                        Form {
                            Section("Details") { details(meeting) }
                            // Without a recording there are no people or processing to show; Audio says so once.
                            if !meeting.tracks.isEmpty {
                                Section("People") { people(meeting) }
                                    .id("people")
                            }
                            Section("Audio") {
                                ForEach(meeting.tracks) { track in AudioSourceRow(meeting: meeting, track: track) }
                                if meeting.tracks.isEmpty { Text("No recording yet").foregroundStyle(PhoneStyle.Ink.secondary) }
                            }
                            if !meeting.tracks.isEmpty {
                                Section("Processing") { processing(meeting) }
                            }
                            if !meeting.revisions.isEmpty {
                                Section {
                                    Button {
                                        dismiss()
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { session.sheet = .history(meeting.id) }
                                    } label: { Label("Version History", systemImage: "clock.arrow.circlepath") }
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                        .background(Color(uiColor: .systemGroupedBackground))
                        #if DEBUG
                        .task {
                            // `--info-scroll people`, for screenshots.
                            guard let index = CommandLine.arguments.firstIndex(of: "--info-scroll"), CommandLine.arguments.indices.contains(index + 1) else { return }
                            try? await Task.sleep(for: .milliseconds(400))
                            proxy.scrollTo(CommandLine.arguments[index + 1], anchor: .top)
                        }
                        #endif
                    }
                } else {
                    ContentUnavailableView("Conversation Not Found", systemImage: "doc.questionmark")
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationDragIndicator(.visible)
    }

    /// `--info-detent large` (debug), for screenshots.
    private static var launchDetent: PresentationDetent {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--info-detent"), CommandLine.arguments.indices.contains(index + 1),
           CommandLine.arguments[index + 1] == "large" { return .large }
        #endif
        return .medium
    }

    // MARK: Details

    @ViewBuilder private func details(_ meeting: Meeting) -> some View {
        Picker(selection: Binding(get: { meeting.folderID }, set: { library.moveToFolder([meeting.id], $0) })) {
            Text("None").tag(UUID?.none)
            ForEach(library.folders) { folder in Text(folder.name).tag(UUID?.some(folder.id)) }
        } label: { InfoLabel("Folder", systemImage: "folder") }
        // The chips start where the row titles do, under "Tags", not under its symbol.
        Label {
            VStack(alignment: .leading, spacing: 8) {
                Text("Tags")
                TagEditor(tags: meeting.tags ?? []) { library.setTags(meeting.id, text: $0.joined(separator: ",")) }
            }
        } icon: {
            // Beside "Tags", not halfway down the chips.
            InfoSymbol("tag").frame(maxHeight: .infinity, alignment: .top).padding(.top, 2)
        }
        .padding(.vertical, 2)
        Picker(selection: Binding(get: { PlacementChoice(meeting.placement) }, set: { library.setPlacement([meeting.id], $0.placement) })) {
            Text(automaticPlacementTitle(meeting)).tag(PlacementChoice.automatic)
            Text("Work").tag(PlacementChoice.work)
            Text("Personal").tag(PlacementChoice.personal)
        } label: { InfoLabel("Shows In", systemImage: "rectangle.stack") }
        Picker(selection: Binding(get: { library.templateSelection(for: meeting.id) }, set: { id in
            if library.chooseTemplate(id, for: meeting.id), !meeting.unifiedTranscript.isEmpty {
                library.summarize(meeting.id, templateID: id == "auto" ? nil : id, placement: placement)
            }
        })) {
            Text(automaticTemplateTitle(meeting)).tag("auto")
            ForEach(library.templates) { Text($0.name).tag($0.id) }
        } label: { InfoLabel("Template", systemImage: "doc.text") }
        LabeledContent("Created", value: stamp(meeting.date))
        LabeledContent("Edited", value: stamp(meeting.updatedAt))
    }

    /// Created and Edited read alike: the year only when it isn't this one.
    private func stamp(_ date: Date) -> String {
        let thisYear = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year)
        return thisYear ? date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
                        : date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute())
    }

    private func automaticTemplateTitle(_ meeting: Meeting) -> String {
        guard let kind = meeting.summary?.kind, kind != .auto else { return "Automatic" }
        return "Automatic (\(kind.title))"
    }

    private func automaticPlacementTitle(_ meeting: Meeting) -> String {
        var automatic = meeting
        automatic.placement = nil
        switch automatic.effectivePlacement {
        case .work?: return "Work (automatic)"
        case .personal?: return "Personal (automatic)"
        case nil: return "Automatic"
        }
    }

    // MARK: People

    @ViewBuilder private func people(_ meeting: Meeting) -> some View {
        if meeting.speakers.isEmpty {
            Text("No speakers yet").foregroundStyle(PhoneStyle.Ink.secondary)
        } else {
            let total = max(1, meeting.speakers.map { talkTime($0.id, in: meeting) }.reduce(0, +))
            ForEach(Array(meeting.speakers.enumerated()), id: \.element.id) { index, speaker in
                let time = talkTime(speaker.id, in: meeting)
                SpeakerRow(name: speaker.name, ink: PhoneStyle.speakerInk(index), talkTime: time, share: time / total) { name in
                    library.renameSpeaker(speaker.id, to: name, in: meeting.id)
                } marker: {
                    SpeakerIdentityLine(library: library, meeting: meeting, speakerID: speaker.id)
                }
            }
        }
    }

    private func talkTime(_ id: String, in meeting: Meeting) -> TimeInterval {
        meeting.unifiedTranscript.filter { $0.speakerID == id }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    // MARK: Processing

    @ViewBuilder private func processing(_ meeting: Meeting) -> some View {
        if let run = meeting.transcripts.max(by: { $0.createdAt < $1.createdAt }) {
            LabeledContent("Transcribed") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ModelCatalog.builtIn.name(for: run.modelID, provenance: run.processingSettings?.model))
                    Text(run.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } else {
            LabeledContent("Transcribed", value: "Not yet")
        }
        LabeledContent("Speakers", value: meeting.speakers.compactMap(\.analysisSettings).first.map { ModelCatalog.builtIn.name(for: $0.modelID, provenance: $0.model) }
            ?? (meeting.speakers.isEmpty ? "Not identified" : "From the recordings"))
        if let summary = meeting.summary {
            LabeledContent("Summary") {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(ModelCatalog.builtIn.name(for: summary.modelID, provenance: summary.processingSettings?.model))
                    Text(summary.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        if let status = StatusPresentation.row(ProcessingStatus.phone(meeting), meeting: meeting) {
            LabeledContent("Now", value: status.text)
        }
        ReprocessMenu(library: library, meeting: meeting)
    }
}

/// A row's name with its symbol in the secondary ink: symbols in Info describe, they aren't actions.
private struct InfoLabel: View {
    let title: String
    let systemImage: String
    init(_ title: String, systemImage: String) { self.title = title; self.systemImage = systemImage }

    var body: some View {
        Label { Text(title) } icon: { InfoSymbol(systemImage) }
    }
}

private struct InfoSymbol: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View { Image(systemName: name).foregroundStyle(PhoneStyle.Ink.secondary) }
}

private enum PlacementChoice: Hashable {
    case automatic, work, personal
    init(_ placement: LibraryPlacement?) {
        switch placement {
        case .work?: self = .work
        case .personal?: self = .personal
        case nil: self = .automatic
        }
    }
    var placement: LibraryPlacement? {
        switch self {
        case .automatic: return nil
        case .work: return .work
        case .personal: return .personal
        }
    }
}

/// A speaker: their ink, their name (tap to rename), and how much of the talking they did; under the
/// name, what Daybook made of their voice (`SpeakerIdentityLine`).
private struct SpeakerRow<Marker: View>: View {
    let name: String
    let ink: Color
    let talkTime: TimeInterval
    let share: Double
    let save: (String) -> Void
    @ViewBuilder var marker: Marker
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            nameLine
            // Lined up with the name, past the ink dot.
            marker.padding(.leading, 20)
        }
    }

    private var nameLine: some View {
        HStack(spacing: 10) {
            Circle().fill(ink).frame(width: 10, height: 10).accessibilityHidden(true)
            TextField("Speaker", text: $draft)
                .foregroundStyle(ink)
                .fontWeight(.semibold)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
                .accessibilityLabel("Speaker name")
                .accessibilityHint("Edit to rename this speaker everywhere in the conversation.")
            Spacer(minLength: 8)
            Capsule().fill(Color.primary.opacity(0.08)).frame(width: 52, height: 5)
                .overlay(alignment: .leading) { Capsule().fill(ink).frame(width: max(5, 52 * share), height: 5) }
                .accessibilityLabel("\(Int((share * 100).rounded())) percent of the talking")
            Text(DurationLabel.format(talkTime)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 52, alignment: .trailing)
        }
        .onAppear { draft = name }
        .onChange(of: name) { _, value in if !focused { draft = value } }
    }

    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { draft = name } else if value != name { save(value) }
    }
}

/// Under a speaker, as on the Mac: a name Daybook gave by voice reads Recognized, with Not <name> to
/// take it back; a profile the voice resembles reads Maybe <name>, with Yes and No. Nothing for names
/// the person gave. The Mac acts on the answer when it arrives (it forgets what the profile learned
/// from a Not, and learns from a Yes).
private struct SpeakerIdentityLine: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    let speakerID: String

    var body: some View {
        if let identity = meeting.speakerIdentity(speakerID), identity.$source.isKnown,
           let profile = identity.profileID.flatMap({ library.metadata.speakerProfile($0) }) {
            switch identity.source {
            case .recognized:
                line {
                    Label("Recognized", systemImage: "waveform")
                    Spacer(minLength: 8)
                    answer("Not \(profile.name)") { library.rejectSpeakerProfile(speakerID, in: meeting.id) }
                }
            case .suggested:
                line {
                    Text("Maybe \(profile.name)")
                    Spacer(minLength: 8)
                    answer("Yes", label: "This is \(profile.name)") { library.confirmSpeakerProfile(speakerID, in: meeting.id) }
                    answer("No", label: "Not \(profile.name)") { library.rejectSpeakerProfile(speakerID, in: meeting.id) }
                }
            default:
                EmptyView()
            }
        }
    }

    private func line<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 4) { content() }
            .font(.footnote)
            .foregroundStyle(PhoneStyle.Ink.secondary)
            .labelStyle(CompactLabelStyle())
    }

    /// A text button with a 44 pt target that doesn't make the row taller (as `TagEditor`'s remove).
    private func answer(_ title: String, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(PhoneStyle.Ink.link)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .padding(.vertical, -12)
        .accessibilityLabel(label ?? title)
    }
}

/// A recording: where it came from, how long, whether its audio is on this iPhone, and how it was
/// lined up with the others.
private struct AudioSourceRow: View {
    let meeting: Meeting
    let track: RecordingTrack
    @Environment(\.audioProvider) private var provider
    @Environment(ReadingSession.self) private var session
    @State private var availability: AudioAvailability?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: SourceDescription.symbol(track)).foregroundStyle(.secondary).frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(SourceDescription.name(track, in: meeting)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(track.duration.map(TimeLabel.short) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                }
                if meeting.supersededLivePortions[track.id] != nil {
                    // Kept for playback; the recorder's own file is what's transcribed.
                    Text("Replaced by the full recording").font(.footnote).foregroundStyle(.secondary)
                } else if let line = SourceDescription.line(track, in: meeting) {
                    HStack(spacing: 4) {
                        if SourceDescription.isUnaligned(track, in: meeting) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(PhoneStyle.Ink.warning)
                        }
                        Text(line)
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                }
                if let availability {
                    Label(availabilityText(availability), systemImage: availabilitySymbol(availability))
                        .labelStyle(CompactLabelStyle())
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Button {
                session.player.play(.source(track, 0), in: meeting, provider: provider)
            } label: {
                Image(systemName: "play.circle.fill").font(.title2).symbolRenderingMode(.hierarchical).foregroundStyle(PhoneStyle.accent)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play this recording")
        }
        .accessibilityElement(children: .combine)
        .task(id: track.id) { availability = await provider.availability(of: track, in: meeting.id) }
    }

    private func availabilityText(_ availability: AudioAvailability) -> String {
        switch availability {
        case .local: return "On this iPhone"
        case .downloadable(let bytes?): return "In iCloud · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        case .downloadable(nil): return "In iCloud"
        case .offline: return "Not on this iPhone yet"
        case .missing: return "Not in the library on this iPhone"
        }
    }

    private func availabilitySymbol(_ availability: AudioAvailability) -> String {
        switch availability {
        case .local: return "iphone"
        case .downloadable: return "icloud.and.arrow.down"
        case .offline: return "icloud.slash"
        case .missing: return "questionmark.circle"
        }
    }
}

/// Tags as chips with a remove button, then a field for another.
struct TagEditor: View {
    let tags: [String]
    let save: ([String]) -> Void
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(tags, id: \.self) { tag in
                HStack(spacing: 4) {
                    Text(tag)
                    // A 44 pt target that doesn't make the chip taller.
                    Button { save(tags.filter { $0 != tag }) } label: {
                        Image(systemName: "xmark").font(.caption2.weight(.bold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                        .buttonStyle(.plain)
                        .padding(.vertical, -14)
                        .padding(.horizontal, -14)
                        .accessibilityLabel("Remove tag \(tag)")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(PhoneStyle.Ink.link)
                .padding(.leading, 10).padding(.trailing, 8).padding(.vertical, 4)
                .background(PhoneStyle.accent.opacity(0.14), in: Capsule())
            }
            TextField("Add Tag…", text: $draft)
                .font(.subheadline)
                .frame(minWidth: 90)
                .fixedSize()
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .onSubmit(commit)
        }
    }

    private func commit() {
        let tag = draft.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: " ")
        draft = ""
        guard !tag.isEmpty, !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        save(tags + [tag])
    }
}
