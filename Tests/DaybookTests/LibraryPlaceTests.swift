import AVFoundation
import DaybookCaptions
import DaybookCore
import DaybookIntelligence
@testable import DaybookKit
import DaybookTestSupport
import DaybookUI
import Foundation
import XCTest
@testable import Daybook

@MainActor
final class LibraryPlaceTests: XCTestCase {
    func testConversationOfUnknownKindAppearsOnlyInAllUntilDetected() {
        var meeting = Meeting(title: "Just recorded")
        XCTAssertTrue(LibrarySection.all.contains(meeting))
        XCTAssertFalse(LibrarySection.work.contains(meeting))
        XCTAssertFalse(LibrarySection.personal.contains(meeting))
        meeting.summary = MeetingSummary(kind: .therapy, overview: "A check-in")
        XCTAssertTrue(LibrarySection.personal.contains(meeting))
        XCTAssertFalse(LibrarySection.work.contains(meeting))
        meeting.placement = .work
        XCTAssertTrue(LibrarySection.work.contains(meeting))
        XCTAssertFalse(LibrarySection.personal.contains(meeting))
        XCTAssertEqual(meeting.displayKind, .therapy, "Moving a conversation never changes its kind")
    }

    func testNewConversationTakesTheSelectedPlace() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        state.window.place = .section(.personal)
        let personal = state.newMeeting()
        XCTAssertEqual(state.meetings.first { $0.id == personal }?.placement, .personal)
        state.createFolder(named: "Hiring", moving: [])
        let folder = try XCTUnwrap(state.folders.first { $0.name == "Hiring" })
        state.window.place = .folder(folder.id)
        let filed = state.newMeeting()
        XCTAssertEqual(state.meetings.first { $0.id == filed }?.folderID, folder.id)
        XCTAssertEqual(state.visibleMeetings.map(\.id), [filed])
    }

    func testNewNoteIsTitledAsOnTheIPhoneAndSelected() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        state.window.place = .section(.work)
        let now = Date()
        let id = state.newNote(at: now)
        let note = try XCTUnwrap(state.meetings.first { $0.id == id })
        XCTAssertEqual(note.title, "Note at \(now.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(note.title, LibraryWords.noteTitle(at: now), "the iPhone's New Note uses the same words")
        XCTAssertTrue(note.tracks.isEmpty, "only notes, until Record records into it")
        XCTAssertEqual(note.placement, .work)
        XCTAssertEqual(state.window.openID, id)
    }

    func testImportedDeviceRecordingsAreRecognizedFromTheLibrary() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        let url = root.appendingPathComponent("Soundcore-1729000000.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000)!
        buffer.frameLength = 4_000
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        state.window.openID = nil
        state.window.place = .section(.personal)
        let identity = DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: "7F3A", recordingID: "1729000000")
        try await state.importFiles([url], source: .soundcore, attachTo: nil, device: identity)
        let meeting = try XCTUnwrap(state.meetings.first)
        XCTAssertEqual(DeviceLibraryLinks(meetings: state.meetings, kind: SoundcoreWorkIntegration.id).imported["1729000000"], meeting.id)
        XCTAssertEqual(meeting.tracks.first?.source, .soundcore)
        XCTAssertEqual(meeting.tracks.first?.device, identity)
        XCTAssertEqual(meeting.date, Date(timeIntervalSince1970: 1_729_000_000), "Dated when it was recorded, not imported")
        XCTAssertNil(state.window.openID, "A background import doesn't change the selection")
        XCTAssertNil(meeting.placement, "Nor take the place being viewed")
        XCTAssertTrue(meeting.title.hasPrefix("Soundcore Work at "))
        // The same bytes from the recorder again join that conversation instead of making another.
        try await state.importFiles([url], source: .soundcore, attachTo: nil, device: identity)
        XCTAssertEqual(state.meetings.count, 1)
    }

    func testBehaviorTheTrashIsAPlaceOfItsOwnThatListsWhatsInItsFolder() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        let kept = state.newMeeting(title: "Kept")
        let gone = state.newMeeting(title: "Old standup")
        _ = try await state.library.moveToTrash(gone)
        state.window.place = .trash
        XCTAssertEqual(state.visibleMeetings, [], "the library's conversations aren't in the Trash")
        let trashed = await state.library.trashedMeetings()
        XCTAssertEqual(trashed.map(\.id), [gone])
        XCTAssertNotNil(state.meetings.first { $0.id == kept })
    }

    func testBehaviorARowDraggedFromASelectionOfSeveralFilesTheWholeSelection() {
        let meetings = (1...4).map { Meeting(title: "Conversation \($0)") }
        let ids = meetings.map(\.id)
        XCTAssertEqual(ConversationDrop.filed([ids[2]], selection: [ids[0], ids[2], ids[3]], in: meetings), [ids[0], ids[2], ids[3]],
                       "one of the selected rows brings the rest, in the library's order")
        XCTAssertEqual(ConversationDrop.filed([ids[1]], selection: [ids[0], ids[2]], in: meetings), [ids[1]],
                       "a row outside the selection travels alone")
        XCTAssertEqual(ConversationDrop.filed([ids[3]], selection: [ids[3]], in: meetings), [ids[3]])
        XCTAssertEqual(ConversationDrop.filed([ids[0], ids[1]], selection: [], in: meetings), [ids[0], ids[1]])
        XCTAssertEqual(ConversationDrop.filed([UUID()], selection: [], in: meetings), [], "one no longer in the library files nothing")
    }

    func testBehaviorLeavingTheTrashWhileItReadsKeepsTheNewPlacesSelection() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        let kept = state.newMeeting(title: "Kept")
        let gone = state.newMeeting(title: "Old standup")
        _ = try await state.library.moveToTrash(gone)
        state.window.place = .trash
        let read = await state.library.trashedMeetings()

        // The person opened the Trash, then All, before its list came back.
        state.window.place = .section(.all)
        state.window.openID = kept
        XCTAssertFalse(MacTrash.adopt(read, state: state))
        XCTAssertEqual(state.window.openID, kept, "All keeps its selection, never a conversation in the Trash")

        state.window.place = .trash
        state.window.searchText = "standup"
        XCTAssertFalse(MacTrash.adopt(read, state: state), "searching: the results own the selection")
        state.window.searchText = ""

        XCTAssertTrue(MacTrash.adopt(read, state: state))
        XCTAssertEqual(state.window.openID, gone, "still in the Trash: its first is selected")
    }

    func testBehaviorARowSaysWhatThisMacIsDoingWithItInTheWordsTheIPhoneUses() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        let id = state.newMeeting(title: "1:1 with Priya")
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        XCTAssertNil(MacRowStatus.make(state, meeting), "a conversation that's only notes is ready")

        state.processor.queue.paused.insert(id)
        let paused = try XCTUnwrap(MacRowStatus.make(state, meeting))
        XCTAssertEqual(paused.kind, .paused, "the pause glyph, as on the iPhone")
        XCTAssertEqual(paused.text, "Paused")
        state.processor.queue.paused.remove(id)

        state.recordingID = id
        XCTAssertEqual(MacRowStatus.make(state, meeting)?.kind, .recording)
        XCTAssertEqual(MacRowStatus.make(state, meeting)?.text, "Recording now")
        state.recordingID = nil
    }

    /// VM-06: the list's subtitle says this Mac's queue in the shared words: the step that runs, by the name its page
    /// gives it, and how many wait; nothing while nothing works, and nothing in the Trash.
    func testBehaviorTheListSubtitleNamesTheStepThatRunsAndSaysNothingInTheTrash() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        let running = state.newMeeting(title: "Roadmap review")
        let waiting = state.newMeeting(title: "Northwind call")
        XCTAssertEqual(MacListSubtitle.text(state, results: 0), "", "nothing works: nothing to say")

        state.processor.queue.runningID = running
        state.processor.queue.activity.set(IntelligenceProgress(0.4, "Transcribing", stage: .transcribing))
        state.processor.queue.jobs = [state.makeJob(meetingID: waiting, mode: .newAudio)]
        XCTAssertEqual(MacListSubtitle.text(state, results: 0), "Transcribing · 1 waiting", "the figure is the row's")
        state.processor.queue.activity.set(IntelligenceProgress(0, "Summarizing", stage: .summarizing))
        XCTAssertEqual(MacListSubtitle.text(state, results: 0), "Summarizing · 1 waiting", "the step that runs, not always Transcribing")
        XCTAssertNil(MacListSubtitle.countdown(state), "no countdown: it doesn't tick")

        state.window.place = .trash
        XCTAssertEqual(MacListSubtitle.text(state, results: 0), "", "the Trash's rows don't work")
        state.window.searchText = "roadmap"
        XCTAssertEqual(MacListSubtitle.text(state, results: 1), "1 result", "a search counts its results anywhere")
        state.window.searchText = ""
        state.window.place = .section(.all)
        state.processor.queue.jobs = []
        state.processor.queue.runningID = nil
        XCTAssertEqual(MacListSubtitle.text(state, results: 0), "")
    }

    func testBehaviorASearchResultOpensWhereThisMacShowsWhatItFound() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        // This Mac transcribed it, then an iPhone's recording joined it: an earlier transcript and newer captions, which
        // the transcript's page shows after that transcript until a newer one replaces them, as on the iPhone.
        let joined = state.newMeeting(title: "Roadmap review")
        state.update(joined) { meeting in
            meeting.transcripts = [TrackTranscript(trackID: UUID(), segments: [], modelID: "m", createdAt: Date().addingTimeInterval(-3_600))]
            meeting.unifiedTranscript = [TranscriptSegment(trackID: UUID(), start: 0, end: 1, text: "We ship the beta on Friday.")]
            meeting.notes = "Ask Priya about pricing."
        }
        let folder = LibraryCaptionSearch.directory(libraryRoot: state.library.rootURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let captions = LiveCaptions(meetingID: joined, localeIdentifier: "en_US",
                                    segments: [LiveCaptionSegment(start: 12, end: 14, text: "The onboarding checklist.", isTentative: false)])
        try JSONEncoder().encode(captions).write(to: folder.appendingPathComponent("\(joined.uuidString).json"))
        let captionHits = await LibraryCaptionSearch.hits(in: state.meetings, query: "checklist", excluding: [], libraryRoot: state.library.rootURL)
        XCTAssertEqual(captionHits.map(\.meeting.id), [joined])

        state.window.pageMode = .transcript
        MacSearch.open(joined, hits: [], captionHits: captionHits, state: state)
        XCTAssertEqual(state.window.openID, joined)
        XCTAssertEqual(state.window.pageMode, .transcript, "saved captions read on the transcript's page")
        XCTAssertEqual(state.window.pageScrollTarget, captions.segments.first?.id, "at the caption found")

        let passage = try XCTUnwrap(LibrarySearch.hits(in: state.meetings, text: "beta", tokens: [], scope: .all).first)
        MacSearch.open(joined, hits: [passage], captionHits: [], state: state)
        XCTAssertEqual(state.window.pageMode, .transcript)
        XCTAssertEqual(state.window.pageScrollTarget, state.meetings.first { $0.id == joined }?.unifiedTranscript.first?.id,
                       "a passage opens the transcript there")

        let note = try XCTUnwrap(LibrarySearch.hits(in: state.meetings, text: "pricing", tokens: [], scope: .all).first)
        MacSearch.open(joined, hits: [note], captionHits: [], state: state)
        XCTAssertEqual(state.window.pageMode, .summary)
        XCTAssertNil(state.window.pageScrollTarget)
        XCTAssertEqual(state.window.takeSummaryRequest(for: joined), SummaryBlockID.notes, "the summary page moves to your notes")

        let title = try XCTUnwrap(LibrarySearch.hits(in: state.meetings, text: "roadmap", tokens: [], scope: .all).first)
        MacSearch.open(joined, hits: [title], captionHits: [], state: state)
        XCTAssertEqual(state.window.pageMode, .summary)
        XCTAssertNil(state.window.pageScrollTarget, "a title opens the page's top, with no earlier result's place left over")
    }

    private func makeState() async throws -> (AppState, URL, UserDefaults) {
        let root = makeTemporaryFolder("DaybookPlaceTests")
        let defaults = makeTestDefaults()
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        XCTAssertTrue(state.isReady)
        return (state, root, defaults)
    }
    private func cleanUp(_ root: URL, _ defaults: UserDefaults) {
        try? FileManager.default.removeItem(at: root)
    }
}
