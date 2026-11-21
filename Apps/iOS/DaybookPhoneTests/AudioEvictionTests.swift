import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// Audio goes back to iCloud sooner (docs/icloud-sync.md, "Cache policy"): when iCloud confirms an upload, when the app
/// leaves the screen, and when a job that needed it ends, never while this iPhone still has work on it. The proof of
/// what is safe to evict is the engine's (`LibrarySyncAudio`, tested in DaybookCoreTests).
@MainActor
final class AudioEvictionTests: XCTestCase {
    /// What iCloud says of everything in the container: nothing is uploaded until `confirmed`, and an uploaded item whose copy
    /// is dropped stays listed as a placeholder, as it does on an iPhone.
    private final class Uploads: @unchecked Sendable {
        private let lock = NSLock()
        private var _confirmed = false, _dropped: [String] = [], stash: [String: Data] = [:]
        var confirmed: Bool {
            get { lock.withLock { _confirmed } }
            set { lock.withLock { _confirmed = newValue } }
        }
        var dropped: [String] { lock.withLock { _dropped } }
        private static func placeholder(_ url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).icloud") }
        var cloud: SyncCloudFiles {
            SyncCloudFiles(requestDownload: { _ in }, isUploaded: { [self] url in
                confirmed && (FileManager.default.fileExists(atPath: url.path) || FileManager.default.fileExists(atPath: Self.placeholder(url).path))
            }, evictLocalCopy: { [self] url in
                lock.withLock { _dropped.append(url.path) }
                guard confirmed, let data = try? Data(contentsOf: url) else { return }
                lock.withLock { stash[url.path] = data }
                try? FileManager.default.removeItem(at: url)
                try? Data().write(to: Self.placeholder(url))
            })
        }
    }

    /// A phone with a recording filed and published, a budget nothing fits, and the app's wiring from sync to eviction.
    private func phoneWithRecording(_ uploads: Uploads) async throws -> (rig: PhoneRig, filed: PhoneLibrary.Filed) {
        let container = try temporaryDirectory("container")
        let rig = try await makePhone(container, budget: 1, cloud: uploads.cloud)
        rig.audio.evictionDelay = .milliseconds(20)
        rig.sync.onUploadsConfirmed = { [weak audio = rig.audio] in audio?.evictSoon() }
        await rig.sync.synchronize(.launch)
        let filed = try await record(into: rig, seconds: 3)
        await rig.sync.synchronize(.filed)
        return (rig, filed)
    }

    private func isLocal(_ rig: PhoneRig, _ filed: PhoneLibrary.Filed) async -> Bool {
        await rig.audio.availability(of: filed.meeting.tracks[0], in: filed.meeting.id) == .local
    }

    func testBehaviorAudioGoesBackToICloudWhenItConfirmsTheUploadAndNotBefore() async throws {
        let uploads = Uploads()
        let (rig, filed) = try await phoneWithRecording(uploads)
        await rig.sync.synchronize(.edit)
        XCTAssertEqual(rig.audio.evictions, 0, "iCloud hasn't confirmed anything")
        let isStillLocal = await isLocal(rig, filed)
        XCTAssertTrue(isStillLocal)

        uploads.confirmed = true
        await rig.sync.synchronize(.edit)
        try await waitUntil("eviction ran after the confirmation", state: { "\(rig.audio.evictions)" }) { rig.audio.evictions == 1 }
        let stillLocal = await isLocal(rig, filed)
        XCTAssertFalse(stillLocal, "the confirmed upload went back to iCloud")
        // Said once: later passes find nothing new confirmed.
        await rig.sync.synchronize(.edit)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.audio.evictions, 1)
    }

    func testBehaviorABurstOfRequestsEvictsOnceAndOneMadeWhileItRunsEvictsOnceMore() async throws {
        let (rig, _) = try await phoneWithRecording(Uploads())
        for _ in 0..<5 { rig.audio.evictSoon() }
        try await waitUntil("one eviction", state: { "\(rig.audio.evictions)" }) { rig.audio.evictions == 1 }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.audio.evictions, 1)
    }

    func testBehaviorLeavingTheForegroundEvictsUnderBackgroundTimeAndExpiryCancelsIt() async throws {
        let uploads = Uploads()
        uploads.confirmed = true
        let (rig, filed) = try await phoneWithRecording(uploads)
        // The recording was confirmed at once and the pass before this left it for the budget's next check.
        var began = 0, ended = 0
        rig.audio.holdsBackgroundTime = { _ in began += 1; return { ended += 1 } }
        let before = rig.audio.evictions
        rig.audio.evictLeavingForeground()
        try await waitUntil("eviction under background time", state: { "\(rig.audio.evictions) \(ended)" }) { rig.audio.evictions == before + 1 && ended == 1 }
        XCTAssertEqual(began, 1)
        let firstIsLocal = await isLocal(rig, filed)
        XCTAssertFalse(firstIsLocal)

        // Out of background time before it starts: nothing is deleted, and the background task still ends.
        let sparedFiled = try await record(into: rig, title: "Second", seconds: 3)
        await rig.sync.synchronize(.filed)
        var expire: (@MainActor () -> Void)?
        var endedAfterExpiry = 0
        rig.audio.holdsBackgroundTime = { expired in expire = expired; return { endedAfterExpiry += 1 } }
        let evictionsBefore = rig.audio.evictions
        rig.audio.evictLeavingForeground()
        expire?()
        try await waitUntil("the background task ends", state: { "\(endedAfterExpiry)" }) { endedAfterExpiry == 1 }
        XCTAssertEqual(rig.audio.evictions, evictionsBefore, "cancelled before it deleted anything")
        let stillThere = await isLocal(rig, sparedFiled)
        XCTAssertTrue(stillThere)
        // Evictable again afterwards: expiry doesn't wedge the scheduler.
        rig.audio.holdsBackgroundTime = { _ in {} }
        rig.audio.evictLeavingForeground()
        try await waitUntil("it can run again after expiry", state: { "\(rig.audio.evictions)" }) { rig.audio.evictions == evictionsBefore + 1 }
    }

    func testBehaviorWhatThisIPhoneStillNeedsIsSparedUntilItIsDone() async throws {
        let uploads = Uploads()
        uploads.confirmed = true
        let (rig, filed) = try await phoneWithRecording(uploads)
        var needed: Set<UUID> = [filed.meeting.id]
        rig.audio.needsAudio = { needed }
        rig.audio.keepWindow = 0
        await rig.audio.evict()
        let sparedWhileNeeded = await isLocal(rig, filed)
        XCTAssertTrue(sparedWhileNeeded, "audio this iPhone has work on stays")
        needed = []
        await rig.audio.evict()
        let goneWhenDone = await isLocal(rig, filed)
        XCTAssertFalse(goneWhenDone, "and goes back once the work is done or given up")
    }

    func testBehaviorWithoutICloudNothingIsEvicted() async throws {
        let root = try temporaryDirectory("phone-unsynced")
        let controller = LibrarySyncController(localRoot: root, defaults: makeTestDefaults("AudioEvictionTests"))
        controller.syncDebounce = nil
        let library = PhoneLibrary(rootURL: root, sync: controller, installation: UUID().uuidString)
        try await library.reload()
        let sync = PhoneSync(library: library.controller)
        let audio = SyncAudioProvider(library: library, sync: sync, budget: 1)
        let rig = PhoneRig(library: library, sync: sync, audio: audio)
        let filed = try await record(into: rig, seconds: 3)
        let report = await audio.evict()
        XCTAssertNil(report, "signed out or sync off: no engine, nothing is touched")
        audio.evictSoon(); audio.evictLeavingForeground()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(audio.evictions, 0)
        let url = try await library.audioURL(for: filed.meeting.tracks[0], in: filed.meeting.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testBehaviorTotalsRefreshAfterAnEviction() async throws {
        let uploads = Uploads()
        uploads.confirmed = true
        let (rig, _) = try await phoneWithRecording(uploads)
        try await waitUntil("the recording is counted", state: { "\(rig.audio.usage)" }) { rig.audio.usage.bytes > 0 }
        await rig.audio.evict()
        try await waitUntil("the totals follow the eviction", state: { "\(rig.audio.usage)" }) { rig.audio.usage.bytes == 0 }
    }

    func testBehaviorTheOriginalOfARecordingWhoseContainerCopyWasDroppedGoesBackAndPlaysAgain() async throws {
        let uploads = Uploads()
        uploads.confirmed = true
        let (rig, filed) = try await phoneWithRecording(uploads)
        await rig.sync.synchronize(.edit)
        XCTAssertEqual(uploads.dropped.count, 1, "iCloud's copy of the upload was let go, the original kept")
        let stillHere = await isLocal(rig, filed)
        XCTAssertTrue(stillHere)
        await rig.audio.evict()
        let went = await isLocal(rig, filed)
        XCTAssertFalse(went, "its object is a placeholder, which is uploaded all the same")
    }

    func testBehaviorADownloadDoesNotTakeBackAudioThePhoneStillNeeds() async throws {
        let container = try temporaryDirectory("container")
        let recorder = try await makePhone(container, name: "Recording iPhone")
        let first = try await record(into: recorder, title: "First", seconds: 3)
        let second = try await record(into: recorder, title: "Second", seconds: 3)
        await recorder.sync.synchronize(.filed)
        let reader = try await makePhone(container, name: "Reading iPhone", budget: 1)
        reader.audio.keepWindow = 0
        reader.audio.evictionDelay = .milliseconds(10)
        await reader.sync.synchronize(.launch)
        reader.audio.needsAudio = { [first.meeting.id] }
        _ = try await reader.audio.localAudio(for: first.meeting.tracks[0], in: first.meeting.id) { _ in }
        _ = try await reader.audio.localAudio(for: second.meeting.tracks[0], in: second.meeting.id) { _ in }
        try await waitUntil("the other download goes back", state: { "\(reader.audio.evictions)" }) { reader.audio.evictions >= 1 }
        try await waitUntil("its usage is measured", state: { "\(reader.audio.usage)" }) { reader.audio.usage.items == 1 }
        let kept = await reader.audio.availability(of: first.meeting.tracks[0], in: first.meeting.id)
        XCTAssertEqual(kept, .local, "the recording being processed survives another conversation's download")
        let gone = await reader.audio.availability(of: second.meeting.tracks[0], in: second.meeting.id)
        XCTAssertEqual(gone, .downloadable(bytes: nil))
    }

    func testBehaviorTheTrackThePlayerHasLoadedIsSparedWhateverItsAge() async throws {
        let uploads = Uploads()
        uploads.confirmed = true
        let (rig, filed) = try await phoneWithRecording(uploads)
        rig.audio.keepWindow = 0
        rig.audio.playingTrack = filed.meeting.tracks[0].id
        await rig.audio.evict()
        let spared = await isLocal(rig, filed)
        XCTAssertTrue(spared)
        rig.audio.playingTrack = nil
        await rig.audio.evict()
        let freed = await isLocal(rig, filed)
        XCTAssertFalse(freed)
    }

    func testBehaviorARecordingAMacWaitsForIsSparedUntilItIsSent() async throws {
        let model = try PhoneAppModel(recorder: RecorderRig().recorder,
                                      library: PhoneLibrary(rootURL: try temporaryDirectory("library"), installation: "INSTALL-1"),
                                      posture: DevicePosture(), options: DebugLaunch(arguments: [], environment: ["XCTestConfigurationFilePath": "1"]),
                                      environment: try .test(self))
        let id = UUID()
        XCTAssertFalse(model.audio.needsAudio().contains(id))
        model.multipoints.outgoingFiling(id, recordingID: nil)
        XCTAssertTrue(model.audio.needsAudio().contains(id), "owed to a Mac, so not given back to iCloud yet")
        model.multipoints.outgoing[id] = nil
        XCTAssertFalse(model.audio.needsAudio().contains(id))
    }

    func testBehaviorAnotherAccountSignedInEvictsNothing() async throws {
        final class Account: @unchecked Sendable {
            private let lock = NSLock(); private var _identity: Data?
            var identity: Data? { get { lock.withLock { _identity } } set { lock.withLock { _identity = newValue } } }
        }
        let account = Account()
        var environment = SyncContainerEnvironment.system
        environment.accountIdentity = { account.identity }
        let uploads = Uploads()
        uploads.confirmed = true
        let container = try temporaryDirectory("container")
        let rig = try await makePhone(container, budget: 1, cloud: uploads.cloud, environment: environment)
        await rig.sync.synchronize(.launch)
        let filed = try await record(into: rig, seconds: 3)
        await rig.sync.synchronize(.filed)
        account.identity = Data([2])
        let report = await rig.audio.evict()
        XCTAssertNil(report, "judged against another account's container: nothing goes")
        let cleared = await rig.audio.clearDownloaded()
        XCTAssertEqual(cleared, 0)
        let stillHere = await isLocal(rig, filed)
        XCTAssertTrue(stillHere)
        account.identity = nil
        let back = await rig.audio.evict()
        XCTAssertEqual(back?.evicted.count, 1)
    }
}
