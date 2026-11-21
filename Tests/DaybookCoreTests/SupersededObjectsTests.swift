import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookCore

/// Superseded originals in iCloud (LibrarySyncSuperseded.swift): once a Mac replaces a recording with a compressed copy,
/// the original's object in `Blobs/` goes only after compaction pruned every journal entry naming it (every device seen
/// in the last 30 days acknowledged a state after the replacement), the copy is in iCloud and here, no track here names
/// the original, and all of that held for a day; on the compacting Mac, in one place. iCloud is a temporary folder
/// (`SimulatedICloud`).
final class SupersededObjectsTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var keychain: MemoryLibraryKeyStore!
    private var remote: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private let day: TimeInterval = 86_400

    override func setUpWithError() throws {
        root = makeTemporaryFolder("DaybookSupersededTests")
        cloud = SimulatedICloud()
        keychain = MemoryLibraryKeyStore()
    }

    private func mac(_ name: String = "Mac", compaction: SyncCompactionPolicy? = .eager) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: "\(name) Studio", canProcess: true),
            cloud: cloud.files, keyStore: keychain, sealsNewLibrary: false, compaction: compaction))
    }

    private func phone(_ name: String = "Phone") throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            audioCache: AudioCachePolicy(budgetBytes: 1 << 30), cloud: cloud.files, keyStore: keychain, sealsNewLibrary: false))
    }

    /// A pass supplying everything the device's library holds, applied and acknowledged.
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, at now: Date? = nil) async throws -> SyncResult {
        // The clock a pass compacts by: now, unless the test moves it.
        await engine.setCompactionClock { now ?? Date() }
        let store = try MeetingStore(rootURL: local(name))
        let result = try await engine.synchronize(meetings: try await store.list())
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs where FileManager.default.fileExists(atPath: local(name).appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        try await engine.acknowledge(result.checkpointID)
        return result
    }

    private func blob(_ sha256: String) -> URL { remote.appendingPathComponent("Blobs/\(sha256)") }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private struct Compressed {
        var meeting: Meeting
        var original: RecordingTrack
        var copy: String
    }

    /// A recording made on the Mac, synced to the iPhone, then replaced by a compressed copy there (bytes stand in for
    /// AAC: sync never decodes audio) and synced again.
    private func recordedAndCompressed(_ mac: LibrarySyncEngine, _ phone: LibrarySyncEngine, bytes: UInt8 = 7,
                                       beforeCompressing: (Meeting) async throws -> Void = { _ in }) async throws -> Compressed {
        let source = root.appendingPathComponent("original-\(bytes).wav")
        try Data(repeating: bytes, count: 8_192).write(to: source)
        let store = try MeetingStore(rootURL: local("Mac"))
        var meeting = try await store.importAudio(from: source, into: Meeting(title: "Call"), source: .microphone)
        try await pass(mac, "Mac"); try await pass(phone, "Phone")
        try await beforeCompressing(meeting)
        let original = meeting.tracks[0]
        let copyBytes = Data(repeating: bytes &+ 100, count: 512)
        let digest = AudioDigest.sha256(data: copyBytes)
        let relativePath = RecordingCompression.relativePath(trackID: original.id, sha256: digest)
        try copyBytes.write(to: local("Mac").appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(relativePath)"))
        RecordingCompression.File(relativePath: relativePath, fileName: "original.m4a", sha256: digest, encoding: TrackEncoding(
            method: "aac-lc-64", sourceFormat: "PCM", previousSHA256: original.sha256, previousRelativePath: original.relativePath,
            previousFileName: original.fileName, encodedAt: Date(), device: "Mac")).apply(to: &meeting.tracks[0])
        try await store.save(meeting)
        try await pass(mac, "Mac")
        XCTAssertTrue(exists(blob(digest)), "the copy is in iCloud")
        return Compressed(meeting: meeting, original: original, copy: digest)
    }

    /// Every device applies the replacement and acknowledges the compaction proposal after it; the Mac commits.
    private func acknowledged(_ mac: LibrarySyncEngine, _ phone: LibrarySyncEngine) async throws {
        try await pass(phone, "Phone")
        try await pass(mac, "Mac")    // proposes
        try await pass(phone, "Phone") // acknowledges
        try await pass(mac, "Mac")    // commits: the history naming the original is pruned
    }

    // MARK: When it goes

    func testBehaviorTheOriginalsObjectGoesADayAfterEveryDeviceHasTheCopyAndNothingNamesIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        XCTAssertTrue(exists(object), "free to go, and waiting a day")
        let state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.copy, compressed.copy)
        let now = Date()
        try await pass(mac, "Mac", at: now.addingTimeInterval(day - 60))
        XCTAssertTrue(exists(object))
        let result = try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
        XCTAssertTrue(exists(blob(compressed.copy)))
        XCTAssertTrue(result.warnings.isEmpty)
        let report = await mac.compactionReport
        XCTAssertEqual(report?.deletedSuperseded, 1)
        // Both still sync, and the iPhone's recording is the copy.
        try await pass(phone, "Phone"); try await pass(mac, "Mac")
        let held = try await MeetingStore(rootURL: local("Phone")).list().first { $0.id == compressed.meeting.id }
        XCTAssertEqual(held?.tracks.first?.sha256, compressed.copy)
        let afterwards = await mac.supersededState()
        XCTAssertTrue(afterwards.objects.isEmpty)
    }

    func testBehaviorADeviceThatHasntAcknowledgedKeepsItUntilItsAwayThirtyDays() async throws {
        let mac = try mac(), phone = try phone(), pad = try self.phone("Pad")
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        // The iPad has everything; the iPhone never sees the replacement, so it can't acknowledge a state after it, and
        // the history naming the original stays.
        try await pass(pad, "Pad"); try await pass(mac, "Mac"); try await pass(pad, "Pad"); try await pass(mac, "Mac")
        try await pass(mac, "Mac", at: Date().addingTimeInterval(3 * day))
        XCTAssertTrue(exists(object), "a device seen lately that hasn't caught up may still need it")
        try agePresence("Phone", days: 20)
        try await pass(mac, "Mac", at: Date().addingTimeInterval(3 * day))
        XCTAssertTrue(exists(object), "seen 23 days ago, it still counts")
        let waiting = await mac.supersededState()
        XCTAssertTrue(waiting.objects.isEmpty)
        // Away more than 30 days, it no longer holds compaction back (the rule for devices that are away), and the object
        // goes a day after it's free.
        try agePresence("Phone", days: 31)
        let now = Date()
        try await pass(mac, "Mac", at: now); try await pass(pad, "Pad"); try await pass(mac, "Mac", at: now)
        let free = await mac.supersededState()
        XCTAssertNotNil(free.objects[compressed.original.sha256])
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
    }

    func testBehaviorWithEveryOtherDeviceAwayNothingGoes() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        // The only other device, away for a month and never caught up: every acknowledgement would pass for want of anyone
        // to give one, so nothing of the conversation's history goes, and nor does the object.
        try agePresence("Phone", days: 31)
        let now = Date()
        for offset in [0, 1, 2, 3] { try await pass(mac, "Mac", at: now.addingTimeInterval(Double(offset) * day)) }
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    func testBehaviorAnObjectFreeToGoWaitsWhileEveryOtherDeviceIsAway() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let free = await mac.supersededState()
        XCTAssertNotNil(free.objects[compressed.original.sha256])
        // Then the only other device goes quiet: this Mac may be the one that's off (its clock ahead, say), so nothing goes.
        try agePresence("Phone", days: 31)
        try await pass(mac, "Mac", at: Date().addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    func testBehaviorADeviceThatDoesntKnowCompressedRecordingsKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        // A device seen in the last 30 days without `compress-1` holds it back.
        try editPresence("Phone") { $0["features"] = ($0["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.compressionFeature } }
        try await pass(mac, "Mac", at: Date().addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    func testBehaviorTheCopyMustBeInICloudAndReportedUploaded() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        cloud.setUploaded(blob(compressed.copy), false)
        try await acknowledged(mac, phone)
        let now = Date()
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(object), "the copy isn't confirmed uploaded")
        let waiting = await mac.supersededState()
        XCTAssertTrue(waiting.objects.isEmpty)
        // Confirmed: free from then, and gone a day later.
        cloud.setUploaded(blob(compressed.copy), true)
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        try await pass(mac, "Mac", at: now.addingTimeInterval(3 * day - 60))
        XCTAssertTrue(exists(object))
        try await pass(mac, "Mac", at: now.addingTimeInterval(3 * day + 60))
        XCTAssertFalse(exists(object))
    }

    func testBehaviorNothingGoesUntilEveryCompactionCommitIsInICloud() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let commits = files("Compaction").map { remote.appendingPathComponent("Compaction/\($0)") }
        XCTAssertFalse(commits.isEmpty)
        for url in commits { cloud.setUploaded(url, false) }
        let now = Date()
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "a device finding it gone must find what pruned its history")
        for url in commits { cloud.setUploaded(url, true) }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A library with too little history to compact still proposes when that would let a replaced original go.
    func testBehaviorAReplacedOriginalIsReasonEnoughToCompact() async throws {
        let policy = SyncCompactionPolicy(minimumEntries: 1_000, minimumBytes: 8_000, interval: 0, maximumCommits: 2)
        let mac = try mac(compaction: policy), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let pruned = await mac.compactionRuntime.prunedIDs
        XCTAssertFalse(pruned.isEmpty, "the original's 8 KB counts toward what compacting gains")
        try await pass(mac, "Mac", at: Date().addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    // MARK: What keeps it

    func testBehaviorATrackPointedBackAtItsOriginalKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        var compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let marked = await mac.supersededState()
        XCTAssertNotNil(marked.objects[compressed.original.sha256])
        // The Mac names its original again (its copy went missing before it was in iCloud, say), and publishes it.
        RecordingCompression.File(compressed.original).apply(to: &compressed.meeting.tracks[0])
        try await MeetingStore(rootURL: local("Mac")).save(compressed.meeting)
        let now = Date()
        try await pass(mac, "Mac", at: now)
        let forgotten = await mac.supersededState()
        XCTAssertNil(forgotten.objects[compressed.original.sha256], "named again: the wait is forgotten")
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(object))
    }

    func testBehaviorAnObjectTwoConversationsShareStaysWhileEitherNamesIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        // A second conversation holding the same bytes (merged conversations copy a recording, the same object).
        let source = root.appendingPathComponent("original-7.wav")
        let other = try await MeetingStore(rootURL: local("Mac")).importAudio(from: source, into: Meeting(title: "Merged"), source: .microphone)
        XCTAssertEqual(other.tracks[0].sha256, compressed.original.sha256)
        try await pass(mac, "Mac")
        try await acknowledged(mac, phone)
        try await pass(mac, "Mac", at: Date().addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the other conversation's recording is that object")
    }

    func testBehaviorAConversationInTheTrashHereKeepsItsRecordingsObject() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let source = root.appendingPathComponent("original-7.wav")
        let store = try MeetingStore(rootURL: local("Mac"))
        let other = try await store.importAudio(from: source, into: Meeting(title: "Merged"), source: .microphone)
        try await pass(mac, "Mac"); try await pass(phone, "Phone")
        // Moved to the Trash here, its deletion synced and its history pruned: the Trash still holds its recording.
        _ = try await store.moveToTrash(other.id)
        try await pass(mac, "Mac")
        try await acknowledged(mac, phone)
        let pruned = await mac.compactionRuntime.prunedIDs
        XCTAssertFalse(pruned.isEmpty)
        try await pass(mac, "Mac", at: Date().addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    func testBehaviorAnObjectNoReplacementNamesIsLeftAlone() async throws {
        let mac = try mac(), phone = try phone()
        // A deleted conversation's recording, its history pruned: not a superseded original, not this path's to delete.
        let source = root.appendingPathComponent("deleted.wav")
        try Data(repeating: 3, count: 4_096).write(to: source)
        let store = try MeetingStore(rootURL: local("Mac"))
        let meeting = try await store.importAudio(from: source, into: Meeting(title: "Gone"), source: .microphone)
        try await pass(mac, "Mac"); try await pass(phone, "Phone")
        _ = try await store.moveToTrash(meeting.id)
        try FileManager.default.removeItem(at: local("Mac").appendingPathComponent("Trash"))
        try await pass(mac, "Mac")
        try await acknowledged(mac, phone)
        try await pass(mac, "Mac", at: Date().addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(meeting.tracks[0].sha256)))
    }

    func testBehaviorAnObjectWrittenAgainDuringTheWaitStartsItAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        // Someone's upload of it, the same bytes under a new file.
        let bytes = try Data(contentsOf: object)
        try FileManager.default.removeItem(at: object)
        try bytes.write(to: object)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(object), "its wait started again when it was written")
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day + 120))
        XCTAssertFalse(exists(object))
    }

    // MARK: Crashes

    func testBehaviorAStopAtAnyStepResumesOrRepeatsTheSameWork() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        // The app quits after the wait began: a new engine finds it remembered.
        let again = try self.mac()
        try await pass(again, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
        // A deletion done before what's remembered was saved: nothing more to do, and nothing goes wrong.
        let state = SupersededObjectsState(objects: [compressed.original.sha256: .init(copy: compressed.copy, since: now.addingTimeInterval(-2 * day),
                                                                                         stamp: VerifiedAsset(digest: compressed.original.sha256, size: 1, modified: now, inode: 1))])
        let libraryID = await again.libraryID
        let url = local("Mac").appendingPathComponent("Sync/superseded-\(try XCTUnwrap(libraryID).uuidString).json")
        try SyncEncoding.data(state).write(to: url)
        let result = try await pass(again, "Mac", at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(result.warnings.isEmpty)
        let cleared = await again.supersededState()
        XCTAssertTrue(cleared.objects.isEmpty)
    }

    func testBehaviorWhatsRememberedLostStartsTheWaitAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let libraryID = await mac.libraryID
        let library = try XCTUnwrap(libraryID)
        try FileManager.default.removeItem(at: local("Mac").appendingPathComponent("Sync/superseded-\(library.uuidString).json"))
        let now = Date().addingTimeInterval(day + 60)
        try await pass(mac, "Mac", at: now)
        XCTAssertTrue(exists(object), "a day from when it's found again")
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
    }

    // MARK: A stale copy elsewhere

    /// The iPhone cached the original before the Mac replaced it. Its cached copy goes the way it always did, once it
    /// names the copy and the copy is in iCloud, whether or not the original's object is still there; never before.
    func testBehaviorTheIPhonesCachedOriginalGoesOnlyThroughItsVerifiedPath() async throws {
        let mac = try mac(), phone = try phone()
        var cached: URL?
        let compressed = try await recordedAndCompressed(mac, phone) { meeting in
            _ = try await phone.fetchAudio(for: meeting.tracks[0], in: meeting.id,
                                           options: AudioFetchOptions(pollInterval: .milliseconds(5), timeout: .seconds(10)))
            cached = self.local("Phone").appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(meeting.tracks[0].relativePath)")
        }
        let file = try XCTUnwrap(cached)
        XCTAssertTrue(exists(file))
        // Before the iPhone names the copy, it stays, and so does the object: the iPhone hasn't acknowledged anything.
        var report = try await phone.evictAudio()
        XCTAssertTrue(report.evicted.isEmpty)
        try await pass(mac, "Mac"); try await pass(mac, "Mac", at: Date().addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await acknowledged(mac, phone)
        try await pass(mac, "Mac", at: Date().addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
        XCTAssertTrue(exists(file), "iCloud's object going doesn't touch a device's own files")
        report = try await phone.evictAudio()
        XCTAssertEqual(report.evicted.map(\.sha256), [compressed.original.sha256])
        XCTAssertFalse(exists(file))
    }

    // MARK: Helpers

    private func files(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent(directory).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func presenceURL(_ deviceID: String) -> URL {
        remote.appendingPathComponent("Devices/\(SyncDigest.sha256(data: Data(deviceID.utf8))).json")
    }

    private func editPresence(_ deviceID: String, _ change: (inout [String: Any]) -> Void) throws {
        let url = presenceURL(deviceID)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        change(&record)
        try JSONSerialization.data(withJSONObject: record).write(to: url)
    }

    private func agePresence(_ deviceID: String, days: Double) throws {
        try editPresence(deviceID) { $0["lastSeen"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86_400)) }
    }
}
