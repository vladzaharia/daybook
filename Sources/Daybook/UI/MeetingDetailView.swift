import AppKit
import DaybookCore
import SwiftUI

struct MeetingDetailView: View {
    @ObservedObject var state: AppState
    let meetingID: UUID
    @State private var tab = DetailTab.summary
    @State private var editingSegment: UUID?
    @State private var editedText = ""
    @State private var playbackTrackID: UUID?
    @State private var playbackRequest: Task<Void, Never>?
    @StateObject private var player = AudioPlaybackController()
    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }
    var body: some View {
        if let meeting {
            VStack(alignment: .leading, spacing: 0) {
                header(meeting)
                HStack(spacing: 20) {
                    ForEach(DetailTab.allCases) { item in
                        Button { tab = item } label: {
                            VStack(spacing: 10) {
                                Text(item.rawValue).font(.callout.weight(tab == item ? .semibold : .regular))
                                Capsule().fill(tab == item ? DaybookStyle.accent : .clear).frame(height: 2)
                            }.fixedSize(horizontal: true, vertical: false)
                        }.buttonStyle(.plain).foregroundStyle(tab == item ? .primary : .secondary)
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 30).padding(.top, 20)
                Divider()
                if state.processingID == meeting.id {
                    HStack(spacing: 12) {
                        ProgressView(value: state.processingProgress.fraction).frame(width: 80)
                        Text(state.processingProgress.message).font(.caption).lineLimit(2)
                        Spacer()
                        Button("Pause") { state.cancelProcessing() }.controlSize(.small)
                    }.padding(14).background(DaybookStyle.accent.opacity(0.06))
                }
                if let error = meeting.errorMessage {
                    Label(error, systemImage: meeting.status == .failed ? "exclamationmark.circle" : "info.circle")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 30).padding(.vertical, 12)
                }
                Group {
                    switch tab {
                    case .summary: summaryView(meeting)
                    case .transcript: transcriptView(meeting)
                    case .notes: notesView(meeting)
                    case .sources: sourcesView(meeting)
                    case .history: historyView(meeting)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if player.duration > 0 { playbackBar }
                if let error = player.errorMessage { Text(error).font(.caption).foregroundStyle(.red).padding(14) }
            }
            .onDisappear { playbackRequest?.cancel(); player.stop() }
        }
    }

    private func header(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(meeting.date.formatted(date: .long, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Export Markdown…") { state.export(meeting.id) }
                    Button("Export full JSON…") { state.export(meeting.id, json: true) }
                    Button("Show library in Finder") { NSWorkspace.shared.open(AppState.libraryURL) }
                    Divider()
                    Button("Move conversation to Trash", role: .destructive) { state.trashMeeting(meeting.id) }
                        .disabled(state.recordingID == meeting.id || state.processingID == meeting.id || state.isStartingRecording || state.isStoppingRecording)
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
            }
            TextField("Conversation title", text: Binding(get: { self.meeting?.title ?? "" }, set: { title in state.update(meeting.id) { $0.title = title } }))
                .font(.system(size: 28, weight: .medium, design: .serif)).textFieldStyle(.plain)
            HStack(spacing: 12) {
                Picker("Template", selection: Binding(get: { self.meeting?.templateID ?? (self.meeting?.kind == .auto ? "auto" : state.resolvedTemplate(for: meeting)?.id ?? "auto") }, set: { id in
                    state.update(meeting.id) { value in
                        value.templateID = id == "auto" ? nil : id
                        value.kind = state.templates.first { $0.id == id }?.kind ?? .auto
                    }
                })) {
                    Text("Automatic").tag("auto")
                    ForEach(state.templates) { template in Text(template.name).tag(template.id) }
                }.labelsHidden().frame(maxWidth: 220).help("Choose a note format, or let the local model identify the conversation type.")
                Text("\(meeting.tracks.count) source\(meeting.tracks.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 10) {
                Button { state.chooseImport(attachTo: meeting.id) } label: { Label("Add audio", systemImage: "plus") }
                    .disabled(state.processingID == meeting.id || state.recordingID == meeting.id)
                Button { state.showNotes(for: meeting.id) } label: { Label("Notes window", systemImage: "sidebar.right") }
                Spacer()
                Button {
                    let hasNew = meeting.tracks.contains { track in !meeting.transcripts.contains { $0.trackID == track.id } }
                    state.enqueue(meeting.id, mode: hasNew ? .newAudio : .summaryOnly)
                } label: {
                    Label(meeting.summary == nil ? "Process" : "Refresh summary", systemImage: "sparkles")
                }.buttonStyle(.borderedProminent)
                    .disabled(meeting.tracks.isEmpty || state.processingID == meeting.id || state.recordingID == meeting.id || state.queuedIDs.contains(meeting.id))
                Menu {
                    ForEach(ProcessingRequest.Mode.allCases) { mode in
                        Button(mode.title) { state.enqueue(meeting.id, mode: mode) }
                    }
                } label: { Image(systemName: "chevron.down") }
                    .menuStyle(.borderlessButton).fixedSize().help("Processing options")
                    .disabled(meeting.tracks.isEmpty || state.processingID == meeting.id || state.recordingID == meeting.id || state.queuedIDs.contains(meeting.id))
            }.controlSize(.small).padding(.top, 5)
            HStack {
                Picker("Folder", selection: Binding(get: { self.meeting?.folderID }, set: { folder in state.update(meeting.id) { $0.folderID = folder } })) {
                    Text("Unfiled").tag(Optional<UUID>.none)
                    ForEach(state.folders) { folder in Text(folder.name).tag(Optional(folder.id)) }
                }.frame(maxWidth: 210)
                TagsEditor(tags: meeting.tags ?? []) { state.setTags(meeting.id, text: $0) }
            }.controlSize(.small)
        }.padding(.horizontal, 30).padding(.top, 26)
    }

    @ViewBuilder private func summaryView(_ meeting: Meeting) -> some View {
        if let summary = meeting.summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(spacing: 6) { Image(systemName: "sparkles"); Text("ENHANCED NOTES").tracking(1.4) }.font(.system(size: 10, weight: .semibold)).foregroundStyle(DaybookStyle.accent)
                    if !meeting.highlights.isEmpty { highlightedContext(meeting) }
                    Text(summary.overview).font(.system(size: 15)).lineSpacing(6).textSelection(.enabled)
                    ForEach(summary.sections) { section in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(section.heading).font(.title3.weight(.semibold))
                            Text(.init(section.body)).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                        }
                    }
                    if !summary.actionItems.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Next steps").font(.title3.weight(.semibold))
                            ForEach(summary.actionItems) { action in
                                Toggle(isOn: Binding(get: { self.meeting?.summary?.actionItems.first { $0.id == action.id }?.completed ?? false }, set: { complete in
                                    state.update(meeting.id) { value in
                                        guard let index = value.summary?.actionItems.firstIndex(where: { $0.id == action.id }) else { return }
                                        value.summary?.actionItems[index].completed = complete
                                    }
                                })) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(action.text).strikethrough(action.completed).textSelection(.enabled)
                                        if let owner = action.owner { Text(owner).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }.toggleStyle(.checkbox)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(DaybookStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                    }
                    Divider()
                    Text("Generated locally with \(summary.modelID) · \(summary.createdAt.formatted(date: .abbreviated, time: .shortened))\nReview the transcript to check details. Your original notes are in My notes.")
                        .font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                }.padding(30)
            }
        } else {
            ContentUnavailableView {
                Label("A little context goes a long way", systemImage: "sparkles")
            } description: {
                Text(meeting.tracks.isEmpty ? "Record or import a conversation, then add the notes you want Daybook to keep in mind." : "Your audio is saved. Process it to create a transcript and notes using local models.")
            } actions: { Button("Write a note") { tab = .notes } }
        }
    }

    private func notesView(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Write what matters to you. New lines written during recording keep their original timestamps and guide the summary.").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { self.meeting?.notes ?? "" }, set: { state.editNotes(meeting.id, text: $0) }))
                .font(.system(size: 15)).lineSpacing(6).scrollContentBackground(.hidden)
                .frame(minHeight: 240)
                .accessibilityLabel("Meeting notes")
            if !meeting.highlights.isEmpty {
                Divider()
                Text("Marked moments").font(.headline)
                ForEach(meeting.highlights) { highlight in
                    HStack(alignment: .top) {
                        Text(TimeLabel.format(highlight.time)).monospacedDigit().foregroundStyle(.secondary)
                        TextField("What stood out?", text: Binding(get: { self.meeting?.highlights.first { $0.id == highlight.id }?.text ?? "" }, set: { text in
                            state.update(meeting.id) { value in if let index = value.highlights.firstIndex(where: { $0.id == highlight.id }) { value.highlights[index].text = text } }
                        })).textFieldStyle(.plain)
                    }.font(.callout)
                }
            }
            HStack { Label("Saved on this Mac", systemImage: "checkmark.circle"); Spacer(); Button("Mark a moment") { state.addHighlight(meeting.id) }.disabled(state.recordingID != meeting.id) }.font(.caption).foregroundStyle(.secondary)
        }.padding(30)
    }

    private func transcriptView(_ meeting: Meeting) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if meeting.unifiedTranscript.isEmpty {
                    ContentUnavailableView("The conversation, in words", systemImage: "text.alignleft", description: Text("Process a recording to see the transcript here."))
                }
                if meeting.alignmentReports.contains(where: { $0.method == .unaligned }) {
                    Label("Some sources could not be aligned. Their transcripts remain in Sources and are excluded from the summary until aligned.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(DaybookStyle.gold).padding(12).background(DaybookStyle.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                if let issues = meeting.correctionTransferIssues, !issues.isEmpty { correctionReview(issues, meeting: meeting) }
                ForEach(MeetingTimelineItem.items(in: meeting)) { item in
                    switch item {
                    case .note(let note):
                        annotation(note.text, at: note.time ?? 0, title: "YOUR NOTE", symbol: "square.and.pencil", in: meeting)
                    case .highlight(let highlight, let time):
                        annotation(highlight.text, at: time, title: "MARKED MOMENT", symbol: "bookmark.fill", in: meeting)
                    case .speech(let segment):
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Button(TimeLabel.format(segment.start)) { play(segment, in: meeting) }.font(.caption.monospacedDigit()).buttonStyle(.plain).foregroundStyle(DaybookStyle.accent)
                            if let id = segment.speakerID, let speaker = meeting.speakers.first(where: { $0.id == id }) {
                                TextField("Speaker", text: Binding(get: { self.meeting?.speakers.first { $0.id == id }?.name ?? speaker.name }, set: { name in state.update(meeting.id) { $0.renameSpeaker(id: id, name: name) } }))
                                    .font(.callout.weight(.semibold)).textFieldStyle(.plain).frame(maxWidth: 180)
                            } else { Text("Unknown speaker").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            if segment.provenance.count > 1 { Label("\(segment.provenance.count) sources", systemImage: "link").font(.caption2).foregroundStyle(.secondary) }
                            Button { editingSegment = segment.id; editedText = segment.text } label: { Image(systemName: "pencil") }.buttonStyle(.plain).foregroundStyle(.tertiary).help("Correct transcript")
                        }
                        if editingSegment == segment.id {
                            TextEditor(text: $editedText).font(.body).frame(minHeight: 90).border(.quaternary)
                            HStack { Button("Save correction") { state.update(meeting.id) { $0.correctSegment(id: segment.id, text: editedText) }; editingSegment = nil }; Button("Cancel") { editingSegment = nil } }
                        } else { Text(segment.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled) }
                    }
                    }
                }
            }.padding(30)
        }
    }

    private func sourcesView(_ meeting: Meeting) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Original audio stays intact. Add a Soundcore recording of this conversation to align and combine the transcripts.").font(.callout).foregroundStyle(.secondary)
                ForEach(meeting.tracks) { track in
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top) {
                            Image(systemName: track.source == .systemAudio ? "desktopcomputer" : "waveform").foregroundStyle(DaybookStyle.accent).font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(track.fileName).font(.headline).textSelection(.enabled)
                                Text("\(track.source.title) · \(TimeLabel.format(track.duration ?? 0))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { requestPlayback(track, at: 0, meetingID: meeting.id) } label: { Image(systemName: "play.fill") }.help("Play original audio")
                        }
                        if let report = meeting.alignmentReports.first(where: { $0.trackID == track.id }) {
                            Text(report.explanation).font(.caption).foregroundStyle(report.method == .unaligned ? DaybookStyle.gold : .secondary)
                        }
                        TrackOffsetEditor(offset: track.offset) { state.setOffset(meeting.id, trackID: track.id, seconds: $0) }
                        if let transcript = meeting.transcripts.filter({ $0.trackID == track.id }).max(by: { $0.createdAt < $1.createdAt }) {
                            Text("Latest run: \(transcript.modelID) · \(meeting.transcripts.filter { $0.trackID == track.id }.count) saved run(s)").font(.caption).foregroundStyle(.secondary)
                            DisclosureGroup("Original transcript · \(transcript.segments.count) passages") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(transcript.segments) { segment in
                                        HStack(alignment: .top) {
                                            Text(TimeLabel.format(segment.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            Text(segment.text).font(.callout).textSelection(.enabled)
                                        }
                                    }
                                }.padding(.top, 12)
                            }.font(.callout)
                        }
                    }.padding(18).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
                }
                if meeting.tracks.isEmpty { ContentUnavailableView("Bring the conversation here", systemImage: "waveform", description: Text("Import an MP3, M4A, WAV, or other audio file.")) }
            }.padding(30)
        }
    }

    private func historyView(_ meeting: Meeting) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                if meeting.revisions.isEmpty { ContentUnavailableView("Room to refine", systemImage: "clock.arrow.circlepath", description: Text("Note edits, transcript corrections, speaker names, and earlier summaries are kept here.")) }
                ForEach(meeting.revisions.reversed()) { revision in
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Before").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(revision.oldValue.isEmpty ? "(empty)" : revision.oldValue).font(.callout).textSelection(.enabled)
                            Text("After").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(revision.newValue.isEmpty ? "(empty)" : revision.newValue).font(.callout).textSelection(.enabled)
                        }.padding(.vertical, 10)
                    } label: {
                        HStack { Text(revision.field.split(separator: ":").first.map(String.init)?.capitalized ?? "Edit"); Spacer(); Text(revision.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                    }
                    Divider()
                }
            }.padding(30)
        }
    }

    private func annotation(_ text: String, at time: Double, title: String, symbol: String, in meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol).font(.system(size: 10, weight: .semibold)).tracking(1)
                Spacer()
                Button(TimeLabel.format(time)) { playTimeline(time, in: meeting) }.buttonStyle(.plain).font(.caption.monospacedDigit())
            }.foregroundStyle(DaybookStyle.gold)
            Text(text).font(.callout).textSelection(.enabled)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(DaybookStyle.gold.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }

    private func highlightedContext(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Marked moments", systemImage: "bookmark.fill").font(.headline).foregroundStyle(DaybookStyle.gold)
            Text("These passages receive extra attention in the summary. Expand to check the original discussion.").font(.caption).foregroundStyle(.secondary)
            ForEach(meeting.highlightContexts()) { context in
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(context.sourceName + (context.isAligned ? " · meeting timeline" : " · source time; not aligned")).font(.caption).foregroundStyle(.secondary)
                        if context.speechContext.isEmpty { Text("No transcribed context is available yet.").font(.caption) }
                        ForEach(context.speechContext) { segment in
                            HStack(alignment: .top) {
                                Button(TimeLabel.format(segment.start)) {
                                    if context.isAligned { play(segment, in: meeting) }
                                    else if let track = meeting.tracks.first(where: { $0.id == context.highlight.trackID }) { requestPlayback(track, at: segment.start, meetingID: meeting.id) }
                                }.buttonStyle(.plain).foregroundStyle(DaybookStyle.accent).font(.caption.monospacedDigit())
                                Text(segment.text).font(.callout).textSelection(.enabled)
                            }
                        }
                    }.padding(.top, 10)
                } label: {
                    Text("[\(TimeLabel.format(context.markerTime))] \(context.highlight.text.isEmpty ? "Highlighted discussion" : context.highlight.text)").font(.callout.weight(.medium))
                }
            }
        }.padding(18).background(DaybookStyle.gold.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
    }

    private func correctionReview(_ issues: [CorrectionTransferIssue], meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Review earlier corrections", systemImage: "exclamationmark.bubble").font(.headline)
            Text("The new transcript changed these passages. Choose where each correction belongs; the earlier text stays in History.").font(.caption)
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 6) {
                    Text(issue.originalSegment.text).font(.callout).textSelection(.enabled)
                    Text(issue.reason).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Menu("Apply to passage…") {
                            ForEach(meeting.unifiedTranscript) { segment in
                                Button("[\(TimeLabel.format(segment.start))] \(String(segment.text.prefix(70)))") { state.update(meeting.id) { $0.resolveCorrectionTransfer(id: issue.id, targetSegmentID: segment.id) } }
                            }
                        }
                        Button("Keep only in History") { state.update(meeting.id) { $0.resolveCorrectionTransfer(id: issue.id, targetSegmentID: nil) } }
                    }.controlSize(.small)
                }
            }
        }.padding(16).background(DaybookStyle.gold.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func playTimeline(_ seconds: Double, in meeting: Meeting) {
        guard let position = MeetingPlaybackPosition.resolve(seconds, in: meeting), let track = meeting.tracks.first(where: { $0.id == position.trackID }) else { return }
        requestPlayback(track, at: position.seconds, meetingID: meeting.id)
    }

    private var playbackBar: some View {
        VStack(spacing: 4) {
            Divider()
            HStack {
                Button { if player.isPlaying { player.pause() } else { player.resume() } } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill") }.buttonStyle(.plain)
                Text(TimeLabel.format(player.position)).font(.caption.monospacedDigit())
                Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                Text(TimeLabel.format(player.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Button {
                    if let trackID = playbackTrackID { state.addPlaybackHighlight(meetingID, trackID: trackID, seconds: player.position) }
                } label: { Image(systemName: "bookmark") }.buttonStyle(.plain).help("Highlight this point in the source recording")
                Button { player.stop() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }.padding(14)
        }
    }

    private func play(_ segment: TranscriptSegment, in meeting: Meeting) {
        guard let track = meeting.tracks.first(where: { $0.id == segment.trackID }) else { return }
        let originalTime = segment.provenance.first { $0.trackID == track.id }?.start ?? max(0, segment.start - (track.offset ?? 0))
        requestPlayback(track, at: originalTime, meetingID: meeting.id)
    }
    private func requestPlayback(_ track: RecordingTrack, at seconds: Double, meetingID: UUID) {
        playbackRequest?.cancel()
        playbackRequest = Task {
            guard let url = await state.audioURL(for: track, meetingID: meetingID), !Task.isCancelled,
                  state.selectedID == meetingID else { return }
            playbackTrackID = track.id
            player.play(url: url, at: seconds)
        }
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case summary = "Summary", transcript = "Transcript", notes = "My notes", sources = "Sources", history = "History"
    var id: String { rawValue }
}

private struct TrackOffsetEditor: View {
    let offset: Double?
    let save: (Double?) -> Void
    @State private var draft = ""
    var body: some View {
        HStack {
            Text("Timeline offset").font(.caption).foregroundStyle(.secondary)
            TextField("Auto", text: $draft).frame(width: 70).textFieldStyle(.roundedBorder)
            Text("seconds").font(.caption).foregroundStyle(.secondary)
            Button("Apply") { save(Double(draft)) }.controlSize(.small).disabled(!draft.isEmpty && Double(draft)?.isFinite != true)
            Button("Auto") { draft = ""; save(nil) }.controlSize(.small)
        }.onAppear { draft = offset.map { String(format: "%.3f", $0) } ?? "" }
            .help("Seconds from the meeting start when this source began. Leave blank for automatic alignment. Negative offsets are allowed.")
    }
}

private struct TagsEditor: View {
    let tags: [String]
    let save: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "number").foregroundStyle(.secondary)
            TextField("Tags, separated by commas", text: $draft).textFieldStyle(.plain).focused($focused)
                .onSubmit { save(draft) }
        }.onAppear { draft = tags.joined(separator: ", ") }
            .onChange(of: focused) { _, active in if !active { save(draft) } }
            .onChange(of: tags) { _, values in if !focused { draft = values.joined(separator: ", ") } }
            .onDisappear { save(draft) }
    }
}
