import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// Voice clips through the sync journal (LibrarySyncVoiceClips.swift): a conversation's clips travel as content-addressed
/// objects its events list, sealed in an encrypted library; an eager replica waits for them before the conversation
/// applies; an on-demand one publishes them by reference without ever fetching them; and an event that lists none (a
/// Daybook from before clips) still brings them. iCloud is a temporary folder (`SimulatedICloud`), iCloud Keychain a
/// `MemoryLibraryKeyStore`; the clips are synthetic bytes.
final class LibrarySyncVoiceClipTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var keychain: MemoryLibraryKeyStore!
    private var remote: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    /// Words that must never appear in the sync folder of an encrypted library.
    private let markers = ["Zanzibar", "Quokka"]

    override func setUpWithError() throws {
        root = makeTemporaryFolder("DaybookVoiceClipSyncTests")
        cloud = SimulatedICloud()
        keychain = MemoryLibraryKeyStore()
    }

    private func mac(_ name: String) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: name, canProcess: true),
            cloud: cloud.files, keyStore: keychain, sealsNewLibrary: false))
    }

    private func phone(_ name: String) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: name, canProcess: false),
            cloud: cloud.files, keyStore: keychain, sealsNewLibrary: false))
    }

    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ meetings: [Meeting] = []) async throws -> SyncResult {
        let result = try await engine.synchronize(meetings: meetings)
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        try await engine.acknowledge(result.checkpointID)
        return result
    }

    /// A conversation on `name` with a recording and a clip of its speaker's speech in its folder, as a Mac cuts one.
    private func meetingWithClip(on name: String) async throws -> (Meeting, VoiceClip, Data) {
        let store = try MeetingStore(rootURL: local(name))
        let audio = root.appendingPathComponent("\(UUID().uuidString).wav")
        try Data((0..<4_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: audio)
        var meeting = try await store.importAudio(from: audio, into: Meeting(title: "Zanzibar offsite"), source: .microphone)
        let track = try XCTUnwrap(meeting.tracks.first)
        let bytes = Data(("Quokka " + String(repeating: "speech ", count: 200)).utf8)
        let sha = AudioDigest.sha256(data: bytes)
        let source = VoiceClipSource(meetingID: meeting.id, trackID: track.id, speakerID: "run:1")
        let clip = VoiceClip(trackID: track.id, speakerID: "run:1", relativePath: VoiceClip.relativePath(for: source, sha256: sha), sha256: sha,
                             size: Int64(bytes.count), originalSHA256: track.sha256, originalFrames: 1_000, sampleRate: 16_000, channels: 1,
                             ranges: [VoiceClipRange(startFrame: 0, endFrame: 400)], createdAt: Date())
        let file = local(name).appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(clip.relativePath)")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file)
        meeting.voiceClips = [clip]
        try await store.save(meeting)
        return (meeting, clip, bytes)
    }

    private func clipFile(_ name: String, _ meeting: Meeting, _ clip: VoiceClip) -> URL {
        local(name).appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(clip.relativePath)")
    }

    private func files(_ directory: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent(directory).path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    private func assertNoPlaintext(file: StaticString = #filePath, line: UInt = #line) throws {
        guard let walker = FileManager.default.enumerator(at: remote, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            for marker in markers { XCTAssertFalse(text.contains(marker), "\(marker) in \(url.lastPathComponent)", file: file, line: line) }
        }
    }

    func testBehaviorAClipTravelsWithItsConversationSealedInAnEncryptedLibrary() async throws {
        let mac = try mac("Mac"), phone = try phone("Phone")
        try await pass(mac, "Mac")
        try await mac.enableSealing()
        let (meeting, clip, bytes) = try await meetingWithClip(on: "Mac")
        let published = try await pass(mac, "Mac", [meeting]).meetings[0]
        XCTAssertEqual(published.voiceClips, [clip])
        XCTAssertTrue(files("Blobs").isEmpty)
        XCTAssertEqual(files("Sealed/Blobs").count, 2, "the recording and its clip")
        try assertNoPlaintext()
        let uploaded = await mac.isObjectUploaded(clip.sha256)
        XCTAssertTrue(uploaded, "what letting an original go asks of the clip")
        // The iPhone applies it at once and never fetches the clip; an edit there publishes it by reference.
        let onPhone = try await pass(phone, "Phone").meetings[0]
        XCTAssertEqual(onPhone.voiceClips, [clip])
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipFile("Phone", meeting, clip).path))
        var edited = onPhone
        edited.setNotes("Typed on the phone")
        let sent = try await pass(phone, "Phone", [edited])
        XCTAssertEqual(sent.publishedEvents, 1)
        XCTAssertEqual(sent.warnings, [])
        // A new Mac opens the sealed clip and installs it before the conversation applies.
        let other = try self.mac("Other")
        let eager = try await pass(other, "Other")
        XCTAssertEqual(eager.pendingDownloads, 0)
        let arrived = try XCTUnwrap(eager.meetings.first)
        XCTAssertEqual(arrived.notes, "Typed on the phone")
        XCTAssertEqual(arrived.voiceClips, [clip])
        XCTAssertEqual(try Data(contentsOf: clipFile("Other", meeting, clip)), bytes)
        try assertNoPlaintext()
    }

    /// A clip whose object isn't there (not downloaded yet, or gone: a Daybook from before clips that seals may delete
    /// it) never holds its conversation back: an eager replica applies it without the clip, which it doesn't hold (so
    /// the source stays uncovered there), and installs it on a later pass once the object is there.
    func testBehaviorAnEagerReplicaAppliesAConversationWithoutAClipThatIsntThereAndInstallsItLater() async throws {
        let (meeting, clip, bytes) = try await meetingWithClip(on: "A")
        let a = try mac("A")
        try await pass(a, "A", [meeting])
        let blob = remote.appendingPathComponent("Blobs/\(clip.sha256)")
        XCTAssertEqual(try Data(contentsOf: blob), bytes, "one object, named by its bytes")
        try FileManager.default.removeItem(at: blob)
        let b = try mac("B")
        let applied = try await pass(b, "B")
        XCTAssertEqual(applied.pendingDownloads, 0, "nothing waits for the clip")
        XCTAssertEqual(applied.meetings.first?.voiceClips, [clip], "the conversation still names it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipFile("B", meeting, clip).path))
        try bytes.write(to: blob)
        let later = try await pass(b, "B")
        XCTAssertEqual(later.pendingDownloads, 0)
        XCTAssertEqual(try Data(contentsOf: clipFile("B", meeting, clip)), bytes, "installed once it's there")
        let history = await b.voiceClipFilesInHistory(of: meeting.id)
        XCTAssertEqual(history, [clip.relativePath])
    }

    /// A Mac that holds a clip whole puts its object back when it's gone from iCloud.
    func testBehaviorAMacHoldingAClipUploadsItAgainWhenItsObjectIsGone() async throws {
        let (meeting, clip, bytes) = try await meetingWithClip(on: "A")
        let a = try mac("A")
        try await pass(a, "A", [meeting])
        let blob = remote.appendingPathComponent("Blobs/\(clip.sha256)")
        try FileManager.default.removeItem(at: blob)
        let again = try await pass(a, "A", [meeting])
        XCTAssertEqual(again.publishedEvents, 0, "nothing changed in the conversation")
        XCTAssertEqual(try Data(contentsOf: blob), bytes)
    }

    /// The iPhone never fetches clips; one whose object is gone is left out of what it publishes, by reference or
    /// otherwise, and the conversation still publishes and applies everywhere.
    func testBehaviorTheIPhonePublishesAConversationWhoseClipObjectIsGone() async throws {
        let (meeting, clip, _) = try await meetingWithClip(on: "Mac")
        let mac = try mac("Mac"), phone = try phone("Phone")
        try await pass(mac, "Mac", [meeting])
        let phoneResult = try await pass(phone, "Phone")
        var onPhone = try XCTUnwrap(phoneResult.meetings.first)
        /// Whether the event whose notes are `notes` lists the clip among its assets.
        func listed(_ notes: String) throws -> Bool? {
            let events = try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("Events").path).filter { $0.hasSuffix(".json") }
            for name in events {
                let event = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: remote.appendingPathComponent("Events/\(name)"))) as? [String: Any])
                guard (event["snapshot"] as? [String: Any])?["notes"] as? String == notes else { continue }
                return ((event["assets"] as? [[String: Any]]) ?? []).contains { $0["sha256"] as? String == clip.sha256 }
            }
            return nil
        }
        // While the object is there, an edit lists the clip by reference.
        onPhone.setNotes("First, on the phone")
        let first = try await pass(phone, "Phone", [onPhone])
        XCTAssertEqual(first.publishedEvents, 1)
        XCTAssertEqual(try listed("First, on the phone"), true, "by reference to the object the sync folder holds")
        onPhone = first.meetings.first { $0.id == meeting.id } ?? onPhone
        try FileManager.default.removeItem(at: remote.appendingPathComponent("Blobs/\(clip.sha256)"))
        onPhone.setNotes("Typed on the phone")
        let sent = try await pass(phone, "Phone", [onPhone])
        XCTAssertEqual(sent.publishedEvents, 1)
        XCTAssertEqual(sent.warnings, [])
        XCTAssertEqual(try listed("Typed on the phone"), false, "never by reference to an object that isn't there")
        let other = try self.mac("Other")
        let arrived = try await pass(other, "Other")
        XCTAssertEqual(arrived.pendingDownloads, 0)
        XCTAssertEqual(arrived.meetings.first?.notes, "Typed on the phone")
        XCTAssertEqual(arrived.meetings.first?.voiceClips, [clip])
    }

    /// In an encrypted library too: a clip whose sealed object is gone never holds a publication or the sealer back.
    func testBehaviorAGoneClipObjectHoldsNothingBackInAnEncryptedLibrary() async throws {
        let mac = try mac("Mac"), phone = try phone("Phone")
        try await pass(mac, "Mac")
        let key = try await mac.enableSealing(recovery: RecoveryKey.generate())
        let (meeting, clip, _) = try await meetingWithClip(on: "Mac")
        try await pass(mac, "Mac", [meeting])
        let phoneResult = try await pass(phone, "Phone")
        var onPhone = try XCTUnwrap(phoneResult.meetings.first)
        // The clip's sealed object goes, and the Mac doesn't hold the clip either.
        let object = try XCTUnwrap(key.objectName(.blob, plaintextSHA256: clip.sha256))
        XCTAssertTrue(files("Sealed/Blobs").contains(object))
        try FileManager.default.removeItem(at: clipFile("Mac", meeting, clip))
        try FileManager.default.removeItem(at: remote.appendingPathComponent("Sealed/Blobs/\(object)"))
        onPhone.setNotes("Typed on the phone")
        let sent = try await pass(phone, "Phone", [onPhone])
        XCTAssertEqual(sent.publishedEvents, 1, "published, not waiting for an object that isn't coming")
        XCTAssertEqual(sent.warnings, [])
        let pulled = try await pass(mac, "Mac", [meeting])
        XCTAssertEqual(pulled.pendingDownloads, 0)
        XCTAssertEqual(pulled.meetings.first?.notes, "Typed on the phone")
        let progressValue = await mac.sealerProgress
        let progress = try XCTUnwrap(progressValue)
        XCTAssertEqual(progress.remaining, 0, "nothing left to seal: the clip isn't anywhere to seal from")
    }

    /// An event from a Daybook that keeps `voiceClips` as a key it doesn't know lists no clip assets: the clip still
    /// comes, from what the conversation names.
    func testBehaviorAnEventListingNoClipAssetsStillBringsTheClip() async throws {
        let (meeting, clip, bytes) = try await meetingWithClip(on: "A")
        let a = try mac("A")
        try await pass(a, "A", [meeting])
        let head = try XCTUnwrap(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("Events").path)
            .first { $0.hasSuffix(".json") }).dropLast(5)
        var snapshot = try XCTUnwrap(JSONSerialization.jsonObject(with: SyncEncoding.data(meeting)) as? [String: Any])
        snapshot["notes"] = "Typed on an older Mac"
        let assets = meeting.tracks.map { ["relativePath": $0.relativePath, "sha256": $0.sha256] }
        let event = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "meetingID": meeting.id.uuidString, "deviceID": "Old", "sequence": 1,
                                                                "parents": [String(head)], "snapshot": snapshot, "deleted": false, "assets": assets] as [String: Any],
                                               options: [.sortedKeys])
        try event.write(to: remote.appendingPathComponent("Events/\(SyncDigest.sha256(data: event)).json"))
        let b = try mac("B")
        let pulled = try await pass(b, "B")
        XCTAssertEqual(pulled.pendingDownloads, 0)
        XCTAssertEqual(pulled.warnings, [])
        XCTAssertEqual(pulled.meetings.first?.notes, "Typed on an older Mac")
        XCTAssertEqual(try Data(contentsOf: clipFile("B", meeting, clip)), bytes, "hydrated from the conversation's clips, not the event's list")
    }

    func testBehaviorAClipUnderAPathThatIsntItsSourcesIsRefused() async throws {
        var (meeting, clip, _) = try await meetingWithClip(on: "A")
        meeting.voiceClips?[0].relativePath = VoiceClip.relativePath(for: VoiceClipSource(meetingID: UUID(), trackID: clip.trackID, speakerID: clip.speakerID),
                                                                     sha256: clip.sha256)
        let a = try mac("A")
        let result = try await a.synchronize(meetings: [meeting])
        XCTAssertEqual(result.publishedEvents, 0, "a path that isn't the source's is never published")
        XCTAssertFalse(result.warnings.isEmpty)
        do { try await a.validateVoiceClipAssets(meeting); XCTFail("accepted it") } catch LibrarySyncError.invalidBlob { }
    }

    /// An encrypted library whose conversation's recording a Mac compressed and whose original it let go: the original's
    /// object is sealed under the first key, and a rotation follows, past the grace. Returns the superseded original's
    /// digest and the new key.
    private func rotateAfterCompressing(holding held: (UUID) -> Set<UUID>?,
                                        judging judged: (UUID) -> Set<UUID> = { [$0] }) async throws -> (original: String, key: LibraryKey) {
        let mac = try mac("Mac")
        try await pass(mac, "Mac")
        try await mac.enableSealing(recovery: RecoveryKey.generate())
        var (meeting, _, _) = try await meetingWithClip(on: "Mac")
        try await pass(mac, "Mac", [meeting])
        // The copy, here and verified (bytes stand in for AAC: sync never decodes audio), named by the track.
        let original = meeting.tracks[0]
        let copyBytes = Data((0..<3_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let digest = AudioDigest.sha256(data: copyBytes)
        let relativePath = RecordingCompression.relativePath(trackID: original.id, sha256: digest)
        let folder = local("Mac").appendingPathComponent("Meetings/\(meeting.id.uuidString)")
        try copyBytes.write(to: folder.appendingPathComponent(relativePath))
        RecordingCompression.File(relativePath: relativePath, fileName: "copy.m4a", sha256: digest, encoding: TrackEncoding(
            method: "aac-lc-64", sourceFormat: "PCM", previousSHA256: original.sha256, previousRelativePath: original.relativePath,
            previousFileName: original.fileName, encodedAt: Date())).apply(to: &meeting.tracks[0])
        try await MeetingStore(rootURL: local("Mac")).save(meeting)
        try await pass(mac, "Mac", [meeting])
        try FileManager.default.removeItem(at: folder.appendingPathComponent(original.relativePath))
        await mac.holdOriginalsInICloud(for: held(meeting.id), judged: judged(meeting.id))
        let start = Date()
        await mac.setSealerClock { start }
        let second = try await mac.rotateKey(now: start)
        try await pass(mac, "Mac", [meeting])
        await mac.setSealerClock { start.addingTimeInterval(LibrarySyncEngine.retirementGrace + 60) }
        try await pass(mac, "Mac", [meeting])
        let progressValue = await mac.sealerProgress
        let progress = try XCTUnwrap(progressValue)
        XCTAssertTrue(progress.oldKeysRetired, "\(progress)")
        return (original.sha256, second)
    }

    /// The sealer keeps a superseded original a voice profile still needs in iCloud (its conversation is among
    /// `meetingsHoldingOriginalsInICloud`, or the library hasn't said): sealed again under the new key, not retired with
    /// the old one.
    func testBehaviorASupersededOriginalAVoiceProfileNeedsStaysThroughAKeyRotation() async throws {
        let (original, key) = try await rotateAfterCompressing { [$0] }
        XCTAssertTrue(files("Sealed/Blobs").contains(try XCTUnwrap(key.objectName(.blob, plaintextSHA256: original))))
    }

    func testBehaviorASupersededOriginalIsKeptWhileTheLibraryHasntSaid() async throws {
        let (original, key) = try await rotateAfterCompressing { _ in nil }
        XCTAssertTrue(files("Sealed/Blobs").contains(try XCTUnwrap(key.objectName(.blob, plaintextSHA256: original))))
    }

    /// A conversation the library hadn't judged (one that arrives in the pass) counts as needed too.
    func testBehaviorASupersededOriginalOfAConversationTheLibraryDidntJudgeIsKept() async throws {
        let (original, key) = try await rotateAfterCompressing(holding: { _ in [] }, judging: { _ in [] })
        XCTAssertTrue(files("Sealed/Blobs").contains(try XCTUnwrap(key.objectName(.blob, plaintextSHA256: original))))
    }

    func testBehaviorASupersededOriginalNoVoiceProfileNeedsGoesWithTheOldKey() async throws {
        let (original, key) = try await rotateAfterCompressing { _ in [] }
        XCTAssertFalse(files("Sealed/Blobs").contains(try XCTUnwrap(key.objectName(.blob, plaintextSHA256: original))))
        XCTAssertEqual(files("Sealed/Blobs").count, 2, "the copy and the clip, under the new key")
    }

    /// What letting a file go on the strength of iCloud's copy asks (`isObjectUploaded`): in a sync folder in iCloud
    /// Drive, only the provider's own yes; an item it can't answer for (the container detached after the person signed
    /// out) isn't uploaded. In a folder that isn't iCloud's, a file that's there is.
    func testBehaviorInICloudDriveOnlyTheProvidersOwnYesIsUploaded() async throws {
        let (meeting, clip, _) = try await meetingWithClip(on: "Mac")
        try await pass(try mac("Mac"), "Mac", [meeting])
        func engine(_ name: String, uploadState: @escaping @Sendable (URL) -> Bool?, iCloud: Bool) throws -> LibrarySyncEngine {
            try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
                audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: name, canProcess: true),
                cloud: SyncCloudFiles(requestDownload: { _ in }, isUploaded: { FileManager.default.fileExists(atPath: $0.path) },
                                      uploadState: uploadState, isICloudFolder: { _ in iCloud }),
                keyStore: keychain, sealsNewLibrary: false))
        }
        let recording = try XCTUnwrap(meeting.tracks.first).sha256
        let detached = try engine("Detached", uploadState: { _ in nil }, iCloud: true)
        let detachedClip = await detached.isObjectUploaded(clip.sha256), detachedRecording = await detached.isObjectUploaded(recording)
        XCTAssertFalse(detachedClip, "the provider can't say: not uploaded")
        XCTAssertFalse(detachedRecording)
        let answering = try engine("Answering", uploadState: { _ in true }, iCloud: true)
        let answered = await answering.isObjectUploaded(clip.sha256)
        XCTAssertTrue(answered)
        let notYet = try engine("NotYet", uploadState: { _ in false }, iCloud: true)
        let pending = await notYet.isObjectUploaded(clip.sha256)
        XCTAssertFalse(pending)
        let elsewhere = try engine("Elsewhere", uploadState: { _ in nil }, iCloud: false)
        let there = await elsewhere.isObjectUploaded(clip.sha256)
        XCTAssertTrue(there, "a folder that isn't iCloud's: there is uploaded")
        let missing = await elsewhere.isObjectUploaded(String(repeating: "0", count: 64))
        XCTAssertFalse(missing)
    }

    func testBehaviorEveryDeviceInUseMustKeepVoiceClips() async throws {
        let mac = try mac("Mac"), phone = try phone("Phone")
        try await pass(mac, "Mac"); try await pass(phone, "Phone"); try await pass(mac, "Mac")
        let keeps = await mac.everyRecentDeviceKeepsVoiceClips()
        XCTAssertTrue(keeps)
        // The iPhone's presence as a version before clips wrote it: no `voiceclip-1`.
        let devices = remote.appendingPathComponent("Devices")
        for name in try FileManager.default.contentsOfDirectory(atPath: devices.path) {
            let url = devices.appendingPathComponent(name)
            guard var record = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
                  record["deviceID"] as? String == "Phone" else { continue }
            record["features"] = (record["features"] as? [String] ?? []).filter { $0 != LibrarySyncEngine.voiceClipFeature }
            try JSONSerialization.data(withJSONObject: record).write(to: url)
        }
        let afterOlder = await mac.everyRecentDeviceKeepsVoiceClips()
        XCTAssertFalse(afterOlder, "an older device in use: no clip is relied on")
        let later = await mac.everyRecentDeviceKeepsVoiceClips(now: Date().addingTimeInterval(31 * 86_400))
        XCTAssertTrue(later, "not once it's been away 30 days")
    }
}
