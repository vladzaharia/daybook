import AppKit
import DaybookCore
import DaybookKit
import SwiftUI

enum PlaybackTarget {
    /// A transcript passage, played from its original recording.
    case segment(TranscriptSegment)
    /// A time on the conversation's shared timeline.
    case timeline(Double)
    /// A time within one recording's own audio.
    case source(RecordingTrack, Double)
}

/// A photo open in the viewer.
struct PhotoViewerRequest: Identifiable, Equatable { let id: UUID }

/// A conversation: its page (Summary or Transcript), toolbar, and player.
struct MeetingDetailView: View {
    @ObservedObject var state: AppState
    let meetingID: UUID
    @State private var playbackRequest: Task<Void, Never>?
    @State private var viewingPhoto: PhotoViewerRequest?
    @AppStorage("isInspectorPresented") private var inspectorPresented = false
    @Environment(\.readingScale) private var scale

    private var meeting: Meeting? { state.meetings.first { $0.id == meetingID } }

    var body: some View {
        if let meeting {
            let mode: PageMode = meeting.unifiedTranscript.isEmpty ? .summary : state.pageMode
            Group {
                switch mode {
                case .summary: SummaryPage(state: state, player: state.playback, meeting: meeting, play: play)
                case .transcript: TranscriptPage(state: state, player: state.playback, meeting: meeting, play: play)
                }
            }
            .transition(.opacity)
            .animation(.easeOut(duration: 0.15), value: mode)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(DaybookStyle.paper)
            .bottomBar {
                PlayerBar(state: state, player: state.playback, meeting: meeting) { play($0) }
            }
            .onDisappear {
                playbackRequest?.cancel()
                if state.playback.meetingID == meetingID { state.playback.unload() }
            }
            .environment(\.openPhoto) { viewingPhoto = PhotoViewerRequest(id: $0.id) }
            .sheet(item: $viewingPhoto) { request in PhotoViewer(state: state, meetingID: meetingID, photoID: request.id, play: play) }
            .modifier(PhotoDropTarget(state: state, meetingID: meetingID))
            // Photos synced from another device, or added before the models were here, are read when seen.
            .task(id: "\(meetingID):\(meeting.visiblePhotos.filter { $0.analysis == nil }.map(\.id)):\(state.photoModel?.description ?? "vision"):\(state.recordingID?.uuidString ?? "idle")") {
                state.readPhotosWhenIdle(meetingID)
                #if DEBUG
                if PhotoDemo.opensPhoto, viewingPhoto == nil, meeting.visiblePhotos.allSatisfy({ $0.analysis != nil }), let first = meeting.visiblePhotos.first {
                    try? await Task.sleep(for: .milliseconds(600))
                    viewingPhoto = PhotoViewerRequest(id: first.id)
                }
                #endif
            }
        }
    }

    private func play(_ target: PlaybackTarget) {
        guard let meeting, !state.isRecording else { return }
        switch target {
        case .segment(let segment):
            guard let track = meeting.tracks.first(where: { $0.id == segment.trackID }) else { return }
            let originalTime = segment.provenance.first { $0.trackID == track.id }?.start ?? max(0, segment.start - (track.offset ?? 0))
            requestPlayback(track, at: originalTime)
        case .timeline(let seconds):
            if let position = MeetingPlaybackPosition.resolve(seconds, in: meeting), let track = meeting.tracks.first(where: { $0.id == position.trackID }) {
                requestPlayback(track, at: position.seconds)
            } else if let track = meeting.tracks.first {
                requestPlayback(track, at: max(0, seconds - (track.offset ?? 0)))
            }
        case .source(let track, let seconds):
            requestPlayback(track, at: seconds)
        }
    }

    private func requestPlayback(_ track: RecordingTrack, at seconds: Double) {
        playbackRequest?.cancel()
        playbackRequest = Task {
            guard let url = await state.audioURL(for: track, meetingID: meetingID), !Task.isCancelled,
                  state.selectedID == meetingID || state.place.isDevice else { return }
            withAnimation(.snappy(duration: 0.25)) { state.playback.play(url: url, at: seconds, trackID: track.id, meetingID: meetingID) }
        }
    }
}

// MARK: - Toolbar

/// The detail toolbar, declared once on the window's stable detail column: Record, then
/// [view switch · More], then the inspector toggle. The groups never come and go: what doesn't
/// apply is dimmed, so Record stays under the pointer from one conversation to the next.
struct DetailToolbar: ToolbarContent {
    @ObservedObject var state: AppState
    let meeting: Meeting?
    @Binding var inspectorPresented: Bool

    var body: some ToolbarContent {
        RecordToolbarItem(state: state)
        if !state.place.isDevice || state.isSearching || meeting != nil {
            if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            conversationItems(meeting)
        }
    }

    @ToolbarContentBuilder
    private func conversationItems(_ meeting: Meeting?) -> some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if let meeting, state.recordingID == meeting.id {
                Button { state.addHighlight(meeting.id) } label: {
                    Label("Bookmark", systemImage: "bookmark")
                        .symbolEffect(.bounce, value: meeting.highlights.count)
                }
                .help("Add Bookmark (⌘D)")
            } else {
                let hasTranscript = meeting.map { !$0.unifiedTranscript.isEmpty } ?? false
                Picker("View", selection: hasTranscript ? $state.pageMode : .constant(.summary)) {
                    ForEach(PageMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!hasTranscript)
                .help(hasTranscript ? "Show the summary (⌘1) or the transcript (⌘2)"
                      : meeting == nil ? "Choose a conversation" : "Not transcribed yet")
            }
            Menu {
                if let meeting { ConversationMoreMenu(state: state, meeting: meeting) }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .disabled(meeting == nil)
            .help("More")
        }
        if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
        ToolbarItem(placement: .primaryAction) {
            Button { withAnimation { inspectorPresented.toggle() } } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                .disabled(meeting == nil)
                .help(inspectorPresented ? "Hide Inspector (⌃⌘I)" : "Show Inspector (⌃⌘I)")
        }
    }
}

/// The conversation's More menu: share, add, reprocess, history, then file actions.
struct ConversationMoreMenu: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    private var locked: Bool { state.recordingID == meeting.id || state.processingID == meeting.id || state.isStartingRecording || state.isStoppingRecording }
    var body: some View {
        Button("Copy Summary") { state.copySummary(meeting.id) }.disabled(meeting.summary == nil)
        Menu("Export") {
            Button("Markdown…") { state.export(meeting.id) }
            Button("Full Data (JSON)…") { state.export(meeting.id, json: true) }
        }
        Divider()
        Button("Show Floating Notes") { state.showNotes(for: meeting.id) }
        Menu("Add Recording") {
            Button("From a File…") { state.chooseImport(attachTo: meeting.id) }
            AddRecordingFromDeviceItems(state: state)
        }
        .disabled(locked)
        Button("Add Photo…") { state.chooseAddPhoto(to: meeting.id) }
        ReprocessMenu(state: state, meeting: meeting)
        Button("Version History…") { state.activeSheet = .versionHistory }.disabled(meeting.revisions.isEmpty)
        Divider()
        Button("Show in Finder") { state.showInFinder(meeting.id) }
        Button("Move to Trash…", role: .destructive) { state.trashRequestID = meeting.id }.disabled(locked)
    }
}

struct ReprocessMenu: View {
    @ObservedObject var state: AppState
    let meeting: Meeting
    var body: some View {
        Menu("Reprocess") {
            if meeting.hasUntranscribedAudio { Button("Transcribe Now") { state.enqueue(meeting.id, mode: .newAudio) } }
            Button("Summarize Again") { state.enqueue(meeting.id, mode: .summaryOnly) }.disabled(meeting.unifiedTranscript.isEmpty)
            Button("Identify Speakers Again") { state.enqueue(meeting.id, mode: .speakerRefresh) }.disabled(meeting.transcripts.isEmpty)
            Button("Transcribe Everything Again") { state.enqueue(meeting.id, mode: .fullRetranscription) }
        }
        .disabled(meeting.tracks.isEmpty || state.recordingID == meeting.id || state.processingID == meeting.id || state.queuedIDs.contains(meeting.id))
    }
}

// MARK: - Player

/// One glass capsule pinned to the bottom of the page, shown once something plays.
private struct PlayerBar: View {
    @ObservedObject var state: AppState
    @ObservedObject var player: AudioPlaybackController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    private static let rates: [Float] = [0.75, 1, 1.25, 1.5, 2]

    private var visible: Bool { player.meetingID == meeting.id && (player.duration > 0 || player.errorMessage != nil) }

    var body: some View {
        if visible {
            GlassGroup {
                VStack(spacing: 2) {
                    if let error = player.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Ink.warning)
                    }
                    if player.duration > 0 { controls }
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .frame(maxWidth: DaybookStyle.measure)
                .glassSurface(in: Capsule())
            }
            .padding(.horizontal, Space.s5).padding(.bottom, Space.s3)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var caption: String? {
        guard meeting.tracks.count > 1, let track = meeting.tracks.first(where: { $0.id == player.trackID }) else { return nil }
        return track.source == .imported ? track.fileName : track.source.recordingName
    }

    private var controls: some View {
        HStack(spacing: 10) {
            SkipButton(symbol: "gobackward.15", help: "Back 15 Seconds (⌥⌘←)") { withAnimation(Motion.state) { player.skip(-15) } }
                .accessibilityLabel("Back 15 seconds")
            Button { player.toggle() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DaybookStyle.onPlayFill)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(DaybookStyle.playFill))
                    .neonGlow(player.isPlaying ? DaybookStyle.neonMint : .clear, radius: 5)
            }
            .buttonStyle(.plain)
            .disabled(state.isRecording)
            .opacity(state.isRecording ? 0.4 : 1)
            .help(state.isRecording ? "Playback is off while recording" : "Play or Pause")
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            SkipButton(symbol: "goforward.15", help: "Forward 15 Seconds (⌥⌘→)") { withAnimation(Motion.state) { player.skip(15) } }
                .accessibilityLabel("Forward 15 seconds")
            VStack(spacing: 0) {
                if let caption { Text(caption).font(.system(size: 10)).foregroundStyle(Ink.secondary).lineLimit(1) }
                HStack(spacing: 8) {
                    // Equal widths either side keep the slider centred.
                    Text(TimeLabel.short(player.position)).frame(minWidth: 44, alignment: .trailing)
                        .contentTransition(.numericText(value: player.position))
                    Slider(value: Binding(get: { player.position }, set: { player.seek(to: $0) }), in: 0...max(1, player.duration))
                        .controlSize(.mini)
                        .tint(DaybookStyle.neonMint)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue("\(SpokenTime.format(player.position)) of \(SpokenTime.format(player.duration))")
                    Text("−" + TimeLabel.short(max(0, player.duration - player.position))).frame(minWidth: 44, alignment: .leading)
                }
                .font(.system(size: 11).monospacedDigit())
                // Explicit inks, not vibrant hierarchy styles: the glass under them adapts to the paper.
                .foregroundStyle(Ink.secondary)
            }
            Menu {
                Picker("Speed", selection: $player.rate) {
                    ForEach(Self.rates, id: \.self) { rate in Text(rate.formatted() + "×").tag(rate) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(player.rate.formatted() + "×").font(.system(size: 11, weight: .medium).monospacedDigit())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DaybookStyle.quietFill, in: Capsule())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Playback Speed")
            Button {
                if let trackID = player.trackID { state.addPlaybackHighlight(meeting.id, trackID: trackID, seconds: player.position) }
            } label: { Image(systemName: "bookmark") }
                .help("Add Bookmark at This Moment").accessibilityLabel("Add bookmark")
            Button { withAnimation(.snappy(duration: 0.25)) { player.unload() } } label: { Image(systemName: "xmark") }
                .help("Close Player").accessibilityLabel("Close player")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Ink.body)
        .imageScale(.medium)
    }
}

/// A quiet skip control that brightens on hover.
private struct SkipButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.borderless)
            .foregroundStyle(hovering ? Ink.body : Ink.secondary)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
            .help(help)
    }
}
