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

    /// The conversation's More, a row's menu, and the selection bar carry an action out the same way: Work or Personal
    /// is undone by one name from one conversation or several, and what needs a sheet or a question asks the session.
    func testBehaviorMoreARowAndASelectionCarryOutAnActionTheSameWay() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "TEST")
        try await library.reload()
        let a = library.controller.newMeeting(title: "A"), b = library.controller.newMeeting(title: "B")
        let session = ReadingSession()
        func perform(_ id: ConversationAction.ID, on ids: [UUID], undoManager: UndoManager? = nil) {
            PhoneActions.perform(id, on: ids, library: library.controller, session: session, provider: LocalAudioProvider(),
                                 placement: nil, undoManager: undoManager)
        }
        for ids in [[a], [a, b]] {
            let undo = UndoManager()
            undo.groupsByEvent = false
            undo.beginUndoGrouping()
            perform(.moveTo(.personal), on: ids, undoManager: undo)
            undo.endUndoGrouping()
            XCTAssertEqual(undo.undoActionName, "Move to Personal", "from More as from a row or the selection bar")
            XCTAssertTrue(ids.allSatisfy { library.controller.meeting($0)?.placement == .personal })
            undo.undo()
            XCTAssertTrue(ids.allSatisfy { library.controller.meeting($0)?.placement == nil })
        }
        perform(.tags, on: [a])
        XCTAssertEqual(session.sheet, .tags([a]))
        perform(.moveToFolder, on: [a])
        XCTAssertEqual(session.sheet, .move([a]))
        perform(.versionHistory, on: [a])
        XCTAssertEqual(session.sheet, .history(a))
        perform(.moveToTrash, on: [a])
        XCTAssertEqual(session.confirmingTrash, [a])
        await library.controller.flush()
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

    func testBehaviorBesideTheTrashTwoPagesShowWhatsInItNeverTheLibrarys() {
        let session = ReadingSession()
        session.isNotebook = true
        let older = Meeting(title: "Roadmap review", date: Date().addingTimeInterval(-7_200))
        let newer = Meeting(title: "Weekly sync", date: Date().addingTimeInterval(-3_600))
        session.place = .trash
        session.showNewest(of: [older, newer])
        XCTAssertNil(session.openID, "no conversation from All beside the Trash")

        let gone = Meeting(title: "Old standup", date: Date().addingTimeInterval(-600))
        let earlier = Meeting(title: "Offsite ideas", date: Date().addingTimeInterval(-86_400))
        session.showInTrash(from: [gone, earlier])
        XCTAssertEqual(session.trashedID, gone.id, "the newest in the Trash, as the Mac's Trash selects its first")
        session.trashedID = earlier.id
        session.showInTrash(from: [gone, earlier])
        XCTAssertEqual(session.trashedID, earlier.id, "the one tapped stays while it's there")
        session.showInTrash(from: [gone])
        XCTAssertEqual(session.trashedID, gone.id, "restored: the next one")
        session.showInTrash(from: [])
        XCTAssertNil(session.trashedID, "an empty Trash: paper")

        session.searchText = "standup"
        session.showInTrash(from: [gone])
        XCTAssertNil(session.trashedID, "searching: the results own the right page")
        session.searchText = ""
        session.place = .library(.section(.all))
        session.showInTrash(from: [gone])
        XCTAssertNil(session.trashedID, "left the Trash while it read")

        session.showNewest(of: [older, newer])
        XCTAssertEqual(session.openID, newer.id, "leaving the Trash shows the place's newest")
        XCTAssertFalse(session.chosen)
    }

    func testBehaviorResultsAndTheTrashKeepTheListsInsetsClearOfTheCrease() {
        XCTAssertNil(PageRows.inset(.leading, twoPage: false, creaseEdge: nil), "one page: the list's own")
        XCTAssertEqual(PageRows.inset(.trailing, twoPage: true, creaseEdge: .trailing), 16)
        XCTAssertEqual(PageRows.inset(.leading, twoPage: true, creaseEdge: .trailing), PageRows.pageInset)
        XCTAssertEqual(PageRows.inset(.leading, twoPage: true, creaseEdge: .leading), 16)
        XCTAssertEqual(PageRows.washInset(.trailing, creaseEdge: .trailing), 16, "the card also stays 16 pt from the crease")
        XCTAssertEqual(PageRows.washInset(.leading, creaseEdge: .leading), 16)
        XCTAssertEqual(PageRows.washInset(.leading, creaseEdge: .trailing), 10, "the wash reaches toward the outer edge")
        XCTAssertEqual(ReadingGeometry.creaseClearance, 24, "controls keep their own clearance")
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
        // Transcribed after its captions began: the transcript replaced them, so the page doesn't show them and search
        // doesn't offer them.
        var replaced = Meeting(title: "Already transcribed")
        replaced.transcripts = [TrackTranscript(trackID: UUID(), segments: [], modelID: "m", createdAt: Date().addingTimeInterval(3_600))]
        replaced.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "Hello")]
        for meeting in [captioned, replaced] {
            let captions = LiveCaptions(meetingID: meeting.id, localeIdentifier: "en_US",
                                        segments: [LiveCaptionSegment(start: 12, end: 14, text: "The onboarding checklist.", isTentative: false)])
            try JSONEncoder().encode(captions).write(to: folder.appendingPathComponent("\(meeting.id.uuidString).json"))
        }

        let candidates = LibraryPage.captionCandidates(in: [captioned, replaced], tokens: [], scope: .all)
        XCTAssertEqual(Set(candidates.map(\.id)), [captioned.id, replaced.id])
        let hits = await LibraryCaptionSearch.hits(in: candidates, query: "checklist", excluding: [], libraryRoot: root)
        XCTAssertEqual(hits.map(\.meeting.id), [captioned.id], "never a result that opens a page with no captions to show")
        XCTAssertTrue(LibraryPage.captionCandidates(in: [captioned, replaced], tokens: [], scope: .work).isEmpty,
                      "and only in the search's scope")
    }
}
