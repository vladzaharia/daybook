import XCTest
@testable import DaybookCore

/// The courier inbox (docs/icloud-sync.md, "Courier (CloudKit)"): files another device sent by courier are verified
/// and kept in `Sync/Inbox`, read before iCloud Drive brings the same files, pruned once it has, and never written
/// into the sync folder. A temporary folder stands in for iCloud Drive (`SimulatedICloud`); files are withheld from
/// it to play iCloud Drive lagging behind the courier. No CloudKit, account, or network is involved.
final class LibrarySyncInboxTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var remote: URL { root.appendingPathComponent("iCloud") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("DaybookInboxTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        cloud = SimulatedICloud()
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func mac(_ name: String = "Mac") throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .eager, device: SyncDeviceIdentity(deviceClass: .mac, displayName: name, canProcess: true), cloud: cloud.files))
    }
    private func phone(_ name: String = "Phone") throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(
            audioPolicy: .onDemand, device: SyncDeviceIdentity(deviceClass: .phone, displayName: name, canProcess: false), cloud: cloud.files))
    }
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ meetings: [Meeting] = []) async throws -> SyncResult {
        let result = try await engine.synchronize(meetings: meetings)
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        try await engine.acknowledge(result.checkpointID)
        return result
    }
    private func record(_ bytes: Data, on name: String, into meeting: Meeting) async throws -> Meeting {
        // Synthetic bytes; sync never decodes audio.
        let file = root.appendingPathComponent("\(UUID().uuidString).wav")
        try bytes.write(to: file)
        return try await MeetingStore(rootURL: local(name)).importAudio(from: file, into: meeting, source: .microphone)
    }
    private func audioBytes(_ count: Int, seed: UInt8) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ Int(seed)) }) }
    private func inbox(_ name: String, _ libraryID: UUID) -> URL { local(name).appendingPathComponent("Sync/Inbox/\(libraryID.uuidString)") }
    /// Everything in the sync folder, by path, so a test can tell that a receiver wrote nothing there.
    private func listing() throws -> Set<String> {
        var paths = Set<String>()
        for case let url as URL in try XCTUnwrap(fm.enumerator(at: remote, includingPropertiesForKeys: nil)) {
            paths.insert(String(url.standardizedFileURL.path.dropFirst(remote.standardizedFileURL.path.count + 1)))
        }
        return paths
    }
    /// What the courier would carry: a staged copy of each file the pass wrote, as the sender makes it.
    private func stage(_ files: [SyncJournalFile], from engine: LibrarySyncEngine) throws -> [SyncJournalFile: URL] {
        var staged: [SyncJournalFile: URL] = [:]
        for file in files {
            let url = root.appendingPathComponent("Courier/\(UUID().uuidString)")
            try engine.copyJournalFile(file, to: url)
            staged[file] = url
        }
        return staged
    }

    func testCourierDeliveryIsReadBeforeICloudDriveDeliversAndPrunedOnceItHas() async throws {
        let phone = try phone(), mac = try mac()
        try await pass(phone, "Phone")
        try await pass(mac, "Mac")
        let known = await phone.libraryID
        let libraryID = try XCTUnwrap(known)

        // The phone records; its pass writes the event and the audio object into the sync folder, and says so.
        let bytes = audioBytes(6_000, seed: 7)
        let recorded = try await record(bytes, on: "Phone", into: Meeting(title: "Standup"))
        let filed = try await pass(phone, "Phone", [recorded])
        let track = try XCTUnwrap(filed.meetings.first?.tracks.first)
        let event = try XCTUnwrap(filed.writtenFiles.first { $0.path.hasPrefix("Events/") })
        XCTAssertEqual(Set(filed.writtenFiles.map(\.path)), ["Blobs/\(track.sha256)", event.path])
        XCTAssertEqual(filed.writtenFiles.first { $0.path.hasPrefix("Blobs/") }, SyncJournalFile(path: "Blobs/\(track.sha256)", sha256: track.sha256, size: Int64(bytes.count)))
        XCTAssertTrue(filed.writtenFiles.allSatisfy(\.isContentAddressed))
        let again = try await pass(phone, "Phone", filed.meetings)
        XCTAssertEqual(again.writtenFiles, [], "Each file is reported by the pass that wrote it, once")

        // The courier is faster than iCloud Drive: the Mac's view of the sync folder doesn't have them yet.
        let staged = try stage(filed.writtenFiles, from: phone)
        for file in filed.writtenFiles { try cloud.withhold(remote.appendingPathComponent(file.path)) }
        let before = try await pass(mac, "Mac")
        XCTAssertFalse(before.meetings.contains { $0.id == recorded.id })
        let folderBefore = try listing()

        for (file, contents) in staged {
            let delivery = try await mac.receiveCourierFile(file, libraryID: libraryID, contents: contents)
            XCTAssertEqual(delivery, .stored)
            XCTAssertTrue(fm.fileExists(atPath: inbox("Mac", libraryID).appendingPathComponent(file.path).path))
        }
        let repeated = try await mac.receiveCourierFile(event, libraryID: libraryID, contents: try XCTUnwrap(staged[event]))
        XCTAssertEqual(repeated, .alreadyHave)
        let waiting = await mac.courierInboxCount()
        XCTAssertEqual(waiting, 2)
        let hasNews = await mac.hasRemoteChanges()
        XCTAssertTrue(hasNews, "A delivery is a remote change")
        XCTAssertEqual(try listing(), folderBefore, "Receiving writes nothing into the sync folder")

        // The Mac's next pass reads the delivery: the conversation applies with its audio, before iCloud Drive.
        let received = try await pass(mac, "Mac")
        let onMac = try XCTUnwrap(received.meetings.first { $0.id == recorded.id })
        XCTAssertEqual(onMac.tracks, filed.meetings.first?.tracks)
        XCTAssertEqual(received.pendingDownloads, 0); XCTAssertEqual(received.warnings, [])
        XCTAssertEqual(try Data(contentsOf: local("Mac").appendingPathComponent("Meetings/\(recorded.id.uuidString)/\(track.relativePath)")), bytes)

        // Publishing an edit on the Mac doesn't put the courier's audio into the sync folder: its recorder uploads it.
        var renamed = onMac; renamed.title = "Standup, agreed"
        let edit = try await pass(mac, "Mac", [renamed])
        XCTAssertEqual(edit.publishedEvents, 1)
        XCTAssertEqual(edit.writtenFiles.map { String($0.path.prefix(7)) }, ["Events/"])
        XCTAssertFalse(fm.fileExists(atPath: remote.appendingPathComponent("Blobs/\(track.sha256)").path))
        XCTAssertFalse(try listing().contains { $0.contains(" 2") }, "No second writer, so no conflict copies")

        // iCloud Drive catches up with the same files: the inbox is pruned, and nothing rolls back.
        for file in filed.writtenFiles { try cloud.deliver(remote.appendingPathComponent(file.path)) }
        let caughtUp = try await pass(mac, "Mac", [edit.meetings.first { $0.id == recorded.id }!])
        XCTAssertEqual(caughtUp.meetings.first { $0.id == recorded.id }?.title, "Standup, agreed")
        XCTAssertEqual(caughtUp.changedMeetingIDs, []); XCTAssertEqual(caughtUp.warnings, [])
        let left = await mac.courierInboxCount()
        XCTAssertEqual(left, 0)
        let quiet = await mac.hasRemoteChanges()
        XCTAssertFalse(quiet, "The same files arriving again through iCloud Drive aren't news")
    }

    func testCourierFilesThatAreDamagedForeignOrNotJournalFilesAreRejected() async throws {
        let phone = try phone(), mac = try mac()
        try await pass(phone, "Phone")
        try await pass(mac, "Mac")
        let known = await phone.libraryID
        let libraryID = try XCTUnwrap(known)
        let bytes = audioBytes(4_000, seed: 3)
        let filed = try await pass(phone, "Phone", [try await record(bytes, on: "Phone", into: Meeting(title: "Review"))])
        let blob = try XCTUnwrap(filed.writtenFiles.first { $0.path.hasPrefix("Blobs/") })
        let event = try XCTUnwrap(filed.writtenFiles.first { $0.path.hasPrefix("Events/") })
        let staged = try stage(filed.writtenFiles, from: phone)

        // While the sync folder holds the file downloaded, a delivery adds nothing.
        let present = try await mac.receiveCourierFile(blob, libraryID: libraryID, contents: try XCTUnwrap(staged[blob]))
        XCTAssertEqual(present, .alreadyHave)
        for file in filed.writtenFiles { try cloud.withhold(remote.appendingPathComponent(file.path)) }

        func receive(_ file: SyncJournalFile, _ contents: URL, library: UUID? = nil) async throws -> CourierDelivery {
            try await mac.receiveCourierFile(file, libraryID: library ?? libraryID, contents: contents)
        }
        func assertRejected(_ delivery: CourierDelivery, _ message: String = "", line: UInt = #line) {
            guard case .rejected = delivery else { return XCTFail("\(delivery) isn’t a rejection. \(message)", line: line) }
        }
        let damaged = root.appendingPathComponent("damaged")
        var flipped = bytes; flipped[100] ^= 0xFF
        try flipped.write(to: damaged)
        assertRejected(try await receive(blob, damaged), "Same size, different bytes")
        let short = root.appendingPathComponent("short")
        try bytes.prefix(1_000).write(to: short)
        assertRejected(try await receive(blob, short))
        assertRejected(try await receive(blob, try XCTUnwrap(staged[blob]), library: UUID()), "Another library")
        let contents = try XCTUnwrap(staged[event])
        for path in ["Devices/\(event.sha256).json", "daybook-sync.json", "Events/../Blobs/\(event.sha256)", "Blobs/\(blob.sha256)"] {
            assertRejected(try await receive(SyncJournalFile(path: path, sha256: event.sha256, size: event.size), contents), path)
        }
        let afterRejections = await mac.courierInboxCount()
        XCTAssertEqual(afterRejections, 0)
        XCTAssertFalse(fm.fileExists(atPath: inbox("Mac", libraryID).appendingPathComponent(blob.path).path))

        // A replica that hasn't seen the library's manifest keeps nothing yet.
        let newcomer = try LibrarySyncEngine(localRoot: local("New"), remoteRoot: root.appendingPathComponent("Empty"), deviceID: "New")
        let early = try await newcomer.receiveCourierFile(event, libraryID: libraryID, contents: contents)
        XCTAssertEqual(early, .waitingForLibrary)
        XCTAssertFalse(early.isSettled)

        // A delivery damaged after it was stored is discarded when read, and iCloud Drive's copy takes over.
        for file in filed.writtenFiles {
            let delivery = try await receive(file, try XCTUnwrap(staged[file]))
            XCTAssertEqual(delivery, .stored)
        }
        try flipped.write(to: inbox("Mac", libraryID).appendingPathComponent(blob.path))
        let waiting = try await mac.synchronize(meetings: [])
        XCTAssertFalse(waiting.meetings.contains { $0.id == filed.meetings.first?.id }, "Not applied without verified audio")
        XCTAssertGreaterThan(waiting.pendingDownloads, 0)
        XCTAssertFalse(fm.fileExists(atPath: inbox("Mac", libraryID).appendingPathComponent(blob.path).path))
        for file in filed.writtenFiles { try cloud.deliver(remote.appendingPathComponent(file.path)) }
        let delivered = try await pass(mac, "Mac")
        let meeting = try XCTUnwrap(delivered.meetings.first { $0.id == filed.meetings.first?.id })
        let audio = local("Mac").appendingPathComponent("Meetings/\(meeting.id.uuidString)/\(meeting.tracks[0].relativePath)")
        XCTAssertEqual(try Data(contentsOf: audio), bytes)
    }

    func testOnDemandFetchInstallsAudioFromTheInboxWithoutWaitingForICloud() async throws {
        let mac = try mac(), phone = try phone()
        let bytes = audioBytes(9_000, seed: 11)
        let published = try await pass(mac, "Mac", [try await record(bytes, on: "Mac", into: Meeting(title: "Planning"))])
        let meeting = try XCTUnwrap(published.meetings.first)
        let track = meeting.tracks[0]
        let blob = try XCTUnwrap(published.writtenFiles.first { $0.path == "Blobs/\(track.sha256)" })
        try await pass(phone, "Phone")
        let known = await phone.libraryID
        let libraryID = try XCTUnwrap(known)
        let staged = try stage([blob], from: mac)

        // iCloud has the object evicted on the phone and holds its download; the courier's copy is here.
        try cloud.evict(remote.appendingPathComponent(blob.path))
        cloud.holdDownloads(true)
        let delivery = try await phone.receiveCourierFile(blob, libraryID: libraryID, contents: try XCTUnwrap(staged[blob]))
        XCTAssertEqual(delivery, .stored)

        final class Phases: @unchecked Sendable {
            private let lock = NSLock(); private var items: [AudioFetchProgress.Phase] = []
            func append(_ phase: AudioFetchProgress.Phase) { lock.withLock { items.append(phase) } }
            var values: [AudioFetchProgress.Phase] { lock.withLock { items } }
        }
        let phases = Phases()
        let installed = try await phone.fetchAudio(for: track, in: meeting.id, options: AudioFetchOptions(pollInterval: .milliseconds(5), timeout: .seconds(2))) {
            phases.append($0.phase)
        }
        XCTAssertEqual(try Data(contentsOf: installed), bytes)
        XCTAssertFalse(phases.values.contains(.downloading)); XCTAssertFalse(phases.values.contains(.waitingForUpload))
        XCTAssertEqual(phases.values.last, .installed)
        XCTAssertEqual(phone.audioAvailability(for: meeting), [track.id: .local])
        XCTAssertTrue(cloud.downloadRequests.allSatisfy { $0.hasSuffix(blob.sha256) }, "Only a request for iCloud's own copy, for pruning")
        let cached = await phone.cachedAudio()
        XCTAssertEqual(cached.map(\.origin), [.fetched])
    }

    func testOnDemandPhotoFetchUsesTheCourierWhileICloudIsUnavailable() async throws {
        let mac = try mac(), phone = try phone()
        let store = try MeetingStore(rootURL: local("Mac"))
        var meeting = Meeting(title: "Whiteboard")
        try await store.save(meeting)
        let bytes = SyntheticPhotos.data(.jpeg)
        let source = try SyntheticPhotos.write(bytes, named: "board.jpg", in: root)
        let photo = try await store.storePhoto(from: source, in: meeting, capturedAt: Date(), capturedAtSource: .added)
        meeting.addPhoto(photo)
        try await store.save(meeting)
        let published = try await pass(mac, "Mac", [meeting])
        let blob = try XCTUnwrap(published.writtenFiles.first { $0.path == "Blobs/\(photo.sha256)" })
        try await pass(phone, "Phone")
        let known = await phone.libraryID
        let libraryID = try XCTUnwrap(known)
        let staged = try stage([blob], from: mac)
        try cloud.evict(remote.appendingPathComponent(blob.path))
        cloud.holdDownloads(true)
        let received = try await phone.receiveCourierFile(blob, libraryID: libraryID, contents: XCTUnwrap(staged[blob]))
        XCTAssertEqual(received, .stored)
        let url = try await phone.fetchPhoto(photo, in: meeting.id,
                                            options: AudioFetchOptions(pollInterval: .milliseconds(5), timeout: .seconds(2)))
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertTrue(phone.isPhotoLocal(photo, in: meeting.id))
    }
}
