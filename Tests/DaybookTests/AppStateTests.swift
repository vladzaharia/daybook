import AVFoundation
import DaybookCore
import Foundation
import XCTest
@testable import Daybook

@MainActor
final class AppStateTests: XCTestCase {
    func testConcurrentImportsPreserveBothSourcesAndCurrentNotes() async throws {
        let (state, root, defaults) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: defaultsSuite(root)) }
        let id = state.newMeeting(title: "Concurrent import")
        let one = try audio(root, name: "one.wav", frequency: 220)
        let two = try audio(root, name: "two.wav", frequency: 440)
        async let first: Void = state.importFiles([one], source: .soundcore, attachTo: id)
        async let second: Void = state.importFiles([two], source: .imported, attachTo: id)
        await Task.yield()
        state.editNotes(id, text: "Keep this note while both sources are importing.")
        state.update(id) { $0.highlights.append(Highlight(time: 12, text: "Imported marker")) }
        try await first; try await second
        await state.flush()
        let store = try MeetingStore(rootURL: root)
        let saved = try await store.load(id)
        XCTAssertEqual(saved.tracks.count, 2)
        XCTAssertEqual(state.meetings.first?.tracks.count, 2)
        XCTAssertEqual(saved.notes, "Keep this note while both sources are importing.")
        XCTAssertTrue(saved.revisions.contains { $0.field == "notes" })
        XCTAssertEqual(saved.highlights.count, 1)
        XCTAssertEqual(saved.status, .imported)
    }

    func testSameRecordingIsNotImportedAgainAsAnotherMeeting() async throws {
        let (state, root, defaults) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: defaultsSuite(root)) }
        let one = try audio(root, name: "first.wav", frequency: 440)
        try await state.importFiles([one], source: .soundcore, attachTo: nil)
        await state.flush()
        let two = root.appendingPathComponent("renamed.wav")
        try FileManager.default.copyItem(at: one, to: two)
        try await state.importFiles([two], source: .imported, attachTo: nil)
        await state.flush()
        XCTAssertEqual(state.meetings.count, 1)
        XCTAssertEqual(state.meetings.first?.tracks.count, 1)
        XCTAssertTrue(state.notice?.contains("already") == true)
    }

    func testPendingRecordingCannotBeTrashed() async throws {
        let (state, root, defaults) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: defaultsSuite(root)) }
        let id = state.newMeeting()
        state.isStartingRecording = true
        state.trashMeeting(id)
        await state.flush()
        XCTAssertNotNil(state.meetings.first { $0.id == id })
        let store = try MeetingStore(rootURL: root)
        let saved = try await store.load(id)
        XCTAssertEqual(saved.id, id)
        state.isStartingRecording = false
    }

    func testRestartPreservesNotesAndPendingAudioWithoutModels() async throws {
        let (state, root, defaults) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: defaultsSuite(root)) }
        let one = try audio(root, name: "meeting.wav", frequency: 220)
        try await state.importFiles([one], source: .imported, attachTo: nil)
        let id = try XCTUnwrap(state.meetings.first?.id)
        state.editNotes(id, text: "The original note.")
        await state.flush()
        let restarted = AppState(libraryURL: root, defaults: defaults)
        await restarted.initialize()
        XCTAssertEqual(restarted.meetings.first?.notes, "The original note.")
        XCTAssertEqual(restarted.meetings.first?.tracks.count, 1)
        XCTAssertFalse(restarted.canProcess)
        XCTAssertFalse(restarted.automaticRecording)
    }

    func testSignedTimelineLabelsRetainEarlierWearableAudio() {
        XCTAssertEqual(TimeLabel.format(-15), "−00:15")
        XCTAssertEqual(TimeLabel.format(3661), "1:01:01")
        XCTAssertEqual(TimeLabel.format(.nan), "00:00")
    }

    func testRecoveryNeverResurrectsTrashedConversation() async throws {
        let (state, root, defaults) = try await makeState()
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: defaultsSuite(root)) }
        let id = state.newMeeting(title: "Intentionally trashed")
        await state.flush()
        let store = try MeetingStore(rootURL: root)
        _ = try await store.moveToTrash(id)
        let staged = root.appendingPathComponent("Staging/\(id.uuidString)")
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        _ = try audio(staged, name: "microphone.caf", frequency: 220)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .millisecondsSince1970
        let manifest = CaptureSessionManifest(id: UUID(), startedAt: Date(), hostTimeSeconds: 1, includeSystemAudio: false)
        try encoder.encode(manifest).write(to: staged.appendingPathComponent("capture-session.json"))
        let restarted = AppState(libraryURL: root, defaults: defaults)
        await restarted.initialize()
        await restarted.flush()
        XCTAssertTrue(restarted.meetings.isEmpty)
        XCTAssertNil(restarted.errorMessage)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("microphone.caf").path))
    }

    private func makeState() async throws -> (AppState, URL, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookAppTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: defaultsSuite(root))!
        let state = AppState(libraryURL: root, defaults: defaults)
        await state.initialize()
        XCTAssertTrue(state.isReady)
        XCTAssertNil(state.errorMessage)
        return (state, root, defaults)
    }
    private func defaultsSuite(_ root: URL) -> String { "local.daybook.tests.\(root.lastPathComponent)" }
    private func audio(_ root: URL, name: String, frequency: Double) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        for index in 0..<8_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * frequency * 2 * .pi / 16_000) * 0.2) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
