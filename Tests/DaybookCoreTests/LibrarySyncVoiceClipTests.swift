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

    func testBehaviorAnEagerReplicaWaitsForAClipBeforeTheConversationApplies() async throws {
        let (meeting, clip, bytes) = try await meetingWithClip(on: "A")
        let a = try mac("A")
        try await pass(a, "A", [meeting])
        let blob = remote.appendingPathComponent("Blobs/\(clip.sha256)")
        XCTAssertEqual(try Data(contentsOf: blob), bytes, "one object, named by its bytes")
        try FileManager.default.removeItem(at: blob)
        let b = try mac("B")
        let waiting = try await b.synchronize(meetings: [])
        XCTAssertTrue(waiting.meetings.isEmpty, "the conversation waits for the clip it names")
        XCTAssertGreaterThan(waiting.pendingDownloads, 0)
        try await b.acknowledge(waiting.checkpointID)
        try bytes.write(to: blob)
        let arrived = try await pass(b, "B")
        XCTAssertEqual(arrived.pendingDownloads, 0)
        XCTAssertEqual(arrived.meetings.first?.voiceClips, [clip])
        XCTAssertEqual(try Data(contentsOf: clipFile("B", meeting, clip)), bytes)
        let history = await b.voiceClipFilesInHistory(of: meeting.id)
        XCTAssertEqual(history, [clip.relativePath])
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
