import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookCore

/// Superseded originals in iCloud (LibrarySyncSuperseded.swift): once a Mac replaces a recording with a compressed copy,
/// the original's object in `Blobs/` goes only after compaction pruned every journal entry naming it, every recording
/// whose original it is has its copy in iCloud and here, nothing here names it, the compacting Mac's notice listed it and
/// every device acknowledged that without holding it for a day, then wrote its presence again with what it wrote applied
/// here; then, after the pass, with everything asked again. Every device treats such an object as possibly gone. iCloud
/// is a temporary folder (`SimulatedICloud`).
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
    /// Macs check at least this often between the moments a test names (a day is a day watched).
    private let checkEvery: TimeInterval = 6 * 3600
    private var macs: [String: LibrarySyncEngine] = [:]
    private var lastPass: [String: Date] = [:]
    /// How far behind a device's own clock is, for the date its presence says (a clock a month behind, say).
    private var presenceSkew: [String: TimeInterval] = [:]
    /// Devices whose passes leave what they write not uploaded until their next pass, as real iCloud does.
    private var uploadsLater: Set<String> = []

    override func setUpWithError() throws {
        root = makeTemporaryFolder("DaybookSupersededTests")
        cloud = SimulatedICloud()
        keychain = MemoryLibraryKeyStore()
    }

    /// Presence is written on every pass here (the apps rewrite it every ten minutes).
    private func mac(_ name: String = "Mac", compaction: SyncCompactionPolicy? = .eager, seals: Bool = false) throws -> LibrarySyncEngine {
        let engine = try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: "\(name) Studio", canProcess: true),
            presenceRefreshInterval: 1, cloud: cloud.files, keyStore: keychain, sealsNewLibrary: seals, compaction: compaction))
        macs[name] = engine
        return engine
    }

    private func phone(_ name: String = "Phone", budget: UInt64 = 1 << 30) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            audioCache: AudioCachePolicy(budgetBytes: budget), presenceRefreshInterval: 1, cloud: cloud.files, keyStore: keychain, sealsNewLibrary: false))
    }

    /// The Macs' checks every few hours up to just before `time` (as running Macs check), before another device syncs then.
    private func advanceMacs(to time: Date, except: String? = nil) async throws {
        for (name, engine) in macs.sorted(by: { $0.key < $1.key }) where name != except {
            guard let last = lastPass[name], time.timeIntervalSince(last) > checkEvery else { continue }
            var step = last.addingTimeInterval(checkEvery)
            while time.timeIntervalSince(step) > 1 {
                try await single(engine, name, at: step, heldForVoice: [], judged: nil, delete: true)
                step = step.addingTimeInterval(checkEvery)
            }
        }
    }

    /// A pass supplying everything the device's library holds, applied and acknowledged, as the library runs it: told
    /// first which conversations voice profiles hold (`heldForVoice`, judged: all of them unless `judged` says), and,
    /// after it, under the lock, deleting what it found due (`delete`). A Mac also checks every few hours between the
    /// moments a test names (`watched`), as a running Mac does.
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, at now: Date? = nil, heldForVoice: Set<UUID> = [],
                      judged: Set<UUID>? = nil, delete: Bool = true, watched: Bool = true, metadata: Data? = nil,
                      judgment: SupersededJudgment = .judge) async throws -> SyncResult {
        let when = now ?? Date()
        // Every other Mac kept checking up to then, so what each saw is in the order it was written.
        if watched, now != nil { try await advanceMacs(to: when.addingTimeInterval(-5), except: name) }
        if watched, macs[name] != nil, let last = lastPass[name], when.timeIntervalSince(last) > checkEvery {
            var step = last.addingTimeInterval(checkEvery)
            while when.timeIntervalSince(step) > 1 {
                try await single(engine, name, at: step, heldForVoice: heldForVoice, judged: judged, delete: delete, judgment: judgment)
                step = step.addingTimeInterval(checkEvery)
            }
        }
        return try await single(engine, name, at: when, heldForVoice: heldForVoice, judged: judged, delete: delete, metadata: metadata,
                                judgment: judgment)
    }

    @discardableResult
    private func single(_ engine: LibrarySyncEngine, _ name: String, at when: Date, heldForVoice: Set<UUID>, judged: Set<UUID>?,
                        delete: Bool, metadata: Data? = nil, judgment: SupersededJudgment = .judge) async throws -> SyncResult {
        lastPass[name] = when
        let mark = SyncClockMark(boot: boot, seconds: when.timeIntervalSince1970 + clockOffset)
        await engine.setCompactionClock { when }
        await engine.setContinuousClock { mark }
        let written = when.addingTimeInterval(presenceSkew[name] ?? 0)
        await engine.setPresenceClock { written }
        let store = try MeetingStore(rootURL: local(name))
        let meetings = try await store.list()
        await engine.holdOriginalsInICloud(for: heldForVoice, judged: judged ?? Set(meetings.map(\.id)), judgment: judgment)
        if uploadsLater.contains(name) { cloud.holdUploads(since: Date()) }
        defer { if uploadsLater.contains(name) { cloud.holdUploads(since: nil) } }
        let result = try await engine.synchronize(meetings: meetings, libraryMetadata: metadata)
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
    /// original is free to go from then, listed in its notice, and acknowledged by the iPhone.
    private func acknowledged(_ mac: LibrarySyncEngine, _ phone: LibrarySyncEngine, _ name: String = "Mac") async throws {
        try await pass(phone, "Phone")
        try await pass(mac, name)    // proposes
        try await pass(phone, "Phone") // acknowledges
        try await pass(mac, name)    // commits: the history naming the original is pruned
    }

    /// The other device syncs at `now` (writing its presence, and reading and acknowledging the notice), then the Mac.
    @discardableResult
    private func noticed(_ mac: LibrarySyncEngine, _ device: LibrarySyncEngine, at now: Date, _ name: String = "Mac", _ deviceName: String = "Phone",
                         watched: Bool = true, judgment: SupersededJudgment = .judge) async throws -> SyncResult {
        try await pass(device, deviceName, at: now.addingTimeInterval(-10), watched: watched)
        return try await pass(mac, name, at: now, watched: watched, judgment: judgment)
    }

    /// When the Mac first saw every device acknowledge this object.
    private func acknowledgedSince(_ mac: LibrarySyncEngine, _ sha256: String) async throws -> Date {
        let state = await mac.supersededState()
        return try XCTUnwrap(state.objects[sha256]?.acknowledgedSince)
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
        XCTAssertEqual(try notice()?.epoch, listed.epoch)
        let presence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        XCTAssertNotNil(presence["superseded"], "the iPhone acknowledges the notice in its presence")
        XCTAssertNotNil(presence["written"], "with what it wrote lately")
        // Free, then acknowledged: a day from then, not a minute before.
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await noticed(mac, phone, at: now.addingTimeInterval(day - 60))
        XCTAssertTrue(exists(object))
        let result = try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
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
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 120))
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
        let start = Date()
        try await pass(mac, "Mac", at: start.addingTimeInterval(3 * day))
        XCTAssertTrue(exists(object), "a device seen lately that hasn't caught up may still need it")
        try agePresence("Phone", days: 20)
        try await pass(mac, "Mac", at: start.addingTimeInterval(3 * day + 60))
        XCTAssertTrue(exists(object), "seen 23 days ago, it still counts")
        let waiting = await mac.supersededState()
        XCTAssertTrue(waiting.objects.isEmpty)
        // Away more than 30 days, it no longer holds compaction back (the rule for devices that are away), and the object
        // goes a day after the iPad acknowledges the notice.
        try agePresence("Phone", days: 31)
        let now = start.addingTimeInterval(4 * day)
        try await pass(mac, "Mac", at: now); try await pass(pad, "Pad", at: now); try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        let free = await mac.supersededState()
        XCTAssertNotNil(free.objects[compressed.original.sha256])
        try await noticed(mac, pad, at: now.addingTimeInterval(120), "Mac", "Pad")
        try await noticed(mac, pad, at: now.addingTimeInterval(day + 180), "Mac", "Pad")
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

    func testBehaviorAnObjectFreeToGoIsWithdrawnWhileEveryOtherDeviceIsAway() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        // Then the only other device goes quiet: this Mac may be the one that's off (its clock ahead, say), so nothing goes,
        // and its notice lists nothing meanwhile.
        try agePresence("Phone", days: 31)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        XCTAssertEqual(try notice()?.objects, [])
    }

    func testBehaviorADeviceThatDoesntKnowCompressedRecordingsKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        // A device seen in the last 30 days without `compress-1` holds it back, fresh and acknowledging as it is.
        try await pass(phone, "Phone", at: now.addingTimeInterval(2 * day))
        try editPresence("Phone") { $0["features"] = ($0["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.compressionFeature } }
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day + 10))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// An older Daybook that doesn't read notices never acknowledges one, and its presence lacks `superseded-1`: nothing is
    /// listed, and nothing goes, while it's in use.
    func testBehaviorAnOlderDeviceThatDoesntReadNoticesKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 60))
        try editPresence("Phone") { record in
            record["features"] = (record["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.supersededFeature }
            record["superseded"] = nil
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 70))
        try await pass(mac, "Mac", at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "nothing is listed while a device in use can't read the notice")
    }

    /// The acknowledgement alone, the feature still listed and the presence fresh: an iPhone whose presence acknowledges
    /// nothing keeps it.
    func testBehaviorADeviceThatHasntAcknowledgedTheNoticeKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 60))
        try editPresence("Phone") { $0["superseded"] = nil }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 70))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince)
    }

    /// An acknowledgement of another Mac's notice counts for nothing here.
    func testBehaviorAnAcknowledgementOfAnotherMacsNoticeCountsForNothing() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 60))
        try editPresence("Phone") { record in
            guard var acks = record["superseded"] as? [[String: Any]] else { return }
            for index in acks.indices { acks[index]["device"] = "Another Mac" }
            record["superseded"] = acks
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 70))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince)
    }

    /// Two apps writing one device's presence (the iPhone app kept beside the one that replaced it): one may hold what the
    /// other's acknowledgement doesn't say, so that device's acknowledgements count for nothing.
    func testBehaviorADeviceTwoAppsWriteForAcknowledgesNothing() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(60))
        try editPresence("Phone") { $0["appInstallation"] = "first" }
        try await pass(mac, "Mac", at: now.addingTimeInterval(70))
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 60))
        try editPresence("Phone") { $0["appInstallation"] = "second" }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 70))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince)
    }

    func testBehaviorTheNoticeMustBeInICloudBeforeAnAcknowledgementCounts() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        // The notice never reads as uploaded from its first write.
        cloud.holdUploads(under: remote.appendingPathComponent("Superseded"))
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        var state = await mac.supersededState()
        XCTAssertNotNil(state.objects[compressed.original.sha256])
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince)
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        cloud.holdUploads(under: nil)
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day + 60))
        state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, now.addingTimeInterval(2 * day + 60))
        try await noticed(mac, phone, at: now.addingTimeInterval(3 * day + 120))
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
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(object), "the copy isn't confirmed uploaded")
        let waiting = await mac.supersededState()
        XCTAssertTrue(waiting.objects.isEmpty)
        // Confirmed: free from then, and gone a day after the iPhone acknowledges it.
        cloud.setUploaded(blob(compressed.copy), true)
        let later = now.addingTimeInterval(2 * day + 60)
        try await pass(mac, "Mac", at: later)
        try await noticed(mac, phone, at: later.addingTimeInterval(60))
        try await noticed(mac, phone, at: later.addingTimeInterval(day))
        XCTAssertTrue(exists(object))
        try await noticed(mac, phone, at: later.addingTimeInterval(day + 120))
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
            let engine = try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
                audioPolicy: eager ? .eager : .onDemand,
                device: SyncDeviceIdentity(deviceClass: eager ? .mac : .phone, displayName: name, canProcess: eager),
                audioCache: eager ? nil : AudioCachePolicy(budgetBytes: 1 << 30), presenceRefreshInterval: 1, cloud: strict, keyStore: keychain,
                sealsNewLibrary: false, compaction: eager ? .eager : nil))
            if eager { macs[name] = engine }
            return engine
        }
        let mac = try engine("Mac", eager: true), phone = try engine("Phone", eager: false)
        let compressed = try await recordedAndCompressed(mac, phone)
        answers.unanswered = [compressed.copy]
        try await acknowledged(mac, phone)
        let now = Date()
        try await noticed(mac, phone, at: now)
        try await noticed(mac, phone, at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
    }

    func testBehaviorNothingGoesUntilEveryCompactionCommitIsInICloud() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let commits = files("Compaction").map { remote.appendingPathComponent("Compaction/\($0)") }
        XCTAssertFalse(commits.isEmpty)
        let before = await mac.supersededState().objects[compressed.original.sha256]
        let sequence = try XCTUnwrap(try notice()?.sequence)
        for url in commits { cloud.setUploaded(url, false) }
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "a device finding it gone must find what pruned its history")
        // Nothing judged meanwhile: still listed, its wait and acknowledgement as they were.
        let during = await mac.supersededState().objects[compressed.original.sha256]
        XCTAssertEqual(during?.since, before?.since)
        XCTAssertEqual(during?.acknowledgedSince, before?.acknowledgedSince)
        XCTAssertEqual(try notice()?.sequence, sequence)
        for url in commits { cloud.setUploaded(url, true) }
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// Nothing comes due in a pass whose notice, as it stands, isn't in iCloud; the acknowledgements stay.
    func testBehaviorNothingComesDueWhileTheNoticeIsntInICloud() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let record = remote.appendingPathComponent("Superseded/\(SupersededRecord.fileName(for: "Mac"))")
        try await noticed(mac, phone, at: now.addingTimeInterval(day - 60))
        cloud.setUploaded(record, false)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, now, "its acknowledgement stays")
        cloud.setUploaded(record, true)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// As with real iCloud, what each pass writes is uploaded only by the next: a compaction commit and a notice rewritten
    /// for a newly listed original, twice in the day, don't hold back an original already waiting.
    func testBehaviorCommitsAndNewListingsDontHoldBackAWaitingOriginal() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let start = try await acknowledgedSince(mac, compressed.original.sha256)
        uploadsLater = ["Mac"]
        var listed: [String] = []
        for (index, hours) in [6.0, 14].enumerated() {
            let time = start.addingTimeInterval(hours * 3600)
            let source = root.appendingPathComponent("later-\(index).wav")
            try Data(repeating: UInt8(40 + index), count: 8_192).write(to: source)
            let meeting = try await MeetingStore(rootURL: local("Mac")).importAudio(from: source, into: Meeting(title: "Day \(index)"), source: .microphone)
            try await pass(mac, "Mac", at: time, watched: false)
            try await pass(phone, "Phone", at: time.addingTimeInterval(10), watched: false)
            let replaced = try await compress(meeting, copyByte: UInt8(140 + index))
            // The copy published, a proposal acknowledged, the commit, the listing, the notice in iCloud.
            for step in 1...6 { try await noticed(mac, phone, at: time.addingTimeInterval(Double(step) * 60), watched: false) }
            listed.append(replaced.original.sha256)
        }
        let notice = try XCTUnwrap(try notice())
        XCTAssertTrue(Set(listed).isSubset(of: notice.objects.map(\.sha256)), "each listed in its turn")
        let state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, start, "its wait went on")
        try await noticed(mac, phone, at: start.addingTimeInterval(day - 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await noticed(mac, phone, at: start.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)), "on time")
        XCTAssertTrue(listed.allSatisfy { exists(blob($0)) })
    }

    /// A library with too little history to compact still proposes when that would let a replaced original go.
    func testBehaviorAReplacedOriginalIsReasonEnoughToCompact() async throws {
        let policy = SyncCompactionPolicy(minimumEntries: 1_000, minimumBytes: 8_000, interval: 0, maximumCommits: 2)
        let mac = try mac(compaction: policy), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let pruned = await mac.compactionRuntime.prunedIDs
        XCTAssertFalse(pruned.isEmpty, "the original's 8 KB counts toward what compacting gains")
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    // MARK: Every device, after the day

    /// An acknowledgement is only as fresh as the presence carrying it: every device must write its presence again a full
    /// day after it acknowledged (an iPhone off since then may have learned a voice, or named a speaker, since).
    func testBehaviorEveryDeviceMustWriteItsPresenceAgainAfterTheDay() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        // It writes again within the day (two hours before its end), then not after it.
        try await noticed(mac, phone, at: now.addingTimeInterval(day - 2 * 3600))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        try await pass(mac, "Mac", at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the iPhone hasn't written since the day was up")
        XCTAssertEqual(try notice()?.deleted, [])
        try await noticed(mac, phone, at: now.addingTimeInterval(3 * day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// Only a full pass acknowledges again: a presence written in between (the app's timer, while it records) says the
    /// same `supersededAt`, so it doesn't pass for one.
    func testBehaviorAPresenceWrittenBetweenFullPassesIsntANewAcknowledgement() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await noticed(mac, phone, at: now.addingTimeInterval(3600))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 30))
        let before = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        try await phone.publishPresence()
        let after = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        XCTAssertNotEqual(after["lastSeen"] as? String, before["lastSeen"] as? String)
        XCTAssertEqual(after["supersededAt"] as? String, before["supersededAt"] as? String)
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the iPhone hasn't acknowledged on a full pass since the day")
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// Every device's latest acknowledgement must have been seen here in the last six hours: one from longer ago may
    /// not say what the device wrote since.
    func testBehaviorAnAcknowledgementSeenMoreThanSixHoursAgoKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        // It acknowledges again after the day, saying it wrote something that hasn't arrived.
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30))
        let acknowledged = try Data(contentsOf: presenceURL("Phone"))
        try editPresence("Phone") { record in
            var written = record["written"] as? [String: Any] ?? [:]
            written["events"] = [String(repeating: "c", count: 64)]
            record["written"] = written
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        // Seven hours on, the presence says nothing unknown any more, but this Mac saw that acknowledgement seven hours ago.
        try acknowledged.write(to: presenceURL("Phone"))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 7 * 3600), watched: false)
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "seen more than six hours ago")
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 7 * 3600 + 60), watched: false)
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// The watermark is as it stands at every presence write: settings a device wrote in a pass of settings alone (while
    /// it records) are waited for, though it hasn't had a full pass since.
    func testBehaviorSettingsWrittenOutsideAFullPassAreWaitedFor() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30))
        let settings = Set(files("Metadata"))
        let meetings = try await MeetingStore(rootURL: local("Phone")).list()
        let result = try await phone.synchronize(meetings: meetings, libraryMetadata: try SyncEncoding.data(LibraryMetadata()), scope: .metadataOnly)
        try await phone.acknowledge(result.checkpointID)
        let written = Set(files("Metadata")).subtracting(settings)
        XCTAssertEqual(written.count, 1)
        let presence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        XCTAssertEqual((presence["written"] as? [String: Any])?["settings"] as? String, written.first.map { ($0 as NSString).deletingPathExtension })
        let aside = root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for name in written { try FileManager.default.moveItem(at: remote.appendingPathComponent("Metadata/\(name)"), to: aside.appendingPathComponent(name)) }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the iPhone's settings aren't here yet")
        for name in written { try FileManager.default.moveItem(at: aside.appendingPathComponent(name), to: remote.appendingPathComponent("Metadata/\(name)")) }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 120))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 180))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// What a device says it wrote must be applied here first (a voiceprint in a settings version, a name in an event,
    /// that hasn't arrived), and the pass that brings new settings judges nothing: only the pass after it may delete.
    func testBehaviorWhatADeviceWroteMustBeAppliedFirst() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        // The iPhone writes library settings (a voiceprint, say) a day on; they haven't reached the Mac.
        let settings = Set(files("Metadata"))
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30), metadata: try SyncEncoding.data(LibraryMetadata()))
        let written = Set(files("Metadata")).subtracting(settings)
        XCTAssertEqual(written.count, 1)
        let aside = root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for name in written { try FileManager.default.moveItem(at: remote.appendingPathComponent("Metadata/\(name)"), to: aside.appendingPathComponent(name)) }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the iPhone's settings aren't applied here yet")
        for name in written { try FileManager.default.moveItem(at: aside.appendingPathComponent(name), to: remote.appendingPathComponent("Metadata/\(name)")) }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 120))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the pass that brings them judges nothing")
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 180))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A pass that changed a conversation starts its recordings' originals' waits again (a name given in it isn't a
    /// voiceprint until the library has seen it); they stay listed.
    func testBehaviorAConversationChangedInThePassStartsItsWaitAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let sequence = try XCTUnwrap(try notice()?.sequence)
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let listed = try await phoneStore.list()
        var edited = try XCTUnwrap(listed.first { $0.id == compressed.meeting.id })
        edited.notes = "Typed on the iPhone"
        try await phoneStore.save(edited)
        let changed = now.addingTimeInterval(day + 60)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30))
        try await pass(mac, "Mac", at: changed)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, changed, "it starts again")
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, changed)
        XCTAssertEqual(try notice()?.sequence, sequence, "still listed")
        try await noticed(mac, phone, at: changed.addingTimeInterval(day - 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await noticed(mac, phone, at: changed.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// One pass bringing both new settings and an edit to the conversation (a name given, and the person it's for) starts
    /// its wait again too, though the pass judges nothing else.
    func testBehaviorAPassBringingSettingsAndAnEditStartsTheWaitAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let listed = try await phoneStore.list()
        var edited = try XCTUnwrap(listed.first { $0.id == compressed.meeting.id })
        edited.notes = "Named on the iPhone"
        try await phoneStore.save(edited)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30), metadata: try SyncEncoding.data(LibraryMetadata()))
        let both = now.addingTimeInterval(day + 60)
        try await pass(mac, "Mac", at: both)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, both, "it starts again")
        try await noticed(mac, phone, at: both.addingTimeInterval(120))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await noticed(mac, phone, at: both.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A conversation changed in a pass that can't judge (another conversation's recording still downloading) isn't
    /// forgotten: the next pass that judges, after a relaunch too, starts its original's wait again.
    func testBehaviorAConversationChangedInAPassThatCantJudgeStartsItsWaitLater() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await noticed(mac, phone, at: now.addingTimeInterval(day - 60))
        // On the iPhone, something new recorded, and a name given in the compressed conversation.
        let source = root.appendingPathComponent("walk.wav")
        try Data(repeating: 77, count: 4_096).write(to: source)
        let walk = try await MeetingStore(rootURL: local("Phone")).importAudio(from: source, into: Meeting(title: "Walk"), source: .microphone)
        try await editOnPhone(compressed.meeting.id, "Vlad named on the iPhone")
        try await pass(phone, "Phone", at: now.addingTimeInterval(day), watched: false)
        // The new recording's audio hasn't reached the Mac: its pass can't judge.
        let walkObject = blob(walk.tracks[0].sha256)
        cloud.holdDownloads(true)
        try cloud.evict(walkObject)
        let incomplete = try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60), watched: false)
        XCTAssertGreaterThan(incomplete.pendingDownloads, 0)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        cloud.holdDownloads(false)
        try cloud.deliver(walkObject)
        let relaunched = try self.mac()
        let judged = now.addingTimeInterval(day + 120)
        try await noticed(relaunched, phone, at: judged, watched: false)
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the name may not be a voiceprint yet")
        let state = await relaunched.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, judged, "it starts again")
        XCTAssertNil(state.unrestarted)
    }

    /// Conversations changed in a pass that can't judge, when saving them fails, are saved on the next pass (compared
    /// with what's saved, not with memory), so a relaunch after it still restarts the wait.
    func testBehaviorChangedConversationsThatCouldntBeSavedAreSavedOnTheNextPass() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await noticed(mac, phone, at: now.addingTimeInterval(day - 60))
        let source = root.appendingPathComponent("walk.wav")
        try Data(repeating: 78, count: 4_096).write(to: source)
        let walk = try await MeetingStore(rootURL: local("Phone")).importAudio(from: source, into: Meeting(title: "Walk"), source: .microphone)
        try await editOnPhone(compressed.meeting.id, "Vlad named on the iPhone")
        try await pass(phone, "Phone", at: now.addingTimeInterval(day), watched: false)
        let walkObject = blob(walk.tracks[0].sha256)
        cloud.holdDownloads(true)
        try cloud.evict(walkObject)
        struct Failed: Error {}
        await mac.setSupersededRememberFault { throw Failed() }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60), watched: false)
        await mac.setSupersededRememberFault(nil)
        // Still unable to judge, but saved this time.
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 90), watched: false)
        cloud.holdDownloads(false)
        try cloud.deliver(walkObject)
        let relaunched = try self.mac()
        let judged = now.addingTimeInterval(day + 120)
        try await noticed(relaunched, phone, at: judged, watched: false)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let state = await relaunched.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, judged)
    }

    /// While the conversations changed since the last check can't be saved, nothing comes due.
    func testBehaviorNothingComesDueWhileChangedConversationsArentSaved() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let other = Meeting(title: "Other")
        try await MeetingStore(rootURL: local("Mac")).save(other)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await editOnPhone(other.id, "Changed on the iPhone")
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30))
        struct Failed: Error {}
        await mac.setSupersededRememberFault { throw Failed() }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        await mac.setSupersededRememberFault(nil)
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "not while what changed isn't saved")
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A conversation, or a recording, carrying fields this version can't read keeps its originals: they might say to,
    /// as they keep a recording from being compressed.
    func testBehaviorAConversationWithFieldsThisVersionCantReadKeepsItsOriginal() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let file = local("Mac").appendingPathComponent("Meetings/\(compressed.meeting.id.uuidString)/meeting.json")
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        record["keepsOriginals"] = true
        try JSONSerialization.data(withJSONObject: record).write(to: file)
        let stored = try await MeetingStore(rootURL: local("Mac")).list().first { $0.id == compressed.meeting.id }
        XCTAssertFalse(try XCTUnwrap(stored).unknownFields.isEmpty)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        XCTAssertEqual(try notice()?.objects, [])
    }

    /// Every other way a pass ends before judging keeps a changed conversation for the next one that does: a presence it
    /// can't read (a trim), its own notice not downloaded (nothing runs), the library saying stop (a withdrawal).
    func testBehaviorEveryPassThatDoesntJudgeKeepsAChangedConversationForTheNext() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        var since = try await acknowledgedSince(mac, compressed.original.sha256)
        let record = remote.appendingPathComponent("Superseded/\(SupersededRecord.fileName(for: "Mac"))")
        let exits: [(String, () throws -> Void, () throws -> Void, SupersededJudgment)] = [
            ("a presence it can't read", { self.cloud.holdDownloads(true); try self.cloud.evict(self.presenceURL("Phone")) },
             { self.cloud.holdDownloads(false); try self.cloud.deliver(self.presenceURL("Phone")) }, .judge),
            ("its own notice not downloaded", { self.cloud.holdDownloads(true); try self.cloud.evict(record) },
             { self.cloud.holdDownloads(false); try self.cloud.deliver(record) }, .judge),
            ("the library saying stop", {}, {}, .stop),
        ]
        for (index, (name, block, unblock, judgment)) in exits.enumerated() {
            // Caught up a day after its acknowledgement, then changed on the iPhone.
            try await noticed(mac, phone, at: since.addingTimeInterval(day - 60))
            try await editOnPhone(compressed.meeting.id, "Edit \(index)")
            try await pass(phone, "Phone", at: since.addingTimeInterval(day), watched: false)
            try block()
            try await pass(mac, "Mac", at: since.addingTimeInterval(day + 60), watched: false, judgment: judgment)
            try unblock()
            let judged = since.addingTimeInterval(day + 120)
            try await noticed(mac, phone, at: judged, watched: false)
            XCTAssertTrue(exists(blob(compressed.original.sha256)), name)
            try await noticed(mac, phone, at: judged.addingTimeInterval(60), watched: false)
            // Started again on the pass that judged (withdrawn, it's listed afresh on the pass after).
            let state = await mac.supersededState()
            XCTAssertEqual(state.objects[compressed.original.sha256]?.since, judgment == .stop ? judged.addingTimeInterval(60) : judged,
                           "\(name): it starts again")
            try await noticed(mac, phone, at: judged.addingTimeInterval(120), watched: false)
            let acknowledged = await mac.supersededState()
            since = try XCTUnwrap(acknowledged.objects[compressed.original.sha256]?.acknowledgedSince)
        }
        try await noticed(mac, phone, at: since.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A pass that judges nothing (the library says pause) still takes out of the listing what certainly isn't free:
    /// here what the iPhone holds, so it can publish it by reference.
    func testBehaviorAPausedPassStillTakesWhatsHeldOutOfTheNotice() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(60), watched: false)
        try editPresence("Phone") { record in
            guard var acks = record["superseded"] as? [[String: Any]] else { return }
            for index in acks.indices { acks[index]["holds"] = [compressed.original.sha256] }
            record["superseded"] = acks
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(120), watched: false, judgment: .pause)
        XCTAssertEqual(try notice()?.objects, [])
    }

    /// A commit, then the notice, kept from iCloud for several passes: the waiting original's wait and acknowledgement go
    /// on, nothing comes due meanwhile (past its day too), and it goes on the first pass after.
    func testBehaviorACommitOrTheNoticeHeldForSeveralPassesOnlyDelaysIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let start = try await acknowledgedSince(mac, compressed.original.sha256)
        let before = await mac.supersededState().objects[compressed.original.sha256]
        // Another recording replaced, its commit kept from iCloud.
        let time = start.addingTimeInterval(3600)
        let source = root.appendingPathComponent("held.wav")
        try Data(repeating: 61, count: 8_192).write(to: source)
        let meeting = try await MeetingStore(rootURL: local("Mac")).importAudio(from: source, into: Meeting(title: "Held"), source: .microphone)
        try await pass(mac, "Mac", at: time, watched: false)
        try await pass(phone, "Phone", at: time.addingTimeInterval(10), watched: false)
        let replaced = try await compress(meeting, copyByte: 161)
        cloud.holdUploads(under: remote.appendingPathComponent("Compaction"))
        for step in 1...6 { try await noticed(mac, phone, at: time.addingTimeInterval(Double(step) * 60), watched: false) }
        try await noticed(mac, phone, at: start.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "a commit still uploading")
        var state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, before?.since)
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, start)
        XCTAssertNil(state.objects[replaced.original.sha256], "not listed while its commit isn't in iCloud")
        // The commit in iCloud, then the notice listing the new one kept from it.
        cloud.holdUploads(under: remote.appendingPathComponent("Superseded"))
        for step in 1...3 { try await noticed(mac, phone, at: start.addingTimeInterval(day + 60 + Double(step) * 60), watched: false) }
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the notice still uploading")
        state = await mac.supersededState()
        XCTAssertNotNil(state.objects[replaced.original.sha256])
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, start)
        cloud.holdUploads(under: nil)
        try await noticed(mac, phone, at: start.addingTimeInterval(day + 300), watched: false)
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
        XCTAssertTrue(exists(blob(replaced.original.sha256)))
    }

    /// A conversation the pass couldn't bring up to date (this Mac's own change to it couldn't be saved to iCloud) starts
    /// its originals' waits again; and what another device wrote in it isn't applied, so a device saying it wrote that
    /// keeps everything.
    func testBehaviorAConversationThePassCouldntBringUpToDateIsntApplied() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let other = Meeting(title: "Other")
        try await MeetingStore(rootURL: local("Mac")).save(other)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let macStore = try MeetingStore(rootURL: local("Mac")), phoneStore = try MeetingStore(rootURL: local("Phone"))
        func edit(_ store: MeetingStore, _ id: UUID, _ notes: String) async throws {
            let listed = try await store.list()
            var meeting = try XCTUnwrap(listed.first { $0.id == id })
            meeting.notes = notes
            try await store.save(meeting)
        }
        let events = remote.appendingPathComponent("Events")
        // Another conversation, edited on both: the Mac's change can't be saved, so the iPhone's isn't applied here.
        try await edit(phoneStore, other.id, "On the iPhone")
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30))
        try await edit(macStore, other.id, "On the Mac")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: events.path)
        let result = try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: events.path)
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix(SyncWarningWords.unsavedChange) })
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the iPhone says it wrote what isn't applied here")
        var state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, now, "its own wait goes on")
        // The conversation itself: its wait starts again.
        try await edit(macStore, compressed.meeting.id, "On the Mac")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: events.path)
        let stopped = now.addingTimeInterval(day + 90)
        try await pass(mac, "Mac", at: stopped)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: events.path)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, stopped)
        try await noticed(mac, phone, at: stopped.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// An acknowledgement that holds everything (more than presence carries) keeps everything: nothing is listed.
    func testBehaviorAnAcknowledgementHoldingEverythingKeepsEverything() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 60))
        try editPresence("Phone") { record in
            guard var acks = record["superseded"] as? [[String: Any]] else { return }
            for index in acks.indices { acks[index]["holdsAll"] = true }
            record["superseded"] = acks
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 70))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        XCTAssertEqual(try notice()?.objects, [])
    }

    /// A watermark that couldn't carry everything the device wrote can't be checked: nothing goes for it.
    func testBehaviorAnIncompleteWatermarkKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 60))
        try editPresence("Phone") { record in
            var written = record["written"] as? [String: Any] ?? [:]
            written["complete"] = false
            record["written"] = written
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 70))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// A device whose clock is more than a month behind still takes part: this Mac saw its presence change lately, so
    /// what it holds keeps the object, whatever date its presence says.
    func testBehaviorADeviceWhoseClockIsAMonthBehindStillTakesPart() async throws {
        let mac = try mac(), phone = try phone(), pad = try self.phone("Pad")
        let compressed = try await recordedAndCompressed(mac, phone)
        try await pass(pad, "Pad")
        try await acknowledged(mac, phone)
        try await noticed(mac, pad, at: Date(), "Mac", "Pad")
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        // The iPhone's clock goes 40 days behind, and it holds the object (a publication by reference waiting).
        presenceSkew["Phone"] = -40 * day
        var reference = Meeting(title: "By reference")
        var track = compressed.original
        track.id = UUID()
        reference.tracks = [track]
        try await MeetingStore(rootURL: local("Phone")).save(reference)
        try await pass(phone, "Phone", at: now.addingTimeInterval(60))
        try await pass(mac, "Mac", at: now.addingTimeInterval(120))
        for offset in [1.0, 2] {
            try await pass(phone, "Phone", at: now.addingTimeInterval(offset * day + 30))
            try await noticed(mac, pad, at: now.addingTimeInterval(offset * day + 60), "Mac", "Pad")
        }
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        XCTAssertEqual(try notice()?.deleted, [], "never deleted")
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
        try await noticed(mac, phone, at: now.addingTimeInterval(4 * day))
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
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "one recording's copy passing doesn't free a shared original")
        state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
        cloud.setUploaded(blob(second.copy), true)
        let later = now.addingTimeInterval(2 * day + 60)
        try await pass(mac, "Mac", at: later)
        state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.copies, [compressed.copy, second.copy].sorted())
        try await noticed(mac, phone, at: later.addingTimeInterval(60))
        try await noticed(mac, phone, at: later.addingTimeInterval(day + 120))
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
        for offset in [0.0, 60, 120] { try await noticed(mac, phone, at: now.addingTimeInterval(offset)) }
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "never listed while the Trash here names it")
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day))
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
        try await noticed(mac, phone, at: now.addingTimeInterval(3 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try FileManager.default.removeItem(at: damaged)
        let later = now.addingTimeInterval(3 * day + 60)
        try await pass(mac, "Mac", at: later); try await noticed(mac, phone, at: later.addingTimeInterval(60))
        try await noticed(mac, phone, at: later.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A conversation in the library that can't be read (the library left it out) may name anything too: on the Mac,
    /// nothing is free; on the iPhone, it acknowledges nothing.
    func testBehaviorAConversationHereThatCantBeReadHoldsEverything() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let damaged = local("Phone").appendingPathComponent("Meetings/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: damaged.appendingPathComponent("meeting.json"))
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        let presence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        XCTAssertNil(presence["superseded"], "the iPhone can't say what it holds")
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try FileManager.default.removeItem(at: damaged)
        let onMac = local("Mac").appendingPathComponent("Meetings/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: onMac, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: onMac.appendingPathComponent("meeting.json"))
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 120))
        let state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
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
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// A hold is kept while the device names the object, listed or not, so the notice doesn't list and withdraw it in turn.
    func testBehaviorAHoldDoesntComeAndGo() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let copy = try await phoneStore.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Same file"), source: .imported)
        // In the iPhone's Trash only, so the journal and the Mac's library don't name it: only the hold keeps it.
        _ = try await phoneStore.moveToTrash(copy.id)
        let now = Date()
        try await noticed(mac, phone, at: now)
        let sequence = try XCTUnwrap(try notice()?.sequence)
        for offset in 1...6 { try await noticed(mac, phone, at: now.addingTimeInterval(Double(offset) * 60)) }
        XCTAssertEqual(try notice()?.sequence, sequence, "listed no more, and not listed again")
        XCTAssertEqual(try notice()?.objects, [])
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day))
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
        let now = Date()
        try await noticed(mac, phone, at: now)
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day))
        XCTAssertTrue(exists(blob(meeting.tracks[0].sha256)))
    }

    func testBehaviorAnObjectWrittenAgainDuringTheWaitStartsItAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        // Someone's upload of it, the same bytes under a new file.
        try rewrite(object)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(object), "its wait started again when it was written")
        try await noticed(mac, phone, at: now.addingTimeInterval(2 * day + 120))
        XCTAssertFalse(exists(object))
    }

    /// An object that stopped being free and is listed again is at a new sequence: every acknowledgement must come again.
    func testBehaviorAnObjectListedAgainNeedsEveryAcknowledgementAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        cloud.setUploaded(blob(compressed.copy), false)
        try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        var state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
        cloud.setUploaded(blob(compressed.copy), true)
        // Listed again; the iPhone's acknowledgement is of a sequence before, its presence fresh.
        try await pass(mac, "Mac", at: now.addingTimeInterval(120))
        state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 600))
        try editPresence("Phone") { record in
            guard var acks = record["superseded"] as? [[String: Any]] else { return }
            for index in acks.indices { acks[index]["through"] = 1 }
            record["superseded"] = acks
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(2 * day))
        try await pass(mac, "Mac", at: now.addingTimeInterval(4 * day))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await noticed(mac, phone, at: now.addingTimeInterval(4 * day + 60))
        try await noticed(mac, phone, at: now.addingTimeInterval(5 * day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
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
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let copy = try await phoneStore.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Same file"), source: .imported)
        XCTAssertEqual(copy.tracks[0].sha256, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(60))
        let file = local("Phone").appendingPathComponent("Meetings/\(copy.id.uuidString)/\(copy.tracks[0].relativePath)")
        // However tight its budget (a new engine, as after a relaunch), its file stays: the object may go.
        let tight = try self.phone("Phone", budget: 1)
        let report = try await tight.evictAudio()
        XCTAssertTrue(report.evicted.isEmpty)
        XCTAssertTrue(exists(file))
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(object))
        let state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256])
        XCTAssertEqual(try notice()?.objects, [])
        for offset in [2.0, 3, 4] { try await noticed(mac, phone, at: now.addingTimeInterval(offset * day)) }
        XCTAssertTrue(exists(object))
    }

    /// The same, made just after the iPhone's fresh presence, so the Mac deletes the object on what it last saw (the
    /// iPhone's new entry and presence not arrived yet): the iPhone, holding the bytes, uploads it again once it sees it's
    /// gone, and says so; the Mac then applies the new conversation with its recording, and lists the object no more.
    func testBehaviorADeletionOnAStaleViewIsRepairedByTheDeviceHoldingTheBytes() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30))
        let freshPresence = try Data(contentsOf: presenceURL("Phone"))
        let events = Set(files("Events"))
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        let copy = try await phoneStore.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Same file"), source: .imported)
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 40))
        // What the iPhone wrote since hasn't reached the Mac: its entry, and its presence holding the object.
        let holding = try Data(contentsOf: presenceURL("Phone"))
        let arrived = Set(files("Events")).subtracting(events)
        XCTAssertFalse(arrived.isEmpty)
        let aside = root.appendingPathComponent("aside", isDirectory: true)
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        for name in arrived { try FileManager.default.moveItem(at: remote.appendingPathComponent("Events/\(name)"), to: aside.appendingPathComponent(name)) }
        try freshPresence.write(to: presenceURL("Phone"))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object), "deleted on a stale view")
        // It arrives.
        for name in arrived { try FileManager.default.moveItem(at: aside.appendingPathComponent(name), to: remote.appendingPathComponent("Events/\(name)")) }
        try holding.write(to: presenceURL("Phone"))
        let result = try await pass(phone, "Phone", at: now.addingTimeInterval(day + 90))
        XCTAssertTrue(exists(object), "the iPhone holding the bytes uploaded them again")
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix(SyncWarningWords.deletedOriginalNeeded) })
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 120))
        let applied = try await MeetingStore(rootURL: local("Mac")).list()
        XCTAssertTrue(applied.contains { $0.id == copy.id }, "the Mac applies the new conversation with its recording")
        let installed = local("Mac").appendingPathComponent("Meetings/\(copy.id.uuidString)/\(copy.tracks[0].relativePath)")
        XCTAssertTrue(exists(installed))
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
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        var reference = Meeting(title: "By reference")
        var track = compressed.original
        track.id = UUID()
        reference.tracks = [track]
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        try await phoneStore.save(reference)
        let events = Set(files("Events"))
        try await pass(phone, "Phone", at: now.addingTimeInterval(30))
        XCTAssertEqual(Set(files("Events")), events, "not published while the notice lists it")
        try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        XCTAssertEqual(try notice()?.objects, [], "the iPhone holds it: listed no more")
        try await pass(phone, "Phone", at: now.addingTimeInterval(90))
        XCTAssertNotEqual(Set(files("Events")), events, "published by reference once nothing lists it")
        for offset in [1.0, 2, 3] { try await noticed(mac, phone, at: now.addingTimeInterval(offset * day + 60)) }
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// The race the notice can't close: an entry naming the object reaches the Mac only after it deleted it. A Mac still
    /// holding the original as a file (not let go yet) uploads it again; one that doesn't says the original is needed,
    /// applies the conversation without its audio rather than waiting for it, and can still publish edits to it.
    func testBehaviorAReferenceArrivingAfterTheDeletionIsUploadedFromAnOriginalStillHereOrWarned() async throws {
        for keepsOriginal in [true, false] {
            root = makeTemporaryFolder("DaybookSupersededTests")
            cloud = SimulatedICloud()
            macs = [:]; lastPass = [:]
            let mac = try mac(), phone = try phone()
            let compressed = try await recordedAndCompressed(mac, phone)
            let object = blob(compressed.original.sha256)
            try await acknowledged(mac, phone)
            let now = try await acknowledgedSince(mac, compressed.original.sha256)
            let original = local("Mac").appendingPathComponent("Meetings/\(compressed.meeting.id.uuidString)/\(compressed.original.relativePath)")
            if !keepsOriginal { try FileManager.default.removeItem(at: original) }
            try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
            XCTAssertFalse(exists(object))
            // An entry naming it arrives late (written by the iPhone when it still had the bytes, say).
            let phoneStore = try MeetingStore(rootURL: local("Phone"))
            let copy = try await phoneStore.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Late"), source: .imported)
            try await pass(phone, "Phone", at: now.addingTimeInterval(day + 70))
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
            guard !keepsOriginal else { continue }
            XCTAssertEqual(result.pendingDownloads, 0, "nothing is waited for")
            let store = try MeetingStore(rootURL: local("Mac"))
            let listed = try await store.list()
            var late = try XCTUnwrap(listed.first { $0.id == copy.id }, "applied without its audio")
            late.notes = "Edited on the Mac"
            try await store.save(late)
            let edited = try await pass(mac, "Mac", at: now.addingTimeInterval(day + 180))
            XCTAssertEqual(edited.publishedEvents, 1, "its edit publishes, naming what it named")
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
        try await pass(phone, "Phone", at: now); try await pass(first, "Mac-A", at: now.addingTimeInterval(10))
        for offset in [1.0, 2, 3] {
            try await pass(later, "Mac-B", at: now.addingTimeInterval(offset * day + 60))
            let due = await later.hasSupersededObjectsDue
            XCTAssertFalse(due)
        }
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        let held = await later.supersededState()
        XCTAssertTrue(held.objects.isEmpty)
        // The Mac that compacts deletes it a day after every device, the other Mac included, acknowledged its notice and
        // wrote its presence again.
        try await pass(phone, "Phone", at: now.addingTimeInterval(3 * day + 90))
        try await pass(first, "Mac-A", at: now.addingTimeInterval(3 * day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A Mac that can't compact now (a device in use doesn't read compacted libraries) lists nothing.
    func testBehaviorAMacThatCantCompactWithdrawsItsNotice() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        XCTAssertEqual(try notice()?.objects.map(\.sha256), [compressed.original.sha256])
        // An older device appears, without `compact-1`.
        var older = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        older["deviceID"] = "Older"
        older["features"] = [String]()
        older["superseded"] = nil
        try JSONSerialization.data(withJSONObject: older).write(to: presenceURL("Older"))
        try await pass(mac, "Mac")
        XCTAssertEqual(try notice()?.objects, [])
    }

    /// A pass that can't judge what's free (part of the journal waits) still takes what another device holds out of the
    /// notice, so that device's publication by reference isn't left waiting.
    func testBehaviorAPassThatCantJudgeStillTakesWhatsHeldOutOfTheNotice() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        var reference = Meeting(title: "By reference")
        var track = compressed.original
        track.id = UUID()
        reference.tracks = [track]
        try await phoneStore.save(reference)
        // And a new recording on the iPhone whose object hasn't reached the Mac: the Mac's pass waits for it.
        let source = root.appendingPathComponent("new.wav")
        try Data(repeating: 5, count: 2_048).write(to: source)
        let fresh = try await phoneStore.importAudio(from: source, into: Meeting(title: "New"), source: .microphone)
        try await pass(phone, "Phone", at: now.addingTimeInterval(30))
        try cloud.withhold(blob(fresh.tracks[0].sha256))
        let result = try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        XCTAssertGreaterThan(result.pendingDownloads, 0)
        XCTAssertEqual(try notice()?.objects, [], "the iPhone holds it")
    }

    /// A notice whose Mac hasn't been seen in 30 days (retired, or reinstalled under a new ID) is ignored: nothing it lists
    /// is waited for, and nobody acknowledges it.
    func testBehaviorANoticeFromAMacAwayAMonthIsIgnored() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        XCTAssertEqual(try notice()?.objects.map(\.sha256), [compressed.original.sha256])
        try agePresence("Mac", days: 31)
        var reference = Meeting(title: "By reference")
        var track = compressed.original
        track.id = UUID()
        reference.tracks = [track]
        try await MeetingStore(rootURL: local("Phone")).save(reference)
        let events = Set(files("Events"))
        try await pass(phone, "Phone")
        XCTAssertNotEqual(Set(files("Events")), events, "published by reference: the notice doesn't count")
        let presence = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Phone"))) as? [String: Any])
        XCTAssertNil(presence["superseded"], "nor is it acknowledged")
    }

    /// The same for a Mac reinstalled under a new device ID: its earlier identity's notice is ignored at once.
    func testBehaviorANoticeFromAnEarlierIdentityOfAReinstalledMacIsIgnored() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        try agePresence("Mac", days: 2)
        var reinstalled = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: presenceURL("Mac"))) as? [String: Any])
        let formatter = ISO8601DateFormatter()
        reinstalled["deviceID"] = "Mac reinstalled"
        reinstalled["firstSeen"] = formatter.string(from: Date().addingTimeInterval(-day))
        reinstalled["lastSeen"] = formatter.string(from: Date())
        reinstalled["superseded"] = nil
        try JSONSerialization.data(withJSONObject: reinstalled).write(to: presenceURL("Mac reinstalled"))
        var reference = Meeting(title: "By reference")
        var track = compressed.original
        track.id = UUID()
        reference.tracks = [track]
        try await MeetingStore(rootURL: local("Phone")).save(reference)
        let events = Set(files("Events"))
        try await pass(phone, "Phone")
        XCTAssertNotEqual(Set(files("Events")), events, "published by reference: the earlier identity's notice doesn't count")
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

    /// A library encrypted while its notice lists an object: the notice lists nothing from then on (its log stays).
    func testBehaviorALibraryEncryptedWhileSomethingIsListedWithdrawsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        XCTAssertEqual(try notice()?.objects.map(\.sha256), [compressed.original.sha256])
        try await mac.enableSealing()
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        XCTAssertEqual(try notice()?.objects, [])
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    // MARK: The clock

    /// A wall clock that jumps (2 days on while the continuous clock moved a minute) starts every wait again, and so does
    /// a restart.
    func testBehaviorAClockThatJumpsOrARestartStartsTheWaitAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        clockOffset = -2 * day + 60
        let jumped = now.addingTimeInterval(2 * day)
        try await noticed(mac, phone, at: jumped, watched: false)
        XCTAssertTrue(exists(object))
        var state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, jumped)
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, jumped)
        // A restart an hour later: started again too.
        boot = "boot-2"
        let restarted = jumped.addingTimeInterval(3600)
        try await noticed(mac, phone, at: restarted, watched: false)
        XCTAssertTrue(exists(object))
        state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, restarted)
        // Within the boot, a day by both clocks: gone.
        try await noticed(mac, phone, at: restarted.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
    }

    /// A gap of more than twelve hours between checks (asleep, off) isn't a time watched, and starts nothing again; after
    /// it, every device must be seen acknowledging again on a later check than the one this Mac woke to.
    func testBehaviorAGapInTheChecksIsntWatchedAndEveryDeviceIsSeenAgainAfterIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        var state = await mac.supersededState()
        let since = try XCTUnwrap(state.objects[compressed.original.sha256]?.since)
        // A minute short of a day watched, then asleep for thirteen hours while the iPhone acknowledges again.
        try await noticed(mac, phone, at: now.addingTimeInterval(day - 60))
        let watched = await mac.supersededState().watched
        let woke = now.addingTimeInterval(day - 60 + 13 * 3600)
        try await pass(phone, "Phone", at: woke.addingTimeInterval(-10), watched: false)
        try await pass(mac, "Mac", at: woke, watched: false)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        state = await mac.supersededState()
        XCTAssertEqual(state.watched, watched, "asleep isn't watched")
        XCTAssertEqual(state.wokeAt, woke)
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, since, "nothing starts again")
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, now)
        // Two minutes on, a day watched: but the iPhone was last seen on the check this Mac woke to.
        try await pass(mac, "Mac", at: woke.addingTimeInterval(120), watched: false)
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "every device is seen again after waking")
        try await noticed(mac, phone, at: woke.addingTimeInterval(180), watched: false)
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// A Mac closed every night for thirteen hours still gets there: its nights aren't counted, and nothing starts again.
    func testBehaviorAMacClosedEveryNightStillDeletes() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let start = try await acknowledgedSince(mac, compressed.original.sha256)
        // Open eleven hours a day, checking every few hours, the iPhone used meanwhile.
        var gone: Date?
        days: for day in 0..<4 {
            for hours in [0.0, 4, 8, 11] where day > 0 || hours > 0 {
                let time = start.addingTimeInterval(Double(day) * self.day + hours * 3600)
                try await noticed(mac, phone, at: time, watched: false)
                if !exists(blob(compressed.original.sha256)) { gone = time; break days }
            }
        }
        // A day watched since it was acknowledged: eleven hours on each of the first two days, then four on the third.
        XCTAssertEqual(gone, start.addingTimeInterval(2 * day + 4 * 3600))
    }

    /// A wall clock set back two days starts every wait again, and an acknowledgement this Mac saw before (dated after its
    /// clock now) doesn't pass for a new one.
    func testBehaviorAWallClockSetBackDoesntMakeAnOldAcknowledgementNew() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await noticed(mac, phone, at: now.addingTimeInterval(3600))
        // Two days back, while the continuous clock moved a minute.
        clockOffset = 2 * day
        let back = now.addingTimeInterval(3600 + 60 - 2 * day)
        try await pass(mac, "Mac", at: back, watched: false)
        var state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, back)
        // A day watched since, the iPhone not seen again.
        try await pass(mac, "Mac", at: back.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "seen at a time after this clock's now")
        state = await mac.supersededState()
        XCTAssertNotNil(state.objects[compressed.original.sha256])
        try await noticed(mac, phone, at: back.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// Within a boot, a day by the wall clock isn't enough while the continuous clock says less.
    func testBehaviorTheContinuousClockMustSayADayToo() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        clockOffset = -30 * 60
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 31 * 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    // MARK: Right before deleting

    /// What voice profiles hold keeps an original in iCloud: before the wait (the library's word before the pass, a
    /// conversation it didn't judge counting as held), and asked again under the lock right before deleting.
    func testBehaviorVoiceProfilesHoldItAndAreAskedAgainRightBeforeDeleting() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let id = compressed.meeting.id
        try await acknowledged(mac, phone)
        let start = Date()
        try await pass(mac, "Mac", at: start, heldForVoice: [id])
        var state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "held: not free")
        try await pass(mac, "Mac", at: start.addingTimeInterval(60), judged: [])
        state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty, "not judged: held")
        let now = start.addingTimeInterval(120)
        try await pass(mac, "Mac", at: now)
        try await noticed(mac, phone, at: now.addingTimeInterval(60))
        let since = try await acknowledgedSince(mac, compressed.original.sha256)
        try await pass(phone, "Phone", at: since.addingTimeInterval(day + 30))
        try await pass(mac, "Mac", at: since.addingTimeInterval(day + 60), delete: false)
        let due = await mac.hasSupersededObjectsDue
        XCTAssertTrue(due)
        let store = try MeetingStore(rootURL: local("Mac"))
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [id])
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "held when asked again")
        try await pass(mac, "Mac", at: since.addingTimeInterval(day + 120))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
    }

    /// Where the library says to stop (Never, or settings it can't read), nothing is listed; where it says to pause (its
    /// settings aren't current yet), waits go on but nothing comes due.
    func testBehaviorTheLibrarySayingPauseOrStopKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let before = await mac.supersededState()
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60), judgment: .pause)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        var state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, before.objects[compressed.original.sha256]?.since, "its wait goes on")
        XCTAssertEqual(state.objects[compressed.original.sha256]?.acknowledgedSince, now)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 90), judgment: .stop)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        XCTAssertEqual(try notice()?.objects, [], "listed no more")
        state = await mac.supersededState()
        XCTAssertTrue(state.objects.isEmpty)
        // Judged again: listed again, its wait from the start.
        let again = now.addingTimeInterval(day + 120)
        try await noticed(mac, phone, at: again)
        state = await mac.supersededState()
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, again)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// Right before deleting, this must still be the Mac that compacts, and still may delete.
    func testBehaviorAMacThatStopsCompactingBeforeTheDeletionDeletesNothing() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let store = try MeetingStore(rootURL: local("Mac"))
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30))
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60), delete: false)
        var due = await mac.hasSupersededObjectsDue
        XCTAssertTrue(due)
        // Compaction turned off meanwhile.
        await mac.setCompactionPolicy(nil)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        await mac.setCompactionPolicy(.eager)
        // Another Mac that compacts instead (its device ID comes first) seen meanwhile.
        try await pass(mac, "Mac", at: now.addingTimeInterval(day + 90), delete: false)
        due = await mac.hasSupersededObjectsDue
        XCTAssertTrue(due)
        let first = try self.mac("Aardvark", compaction: nil)
        try await single(first, "Aardvark", at: now.addingTimeInterval(day + 100), heldForVoice: [], judged: nil, delete: false)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
    }

    /// Between the pass and the deletion: an object written again, an event or a settings version that arrived, a copy
    /// whose file went, a device holding it now, or a track here naming it now keeps it; nothing awaited inside the
    /// coordinated delete lets a write slip in.
    func testBehaviorWhatChangedSinceThePassKeepsIt() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let store = try MeetingStore(rootURL: local("Mac"))
        func due(at time: Date) async throws {
            try await pass(phone, "Phone", at: time.addingTimeInterval(-10))
            try await pass(mac, "Mac", at: time, delete: false)
            let due = await mac.hasSupersededObjectsDue
            XCTAssertTrue(due)
        }
        // Written again.
        try await due(at: now.addingTimeInterval(day + 60))
        try rewrite(object)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        // Its wait starts again from the next pass.
        let later = now.addingTimeInterval(day + 120)
        try await noticed(mac, phone, at: later)
        // An event arrived.
        try await due(at: later.addingTimeInterval(day + 60))
        let stray = remote.appendingPathComponent("Events/\(String(repeating: "a", count: 64)).json")
        try Data("{}".utf8).write(to: stray)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        try FileManager.default.removeItem(at: stray)
        // A settings version arrived (a voiceprint).
        try await due(at: later.addingTimeInterval(day + 90))
        let settings = remote.appendingPathComponent("Metadata/\(String(repeating: "b", count: 64)).json")
        try Data("{}".utf8).write(to: settings)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        try FileManager.default.removeItem(at: settings)
        // The copy's file went.
        try await due(at: later.addingTimeInterval(day + 120))
        let copyFile = local("Mac").appendingPathComponent("Meetings/\(compressed.meeting.id.uuidString)/\(compressed.meeting.tracks[0].relativePath)")
        let bytes = try Data(contentsOf: copyFile)
        try FileManager.default.removeItem(at: copyFile)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        try bytes.write(to: copyFile)
        // A device's presence holding it now.
        try await due(at: later.addingTimeInterval(day + 150))
        let acknowledged = try Data(contentsOf: presenceURL("Phone"))
        try editPresence("Phone") { record in
            guard var acks = record["superseded"] as? [[String: Any]] else { return }
            for index in acks.indices { acks[index]["holds"] = [compressed.original.sha256] }
            record["superseded"] = acks
        }
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        try acknowledged.write(to: presenceURL("Phone"))
        // A device that wrote something since (its presence arrived, the entry not yet).
        try await due(at: later.addingTimeInterval(day + 165))
        let before = try Data(contentsOf: presenceURL("Phone"))
        try editPresence("Phone") { record in
            var written = record["written"] as? [String: Any] ?? [:]
            written["events"] = [String(repeating: "c", count: 64)]
            record["written"] = written
            record["lastSeen"] = ISO8601DateFormatter().string(from: later.addingTimeInterval(day + 166))
        }
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
        try before.write(to: presenceURL("Phone"))
        // A track here naming it now (the same file imported here since).
        try await due(at: later.addingTimeInterval(day + 180))
        _ = try await store.importAudio(from: root.appendingPathComponent("original-7.wav"), into: Meeting(title: "Again"), source: .imported)
        await mac.deleteSupersededObjects(meetings: try await store.list(), heldForVoice: [])
        XCTAssertTrue(exists(object))
    }

    /// A delete that fails is the report's error; the log doesn't say it went; it's tried again on a later pass.
    func testBehaviorADeleteThatFailsIsTheReportsErrorAndIsTriedAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let blobs = remote.appendingPathComponent("Blobs")
        try await pass(phone, "Phone", at: now.addingTimeInterval(day + 30))
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

    /// A delete that fails after the object went (its placeholder wouldn't go, say) keeps its log entry: it went.
    func testBehaviorADeleteThatFailsAfterTheObjectWentKeepsItsLogEntry() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        struct Stopped: Error {}
        await mac.setSupersededDeleteFault { throw Stopped() }
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
        let report = await mac.compactionReport
        XCTAssertNotNil(report?.lastError)
        XCTAssertEqual(report?.deletedSuperseded, 1)
        XCTAssertEqual(try notice()?.deleted.map(\.sha256), [compressed.original.sha256])
    }

    // MARK: What the Mac remembers

    func testBehaviorAStopAtAnyStepResumesOrRepeatsTheSameWork() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        // The app quits after the wait began: a new engine finds it remembered.
        let again = try self.mac()
        try await noticed(again, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
        // A wait remembered for an object that's gone already: nothing more to do, and nothing goes wrong.
        let libraryID = await again.libraryID
        let url = local("Mac").appendingPathComponent("Sync/superseded-\(try XCTUnwrap(libraryID).uuidString).json")
        var state = await again.supersededState()
        state.objects[compressed.original.sha256] = .init(copies: [compressed.copy], since: now.addingTimeInterval(-2 * day), sinceWatched: 0,
                                                         stamp: VerifiedAsset(digest: compressed.original.sha256, size: 1, modified: now, inode: 1), sequence: 1)
        try SyncEncoding.data(state).write(to: url)
        let result = try await noticed(again, phone, at: now.addingTimeInterval(day + 120))
        XCTAssertTrue(result.warnings.isEmpty)
        let cleared = await again.supersededState()
        XCTAssertTrue(cleared.objects.isEmpty)
    }

    /// What's remembered here lost: a new epoch begins and every wait starts again, so no acknowledgement given for the old
    /// epoch counts, whatever its sequence; the log and the sequence come back from the notice in iCloud.
    func testBehaviorWhatsRememberedLostStartsANewEpochAndKeepsTheLog() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        let object = blob(compressed.original.sha256)
        try await acknowledged(mac, phone)
        let libraryID = await mac.libraryID
        let library = try XCTUnwrap(libraryID)
        let url = local("Mac").appendingPathComponent("Sync/superseded-\(library.uuidString).json")
        let since = try await acknowledgedSince(mac, compressed.original.sha256)
        let old = try XCTUnwrap(try notice())
        try FileManager.default.removeItem(at: url)
        // A new engine (the app relaunched): its record of waits is gone. The iPhone's acknowledgement is of the old
        // epoch, through any sequence.
        let relaunched = try self.mac()
        try await pass(phone, "Phone", at: since.addingTimeInterval(60))
        try editPresence("Phone") { record in
            guard var acks = record["superseded"] as? [[String: Any]] else { return }
            for index in acks.indices { acks[index]["through"] = 1_000 }
            record["superseded"] = acks
        }
        let now = since.addingTimeInterval(120)
        try await pass(relaunched, "Mac", at: now)
        XCTAssertNotEqual(try notice()?.epoch, old.epoch)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(try notice()?.sequence), old.sequence)
        // Once the new notice is in iCloud, the old acknowledgement, through any sequence, still counts for nothing.
        try await pass(relaunched, "Mac", at: now.addingTimeInterval(30))
        var state = await relaunched.supersededState()
        XCTAssertNotNil(state.objects[compressed.original.sha256])
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince, "the old epoch's acknowledgement counts for nothing")
        try await noticed(relaunched, phone, at: now.addingTimeInterval(60))
        let acknowledged = try await acknowledgedSince(relaunched, compressed.original.sha256)
        try await noticed(relaunched, phone, at: acknowledged.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(object))
        try FileManager.default.removeItem(at: url)
        let again = try self.mac()
        try await noticed(again, phone, at: acknowledged.addingTimeInterval(day + 120))
        state = await again.supersededState()
        XCTAssertNotNil(state.deleted[compressed.original.sha256], "the log comes back from the notice")
    }

    /// No notice of its own in iCloud though one was written (what's remembered here restored, or iCloud still listing):
    /// a new epoch, so no acknowledgement of the old one counts, whatever its sequence; the log stays.
    func testBehaviorANoticeOfItsOwnMissingStartsANewEpochAndKeepsTheLog() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let libraryID = await mac.libraryID
        let url = local("Mac").appendingPathComponent("Sync/superseded-\(try XCTUnwrap(libraryID).uuidString).json")
        var state = await mac.supersededState()
        let logged = String(repeating: "d", count: 64)
        state.deleted[logged] = .init(sha256: logged, at: now, size: 1, tracks: [])
        try SyncEncoding.data(state).write(to: url)
        let old = try XCTUnwrap(try notice())
        try FileManager.default.removeItem(at: remote.appendingPathComponent("Superseded/\(SupersededRecord.fileName(for: "Mac"))"))
        try editPresence("Phone") { record in
            guard var acks = record["superseded"] as? [[String: Any]] else { return }
            for index in acks.indices { acks[index]["through"] = 1_000 }
            record["superseded"] = acks
        }
        try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        try await pass(mac, "Mac", at: now.addingTimeInterval(90))
        let renewed = try XCTUnwrap(try notice())
        XCTAssertNotEqual(renewed.epoch, old.epoch)
        XCTAssertGreaterThan(renewed.sequence, old.sequence)
        XCTAssertTrue(renewed.deleted.contains { $0.sha256 == logged }, "the log stays")
        state = await mac.supersededState()
        XCTAssertNil(state.objects[compressed.original.sha256]?.acknowledgedSince, "the old epoch's acknowledgement counts for nothing")
        XCTAssertEqual(state.objects[compressed.original.sha256]?.since, now.addingTimeInterval(60))
    }

    /// The log keeps what went for good, but each deletion's details only for 90 days; a notice that would be larger than
    /// any device reads isn't written (nothing more is listed or goes), and the pass says so.
    func testBehaviorTheLogIsTrimmedAndANoticeTooLargeIsntWritten() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let libraryID = await mac.libraryID
        let url = local("Mac").appendingPathComponent("Sync/superseded-\(try XCTUnwrap(libraryID).uuidString).json")
        let track = SupersededRecord.Deletion.Track(meetingID: UUID(), trackID: UUID(), copy: String(repeating: "e", count: 64))
        var state = await mac.supersededState()
        let old = String(repeating: "a", count: 64), recent = String(repeating: "b", count: 64)
        state.deleted[old] = .init(sha256: old, at: now.addingTimeInterval(-91 * day), size: 1, tracks: [track])
        state.deleted[recent] = .init(sha256: recent, at: now.addingTimeInterval(-89 * day), size: 1, tracks: [track])
        state.sequence += 1
        try SyncEncoding.data(state).write(to: url)
        try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        let trimmed = try XCTUnwrap(try notice())
        XCTAssertEqual(trimmed.deleted.first { $0.sha256 == old }?.tracks, [])
        XCTAssertEqual(trimmed.deleted.first { $0.sha256 == recent }?.tracks, [track])
        // Tens of thousands of deletions later.
        state = await mac.supersededState()
        for index in 0..<36_000 {
            let sha = String(format: "%064x", index + 1_000)
            state.deleted[sha] = .init(sha256: sha, at: now, size: 1, tracks: [track])
        }
        state.sequence += 1
        try SyncEncoding.data(state).write(to: url)
        let result = try await pass(mac, "Mac", at: now.addingTimeInterval(120))
        XCTAssertEqual(try notice()?.deleted.count, trimmed.deleted.count, "not written")
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix(SyncWarningWords.originalsNoticeStuck) })
        let quiet = try await pass(mac, "Mac", at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "nothing goes while it can't be written")
        XCTAssertTrue(quiet.warnings.contains { $0.hasPrefix(SyncWarningWords.originalsNoticeStuck) })
    }

    /// A notice of its own the Mac can't read (not downloaded, say) stops everything: nothing is written over it, listed,
    /// or deleted until it can be read; after an hour, or at once when it's damaged, the pass says so.
    func testBehaviorANoticeOfItsOwnItCantReadStopsEverything() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let record = remote.appendingPathComponent("Superseded/\(SupersededRecord.fileName(for: "Mac"))")
        let libraryID = await mac.libraryID
        try FileManager.default.removeItem(at: local("Mac").appendingPathComponent("Sync/superseded-\(try XCTUnwrap(libraryID).uuidString).json"))
        cloud.holdDownloads(true)
        try cloud.evict(record)
        let relaunched = try self.mac()
        var result = try await noticed(relaunched, phone, at: now.addingTimeInterval(day + 60), watched: false)
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        XCTAssertFalse(exists(record), "not written over")
        XCTAssertTrue(exists(SimulatedICloud.placeholder(record)))
        XCTAssertFalse(result.warnings.contains { $0.hasPrefix(SyncWarningWords.originalsNoticeStuck) }, "not yet")
        result = try await noticed(relaunched, phone, at: now.addingTimeInterval(day + 2 * 3600), watched: false)
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix(SyncWarningWords.originalsNoticeStuck) }, "an hour on")
        cloud.holdDownloads(false)
        try cloud.deliver(record)
        let good = try Data(contentsOf: record)
        result = try await noticed(relaunched, phone, at: now.addingTimeInterval(day + 2 * 3600 + 60))
        XCTAssertNotNil(try notice())
        XCTAssertFalse(result.warnings.contains { $0.hasPrefix(SyncWarningWords.originalsNoticeStuck) })
        // Damaged: said at once.
        try Data("{".utf8).write(to: record)
        result = try await noticed(relaunched, phone, at: now.addingTimeInterval(day + 2 * 3600 + 120))
        XCTAssertTrue(result.warnings.contains { $0.hasPrefix(SyncWarningWords.originalsNoticeStuck) })
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try good.write(to: record)
    }

    /// The Mac's record restored from a backup (the same epoch) brings back a wait the notice has since replaced: a wait
    /// the notice doesn't list at the same sequence starts again.
    func testBehaviorARecordRestoredFromABackupStartsItsWaitsAgain() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        let libraryID = await mac.libraryID
        let url = local("Mac").appendingPathComponent("Sync/superseded-\(try XCTUnwrap(libraryID).uuidString).json")
        let backup = try Data(contentsOf: url)
        // Since the backup: delisted, then listed again at a later sequence, the iPhone acknowledging that.
        cloud.setUploaded(blob(compressed.copy), false)
        try await pass(mac, "Mac", at: now.addingTimeInterval(60))
        cloud.setUploaded(blob(compressed.copy), true)
        try await pass(mac, "Mac", at: now.addingTimeInterval(120))
        try await noticed(mac, phone, at: now.addingTimeInterval(180))
        try backup.write(to: url)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertTrue(exists(blob(compressed.original.sha256)), "the restored wait isn't the notice's")
        let state = await mac.supersededState()
        XCTAssertGreaterThan(try XCTUnwrap(state.objects[compressed.original.sha256]?.since), now.addingTimeInterval(180), "started again")
    }

    // MARK: On every device

    /// The iPhone counts what a notice listed as possibly gone even on a pass that can't read that notice, after a
    /// relaunch too.
    func testBehaviorPossiblyGoneStaysWhileANoticeCantBeRead() async throws {
        let mac = try mac(), phone = try phone()
        let compressed = try await recordedAndCompressed(mac, phone)
        try await acknowledged(mac, phone)
        // The iPhone no longer has the conversation (deleted there): only the notice says the original may go.
        let phoneStore = try MeetingStore(rootURL: local("Phone"))
        _ = try await phoneStore.moveToTrash(compressed.meeting.id)
        try await pass(phone, "Phone")
        var gone = await phone.supersededRuntime.possiblyGone
        XCTAssertTrue(gone.contains(compressed.original.sha256))
        cloud.holdDownloads(true)
        try cloud.evict(remote.appendingPathComponent("Superseded/\(SupersededRecord.fileName(for: "Mac"))"))
        let relaunched = try self.phone()
        try await pass(relaunched, "Phone")
        gone = await relaunched.supersededRuntime.possiblyGone
        XCTAssertTrue(gone.contains(compressed.original.sha256), "kept from before")
        cloud.holdDownloads(false)
    }

    /// An acknowledgement holding more than presence can carry holds everything; a watermark over its limit isn't complete.
    func testBehaviorWhatPresenceCantCarryHoldsEverything() async throws {
        let phone = try phone()
        let objects = (0..<(LibrarySyncEngine.supersededHoldsLimit + 1)).map { String(format: "%064x", $0 + 1) }
        let record = SupersededRecord(deviceID: "Mac", epoch: "e", writtenAt: Date(), sequence: 3,
                                      objects: objects.map { .init(sha256: $0, sequence: 3) }, deleted: [])
        var meeting = Meeting(title: "Many")
        meeting.tracks = objects.map { RecordingTrack(relativePath: "Originals/\($0).wav", fileName: "\($0).wav", sha256: $0) }
        let acks = await phone.supersededAcksForTest(records: [record], meetings: [meeting])
        XCTAssertEqual(acks?.first?.holdsAll, true)
        XCTAssertEqual(acks?.first?.holds, [])
        // The limit counts across every notice: two that each name fewer than the limit, but more together.
        let half = Array(objects.prefix(LibrarySyncEngine.supersededHoldsLimit / 2 + 1))
        let notices = ["Mac", "Studio"].map { SupersededRecord(deviceID: $0, epoch: "e", writtenAt: Date(), sequence: 3,
                                                               objects: half.map { .init(sha256: $0, sequence: 3) }, deleted: []) }
        let both = await phone.supersededAcksForTest(records: notices, meetings: [meeting])
        XCTAssertEqual(both?.map(\.holdsAll), [true, true])
        let fewer = await phone.supersededAcksForTest(records: notices.map { var record = $0; record.objects.removeLast(2); return record },
                                                      meetings: [meeting])
        XCTAssertEqual(fewer?.map(\.holdsAll), [nil, nil])
        XCTAssertEqual(fewer?.first?.holds.count, half.count - 2)
        // A presence larger than any device reads holds everything instead.
        let source = root.appendingPathComponent("p.wav")
        try Data(repeating: 1, count: 64).write(to: source)
        _ = try await MeetingStore(rootURL: local("Phone")).importAudio(from: source, into: Meeting(title: "Walk"), source: .microphone)
        try await pass(phone, "Phone")
        let many = (0..<2_000).map { String(format: "%064x", $0 + 1) }
        await phone.publishPresenceForTest(acks: [SupersededAck(device: "Mac", epoch: "e", through: 3, holds: many)])
        let data = try Data(contentsOf: presenceURL("Phone"))
        XCTAssertLessThanOrEqual(data.count, SyncPresenceFiles.maximumBytes)
        let presence = try XCTUnwrap(SyncPresenceFiles.decode(data))
        XCTAssertEqual(presence.superseded?.first?.holdsAll, true)
        XCTAssertEqual(presence.superseded?.first?.through, 3)
        XCTAssertEqual(presence.written?.complete, false)
        let written = await phone.watermarkForTest(writes: LibrarySyncEngine.supersededWatermarkEvents + 1)
        XCTAssertEqual(written?.complete, false)
        let few = await phone.watermarkForTest(writes: 3)
        XCTAssertEqual(few?.complete, true)
        XCTAssertEqual(few?.events.count, 3)
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
        try await pass(mac, "Mac")
        XCTAssertTrue(exists(blob(compressed.original.sha256)))
        try await acknowledged(mac, phone)
        let now = try await acknowledgedSince(mac, compressed.original.sha256)
        try await noticed(mac, phone, at: now.addingTimeInterval(day + 60))
        XCTAssertFalse(exists(blob(compressed.original.sha256)))
        XCTAssertTrue(exists(file), "iCloud's object going doesn't touch a device's own files")
        report = try await phone.evictAudio()
        XCTAssertEqual(report.evicted.map(\.sha256), [compressed.original.sha256])
        XCTAssertFalse(exists(file))
    }

    /// In iCloud Drive an iPhone lets an original it recorded go back to iCloud only on iCloud's own yes for its object.
    func testBehaviorAnIPhoneLetsItsOwnRecordingGoOnlyOnICloudsOwnYes() async throws {
        let answers = UploadAnswers()
        let files = cloud.files
        let strict = SyncCloudFiles(requestDownload: files.requestDownload, isUploaded: files.isUploaded,
                                    uploadState: { url in answers.unanswered.contains(url.lastPathComponent) ? nil : files.isUploaded(url) },
                                    isICloudFolder: { _ in true })
        let phone = try LibrarySyncEngine(localRoot: local("Phone"), remoteRoot: remote, deviceID: "Phone", replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: "Pocket", canProcess: false),
            audioCache: AudioCachePolicy(budgetBytes: 1), cloud: strict, keyStore: keychain, sealsNewLibrary: false))
        let source = root.appendingPathComponent("phone.wav")
        try Data(repeating: 9, count: 4_096).write(to: source)
        let meeting = try await MeetingStore(rootURL: local("Phone")).importAudio(from: source, into: Meeting(title: "Walk"), source: .microphone)
        try await pass(phone, "Phone")
        let file = local("Phone").appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(meeting.tracks[0].relativePath)")
        answers.unanswered = [meeting.tracks[0].sha256]
        var report = try await phone.evictAudio()
        XCTAssertTrue(report.evicted.isEmpty, "iCloud can't say it has it")
        XCTAssertTrue(exists(file))
        answers.unanswered = []
        report = try await phone.evictAudio()
        XCTAssertEqual(report.evicted.map(\.sha256), [meeting.tracks[0].sha256])
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

    /// The person changes the conversation on the iPhone (a name given, say).
    private func editOnPhone(_ id: UUID, _ notes: String) async throws {
        let store = try MeetingStore(rootURL: local("Phone"))
        let listed = try await store.list()
        var meeting = try XCTUnwrap(listed.first { $0.id == id })
        meeting.notes = notes
        try await store.save(meeting)
    }

    private func agePresence(_ deviceID: String, days: Double) throws {
        try editPresence(deviceID) { $0["lastSeen"] = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-days * 86_400)) }
    }
}

extension LibrarySyncEngine {
    /// The acknowledgements this device would give for `records`, its library holding `meetings`.
    func supersededAcksForTest(records: [SupersededRecord], meetings: [Meeting]) -> [SupersededAck]? {
        supersededRuntime.records = Dictionary(records.map { ($0.deviceID, $0) }, uniquingKeysWith: { a, _ in a })
        supersededRuntime.staleWriters = []
        noteSupersededAcks(meetings)
        return supersededRuntime.acks
    }

    /// Writes this device's presence with these acknowledgements, as if its last full pass had worked them out.
    func publishPresenceForTest(acks: [SupersededAck]) {
        supersededRuntime.acks = acks
        supersededRuntime.acksAt = Date()
        try? writePresence(now: Date(), force: true)
    }

    /// The watermark this device would give having written `writes` events just now.
    func watermarkForTest(writes: Int) -> SupersededWatermark? {
        state.recentWrites = nil
        for index in 0..<writes { noteOwnWrite(String(format: "%064x", index + 1), directory: "Events") }
        supersededRuntime.records = ["Mac": SupersededRecord(deviceID: "Mac", epoch: "e", writtenAt: Date(), sequence: 1, objects: [], deleted: [])]
        supersededRuntime.staleWriters = []
        noteSupersededAcks([])
        return supersededRuntime.written
    }
}
