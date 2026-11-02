import AVFoundation
import DaybookCore
@testable import DaybookKit
import DaybookTestSupport
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
        state.place = .section(.personal)
        let personal = state.newMeeting()
        XCTAssertEqual(state.meetings.first { $0.id == personal }?.placement, .personal)
        state.createFolder(named: "Hiring", moving: [])
        let folder = try XCTUnwrap(state.folders.first { $0.name == "Hiring" })
        state.place = .folder(folder.id)
        let filed = state.newMeeting()
        XCTAssertEqual(state.meetings.first { $0.id == filed }?.folderID, folder.id)
        XCTAssertEqual(state.visibleMeetings.map(\.id), [filed])
    }

    func testNewNoteIsTitledAsOnTheIPhoneAndSelected() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        state.place = .section(.work)
        let now = Date()
        let id = state.newNote(at: now)
        let note = try XCTUnwrap(state.meetings.first { $0.id == id })
        XCTAssertEqual(note.title, "Note at \(now.formatted(date: .omitted, time: .shortened))")
        XCTAssertEqual(note.title, LibraryWords.noteTitle(at: now), "the iPhone's New Note uses the same words")
        XCTAssertTrue(note.tracks.isEmpty, "only notes, until Record records into it")
        XCTAssertEqual(note.placement, .work)
        XCTAssertEqual(state.selectedID, id)
    }

    func testImportedDeviceRecordingsAreRecognizedFromTheLibrary() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        let url = root.appendingPathComponent("Soundcore-1729000000.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000)!
        buffer.frameLength = 4_000
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: buffer)
        state.selectedID = nil
        state.place = .section(.personal)
        let identity = DeviceRecordingIdentity(kind: SoundcoreWorkIntegration.id, serial: "7F3A", recordingID: "1729000000")
        try await state.importFiles([url], source: .soundcore, attachTo: nil, device: identity)
        let meeting = try XCTUnwrap(state.meetings.first)
        XCTAssertEqual(DeviceLibraryLinks(meetings: state.meetings, kind: SoundcoreWorkIntegration.id).imported["1729000000"], meeting.id)
        XCTAssertEqual(meeting.tracks.first?.source, .soundcore)
        XCTAssertEqual(meeting.tracks.first?.device, identity)
        XCTAssertEqual(meeting.date, Date(timeIntervalSince1970: 1_729_000_000), "Dated when it was recorded, not imported")
        XCTAssertNil(state.selectedID, "A background import doesn't change the selection")
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
        state.place = .trash
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
        state.place = .trash
        let read = await state.library.trashedMeetings()

        // The person opened the Trash, then All, before its list came back.
        state.place = .section(.all)
        state.selectedID = kept
        XCTAssertFalse(MacTrash.adopt(read, state: state))
        XCTAssertEqual(state.selectedID, kept, "All keeps its selection, never a conversation in the Trash")

        state.place = .trash
        state.search = "standup"
        XCTAssertFalse(MacTrash.adopt(read, state: state), "searching: the results own the selection")
        state.search = ""

        XCTAssertTrue(MacTrash.adopt(read, state: state))
        XCTAssertEqual(state.selectedID, gone, "still in the Trash: its first is selected")
    }

    func testBehaviorARowSaysWhatThisMacIsDoingWithItInTheWordsTheIPhoneUses() async throws {
        let (state, root, defaults) = try await makeState()
        defer { cleanUp(root, defaults) }
        let id = state.newMeeting(title: "1:1 with Priya")
        let meeting = try XCTUnwrap(state.meetings.first { $0.id == id })
        XCTAssertNil(MacRowStatus.make(state, meeting), "a conversation that's only notes is ready")

        state.pausedIDs.insert(id)
        let paused = try XCTUnwrap(MacRowStatus.make(state, meeting))
        XCTAssertEqual(paused.kind, .paused, "the pause glyph, as on the iPhone")
        XCTAssertEqual(paused.text, "Paused")
        state.pausedIDs.remove(id)

        state.recordingID = id
        XCTAssertEqual(MacRowStatus.make(state, meeting)?.kind, .recording)
        XCTAssertEqual(MacRowStatus.make(state, meeting)?.text, "Recording now")
        state.recordingID = nil
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
