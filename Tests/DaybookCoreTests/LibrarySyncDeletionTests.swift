import XCTest
@testable import DaybookCore

/// A conversation deleted on one device while another records into it, processes it, or adds to it offline.
/// Independent temporary libraries and a shared temporary folder; synthetic audio bytes only.
final class LibrarySyncDeletionTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Remote") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private func engine(_ name: String, policy: SyncAudioPolicy = .eager) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name, replica: SyncReplicaConfiguration(audioPolicy: policy))
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSyncDeletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ meetings: [Meeting] = [], deleting: Set<UUID> = [],
                      protecting: Set<UUID> = []) async throws -> SyncResult {
        let result = try await engine.synchronize(meetings: meetings, deletedMeetingIDs: deleting, protecting: protecting)
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs where FileManager.default.fileExists(atPath: local(name).appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        try await engine.acknowledge(result.checkpointID)
        return result
    }
    private func record(_ text: String, on name: String, into meeting: Meeting) async throws -> Meeting {
        let file = root.appendingPathComponent("\(UUID().uuidString).wav")
        try Data(text.utf8).write(to: file)
        return try await MeetingStore(rootURL: local(name)).importAudio(from: file, into: meeting, source: .microphone)
    }

    func testARecordingMadeIntoAConversationDeletedElsewhereIsKeptAsANewOne() async throws {
        let mac = try engine("Mac"), phone = try engine("Phone", policy: .onDemand)
        let meeting = Meeting(title: "Standup", notes: "Agenda")
        try await pass(phone, "Phone", [meeting])
        try await pass(mac, "Mac")
        // The phone records into it while the Mac deletes it.
        try await pass(mac, "Mac", deleting: [meeting.id])
        var recording = try await record("phone audio", on: "Phone", into: meeting)
        let during = try await pass(phone, "Phone", [recording], protecting: [meeting.id])
        XCTAssertFalse(during.deletedMeetingIDs.contains(meeting.id), "nothing happens to it while it's being recorded")
        XCTAssertEqual(during.meetings.map(\.id), [meeting.id])
        recording.setNotes("Agenda\nDecided to ship")
        // Recording stopped: what it added is kept as a new conversation, with its audio.
        let after = try await pass(phone, "Phone", [recording])
        XCTAssertTrue(after.deletedMeetingIDs.contains(meeting.id))
        let kept = try XCTUnwrap(after.meetings.first)
        XCTAssertNotEqual(kept.id, meeting.id)
        XCTAssertEqual(kept.tracks, recording.tracks)
        XCTAssertEqual(kept.notes, "Agenda\nDecided to ship")
        XCTAssertTrue(kept.revisions.contains { $0.field.hasPrefix("source:kept-after-deletion") })
        XCTAssertTrue(after.warnings.contains { $0.contains("kept as a new conversation") })
        let audio = local("Phone").appendingPathComponent("Meetings/\(kept.id)/\(kept.tracks[0].relativePath)")
        XCTAssertEqual(try Data(contentsOf: audio), Data("phone audio".utf8))
        // The next pass publishes it; the Mac gets it with its audio, and the deleted one stays deleted.
        let published = try await pass(phone, "Phone", after.meetings)
        XCTAssertEqual(published.publishedEvents, 1)
        let onMac = try await pass(mac, "Mac")
        XCTAssertEqual(onMac.meetings.map(\.id), [kept.id])
        XCTAssertFalse(onMac.hasPendingTransfers)
        XCTAssertEqual(try Data(contentsOf: local("Mac").appendingPathComponent("Meetings/\(kept.id)/\(kept.tracks[0].relativePath)")),
                       Data("phone audio".utf8))
        XCTAssertTrue(onMac.deletedMeetingIDs.contains(meeting.id))
    }

    func testADeletionWhoseHistoryHasntArrivedHoldsTheConversationInsteadOfKeepingIt() async throws {
        let a = try engine("A"), b = try engine("B")
        let meeting = Meeting(title: "Retro", notes: "First notes")
        try await pass(a, "A", [meeting]); try await pass(b, "B")
        // A edits, then deletes; B gets the deletion before the edit it was made after.
        var edited = meeting; edited.setNotes("First notes\nMore from A")
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("Events").path))
        try await pass(a, "A", [edited])
        let edit = try XCTUnwrap(Set(try FileManager.default.contentsOfDirectory(atPath: remote.appendingPathComponent("Events").path)).subtracting(before).first)
        try await pass(a, "A", deleting: [meeting.id])
        let aside = root.appendingPathComponent("aside.json")
        try FileManager.default.moveItem(at: remote.appendingPathComponent("Events/\(edit)"), to: aside)
        let early = try await pass(b, "B", [meeting])
        XCTAssertFalse(early.deletedMeetingIDs.contains(meeting.id), "held until what the deletion saw is read")
        XCTAssertEqual(early.meetings.map(\.id), [meeting.id], "nothing is kept as a new conversation")
        XCTAssertGreaterThan(early.pendingDownloads, 0)
        try FileManager.default.moveItem(at: aside, to: remote.appendingPathComponent("Events/\(edit)"))
        let later = try await pass(b, "B", [meeting])
        XCTAssertTrue(later.deletedMeetingIDs.contains(meeting.id))
        XCTAssertTrue(later.meetings.isEmpty, "B added nothing the deletion didn't see")
    }

    func testTwoDevicesThatKeepTheSameDeletedConversationMakeOneNewOne() async throws {
        let a = try engine("A"), b = try engine("B"), c = try engine("C")
        let meeting = Meeting(title: "Workshop")
        try await pass(a, "A", [meeting]); try await pass(b, "B"); try await pass(c, "C")
        try await pass(a, "A", deleting: [meeting.id])
        var onB = meeting; onB.setNotes("B's idea")
        var onC = meeting; onC.setNotes("C's idea")
        let fromB = try await pass(b, "B", [onB]), fromC = try await pass(c, "C", [onC])
        XCTAssertEqual(fromB.meetings.map(\.id), fromC.meetings.map(\.id), "the same new conversation on both")
        try await pass(b, "B", fromB.meetings); try await pass(c, "C", fromC.meetings)
        let backOnB = try await pass(b, "B", fromB.meetings)
        let merged = try XCTUnwrap(backOnB.meetings.first)
        XCTAssertEqual(Set(merged.notes.components(separatedBy: "\n")), ["B's idea", "C's idea"])
    }

    func testAudioInstalledBeforeADeletionArrivesGoesToTheTrash() async throws {
        let a = try engine("A"), b = try engine("B")
        let meeting = try await record("recorded on A", on: "A", into: Meeting(title: "Interview"))
        try await pass(a, "A", [meeting])
        // B's pass installs the audio, but the app quits before saving the conversation.
        _ = try await b.synchronize(meetings: [])
        let folder = local("B").appendingPathComponent("Meetings/\(meeting.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
        try await pass(a, "A", deleting: [meeting.id])
        let restarted = try engine("B")
        let result = try await pass(restarted, "B")
        XCTAssertTrue(result.deletedMeetingIDs.contains(meeting.id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "no folder without a conversation left in the library")
        XCTAssertTrue(FileManager.default.fileExists(atPath: local("B").appendingPathComponent("Trash/\(meeting.id)").path))
        let warnings = await MeetingStore.listWarnings(at: local("B"))
        XCTAssertTrue(warnings.isEmpty, "\(warnings)")
    }
}

private extension MeetingStore {
    static func listWarnings(at root: URL) async -> [String] {
        guard let store = try? MeetingStore(rootURL: root) else { return ["unopenable"] }
        _ = try? await store.list()
        return await store.warnings
    }
}
