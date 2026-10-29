import DaybookCore
import DaybookIntelligence
import DaybookKit
import SwiftUI

/// Properties of the selected conversation, kept out of the page: where it's filed, who spoke,
/// its recordings, and how it was processed.
struct MeetingInspector: View {
    @ObservedObject var state: AppState
    let meetingID: UUID
    @AppStorage("inspector.details") private var detailsExpanded = true
    @AppStorage("inspector.people") private var peopleExpanded = true
    @AppStorage("inspector.audio") private var audioExpanded = false
    @AppStorage("inspector.processing") private var processingExpanded = false

    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let meeting {
            Form {
                Section("Details", isExpanded: $detailsExpanded) { details(meeting) }
                // Notes alone have no speakers and nothing processed: those sections wait for audio.
                if !meeting.tracks.isEmpty || !meeting.speakers.isEmpty {
                    Section("People", isExpanded: $peopleExpanded) { people(meeting) }
                }
                Section("Audio", isExpanded: $audioExpanded) { audio(meeting) }
                if !meeting.tracks.isEmpty || !meeting.revisions.isEmpty {
                    Section("Processing", isExpanded: $processingExpanded) { processing(meeting) }
                }
            }
            .formStyle(.grouped)
            .controlSize(.small)
            .labeledContentStyle(SecondaryLabelStyle())
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.trailing")
        }
    }

    @ViewBuilder private func details(_ meeting: Meeting) -> some View {
        Picker("Folder", selection: Binding(get: { meeting.folderID }, set: { folder in state.moveToFolder([meeting.id], folder) })) {
            Text("None").tag(UUID?.none)
            if !state.folders.isEmpty { Divider() }
            ForEach(state.folders) { folder in Text(folder.name).tag(UUID?.some(folder.id)) }
        }
        // Like Finder's Get Info: the label, then chips starting on the label's edge.
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").foregroundStyle(.secondary)
            TagEditor(tags: meeting.tags ?? [], save: { state.setTags(meeting.id, text: $0.joined(separator: ",")) },
                      showTag: { tag in state.searchTokens = [.tag(tag)] }, alignment: .leading)
        }
        Picker("Shows in", selection: Binding(get: { meeting.placement.map(PlacementChoice.init) ?? .automatic }, set: { choice in
            state.setPlacement([meeting.id], choice.placement)
        })) {
            Text(automaticPlacementTitle(meeting)).tag(PlacementChoice.automatic)
            Divider()
            Text("Work").tag(PlacementChoice.work)
            Text("Personal").tag(PlacementChoice.personal)
        }
        Picker("Template", selection: state.templateSelection(for: meeting.id)) {
            Text(automaticTemplateTitle(meeting)).tag("auto")
            Divider()
            ForEach(state.templates.filter(\.isBuiltIn)) { template in Text(template.name).tag(template.id) }
            let custom = state.templates.filter { !$0.isBuiltIn }
            if !custom.isEmpty {
                Divider()
                ForEach(custom) { template in Text(template.name).tag(template.id) }
            }
        }
        LabeledContent("Created", value: meeting.date.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
        LabeledContent("Edited", value: meeting.updatedAt.formatted(.dateTime.day().month(.abbreviated).hour().minute()))
    }

    /// The guess folds into the first item, "Automatic (Meeting)", so the row needs no caption.
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

    @ViewBuilder private func people(_ meeting: Meeting) -> some View {
        if meeting.speakers.isEmpty {
            Text("No speakers yet").foregroundStyle(.secondary)
        } else {
            let total = max(1, meeting.speakers.map { talkTime($0.id, in: meeting) }.reduce(0, +))
            ForEach(Array(meeting.speakers.enumerated()), id: \.element.id) { index, speaker in
                let time = talkTime(speaker.id, in: meeting)
                SpeakerRow(name: speaker.name, ink: DaybookStyle.speakerInk(index), talkTime: time, share: time / total) { name in
                    state.update(meeting.id) { $0.renameSpeaker(id: speaker.id, name: name) }
                }
            }
        }
    }

    private func talkTime(_ id: String, in meeting: Meeting) -> TimeInterval {
        meeting.unifiedTranscript.filter { $0.speakerID == id }.reduce(0) { $0 + max(0, $1.end - $1.start) }
    }

    @ViewBuilder private func audio(_ meeting: Meeting) -> some View {
        ForEach(meeting.tracks) { track in
            AudioRow(state: state, meeting: meeting, track: track)
        }
        if meeting.tracks.isEmpty { Text("No recordings yet").foregroundStyle(.secondary) }
        SourceHooks(state: state, meeting: meeting)
        Menu("Add Recording") {
            Button("From a File…") { state.chooseImport(attachTo: meeting.id) }
            AddRecordingFromDeviceItems(state: state)
            Button("Record on This Mac") { Task { await state.startRecording(into: meeting.id) } }
                .disabled(state.isRecording || !state.canRecordInto(meeting.id))
        }
        .menuStyle(.button)
        .fixedSize()
        .disabled(state.processingID == meeting.id || state.recordingID == meeting.id)
    }

    @ViewBuilder private func processing(_ meeting: Meeting) -> some View {
        if let run = meeting.transcripts.max(by: { $0.createdAt < $1.createdAt }) {
            LabeledContent("Transcribed", value: state.modelCatalog.name(for: run.modelID, provenance: run.processingSettings?.model))
                .help(run.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        // Which model found the speakers; "Not identified" only for a transcript that has none.
        if let model = speakerModel(meeting) {
            LabeledContent("Speakers", value: model)
        } else if !meeting.transcripts.isEmpty && meeting.speakers.isEmpty {
            LabeledContent("Speakers", value: "Not identified")
        }
        if let summary = meeting.summary {
            LabeledContent("Summary", value: state.modelCatalog.name(for: summary.modelID, provenance: summary.processingSettings?.model))
                .help(summary.createdAt.formatted(date: .abbreviated, time: .shortened))
        }
        HStack {
            if !meeting.tracks.isEmpty { ReprocessMenu(state: state, meeting: meeting).fixedSize() }
            Spacer()
            if !meeting.revisions.isEmpty { Button("Version History…") { state.activeSheet = .versionHistory } }
        }
    }

    private func speakerModel(_ meeting: Meeting) -> String? {
        meeting.speakers.compactMap(\.analysisSettings).first.map { state.modelCatalog.name(for: $0.modelID, provenance: $0.model) }
    }
}

private enum PlacementChoice: Hashable {
    case automatic, work, personal
    init(_ placement: LibraryPlacement) { self = placement == .work ? .work : .personal }
    var placement: LibraryPlacement? {
        switch self {
        case .automatic: return nil
        case .work: return .work
        case .personal: return .personal
        }
    }
}

private struct SpeakerRow: View {
    let name: String
    let ink: Color
    let talkTime: TimeInterval
    let share: Double
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(ink).frame(width: 8, height: 8).accessibilityHidden(true)
            TextField("Speaker", text: $draft)
                .textFieldStyle(.plain)
                .labelsHidden()
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, active in if !active { commit() } }
            Spacer()
            Capsule().fill(Color.primary.opacity(0.08)).frame(width: 44, height: 4)
                .overlay(alignment: .leading) { Capsule().fill(ink).frame(width: max(4, 44 * share), height: 4) }
                .accessibilityLabel("\(Int(share * 100)) percent of the talking")
            Text(DurationLabel.format(talkTime)).foregroundStyle(.secondary).monospacedDigit().frame(minWidth: 44, alignment: .trailing)
        }
        .help("Click to rename")
        .onAppear { draft = name }
        .onChange(of: name) { _, value in if !focused { draft = value } }
    }
    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { draft = name } else if value != name { save(value) }
    }
}

private struct AudioRow: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let track: RecordingTrack

    private var name: String {
        if track.source == .imported { return track.fileName }
        if track.derivedFrom != nil { return "\(track.source.recordingName), \(RecordingTrack.processingName(track.processing))" }
        if meeting.tracks.contains(where: { $0.derivedFrom == track.id }) { return "\(track.source.recordingName), original" }
        return track.source.recordingName
    }
    private var alignment: TrackAlignment? { meeting.alignmentReports.first { $0.trackID == track.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: track.source.systemImage).foregroundStyle(.secondary).frame(width: 16)
                Text(name).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(track.duration.map(TimeLabel.short) ?? "—").foregroundStyle(.secondary).monospacedDigit()
                Button { playThis() } label: {
                    Image(systemName: "play.circle.fill").font(.system(size: 15)).symbolRenderingMode(.hierarchical).foregroundStyle(DaybookStyle.accent)
                }
                    .buttonStyle(.borderless)
                    .disabled(state.isRecording)
                    .help("Play this recording")
                    .accessibilityLabel("Play \(name)")
                Menu {
                    Button("Play", action: playThis).disabled(state.isRecording)
                    Divider()
                    Button("Adjust Timing…") { state.activeSheet = .adjustTiming(track.id) }.disabled(meeting.tracks.count < 2)
                    Button("Show Original Transcript…") { state.activeSheet = .originalTranscript(track.id) }
                        .disabled(!meeting.transcripts.contains { $0.trackID == track.id })
                    Divider()
                    Button("Show in Finder") { state.showInFinder(meeting.id) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                    .help("More")
                    .accessibilityLabel("More for \(name)")
            }
            HStack(spacing: 4) {
                if alignment?.method == .unaligned {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Ink.warning)
                    Text("Couldn’t line up")
                    Button("Adjust Timing…") { state.activeSheet = .adjustTiming(track.id) }
                        .buttonStyle(.daybookLink)
                } else {
                    Text(timingLine)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 22)
        }
    }

    private var timingLine: String { "\(state.sourceRole(track, in: meeting)) · \(state.sourceTimingLine(track, in: meeting))" }

    private func playThis() {
        guard !state.isRecording else { return }
        Task {
            guard let url = await state.audioURL(for: track, meetingID: meeting.id) else { return }
            withAnimation(.snappy(duration: 0.25)) { state.playback.play(url: url, at: 0, trackID: track.id, meetingID: meeting.id) }
        }
    }
}

/// Inspector labels recede so the values lead.
private struct SecondaryLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        LabeledContent {
            configuration.content
        } label: {
            configuration.label.foregroundStyle(.secondary)
        }
    }
}
