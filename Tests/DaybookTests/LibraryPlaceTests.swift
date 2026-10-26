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

    private func makeState() async throws -> (AppState, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookPlaceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
