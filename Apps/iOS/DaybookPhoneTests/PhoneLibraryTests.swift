import AVFoundation
import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// Filing a phone recording through the `PhoneLibrary` (DaybookKit's `LibraryController`).
@MainActor
final class PhoneLibraryTests: XCTestCase {
    func testAnUnavailableLibraryReportsFailureAndRetriesTheSameLocation() async throws {
        let root = try temporaryDirectory().appendingPathComponent("library")
        try Data("blocked".utf8).write(to: root)
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        do { try await library.reload(); XCTFail("An unopenable library must fail") }
        catch { XCTAssertEqual(library.rootURL.path, root.standardizedFileURL.path) }
        try FileManager.default.removeItem(at: root)
        try await library.reload()
        XCTAssertTrue(library.controller.isLoaded)
        XCTAssertEqual(library.rootURL.path, root.standardizedFileURL.path)
    }

    func testImportingAFileThatsBusyElsewhereDoesNotHoldUpTheMainActor() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root.appendingPathComponent("library"), installation: "INSTALL-1")
        try await library.reload()
        let file = root.appendingPathComponent("Voice memo.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_000)!
        buffer.frameLength = 8_000
        try AVAudioFile(forWriting: file, settings: format.settings).write(from: buffer)
        // Another writer (a File Provider downloading it) holds the file for a moment.
        let released = Date().addingTimeInterval(0.6)
        let writing = expectation(description: "the writer took the file")
        DispatchQueue.global().async {
            NSFileCoordinator().coordinate(writingItemAt: file, options: [], error: nil) { _ in
                writing.fulfill()
                Thread.sleep(until: released)
            }
        }
        await fulfillment(of: [writing], timeout: 5)
        var mainActorRan: Date?
        let ticker = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            mainActorRan = Date()
        }
        let filed = try await library.importFile(file, requestTranscription: false)
        await ticker.value
        XCTAssertEqual(filed.meeting.tracks.count, 1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(released), 0, "The import waited for the writer")
        XCTAssertLessThan(try XCTUnwrap(mainActorRan), released, "The main actor kept running while the import waited")
    }

    func testFilingRetainsRecoveryDataWhenJoinedNotesCannotBeSaved() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        var (recording, _) = try await record(into: library)
        let spare = try temporaryDirectory().appendingPathComponent("recovery")
        try FileManager.default.copyItem(at: recording.stagingDirectory, to: spare)
        _ = try await library.file(recording)
        recording.stagingDirectory = spare
        recording.notes += "\nA new joined note"
        recording.timedNotes.append(TimedNote(time: 6, text: "A new joined note"))
        let folder = root.appendingPathComponent("Meetings/\(recording.id.uuidString)")
        let primary = folder.appendingPathComponent("meeting.json")
        try FileManager.default.moveItem(at: primary, to: folder.appendingPathComponent("held.json"))
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        do {
            _ = try await library.fileRecording(recording, join: .init())
            XCTFail("A failed save must not finish filing")
        } catch {
            XCTAssertTrue(FileManager.default.fileExists(atPath: spare.path))
            XCTAssertTrue(library.controller.meeting(recording.id)?.notes.contains("A new joined note") == true)
        }
    }
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
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
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
        XCTAssertEqual(track.device, DeviceRecordingIdentity(kind: "daybook.iphone", serial: "INSTALL-1", recordingID: recording.recordingID.uuidString))
        XCTAssertNotEqual(recording.recordingID, recording.id, "the recording has its own ID, apart from its conversation's")
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

    func testPhotosTakenWhileRecordingAreFiledOnThePhoneTrack() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let rig = RecorderRig()
        let id = UUID()
        try await rig.recorder.start(in: library.stagingURL.appendingPathComponent(id.uuidString), id: id, title: "Whiteboard")
        rig.pump(4)
        let shutter = rig.clock.now().addingTimeInterval(-1)
        let keptPhoto = try await rig.recorder.addPhoto(syntheticCameraPhoto(capturedAt: shutter))
        let kept = try XCTUnwrap(keptPhoto)
        rig.pump(2)
        var recording = try await rig.stop()
        let spare = try temporaryDirectory().appendingPathComponent("spare")
        try FileManager.default.copyItem(at: recording.stagingDirectory, to: spare)

        let meeting = try await library.file(recording)
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertEqual(meeting.visiblePhotos.count, 1)
        let photo = try XCTUnwrap(meeting.visiblePhotos.first)
        XCTAssertEqual(photo.trackID, track.id)
        XCTAssertEqual(photo.time ?? -1, kept.time, accuracy: 1e-6)
        XCTAssertEqual(photo.time ?? -1, 3, accuracy: 1e-6)
        XCTAssertEqual(photo.capturedAt, shutter)
        XCTAssertEqual(photo.origin?.kind, PhoneDevice.kind)
        XCTAssertEqual(photo.origin?.serial, "INSTALL-1")
        XCTAssertEqual(meeting.timelineTime(of: photo) ?? -1, 3, accuracy: 1e-6)
        XCTAssertTrue(library.controller.hasLocalPhoto(photo, in: meeting.id))

        // Filing again after an interruption keeps one photo.
        recording.stagingDirectory = spare
        recording.audioURL = spare.appendingPathComponent(PhoneCaptureJournal.finalFileName)
        let again = try await library.file(recording)
        XCTAssertEqual(again.visiblePhotos.map(\.id), [photo.id])
    }

    func testAPhotoFromTheCameraAfterStopJoinsTheFiledConversation() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let rig = RecorderRig()
        let model = PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]))
        try await model.startRecording()
        let recordingID = rig.recorder.captureID
        rig.pump(3)
        await model.addPhoto(syntheticCameraPhoto(capturedAt: rig.clock.now()), recording: recordingID)
        rig.pump(2)
        // A Mac stopped the recording while the camera was still open.
        try await model.stopRecording()
        let late = rig.clock.now()
        await model.addPhoto(syntheticCameraPhoto(capturedAt: late, size: CGSize(width: 50, height: 50)), recording: recordingID)
        XCTAssertNil(model.notice)

        let filed = try XCTUnwrap(library.conversations.first)
        XCTAssertEqual(filed.visiblePhotos.count, 2)
        let during = try XCTUnwrap(filed.visiblePhotos.first { $0.trackID != nil })
        XCTAssertEqual(during.trackID, filed.tracks.first?.id)
        XCTAssertEqual(during.time ?? -1, 3, accuracy: 1e-6)
        let after = try XCTUnwrap(filed.visiblePhotos.first { $0.trackID == nil })
        XCTAssertEqual(after.capturedAt, late)
        XCTAssertEqual(after.origin?.serial, "INSTALL-1", "the library's identity, as on its recordings")
        XCTAssertEqual(filed.timelineTime(of: after) ?? -1, 5, accuracy: 1e-3, "placed by the phone track's clock")
    }

    func testFilingAgainNeverDuplicates() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
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
        let reopened = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        try await reopened.reload()
        XCTAssertEqual(reopened.openRequests(for: again.id).count, 1)
    }

    func testASecondRecordingIntoTheSameConversationKeepsItsAudio() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let conversation = UUID()
        func record(seconds: TimeInterval) async throws -> PhoneRecording {
            let rig = RecorderRig()
            let recordingID = UUID()
            try await rig.recorder.start(in: library.stagingURL.appendingPathComponent(recordingID.uuidString), id: conversation,
                                         recordingID: recordingID, title: "Design review")
            rig.pump(seconds)
            return try await rig.stop()
        }
        let first = try await record(seconds: 2)
        _ = try await library.fileRecording(first, join: .init())
        // A Mac records into the same conversation later and asks this iPhone again.
        let second = try await record(seconds: 3)
        XCTAssertEqual(second.id, first.id)
        XCTAssertNotEqual(second.recordingID, first.recordingID)
        let filed = try await library.fileRecording(second, join: .init())
        XCTAssertEqual(filed.meeting.tracks.count, 2, "the second recording is a track of its own")
        let tracks = filed.meeting.tracks.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
        XCTAssertEqual(tracks.map(\.deviceRecordingID), [first.recordingID.uuidString, second.recordingID.uuidString])
        XCTAssertEqual(tracks.last?.duration ?? 0, 3, accuracy: 0.001)
        let stored = try await library.audioURL(for: try XCTUnwrap(tracks.last), in: conversation)
        XCTAssertEqual(try AVAudioFile(forReading: stored).length, 3 * 48_000, "its own audio, not the first recording's")
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.stagingDirectory.path))
    }

    func testAJournalFromBeforeRecordingIDsRecoversUnderItsConversationsID() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        let rig = RecorderRig()
        let id = UUID()
        let folder = library.stagingURL.appendingPathComponent(id.uuidString)
        try await rig.recorder.start(in: folder, id: id, title: "Older")
        rig.pump(2)
        await rig.recorder.flush()
        rig.recorder.prepareForTermination()
        // As v0.3.0 wrote it: no recording ID.
        let url = PhoneCaptureJournal.url(in: folder)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["recordingID"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let recording = try await PhoneRecorder.recover(in: folder)
        XCTAssertEqual(recording.recordingID, id)
        let meeting = try await library.file(recording)
        XCTAssertEqual(meeting.tracks.first?.deviceRecordingID, id.uuidString, "named as it was before")
    }

    // MARK: Joining a conversation a Mac leads

    /// A recording made with notes at 2 s and 5 s (the second paragraph repeated at 7 s) and a bookmark at 5 s.
    private func recordWithNotes(into library: PhoneLibrary, conversation: UUID) async throws -> PhoneRecording {
        let rig = RecorderRig()
        let recordingID = UUID()
        try await rig.recorder.start(in: library.stagingURL.appendingPathComponent(recordingID.uuidString), id: conversation,
                                     recordingID: recordingID, title: "Conversation at 10:02")
        rig.pump(2)
        rig.recorder.editNotes("Decisions")
        rig.pump(3)
        rig.recorder.editNotes("Decisions\nOwners")
        rig.recorder.addBookmark()
        rig.pump(2)
        rig.recorder.editNotes("Decisions\nOwners\nOwners")
        rig.pump(1)
        return try await rig.stop()
    }

    func testJoiningTheMacsSyncedConversationKeepsItsOwnFieldsAndHoldsTheNotes() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        try await library.reload()
        let conversation = UUID()
        let macDate = Date(timeIntervalSince1970: 1_800_000_000)
        // The Mac's conversation synced here while it records.
        library.controller.add(Meeting(id: conversation, title: "Design review", date: macDate, status: .recording))
        let recording = try await recordWithNotes(into: library, conversation: conversation)

        let filed = try await library.fileRecording(recording, join: .init(estimatedOffset: 30, title: "Not this", date: Date()))
        let meeting = filed.meeting
        XCTAssertEqual(meeting.title, "Design review", "the Mac's title stays")
        XCTAssertEqual(meeting.date, macDate)
        XCTAssertEqual(meeting.status, .recording, "the conversation's status is the Mac's")
        XCTAssertNil(meeting.errorMessage)
        XCTAssertEqual(meeting.notes, "Decisions\nOwners\nOwners", "the notes are written")
        XCTAssertEqual(meeting.paragraphTimes(), [32, 35, 37], "each paragraph keeps its own time, by the clock estimate")
        let track = try XCTUnwrap(meeting.tracks.first)
        XCTAssertNil(track.offset, "the Mac places it")
        XCTAssertEqual(track.alignment?.method, .pending)
        XCTAssertEqual(track.alignment?.heldNoteIDs, recording.timedNotes.map(\.id), "held by the phone's recording until it's placed")
        XCTAssertEqual(track.alignment?.captureOffset, 30)
        XCTAssertEqual(meeting.highlights.map(\.trackID), [track.id], "the bookmark follows the phone's recording")
        XCTAssertEqual(meeting.highlights.map(\.time), [5])
        XCTAssertFalse(FileManager.default.fileExists(atPath: recording.stagingDirectory.path))

        // Once the Mac places the recording 28 s in, the notes follow it.
        var placed = meeting
        placed.applyPlacements([track.id: SourceAlignment(method: .audio, offset: 28, confidence: 0.9)])
        XCTAssertEqual(placed.paragraphTimes(), [30, 33, 35])
    }

    func testJoiningAConversationWithTheMacsRecordingKeepsEveryNoteTimed() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
        try await library.reload()
        let conversation = UUID()
        library.controller.add(Meeting(id: conversation, title: "Design review", date: Date(), notes: "Decisions",
                                       status: .imported, timedNotes: [TimedNote(time: 1, text: "Decisions")]))
        // The Mac's own recording is here already.
        let macRig = RecorderRig()
        try await macRig.recorder.start(in: try temporaryDirectory().appendingPathComponent("mac"), title: "Mac")
        macRig.pump(4)
        let macAudio = try await macRig.stop()
        await library.controller.acquireLock()
        _ = try await library.controller.ingest(macAudio.audioURL, into: conversation, provenance: RecordingProvenance(source: .microphone, offset: 0))
        library.controller.releaseLock()

        let recording = try await recordWithNotes(into: library, conversation: conversation)
        // Without a join (filed again after a restart, say), the Mac's recording still makes it one.
        let meeting = try await library.fileRecording(recording).meeting
        XCTAssertEqual(meeting.tracks.count, 2)
        XCTAssertEqual(meeting.notes, "Decisions\nDecisions\nOwners\nOwners", "a paragraph the Mac also typed is still the phone's own")
        XCTAssertEqual(meeting.paragraphTimes(), [1, 2, 5, 7], "timed by the phone's clock, held until the phone's recording is placed")
        let phoneTrack = try XCTUnwrap(meeting.tracks.first { $0.deviceKind == PhoneDevice.kind })
        XCTAssertNil(phoneTrack.offset)
        XCTAssertEqual(phoneTrack.alignment?.heldNoteIDs?.count, 3)
        XCTAssertEqual(meeting.title, "Design review")

        // Filed again (a retry after a failure), nothing doubles.
        let twice = try await library.fileRecording(recording, join: .init()).meeting
        XCTAssertEqual(twice.notes, meeting.notes)
        XCTAssertEqual(twice.highlights.count, 1)
    }

    func testJoiningAConversationThatHasntSyncedMakesItAsTheMacHasIt() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        try await library.reload()
        let conversation = UUID()
        let macDate = Date(timeIntervalSince1970: 1_800_000_000)
        let recording = try await recordWithNotes(into: library, conversation: conversation)
        let meeting = try await library.fileRecording(recording, join: .init(estimatedOffset: nil, title: "Design review", date: macDate)).meeting
        XCTAssertEqual(meeting.title, "Design review", "the Mac's title, which came with its request, not a placeholder")
        XCTAssertEqual(meeting.date, macDate)
        XCTAssertEqual(meeting.status, .draft, "its status is left for the Mac's copy")
        XCTAssertEqual(meeting.paragraphTimes(), [2, 5, 7])
        XCTAssertEqual(meeting.tracks.first?.alignment?.heldNoteIDs?.count, 3)
    }

    func testAppModelRecordsAndFilesEndToEnd() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
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

    func testRecordingIntoANewNoteFilesIntoItAfterItsNotes() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        try await library.reload()
        let rig = RecorderRig()
        let model = PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]))
        let session = ReadingSession()
        let note = session.newNote(in: library.controller)
        library.controller.update(note) { $0.notes = "Agenda" }
        let title = try XCTUnwrap(library.controller.meeting(note)?.title)
        XCTAssertTrue(title.hasPrefix("Note at "), title)

        try await model.startRecording(into: note, title: title, multipoint: nil)
        XCTAssertEqual(rig.recorder.captureID, note)
        rig.pump(1)
        model.editNotes("Said during the call")
        rig.pump(1)
        try await model.stopRecording()

        XCTAssertEqual(library.conversations.count, 1, "no second conversation")
        let filed = try XCTUnwrap(library.controller.meeting(note))
        XCTAssertEqual(filed.title, title)
        XCTAssertEqual(filed.tracks.count, 1)
        XCTAssertEqual(filed.notes, "Agenda\nSaid during the call")
    }

    func testTwoStartsAtOnceLeaveTheOneThatWonAlone() async throws {
        let library = PhoneLibrary(rootURL: try temporaryDirectory(), installation: "INSTALL-1")
        let rig = RecorderRig()
        let model = PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                                  options: LaunchOptions(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]))
        // A Mac's request and an intent arrive together.
        let conversation = UUID()
        let session = MultipointSession(conversationID: conversation, role: .macLed(macID: UUID()),
                                        macs: [MultipointSession.Mac(id: UUID(), name: "Studio Mac", state: .recording, startedAt: nil, startedByPhone: false)])
        let led = Task { try await model.startRecording(into: conversation, title: "Design review", multipoint: session) }
        let intent = Task { try await model.startRecording() }
        let ledFailed: Bool
        do { try await led.value; ledFailed = false } catch { ledFailed = true }
        try await intent.value
        XCTAssertTrue(model.recorder.isActive)
        if model.recorder.captureID == conversation {
            XCTAssertFalse(ledFailed)
            XCTAssertEqual(model.multipoint?.conversationID, conversation, "the loser didn't clear the winner's session")
        } else {
            XCTAssertTrue(ledFailed, "the Mac's conversation can't start while another records")
            XCTAssertNil(model.multipoint)
        }
        rig.pump(1)
        try await model.stopRecording()
        XCTAssertEqual(library.conversations.count, 1)
    }

    func testStopFilesTheRecordingEvenWhenTheCallerIsCancelled() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
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
        let library = PhoneLibrary(rootURL: root, installation: "INSTALL-1")
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

    // MARK: Files opened in Daybook

    /// A second of tone as a WAV file, as another app might hand over.
    private func audioFile(at url: URL, step: Float = 0.17) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        for index in 0..<16_000 { buffer.floatChannelData![0][index] = 0.2 * sin(Float(index) * step) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                                                              AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        try file.write(from: buffer)
    }

    /// iOS copies a file another app opens in Daybook into Documents/Inbox. Once imported, that copy
    /// goes; a failed import keeps it, and a file from anywhere else is never removed.
    func testAnImportedInboxCopyIsRemovedButAFailedOneAndOutsideFilesStay() async throws {
        let root = try temporaryDirectory()
        let library = PhoneLibrary(rootURL: root.appendingPathComponent("Library"), installation: "INSTALL-1")
        library.inboxURL = root.appendingPathComponent("Documents/Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: library.inboxURL, withIntermediateDirectories: true)

        let shared = library.inboxURL.appendingPathComponent("Voice memo.wav")
        try audioFile(at: shared)
        let filed = try await library.importFile(shared, requestTranscription: false)
        XCTAssertEqual(filed.meeting.title, "Voice memo")
        XCTAssertFalse(FileManager.default.fileExists(atPath: shared.path), "the inbox copy goes once imported")

        let broken = library.inboxURL.appendingPathComponent("Broken.m4a")
        try Data("not audio".utf8).write(to: broken)
        do {
            _ = try await library.importFile(broken, requestTranscription: false)
            XCTFail("imported something that isn't audio")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.path), "kept to try again")

        let picked = root.appendingPathComponent("Files/Interview.wav")
        try FileManager.default.createDirectory(at: picked.deletingLastPathComponent(), withIntermediateDirectories: true)
        try audioFile(at: picked, step: 0.31)
        _ = try await library.importFile(picked, requestTranscription: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: picked.path), "a file chosen in Files is the person's")
        XCTAssertEqual(library.conversations.count, 2)
    }
}
