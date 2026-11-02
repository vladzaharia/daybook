import DaybookCaptions
import DaybookCore
import DaybookKit
import DaybookLink
import DaybookUI
import XCTest
@testable import DaybookPhone

/// The library list on this iPhone: what a row says with a Mac's live progress and recording over the link, what
/// its menus and selection bar offer, and the Trash it lists, the Mac's words throughout.
@MainActor
final class LibraryListPhoneTests: XCTestCase {
    private func recorded(_ title: String) -> Meeting {
        var meeting = Meeting(title: title)
        meeting.tracks = [RecordingTrack(source: .microphone, relativePath: "Originals/a.m4a", fileName: "a.m4a", duration: 60)]
        return meeting
    }

    func testBehaviorARowFollowsAMacsLiveProgressBeforeSyncSaysSo() {
        let meeting = recorded("Roadmap review")
        let progress = LinkProcessingProgress(meetingID: meeting.id, phase: .transcribing, fraction: 0.4, macName: "Studio Mac")
        let context = PhoneRowStatus.Context(thisDeviceID: "phone", recordingOnMac: [],
                                             live: [meeting.id: LiveProgress(progress, receivedAt: Date())])
        let row = PhoneRowStatus.make(meeting, context: context, now: Date())
        XCTAssertEqual(row?.kind, .processing)
        XCTAssertEqual(row?.text, "Transcribing on Studio Mac · 40%")
        XCTAssertEqual(row?.phrase, "Transcribing on Studio Mac", "the line fades when its words change, not at every percent")

        let quiet = PhoneRowStatus.make(meeting, context: .init(thisDeviceID: "phone", recordingOnMac: []), now: Date())
        XCTAssertEqual(quiet?.kind, .notTranscribed, "without the link, what the library says")
    }

    func testBehaviorARowSaysAMacIsRecordingItNowAndMintMarksTheOnePlaying() {
        let meeting = recorded("Design review")
        let states = [LinkRecordingState(phase: .recording, conversationID: meeting.id),
                      LinkRecordingState(phase: .stopping, conversationID: UUID())]
        let recording = PhoneRowStatus.recording(states)
        XCTAssertEqual(recording, [meeting.id], "saving isn't recording")
        let row = PhoneRowStatus.make(meeting, context: .init(thisDeviceID: "phone", recordingOnMac: recording), now: Date())
        XCTAssertEqual(row?.kind, .recording)
        XCTAssertEqual(row?.text, "Recording now")

        var ready = Meeting(title: "Weekly product sync")
        ready.summary = MeetingSummary(overview: "Agreed.")
        let playing = PhoneRowStatus.make(ready, context: .init(thisDeviceID: "phone", recordingOnMac: [], playing: ready.id), now: Date())
        XCTAssertEqual(playing?.kind, .playing)
        XCTAssertNil(playing?.text, "the gist stays")
    }

    func testBehaviorAPausedRowReadsPausedWithThePauseGlyphNotAClock() {
        // The shared row has a paused kind of its own; the reading status's older row mapped it to waiting.
        let shared = ConversationRow.shared(RowStatus(kind: .waiting, text: "Paused"))
        XCTAssertEqual(shared.kind, .paused)
        XCTAssertEqual(shared.kind.symbol, "pause.circle")
    }

    func testBehaviorASelectionOffersWhatTheMacsDoesInTheSameOrder() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "TEST")
        try await library.reload()
        let a = library.controller.newMeeting(title: "A"), b = library.controller.newMeeting(title: "B")
        library.controller.update(a) { $0.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "Hello")] }
        let groups = PhoneActions.groups(for: [a, b], library: library.controller)
        let shown = ConversationActionMenuItems.shown(groups, on: .iPhone).flatMap(\.actions)
        XCTAssertEqual(shown.map(ConversationActionMenuItems.shortTitle), ["Summarize", "Move", "Tags", "Personal", "Trash"])
        let one = PhoneActions.groups(for: [b], library: library.controller)
        let only = ConversationActionMenuItems.shown(one, on: .iPhone).flatMap(\.actions).map(\.id)
        XCTAssertFalse(only.contains(.copySummary), "no summary yet: left out on an iPhone")
        XCTAssertTrue(only.contains(.moveToTrash))
    }

    func testBehaviorTheTrashListsWhatWasMovedThereThroughTheSharedReader() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "TEST")
        try await library.reload()
        let trashed = library.controller.newMeeting(title: "Offsite ideas")
        await library.controller.flush()
        _ = try await library.controller.moveToTrash(trashed)
        let listed = await library.controller.trashedMeetings()
        XCTAssertEqual(listed.map(\.title), ["Offsite ideas"])
        XCTAssertEqual(LibraryWords.emptyPlace(.trash, libraryIsEmpty: true, platform: .iPhone)?.title, "No Conversations",
                       "an empty Trash says what every empty place says")
    }

    func testBehaviorTheTrashHasOneNameTheLibrarysOwn() {
        XCTAssertEqual(ReadingPlace.trash, .library(.trash), "one place, however it's written")
        XCTAssertTrue(ReadingPlace.library(.trash).isTrash)
        XCTAssertEqual(ReadingPlace.trash.libraryPlace, .trash)
        XCTAssertFalse(ReadingPlace.library(.section(.all)).isTrash)
        XCTAssertFalse(ReadingPlace.library(.folder(UUID())).isTrash)
    }

    func testBehaviorCaptionSearchListsOnlyCaptionsThisIPhonesPageShows() async throws {
        let root = try temporaryDirectory()
        let folder = LibraryCaptionSearch.directory(libraryRoot: root)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let captioned = Meeting(title: "Onboarding design review")
        // An iPhone's recording joined to a conversation a Mac had already transcribed: an earlier transcript, newer
        // captions. This iPhone's transcript page shows the transcript, so search doesn't offer the captions.
        var joined = Meeting(title: "Already transcribed")
        joined.transcripts = [TrackTranscript(trackID: UUID(), segments: [], modelID: "m", createdAt: Date().addingTimeInterval(-3_600))]
        joined.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "Hello")]
        for meeting in [captioned, joined] {
            let captions = LiveCaptions(meetingID: meeting.id, localeIdentifier: "en_US",
                                        segments: [LiveCaptionSegment(start: 12, end: 14, text: "The onboarding checklist.", isTentative: false)])
            try JSONEncoder().encode(captions).write(to: folder.appendingPathComponent("\(meeting.id.uuidString).json"))
        }
        XCTAssertFalse(joined.showsLiveCaptions)

        let candidates = LibraryPage.captionCandidates(in: [captioned, joined], tokens: [], scope: .all)
        XCTAssertEqual(candidates.map(\.id), [captioned.id])
        let hits = await LibraryCaptionSearch.hits(in: candidates, query: "checklist", excluding: [], libraryRoot: root)
        XCTAssertEqual(hits.map(\.meeting.id), [captioned.id], "never a result that opens a page with no captions to show")
        XCTAssertTrue(LibraryPage.captionCandidates(in: [captioned, joined], tokens: [], scope: .work).isEmpty,
                      "and only in the search's scope")
    }
}
