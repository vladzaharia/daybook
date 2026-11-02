import DaybookCaptions
import DaybookDevices
import DaybookKit
import DaybookUI
import SwiftUI

// The iPhone's transcript is DaybookUI's `TranscriptPage`, the same page the Mac draws, over this iPhone's library, its
// player, and its reading session. Saved live captions read on it by the Mac's rule (`SavedCaptions`): in the
// transcript's place before it arrives, else after an earlier recording's transcript. Without either, a calm empty page.

/// The transcript's page on the iPhone: one column's Transcript side, or the right page of the open Duo. A tap plays
/// from a passage; Correct Passage… opens its sheet; playback follows along until the person scrolls away.
struct PhoneTranscriptPage: View {
    let library: LibraryController
    /// Not read in the page's body: the page follows it apart and redraws when the passage under the playhead changes.
    let player: PlaybackController
    let meeting: Meeting
    /// One column shows the title and byline here too, so switching feels like turning the page.
    var showsHeader = true
    @Environment(ReadingSession.self) private var session
    @Environment(\.audioProvider) private var provider
    @Environment(\.findQuery) private var findQuery
    @Environment(\.isTwoPage) private var twoPage
    @Environment(\.liveCaptionStore) private var captionStore
    @Environment(\.liveCaptionsSaved) private var captionsSaved
    @State private var find = ConversationFind()
    /// Saved live captions to read here (`SavedCaptions.shown`): in the transcript's place until a transcript arrives,
    /// else after an earlier recording's transcript.
    @State private var captions: LiveCaptions?
    /// Where the page goes next: the session's latest jump.
    @State private var scrollRequest: TranscriptScrollRequest?
    @State private var requests = 0

    var body: some View {
        @Bindable var session = session
        let shownCaptions = SavedCaptions.shown(captions, for: meeting)
        TranscriptPage(meeting: meeting, host: host, findQuery: findQuery, find: find, scrollRequest: scrollRequest,
                       anchor: $session.transcriptAnchor, captions: shownCaptions) {
            if showsHeader {
                PageHeader(library: library, meeting: meeting, play: play).padding(.bottom, PhoneStyle.Space.s2).id("header")
            }
        } placeholder: {
            if shownCaptions == nil {
                EmptyTranscript(meeting: meeting, status: ProcessingStatus.phone(meeting), words: .iPhone(id: library.thisDevice.id),
                                // On two pages the summary's box beside this one says why, with Try Again.
                                showsReason: !twoPage, play: { play(.timeline(0)) },
                                transcribe: twoPage ? { library.requestProcessing(meeting.id, mode: .newAudio) } : nil) {
                    RecordIntoButton(meeting: meeting)
                }
                .id("empty")
            }
        }
        .photoServices(.phone(library: library, session: session, provider: provider))
        .paperBackground()
        .scrollEdgeEffectStyle(.soft, for: .top)
        .modifier(PageTitle(title: showsHeader ? nil : shownCaptions != nil && SavedCaptions.standsIn(for: meeting) ? "Live Captions" : "Transcript"))
        // A jump asked for elsewhere (a search hit, a summary line's evidence, a photo's moment), again each time the
        // page appears, so turning to it from the summary lands there.
        .onChange(of: session.transcriptRequest, initial: true) { _, request in
            guard let request else { return }
            requests += 1
            // The passage washes once, when it's first jumped to; turning back to the page later only scrolls there.
            let flash = request.flash && session.flashedSegment?.uuidString == request.target
            if flash { session.flashedSegment = nil }
            scrollRequest = TranscriptScrollRequest(target: request.target, token: requests, flash: flash)
        }
        // Captions come from the store `LibraryBrowser` provides, read off the main actor; a transcript made after
        // them replaces them. The page follows the playhead through them as it does through passages.
        .task(id: SavedCaptions.Reading(meeting, lastSave: captionsSaved)) {
            let read = await SavedCaptions.read(for: meeting, from: captionStore)
            guard !Task.isCancelled else { return }
            if read != captions { captions = read }
        }
    }

    private var host: TranscriptHost {
        let session = session
        let player = player
        let meetingID = meeting.id
        return TranscriptHost(
            library: library,
            playhead: {
                guard player.meetingID == meetingID, player.phase == .ready, let trackID = player.trackID else { return nil }
                return TranscriptPlayhead(trackID: trackID, position: player.position, isPlaying: player.isPlaying)
            },
            play: play,
            present: { sheet in
                session.sheet = Self.readingSheet(sheet, meetingID: meetingID)
                return true
            },
            showNotes: { session.showOnSummary(SummaryBlockID.notes) },
            didScroll: { session.pageMode = .transcript },
            photos: .phone(library: library, session: session, provider: provider))
    }

    /// The transcript's sheets are reading sheets: a sheet in the hand, a card on the open Duo's right page.
    static func readingSheet(_ sheet: TranscriptSheet, meetingID: UUID) -> ReadingSheet {
        switch sheet {
        case .correct(let segmentID): return .correct(meetingID: meetingID, segmentID: segmentID)
        case .reviewCorrections: return .reviewCorrections(meetingID)
        case .adjustTiming(let trackID): return .adjustTiming(meetingID: meetingID, trackID: trackID)
        case .originalTranscript(let trackID): return .originalTranscript(meetingID: meetingID, trackID: trackID)
        }
    }

    private func play(_ target: PlaybackTarget) {
        player.play(target, in: meeting, provider: provider)
    }
}

/// The page's own title on two pages (one column shows the page switch instead).
private struct PageTitle: ViewModifier {
    let title: String?
    func body(content: Content) -> some View {
        if let title { content.navigationTitle(title) } else { content }
    }
}

/// Record, into a conversation that's only notes so far: the recording joins it, after the notes.
struct RecordIntoButton: View {
    let meeting: Meeting
    @Environment(PhoneAppModel.self) private var model

    var body: some View {
        Button {
            Task { try? await model.startRecording(into: meeting.id, title: meeting.title, multipoint: nil) }
        } label: {
            HStack(spacing: PhoneStyle.Space.s2) {
                Circle().fill(PhoneStyle.Ink.record).frame(width: 10, height: 10).accessibilityHidden(true)
                Text("Record").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(PhoneStyle.Ink.title)
            .padding(.horizontal, 6).padding(.vertical, 2)
        }
        .buttonStyle(.glass)
        .disabled(model.recorder.state != .idle || model.isFiling)
        .accessibilityHint("Records into this conversation")
    }
}
