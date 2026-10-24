import AVFoundation
import DaybookCore
import XCTest
@testable import DaybookPhone

/// Filing a phone recording through the `PhoneLibrary` (DaybookKit's `LibraryController`).
@MainActor
final class PhoneLibraryTests: XCTestCase {
    private func record(into library: PhoneLibrary, seconds: TimeInterval = 6) async throws -> (PhoneRecording, RecorderRig) {
        let rig = RecorderRig()
        let id = UUID()
        try await rig.recorder.start(in: library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: "Design review")
        rig.pump(2)
        rig.recorder.editNotes("Decisions")
        rig.pump(3)
        rig.recorder.editNotes("Decisions\nOwners")
        rig.recorder.addBookmark()
        rig.pump(seconds - 5)
        return (try await rig.stop(), rig)
    }

    func testFilingCreatesAConversationWithAPhoneMicrophoneTrackAndATranscribeRequest() async throws {
        let root = try temporaryDirectory()
        let library = try PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let (recording, _) = try await record(into: library)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recording.stagingDirectory.path))

        let meeting = try await library.file(recording)
        XCTAssertEqual(meeting.id, recording.id)
        XCTAssertEqual(meeting.title, "Design review")
        XCTAssertEqual(meeting.status, .imported)
        XCTAssertEqual(meeting.date, recording.startedAt)
        XCTAssertEqual(meeting.notes, "Decisions\nOwners")
        XCTAssertEqual(meeting.paragraphTimes(), [2, 5])
        XCTAssertEqual(meeting.highlights.map(\.time), [5])
        XCTAssertNil(meeting.highlights.first?.trackID)

        XCTAssertEqual(meeting.tracks.count, 1)
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertEqual(track.source, .microphone)
        XCTAssertEqual(track.device, DeviceRecordingIdentity(kind: "daybook.iphone", serial: "INSTALL-1", recordingID: recording.id.uuidString))
        XCTAssertEqual(track.duration ?? 0, 6, accuracy: 0.001)
        XCTAssertEqual(track.offset, 0)
        XCTAssertEqual(track.startedAt, recording.startedAt)
        XCTAssertEqual(track.capture?.method, "iphone-microphone")
        XCTAssertFalse(track.sha256.isEmpty)
        XCTAssertEqual(track.fileName, "iPhone recording.m4a")

        let stored = try await library.audioURL(for: track, in: meeting.id)
        XCTAssertEqual(try AVAudioFile(forReading: stored).length, 6 * 48_000)

        let requests = library.openRequests(for: meeting.id)
        XCTAssertEqual(requests.map(\.mode), [.newAudio])
        XCTAssertEqual(requests.first?.requestedBy.name, ProcessingRequest.Device.currentName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.stagingDirectory.path), "staging is removed once filed")
        XCTAssertEqual(library.conversations.map(\.id), [meeting.id])

        // The Mac's store reads it back unchanged.
        let reopened = try MeetingStore(rootURL: root)
        let loaded = try await reopened.load(meeting.id)
        XCTAssertEqual(loaded.tracks, meeting.tracks)
        XCTAssertEqual(loaded.timedNotes, meeting.timedNotes)
    }

    func testFilingAgainNeverDuplicates() async throws {
        let root = try temporaryDirectory()
        let library = try PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        var (recording, _) = try await record(into: library)
        // Keep a copy, as if filing were interrupted after the import and retried.
        let spare = try temporaryDirectory().appendingPathComponent("spare")
        try FileManager.default.copyItem(at: recording.stagingDirectory, to: spare)
        try await library.file(recording)

        recording.stagingDirectory = spare
        recording.audioURL = spare.appendingPathComponent(PhoneCaptureJournal.finalFileName)
        let again = try await library.file(recording)
        XCTAssertEqual(again.tracks.count, 1)
        XCTAssertEqual(again.highlights.count, 1)
        XCTAssertEqual(library.openRequests(for: again.id).count, 1)
        XCTAssertEqual(library.conversations.count, 1)

        // A fresh library instance reads the same requests from disk.
        let reopened = try PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        try await reopened.reload()
        XCTAssertEqual(reopened.openRequests(for: again.id).count, 1)
    }

    func testAppModelRecordsAndFilesEndToEnd() async throws {
        let root = try temporaryDirectory()
        let library = try PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let rig = RecorderRig()
        let model = PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]))
        try await model.startRecording()
        XCTAssertTrue(model.isRecordingActive)
        rig.pump(1)
        model.editNotes("Kickoff")
        rig.pump(1)
        let time = try await model.addBookmark()
        XCTAssertEqual(time, 2)
        try await model.stopRecording()
        XCTAssertFalse(model.isRecordingActive)
        let filed = try XCTUnwrap(library.conversations.first)
        XCTAssertEqual(model.lastFiledID, filed.id)
        XCTAssertEqual(filed.paragraphTimes(), [1])
        XCTAssertEqual(filed.highlights.map(\.time), [2])
        XCTAssertEqual(library.openRequests(for: filed.id).map(\.mode), [.newAudio])
        do {
            try await model.stopRecording()
            XCTFail("stopping twice should say nothing is recording")
        } catch {}
    }

    func testStopFilesTheRecordingEvenWhenTheCallerIsCancelled() async throws {
        let root = try temporaryDirectory()
        let library = try PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let rig = RecorderRig()
        let model = PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]))
        try await model.startRecording()
        rig.pump(2)
        // An intent the system gave up on, or a demo script that was cancelled, still saves.
        let caller = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            try await model.stopRecording()
        }
        try await caller.value
        XCTAssertEqual(library.conversations.count, 1)
        XCTAssertNil(model.notice)
        XCTAssertTrue(PhoneRecorder.pendingCaptures(in: library.stagingURL).isEmpty)
    }

    func testLaunchFilesWhatAPreviousRunLeftInStaging() async throws {
        let root = try temporaryDirectory()
        let library = try PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let rig = RecorderRig()
        let id = UUID()
        try await rig.recorder.start(in: library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: "Killed")
        rig.pump(3)
        rig.recorder.addBookmark()
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()   // the process ends here

        let relaunched = PhoneAppModel(recorder: RecorderRig().recorder, library: library, posture: DevicePosture(),
                                       options: LaunchOptions(arguments: [], environment: [:]))
        await relaunched.launch()
        XCTAssertEqual(library.conversations.map(\.id), [id])
        XCTAssertEqual(library.conversations.first?.highlights.count, 1)
        XCTAssertEqual(library.conversations.first?.tracks.first?.duration ?? 0, 3, accuracy: 0.001)
        XCTAssertEqual(relaunched.notice, "Recovered a recording Daybook was making when it quit.")
        XCTAssertTrue(PhoneRecorder.pendingCaptures(in: library.stagingURL).isEmpty)
    }
}
