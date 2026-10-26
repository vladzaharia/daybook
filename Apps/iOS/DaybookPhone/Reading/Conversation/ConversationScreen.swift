import DaybookCaptions
import DaybookKit
import SwiftUI

/// One column: the conversation with a Summary | Transcript switch, the player at the thumb.
struct ConversationScreen: View {
    @ObservedObject var library: LibraryController
    let id: UUID
    @Environment(ReadingSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.liveCaptionStore) private var captionStore
    @State private var hasCaptions = false

    var body: some View {
        @Bindable var session = session
        if let meeting = library.meeting(id) {
            // Saved live captions open the Transcript side until the Mac's transcript arrives.
            let hasTranscript = !meeting.unifiedTranscript.isEmpty || hasCaptions
            let mode: PageMode = hasTranscript ? session.pageMode : .summary
            Group {
                switch mode {
                case .summary: SummaryPage(library: library, meeting: meeting)
                case .transcript: TranscriptPage(library: library, player: session.player, meeting: meeting)
                }
            }
            .transition(.opacity)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: mode)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                PlayerBar(player: session.player, library: library, meeting: meeting)
            }
            .motion(.snappy(duration: 0.25), value: session.player.isActive(for: meeting.id))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Page", selection: hasTranscript ? $session.pageMode : .constant(.summary)) {
                        ForEach(PageMode.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                    .disabled(!hasTranscript)
                    .accessibilityHint(hasTranscript ? "" : "Not transcribed yet")
                }
                ConversationToolbar(library: library, meeting: meeting)
            }
            .task(id: "\(meeting.id)-\(meeting.showsLiveCaptions)") {
                hasCaptions = SavedCaptions.shown(captionStore?.captions(for: meeting.id), for: meeting) != nil
            }
        } else {
            ContentUnavailableView("Conversation Not Found", systemImage: "doc.questionmark")
                .paperBackground()
        }
    }
}

/// Info and More, the same in every layout.
struct ConversationToolbar: ToolbarContent {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { session.sheet = .info(meeting.id) } label: { Label("Info", systemImage: "info.circle") }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                ConversationMoreMenu(library: library, meeting: meeting)
            } label: {
                Label("More", systemImage: "ellipsis")
            }
        }
    }
}

/// The conversation's More menu: share, ask your Mac, history, then filing.
struct ConversationMoreMenu: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session

    var body: some View {
        if CameraPicker.isAvailable {
            Button { session.cameraFor = meeting.id } label: { Label("Take Photo", systemImage: "camera") }
        }
        Button { session.sheet = .importPhotos(meeting.id) } label: { Label("Add Photos…", systemImage: "photo.badge.plus") }
        ExportMenu(meeting: meeting)
        if meeting.summary != nil {
            Button { LocalPasteboard.copy(MeetingExport.summaryMarkdown(meeting)) } label: {
                Label("Copy Summary", systemImage: "doc.on.doc")
            }
        }
        Divider()
        ReprocessMenu(library: library, meeting: meeting)
        Button { session.sheet = .history(meeting.id) } label: { Label("Version History", systemImage: "clock.arrow.circlepath") }
            .disabled(meeting.revisions.isEmpty)
        Divider()
        Button { session.sheet = .move([meeting.id]) } label: { Label("Move to Folder…", systemImage: "folder") }
        Button { session.sheet = .tags([meeting.id]) } label: { Label("Tags…", systemImage: "tag") }
        let personal = meeting.effectivePlacement == .personal
        Button { library.setPlacement([meeting.id], personal ? .work : .personal) } label: {
            Label(personal ? "Move to Work" : "Move to Personal", systemImage: personal ? "briefcase" : "house")
        }
        Divider()
        Button(role: .destructive) {
            Task {
                if (try? await library.moveToTrash(meeting.id)) == true { session.forget(meeting.id) }
            }
        } label: { Label("Move to Trash", systemImage: "trash") }
    }
}

/// Processing your Mac carries out. Each item writes a request; the page then says it's waiting.
struct ReprocessMenu: View {
    @ObservedObject var library: LibraryController
    let meeting: Meeting

    var body: some View {
        Menu {
            Section("Your Mac does this") {
                if meeting.hasUntranscribedAudio {
                    Button { request(.newAudio) } label: { Label("Transcribe", systemImage: "waveform") }
                }
                Button { request(.summaryOnly) } label: { Label("Summarize Again", systemImage: "text.alignleft") }
                    .disabled(meeting.unifiedTranscript.isEmpty)
                Button { request(.speakerRefresh) } label: { Label("Identify Speakers Again", systemImage: "person.2") }
                    .disabled(meeting.transcripts.isEmpty)
                Button { request(.fullRetranscription) } label: { Label("Transcribe Everything Again", systemImage: "arrow.clockwise") }
            }
        } label: {
            Label("Reprocess", systemImage: "laptopcomputer")
        }
        .disabled(meeting.tracks.isEmpty || ProcessingStatus(meeting).isPending)
    }

    private func request(_ mode: ProcessingRequest.Mode) {
        library.requestProcessing(meeting.id, mode: mode)
    }
}

/// Share › Markdown or the audio, through the share sheet.
struct ExportMenu: View {
    let meeting: Meeting
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider

    var body: some View {
        Menu {
            Button { shareMarkdown() } label: { Label("Markdown", systemImage: "doc.richtext") }
            Button { shareAudio() } label: { Label("Audio", systemImage: "waveform") }
                .disabled(meeting.tracks.isEmpty)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
    }

    private func shareMarkdown() {
        Task {
            do {
                var originals: [UUID: URL] = [:]
                for photo in meeting.visiblePhotos { originals[photo.id] = try await provider.localPhoto(for: photo, in: meeting.id) }
                let files = originals
                let url = try await Task.detached { try ExportFiles.markdownWithPhotos(meeting, originals: files) }.value
                session.sheet = .share([url])
            } catch { session.alert = "The Markdown couldn’t be prepared: \(error.localizedDescription)" }
        }
    }

    private func shareAudio() {
        guard let track = meeting.transcribableTracks.first ?? meeting.tracks.first else { return }
        let meeting = meeting
        Task { @MainActor in
            do {
                let url = try await provider.localAudio(for: track, in: meeting.id) { _ in }
                session.sheet = .share([try ExportFiles.audio(url, meeting: meeting, track: track)])
            } catch {
                session.alert = error.localizedDescription
            }
        }
    }
}
