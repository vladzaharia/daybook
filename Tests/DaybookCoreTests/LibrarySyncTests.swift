import XCTest
@testable import DaybookCore

final class LibrarySyncTests: XCTestCase {
    private var root: URL!
    private var remote: URL { root.appendingPathComponent("Remote") }
    private func local(_ name: String) -> URL { root.appendingPathComponent(name) }
    private func engine(_ name: String, remote: URL? = nil) throws -> LibrarySyncEngine {
        try LibrarySyncEngine(localRoot: local(name), remoteRoot: remote ?? self.remote, deviceID: name)
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func apply(_ result: SyncResult, to name: String, using engine: LibrarySyncEngine) async throws {
        let store = try MeetingStore(rootURL: local(name))
        for meeting in result.meetings { try await store.save(meeting) }
        for id in result.deletedMeetingIDs where FileManager.default.fileExists(atPath: local(name).appendingPathComponent("Meetings/\(id)").path) {
            _ = try await store.moveToTrash(id)
        }
        try await engine.acknowledge(result.checkpointID)
    }
    private func publish(_ meeting: Meeting, using engine: LibrarySyncEngine, name: String) async throws -> Meeting {
        let result = try await engine.synchronize(meetings: [meeting])
        try await apply(result, to: name, using: engine)
        return try XCTUnwrap(result.meetings.first)
    }
    private func records(_ directory: String = "Events") throws -> [[String: Any]] {
        try FileManager.default.contentsOfDirectory(at: remote.appendingPathComponent(directory), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: $0)) as? [String: Any]) }
    }
    private func writeRecord(_ object: [String: Any], directory: String = "Events") throws -> URL {
        let bytes = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let url = remote.appendingPathComponent("\(directory)/\(AudioDigest.sha256(data: bytes)).json")
        try bytes.write(to: url); return url
    }

    func testOriginalAudioSidecarsAndAllMetadataRoundTripBeforeAcknowledgement() async throws {
        let source = root.appendingPathComponent("audio.wav"), sidecar = root.appendingPathComponent("audio.highlights.json")
        let audio = Data("original immutable audio".utf8)
        try audio.write(to: source)
        try JSONEncoder().encode(HighlightSidecar(highlights: [.init(time: 7, text: "A double tap")])).write(to: sidecar)
        let storeA = try MeetingStore(rootURL: local("A"))
        var meeting = try await storeA.importAudio(from: source, into: Meeting(title: "Therapy"), source: .soundcore, sidecarURL: sidecar)
        meeting.timedNotes = [TimedNote(time: 4, text: "Private note")]
        meeting.notes = "Private note"; meeting.tags = ["personal"]; meeting.folderID = UUID(); meeting.templateID = "private-template"
        let track = meeting.tracks[0]
        meeting.transcripts = [TrackTranscript(trackID: track.id, segments: [.init(trackID: track.id, start: 1, end: 3, text: "Original speech")], processingSettings: .init(modelID: "local-model", parameters: ["quality": "accurate"]))]
        meeting.setSummary(.init(overview: "Local summary"))
        let a = try engine("A"), b = try engine("B")
        let uploaded = try await publish(meeting, using: a, name: "A")
        let pulled = try await b.synchronize(meetings: [])
        XCTAssertEqual(pulled.meetings, [uploaded]); XCTAssertFalse(pulled.hasPendingTransfers)
        let originals = local("B").appendingPathComponent("Meetings/\(meeting.id)/Originals")
        let files = try FileManager.default.contentsOfDirectory(at: originals, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try Data(contentsOf: local("B").appendingPathComponent("Meetings/\(meeting.id)/\(track.relativePath)")), audio)
        // A download hydrates originals, but does not claim metadata has been saved by the caller.
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("B").appendingPathComponent("Meetings/\(meeting.id)/meeting.json").path))
        try await apply(pulled, to: "B", using: b)
        let loaded = try await MeetingStore(rootURL: local("B")).load(meeting.id)
        XCTAssertEqual(loaded, uploaded)
    }

    func testIndependentAndConcurrentEditsConvergeWithRecoverableConflictHistory() async throws {
        let a = try engine("A"), b = try engine("B")
        let base = try await publish(Meeting(title: "Initial", notes: "Base"), using: a, name: "A")
        let initialPull = try await b.synchronize(meetings: [])
        try await apply(initialPull, to: "B", using: b)
        var left = base, right = base
        left.title = "Renamed on A"; right.setNotes("Notes on B")
        _ = try await publish(left, using: a, name: "A")
        let independent = try await b.synchronize(meetings: [right])
        XCTAssertEqual(independent.meetings[0].title, left.title)
        XCTAssertEqual(independent.meetings[0].notes, right.notes)
        XCTAssertFalse(independent.meetings[0].revisions.contains { $0.field.hasPrefix("sync:") })
        try await apply(independent, to: "B", using: b)
        let catchUp = try await a.synchronize(meetings: [left]); try await apply(catchUp, to: "A", using: a)
        left = catchUp.meetings[0]; right = independent.meetings[0]
        left.setNotes("A concurrent note"); right.setNotes("B concurrent note")
        _ = try await publish(left, using: a, name: "A")
        let mergedB = try await b.synchronize(meetings: [right]); try await apply(mergedB, to: "B", using: b)
        let mergedA = try await a.synchronize(meetings: [left]); try await apply(mergedA, to: "A", using: a)
        XCTAssertEqual(mergedA.meetings, mergedB.meetings)
        let conflict = try XCTUnwrap(mergedA.meetings[0].revisions.first { $0.field == "sync:notes" })
        XCTAssertTrue(conflict.oldValue.contains("A concurrent note")); XCTAssertTrue(conflict.newValue.contains("B concurrent note"))
        XCTAssertFalse(mergedB.warnings.isEmpty)
    }

    func testTwoDevicesThatStartedTheSameConversationKeepWhatEitherSet() async throws {
        let a = try engine("A"), b = try engine("B")
        let id = UUID(), folder = UUID()
        // The Mac named it, filed it, and took notes; the phone joined the same conversation ID and only recorded.
        var mac = Meeting(id: id, title: "Design review", notes: "Ship on Friday", folderID: folder, templateID: "custom-review")
        mac.timedNotes = [TimedNote(time: 8, text: "Ship on Friday")]
        let phone = Meeting(id: id, title: "Untitled Conversation", date: mac.date.addingTimeInterval(3), status: .imported)
        _ = try await publish(mac, using: a, name: "A")
        let fromB = try await b.synchronize(meetings: [phone]); try await apply(fromB, to: "B", using: b)
        let fromA = try await a.synchronize(meetings: [mac]); try await apply(fromA, to: "A", using: a)
        for merged in [fromA.meetings[0], fromB.meetings[0]] {
            XCTAssertEqual(merged.title, "Design review")
            XCTAssertEqual(merged.notes, "Ship on Friday")
            XCTAssertEqual(merged.timedNotes, mac.timedNotes)
            XCTAssertEqual(merged.folderID, folder)
            XCTAssertEqual(merged.templateID, "custom-review")
            XCTAssertFalse(merged.revisions.contains { $0.field.hasPrefix("sync:") })
        }
        XCTAssertEqual(fromA.meetings, fromB.meetings)
    }

    func testCrashBeforeAndAfterLocalApplyReoffersUntilAcknowledged() async throws {
        let a = try engine("A")
        let original = try await publish(Meeting(notes: "Initial"), using: a, name: "A")
        let b = try engine("B")
        let first = try await b.synchronize(meetings: [])
        // Simulate crash before local metadata writes or acknowledgement.
        let restarted = try engine("B")
        let second = try await restarted.synchronize(meetings: [])
        XCTAssertEqual(second.meetings, first.meetings)
        // Simulate metadata saved, followed by a crash before acknowledgement.
        let store = try MeetingStore(rootURL: local("B")); try await store.save(second.meetings[0])
        let restartedAgain = try engine("B")
        let third = try await restartedAgain.synchronize(meetings: [try await store.load(original.id)])
        XCTAssertEqual(third.meetings, first.meetings); XCTAssertEqual(third.publishedEvents, 0)
        do { try await restartedAgain.acknowledge(second.checkpointID); XCTFail("Accepted stale checkpoint") }
        catch LibrarySyncError.invalidCheckpoint { }
        try await apply(third, to: "B", using: restartedAgain)
        var edited = third.meetings[0]; edited.setNotes("Sequential edit after acknowledgement")
        _ = try await publish(edited, using: restartedAgain, name: "B")
        let result = try await a.synchronize(meetings: [original])
        XCTAssertEqual(result.meetings[0].notes, edited.notes)
        XCTAssertFalse(result.meetings[0].revisions.contains { $0.field == "sync:notes" })
    }

    func testUnacknowledgedPullCannotClaimRemoteEditsAsAnAncestor() async throws {
        let a = try engine("A"), b = try engine("B")
        let base = try await publish(Meeting(notes: "Base"), using: a, name: "A")
        let initial = try await b.synchronize(meetings: []); try await apply(initial, to: "B", using: b)
        var remoteEdit = base; remoteEdit.setNotes("Remote edit")
        _ = try await publish(remoteEdit, using: a, name: "A")
        _ = try await b.synchronize(meetings: [base]) // Received, but did not apply.
        var offlineEdit = base; offlineEdit.setNotes("Offline local edit")
        let restarted = try engine("B")
        let result = try await restarted.synchronize(meetings: [offlineEdit])
        XCTAssertTrue(result.meetings[0].revisions.contains { $0.field == "sync:notes" })
    }

    func testDeletionWinsStaleAndConcurrentEditsButJournalPreservesRecoverySnapshot() async throws {
        let a = try engine("A"), b = try engine("B")
        let base = try await publish(Meeting(notes: "Recoverable"), using: a, name: "A")
        let initial = try await b.synchronize(meetings: []); try await apply(initial, to: "B", using: b)
        let deleted = try await a.synchronize(meetings: [], deletedMeetingIDs: [base.id]); try await apply(deleted, to: "A", using: a)
        // An edit the deletion never saw is kept as a new conversation; the deleted one stays deleted.
        var concurrent = base; concurrent.setNotes("Unsynced edit retained in the journal")
        let result = try await b.synchronize(meetings: [concurrent])
        XCTAssertTrue(result.deletedMeetingIDs.contains(base.id))
        XCTAssertFalse(result.meetings.contains { $0.id == base.id })
        XCTAssertEqual(result.meetings.map(\.notes), [concurrent.notes])
        XCTAssertTrue(try records().contains { ($0["snapshot"] as? [String: Any])?["notes"] as? String == concurrent.notes })
        try await apply(result, to: "B", using: b)
        let restart = try engine("B")
        let stale = try await restart.synchronize(meetings: [base])
        XCTAssertTrue(stale.meetings.isEmpty); XCTAssertEqual(stale.publishedEvents, 0)
        // An unchanged copy simply goes.
        let other = try await publish(Meeting(notes: "Nothing new"), using: a, name: "A")
        let pulled = try await b.synchronize(meetings: []); try await apply(pulled, to: "B", using: b)
        let gone = try await a.synchronize(meetings: [], deletedMeetingIDs: [other.id]); try await apply(gone, to: "A", using: a)
        let plain = try await b.synchronize(meetings: [other])
        XCTAssertTrue(plain.deletedMeetingIDs.contains(other.id))
        XCTAssertTrue(plain.meetings.isEmpty)
    }

    func testMissingOrCorruptBlobNeverAppliesRemoteMetadataAndRetries() async throws {
        let source = root.appendingPathComponent("audio.wav"); let bytes = Data("audio bytes".utf8); try bytes.write(to: source)
        let store = try MeetingStore(rootURL: local("A"))
        let meeting = try await store.importAudio(from: source, into: Meeting())
        let a = try engine("A"), b = try engine("B")
        _ = try await publish(meeting, using: a, name: "A")
        let blob = remote.appendingPathComponent("Blobs/\(meeting.tracks[0].sha256)")
        try FileManager.default.removeItem(at: blob)
        let missing = try await b.synchronize(meetings: [])
        XCTAssertTrue(missing.meetings.isEmpty); XCTAssertGreaterThan(missing.pendingDownloads, 0)
        try Data("corrupt".utf8).write(to: blob)
        let corrupt = try await b.synchronize(meetings: [])
        XCTAssertTrue(corrupt.meetings.isEmpty); XCTAssertFalse(corrupt.warnings.isEmpty)
        try bytes.write(to: blob)
        let ready = try await b.synchronize(meetings: [])
        XCTAssertEqual(ready.meetings.count, 1); XCTAssertEqual(ready.pendingDownloads, 0)
    }

    func testAHeldConversationPublishesALocalEditOnceAcrossManyPasses() async throws {
        let first = root.appendingPathComponent("first.wav"), second = root.appendingPathComponent("second.wav")
        try Data("first recording".utf8).write(to: first); try Data("second recording".utf8).write(to: second)
        let storeA = try MeetingStore(rootURL: local("A"))
        let a = try engine("A"), b = try engine("B")
        let base = try await publish(try await storeA.importAudio(from: first, into: Meeting(title: "Review")), using: a, name: "A")
        let pulled = try await b.synchronize(meetings: []); try await apply(pulled, to: "B", using: b)
        // A adds a recording whose audio hasn't reached the sync folder: B's copy waits for it.
        let added = try await storeA.importAudio(from: second, into: base)
        _ = try await publish(added, using: a, name: "A")
        try FileManager.default.removeItem(at: remote.appendingPathComponent("Blobs/\(added.tracks[1].sha256)"))
        var edited = pulled.meetings[0]; edited.setNotes("Edited on B while A's recording uploads")
        var published = 0
        for _ in 0..<5 {
            let result = try await b.synchronize(meetings: [edited])
            XCTAssertGreaterThan(result.pendingDownloads, 0)
            XCTAssertEqual(result.meetings.first?.notes, edited.notes, "the held conversation keeps the local edit")
            published += result.publishedEvents
            try await b.acknowledge(result.checkpointID)
        }
        XCTAssertEqual(published, 1, "a held conversation publishes its edit once, not every pass")
        XCTAssertEqual(try records().filter { $0["deviceID"] as? String == "B" }.count, 1)
    }

    func testARevertWhileAPublishedEditIsHeldBackIsPublishedToo() async throws {
        let first = root.appendingPathComponent("first.wav"), second = root.appendingPathComponent("second.wav")
        try Data("first recording".utf8).write(to: first); try Data("second recording".utf8).write(to: second)
        let storeA = try MeetingStore(rootURL: local("A"))
        let a = try engine("A"), b = try engine("B")
        var original = try await storeA.importAudio(from: first, into: Meeting(title: "Review"))
        original.notes = "Original"
        let base = try await publish(original, using: a, name: "A")
        let pulled = try await b.synchronize(meetings: []); try await apply(pulled, to: "B", using: b)
        let onB = pulled.meetings[0]
        // A's new recording hasn't uploaded, so B's copy is held back while B edits and then reverts.
        let added = try await storeA.importAudio(from: second, into: base)
        _ = try await publish(added, using: a, name: "A")
        let blob = remote.appendingPathComponent("Blobs/\(added.tracks[1].sha256)")
        let aside = root.appendingPathComponent("blob")
        try FileManager.default.moveItem(at: blob, to: aside)
        var changed = onB; changed.notes = "Changed"
        let edit = try await b.synchronize(meetings: [changed]); try await b.acknowledge(edit.checkpointID)
        XCTAssertEqual(edit.publishedEvents, 1)
        let revert = try await b.synchronize(meetings: [onB]); try await b.acknowledge(revert.checkpointID)
        XCTAssertEqual(revert.publishedEvents, 1, "going back to the base value is an edit too")
        try FileManager.default.moveItem(at: aside, to: blob)
        let settled = try await b.synchronize(meetings: [onB])
        XCTAssertEqual(settled.meetings.first?.notes, "Original")
        XCTAssertEqual(settled.meetings.first?.tracks.count, 2)
    }

    func testACrashBetweenWritingAnEntryAndSavingTheCheckpointPublishesTheSameEntry() async throws {
        let a = try engine("A")
        let base = try await publish(Meeting(title: "Plan", notes: "First"), using: a, name: "A")
        let checkpoint = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: local("A").appendingPathComponent("Sync"), includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "json" })
        let saved = try Data(contentsOf: checkpoint)
        var edited = base; edited.setNotes("Second")
        var renamed = Meeting(title: "Another"); renamed.notes = "Also new"
        let first = try await a.synchronize(meetings: [edited, renamed])
        XCTAssertEqual(first.publishedEvents, 2)
        let written = try records().count
        // The process stops after writing both entries but before the checkpoint recorded them.
        try saved.write(to: checkpoint)
        let restarted = try engine("A")
        let again = try await restarted.synchronize(meetings: [edited, renamed])
        XCTAssertEqual(try records().count, written, "the same bytes again, not a second sibling of each")
        try await apply(again, to: "A", using: restarted)
        let b = try engine("B")
        let pulled = try await b.synchronize(meetings: [])
        XCTAssertEqual(Set(pulled.meetings.map(\.notes)), ["Second", "Also new"])
        XCTAssertFalse(pulled.meetings.contains { $0.revisions.contains { $0.field.hasPrefix("sync:") } })
    }

    func testBasesLiveInTheirOwnFilesAndOnlyUsedSnapshotsStayInMemory() async throws {
        let a = try engine("A"), b = try engine("B")
        var meeting = try await publish(Meeting(title: "Long history"), using: a, name: "A")
        for index in 0..<12 {
            meeting.setNotes("Revision \(index)")
            meeting = try await publish(meeting, using: a, name: "A")
        }
        let other = try await publish(Meeting(title: "Short"), using: a, name: "A")
        let pulled = try await b.synchronize(meetings: [])
        try await apply(pulled, to: "B", using: b)
        let counts = await b.cacheCounts()
        XCTAssertEqual(counts.headers, 14, "every event's header")
        XCTAssertEqual(counts.snapshots, 2, "only the two heads' snapshots")
        let sync = local("B").appendingPathComponent("Sync")
        let checkpoint = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: sync, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" })
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: checkpoint)) as? [String: Any])
        XCTAssertEqual((stored["bases"] as? [String: Any])?.count, 0, "no copy of the library in the checkpoint")
        let bases = sync.appendingPathComponent("Bases/\(checkpoint.deletingPathExtension().lastPathComponent)")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: bases.path)), ["\(meeting.id).json", "\(other.id).json"])
        // A restarted engine reads them back: nothing is published again.
        let restarted = try engine("B")
        let again = try await restarted.synchronize(meetings: pulled.meetings)
        XCTAssertEqual(again.publishedEvents, 0)
        XCTAssertTrue(again.changedMeetingIDs.isEmpty)
    }

    func testFailedLocalUploadPreservesUnsentEdits() async throws {
        let a = try engine("A")
        let base = try await publish(Meeting(notes: "Published base"), using: a, name: "A")
        var changed = base; changed.setNotes("Keep this unsent edit")
        changed.tracks.append(.init(relativePath: "Originals/missing.wav", fileName: "Missing recording"))
        let result = try await a.synchronize(meetings: [changed])
        XCTAssertEqual(result.meetings[0], changed); XCTAssertGreaterThan(result.pendingUploads, 0)
    }

    func testRemoteIdentityScopesCheckpointsAndCorruptCheckpointStaysBlocked() async throws {
        let a = try engine("A")
        let original = try await publish(Meeting(notes: "Upload to both libraries"), using: a, name: "A")
        let other = root.appendingPathComponent("OtherRemote")
        let differentLibrary = try engine("A", remote: other)
        let fresh = try await differentLibrary.synchronize(meetings: [original])
        XCTAssertEqual(fresh.publishedEvents, 1)
        let checkpoints = try FileManager.default.contentsOfDirectory(at: local("A").appendingPathComponent("Sync"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        XCTAssertEqual(checkpoints.count, 2)
        for checkpoint in checkpoints { try Data("broken".utf8).write(to: checkpoint) }
        let restart = try engine("A")
        for _ in 0..<2 {
            do { _ = try await restart.synchronize(meetings: [original]); XCTFail("Ignored corrupt causal history") }
            catch LibrarySyncError.corruptState { }
        }
    }

    func testMetadataConcurrentVersionsRemainUntilCallerMergesAndAcknowledges() async throws {
        let a = try engine("A"), b = try engine("B")
        let first = try await a.synchronize(meetings: [], libraryMetadata: Data("base".utf8)); try await a.acknowledge(first.checkpointID)
        let initial = try await b.synchronize(meetings: []); try await b.acknowledge(initial.checkpointID)
        let left = try await a.synchronize(meetings: [], libraryMetadata: Data("A folders".utf8)); try await a.acknowledge(left.checkpointID)
        let right = try await b.synchronize(meetings: [], libraryMetadata: Data("B templates".utf8))
        XCTAssertEqual(Set(right.metadataVersions), Set([Data("A folders".utf8), Data("B templates".utf8)]))
        try await b.acknowledge(right.checkpointID)
        let merged = try await b.synchronize(meetings: [], libraryMetadata: Data("A folders and B templates".utf8))
        XCTAssertEqual(merged.metadataVersions, [Data("A folders and B templates".utf8)])
    }

    func testMaliciousAssetPathAndCrossMeetingParentsAreRejected() async throws {
        let a = try engine("A")
        let base = try await publish(Meeting(notes: "Legitimate"), using: a, name: "A")
        let urls = try FileManager.default.contentsOfDirectory(at: remote.appendingPathComponent("Events"), includingPropertiesForKeys: nil)
        let originalHash = try XCTUnwrap(urls.first).deletingPathExtension().lastPathComponent
        var forged = try XCTUnwrap(records().first)
        var snapshot = try XCTUnwrap(forged["snapshot"] as? [String: Any])
        let otherID = UUID(); snapshot["id"] = otherID.uuidString; snapshot["notes"] = "Must not appear"
        forged["meetingID"] = otherID.uuidString; forged["snapshot"] = snapshot; forged["parents"] = [originalHash]
        _ = try writeRecord(forged)
        var unsafe = try XCTUnwrap(records().first { ($0["meetingID"] as? String) == base.id.uuidString })
        unsafe["assets"] = [["relativePath": "Originals/../../outside", "sha256": String(repeating: "a", count: 64)]]
        _ = try writeRecord(unsafe)
        let result = try await engine("B").synchronize(meetings: [])
        XCTAssertEqual(result.meetings.map(\.id), [base.id]); XCTAssertGreaterThanOrEqual(result.warnings.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: local("B").appendingPathComponent("Meetings/outside").path))
    }

    func testIntentionalRevertToPreviouslyPublishedValueIsNotSuppressed() async throws {
        let a = try engine("A"), b = try engine("B")
        let base = try await publish(Meeting(notes: "Original"), using: a, name: "A")
        let initial = try await b.synchronize(meetings: []); try await apply(initial, to: "B", using: b)
        var changed = base; changed.notes = "Remote replacement"
        _ = try await publish(changed, using: b, name: "B")
        let pulled = try await a.synchronize(meetings: [base]); try await apply(pulled, to: "A", using: a)
        let reverted = try await a.synchronize(meetings: [base])
        XCTAssertEqual(reverted.publishedEvents, 1); XCTAssertEqual(reverted.meetings[0].notes, "Original")
    }

    func testMergeIsCommutativeAndKeepsIndependentArtifacts() {
        let base = Meeting(notes: "Base", tags: ["old"])
        var a = base, b = base
        a.setNotes("First"); b.setNotes("Second")
        a.tracks = [.init(relativePath: "Originals/a.wav", fileName: "A")]
        b.tracks = [.init(relativePath: "Originals/b.wav", fileName: "B")]
        a.tags = ["A"]; b.tags = ["old", "B"]
        let forward = MeetingMerge.merge(base: base, local: a, remote: b)
        let reverse = MeetingMerge.merge(base: base, local: b, remote: a)
        XCTAssertEqual(forward.meeting, reverse.meeting)
        XCTAssertEqual(forward.meeting.tracks.count, 2); XCTAssertEqual(forward.meeting.tags, ["A", "B"])
    }

    func testBookmarkDeletionSurvivesAnIndependentEditAndConcurrentEditsRemainRecoverable() {
        let bookmark = Highlight(time: 5, text: "Decision")
        let base = Meeting(title: "Review", highlights: [bookmark])
        var deleted = base, renamed = base
        deleted.highlights = []
        renamed.title = "Renamed"
        for (a, b) in [(deleted, renamed), (renamed, deleted), (deleted, deleted)] {
            XCTAssertTrue(MeetingMerge.merge(base: base, local: a, remote: b).meeting.highlights.isEmpty)
        }
        var edited = base
        edited.highlights[0].text = "Edited decision"
        let forward = MeetingMerge.merge(base: base, local: deleted, remote: edited)
        let reverse = MeetingMerge.merge(base: base, local: edited, remote: deleted)
        XCTAssertEqual(forward.meeting, reverse.meeting)
        XCTAssertTrue(forward.meeting.revisions.contains { $0.field.hasPrefix("sync:highlight:") })
    }

    func testRepeatedMergeDiamondsTraverseWithinBudgetAndExpiredPassDefersWork() async throws {
        let sync = try engine("reader")
        let initial = try await sync.synchronize(meetings: [])
        try await sync.acknowledge(initial.checkpointID)
        let meeting = Meeting(title: "Branching history")
        var parents: [String] = []
        for level in 0..<24 {
            var next: [String] = []
            for device in ["a", "b"] {
                let snapshot = try JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting))
                let event: [String: Any] = ["schemaVersion": 1, "meetingID": meeting.id.uuidString, "deviceID": device,
                    "sequence": level, "parents": parents, "snapshot": snapshot, "deleted": false, "assets": []]
                let bytes = try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])
                let digest = SyncDigest.sha256(data: bytes)
                try bytes.write(to: remote.appendingPathComponent("Events/\(digest).json"))
                next.append(digest)
            }
            parents = next
        }
        let start = ContinuousClock.now
        let result = try await sync.synchronize(meetings: [], limits: SyncPassLimits(timeBudget: .seconds(2)))
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        XCTAssertEqual(result.meetings.map(\.id), [meeting.id])
        try await sync.acknowledge(result.checkpointID)
        let expired = try await sync.synchronize(meetings: result.meetings, limits: SyncPassLimits(timeBudget: .zero))
        XCTAssertTrue(expired.hasMoreWork)
        XCTAssertEqual(expired.meetings, result.meetings)
    }

    func testDerivedTranscriptViewKeepsItsOwnAlignmentAndReviewCandidates() {
        let track = UUID(), base = Meeting()
        var a = base, b = base
        a.unifiedTranscript = [.init(trackID: track, start: 9, end: 10, text: "A words")]
        b.unifiedTranscript = [.init(trackID: track, start: 2, end: 3, text: "Z words")]
        a.alignmentReports = [.init(trackID: track, method: .provided, offset: 9)]
        b.alignmentReports = [.init(trackID: track, method: .provided, offset: 2)]
        a.correctionTransferIssues = [.init(originalSegment: a.unifiedTranscript[0], candidateSegmentIDs: [a.unifiedTranscript[0].id], reason: "A review")]
        b.correctionTransferIssues = [.init(originalSegment: b.unifiedTranscript[0], candidateSegmentIDs: [b.unifiedTranscript[0].id], reason: "B review")]
        let result = MeetingMerge.merge(base: base, local: a, remote: b).meeting
        let selected = result.unifiedTranscript == a.unifiedTranscript ? a : b
        XCTAssertEqual(result.alignmentReports, selected.alignmentReports)
        XCTAssertEqual(result.correctionTransferIssues, selected.correctionTransferIssues)
        XCTAssertTrue(result.revisions.contains { $0.field == "sync:transcript-view" })
    }

    func testConcurrentNotesPreserveBothParagraphTimelinesInHistory() throws {
        let base = Meeting(notes: "Base")
        var a = base, b = base
        a.notes = "A note"; a.timedNotes = [.init(time: 15.5, text: a.notes)]
        b.notes = "B note"; b.timedNotes = [.init(time: 42.25, text: b.notes)]
        let merged = MeetingMerge.merge(base: base, local: a, remote: b).meeting
        XCTAssertEqual(merged.timedNotes, merged.notes == a.notes ? a.timedNotes : b.timedNotes)
        let history = try XCTUnwrap(merged.revisions.first { $0.field == "sync:notes" })
        let serialized = history.oldValue + history.newValue
        for note in (a.timedNotes ?? []) + (b.timedNotes ?? []) {
            XCTAssertTrue(serialized.contains(note.id.uuidString)); XCTAssertTrue(serialized.contains(note.text))
            XCTAssertTrue(serialized.contains(String(note.time!)))
        }
    }

    func testChangedLocalOriginalIsPreservedAndRepairedAfterCachedIntegrityCheck() async throws {
        let source = root.appendingPathComponent("audio.wav"), bytes = Data("trusted original".utf8)
        try bytes.write(to: source)
        let meeting = try await MeetingStore(rootURL: local("A")).importAudio(from: source, into: Meeting())
        let a = try engine("A"), b = try engine("B")
        _ = try await publish(meeting, using: a, name: "A")
        let first = try await b.synchronize(meetings: []); try await apply(first, to: "B", using: b)
        let original = local("B").appendingPathComponent("Meetings/\(meeting.id)/\(meeting.tracks[0].relativePath)")
        let modified = Data("externally modified recording".utf8); try modified.write(to: original)
        let repaired = try await b.synchronize(meetings: first.meetings)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        // One plain sentence; where the changed copy went is behind Details.
        let kept = try XCTUnwrap(repaired.warnings.map(SyncWarningWords.split).first { $0.text == SyncWarningWords.keptBothRecordings + "." })
        XCTAssertTrue(kept.details?.contains("SyncConflicts") == true)
        let conflicts = local("B").appendingPathComponent("Meetings/\(meeting.id)/SyncConflicts")
        let saved = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: conflicts, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: saved), modified)
    }

    func testSyncSymlinkLocationsAndInvalidSourceTimesAreRejected() async throws {
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: remote, withDestinationURL: outside)
        XCTAssertThrowsError(try engine("A"))
        try FileManager.default.removeItem(at: remote)
        let a = try engine("A")
        _ = try await publish(Meeting(), using: a, name: "A")
        var event = try XCTUnwrap(records().first)
        var snapshot = try XCTUnwrap(event["snapshot"] as? [String: Any])
        let track = UUID()
        let run = TrackTranscript(trackID: track, segments: [.init(trackID: track, start: -10, end: 2, text: "Invalid source time")])
        snapshot["transcripts"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode([run]))
        event["snapshot"] = snapshot
        _ = try writeRecord(event)
        let result = try await engine("B").synchronize(meetings: [])
        XCTAssertEqual(result.meetings.count, 1)
        XCTAssertTrue(result.meetings[0].transcripts.isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
        let syncPath = local("C").appendingPathComponent("Sync")
        try FileManager.default.createDirectory(at: local("C"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: syncPath, withDestinationURL: outside)
        XCTAssertThrowsError(try engine("C"))
    }
}
