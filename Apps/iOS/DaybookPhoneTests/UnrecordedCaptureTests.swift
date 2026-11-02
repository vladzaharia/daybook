import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// A recording that captured no audio (the microphone never delivered, or a start raced a call): the
/// notes, bookmarks, and photos made during it are the person's, so they're filed as a conversation of
/// notes, at Stop and when a later launch finds them, and the person is told plainly, never promised a
/// retry that can't succeed. Synthetic inputs that never deliver; temporary libraries.
@MainActor
final class UnrecordedCaptureTests: XCTestCase {
    private func makeModel(rig: RecorderRig, library: PhoneLibrary? = nil, runsLaunch: Bool = false) throws -> PhoneAppModel {
        let library = try library ?? PhoneLibrary(rootURL: temporaryDirectory("library"), installation: "INSTALL-1")
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: DebugLaunch(arguments: [], environment: runsLaunch ? [:] : ["XCTestConfigurationFilePath": "1"]),
                             environment: try .test(self))
    }

    func testBehaviorStopWithNoAudioFilesTheNotesBookmarksAndPhotosAsAConversationOfNotes() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        // The microphone never delivers: no audio, but the person takes notes, a bookmark, and a photo.
        model.editNotes("Whiteboard: Q3 targets\nAsk Priya about the venue")
        try await model.addBookmark()
        await model.addPhoto(syntheticCameraPhoto(capturedAt: Date()), recording: model.recorder.captureID)
        try await model.stopRecording()

        XCTAssertEqual(model.notice, "No audio was recorded. Your notes are saved.")
        XCTAssertEqual(model.lastStopResult.sentence, "No audio was recorded. Your notes are saved.", "what Siri says too")
        guard case .saved(let id, _)? = model.lastFiling else { return XCTFail("filed: \(String(describing: model.lastFiling))") }
        let meeting = try XCTUnwrap(model.library.controller.meeting(id))
        XCTAssertTrue(meeting.title.hasPrefix("Note at "), meeting.title)
        XCTAssertTrue(meeting.tracks.isEmpty, "a conversation of notes: its page offers Record")
        XCTAssertEqual(meeting.notes, "Whiteboard: Q3 targets\nAsk Priya about the venue")
        XCTAssertEqual(meeting.timedNotes?.map(\.time), [nil, nil], "no first sample, so no timeline to time them by")
        XCTAssertEqual(meeting.highlights.count, 1)
        XCTAssertEqual(meeting.visiblePhotos.count, 1)
        XCTAssertEqual(model.lastFiledID, id)
        XCTAssertTrue(PhoneRecorder.pendingCaptures(in: model.library.stagingURL).isEmpty, "nothing left in staging")
    }

    func testBehaviorStopWithNoAudioAndNothingElseSaysSoAndKeepsNothing() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        try await model.startRecording()
        try await model.stopRecording()

        XCTAssertEqual(model.notice, "No audio was recorded.")
        XCTAssertNil(model.noticeDetails)
        XCTAssertEqual(model.lastFiling, .failed("No audio was recorded."))
        XCTAssertEqual(model.lastStopResult.sentence, "No audio was recorded.")
        XCTAssertFalse(model.notice?.contains("tries again") ?? true, "never a retry that can't succeed")
        XCTAssertTrue(model.library.conversations.isEmpty)
        XCTAssertTrue(PhoneRecorder.pendingCaptures(in: model.library.stagingURL).isEmpty)
    }

    func testBehaviorALaunchFilesTheNotesAnEarlierRunLeftWithoutAudio() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        try await library.reload()
        // What an earlier build left: a stopped journal with notes and no audio at all.
        let id = UUID()
        let folder = library.stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        var journal = PhoneCaptureJournal(id: id, title: "Conversation at 10:15 AM", createdAt: created, format: .speech)
        journal.state = .stopped
        journal.notes = "Only notes survived"
        journal.timedNotes = [TimedNote(time: 0, text: "Only notes survived")]
        journal.highlights = [Highlight(time: 0, text: "Decision")]
        try journal.write(to: folder)

        let model = try makeModel(rig: RecorderRig(), library: library, runsLaunch: true)
        await model.launch()
        let meeting = try XCTUnwrap(library.controller.meeting(id), "filed into the conversation it was recording")
        XCTAssertEqual(meeting.title, LibraryWords.noteTitle(at: created))
        XCTAssertEqual(meeting.notes, "Only notes survived")
        XCTAssertEqual(meeting.highlights.map(\.text), ["Decision"])
        XCTAssertEqual(model.notice, "No audio was recorded. Your notes are saved.")
        XCTAssertTrue(PhoneRecorder.pendingCaptures(in: library.stagingURL).isEmpty, "not left to be tried again forever")
    }

    func testBehaviorNotesOfARecordingIntoANoteJoinThatNote() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        try await model.library.reload()
        let note = model.library.controller.newMeeting(title: "Ideas for the offsite")
        model.library.controller.update(note) { $0.setNotes("Walk instead of a room") }
        try await model.startRecording(into: note, title: "Ideas for the offsite", multipoint: nil)
        model.editNotes("Budget by Friday")
        try await model.stopRecording()

        let meeting = try XCTUnwrap(model.library.controller.meeting(note))
        XCTAssertEqual(meeting.title, "Ideas for the offsite", "the conversation it was recording into keeps its title")
        XCTAssertEqual(meeting.notes, "Walk instead of a room\nBudget by Friday")
        XCTAssertEqual(model.library.conversations.count, 1)
    }

    func testBehaviorTheTimesOfACaptureThatHadATimelineStayOnIt() throws {
        var journal = PhoneCaptureJournal(id: UUID(), title: "T", createdAt: Date(), format: .speech)
        XCTAssertNil(UnrecordedCapture.timelineShift(journal, session: nil), "no first sample: no times")
        journal.startedAt = Date(timeIntervalSince1970: 1_800_000_100)
        XCTAssertEqual(UnrecordedCapture.timelineShift(journal, session: nil), 0, "its own conversation's timeline")
        // Led by a Mac whose timeline began 100 s earlier (its clock 2 s ahead): its times move along.
        let mac = MultipointSession(conversationID: journal.id, role: .macLed(macID: UUID()),
                                    timelineStart: Date(timeIntervalSince1970: 1_800_000_002), leadClockOffset: 2)
        XCTAssertEqual(UnrecordedCapture.timelineShift(journal, session: mac) ?? -1, 100, accuracy: 0.001)

        XCTAssertFalse(UnrecordedCapture.hasContent(journal))
        journal.notes = "  \n "
        XCTAssertFalse(UnrecordedCapture.hasContent(journal), "blank notes are nothing")
        journal.photos = [CapturePhoto(fileName: "photo-a.jpg", capturedAt: Date(), time: 0)]
        XCTAssertTrue(UnrecordedCapture.hasContent(journal))
    }
}
