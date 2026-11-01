import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Saving: edits coalesce into one write per burst, a failed save is retried and never outlives its
/// conversation, and the durable flush only blocks on the conversations a caller cares about.
@MainActor
final class LibrarySavingTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookSaving")
    }

    private func open() async throws -> LibraryController {
        let library = LibraryController(rootURL: root, sync: nil)
        try await library.load()
        return library
    }

    private func file(_ name: String, _ contents: String) throws -> URL {
        let folder = root.appendingPathComponent("Incoming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// Makes a conversation's saves fail: its meeting.json is a folder. Returns how to undo it.
    private func breakSaves(of id: UUID) throws -> () throws -> Void {
        let folder = root.appendingPathComponent("Meetings/\(id.uuidString)")
        let primary = folder.appendingPathComponent("meeting.json"), held = folder.appendingPathComponent("held.json")
        try FileManager.default.moveItem(at: primary, to: held)
        try FileManager.default.createDirectory(at: primary, withIntermediateDirectories: false)
        return {
            try FileManager.default.removeItem(at: primary)
            try FileManager.default.moveItem(at: held, to: primary)
        }
    }

    func testAnUpdateChangesTheLibraryOnceAndAnUpdateThatChangesNothingNotAtAll() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Standup")
        await library.flush()
        let saves = library.savesCompleted
        let changes = ObservationCount { _ = library.meetings }
        defer { changes.cancel() }
        library.update(id) { $0.tags = ["Weekly"] }
        XCTAssertEqual(changes.count, 1, "One change for observers, its time stamp included: every view of the library redraws per change")
        library.update(id) { $0.tags = ["Weekly"]; $0.errorMessage = nil }
        XCTAssertEqual(changes.count, 1, "Nothing changed: no redraw, and no save")
        let stamped = try XCTUnwrap(library.meeting(id)?.updatedAt)
        await library.flush()
        XCTAssertEqual(library.savesCompleted - saves, 1)
        XCTAssertEqual(library.meeting(id)?.updatedAt, stamped)
    }

    func testABurstOfNoteEditsWritesOnceAndChangesTheLibraryOncePerKeystroke() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Standup")
        await library.flush()
        let before = library.savesCompleted
        let changes = ObservationCount { _ = library.meetings }
        let text = "Ship the beta on Friday"
        for count in 1...text.count { library.editNotes(id, text: String(text.prefix(count))) }
        XCTAssertEqual(changes.count, text.count, "One change per keystroke")
        changes.cancel()
        await library.flush()
        XCTAssertEqual(library.savesCompleted - before, 1, "The whole burst is one save")
        let reopened = try await open()
        XCTAssertEqual(reopened.meeting(id)?.notes, text)
        XCTAssertEqual(reopened.meeting(id)?.revisions.filter { $0.field == "notes" }.count, 1)
    }

    func testSavesHappenWithoutAFlushShortlyAfterTheEdits() async throws {
        let library = try await open()
        library.saveDelay = .milliseconds(20)
        let id = library.newMeeting(title: "Autosaved")
        library.rename(id, to: "Autosaved, renamed")
        let primary = root.appendingPathComponent("Meetings/\(id.uuidString)/meeting.json")
        try await waitUntil("the rename to be saved without a flush") {
            (try? JSONDecoder().decode(Meeting.self, from: Data(contentsOf: primary)))?.title == "Autosaved, renamed"
        }
    }

    func testAFailedSaveIsRetriedAtTheNextFlushWithoutAnotherEdit() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Capture")
        try await library.flushDurably()
        let repair = try breakSaves(of: id)
        library.update(id) { $0.notes = "Keep this" }
        do { try await library.flushDurably(); XCTFail("A failed save must stop the barrier") } catch { }
        try repair()
        try await library.flushDurably()
        let reopened = try await open()
        XCTAssertEqual(reopened.meeting(id)?.notes, "Keep this")
    }

    func testAnotherConversationsFailedSaveDoesNotStopAnImport() async throws {
        let library = try await open()
        let broken = library.newMeeting(title: "Can't be saved")
        let target = library.newMeeting(title: "Import here")
        try await library.flushDurably()
        _ = try breakSaves(of: broken)
        library.rename(broken, to: "Still can't be saved")
        await library.flush()
        let audio = try file("voice.m4a", "recorder bytes")
        await library.acquireLock()
        let ingested = try await library.ingest(audio, into: target, provenance: .file(source: .imported))
        library.releaseLock()
        XCTAssertNotNil(ingested.track)
        do { try await library.flushDurably([broken]); XCTFail("The broken conversation still counts for itself") } catch { }
        try await library.flushDurably([target])
    }

    func testAFailedSaveEndsWhenItsConversationGoesToTheTrash() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Doomed")
        let other = library.newMeeting(title: "Healthy")
        try await library.flushDurably()
        _ = try breakSaves(of: id)
        library.rename(id, to: "Doomed, renamed")
        await library.flush()
        let moved = try await library.moveToTrash(id)
        XCTAssertTrue(moved)
        try await library.flushDurably()
        library.rename(other, to: "Healthy, renamed")
        try await library.flushDurably()
    }

    func testASaveForAConversationTrashedBehindTheLibrarysBackIsMoot() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "Removed elsewhere")
        try await library.flushDurably()
        // A remote deletion moves the folder while a save is still queued for it.
        try await MeetingStore(rootURL: root).moveToTrash(id)
        library.rename(id, to: "Renamed after the move")
        try await library.flushDurably()
        XCTAssertNil(library.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Meetings/\(id.uuidString)").path))
    }

    func testFlushWaitsForSavesQueuedWhileItWaited() async throws {
        let library = try await open()
        let id = library.newMeeting(title: "First")
        let flushing = Task { await library.flush() }
        await Task.yield()
        library.rename(id, to: "Second")
        await flushing.value
        await library.flush()
        let stored = try await MeetingStore(rootURL: root).load(id)
        XCTAssertEqual(stored.title, "Second")
    }

    // MARK: Leaving the foreground

    func testBehaviorLeavingTheForegroundWritesWaitingSavesAndThenEndsItsBackgroundTime() async throws {
        let library = try await open()
        library.saveDelay = .seconds(60)
        let id = library.newMeeting(title: "Written on the way out")
        let time = FakeBackgroundTime()
        await library.flushInBackground(time).value
        XCTAssertEqual(time.begun, ["Saving the library"])
        XCTAssertEqual(time.ended, [1])
        let stored = try await MeetingStore(rootURL: root).load(id)
        XCTAssertEqual(stored.title, "Written on the way out")
    }

    func testBehaviorBackgroundTimeRunningOutEndsItThenAndNotAgainOnceTheSavesAreWritten() async throws {
        let library = try await open()
        library.saveDelay = .seconds(60)
        let id = library.newMeeting(title: "Written when the app comes back")
        let time = FakeBackgroundTime()
        let flushing = library.flushInBackground(time)
        time.expire()
        XCTAssertEqual(time.ended, [1], "Held past its time, the app would be ended instead of suspended")
        await flushing.value
        XCTAssertEqual(time.ended, [1])
        let stored = try await MeetingStore(rootURL: root).load(id)
        XCTAssertEqual(stored.title, "Written when the app comes back")
    }

    func testBehaviorWithNoBackgroundTimeLeftTheSavesAreStillWrittenAndNothingIsEnded() async throws {
        let library = try await open()
        library.saveDelay = .seconds(60)
        let id = library.newMeeting(title: "No time granted")
        let time = FakeBackgroundTime(grants: false)
        await library.flushInBackground(time).value
        XCTAssertEqual(time.ended, [])
        let stored = try await MeetingStore(rootURL: root).load(id)
        XCTAssertEqual(stored.title, "No time granted")
    }
}

/// Background time that's granted (or not) at once and runs out when a test says so.
@MainActor
private final class FakeBackgroundTime: BackgroundTime {
    private let grants: Bool
    private var next = 1
    private var expirations: [Int: @MainActor @Sendable () -> Void] = [:]
    private(set) var begun: [String] = []
    private(set) var ended: [Int] = []

    init(grants: Bool = true) { self.grants = grants }

    func begin(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) -> Int? {
        guard grants else { return nil }
        begun.append(name)
        defer { next += 1 }
        expirations[next] = expired
        return next
    }

    func end(_ assertion: Int) {
        ended.append(assertion)
        expirations[assertion] = nil
    }

    /// The time is up for every assertion still held.
    func expire() {
        for expired in expirations.sorted(by: { $0.key < $1.key }).map(\.value) { expired() }
    }
}
