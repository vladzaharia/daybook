import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

/// The evidence behind the page: who said what, with your notes and bookmarks at their times.
///
/// The page doesn't observe the player, which publishes its position ten times a second: it keeps
/// the passage under the playhead in its own state and redraws when that passage changes. Blocks,
/// bookmark marks, and the playhead index are worked out once per version of the conversation
/// (`TranscriptLayout`).
struct TranscriptPage: View {
    @ObservedObject var state: AppState
    let player: AudioPlaybackController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    @State private var editing: UUID?
    @State private var draft = ""
    @State private var lastUserScroll = Date.distantPast
    @State private var followSuspended = false
    @State private var playing: UUID?
    @State private var isPlaying = false
    @State private var playerShown = false
    @Environment(\.readingScale) private var scale

    var body: some View {
        let layout = TranscriptLayout.cached(for: meeting)
        let marks = layout.marks
        ScrollViewReader { proxy in
            PageScroll(lazy: true, bottomInset: playerShown ? 56 : 0) {
                PageHeader(state: state, player: player, meeting: meeting, play: play)
                notices
                if meeting.unifiedTranscript.isEmpty {
                    MarginRow {
                        Text(meeting.tracks.isEmpty ? "No transcript yet." : meeting.status == .failed ? "No speech was found in this recording." : "Not transcribed yet.")
                            .font(TypeStyle.status).foregroundStyle(Ink.secondary)
                    }
                    .padding(.top, Space.s5)
                }
                ForEach(layout.blocks) { block in
                    switch block {
                    case .turn(_, let speakerID, let segments):
                        TurnView(state: state, meeting: meeting, speakerID: speakerID, segments: segments, playingID: playing,
                                    marks: marks, editing: $editing, draft: $draft, play: play)
                            .padding(.top, Space.s5)
                    case .note(let note):
                        NoteBlock(note: note) { play(.timeline(note.time ?? 0)) } open: { state.pageMode = .summary }
                            .padding(.top, Space.s3)
                    case .photo(let photo, let time):
                        TranscriptPhotoBlock(state: state, meeting: meeting, photo: photo, time: time) { play(.timeline(time)) }
                            .padding(.top, Space.s3)
                    }
                }
            }
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating {
                    lastUserScroll = Date()
                    if isPlaying { followSuspended = true }
                }
            }
            .overlay(alignment: .topTrailing) {
                if followSuspended && isPlaying, let playing {
                    Button {
                        lastUserScroll = .distantPast
                        followSuspended = false
                        withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(playing, anchor: UnitPoint(x: 0, y: 0.33)) }
                    } label: {
                        Label("Back to Playing", systemImage: "arrow.down.to.line")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Ink.link)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, Space.s3).padding(.trailing, Space.s4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .motion(Motion.state, value: followSuspended)
            .onAppear { scrollToTarget(proxy) }
            .onChange(of: state.pageScrollTarget) { _, _ in scrollToTarget(proxy) }
            .onChange(of: playing) { _, id in
                // Follow playback only while the person isn't reading elsewhere.
                guard let id, isPlaying else { return }
                if Date().timeIntervalSince(lastUserScroll) > 5 { followSuspended = false }
                guard !followSuspended else { return }
                withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(id, anchor: UnitPoint(x: 0, y: 0.33)) }
            }
        }
        .onReceive(player.objectWillChange.receive(on: RunLoop.main)) { _ in followPlayhead(layout) }
        .onAppear { followPlayhead(layout) }
        .onChange(of: meeting) { _, _ in followPlayhead(TranscriptLayout.cached(for: meeting)) }
    }

    @ViewBuilder private var notices: some View {
        let unaligned = meeting.alignmentReports.filter { $0.method == .unaligned }
        if let report = unaligned.first {
            let name = meeting.tracks.first { $0.id == report.trackID }?.source.recordingName ?? "added"
            notice(symbol: "exclamationmark.triangle.fill", tint: Ink.warning,
                   text: "Couldn’t line up the \(name) recording with the others.",
                   action: "Adjust Timing…") { state.activeSheet = .adjustTiming(report.trackID) }
        }
        if let issues = meeting.correctionTransferIssues, !issues.isEmpty {
            notice(symbol: "pencil.line", tint: Ink.secondary,
                   text: issues.count == 1 ? "An earlier correction needs a look." : "\(issues.count) earlier corrections need a look.",
                   action: "Review…") { state.activeSheet = .reviewCorrections }
        }
    }

    private func notice(symbol: String, tint: Color, text: String, action: String, perform: @escaping () -> Void) -> some View {
        MarginRow {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                Spacer(minLength: Space.s3)
                Button(action, action: perform).buttonStyle(.daybookLink).fixedSize()
            }
            .font(TypeStyle.status)
            .padding(Space.s3)
            .quietBox()
        }
        .padding(.top, Space.s4)
    }

    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = state.pageScrollTarget else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(target, anchor: UnitPoint(x: 0, y: 0.33))
            state.pageScrollTarget = nil
        }
    }

    /// The passage under the playhead, in the recording that is playing; state changes only when it does.
    private func followPlayhead(_ layout: TranscriptLayout) {
        let here = player.meetingID == meeting.id && player.duration > 0
        let id = here ? player.trackID.flatMap { layout.playhead.segmentID(at: player.position, trackID: $0) } : nil
        if id != playing { playing = id }
        if (here && player.isPlaying) != isPlaying { isPlaying = here && player.isPlaying }
        if here != playerShown { playerShown = here }
    }
}

private struct TurnView: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let speakerID: String?
    let segments: [TranscriptSegment]
    let playingID: UUID?
    let marks: BookmarkMarks
    @Binding var editing: UUID?
    @Binding var draft: String
    let play: (PlaybackTarget) -> Void
    @State private var renaming = false
    @Environment(\.readingScale) private var scale

    private var name: String { meeting.speakerName(speakerID) ?? "Unknown speaker" }
    private var ink: Color { DaybookStyle.speakerInk(meeting.speakerIndex(speakerID)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MarginRow {
                if let first = segments.first { MarginTime(time: first.start) { play(.segment(first)) } }
            } content: {
                Button(name) { if speakerID != nil { renaming = true } }
                    .buttonStyle(.plain)
                    .font(TypeStyle.speaker(scale))
                    .foregroundStyle(ink)
                    .help(speakerID == nil ? "" : "Rename this speaker")
                    .popover(isPresented: $renaming, arrowEdge: .bottom) {
                        if let speakerID { RenameSpeakerPopover(name: name) { new in state.update(meeting.id) { $0.renameSpeaker(id: speakerID, name: new) } } }
                    }
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 2)
            }
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if editing == segment.id {
                    PassageEditor(text: $draft) {
                        state.update(meeting.id) { $0.correctSegment(id: segment.id, text: draft) }
                        editing = nil
                    } cancel: { editing = nil }
                } else {
                    Passage(state: state, meeting: meeting, segment: segment, showsTime: index > 0, isPlaying: playingID == segment.id,
                            bookmarks: marks.bookmarksBySegment[segment.id] ?? [],
                            holder: marks.holders.contains(segment.id),
                            label: marks.labelSegments[segment.id], play: play,
                            correct: { draft = segment.text; editing = segment.id },
                            rename: speakerID == nil ? nil : { renaming = true })
                }
            }
        }
    }
}

private struct Passage: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    let segment: TranscriptSegment
    let showsTime: Bool
    let isPlaying: Bool
    let bookmarks: [Highlight]
    let holder: Bool
    let label: String?
    let play: (PlaybackTarget) -> Void
    let correct: () -> Void
    let rename: (() -> Void)?
    @State private var hovering = false
    @State private var showingSources = false
    @Environment(\.readingScale) private var scale
    @Environment(\.colorSchemeContrast) private var contrast

    private var corrected: Bool { meeting.revisions.contains { $0.field == "segment:\(segment.id.uuidString)" } }

    var body: some View {
        MarginRow(gutterDot: corrected ? DaybookStyle.accent : nil) {
            if !bookmarks.isEmpty {
                Image(systemName: "bookmark.fill").font(.system(size: 9 * scale)).foregroundStyle(DaybookStyle.bookmark)
                    .neonGlow(DaybookStyle.bookmark, radius: 3)
                    .frame(width: 8)
                    .help(bookmarks.map { $0.text.isEmpty ? "Bookmark" : $0.text }.joined(separator: "\n"))
                    .accessibilityLabel("Bookmark")
            }
            // A turn's first passage already has its time above it; a bookmark there shows the glyph alone.
            if showsTime {
                MarginTime(time: segment.start, alwaysVisible: hovering || !bookmarks.isEmpty) { play(.segment(segment)) }
            }
        } content: {
            VStack(alignment: .leading, spacing: 2) {
                if let label {
                    Text(label).font(TypeStyle.speaker(scale)).foregroundStyle(DaybookStyle.bookmark)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(highlighted)
                        .font(TypeStyle.body(scale))
                        .foregroundStyle(Ink.body)
                        .lineSpacing(TypeStyle.bodyLineSpacing(scale))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if segment.provenance.count > 1 {
                        Button { showingSources = true } label: { Image(systemName: "square.on.square").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundStyle(Ink.meta)
                            .help("Heard in \(segment.provenance.count) recordings")
                            .popover(isPresented: $showingSources) { HeardInRecordings(meeting: meeting, segment: segment, play: play) }
                    }
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(background, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .leading) {
                // The playhead and a bookmark share one rule, centred in the gutter between time and text
                // (x = −4, where a corrected passage's dot sits), so neither touches the time.
                if isPlaying {
                    Capsule().fill(DaybookStyle.neonMint).frame(width: 3)
                        .neonGlow(DaybookStyle.neonMint, radius: 4)
                        .offset(x: 0.5)
                        .transition(.opacity)
                } else if holder {
                    Capsule().fill(DaybookStyle.bookmark).frame(width: 2).offset(x: 1)
                }
            }
            .padding(.horizontal, -6)
        }
        .id(segment.id)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: correct)
        .animation(.easeOut(duration: 0.2), value: isPlaying)
        .contextMenu {
            Button("Play from Here") { play(.segment(segment)) }
                .disabled(state.isRecording)
            Button("Copy") { LocalPasteboard.copy(segment.text) }
            Divider()
            Button("Correct Passage…", action: correct)
            if let rename { Button("Rename Speaker…", action: rename) }
            Divider()
            Button("Add Bookmark Here") {
                let start = segment.provenance.first { $0.trackID == segment.trackID }?.start ?? segment.start
                state.addPlaybackHighlight(meeting.id, trackID: segment.trackID, seconds: start)
            }
            if segment.provenance.count > 1 { Button("Heard in Recordings…") { showingSources = true } }
        }
    }

    private var background: Color {
        isPlaying && contrast != .increased ? DaybookStyle.neonMint.opacity(0.10) : .clear
    }

    /// Matches for the current library search, marked with the system find highlight.
    private var highlighted: AttributedString { FindHighlight.mark(AttributedString(segment.text), query: state.search) }
}

private struct PassageEditor: View {
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.readingScale) private var scale
    var body: some View {
        MarginRow {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Passage", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(TypeStyle.body(scale))
                    .foregroundStyle(Ink.body)
                    .lineSpacing(TypeStyle.bodyLineSpacing(scale))
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(DaybookStyle.accent, lineWidth: 1.5))
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand(perform: cancel)
                    .accessibilityLabel("Corrected passage")
                Text("Return to save · Esc to cancel")
                    .font(TypeStyle.colophon).foregroundStyle(Ink.meta)
            }
        }
        .onAppear { focused = true }
    }
}

private struct NoteBlock: View {
    let note: TimedNote
    let play: () -> Void
    let open: () -> Void
    @Environment(\.readingScale) private var scale
    @State private var hovering = false
    var body: some View {
        MarginRow {
            MarginTime(time: note.time ?? 0, play: play)
        } content: {
            // Built like a passage, so your words start on the transcript's edge and the teal rule
            // hangs where the playhead and bookmark rules hang.
            Text(note.text)
                .font(TypeStyle.body(scale))
                .foregroundStyle(Ink.body)
                .lineSpacing(TypeStyle.bodyLineSpacing(scale))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(DaybookStyle.accent.opacity(hovering ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(alignment: .leading) { Capsule().fill(DaybookStyle.accent).frame(width: 2).offset(x: 1) }
                .padding(.horizontal, -6)
                .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .onTapGesture(perform: open)
            .help("Your note. Click to see it on the Summary.")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your note at \(SpokenTime.format(note.time ?? 0)): \(note.text)")
        }
    }
}

private struct HeardInRecordings: View {
    let meeting: Meeting
    let segment: TranscriptSegment
    let play: (PlaybackTarget) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heard in \(segment.provenance.count) recordings").font(.headline)
            ForEach(Array(segment.provenance.enumerated()), id: \.offset) { _, source in
                let track = meeting.tracks.first { $0.id == source.trackID }
                VStack(alignment: .leading, spacing: 3) {
                    Button {
                        if let track { play(.source(track, source.start)) }
                    } label: {
                        Label("\(track?.source.recordingName ?? "Recording") · \(TimeLabel.short(source.start))", systemImage: "play.fill")
                    }
                    .buttonStyle(.daybookLink)
                    Text("“\(source.text)”").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}

struct RenameSpeakerPopover: View {
    let name: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: $draft).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit(commit)
            Text("Changes every passage by \(name) in this conversation.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit).keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 252)
        .onAppear { draft = name }
    }
    private func commit() {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        save(value); dismiss()
    }
}
