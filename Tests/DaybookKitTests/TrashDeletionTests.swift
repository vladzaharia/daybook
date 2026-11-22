import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Delete Now and Empty Trash (`LibraryController.deleteFromTrash`), the library's one permanent deletion, in a synced
/// library: a Mac and an iPhone sharing a temporary folder that stands in for the iCloud container.
@MainActor
final class TrashDeletionTests: XCTestCase {
    private var root: URL!
    private var suites: [String: String] = [:]
    private var controllers: [LibrarySyncController] = []
    private var container: URL { root.appendingPathComponent("Container", isDirectory: true) }

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookTrashDeletion")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        for controller in controllers { controller.reportFailure("Test cleanup"); controller.disconnect() }
        controllers = []
    }

    private func library(_ name: String, phone: Bool = false, connected: Bool = true) async throws -> LibraryController {
        let libraryRoot = root.appendingPathComponent(name, isDirectory: true)
        let suite = suites[name] ?? makeTestSuite("daybook.trash.deletion.\(name)")
        suites[name] = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(name, forKey: "syncDeviceID")
        let sync = LibrarySyncController(localRoot: libraryRoot, defaults: defaults)
        controllers.append(sync)
        sync.replica = phone ? .phone(displayName: name) : .mac(displayName: name, canProcess: true)
        sync.syncDebounce = nil
        let library = LibraryController(rootURL: libraryRoot, sync: sync)
        try await library.load()
        if connected { try sync.connect(to: container, monitorChanges: false) }
        return library
    }

    @discardableResult
    private func sync(_ library: LibraryController, file: StaticString = #filePath, line: UInt = #line) async -> SyncApplied? {
        let applied = await library.synchronize()
        XCTAssertEqual(applied?.acknowledged, true, library.sync?.statusText ?? "", file: file, line: line)
        return applied
    }

    /// A conversation with a recording, on both devices.
    private func recorded(_ mac: LibraryController, _ phone: LibraryController, title: String = "Weekly sync") async throws -> UUID {
        let id = mac.newMeeting(title: title)
        let file = root.appendingPathComponent("\(UUID().uuidString).m4a")
        try Data("recording of \(title)".utf8).write(to: file)
        await mac.acquireLock()
        _ = try await mac.ingest(file, into: id, provenance: .file(source: .microphone))
        mac.releaseLock()
        await mac.flush()
        await sync(mac); await sync(phone)
        XCTAssertNotNil(phone.meeting(id))
        return id
    }

    private func folder(_ library: LibraryController, _ path: String) -> URL { library.rootURL.appendingPathComponent(path) }

    /// The deletions the shared folder's journal holds.
    private func publishedDeletions(in folder: URL? = nil) throws -> Set<UUID> {
        let events = (folder ?? container).appendingPathComponent("Events", isDirectory: true)
        var deleted = Set<UUID>()
        for name in try FileManager.default.contentsOfDirectory(atPath: events.path) where name.hasSuffix(".json") {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: events.appendingPathComponent(name))) as? [String: Any]
            if object?["deleted"] as? Bool == true, let id = (object?["meetingID"] as? String).flatMap(UUID.init(uuidString:)) { deleted.insert(id) }
        }
        return deleted
    }

    func testBehaviorADeletedConversationStaysDeletedThroughSyncPassesAndIsNotDownloadedAgain() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        let id = try await recorded(mac, phone)
        _ = try await mac.moveToTrash(id)
        await sync(mac); await sync(phone)
        XCTAssertNil(phone.meeting(id))

        let result = try await mac.deleteFromTrash([id])
        XCTAssertEqual(result.deleted, [id])
        await sync(mac); await sync(phone); await sync(mac)
        XCTAssertNil(mac.meeting(id), "it doesn't come back")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder(mac, "Meetings/\(id.uuidString)").path), "nothing is downloaded for it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder(mac, "Trash/\(id.uuidString)").path), "the ID's tombstone stays")
        XCTAssertTrue(try publishedDeletions().contains(id))
        let listed = await mac.trashedMeetings()
        XCTAssertTrue(listed.isEmpty)
    }

    func testBehaviorDeletingBeforeTheTrashSyncedGoesAtOnceAndStillReachesTheOtherDevice() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        let id = try await recorded(mac, phone)
        _ = try await mac.moveToTrash(id)
        // No pass in between: the deletion hasn't left this Mac.
        let result = try await mac.deleteFromTrash([id])
        XCTAssertEqual(result.deleted, [id], "nothing waits for sync")
        await sync(mac); await sync(phone)
        XCTAssertTrue(try publishedDeletions().contains(id), "the tombstone is published from what the Trash keeps")
        XCTAssertNil(phone.meeting(id), "and the other device deletes it")
        XCTAssertTrue(phone.trashedMeetingIDs().contains(id))
    }

    func testBehaviorWithSyncOffItGoesAtOnceAndTheDeletionReachesSyncOnceItsOn() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        let id = try await recorded(mac, phone)
        mac.sync?.disconnect()
        _ = try await mac.moveToTrash(id)
        let result = try await mac.deleteFromTrash([id])
        XCTAssertEqual(result.deleted, [id], "sync being off holds nothing back")
        try mac.sync?.connect(to: container, monitorChanges: false)
        await sync(mac); await sync(phone); await sync(mac)
        XCTAssertNil(phone.meeting(id))
        XCTAssertNil(mac.meeting(id))
    }

    func testBehaviorANewJournalStillLearnsADeletionMadeForGoodBeforeIt() async throws {
        let mac = try await library("Mac"), phone = try await library("Phone", phone: true)
        let id = try await recorded(mac, phone)
        _ = try await mac.moveToTrash(id)
        await sync(mac)
        _ = try await mac.deleteFromTrash([id])
        // A new library in iCloud (Start Over, or another library replacing this one) starts from no checkpoint.
        mac.sync?.disconnect()
        let fresh = root.appendingPathComponent("Fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: fresh, withIntermediateDirectories: true)
        try mac.sync?.connect(to: fresh, monitorChanges: false)
        await sync(mac)
        XCTAssertTrue(try publishedDeletions(in: fresh).contains(id), "the deletion reaches the new journal from the Trash's tombstone")
        XCTAssertNil(mac.meeting(id))
    }

    func testBehaviorAConversationDeletedForGoodIsNeverAddedBack() async throws {
        let mac = try await library("Mac", connected: false)
        let id = mac.newMeeting(title: "Gone")
        await mac.flush()
        _ = try await mac.moveToTrash(id)
        _ = try await mac.deleteFromTrash([id])
        // A recording into it that was left behind (an iPhone's leftover, a Mac's staging) comes back as `add`.
        mac.add(Meeting(id: id, title: "Recovered"))
        await mac.flush()
        XCTAssertNil(mac.meeting(id))
        let reopened = LibraryController(rootURL: mac.rootURL, sync: nil)
        try await reopened.load()
        XCTAssertNil(reopened.meeting(id))
        await XCTAssertThrowsErrorAsync(try await reopened.restoreFromTrash(id))
        let hasTrash = await reopened.hasTrashedMeetings()
        XCTAssertFalse(hasTrash)
        XCTAssertTrue(reopened.trashedMeetingIDs().isEmpty)
        XCTAssertEqual(reopened.deletedMeetingIDs(), [id], "still a deletion, for sync")
    }

    // MARK: Stopped partway, and what can't go

    func testBehaviorADeletionAQuitStoppedPartwayFinishesWhenTheLibraryOpens() async throws {
        let library = try await library("Mac", connected: false)
        let stopped = library.newMeeting(title: "Stopped"), hidden = library.newMeeting(title: "Hidden away")
        await library.flush()
        _ = try await library.moveToTrash(stopped)
        _ = try await library.moveToTrash(hidden)
        let trash = folder(library, "Trash")
        // Its tombstone was written, and the quit came before its files went.
        let folder = trash.appendingPathComponent(stopped.uuidString)
        let meeting = try XCTUnwrap(MeetingStore.readableTrashedMeeting(stopped, in: folder))
        try JSONEncoder().encode(TrashTombstone(meeting)).write(to: folder.appendingPathComponent(TrashTombstone.fileName))
        try Data("audio".utf8).write(to: folder.appendingPathComponent("Originals.m4a"))
        // And another's files had moved aside, not yet removed.
        let aside = trash.appendingPathComponent(".deleting-\(hidden.uuidString)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: aside.appendingPathComponent("left.m4a"))

        let listedBefore = await library.trashedMeetings()
        XCTAssertEqual(listedBefore.map(\.id), [hidden], "a tombstone is never listed, whatever is still beside it")
        let reopened = LibraryController(rootURL: library.rootURL, sync: nil)
        try await reopened.load()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [TrashTombstone.fileName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.path))
        let listed = await reopened.trashedMeetings()
        XCTAssertEqual(listed.map(\.id), [hidden], "the one still in the Trash is untouched")
    }

    func testBehaviorEachDeletionStandsOnItsOwnAndWhatCantBeReadOrWasWrittenByANewerDaybookIsKept() async throws {
        let library = try await library("Mac", connected: false)
        let fine = library.newMeeting(title: "Fine"), locked = library.newMeeting(title: "Read-only folder")
        let newer = library.newMeeting(title: "From a newer Daybook"), torn = library.newMeeting(title: "Torn")
        await library.flush()
        for id in [fine, locked, newer, torn] { _ = try await library.moveToTrash(id) }
        let trash = folder(library, "Trash")
        // A newer Daybook's copy, and one neither of whose copies can be read.
        let newerFile = trash.appendingPathComponent("\(newer.uuidString)/meeting.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: newerFile)) as? [String: Any])
        object["schemaVersion"] = 2
        try JSONSerialization.data(withJSONObject: object).write(to: newerFile)
        try? FileManager.default.removeItem(at: trash.appendingPathComponent("\(newer.uuidString)/meeting.recovery.json"))
        for name in ["meeting.json", "meeting.recovery.json"] { try Data("{".utf8).write(to: trash.appendingPathComponent("\(torn.uuidString)/\(name)")) }
        // A folder its tombstone can't be written into.
        let lockedFolder = trash.appendingPathComponent(locked.uuidString)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedFolder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedFolder.path) }

        let listed = await library.trashedMeetings()
        XCTAssertEqual(Set(listed.map(\.id)), [fine, locked], "the Trash lists only what this version reads")
        let revision = library.revision
        let result = try await library.deleteFromTrash([fine, locked, newer, torn])
        XCTAssertEqual(result.deleted, [fine], "one that fails doesn't stop the others")
        XCTAssertEqual(Set(result.failed), [locked, newer, torn])
        XCTAssertNotEqual(library.revision, revision, "what the Trash lists is read again")
        XCTAssertEqual(LibraryWords.deletedNow(deleted: result.deleted.count, failed: result.failed.count),
                       ["Deleted 1 conversation.", "Couldn’t delete 3 conversations."])
        for id in [newer, torn] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("\(id.uuidString)/meeting.json").path), "kept as it was")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedFolder.path)
        let after = await library.trashedMeetings()
        XCTAssertEqual(after.map(\.id), [locked], "intact, and still in the Trash")
    }

    // MARK: What the Trash shows and Storage counts

    func testBehaviorStorageCountsOnlyWhatEmptyTrashFrees() async throws {
        let library = try await library("Mac", connected: false)
        let kept = library.newMeeting(title: "Kept in the Trash"), gone = library.newMeeting(title: "Deleted")
        await library.flush()
        _ = try await library.moveToTrash(kept)
        _ = try await library.moveToTrash(gone)
        let trash = folder(library, "Trash")
        try Data(repeating: 1, count: 4_000).write(to: trash.appendingPathComponent("\(kept.uuidString)/old.m4a"))
        try Data(repeating: 1, count: 9_000).write(to: trash.appendingPathComponent("\(gone.uuidString)/old.m4a"))
        _ = try await library.deleteFromTrash([gone])
        // What a newer Daybook wrote stays and isn't counted as freed.
        let unreadable = trash.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 7_000).write(to: unreadable.appendingPathComponent("new.m4a"))

        let report = LibraryStorageReport.measure(libraryRoot: library.rootURL)
        let keptFolder = try FileManager.default.contentsOfDirectory(at: trash.appendingPathComponent(kept.uuidString), includingPropertiesForKeys: [.fileSizeKey])
        let keptBytes = try keptFolder.reduce(Int64(0)) { $0 + Int64(try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
        XCTAssertEqual(report.trash, keptBytes, "the conversation the Trash lists, not a tombstone or a folder it can't read")
        XCTAssertGreaterThanOrEqual(report.audio, 11_000, "both are still on this Mac")
    }

    // MARK: The Personal lock

    func testBehaviorActingOnAConversationThePersonalLockHidesAsksToUnlockFirst() async {
        let authenticator = FakePersonalLockAuthenticator(answers: false)
        let lock = PersonalLock(defaults: makeTestDefaults("TrashDeletionTests.lock"), platform: .mac, authenticator: authenticator)
        await lock.setRequired(true)
        var personal = Meeting(title: "Session with Dr. Lee"), work = Meeting(title: "Weekly sync")
        personal.placement = .personal; work.placement = .work

        let workOnly = await lock.unlock(toActOn: [work])
        XCTAssertTrue(workOnly)
        XCTAssertEqual(authenticator.asked, 0, "nothing hidden: nothing asked")
        let refused = await lock.unlock(toActOn: [work, personal])
        XCTAssertFalse(refused, "not unlocked: Empty Trash doesn't ask its question")
        XCTAssertEqual(authenticator.asked, 1)
        XCTAssertEqual(LibraryWords.deleteNowTitle([personal], hidden: { lock.hides($0) }), "Delete this conversation now?", "never its title")
        authenticator.answers(true)
        let unlocked = await lock.unlock(toActOn: [personal])
        XCTAssertTrue(unlocked)
        XCTAssertEqual(LibraryWords.deleteNowTitle([personal], hidden: { lock.hides($0) }), "Delete “Session with Dr. Lee” now?")
    }

    // MARK: Compression

    func testBehaviorAVoiceProfilesAudioStaysProtectedAfterItsConversationIsDeletedForGood() async throws {
        let library = try await library("Mac", connected: false)
        let file = root.appendingPathComponent("taught.m4a")
        try Data("the recording a voice profile learned from".utf8).write(to: file)
        let taught = library.newMeeting(title: "Taught"), copy = library.newMeeting(title: "The same recording")
        await library.acquireLock()
        for id in [taught, copy] { _ = try await library.ingest(file, into: id, provenance: .file(source: .microphone)) }
        library.releaseLock()
        await library.flush()
        let track = try XCTUnwrap(library.meeting(taught)?.tracks.first)
        let print = Voiceprint(id: "vp", profileID: UUID(), origin: .named, vector: VoiceVector(space: "s", values: [1]), meetingID: taught,
                               speakerID: "s1", trackID: track.id, speechSeconds: 30, recordedAt: Date())
        _ = try await library.moveToTrash(taught)
        _ = try await library.deleteFromTrash([taught])

        let lineage = await library.compressionLineage()
        XCTAssertEqual(lineage.map(\.id), [taught], "the tombstone keeps what compression follows")
        XCTAssertEqual(lineage.first?.tracks.map(\.sha256), [track.sha256])
        XCTAssertTrue(lineage.first?.title.isEmpty == true, "and nothing else of it")
        let learned = RecordingCompressionPlanner.learnedFrom(library.meetings, voiceprints: [print], lineage: lineage)
        XCTAssertTrue(learned.contains(copy), "the same bytes elsewhere stay protected")
        // The Trash alone (what compression followed before) no longer leads there.
        let trashOnly = await library.trashedMeetings()
        XCTAssertFalse(RecordingCompressionPlanner.learnedFrom(library.meetings, voiceprints: [print], lineage: trashOnly).contains(copy))
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("expected an error", file: file, line: line) } catch {}
}
