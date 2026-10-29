import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// `LibraryController.synchronize`: applying a pass to a library, with two libraries sharing a temporary
/// folder that stands in for the iCloud container. No iCloud account, CloudKit, or network.
@MainActor
final class LibrarySyncApplyTests: XCTestCase {
    private var root: URL!
    /// Each library's preferences, by name, so a library opened again by name is the same device.
    private var suites: [String: String] = [:]
    private var controllers: [LibrarySyncController] = []
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSyncApply-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
        try? FileManager.default.removeItem(at: root)
    }

    /// A library connected to the shared folder. Passes run only when a test asks.
    private func library(_ name: String, phone: Bool = false, cloud: SyncCloudFiles = .system) async throws -> LibraryController {
        let libraryRoot = root.appendingPathComponent(name, isDirectory: true)
        let suite = suites[name] ?? makeTestSuite("daybook.sync.apply.\(name)")
        suites[name] = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(name, forKey: "syncDeviceID")
        let sync = LibrarySyncController(localRoot: libraryRoot, defaults: defaults)
        controllers.append(sync)
        sync.replica = phone ? .phone(displayName: name) : .mac(displayName: name, canProcess: true)
        sync.replica.cloud = cloud
        sync.syncDebounce = nil
        let library = LibraryController(rootURL: libraryRoot, sync: sync)
        try await library.load()
        try sync.connect(to: container, monitorChanges: false)
        return library
    }

    @discardableResult
    private func sync(_ library: LibraryController, protecting: UUID? = nil, file: StaticString = #filePath, line: UInt = #line) async -> SyncApplied? {
        let applied = await library.synchronize(protecting: protecting)
        XCTAssertEqual(applied?.acknowledged, true, library.sync?.status ?? "", file: file, line: line)
        return applied
    }

    func testLibrarySettingsThisVersionCantReadDoNotStopThePass() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        mac.createFolder(named: "Research")
        await mac.flush()
        await sync(mac)
        // A newer Daybook's settings that don't decode as this version's.
        let metadata = try XCTUnwrap(FileManager.default.contentsOfDirectory(atPath: container.appendingPathComponent("Metadata").path).first)
        let record: [String: Any] = ["schemaVersion": 1, "deviceID": "Future", "sequence": 9, "parents": [String(metadata.dropLast(5))],
                                     "data": Data(#"{"schemaVersion":1,"folders":"not a list"}"#.utf8).base64EncodedString()]
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try bytes.write(to: container.appendingPathComponent("Metadata/\(AudioDigest.sha256(data: bytes)).json"))
        mac.createFolder(named: "Later")
        await mac.flush()
        await sync(mac)
        await sync(phone)
        XCTAssertEqual(Set(phone.folders.map(\.name)), ["Research", "Later"])
        XCTAssertTrue(phone.notice?.contains("newer version of Daybook") == true)
        await sync(phone)
    }

    /// A damaged entry in the journal: the library's notice is one plain sentence, with no file name; Settings › Library
    /// has the warning with what's wrong behind Details.
    func testADamagedEntrysNoticeIsAPlainSentence() async throws {
        let mac = try await library("Mac")
        _ = mac.newMeeting(title: "Fine")
        await mac.flush()
        await sync(mac)
        let other = Meeting(title: "Elsewhere")
        let record: [String: Any] = ["schemaVersion": 1, "meetingID": UUID().uuidString, "deviceID": "X", "sequence": 1, "parents": [String](),
                                     "snapshot": try JSONSerialization.jsonObject(with: JSONEncoder().encode(other)), "deleted": false, "assets": [Any]()]
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        let name = AudioDigest.sha256(data: bytes)
        try bytes.write(to: container.appendingPathComponent("Events/\(name).json"))
        await sync(mac)
        let notice = try XCTUnwrap(mac.notice)
        XCTAssertEqual(notice, SyncWarningWords.damagedHistory + ".")
        let warning = try XCTUnwrap(mac.sync?.warnings.first { $0.hasPrefix(SyncWarningWords.damagedHistory) })
        XCTAssertTrue(SyncWarningWords.split(warning).details?.contains(name) == true)
    }

    func testARecordingIntoAConversationDeletedOnTheMacIsKeptOnThePhone() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        let id = phone.newMeeting(title: "Walk and talk")
        await phone.flush()
        await sync(phone); await sync(mac)
        XCTAssertNotNil(mac.meeting(id))
        _ = try await mac.moveToTrash(id)
        await sync(mac)
        // The phone records into it meanwhile; the pass during the recording leaves it alone.
        let file = root.appendingPathComponent("phone.m4a")
        try Data("phone recording".utf8).write(to: file)
        await phone.acquireLock()
        _ = try await phone.ingest(file, into: id, provenance: .file(source: .microphone))
        phone.releaseLock()
        await sync(phone, protecting: id)
        XCTAssertNotNil(phone.meeting(id))
        // After it, the recording is kept as a new conversation and the deleted one goes to the Trash.
        await sync(phone)
        XCTAssertNil(phone.meeting(id))
        XCTAssertTrue(phone.trashedMeetingIDs().contains(id))
        let kept = try XCTUnwrap(phone.meetings.first)
        XCTAssertEqual(kept.title, "Walk and talk")
        XCTAssertEqual(kept.tracks.count, 1)
        XCTAssertTrue(phone.notice?.contains("kept as a new conversation") == true)
        await sync(phone)
        await sync(mac)
        XCTAssertEqual(mac.meeting(kept.id)?.tracks.map(\.sha256), kept.tracks.map(\.sha256))
        XCTAssertNil(mac.meeting(id))
    }

    func testRestoringAConversationWhoseDeletionSyncedBringsItBackAsANewOne() async throws {
        let mac = try await library("Mac"), other = try await library("Other Mac")
        let id = mac.newMeeting(title: "Budget")
        mac.editNotes(id, text: "Line items")
        let file = root.appendingPathComponent("budget.wav")
        try Data("budget audio".utf8).write(to: file)
        await mac.acquireLock()
        _ = try await mac.ingest(file, into: id, provenance: .file(source: .imported))
        mac.releaseLock()
        await mac.flush()
        await sync(mac); await sync(other)
        _ = try await mac.moveToTrash(id)
        await sync(mac); await sync(other)
        XCTAssertNil(other.meeting(id))

        // With sync off, as before; turning it back on must not take it away again.
        mac.sync?.disconnect()
        let restored = try await mac.restoreFromTrash(id)
        XCTAssertNotEqual(restored.id, id, "the deleted ID stays deleted; the conversation comes back as a new one")
        XCTAssertEqual(restored.notes, "Line items")
        XCTAssertEqual(restored.tracks.count, 1)
        XCTAssertTrue(restored.revisions.contains { $0.field.hasPrefix("source:restored") })
        XCTAssertFalse(mac.trashedMeetingIDs().contains(id))
        let audio = try await mac.audioURL(for: restored.tracks[0], in: restored.id)
        XCTAssertEqual(try Data(contentsOf: audio), Data("budget audio".utf8))

        try mac.sync?.connect(to: container, monitorChanges: false)
        await sync(mac)
        XCTAssertNotNil(mac.meeting(restored.id), "turning sync on again doesn't move it back to the Trash")
        await sync(other)
        XCTAssertEqual(other.meeting(restored.id)?.notes, "Line items")
        XCTAssertNil(other.meeting(id))

        // Restoring one whose deletion hasn't synced yet keeps its ID.
        let fresh = mac.newMeeting(title: "Never synced")
        await mac.flush()
        _ = try await mac.moveToTrash(fresh)
        let back = try await mac.restoreFromTrash(fresh)
        XCTAssertEqual(back.id, fresh)
    }

    func testAnotherDevicesProcessingStatusIsKeptAsSyncedAndNotPublishedBack() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        let id = mac.newMeeting(title: "Interview")
        await mac.flush()
        await sync(mac); await sync(phone)
        for status in [MeetingStatus.transcribing, .summarizing, .ready] {
            mac.update(id) { $0.status = status }
            await mac.flush()
            await sync(mac)
            let applied = await sync(phone)
            XCTAssertEqual(phone.meeting(id)?.status, status)
            XCTAssertEqual(applied?.published, 0, "the phone doesn't publish the Mac's status back")
            if let meeting = phone.meeting(id), case .processing = ProcessingStatus(meeting) { XCTFail("nothing runs on the phone") }
            let again = await sync(mac)
            XCTAssertEqual(again?.published, 0)
            XCTAssertFalse(mac.meeting(id)?.revisions.contains { $0.field.hasPrefix("sync:") } ?? true, "no status conflicts")
        }
    }

    func testAnEditMadeWhileAPassRunsAsksForAnotherPassThatPublishesIt() async throws {
        let gate = OneTimeGate()
        let mac = try await library("Mac", cloud: SyncCloudFiles(requestDownload: { _ in gate.hold() }, isUploaded: { _ in true }))
        let id = mac.newMeeting(title: "Before")
        await mac.flush()
        await sync(mac)
        // An entry still in iCloud makes the next pass ask for a download, which the test holds.
        let placeholder = container.appendingPathComponent("Events/.\(String(repeating: "a", count: 64)).json.icloud")
        try Data().write(to: placeholder)
        mac.sync?.syncDebounce = .seconds(60)
        let running = Task { await mac.synchronize() }
        try await waitUntil("the pass to reach the journal") { gate.entered }
        mac.rename(id, to: "Edited while the pass ran")
        gate.release()
        let applied = await running.value
        XCTAssertEqual(applied?.acknowledged, true)
        XCTAssertEqual(applied?.editedDuringPass, [id])
        XCTAssertEqual(mac.meeting(id)?.title, "Edited while the pass ran", "the pass didn't undo it")
        XCTAssertEqual(mac.sync?.hasPendingSyncRequest, true, "another pass is on its way")
        try FileManager.default.removeItem(at: placeholder)
        let next = await sync(mac)
        XCTAssertEqual(next?.published, 1)
        XCTAssertEqual(next?.editedDuringPass, [])
    }

    func testARequestMadeByTheRequestedPassRunsAfterItInsteadOfCancellingIt() async throws {
        let mac = try await library("Mac")
        let sync = try XCTUnwrap(mac.sync)
        sync.syncDebounce = .milliseconds(10)
        var passes = 0, cancelled = false
        sync.onSyncRequested = {
            passes += 1
            if passes == 1 {
                sync.requestSync()   // what an edit saved during the pass does
                try? await Task.sleep(for: .milliseconds(30))
                cancelled = Task.isCancelled
            }
        }
        sync.requestSync()
        try await waitUntil("the first pass") { passes == 1 }
        await sync.awaitIdle()
        XCTAssertFalse(cancelled, "the running pass isn't cancelled by its own request")
        XCTAssertEqual(passes, 2, "the request runs once the pass is over")
    }

    func testWhileRecordingTheMacTakesHandoffsAndOwnershipAndSaysItsRecording() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        let id = mac.newMeeting(title: "Recording now")
        await mac.flush()
        await sync(mac); await sync(phone)
        // The Mac starts recording: the phone sees it at once, without a pass.
        mac.sync?.publishActivity(recording: id, since: Date())
        var recording: KnownSyncDevice?
        for _ in 0..<100 where recording == nil {
            recording = await phone.sync?.knownDevices().recordingMac()
            if recording == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(recording?.activity?.recordingConversationID, id)
        // The phone takes over a recorder and renames the conversation; the Mac, still recording, takes the
        // ownership only.
        phone.claimRecorder(kind: "soundcore.work", serial: "S1", deviceClass: .phone)
        phone.rename(id, to: "Renamed on the phone")
        await phone.flush()
        await sync(phone)
        let busy = await mac.synchronize(protecting: id, scope: .metadataOnly)
        XCTAssertEqual(busy?.acknowledged, true)
        XCTAssertEqual(mac.recorderOwner(kind: "soundcore.work", serial: "S1")?.ownerID, phone.sync?.deviceID)
        XCTAssertEqual(mac.meeting(id)?.title, "Recording now", "conversations wait until the recording is filed")
        mac.sync?.publishActivity(recording: nil)
        await sync(mac)
        XCTAssertEqual(mac.meeting(id)?.title, "Renamed on the phone")
    }

    /// Waits for `condition`, scaled by `DAYBOOK_TEST_TIMEOUT_SCALE`; throws on timeout with the controllers' state.
    private func waitUntil(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let scale = Double(ProcessInfo.processInfo.environment["DAYBOOK_TEST_TIMEOUT_SCALE"] ?? "") ?? 1
        let deadline = ContinuousClock.now + timeout * scale
        while !condition() {
            guard ContinuousClock.now < deadline else {
                throw TimedOut(description: "Timed out waiting for \(what) (\(controllers.map(\.status).joined(separator: "; ")))")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private struct TimedOut: Error, CustomStringConvertible { var description: String }
}

/// Holds the first cloud-provider call until released; later ones pass straight through.
private final class OneTimeGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var held = false, _entered = false
    var entered: Bool { lock.withLock { _entered } }
    func hold() {
        let first = lock.withLock { () -> Bool in defer { held = true; _entered = true }; return !held }
        if first { _ = semaphore.wait(timeout: .now() + 10) }
    }
    func release() { semaphore.signal() }
}
