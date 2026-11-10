import AVFoundation
import DaybookCaptions
import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// A recording in progress is kept until unlock (class B, `StagingProtection`): its folder and everything the recorder
/// writes in it, and its live captions. Stop on a locked iPhone saves it (the journal says `stopping`) and joins and files
/// it once a pretend iPhone is unlocked; recovery never deletes a folder it couldn't read.
///
/// The simulator neither locks nor applies data protection: its Foundation leaves the class out of what it writes
/// (every file reads class C there, whatever was asked). So a pretend iPhone (`PhoneAppEnvironment.protectedData`) and
/// files made unreadable stand in for a locked one, and the folder's class is given through the file system, as the
/// iPhone's Foundation gives it, to check that what's made in it keeps it. Synthetic audio; temporary libraries.
@MainActor
final class StagingProtectionTests: XCTestCase {
    /// The file system's class numbers (`F_GETPROTECTIONCLASS`).
    private static let classes: [Int32: FileProtectionType] = [
        1: .complete, 2: .completeUnlessOpen, 3: .completeUntilFirstUserAuthentication, 4: FileProtectionType.none]

    /// A file's or folder's data protection class, as the file system keeps it.
    private func protection(_ url: URL) -> FileProtectionType? {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        return Self.classes[fcntl(descriptor, F_GETPROTECTIONCLASS)]
    }

    /// Gives a folder a class through the file system, as the iPhone's Foundation does for
    /// `createDirectory(attributes: [.protectionKey: …])`.
    private func give(_ folder: URL, _ type: FileProtectionType) throws {
        let descriptor = open(folder.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoPermission) }
        defer { close(descriptor) }
        let number = try XCTUnwrap(Self.classes.first { $0.value == type }?.key)
        XCTAssertEqual(fcntl(descriptor, F_SETPROTECTIONCLASS, number), 0, "the file system takes a class")
    }

    private func makeModel(rig: RecorderRig, lock: PretendLock? = nil, time: (any BackgroundTime)? = nil) throws -> PhoneAppModel {
        var environment = try PhoneAppEnvironment.test(self)
        if let lock { environment.protectedData = lock.protectedData }
        if let time { environment.backgroundTime = time }
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        return PhoneAppModel(recorder: rig.recorder, library: library, posture: DevicePosture(),
                             options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                             environment: environment)
    }

    // MARK: The class

    /// Everything a recording in progress writes asks for class B: its folder (which what's made in it takes, the parts
    /// AVFoundation writes too), the journal and photos (each a new file), and its live captions.
    func testBehaviorARecordingInProgressAsksToBeKeptUntilUnlock() {
        XCTAssertEqual(StagingProtection.type, .completeUnlessOpen)
        XCTAssertEqual(StagingProtection.writing, .completeFileProtectionUnlessOpen)
        XCTAssertEqual(LiveCaptionStore.defaultProtection, .completeUnlessOpen, "the iPhone's captions")
        XCTAssertEqual(LiveCaptionStore(libraryRoot: FileManager.default.temporaryDirectory).protection, .completeUnlessOpen)
    }

    /// In a class B staging folder, the parts AVFoundation writes, the journal, a photo, and the joined recording are
    /// class B, and the recording keeps it once it's filed into the library (copied into `Meetings/`).
    func testBehaviorWhatsMadeInTheStagingFolderAndFiledKeepsItsClass() async throws {
        let rig = RecorderRig()
        let folder = try temporaryDirectory().appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try give(folder, StagingProtection.type)
        let library = PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1")
        try await library.reload()
        XCTAssertNotEqual(protection(library.rootURL), .completeUnlessOpen, "the library's other files aren't")

        try await rig.recorder.start(in: folder, title: "Kept until unlock")
        rig.pump(3)
        let photo = try await rig.recorder.addPhoto(syntheticCameraPhoto(capturedAt: rig.clock.now()))
        // A call: the first part closes, a second opens, and Stop joins them by copying their packets.
        rig.session.send(.interruptionBegan(reason: nil))
        try await waitUntil("the first part to close") { rig.recorder.isPaused }
        rig.session.send(.interruptionEnded(shouldResume: true))
        try await waitUntil("recording to resume") { rig.recorder.state == .recording }
        rig.pump(2)
        await rig.recorder.flush()

        XCTAssertEqual(protection(folder), .completeUnlessOpen, "the staging folder")
        XCTAssertEqual(protection(PhoneCaptureJournal.url(in: folder)), .completeUnlessOpen, "the journal, a new file each write")
        for index in 0...1 {
            XCTAssertEqual(protection(folder.appendingPathComponent(CaptureSegment.fileName(index: index))), .completeUnlessOpen,
                           "part \(index), written by AVFoundation in the folder")
        }
        XCTAssertEqual(protection(folder.appendingPathComponent(try XCTUnwrap(photo).fileName)), .completeUnlessOpen, "a photo")

        let recording = try await rig.stop()
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).finalFile?.joined, true)
        XCTAssertEqual(protection(recording.audioURL), .completeUnlessOpen, "the joined recording")
        let meeting = try await library.file(recording)
        let filed = try await library.audioURL(for: try XCTUnwrap(meeting.tracks.first), in: meeting.id)
        XCTAssertEqual(protection(filed), .completeUnlessOpen, "filed, it keeps its class")
        XCTAssertNotEqual(protection(filed.deletingLastPathComponent()), .completeUnlessOpen, "in a folder that isn't")
    }

    // MARK: Stop while locked

    /// Stop on a locked iPhone: the capture ends, the journal says `stopping`, everything else ends as Stop ends it, and
    /// Daybook can record again; the Live Activity says it's saved and finishes on unlock. Recovery leaves it be. Once
    /// the pretend iPhone is unlocked it's joined and filed, whole, and its activity goes.
    func testBehaviorAStopWhileLockedIsSavedAndFinishesOnceUnlocked() async throws {
        let rig = RecorderRig()
        let lock = PretendLock(locked: false)
        let time = CountedBackgroundTime()
        let model = try makeModel(rig: rig, lock: lock, time: time)
        try await model.startRecording()
        rig.pump(3)
        model.editNotes("Said while locked")
        try await model.addBookmark()
        let id = try XCTUnwrap(model.recorder.captureID)
        let folder = try XCTUnwrap(model.recorder.stagingDirectory)
        model.scenePhaseChanged(.background)
        lock.lock()

        try await model.stopRecording()
        XCTAssertEqual(model.recorder.state, .idle, "free to record again")
        XCTAssertFalse(model.isFiling)
        XCTAssertEqual(try PhoneCaptureJournal.load(from: folder).state, .stopping, "saved: whole on disk, and it says so")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent(PhoneCaptureJournal.finalFileName).path),
                       "nothing joined while locked")
        XCTAssertEqual(model.lastStopResult.sentence, RecordingWords.savedUntilUnlock, "what Siri says")
        XCTAssertNil(model.lastFiling)
        XCTAssertEqual(model.waitsForUnlock(id), true)
        XCTAssertNil(model.library.controller.meeting(id))
        let ended = try XCTUnwrap(model.activities.endedOn)
        XCTAssertEqual(ended.title(isStale: false), "Saved")
        XCTAssertEqual(ended.endLine, "Finishes when you unlock iPhone")
        XCTAssertEqual(RecordingActivityController.dismissal(for: ended, now: Date()), .default, "stays until it's finished")
        XCTAssertNil(model.notice, "nothing to say in the app")

        // Recovery, run again meanwhile, leaves it to the stop.
        await model.recoverLeftovers()
        XCTAssertTrue(FileManager.default.fileExists(atPath: PhoneCaptureJournal.url(in: folder).path))
        XCTAssertNil(model.library.controller.meeting(id))
        XCTAssertNil(model.notice)

        // A look while still locked changes nothing.
        model.protectedDataMayBeAvailable()
        XCTAssertEqual(model.waitsForUnlock(id), true)

        lock.unlock()
        try await waitUntil("filed once unlocked") { model.lastFiling != nil && model.waitsForUnlock(id) == nil }
        guard case .saved(let filed, _)? = model.lastFiling else { return XCTFail("filed: \(String(describing: model.lastFiling))") }
        XCTAssertEqual(filed, id)
        let meeting = try XCTUnwrap(model.library.controller.meeting(id))
        XCTAssertEqual(meeting.tracks.count, 1)
        XCTAssertEqual(meeting.tracks.first?.duration ?? 0, 3, accuracy: 0.05, "whole")
        XCTAssertEqual(meeting.notes, "Said while locked")
        XCTAssertEqual(meeting.highlights.count, 1)
        XCTAssertFalse(meeting.tracks.first?.capture?.notes?.contains(RecordingWords.savedAfterInterruptedSave) ?? false,
                       "a Stop, not a recovery")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "staging goes once it's filed")
        XCTAssertEqual(model.activities.dismissed, [id], "“Finishes when you unlock iPhone” goes")
        XCTAssertNil(model.notice)
        XCTAssertEqual(time.held, [], "every bit of background time given back")
        XCTAssertGreaterThanOrEqual(time.begun, 2, "Stop's, and the wait's")
    }

    /// Recording again while the last one waits for an unlock: the new one is its own, and the waiting one is filed
    /// apart once the iPhone is unlocked.
    func testBehaviorRecordingAgainWhileOneWaitsForAnUnlock() async throws {
        let rig = RecorderRig()
        let lock = PretendLock(locked: false)
        let model = try makeModel(rig: rig, lock: lock)
        try await model.startRecording()
        rig.pump(2)
        let first = try XCTUnwrap(model.recorder.captureID)
        lock.lock()
        try await model.stopRecording()
        XCTAssertEqual(model.waitsForUnlock(first), true)

        try await model.startRecording()
        rig.pump(1)
        let second = try XCTUnwrap(model.recorder.captureID)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(model.recorder.state, .recording)
        lock.unlock()
        try await waitUntil("the first is filed") { model.library.controller.meeting(first) != nil }
        XCTAssertEqual(model.recorder.state, .recording, "the first's filing leaves the second recording")
        XCTAssertEqual(model.recorder.captureID, second)
        try await model.stopRecording()
        try await waitUntil("both are filed") { model.library.controller.meeting(second) != nil }
        XCTAssertEqual(model.library.controller.meeting(first)?.tracks.first?.duration ?? 0, 2, accuracy: 0.05)
        XCTAssertEqual(model.library.controller.meeting(second)?.tracks.first?.duration ?? 0, 1, accuracy: 0.05)
    }

    /// Two recordings stopped while locked finish after the one unlock, and the recorder after Stop hears of the last
    /// one's, whichever is filed first.
    func testBehaviorTheLastStopSaysWhereItsRecordingWentWhicheverFinishesFirst() async throws {
        let rig = RecorderRig()
        let lock = PretendLock(locked: true)
        let model = try makeModel(rig: rig, lock: lock)
        try await model.startRecording()
        rig.pump(1)
        let first = try XCTUnwrap(model.recorder.captureID)
        try await model.stopRecording()
        try await model.startRecording()
        rig.pump(1)
        let second = try XCTUnwrap(model.recorder.captureID)
        try await model.stopRecording()
        XCTAssertEqual(model.waitsForUnlock(first), true)
        XCTAssertEqual(model.waitsForUnlock(second), true)

        lock.unlock()
        try await waitUntil("both are filed") {
            model.waitsForUnlock(first) == nil && model.waitsForUnlock(second) == nil
                && model.library.controller.meeting(first) != nil && model.library.controller.meeting(second) != nil
        }
        guard case .saved(let id, _)? = model.lastFiling else { return XCTFail("filed: \(String(describing: model.lastFiling))") }
        XCTAssertEqual(id, second)
        XCTAssertTrue(PhoneRecorder.pendingCaptures(in: model.library.stagingURL).isEmpty)
    }

    // MARK: Never "no audio" for audio it couldn't read

    /// A part that's there but can't be opened (as on a locked iPhone) is never "No audio was recorded": the join says
    /// it's locked, and recovery keeps the folder.
    func testBehaviorAPartItCantOpenIsNeverNoAudioAndItsFolderStays() async throws {
        let rig = RecorderRig()
        let model = try makeModel(rig: rig)
        let folder = model.library.stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appendingPathComponent(CaptureSegment.fileName(index: 0))
        let frames = try CaptureFiles.writeClosedSegment(to: part, seconds: 2, frequency: 440)
        var journal = PhoneCaptureJournal(id: UUID(), title: "Unreadable", createdAt: Date(), format: CaptureFiles.format)
        journal.state = .stopping
        journal.segments = [CaptureSegment(index: 0, fileName: part.lastPathComponent, startOffset: 0, frameCount: frames, closed: true,
                                           firstSampleHostTime: 0, clockAnchors: [], notes: nil)]
        try journal.write(to: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: part.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path) }

        XCTAssertTrue(StagingProtection.cannotOpen(part))
        XCTAssertFalse(StagingProtection.canReadAll(in: folder))
        do {
            _ = try await RecordingAssembler.assemble(PhoneCaptureFinisher.pieces(journal, in: folder),
                                                      into: folder.appendingPathComponent(PhoneCaptureJournal.finalFileName),
                                                      format: journal.format)
            XCTFail("joined a part it couldn't open")
        } catch {
            XCTAssertEqual(error as? PhoneRecorderError, .locked, "never “No audio was recorded”")
        }

        await model.recoverLeftovers()
        XCTAssertTrue(FileManager.default.fileExists(atPath: part.path), "the folder stays, its audio with it")
        XCTAssertNil(model.library.controller.meeting(journal.id))
        XCTAssertNotEqual(model.notice, "No audio was recorded.")

        // Readable again, it's filed whole.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: part.path)
        await model.recoverLeftovers()
        XCTAssertEqual(model.library.controller.meeting(journal.id)?.tracks.first?.duration ?? 0, 2, accuracy: 0.05)
    }

    /// Recovery on a locked iPhone reads nothing and deletes nothing: a journal it can't read, with no notes, stays, and
    /// recovery runs again once the iPhone is unlocked.
    func testBehaviorRecoveryWhileLockedWaitsAndRunsAgainOnUnlock() async throws {
        let rig = RecorderRig()
        let lock = PretendLock(locked: true)
        let model = try makeModel(rig: rig, lock: lock)
        let folder = model.library.stagingURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let part = folder.appendingPathComponent(CaptureSegment.fileName(index: 0))
        let frames = try CaptureFiles.writeClosedSegment(to: part, seconds: 1, frequency: 440)
        var journal = PhoneCaptureJournal(id: UUID(), title: "Left while locked", createdAt: Date(), format: CaptureFiles.format)
        journal.segments = [CaptureSegment(index: 0, fileName: part.lastPathComponent, startOffset: 0, frameCount: frames, closed: false,
                                           firstSampleHostTime: 0, clockAnchors: [], notes: nil)]
        try journal.write(to: folder)
        let journalURL = PhoneCaptureJournal.url(in: folder)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: journalURL.path)

        await model.recoverLeftovers()
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path), "kept")
        XCTAssertNil(model.notice, "nothing to say: it waits for the unlock")
        XCTAssertTrue(model.recoveryWaitsForUnlock)
        XCTAssertThrowsError(try PhoneCaptureJournal.load(from: folder)) { error in
            XCTAssertEqual(error as? PhoneRecorderError, .locked, "a journal it can't read is never one with nothing in it")
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
        lock.unlock()
        try await waitUntil("recovered once unlocked") { model.library.controller.meeting(journal.id) != nil }
        XCTAssertFalse(model.recoveryWaitsForUnlock)
    }

    // MARK: Captions

    /// Captions that can't be read back (as on a locked iPhone) read as the copy last written, so filing them with
    /// their recording still works.
    func testBehaviorCaptionsFallBackToTheLastCopyWritten() async throws {
        let store = LiveCaptionStore(libraryRoot: try temporaryDirectory("captions"))
        let captions = LiveCaptions(meetingID: UUID(), captureID: UUID(), localeIdentifier: "en_US",
                                    segments: [LiveCaptionSegment(start: 0, end: 1.5, text: "Said with the iPhone locked", isTentative: false)])
        try await store.save(captions)
        let url = store.url(for: captions.key)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        XCTAssertNil(try? Data(contentsOf: url), "the file can't be read")

        XCTAssertEqual(store.captions(for: captions.key)?.segments.map(\.text), ["Said with the iPhone locked"])
        let track = UUID()
        let filed = try await store.update(captions.key) { $0.trackID = track; $0.updatedAt = Date(); return true }
        XCTAssertEqual(filed?.trackID, track, "filed with its recording")
        let written = try JSONDecoder().decode(LiveCaptions.self, from: Data(contentsOf: url))
        XCTAssertEqual(written.trackID, track)
        XCTAssertEqual(written.segments.map(\.text), ["Said with the iPhone locked"])

        // A file that's gone reads as gone.
        await store.remove(captions.meetingID)
        XCTAssertNil(store.captions(for: captions.key))
    }
}

/// A pretend iPhone that tests lock and unlock (`PhoneAppEnvironment.protectedData`).
@MainActor
final class PretendLock {
    private(set) var locked: Bool
    private var handlers: [@MainActor () -> Void] = []
    private var lockHandlers: [@MainActor () -> Void] = []

    init(locked: Bool) { self.locked = locked }

    var protectedData: ProtectedData {
        ProtectedData(isAvailable: { [unowned self] in !self.locked }, whenAvailable: { [unowned self] in self.handlers.append($0) },
                      whenUnavailable: { [unowned self] in self.lockHandlers.append($0) })
    }

    func lock() {
        locked = true
        for handler in lockHandlers { handler() }
    }

    func unlock() {
        locked = false
        for handler in handlers { handler() }
    }
}

/// Background time, counting what's held.
@MainActor
private final class CountedBackgroundTime: BackgroundTime {
    private(set) var begun = 0
    private(set) var held: Set<Int> = []

    func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int? {
        begun += 1
        held.insert(begun)
        return begun
    }

    func end(_ assertion: Int) { held.remove(assertion) }
}
