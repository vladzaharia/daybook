import XCTest
@testable import DaybookCore

final class MeetingStoreTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    func testRoundTripRetainsNotesCorrectionsAndOriginalTranscripts() async throws {
        let store = try MeetingStore(rootURL: root)
        let track = UUID()
        let segment = TranscriptSegment(trackID: track, start: 1, end: 2, text: "Wrong term")
        var meeting = Meeting(title: "Weekly review", transcripts: [TrackTranscript(trackID: track, segments: [segment])], unifiedTranscript: [segment])
        meeting.setNotes("A note captured live")
        meeting.correctSegment(id: segment.id, text: "Correct term")
        meeting.setSummary(MeetingSummary(overview: "Review complete"))
        try await store.save(meeting)
        let restarted = try MeetingStore(rootURL: root)
        let loaded = try await restarted.load(meeting.id)
        XCTAssertEqual(loaded, meeting)
        XCTAssertEqual(loaded.transcripts[0].segments[0].text, "Wrong term")
        XCTAssertEqual(loaded.revisions.count, 3)
    }
    func testDamagedMetadataRecoversPreviousSnapshot() async throws {
        let store = try MeetingStore(rootURL: root)
        var meeting = Meeting(title: "Recoverable meeting", notes: "Original note")
        try await store.save(meeting)
        meeting.setNotes("Newer note")
        try await store.save(meeting)
        let directory = try await store.meetingDirectory(for: meeting.id)
        try Data("{broken".utf8).write(to: directory.appendingPathComponent("meeting.json"))
        let loaded = try await store.load(meeting.id)
        XCTAssertEqual(loaded.notes, "Original note")
        let warnings = await store.warnings
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix("meeting.corrupt-") })
        let restored = try await store.load(meeting.id)
        XCTAssertEqual(restored, loaded)
    }
    func testListReportsCorruptionWithoutHidingOtherMeetings() async throws {
        let store = try MeetingStore(rootURL: root)
        let good = Meeting(title: "Healthy meeting")
        try await store.save(good)
        let bad = try await store.meetingDirectory(for: UUID())
        try Data("invalid".utf8).write(to: bad.appendingPathComponent("meeting.json"))
        let meetings = try await store.list()
        let warnings = await store.warnings
        XCTAssertEqual(meetings.map(\.id), [good.id])
        XCTAssertEqual(warnings.count, 1)
    }
    func testImportCopiesBytesDeduplicatesAndPreservesHighlights() async throws {
        let store = try MeetingStore(rootURL: root)
        let source = root.appendingPathComponent("voice.mp3")
        let bytes = Data("fixture audio bytes".utf8)
        try bytes.write(to: source)
        let sidecar = root.appendingPathComponent("voice.json")
        try JSONEncoder().encode(HighlightSidecar(highlights: [.init(time: 4.5, text: "Key moment")])).write(to: sidecar)
        let first = try await store.importAudio(from: source, into: Meeting(), source: .soundcore, sidecarURL: sidecar)
        let second = try await store.importAudio(from: source, into: first, source: .soundcore, sidecarURL: sidecar)
        XCTAssertEqual(second.tracks.count, 1)
        XCTAssertEqual(second.highlights.count, 1)
        let imported = try await store.audioURL(for: second.tracks[0], in: second.id)
        XCTAssertEqual(try Data(contentsOf: imported), bytes)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try Data(contentsOf: imported), bytes)
        XCTAssertEqual(second.highlights[0].trackID, second.tracks[0].id)
        XCTAssertEqual(second.tracks[0].sha256, AudioDigest.sha256(data: bytes))
    }
    func testPathTraversalAndSymlinkEscapeAreRejected() async throws {
        let store = try MeetingStore(rootURL: root)
        let meeting = Meeting()
        for path in ["../outside.wav", "/etc/passwd", "Originals/../../outside.wav", "Originals//audio.wav"] {
            do {
                _ = try await store.audioURL(for: RecordingTrack(relativePath: path, fileName: "bad"), in: meeting.id)
                XCTFail("Accepted unsafe path: \(path)")
            } catch LibraryError.unsafePath { } catch { XCTFail("Wrong error: \(error)") }
        }
        let directory = try await store.meetingDirectory(for: meeting.id)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("escape"), withDestinationURL: root)
        do {
            _ = try await store.audioURL(for: RecordingTrack(relativePath: "escape/private.wav", fileName: "bad"), in: meeting.id)
            XCTFail("Accepted symlink escape")
        } catch LibraryError.unsafePath { }
    }
    func testFutureSchemaIsNotSilentlyRolledBack() async throws {
        let store = try MeetingStore(rootURL: root)
        let meeting = Meeting()
        try await store.save(meeting)
        let directory = try await store.meetingDirectory(for: meeting.id)
        try Data("{\"schemaVersion\":99}".utf8).write(to: directory.appendingPathComponent("meeting.json"))
        do { _ = try await store.load(meeting.id); XCTFail("Future schema was rolled back") }
        catch LibraryError.unsupportedSchema(99) { }
        do { try await store.save(meeting); XCTFail("Future schema was overwritten") }
        catch LibraryError.unsupportedSchema(99) { }
    }
    func testSHA256KnownVectorsAndStreaming() throws {
        XCTAssertEqual(AudioDigest.sha256(data: Data()), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(AudioDigest.sha256(data: Data("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let million = Data(repeating: 97, count: 1_000_000)
        XCTAssertEqual(AudioDigest.sha256(data: million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
        let file = root.appendingPathComponent("large.wav")
        let bytes = Data(repeating: 42, count: 2_100_017)
        try bytes.write(to: file)
        XCTAssertEqual(try AudioDigest.sha256(fileURL: file), AudioDigest.sha256(data: bytes))
    }
    func testUnapprovedVocabularyStaysWithinOriginMeeting() async throws {
        let glossary = try GlossaryStore(rootURL: root)
        let therapy = UUID(), work = UUID()
        try await glossary.propose([GlossaryTerm(term: "Avery", definition: "Private therapy context", approved: true)], for: therapy)
        let approved = try await glossary.approvedTerms()
        let workTerms = try await glossary.terms(for: work)
        XCTAssertTrue(approved.isEmpty)
        XCTAssertTrue(workTerms.isEmpty)
        try await glossary.propose([GlossaryTerm(term: "Avery", definition: "A work project")], for: work)
        let scoped = try await glossary.terms(for: work)
        XCTAssertEqual(scoped.count, 1)
        XCTAssertEqual(scoped.first?.definition, "A work project")
        var terms = try await glossary.list()
        terms[1].approved = true
        try await glossary.save(terms)
        let shared = try await glossary.approvedTerms()
        XCTAssertEqual(shared.count, 1)
        XCTAssertEqual(shared.first?.definition, "A work project")
    }
    func testStaleImportAndNotesSnapshotCannotDetachRecordings() async throws {
        let store = try MeetingStore(rootURL: root)
        let original = Meeting(title: "Concurrent changes")
        try await store.save(original)
        var newer = original
        newer.setNotes("New notes saved during import")
        try await store.save(newer)
        let source = root.appendingPathComponent("first.wav")
        try Data("first audio".utf8).write(to: source)
        let first = try await store.importAudio(from: source, into: original)
        XCTAssertEqual(first.notes, newer.notes)
        let secondSource = root.appendingPathComponent("second.wav")
        try Data("second audio".utf8).write(to: secondSource)
        let second = try await store.importAudio(from: secondSource, into: original)
        XCTAssertEqual(second.tracks.count, 2)
        newer.setNotes("Typing continued while the second import finished")
        try await store.save(newer)
        let stored = try await store.load(original.id)
        XCTAssertEqual(stored.tracks.count, 2)
        XCTAssertEqual(stored.notes, newer.notes)
        let existing = try await store.existingMeeting(containingAudioAt: source)
        XCTAssertEqual(existing?.id, original.id)
    }
    func testLocalTrashIsReversibleAndRejectsQueuedStaleSaves() async throws {
        let store = try MeetingStore(rootURL: root)
        let meeting = Meeting(title: "Private conversation", notes: "Keep this recoverable")
        try await store.save(meeting)
        let trashURL = try await store.moveToTrash(meeting.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.appendingPathComponent("meeting.json").path))
        let listed = try await store.list()
        XCTAssertTrue(listed.isEmpty)
        do { try await store.save(meeting); XCTFail("A queued save resurrected a trashed meeting") }
        catch LibraryError.trashedMeeting { }
        let restarted = try MeetingStore(rootURL: root)
        do { try await restarted.save(meeting); XCTFail("Tombstone did not persist across restart") }
        catch LibraryError.trashedMeeting { }
        let restored = try await restarted.restoreFromTrash(meeting.id)
        XCTAssertEqual(restored, meeting)
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashURL.path))
    }
    func testNegativeUnifiedTimelineRoundTripsButNegativeRawTimeIsRejected() async throws {
        let store = try MeetingStore(rootURL: root)
        let track = RecordingTrack(relativePath: "Originals/fixture.wav", fileName: "fixture.wav", offset: -20)
        let raw = TranscriptSegment(trackID: track.id, start: 0, end: 2, text: "Before the reference recording")
        var meeting = Meeting(tracks: [track], transcripts: [TrackTranscript(trackID: track.id, segments: [raw])])
        meeting.applyFusion(TranscriptFusion.fuse(meeting.transcripts, tracks: meeting.tracks))
        try await store.save(meeting)
        let loaded = try await store.load(meeting.id)
        XCTAssertEqual(loaded.unifiedTranscript.first?.start, -20)
        meeting.transcripts[0].segments[0].start = -1
        do { try await store.save(meeting); XCTFail("Negative source-local time should be rejected") }
        catch LibraryError.invalidTranscript { }
    }
    func testSemanticCorruptionRecoversAndQueuedSaveRetainsRecoveryArtifacts() async throws {
        let store = try MeetingStore(rootURL: root)
        let original = Meeting(title: "Recover track")
        let source = root.appendingPathComponent("source.wav")
        try Data("audio fixture".utf8).write(to: source)
        let imported = try await store.importAudio(from: source, into: original)
        let directory = try await store.meetingDirectory(for: original.id)
        var bad = imported
        bad.id = UUID()
        try JSONEncoder().encode(bad).write(to: directory.appendingPathComponent("meeting.json"))
        var notesSnapshot = original
        notesSnapshot.setNotes("New notes from a queued write")
        try await store.save(notesSnapshot)
        let restored = try await store.load(original.id)
        XCTAssertEqual(restored.tracks.count, 1)
        XCTAssertEqual(restored.notes, notesSnapshot.notes)
        let warnings = await store.warnings
        XCTAssertEqual(warnings.count, 1)
    }
    func testVersionedHighlightSidecarsAndLegacyCompatibility() async throws {
        let store = try MeetingStore(rootURL: root)
        let source = root.appendingPathComponent("voice.wav")
        try Data("audio fixture".utf8).write(to: source)
        let sidecar = root.appendingPathComponent("voice.highlights.json")
        try Data("{\"highlights\":[{\"time\":5,\"text\":\"Legacy mark\"}]}".utf8).write(to: sidecar)
        let imported = try await store.importAudio(from: source, into: Meeting(), sidecarURL: sidecar)
        XCTAssertEqual(imported.highlights.first?.text, "Legacy mark")
        try JSONEncoder().encode(HighlightSidecar(schemaVersion: 99, highlights: [])).write(to: sidecar)
        do { _ = try await store.importAudio(from: source, into: imported, sidecarURL: sidecar); XCTFail("Unsupported sidecar version accepted") }
        catch LibraryError.unsupportedHighlightSchema(99) { }
        try Data("{\"transcript\":\"Different recorder export\"}".utf8).write(to: sidecar)
        do { _ = try await store.importAudio(from: source, into: imported, sidecarURL: sidecar); XCTFail("Unrelated JSON accepted as highlights") }
        catch LibraryError.invalidHighlightSidecar { }
        let preserved = try await store.load(imported.id)
        XCTAssertEqual(preserved.highlights.count, 1)
    }
    func testMissingGlossaryPrimaryRecoversFromBackup() async throws {
        let store = try GlossaryStore(rootURL: root)
        let term = GlossaryTerm(term: "Daybook", approved: true)
        try await store.save([term])
        try FileManager.default.removeItem(at: root.appendingPathComponent("glossary.json"))
        let recovered = try await store.list()
        XCTAssertEqual(recovered, [term])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("glossary.json").path))
    }
    func testDedupeDoesNotHideMissingOrModifiedOriginalAudio() async throws {
        let store = try MeetingStore(rootURL: root)
        let source = root.appendingPathComponent("voice.wav")
        try Data("original audio bytes".utf8).write(to: source)
        let first = try await store.importAudio(from: source, into: Meeting())
        let original = try await store.audioURL(for: first.tracks[0], in: first.id)
        try FileManager.default.removeItem(at: original)
        let missing = try await store.existingMeeting(containingAudioAt: source)
        XCTAssertNil(missing)
        let restored = try await store.importAudio(from: source, into: first)
        XCTAssertEqual(restored.tracks.count, 2)
        let restoredURL = try await store.audioURL(for: restored.tracks[1], in: restored.id)
        try Data("modified audio bytes".utf8).write(to: restoredURL)
        let modified = try await store.existingMeeting(containingAudioAt: source)
        XCTAssertNil(modified)
        let reimported = try await store.importAudio(from: source, into: restored)
        XCTAssertEqual(reimported.tracks.count, 3)
        let found = try await store.existingMeeting(containingAudioAt: source)
        XCTAssertEqual(found?.id, first.id)
    }

    func testSavesReuseTheStoredVersionUntilAnotherWriterChangesTheFile() async throws {
        let store = try MeetingStore(rootURL: root)
        var meeting = Meeting(title: "Long conversation")
        try await store.save(meeting)
        for index in 0..<20 {
            meeting.notes = "Typing \(index)"
            try await store.save(meeting)
        }
        var reads = await store.metadataReads
        XCTAssertEqual(reads, 0, "An unchanged meeting.json is never read back to save the next snapshot")
        // Another writer (a second store, an older Daybook) changes the file: the next save reads it once.
        let source = root.appendingPathComponent("voice.wav")
        try Data("audio from elsewhere".utf8).write(to: source)
        let imported = try await MeetingStore(rootURL: root).importAudio(from: source, into: meeting)
        meeting.notes = "Typing continued"
        try await store.save(meeting)
        reads = await store.metadataReads
        XCTAssertEqual(reads, 1)
        let stored = try await store.load(meeting.id)
        XCTAssertEqual(stored.tracks.map(\.id), imported.tracks.map(\.id), "The other writer's recording is kept")
        XCTAssertEqual(stored.notes, "Typing continued")
        reads = await store.metadataReads
        XCTAssertEqual(reads, 1)
    }

    func testAnUnchangedSnapshotWritesNothing() async throws {
        let store = try MeetingStore(rootURL: root)
        let meeting = Meeting(title: "Quiet")
        try await store.save(meeting)
        let primary = root.appendingPathComponent("Meetings/\(meeting.id)/meeting.json")
        let before = try FileManager.default.attributesOfItem(atPath: primary.path)[.systemFileNumber] as? Int
        try await store.save(meeting)
        try await store.save(meeting)
        let writes = await store.metadataWrites
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: primary.path)[.systemFileNumber] as? Int, before)
    }

    func testTheRecoveryCopyIsThePreviousSnapshotAndFilesAreCompact() async throws {
        let store = try MeetingStore(rootURL: root)
        var meeting = Meeting(title: "Versions", notes: "First")
        try await store.save(meeting)
        meeting.notes = "Second"
        try await store.save(meeting)
        meeting.notes = "Third"
        try await store.save(meeting)
        let folder = root.appendingPathComponent("Meetings/\(meeting.id)")
        let primary = try Data(contentsOf: folder.appendingPathComponent("meeting.json"))
        let backup = try Data(contentsOf: folder.appendingPathComponent("meeting.recovery.json"))
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: primary).notes, "Third")
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: backup).notes, "Second")
        XCTAssertFalse(String(decoding: primary, as: UTF8.self).contains("\n"), "Compact JSON")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [], "No temporary files stay behind")
    }

    func testReadsThePrettyPrintedFilesEarlierVersionsWrote() async throws {
        let meeting = Meeting(title: "Written by 0.3", notes: "Kept")
        let folder = root.appendingPathComponent("Meetings/\(meeting.id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(meeting).write(to: folder.appendingPathComponent("meeting.json"))
        try encoder.encode(meeting).write(to: folder.appendingPathComponent("meeting.recovery.json"))
        let store = try MeetingStore(rootURL: root)
        let loaded = try await store.list()
        XCTAssertEqual(loaded, [meeting])
        var edited = meeting
        edited.notes = "Edited here"
        try await store.save(edited)
        let backup = try Data(contentsOf: folder.appendingPathComponent("meeting.recovery.json"))
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: backup).notes, "Kept", "The earlier file became the recovery copy")
    }

    func testALongImportDoesNotHoldUpOtherSavesAndStopsWhenCancelled() async throws {
        let store = try MeetingStore(rootURL: root)
        // A sparse two-gigabyte "recording": no disk space, but hashing it takes a while.
        let source = root.appendingPathComponent("long.wav")
        FileManager.default.createFile(atPath: source.path, contents: Data("RIFF".utf8))
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 2 << 30)
        try handle.close()
        let target = Meeting(title: "Long import")
        try await store.save(target)
        let importing = Task { try await store.importAudio(from: source, into: target) }
        try await Task.sleep(for: .milliseconds(100))
        let started = Date()
        var other = Meeting(title: "Edited meanwhile")
        try await store.save(other)
        other.notes = "Saved while the import hashed"
        try await store.save(other)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "Saves don't wait for the import")
        importing.cancel()
        do { _ = try await importing.value; XCTFail("A cancelled import finished") } catch is CancellationError { }
        let originals = root.appendingPathComponent("Meetings/\(target.id.uuidString)/Originals")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: originals.path), [], "Nothing staged is left behind")
        let stored = try await store.load(target.id)
        XCTAssertTrue(stored.tracks.isEmpty)
    }
}
