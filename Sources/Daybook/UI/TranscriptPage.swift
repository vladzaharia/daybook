import AppKit
import DaybookCore
import DaybookKit
import DaybookUI
import SwiftUI

// The Mac's transcript is DaybookUI's `TranscriptPage` (docs/interface.md, "Geometry"), the same page the iPhone
// draws, over this Mac's library, its player, and its sheets. The page doesn't read the player in its body: it follows
// it apart and redraws when the passage under the playhead changes.

extension TranscriptPage where Header == MacTranscriptHeader, Placeholder == EmptyView {
    /// The transcript of a conversation on this Mac. A jump asked for elsewhere (a search hit, a photo's moment, a
    /// summary line's evidence: `AppState.pageScrollTarget`) moves the page once and is then cleared.
    init(state: AppState, player: AudioPlaybackController, meeting: Meeting, play: @escaping (PlaybackTarget) -> Void) {
        self.init(meeting: meeting,
                  host: .mac(state: state, player: player, meetingID: meeting.id, play: play),
                  findQuery: state.search,
                  find: ConversationFind.window,
                  scrollRequest: state.pageScrollTarget.map { TranscriptScrollRequest(target: $0.uuidString, token: $0.hashValue) },
                  scrolled: { state.pageScrollTarget = nil },
                  playerInset: 56) {
            MacTranscriptHeader(state: state, player: player, meeting: meeting, play: play)
        }
    }
}

/// The title and byline, then the same status line as the summary page, so turning the page keeps them in view.
struct MacTranscriptHeader: View {
    let state: AppState
    let player: AudioPlaybackController
    let meeting: Meeting
    let play: (PlaybackTarget) -> Void
    @Environment(\.readingWidth) private var readingWidth

    var body: some View {
        Group {
            PageHeader(state: state, player: player, meeting: meeting, play: play)
            ConversationStatus(state: state, meeting: meeting)
        }
        // The page's own rows fold their times inline on a narrow page; these do too.
        .environment(\.pageIsNarrow, readingWidth == .narrow)
    }
}

extension TranscriptHost {
    /// This Mac's: its library, its player (nothing plays while it records), Audio's names for recordings, and the
    /// window's sheets. Correct Passage on a narrow page is the page's own sheet.
    @MainActor
    static func mac(state: AppState, player: AudioPlaybackController, meetingID: UUID, play: @escaping (PlaybackTarget) -> Void) -> TranscriptHost {
        TranscriptHost(
            library: state.library,
            playhead: {
                guard player.meetingID == meetingID, player.duration > 0, let trackID = player.trackID else { return nil }
                return TranscriptPlayhead(trackID: trackID, position: player.position, isPlaying: player.isPlaying)
            },
            play: play,
            canPlay: { !state.isRecording },
            recordingName: { state.recordingName($0, in: $1) },
            present: { sheet in
                switch sheet {
                case .correct: return false
                case .reviewCorrections: state.activeSheet = .reviewCorrections
                case .adjustTiming(let id): state.activeSheet = .adjustTiming(id)
                case .originalTranscript(let id): state.activeSheet = .originalTranscript(id)
                }
                return true
            },
            showNotes: {
                SummaryJump.window.show(SummaryJump.notes, in: meetingID)
                state.pageMode = .summary
            },
            photos: .mac(state: state, play: play))
    }
}

/// A block of the summary page to bring into view, asked for from elsewhere: Show in Your Notes on the transcript. The
/// summary page moves to it once (`summaryJumps(in:)`), as the iPhone's does for `ReadingSession.showOnSummary`.
@MainActor @Observable
final class SummaryJump {
    /// The library window's: one window, one conversation page.
    static let window = SummaryJump()
    /// The "Your notes" heading, under the summary.
    static let notes = "notes"

    /// Bumped by each request.
    private(set) var token = 0
    @ObservationIgnored private var pending: (target: String, meetingID: UUID)?

    func show(_ target: String, in meetingID: UUID) {
        pending = (target, meetingID)
        token += 1
    }

    /// The block for this conversation's summary page, once. Taking clears the request, and a request made for another
    /// conversation is dropped: the person has moved on from it.
    func take(for meetingID: UUID) -> String? {
        defer { pending = nil }
        return pending?.meetingID == meetingID ? pending?.target : nil
    }
}

extension View {
    /// Around a conversation's summary page, its scroll view inside: moves to the block `SummaryJump` asks for, by the
    /// `.id` it carries, once the page has laid out. The page has just opened, so it opens there.
    func summaryJumps(in meetingID: UUID) -> some View {
        modifier(SummaryJumps(meetingID: meetingID))
    }
}

private struct SummaryJumps: ViewModifier {
    let meetingID: UUID

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .onAppear { jump(proxy) }
                .onChange(of: SummaryJump.window.token) { jump(proxy) }
        }
    }

    private func jump(_ proxy: ScrollViewProxy) {
        guard let target = SummaryJump.window.take(for: meetingID) else { return }
        // The blocks are there on the next turn of the main queue, once the page has laid out.
        Task { @MainActor in proxy.scrollTo(target, anchor: .top) }
    }
}

extension ConversationFind {
    /// The library window's Find in Conversation: one window, one conversation page, so one find, which the page and
    /// the Edit menu's items share (`ConversationFindCommands`).
    @MainActor static let window = ConversationFind()
}

/// Edit › Find in Conversation… (⌘F), Find Next (⌘G), and Find Previous (⇧⌘G), for the conversation on the page. The
/// transcript's own keys answer first while it shows; from the summary, Find in Conversation turns to the transcript.
struct ConversationFindCommands: Commands {
    let state: AppState
    @FocusedValue(\.shownConversation) private var shown

    private var meeting: Meeting? { shown.flatMap { id in state.meetings.first { $0.id == id } } }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in Conversation…") {
                guard let meeting else { return }
                state.pageMode = .transcript
                ConversationFind.window.show(in: meeting.id)
            }
            .keyboardShortcut("f")
            .disabled(meeting?.unifiedTranscript.isEmpty != false)
            Button("Find Next") { find(ConversationFind.window.next) }
                .keyboardShortcut("g")
                .disabled(meeting?.unifiedTranscript.isEmpty != false)
            Button("Find Previous") { find(ConversationFind.window.previous) }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(meeting?.unifiedTranscript.isEmpty != false)
        }
    }

    /// Steps when Find shows; otherwise opens it on the transcript, as Find in Conversation does.
    private func find(_ step: () -> Void) {
        guard let meeting else { return }
        if ConversationFind.window.isShown, state.pageMode == .transcript { return step() }
        state.pageMode = .transcript
        ConversationFind.window.show(in: meeting.id)
    }
}
