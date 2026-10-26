import XCTest
@testable import DaybookCore

/// Moving a library that synced through a chosen folder into the iCloud container. Temporary folders stand
/// in for both; `SimulatedICloud` evicts files to `.name.icloud` placeholders. No iCloud account is involved.
final class LibrarySyncMigrationTests: XCTestCase {
    private var root: URL!
    private var cloud: SimulatedICloud!
    private var folder: URL { root.appendingPathComponent("iCloud Drive/Daybook Sync", isDirectory: true) }
    private var container: URL { root.appendingPathComponent("Container/Documents/Daybook", isDirectory: true) }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("DaybookMigrationTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        cloud = SimulatedICloud()
        cloud.holdDownloads(true)
    }
    override func tearDownWithError() throws { try fm.removeItem(at: root) }

    private func engine(_ name: String, _ remote: URL) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(cloud: cloud.files))
    }
    private func migration(_ name: String, into destination: URL? = nil) throws -> LibrarySyncMigration {
        try LibrarySyncMigration(source: folder, destination: destination ?? container, localRoot: local(name), deviceID: name, cloud: cloud.files)
    }
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ meetings: [Meeting] = [], metadata: Data? = nil) async throws -> SyncResult {
        let result = try await engine.synchronize(meetings: meetings, libraryMetadata: metadata)
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        try await engine.acknowledge(result.checkpointID)
        return result
    }
    private func record(_ seed: UInt8, on name: String, title: String) async throws -> Meeting {
        let file = root.appendingPathComponent("\(UUID().uuidString).wav")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }).write(to: file)
        return try await MeetingStore(rootURL: local(name)).importAudio(from: file, into: Meeting(title: title))
    }
    private func stored(_ name: String) async throws -> [Meeting] { try await MeetingStore(rootURL: local(name)).list() }
    /// The same bytes every time, so passing it again isn't a new edit.
    private func metadata(_ folderName: String) throws -> Data {
        let folder = LibraryFolder(id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, name: folderName)
        var value = LibraryMetadata()
        value.folders = [LibraryValue(id: folder.id.uuidString, value: folder, modifiedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    /// Every file below `directory`, hidden ones included: relative path → (SHA-256, modification date).
    private func snapshot(_ directory: URL) throws -> [String: [String]] {
        var files: [String: [String]] = [:]
        let enumerator = try XCTUnwrap(fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey]))
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path.dropFirst(directory.standardizedFileURL.path.count + 1))
            files[relative] = [try AudioDigest.sha256(fileURL: url), "\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"]
        }
        return files
    }
    private func names(_ directory: String, in remote: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: remote.appendingPathComponent(directory), includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }

    func testMigrationCopiesVerifiedJournalIdempotentlyAndLeavesTheFolderUntouched() async throws {
        let mac = try engine("Mac", folder)
        let first = try await record(1, on: "Mac", title: "Design review")
        try await pass(mac, "Mac", [first], metadata: metadata("Work"))
        try await pass(mac, "Mac", try await stored("Mac") + [try await record(2, on: "Mac", title: "Standup")], metadata: metadata("Work"))
        let before = try snapshot(folder)
        XCTAssertGreaterThanOrEqual(before.keys.filter { $0.hasPrefix("Blobs/") }.count, 2)

        let outcome = try await migration("Mac").run()
        XCTAssertTrue(outcome.progress.isComplete); XCTAssertTrue(outcome.progress.journalComplete)
        XCTAssertEqual(outcome.progress.completed, outcome.progress.total)
        XCTAssertEqual(outcome.progress.total, before.count)
        XCTAssertEqual(outcome.progress.skipped, [])
        XCTAssertEqual(outcome.sourceLibraryID, outcome.destinationLibraryID)
        XCTAssertFalse(outcome.adoptedCheckpoint)
        // Byte for byte, and nothing else (no temporary files left behind).
        let copied = try snapshot(container)
        XCTAssertEqual(copied.mapValues { $0[0] }, before.mapValues { $0[0] })
        XCTAssertEqual(try snapshot(folder), before, "The chosen folder is never modified")

        // Idempotent: a fresh pass (no cache) finds everything and rewrites nothing.
        let again = try await migration("Mac").run()
        XCTAssertTrue(again.progress.isComplete); XCTAssertEqual(again.progress.completed, again.progress.total)
        XCTAssertEqual(try snapshot(container), copied)

        // Same library identity and checkpoint: the Mac carries on in the container with nothing to republish.
        let moved = try engine("Mac", container)
        let resumed = try await moved.synchronize(meetings: try await stored("Mac"), libraryMetadata: metadata("Work"))
        XCTAssertEqual(resumed.publishedEvents, 0); XCTAssertEqual(resumed.changedMeetingIDs, [])
        XCTAssertEqual(resumed.pendingDownloads, 0); XCTAssertEqual(resumed.warnings, [])
        // A Mac joining the container gets every conversation and its audio.
        let joined = try await pass(try engine("New Mac", container), "New Mac")
        XCTAssertEqual(Set(joined.meetings.map(\.title)), ["Design review", "Standup"])
        XCTAssertEqual(joined.pendingDownloads, 0)
        XCTAssertEqual(try snapshot(folder), before)
    }

    func testMigrationMergesIntoAContainerAnotherLibraryStartedWithoutRepublishing() async throws {
        // The iPhone (or another Mac) used the container first: its own library identity and conversation.
        let phone = try engine("Phone", container)
        try await pass(phone, "Phone", [try await record(9, on: "Phone", title: "Phone memo")])
        let manifest = try Data(contentsOf: container.appendingPathComponent("daybook-sync.json"))
        // This Mac synced through a folder.
        let mac = try engine("Mac", folder)
        try await pass(mac, "Mac", [try await record(1, on: "Mac", title: "Planning")], metadata: metadata("Work"))
        let before = try snapshot(folder)

        let outcome = try await migration("Mac").run()
        XCTAssertTrue(outcome.progress.isComplete)
        XCTAssertNotEqual(outcome.sourceLibraryID, outcome.destinationLibraryID)
        XCTAssertTrue(outcome.adoptedCheckpoint)
        XCTAssertEqual(try Data(contentsOf: container.appendingPathComponent("daybook-sync.json")), manifest,
                       "The container's library identity is never replaced")
        XCTAssertEqual(try snapshot(folder), before)
        // Running again never adopts over the checkpoint the engine now owns.
        let again = try await migration("Mac").run()
        XCTAssertFalse(again.adoptedCheckpoint); XCTAssertTrue(again.progress.isComplete)

        // The Mac continues from its applied history, so nothing is republished, and gets the phone's memo.
        let moved = try engine("Mac", container)
        let macPass = try await pass(moved, "Mac", try await stored("Mac"), metadata: metadata("Work"))
        XCTAssertEqual(macPass.publishedEvents, 0)
        XCTAssertEqual(Set(macPass.meetings.map(\.title)), ["Planning", "Phone memo"])
        XCTAssertEqual(macPass.warnings, [])
        // The phone gets the Mac's conversation, audio included.
        let phonePass = try await pass(phone, "Phone", try await stored("Phone"))
        XCTAssertEqual(Set(phonePass.meetings.map(\.title)), ["Planning", "Phone memo"])
        XCTAssertEqual(phonePass.pendingDownloads, 0)
    }

    func testSecondMacMergesIntoTheContainerAfterAnotherMacMovedFirst() async throws {
        let a = try engine("A", folder), b = try engine("B", folder)
        try await pass(a, "A", [try await record(1, on: "A", title: "Review")])
        try await pass(b, "B")
        let movedFirst = try await migration("A").run()
        XCTAssertTrue(movedFirst.progress.isComplete)
        // B is still on the old build: it keeps writing to the folder after A moved.
        let onlyB = try await stored("B")
        var edited = try XCTUnwrap(onlyB.first)
        edited.setNotes("Added on B before it moved")
        try await pass(b, "B", [edited])

        let outcome = try await migration("B").run()
        XCTAssertTrue(outcome.progress.isComplete); XCTAssertEqual(outcome.progress.skipped, [])
        XCTAssertEqual(outcome.sourceLibraryID, outcome.destinationLibraryID); XCTAssertFalse(outcome.adoptedCheckpoint)

        let movedA = try engine("A", container)
        let onA = try await pass(movedA, "A", try await stored("A"))
        XCTAssertEqual(onA.meetings.first?.notes, "Added on B before it moved")
        let movedB = try engine("B", container)
        let onB = try await movedB.synchronize(meetings: try await stored("B"))
        XCTAssertEqual(onB.publishedEvents, 0); XCTAssertEqual(onB.warnings, [])
    }

    func testMigrationWaitsForEvictedFilesAndResumesWithoutCopyingPlaceholders() async throws {
        let mac = try engine("Mac", folder)
        let published = try await pass(mac, "Mac", [try await record(1, on: "Mac", title: "Offsite")], metadata: metadata("Work"))
        let track = try XCTUnwrap(published.meetings.first?.tracks.first)
        // Optimize Mac Storage evicted part of the folder: an event, a metadata version, and the audio.
        let event = try XCTUnwrap(try names("Events", in: folder).first)
        let version = try XCTUnwrap(try names("Metadata", in: folder).first)
        let blob = folder.appendingPathComponent("Blobs/\(track.sha256)")
        for url in [event, version, blob] { try cloud.evict(url) }

        let migration = try migration("Mac")
        let first = try await migration.run()
        XCTAssertFalse(first.progress.journalComplete); XCTAssertEqual(first.progress.waitingJournal, 2)
        XCTAssertEqual(first.progress.waitingForDownload, 2, "This Mac's own copy of the audio is used instead of waiting")
        let requested = cloud.downloadRequests.map { $0.split(separator: "/").suffix(2).joined(separator: "/") }
        XCTAssertEqual(Set(requested), ["Events/\(event.lastPathComponent)", "Metadata/\(version.lastPathComponent)"])
        XCTAssertFalse(fm.fileExists(atPath: container.appendingPathComponent("Events/\(event.lastPathComponent)").path))
        XCTAssertEqual(try AudioDigest.sha256(fileURL: container.appendingPathComponent("Blobs/\(track.sha256)")), track.sha256)
        XCTAssertEqual(try snapshot(container).keys.filter { $0.split(separator: "/").last?.hasPrefix(".") == true }, [],
                       "No placeholders or partial copies reach the container")

        // iCloud delivers; the same migration picks up where it stopped.
        try cloud.deliver(event); try cloud.deliver(version)
        let second = try await migration.run()
        XCTAssertTrue(second.progress.journalComplete); XCTAssertTrue(second.progress.isComplete)
        XCTAssertEqual(second.progress.completed, second.progress.total)

        // A library that doesn't hold the audio waits for that download but can already switch over.
        let elsewhere = root.appendingPathComponent("Other Container", isDirectory: true)
        let stranger = try self.migration("Stranger", into: elsewhere)
        let waiting = try await stranger.run()
        XCTAssertTrue(waiting.progress.journalComplete); XCTAssertFalse(waiting.progress.isComplete)
        XCTAssertEqual(waiting.progress.waitingForDownload, 1)
        try cloud.deliver(blob)
        let delivered = try await stranger.run()
        XCTAssertTrue(delivered.progress.isComplete)
        XCTAssertEqual(try AudioDigest.sha256(fileURL: elsewhere.appendingPathComponent("Blobs/\(track.sha256)")), track.sha256)
    }

    func testMigrationNeverOverwritesTheContainerAndSkipsDamagedSourceFiles() async throws {
        let mac = try engine("Mac", folder)
        try await pass(mac, "Mac", [try await record(1, on: "Mac", title: "One")])
        try await pass(mac, "Mac", try await stored("Mac") + [try await record(2, on: "Mac", title: "Two")])
        let events = try names("Events", in: folder)
        XCTAssertGreaterThanOrEqual(events.count, 2)
        // The container already holds other bytes under one name; the folder's copy of another is damaged.
        let occupied = container.appendingPathComponent("Events/\(events[0].lastPathComponent)")
        try fm.createDirectory(at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not this event".utf8).write(to: occupied)
        try Data("damaged".utf8).write(to: events[1])

        let outcome = try await migration("Mac").run()
        XCTAssertTrue(outcome.progress.isComplete)
        XCTAssertEqual(outcome.progress.skipped.count, 2)
        XCTAssertEqual(try Data(contentsOf: occupied), Data("not this event".utf8))
        XCTAssertFalse(fm.fileExists(atPath: container.appendingPathComponent("Events/\(events[1].lastPathComponent)").path))
        XCTAssertThrowsError(try LibrarySyncMigration(source: folder, destination: folder.appendingPathComponent("Inside"),
                                                      localRoot: local("Mac"), deviceID: "Mac"))
    }

    func testMovingIntoAnEncryptedContainerSealsEverythingAsItCopies() async throws {
        // The old folder holds a plaintext library; the container, an encrypted one another device started.
        let mac = try engine("Mac", folder)
        let meeting = try await record(9, on: "Mac", title: "Zanzibar review")
        try await pass(mac, "Mac", [meeting], metadata: metadata("Quokka"))
        let keychain = MemoryLibraryKeyStore()
        let phone = try LibrarySyncEngine(localRoot: local("Phone"), remoteRoot: container, deviceID: "Phone",
                                          replica: SyncReplicaConfiguration(cloud: cloud.files, keyStore: keychain))
        try await pass(phone, "Phone")
        try await phone.enableSealing()
        let folderBefore = try snapshot(folder)

        // Without the key the move waits.
        do { _ = try await LibrarySyncMigration(source: folder, destination: container, localRoot: local("Mac"), deviceID: "Mac",
                                                cloud: cloud.files, keyStore: MemoryLibraryKeyStore()).run(); XCTFail() }
        catch LibrarySyncError.keyUnavailable {}
        let migration = try LibrarySyncMigration(source: folder, destination: container, localRoot: local("Mac"), deviceID: "Mac",
                                                 cloud: cloud.files, keyStore: keychain)
        let outcome = try await migration.run()
        XCTAssertTrue(outcome.progress.isComplete, "\(outcome.progress)")
        XCTAssertEqual(outcome.progress.skipped, [])
        XCTAssertEqual(try snapshot(folder), folderBefore, "The old folder is only read")
        // Nothing plaintext reached the container.
        for directory in ["Events", "Metadata", "Blobs"] {
            XCTAssertEqual((try? fm.contentsOfDirectory(atPath: container.appendingPathComponent(directory).path))?.filter { !$0.hasPrefix(".") } ?? [], [])
        }
        for (path, _) in try snapshot(container) {
            let text = String(decoding: try Data(contentsOf: container.appendingPathComponent(path)), as: UTF8.self)
            XCTAssertFalse(text.contains("Zanzibar") || text.contains("Quokka"), path)
        }
        // The Mac continues in the container, with its keys, publishing nothing again.
        let inContainer = try LibrarySyncEngine(localRoot: local("Mac"), remoteRoot: container, deviceID: "Mac",
                                                replica: SyncReplicaConfiguration(cloud: cloud.files, keyStore: keychain))
        let result = try await pass(inContainer, "Mac", try await stored("Mac"), metadata: metadata("Quokka"))
        XCTAssertEqual(result.warnings, []); XCTAssertEqual(result.publishedEvents, 0)
        let onPhone = try await pass(phone, "Phone")
        XCTAssertEqual(onPhone.meetings.map(\.id), [meeting.id])
        XCTAssertEqual(onPhone.pendingDownloads, 0)
    }
}
