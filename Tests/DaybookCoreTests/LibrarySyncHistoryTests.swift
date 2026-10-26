import XCTest
@testable import DaybookCore

/// Histories that branch and join: criss-cross merges, and edits from a Daybook that predates photos.
/// Independent temporary libraries and a shared temporary folder; synthetic data only.
final class LibrarySyncHistoryTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Remote") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private func engine(_ name: String) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote, deviceID: name)
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSyncHistory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    /// One pass, saved and acknowledged; returns the conversation as it is now on `name`.
    @discardableResult
    private func pass(_ engine: LibrarySyncEngine, _ name: String, _ meeting: Meeting? = nil) async throws -> SyncResult {
        let result = try await engine.synchronize(meetings: meeting.map { [$0] } ?? [])
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs { _ = try? await store.moveToTrash(id) }
        try await engine.acknowledge(result.checkpointID)
        return result
    }

    /// A pass on `name`, and the conversation it returned.
    private func merged(_ engine: LibrarySyncEngine, _ name: String, _ meeting: Meeting? = nil) async throws -> Meeting {
        let result = try await pass(engine, name, meeting)
        return try XCTUnwrap(result.meetings.first)
    }

    private func addPhoto(to meeting: inout Meeting, on name: String, seed: Int) async throws -> MeetingPhoto {
        let store = try MeetingStore(rootURL: local(name))
        let file = try SyntheticPhotos.write(SyntheticPhotos.data(.jpeg, seed: seed), named: "IMG_\(seed).JPG", in: root.appendingPathComponent("Camera-\(seed)"))
        let photo = try await store.storePhoto(from: file, in: meeting, capturedAt: Date(timeIntervalSince1970: 1_792_829_700),
                                               capturedAtSource: .camera, origin: PhotoOrigin(kind: PhotoOrigin.macKind))
        meeting.addPhoto(photo)
        try await store.save(meeting)
        return photo
    }

    /// Both devices apply the same merge, then edit again. The next merge's base is that merge, so what either
    /// removed after it stays removed and a revert to the original wording sticks.
    func testCrissCrossRemovalsAndARevertSurviveTheNextMerge() async throws {
        let a = try engine("A"), b = try engine("B")
        let original = Meeting(title: "Plan", notes: "First draft")
        try await pass(a, "A", original)
        try await pass(b, "B")

        // Offline on both: each adds a tag and a bookmark; A rewrites the notes and adds a photo.
        var onA = original
        onA.tags = ["from-a"]; onA.highlights.append(Highlight(time: 5, text: "A's moment")); onA.setNotes("Second draft")
        let photo = try await addPhoto(to: &onA, on: "A", seed: 7)
        var onB = original
        onB.tags = ["from-b"]; onB.highlights.append(Highlight(time: 9, text: "B's moment"))
        try await pass(a, "A", onA)
        let joinedOnB = try await merged(b, "B", onB)
        let joinedOnA = try await merged(a, "A", onA)
        XCTAssertEqual(joinedOnA, joinedOnB)
        XCTAssertEqual(joinedOnA.tags, ["from-a", "from-b"])
        XCTAssertEqual(joinedOnA.highlights.count, 2)
        XCTAssertEqual(joinedOnA.notes, "Second draft")

        // Each now removes what the other added; B also puts the original notes back and deletes the photo.
        var laterA = joinedOnA
        laterA.tags = ["from-a"]; laterA.highlights.removeAll { $0.text == "B's moment" }
        var laterB = joinedOnB
        laterB.tags = ["from-b"]; laterB.highlights.removeAll { $0.text == "A's moment" }
        laterB.setNotes("First draft"); laterB.removePhoto(photo.id)
        try await pass(a, "A", laterA)
        let finalB = try await merged(b, "B", laterB)
        let finalA = try await merged(a, "A", laterA)
        XCTAssertEqual(finalA, finalB)
        for merged in [finalA, finalB] {
            XCTAssertEqual(merged.tags ?? [], [], "a tag removed after the shared merge doesn't come back")
            XCTAssertTrue(merged.highlights.isEmpty, "a deleted bookmark doesn't come back")
            XCTAssertEqual(merged.notes, "First draft", "the revert to the original wording sticks")
            XCTAssertEqual(merged.photo(photo.id)?.isRemoved, true, "a deleted photo stays deleted")
            XCTAssertFalse(merged.revisions.contains { $0.field.hasPrefix("sync:") }, "nothing here conflicted")
        }
    }

    /// Three heads after a criss-cross on two devices and a third that edited the shared merge.
    func testThreeWayCrissCrossConverges() async throws {
        let a = try engine("A"), b = try engine("B"), c = try engine("C")
        let original = Meeting(title: "Plan")
        try await pass(a, "A", original)
        try await pass(b, "B"); try await pass(c, "C")
        var onA = original; onA.tags = ["a"]
        var onB = original; onB.tags = ["b"]
        try await pass(a, "A", onA)
        let joined = try await merged(b, "B", onB)
        _ = try await pass(a, "A", onA)
        _ = try await pass(c, "C")
        var laterA = joined; laterA.title = "Plan A"
        var laterB = joined; laterB.tags = ["b"]
        var laterC = joined; laterC.notes = "From C"
        try await pass(a, "A", laterA)
        // Each device supplies its library as it is now: B saved the merge of its edit with A's.
        let savedB = try await merged(b, "B", laterB)
        let resultC = try await merged(c, "C", laterC)
        let resultA = try await merged(a, "A", laterA)
        let resultB = try await merged(b, "B", savedB)
        XCTAssertEqual(resultA, resultB); XCTAssertEqual(resultB, resultC)
        XCTAssertEqual(resultA.title, "Plan A"); XCTAssertEqual(resultA.tags, ["b"]); XCTAssertEqual(resultA.notes, "From C")
        XCTAssertFalse(resultA.revisions.contains { $0.field.hasPrefix("sync:") })
    }

    /// A Mac still on a Daybook before photos edits a conversation with photos: its snapshot has no photos and its
    /// summary sections no photo IDs. Current replicas keep both.
    func testAnEditFromADaybookBeforePhotosKeepsPhotosAndSummaryPlacement() async throws {
        let a = try engine("A")
        var meeting = Meeting(title: "Whiteboard", notes: "Draft")
        let photo = try await addPhoto(to: &meeting, on: "A", seed: 3)
        let section = SummarySection(heading: "Plan", body: "On the board", photoIDs: [photo.id])
        meeting.summary = MeetingSummary(overview: "Planning", sections: [section])
        try await pass(a, "A", meeting)

        let legacy = try LegacyLibrarySyncEngine(localRoot: local("Legacy"), remoteRoot: remote, deviceID: "Legacy")
        let pulled = try await legacy.synchronize(meetings: [])
        try await legacy.acknowledge(pulled.checkpointID)
        // What the older app holds and edits: no photos, and summary sections without photo IDs.
        var older = try XCTUnwrap(pulled.meetings.first)
        older.photos = nil
        older.summary?.sections[0].photoIDs = nil
        older.setNotes("Edited on the older Mac")
        let published = try await legacy.synchronize(meetings: [older])
        XCTAssertEqual(published.publishedEvents, 1)
        try await legacy.acknowledge(published.checkpointID)

        let onA = try await merged(a, "A", meeting)
        let phone = try LibrarySyncEngine(localRoot: local("Phone"), remoteRoot: remote, deviceID: "Phone",
                                          replica: SyncReplicaConfiguration(audioPolicy: .onDemand))
        let onPhone = try await merged(phone, "Phone")
        for merged in [onA, onPhone] {
            XCTAssertEqual(merged.notes, "Edited on the older Mac")
            XCTAssertEqual(merged.photos, meeting.photos)
            XCTAssertEqual(merged.summary?.sections.first?.photoIDs, [photo.id])
        }
        // The current device's next edit carries both forward; nothing is republished just to restore them.
        let again = try await a.synchronize(meetings: [onA])
        XCTAssertEqual(again.publishedEvents, 0)
    }
}
