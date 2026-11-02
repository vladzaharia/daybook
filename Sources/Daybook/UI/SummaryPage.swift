import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

/// The default page: what happened, what's next, the template's sections, then your own notes, and how the page was
/// made. The blocks are DaybookUI's, the same as the iPhone's page (`SummaryBody`, `YourNotes`, `Colophon`); this Mac
/// gives them its notes editor, photos, captions, and player.
struct SummaryPage: View {
    let state: AppState
    let player: AudioPlaybackController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    /// The summary present when the page opened. Any later one arrived while the page was on screen,
    /// so it's revealed block by block; opening a page never animates.
    @State private var openedWith: Date?
    @Environment(\.readingScale) private var scale
    @Environment(\.pageIsNarrow) private var narrow

    init(state: AppState, player: AudioPlaybackController, meeting: Meeting, play: @escaping (PlaybackTarget) -> Void) {
        self.state = state; self.player = player; self.meeting = meeting; self.play = play
        _openedWith = State(initialValue: meeting.summary?.createdAt)
    }

    private var isRecording: Bool { state.recordingID == meeting.id }
    private var passages: PassageLinks { PassageLinks { [state] in state.showPassage($0) } }

    var body: some View {
        PageScroll(bottomInset: player.meetingID == meeting.id && player.duration > 0 ? 56 : 0) {
            PageHeader(state: state, player: player, meeting: meeting, play: play)
            ConversationStatus(state: state, meeting: meeting)
            if let summary = meeting.summary {
                SummaryBody(meeting: meeting, summary: summary, library: state.library, query: state.search,
                            revealing: summary.createdAt != openedWith, passages: passages) { section in
                    let pictures = meeting.photos(in: section)
                    if !pictures.isEmpty { SectionPhotos(state: state, meeting: meeting, photos: pictures) }
                }
                .id(summary.createdAt)
                // Summarize Again: the old summary steps back while the new one is written (not while it counts down).
                .opacity(meeting.status == .summarizing && state.placements[meeting.id]?.deadline == nil ? 0.5 : 1)
                .daybookTransition(.opacity)
            } else if meeting.tracks.isEmpty && !isRecording {
                // The byline already says "Notes only"; this line offers the ways to add audio.
                MarginRow {
                    HStack(spacing: Space.s4) {
                        Button("Record") { Task { await state.startRecording(into: meeting.id) } }
                            .disabled(state.isRecording || state.isStartingRecording)
                            .help("Record into this conversation")
                        Button("Add Recording…") { state.chooseImport(attachTo: meeting.id) }
                    }
                    .buttonStyle(.daybookLink)
                    .font(TypeStyle.status)
                }
                .padding(.top, Space.s5)
            }
            NotesSection(state: state, meeting: meeting, play: play, passages: passages)
                .padding(.top, meeting.summary == nil ? Space.s5 : Space.s2)
            // Every photo, in the order taken; the summary's sections show the ones they illustrate.
            PhotoStrip(state: state, meeting: meeting)
            // Tentative captions while recording; after the notes, so arriving words never move what
            // you're typing. Once saved, they read on the transcript's page.
            LiveCaptionsSection(captions: state.captions, meeting: meeting, isRecording: isRecording)
            // How the page was made, once there is a summary; never while recording. A transcript without a summary
            // says so in its status, with Summarize.
            if !isRecording, let summary = meeting.summary {
                PageColophon(state: state, meeting: meeting, summary: summary)
            }
        }
        .environment(\.findQuery, state.search)
        .macReadingContext(state)
        .daybookMotion(Motion.page, value: meeting.summary?.createdAt)
        .daybookMotion(Motion.dim, value: meeting.status == .summarizing)
    }
}

/// Your words with their recording times, then your bookmarks: DaybookUI's `YourNotes` around this Mac's notes editor.
private struct NotesSection: View {
    let state: AppState
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    let passages: PassageLinks
    @Environment(\.readingScale) private var scale
    @Environment(\.pageIsNarrow) private var narrow

    private var isRecording: Bool { state.recordingID == meeting.id }

    var body: some View {
        // Each non-empty paragraph's time, matched to the saved anchors by text; nil where there is none.
        let times = meeting.paragraphTimes()
        YourNotes(meeting: meeting, library: state.library, canPlay: !meeting.tracks.isEmpty && !state.isRecording, play: play,
                  passages: passages) {
            MarginNotesEditor(
                text: Binding(get: { meeting.notes }, set: { state.editNotes(meeting.id, text: $0) }),
                times: times,
                placeholder: "Add a note…",
                fontSize: 14 * scale, lineSpacing: 5 * scale,
                // Narrow, the times keep a lane as the bookmarks and Floating Notes do, rather than disappearing.
                margin: narrow ? (times.contains { $0 != nil } ? FloatingLayout.textLeading : 0) : DaybookStyle.margin,
                focusOnAppear: isRecording && meeting.notes.isEmpty,
                playTime: state.isRecording ? nil : { play(.timeline($0)) })
        }
        .contentShape(Rectangle())
    }
}

/// How the page was made, at its foot: DaybookUI's `Colophon`, with the template menu and Summarize Again.
private struct PageColophon: View {
    let state: AppState
    let meeting: Meeting
    let summary: MeetingSummary

    var body: some View {
        let origin = summary.origin
        let deviceClass = origin.deviceID.flatMap { id in state.syncDevices.first { $0.id == id }?.deviceClass }
        Colophon(SummaryColophon(summary, thisDeviceID: state.library.thisDevice.id, words: state.statusWords,
                                 catalog: state.modelCatalog, deviceClass: deviceClass),
                 arrived: summary.createdAt, template: templateTitle, summarizeAgain: summarizeAgain) {
            TemplateMenuItems(state: state, meetingID: meeting.id)
        }
    }

    /// Only while it can be asked for: work on the conversation already shows in its status.
    private var summarizeAgain: (() -> Void)? {
        guard !meeting.unifiedTranscript.isEmpty, !state.processingStatus(for: meeting).isPending,
              state.recordingID != meeting.id else { return nil }
        return { [state, id = meeting.id] in state.enqueue(id, mode: .summaryOnly) }
    }

    private var templateTitle: String {
        if let template = state.resolvedTemplate(for: meeting) { return template.name }
        // The inspector's words for the same choice.
        if let kind = meeting.summary?.kind, kind != .auto { return "Automatic (\(kind.title))" }
        return "Automatic"
    }
}
