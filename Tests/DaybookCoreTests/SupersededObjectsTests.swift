import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookCore

/// Superseded originals in iCloud (LibrarySyncSuperseded.swift): once a Mac replaces a recording with a compressed copy,
/// the original's object in `Blobs/` goes only after compaction pruned every journal entry naming it, every recording
/// whose original it is has its copy in iCloud and here, nothing here names it, the compacting Mac's notice listed it and
/// every device acknowledged that without holding it, and a day passed for each; then, after the pass, with everything
/// asked again. Every device treats such an object as possibly gone. iCloud is a temporary folder (`SimulatedICloud`).
final class SupersededObjectsTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var keychain: MemoryLibraryKeyStore!
    private var remote: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private let day: TimeInterval = 86_400
    /// The continuous clock passes read: the wall clock they're given plus `clockOffset`, in `boot`.
    private var boot = "boot-1"
    private var clockOffset: TimeInterval = 0

    override func setUpWithError() throws {
        root = makeTemporaryFolder("DaybookSupersededTests")
        cloud = SimulatedICloud()
        keychain = MemoryLibraryKeyStore()
    }

    private func mac(_ name: String = "Mac", compaction: SyncCompactionPolicy? = .eager, seals: Bool = false) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: "\(name) Studio", canProcess: true),
            cloud: cloud.files, keyStore: keychain, sealsNewLibrary: seals, compaction: compaction))
    }

    private func phone(_ name: String = "Phone", budget: UInt64 = 1 << 30) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            audioCache: AudioCachePolicy(budgetBytes: budget), cloud: cloud.files, keyStore: keychain, sealsNewLibrary: false))
    }

    /// A pass supplying everything the device's library holds, applied and acknowledged, as the library runs it: told
    /// first which conversations voice profiles hold (`heldForVoice`, judged: all of them unless `judged` says), and,
    /// after it, under the lock, deleting what it found due (`delete`).
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, at now: Date? = nil, heldForVoice: Set<UUID> = [],
                      judged: Set<UUID>? = nil, delete: Bool = true) async throws -> SyncResult {
        let when = now ?? Date()
        await engine.setCompactionClock { when }
        let mark = SyncClockMark(boot: boot, seconds: when.timeIntervalSince1970 + clockOffset)
        await engine.setContinuousClock { mark }
        let store = try MeetingStore(rootURL: local(name))
        let meetings = try await store.list()
        await engine.holdOriginalsInICloud(for: heldForVoice, judged: judged ?? Set(meetings.map(\.id)))
        let result = try await engine.synchronize(meetings: meetings)
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs where FileManager.default.fileExists(atPath: local(name).appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        try await engine.acknowledge(result.checkpointID)
        if delete { await engine.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: heldForVoice) }
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
    private func recordedAndCompressed(_ mac: LibrarySyncEngine, _ phone: LibrarySyncEngine, bytes: UInt8 = 7, on name: String = "Mac",
                                       beforeCompressing: (Meeting) async throws -> Void = { _ in }) async throws -> Compressed {
        let source = root.appendingPathComponent("original-\(bytes).wav")
        try Data(repeating: bytes, count: 8_192).write(to: source)
        let store = try MeetingStore(rootURL: local(name))
        let meeting = try await store.importAudio(from: source, into: Meeting(title: "Call"), source: .microphone)
        try await pass(mac, name); try await pass(phone, "Phone")
        try await beforeCompressing(meeting)
        let compressed = try await compress(meeting, on: name, copyByte: bytes &+ 100)
        try await pass(mac, name)
        let holds = await mac.holdsObject(compressed.copy)
        XCTAssertTrue(holds, "the copy is in iCloud")
        return compressed
    }

    /// The conversation's recording replaced, on that Mac, by a copy of `copyByte`s.
    private func compress(_ meeting: Meeting, on name: String = "Mac", copyByte: UInt8) async throws -> Compressed {
        let store = try MeetingStore(rootURL: local(name))
        let listed = try await store.list()
        var meeting = try XCTUnwrap(listed.first { $0.id == meeting.id })
        let original = meeting.tracks[0]
        let copyBytes = Data(repeating: copyByte, count: 512)
        let digest = AudioDigest.sha256(data: copyBytes)
        let relativePath = RecordingCompression.relativePath(trackID: original.id, sha256: digest)
        try copyBytes.write(to: local(name).appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(relativePath)"))
        RecordingCompression.File(relativePath: relativePath, fileName: "original.m4a", sha256: digest, encoding: TrackEncoding(
            method: "aac-lc-64", sourceFormat: "PCM", previousSHA256: original.sha256, previousRelativePath: original.relativePath,
            previousFileName: original.fileName, encodedAt: Date(), device: name)).apply(to: &meeting.tracks[0])
        try await store.save(meeting)
        return Compressed(meeting: meeting, original: original, copy: digest)
    }

    /// Every device applies the replacement and acknowledges the compaction proposal after it; the Mac commits, and the
    /// original is free to go from then, listed in its notice.
    private func acknowledged(_ mac: LibrarySyncEngine, _ phone: LibrarySyncEngine, _ name: String = "Mac") async throws {
        try await pass(phone, "Phone")
        try await pass(mac, name)    // proposes
        try await pass(phone, "Phone") // acknowledges
        try await pass(mac, name)    // commits: the history naming the original is pruned
    }

    /// The iPhone reads the notice and acknowledges it; the Mac sees that at `now`.
    private func noticed(_ mac: LibrarySyncEngine, _ phone: LibrarySyncEngine, at now: Date, _ name: String = "Mac") async throws {
        try await pass(phone, "Phone")
        try await pass(mac, name, at: now)
    }

    private func notice(_ deviceID: String = "Mac") throws -> SupersededRecord? {
        let url = remote.appendingPathComponent("Superseded/\(SupersededRecord.fileName(for: deviceID))")
        guard exists(url) else { return nil }
        return SupersededRecord.decode(try Data(contentsOf: url))
    }

    // MARK: When it goes

    func testBehaviorTheOriginalsObjectGoesADayAfterEveryDeviceAcknowledgedItsNotice() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let listed = await mac.supersededState()
        XCTAssertEqual(listed.objects[compressed.original.sha256]?.copies, [compressed.copy])
        XCTAssertEqual(try notice()?.objects.map(\.sha256), [compressed.original.sha256])
        let presence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        XCTAssertNotNil(presence["superseded"], "the iPhone acknowledges the notice in its presence")
        // Free, then acknowledged: a day from then, not a minute before.
        let now = try XCTUnwrap(listed.objects[compressed.original.sha256]?.acknowledgedSince)
        XCTAssertGreaterThanOrEqual(now, try XCTUnwrap(listed.objects[compressed.original.sha256]?.since))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day - 60))
        XCTAssertTrue(exists(object))
        let result = try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
        XCTAssertTrue(exists(blob(compressed.copy)))
        XCTAssertTrue(result.warnings.isEmpty)
        let report = await mac.compactionReport
        XCTAssertEqual(report?.deletedSuperseded, 1)
        // The log, here and in the notice: what went, when, and which recording and copy justified it.
        let log = try XCTUnwrap(try notice()?.deleted.first)
        XCTAssertEqual(log.sha256, compressed.original.sha256)
        XCTAssertEqual(log.tracks, [.init(meetingID: compressed.meeting.id, trackID: compressed.original.id, copy: compressed.copy)])
        XCTAssertEqual(try notice()?.objects, [])
        // Both still sync, the iPhone's recording is the copy, and it counts the object as gone.
        try await pass(phone, "Phone"); try await pass(mac, "Mac")
        let held = try await MeetingStore(rootURL: local("Phone")).list().first { $0.id == compressed.meeting.id }
        XCTAssertEqual(held?.tracks.first?.sha256, compressed.copy)
        let gone = await phone.supersededRuntime.possiblyGone
        XCTAssertTrue(gone.contains(compressed.original.sha256))
        let afterwards = await mac.supersededState()
        XCTAssertTrue(afterwards.objects.isEmpty)
        XCTAssertNotNil(afterwards.deleted[compressed.original.sha256])
    }

    func testBehaviorADeviceThatHasntAcknowledgedKeepsItUntilItsAwayThirtyDays() async throws {
        let mac = try mac(), phone = try phone(), pad = try self.phone("Pad")
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        // The iPad has everything; the iPhone never sees the replacement, so it can't acknowledge a state after it, and
        // the history naming the original stays.
        try await pass(pad, "Pad"); try await pass(mac, "Mac"); try await pass(pad, "Pad"); try await pass(mac, "Mac")
        try await pass(pad, "Pad")
        try await pass(mac, "Mac", at: Date().addingTimeInterval(3 * day))
        XCTAssertTrue(exists(object), "a device seen lately that hasn't caught up may still need it")
        try agePresence("Phone", days: 20)
        try await pass(mac, "Mac", at: Date().addingTimeInterval(3 * day))
        XCTAssertTrue(exists(object), "seen 23 days ago, it still counts")
        let waiting = await mac.supersededState()
        XCTAssertTrue(waiting.objects.isEmpty)
        // Away more than 30 days, it no longer holds compaction back (the rule for devices that are away), and the object
        // goes a day after the iPad acknowledges the notice.
        try agePresence("Phone", days: 31)
        let now = Date().addingTimeInterval(4 * day)
        try await pass(mac, "Mac", at: now); try await pass(pad, "Pad"); try await pass(mac, "Mac", at: now)
        let free = await mac.supersededState()
        XCTAssertNotNil(free.objects[compressed.original.sha256])
        try await pass(pad, "Pad"); try await pass(mac, "Mac", at: now)
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
        let now = Date()
        try await noticed(mac, phone, at: now)
        let free = await mac.supersededState()
        XCTAssertNotNil(free.objects[compressed.original.sha256]?.acknowledgedSince)
        // Then the only other device goes quiet: this Mac may be the one that's off (its clock ahead, say), so nothing goes.
        try agePresence("Phone", days: 31)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    func testBehaviorADeviceThatDoesntKnowCompressedRecordingsKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        // A device seen in the last 30 days without `compress-1` holds it back.
        try editPresence("Phone") { $0["features"] = ($0["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.compressionFeature } }
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// An older Daybook that doesn't read notices never acknowledges one, and its presence lacks `superseded-1`: nothing is
    /// listed, and nothing goes, while it's in use.
    func testBehaviorAnOlderDeviceThatDoesntReadNoticesKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        try editPresence("Phone") { record in
            record["features"] = (record["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.supersededFeature }
            record["superseded"] = nil
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        try await pass(mac, "Mac", at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "nothing is listed while a device in use can't read the notice")
    }

    /// The acknowledgement alone, the feature still listed: an iPhone whose presence acknowledges nothing keeps it.
    func testBehaviorADeviceThatHasntAcknowledgedTheNoticeKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = Date()
        try await pass(mac, "Mac", at: now)
        try editPresence("Phone") { $0["superseded"] = nil }
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince)
    }

    func testBehaviorTheNoticeMustBeInICloudBeforeAnAcknowledgementCounts() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let record = remote.appendingPathComponent("Superseded/\(SupersededRecord.fileName(for: "Mac"))")
        try await acknowledged(mac, phone)
        cloud.setUploaded(record, false)
        let now = Date()
        try await noticed(mac, phone, at: now)
        var state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince)
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        cloud.setUploaded(record, true)
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, now.addingTimeInterval(2 * day))
        try await pass(mac, "Mac", at: now.addingTimeInterval(3 * day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    func testBehaviorTheCopyMustBeInICloudAndReportedUploaded() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        cloud.setUploaded(blob(compressed.copy), false)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(object), "the copy isn't confirmed uploaded")
        let waiting = await mac.supersededState()
        XCTAssertTrue(waiting.objects.isEmpty)
        // Confirmed: free from then, and gone a day after the iPhone acknowledges it.
        cloud.setUploaded(blob(compressed.copy), true)
        let later = now.addingTimeInterval(2 * day)
        try await pass(mac, "Mac", at: later)
        try await noticed(mac, phone, at: later)
        try await pass(mac, "Mac", at: later.addingTimeInterval(day - 60))
        XCTAssertTrue(exists(object))
        try await pass(mac, "Mac", at: later.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
    }

    /// In iCloud Drive, only iCloud's own yes counts as uploaded: a copy the provider can't answer for keeps the original.
    func testBehaviorInICloudDriveOnlyICloudsOwnYesIsUploaded() async throws {
        let answers = UploadAnswers()
        let files = cloud.files
        let strict = SyncCloudFiles(requestDownload: files.requestDownload, isUploaded: files.isUploaded,
                                    uploadState: { url in answers.unanswered.contains(url.lastPathComponent) ? nil : files.isUploaded(url) },
                                    isICloudFolder: { _ in true })
        func engine(_ name: String, eager: Bool) throws -> LibrarySyncEngine {
            try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
                audioPolicy: eager ? .eager : .onDemand,
                device: SyncDeviceIdentity(deviceClass: eager ? .mac : .phone, displayName: name, canProcess: eager),
                audioCache: eager ? nil : AudioCachePolicy(budgetBytes: 1 << 30), cloud: strict, keyStore: keychain, sealsNewLibrary: false,
                compaction: eager ? .eager : nil))
        }
        let mac = try engine("Mac", eager: true), phone = try engine("Phone", eager: false)
        let compressed = try await recordedAndCompressed(mac, phone)
        answers.unanswered = [compressed.copy]
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        try await pass(mac, "Mac", at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
    }

    func testBehaviorNothingGoesUntilEveryCompactionCommitIsInICloud() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        let commits = files("Compaction").map { remote.appendingPathComponent("Compaction/\($0)") }
        XCTAssertFalse(commits.isEmpty)
        for url in commits { cloud.setUploaded(url, false) }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "a device finding it gone must find what pruned its history")
        for url in commits { cloud.setUploaded(url, true) }
        let later = now.addingTimeInterval(day + 60)
        try await pass(mac, "Mac", at: later); try await noticed(mac, phone, at: later)
        try await pass(mac, "Mac", at: later.addingTimeInterval(day + 60))
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
        let now = Date()
        try await noticed(mac, phone, at: now)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    // MARK: What keeps it

    /// A journal entry still naming the object keeps it, whatever else holds: here compaction never prunes (it has too
    /// little to gain), so the history from before the replacement stays, and so does the object, the iPhone caught up and
    /// acknowledging every notice.
    func testBehaviorAJournalEntryStillNamingItKeepsIt() async throws {
        let never = SyncCompactionPolicy(minimumEntries: .max, minimumBytes: .max, interval: 0, maximumCommits: 2)
        let mac = try mac(compaction: never), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await pass(phone, "Phone")
        let now = Date()
        for offset in [0.0, 1, 2, 3, 4] {
            try await noticed(mac, phone, at: now.addingTimeInterval(offset * day + 60))
        }
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "never listed while an entry names it")
    }

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
        XCTAssertEqual(try notice()?.objects, [], "and the notice lists it no more")
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day))
        try await pass(mac, "Mac", at: now.addingTimeInterval(4 * day))
        XCTAssertTrue(exists(object))
    }

    /// Two recordings whose original is the same object (a merge copied it), both compressed: it goes only once every one
    /// of them passes every check, and the log remembers both copies.
    func testBehaviorTwoCompressedRecordingsSharingAnOriginalBothMustPass() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let store = try MeetingStore(rootURL: local("Mac"))
        let other = try await store.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Merged"), source: .microphone)
        XCTAssertEqual(other.tracks[0].sha256, compressed.original.sha256)
        try await pass(mac, "Mac"); try await pass(phone, "Phone")
        try await acknowledged(mac, phone)
        var state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "the other recording still is that object")
        // The second is compressed too, but its copy isn't uploaded (iCloud refused it for storage, say).
        let second = try await compress(other, copyByte: 200)
        try await pass(mac, "Mac")
        cloud.setUploaded(blob(second.copy), false)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "one recording's copy passing doesn't free a shared original")
        state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
        cloud.setUploaded(blob(second.copy), true)
        let later = now.addingTimeInterval(2 * day)
        try await pass(mac, "Mac", at: later)
        state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.copies, [compressed.copy, second.copy].sorted())
        try await noticed(mac, phone, at: later)
        try await pass(mac, "Mac", at: later.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
        let log = try XCTUnwrap(try notice()?.deleted.first)
        XCTAssertEqual(Set(log.tracks.map(\.copy)), [compressed.copy, second.copy])
        XCTAssertEqual(Set(log.tracks.map(\.meetingID)), [compressed.meeting.id, other.id])
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
        // The iPhone's Trash holds it too, which it says in its presence; its own Trash goes, so only the Mac's keeps it.
        try? FileManager.default.removeItem(at: local("Phone").appendingPathComponent("Trash"))
        let now = Date()
        try await noticed(mac, phone, at: now)
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// A conversation in the Trash that can't be read may name anything: nothing is free to go while it's there.
    func testBehaviorAConversationInTheTrashThatCantBeReadKeepsEverything() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let damaged = local("Mac").appendingPathComponent("Trash/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("{ not a conversation".utf8).write(to: damaged.appendingPathComponent("meeting.json"))
        let now = Date()
        try await noticed(mac, phone, at: now)
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        try await pass(mac, "Mac", at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try FileManager.default.removeItem(at: damaged)
        let later = now.addingTimeInterval(3 * day)
        try await pass(mac, "Mac", at: later); try await noticed(mac, phone, at: later)
        try await pass(mac, "Mac", at: later.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// An iPhone whose Trash holds a conversation it can't read can't say what it holds: it acknowledges nothing.
    func testBehaviorADeviceWhoseTrashCantBeReadAcknowledgesNothing() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let damaged = local("Phone").appendingPathComponent("Trash/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: damaged.appendingPathComponent("meeting.json"))
        let now = Date()
        try await noticed(mac, phone, at: now)
        let presence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        XCTAssertNil(presence["superseded"])
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
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
        try await noticed(mac, phone, at: Date())
        try await pass(mac, "Mac", at: Date().addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(meeting.tracks[0].sha256)))
    }

    func testBehaviorAnObjectWrittenAgainDuringTheWaitStartsItAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        // Someone's upload of it, the same bytes under a new file.
        try rewrite(object)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(object), "its wait started again when it was written")
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day + 120))
        XCTAssertFalse(exists(object))
    }

    // MARK: A new reference to the same bytes

    /// An iPhone that acknowledged the notice imports a file with the same bytes into a new conversation. It never lets
    /// that file go while the object may go (whatever its budget), and its presence holds the object: it isn't deleted,
    /// and the notice lists it no more.
    func testBehaviorANewReferenceFromAnotherDeviceHoldsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let copy = try await phoneStore.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Same file"), source: .imported)
        XCTAssertEqual(copy.tracks[0].sha256, compressed.original.sha256)
        try await pass(phone, "Phone")
        let file = local("Phone").appendingPathComponent("Meetings/\(copy.id.uuidString)/\(copy.tracks[0].relativePath)")
        // However tight its budget (a new engine, as after a relaunch), its file stays: the object may go.
        let tight = try self.phone("Phone", budget: 1)
        let report = try await tight.evictAudio()
        XCTAssertTrue(report.evicted.isEmpty)
        XCTAssertTrue(exists(file))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(object))
        let state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256])
        XCTAssertEqual(try notice()?.objects, [])
        for offset in [2.0, 3, 4] { try await noticed(mac, phone, at: now.addingTimeInterval(offset * day)) }
        XCTAssertTrue(exists(object))
    }

    /// The same, but the Mac deletes the object on what it last saw (the iPhone's new presence and entry not arrived yet):
    /// the iPhone, holding the bytes, uploads it again once it sees it's gone, and says so; the Mac then applies the new
    /// conversation with its recording, and lists the object no more.
    func testBehaviorADeletionOnAStaleViewIsRepairedByTheDeviceHoldingTheBytes() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        let acknowledgedPresence = try Data(contentsOf: presenceURL("Phone"))
        let events = Set(files("Events"))
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let copy = try await phoneStore.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Same file"), source: .imported)
        try await pass(phone, "Phone")
        // What the iPhone wrote hasn't reached the Mac: its entry, and its presence holding the object.
        let holding = try Data(contentsOf: presenceURL("Phone"))
        let arrived = Set(files("Events")).subtracting(events)
        XCTAssertFalse(arrived.isEmpty)
        let aside = root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for name in arrived { try FileManager.default.moveItem(at: remote.appendingPathComponent("Events/\(name)"), to: aside.appendingPathComponent(name)) }
        try acknowledgedPresence.write(to: presenceURL("Phone"))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object), "deleted on a stale view")
        // It arrives.
        for name in arrived { try FileManager.default.moveItem(at: aside.appendingPathComponent(name), to: remote.appendingPathComponent("Events/\(name)")) }
        try holding.write(to: presenceURL("Phone"))
        let result = try await pass(phone, "Phone")
        XCTAssertTrue(exists(object), "the iPhone holding the bytes uploaded them again")
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix(SyncWarningWords.deletedOriginalNeeded) })
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 120))
        let applied = try await MeetingStore(rootURL: local("Mac")).list()
        XCTAssertTrue(applied.contains { $0.id == copy.id }, "the Mac applies the new conversation with its recording")
        for offset in [2.0, 3, 4] { try await noticed(mac, phone, at: now.addingTimeInterval(offset * day)) }
        let state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256])
        XCTAssertTrue(exists(object))
    }

    /// An iPhone never publishes by reference an object a notice lists: it waits, holding it, until the notice lists it
    /// no more (the Mac sees the hold), then publishes, and the journal keeps it from then on.
    func testBehaviorAnIPhoneDoesntPublishByReferenceWhatANoticeLists() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        var reference = Meeting(title: "By reference")
        var track = compressed.original
        track.id = UUID()
        reference.tracks = [track]
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        try await phoneStore.save(reference)
        let events = Set(files("Events"))
        try await pass(phone, "Phone")
        XCTAssertEqual(Set(files("Events")), events, "not published while the notice lists it")
        try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        XCTAssertEqual(try notice()?.objects, [], "the iPhone holds it: listed no more")
        try await pass(phone, "Phone")
        XCTAssertNotEqual(Set(files("Events")), events, "published by reference once nothing lists it")
        for offset in [1.0, 2, 3] { try await noticed(mac, phone, at: now.addingTimeInterval(offset * day + 60)) }
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// The race the notice can't close: an entry naming the object reaches the Mac only after it deleted it. A Mac still
    /// holding the original as a file (not let go yet) uploads it again; one that doesn't says the original is needed.
    func testBehaviorAReferenceArrivingAfterTheDeletionIsUploadedFromAnOriginalStillHereOrWarned() async throws {
        for keepsOriginal in [true, false] {
            root = makeTemporaryFolder("DaybookSupersededTests")
            cloud = SimulatedICloud()
            let mac = try mac(), phone = try phone()
            let compressed = try await recordedAndCompressed(mac, phone)
            let object = blob(compressed.original.sha256)
            try await acknowledged(mac, phone)
            let now = Date()
            try await noticed(mac, phone, at: now)
            let original = local("Mac").appendingPathComponent("Meetings/\(compressed.meeting.id.uuidString)/\(compressed.original.relativePath)")
            if !keepsOriginal { try FileManager.default.removeItem(at: original) }
            try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
            XCTAssertFalse(exists(object))
            // An entry naming it arrives late (written by the iPhone when it still had the bytes, say).
            let phoneStore = try MeetingStore(rootURL: local("Phone"))
            let copy = try await phoneStore.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Late"), source: .imported)
            try await pass(phone, "Phone")
            try cloud.withhold(object)
            try? FileManager.default.removeItem(at: SimulatedICloud.placeholder(object))
            XCTAssertFalse(exists(object))
            // The iPhone's file is gone too (lost with the device, say).
            try FileManager.default.removeItem(at: local("Phone").appendingPathComponent("Meetings/\(copy.id.uuidString)/\(copy.tracks[0].relativePath)"))
            let result = try await pass(mac, "Mac", at: now.addingTimeInterval(day + 120))
            let warning = result.warnings.first { $0.hasPrefix(SyncWarningWords.deletedOriginalNeeded) }
            XCTAssertNotNil(warning)
            XCTAssertEqual(exists(object), keepsOriginal, "uploaded again from the original still here")
            XCTAssertEqual(warning?.contains("Uploaded again"), keepsOriginal)
        }
    }

    // MARK: Who deletes

    /// Only the Mac that compacts: another Mac with compaction on never lists or deletes anything, and a Mac that stops
    /// being the one withdraws what it listed.
    func testBehaviorOnlyTheCompactingMacDeletesAndOneThatStopsWithdrawsItsNotice() async throws {
        let later = try mac("Mac-B"), phone = try phone()
        let compressed = try await recordedAndCompressed(later, phone, on: "Mac-B")
        try await acknowledged(later, phone, "Mac-B")
        XCTAssertEqual(try notice("Mac-B")?.objects.map(\.sha256), [compressed.original.sha256])
        // A Mac with a smaller device ID joins: it's the one now, and lists it afresh, once its library has judged the
        // conversation that arrived in its first pass.
        let first = try mac("Mac-A")
        try await pass(first, "Mac-A")
        XCTAssertNil(try notice("Mac-A"))
        try await pass(first, "Mac-A")
        XCTAssertEqual(try notice("Mac-A")?.objects.map(\.sha256), [compressed.original.sha256])
        let now = Date()
        try await pass(later, "Mac-B", at: now)
        XCTAssertEqual(try notice("Mac-B")?.objects, [], "withdrawn")
        try await pass(phone, "Phone"); try await pass(first, "Mac-A", at: now)
        for offset in [1.0, 2, 3] {
            try await pass(later, "Mac-B", at: now.addingTimeInterval(offset * day + 60))
            let due = await later.hasSupersededObjectsDue
            XCTAssertFalse(due)
        }
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let held = await later.supersededState()
        XCTAssertTrue(held.objects.isEmpty)
        // The Mac that compacts deletes it a day after every device, the other Mac included, acknowledged its notice.
        try await pass(first, "Mac-A", at: now.addingTimeInterval(3 * day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// An encrypted library's sealer retires what nothing live uses on its own: nothing here lists, waits, or deletes.
    func testBehaviorAnEncryptedLibraryListsAndDeletesNothingHere() async throws {
        let mac = try mac(seals: true), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = Date()
        for offset in [0.0, 1, 2, 3] { try await noticed(mac, phone, at: now.addingTimeInterval(offset * day + 60)) }
        XCTAssertNil(try notice())
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
        let gone = await phone.supersededRuntime.possiblyGone
        XCTAssertTrue(gone.contains(compressed.original.sha256), "the iPhone still counts the original as possibly gone")
    }

    // MARK: The clock

    /// A wall clock that jumps (2 days on while the continuous clock moved a minute) starts every wait again; across a
    /// restart, one more than three days on does too.
    func testBehaviorAClockThatJumpsStartsTheWaitAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        clockOffset = -2 * day + 60
        let jumped = now.addingTimeInterval(2 * day)
        try await pass(mac, "Mac", at: jumped)
        XCTAssertTrue(exists(object))
        var state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, jumped)
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, jumped)
        // Across a restart, four days on: started again too.
        boot = "boot-2"
        let restarted = jumped.addingTimeInterval(4 * day)
        try await pass(phone, "Phone"); try await pass(mac, "Mac", at: restarted)
        XCTAssertTrue(exists(object))
        state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, restarted)
        // Within the boot, a day by both clocks: gone.
        try await pass(mac, "Mac", at: restarted.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
    }

    /// Within a boot, a day by the wall clock isn't enough while the continuous clock says less.
    func testBehaviorTheContinuousClockMustSayADayToo() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        clockOffset = -30 * 60
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 31 * 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    // MARK: Right before deleting

    /// What voice profiles hold keeps an original in iCloud: before the wait (the library's word before the pass, a
    /// conversation it didn't judge counting as held), and asked again under the lock right before deleting.
    func testBehaviorVoiceProfilesHoldItAndAreAskedAgainRightBeforeDeleting() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let id = compressed.meeting.id
        try await pass(phone, "Phone")
        try await pass(mac, "Mac", heldForVoice: [id]); try await pass(phone, "Phone")
        try await pass(mac, "Mac", heldForVoice: [id])
        var state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "held: not free")
        try await pass(mac, "Mac", judged: [])
        state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "not judged: held")
        let now = Date()
        try await pass(mac, "Mac", at: now)
        try await noticed(mac, phone, at: now)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60), delete: false)
        let due = await mac.hasSupersededObjectsDue
        XCTAssertTrue(due)
        let store = try MeetingStore(rootURL: local("Mac"))
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [id])
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "held when asked again")
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// Between the pass and the deletion: an object written again, a journal entry that arrived, or a copy whose file
    /// went keeps it; nothing awaited inside the coordinated delete lets a write slip in.
    func testBehaviorWhatChangedSinceThePassKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        let store = try MeetingStore(rootURL: local("Mac"))
        // Written again.
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60), delete: false)
        try rewrite(object)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        // A journal entry arrived.
        let later = now.addingTimeInterval(day + 60)
        try await noticed(mac, phone, at: later)
        try await pass(mac, "Mac", at: later.addingTimeInterval(day + 60), delete: false)
        var due = await mac.hasSupersededObjectsDue
        XCTAssertTrue(due)
        let stray = remote.appendingPathComponent("Events/\(String(repeating: "a", count: 64)).json")
        try Data("{}".utf8).write(to: stray)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        try FileManager.default.removeItem(at: stray)
        // The copy's file went.
        try await pass(mac, "Mac", at: later.addingTimeInterval(day + 90), delete: false)
        due = await mac.hasSupersededObjectsDue
        XCTAssertTrue(due)
        let copyFile = local("Mac").appendingPathComponent("Meetings/\(compressed.meeting.id.uuidString)/\(compressed.meeting.tracks[0].relativePath)")
        let bytes = try Data(contentsOf: copyFile)
        try FileManager.default.removeItem(at: copyFile)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        try bytes.write(to: copyFile)
        // A device's presence holding it now.
        try await pass(mac, "Mac", at: later.addingTimeInterval(day + 100), delete: false)
        due = await mac.hasSupersededObjectsDue
        XCTAssertTrue(due)
        let acknowledged = try Data(contentsOf: presenceURL("Phone"))
        try editPresence("Phone") { record in
            guard var acks = record["superseded"] as? [[String: Any]] else { return }
            for index in acks.indices { acks[index]["holds"] = [compressed.original.sha256] }
            record["superseded"] = acks
        }
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        try acknowledged.write(to: presenceURL("Phone"))
        // A track here naming it now (the same file imported here since).
        try await pass(mac, "Mac", at: later.addingTimeInterval(day + 110), delete: false)
        due = await mac.hasSupersededObjectsDue
        XCTAssertTrue(due)
        _ = try await store.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Again"), source: .imported)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
    }

    /// An object that stopped being free and is listed again is at a new sequence: every acknowledgement must come again.
    func testBehaviorAnObjectListedAgainNeedsEveryAcknowledgementAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        cloud.setUploaded(blob(compressed.copy), false)
        try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        var state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
        cloud.setUploaded(blob(compressed.copy), true)
        // Listed again; the iPhone's acknowledgement is of the sequence before.
        try await pass(mac, "Mac", at: now.addingTimeInterval(120))
        state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince)
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        try await pass(mac, "Mac", at: now.addingTimeInterval(4 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await noticed(mac, phone, at: now.addingTimeInterval(4 * day))
        try await pass(mac, "Mac", at: now.addingTimeInterval(5 * day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A delete that fails is the report's error; the log doesn't say it went; it's tried again on a later pass.
    func testBehaviorADeleteThatFailsIsTheReportsErrorAndIsTriedAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        let blobs = remote.appendingPathComponent("Blobs")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: blobs.path)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blobs.path)
        XCTAssertTrue(exists(object))
        let report = await mac.compactionReport
        XCTAssertNotNil(report?.lastError)
        XCTAssertEqual(report?.deletedSuperseded, 0)
        let state = await mac.supersededState()
        XCTAssertNil(state.deleted[compressed.original.sha256])
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(object))
    }

    // MARK: Crashes

    func testBehaviorAStopAtAnyStepResumesOrRepeatsTheSameWork() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        // The app quits after the wait began: a new engine finds it remembered.
        let again = try self.mac()
        try await pass(again, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
        // A deletion logged before the object went, then a stop: the object's already gone, and nothing goes wrong.
        let libraryID = await again.libraryID
        let url = local("Mac").appendingPathComponent("Sync/superseded-\(try XCTUnwrap(libraryID).uuidString).json")
        var state = await again.supersededState()
        state.objects[compressed.original.sha256] = .init(copies: [compressed.copy], since: now.addingTimeInterval(-2 * day),
                                                         clock: SyncClockMark(boot: boot, seconds: 0),
                                                         stamp: VerifiedAsset(digest: compressed.original.sha256, size: 1, modified: now, inode: 1), sequence: 1)
        try SyncEncoding.data(state).write(to: url)
        let result = try await pass(again, "Mac", at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(result.warnings.isEmpty)
        let cleared = await again.supersededState()
        XCTAssertTrue(cleared.objects.isEmpty)
    }

    /// What's remembered here lost: every wait starts again, and the log and the notice's sequence come back from the
    /// notice in iCloud.
    func testBehaviorWhatsRememberedLostStartsTheWaitAgainAndKeepsTheLog() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let libraryID = await mac.libraryID
        let library = try XCTUnwrap(libraryID)
        let url = local("Mac").appendingPathComponent("Sync/superseded-\(library.uuidString).json")
        try await noticed(mac, phone, at: Date())
        let sequence = try XCTUnwrap(try notice()?.sequence)
        try FileManager.default.removeItem(at: url)
        let now = Date().addingTimeInterval(day + 60)
        try await pass(mac, "Mac", at: now)
        XCTAssertTrue(exists(object), "a day from when it's found again")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(try notice()?.sequence), sequence)
        try await noticed(mac, phone, at: now)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
        try FileManager.default.removeItem(at: url)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 120))
        let state = await mac.supersededState()
        XCTAssertNotNil(state.deleted[compressed.original.sha256], "the log comes back from the notice")
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
        let now = Date()
        try await noticed(mac, phone, at: now)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
        XCTAssertTrue(exists(file), "iCloud's object going doesn't touch a device's own files")
        report = try await phone.evictAudio()
        XCTAssertEqual(report.evicted.map(\.sha256), [compressed.original.sha256])
        XCTAssertFalse(exists(file))
    }

    // MARK: Helpers

    private final class UploadAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var names: Set<String> = []
        var unanswered: Set<String> {
            get { lock.withLock { names } }
            set { lock.withLock { names = newValue } }
        }
    }

    private func rewrite(_ url: URL) throws {
        let bytes = try Data(contentsOf: url)
        try FileManager.default.removeItem(at: url)
        try bytes.write(to: url)
    }

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
