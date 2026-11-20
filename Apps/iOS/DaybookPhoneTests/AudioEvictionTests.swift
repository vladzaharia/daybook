import DaybookCore
import DaybookKit
import XCTest
@testable import DaybookPhone

/// Audio goes back to iCloud sooner (docs/icloud-sync.md, "Cache policy"): when iCloud confirms an upload, when the app
/// leaves the screen, and when a job that needed it ends, never while this iPhone still has work on it. The proof of
/// what is safe to evict is the engine's (`LibrarySyncAudio`, tested in DaybookCoreTests).
@MainActor
final class AudioEvictionTests: XCTestCase {
    /// What iCloud says of everything in the container.
    private final class Uploads: @unchecked Sendable {
        private let lock = NSLock()
        private var _confirmed = false
        var confirmed: Bool {
            get { lock.withLock { _confirmed } }
            set { lock.withLock { _confirmed = newValue } }
        }
        var cloud: SyncCloudFiles {
            SyncCloudFiles(requestDownload: { _ in }, isUploaded: { [self] url in confirmed && FileManager.default.fileExists(atPath: url.path) })
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
        let isLocal = await isLocal(rig, filed)
        XCTAssertFalse(isLocal)

        // A second request while it runs doesn't start another.
        var expire: (@MainActor () -> Void)?
        rig.audio.holdsBackgroundTime = { expired in expire = expired; return {} }
        rig.audio.evictLeavingForeground()
        expire?()
        try await Task.sleep(for: .milliseconds(150))
        rig.audio.evictLeavingForeground()
        try await waitUntil("it can run again after expiry", state: { "\(rig.audio.evictions)" }) { rig.audio.evictions >= before + 2 }
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
}
