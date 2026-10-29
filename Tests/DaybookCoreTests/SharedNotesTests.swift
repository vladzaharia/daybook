import XCTest
@testable import DaybookCore

/// Notes and bookmarks shared live during a recording on two devices, and a recorder's live audio
/// replaced by its own file (docs/multipoint.md): each paragraph, bookmark, and recording is one item,
/// by its ID, however many ways it arrives.
final class SharedNotesTests: XCTestCase {
    // MARK: Paragraphs by ID

    func testChangesAreTheParagraphsWrittenEditedOrDeletedByID() {
        let a = TimedNote(time: 1, text: "Agenda"), b = TimedNote(time: 5, text: "Launch on the 14th")
        let c = TimedNote(time: 9, text: "Priya owns the checklist")
        var edited = b
        edited.text = "Launch on the 21st"
        let changes = NoteTimeline.changes(from: [a, b, c], to: [a, edited, TimedNote(id: UUID(), time: 12, text: "New")])
        XCTAssertEqual(changes.map(\.text), ["Launch on the 21st", "New", "Priya owns the checklist"])
        XCTAssertEqual(changes.map(\.deleted), [false, false, true])
        XCTAssertEqual(changes[0].id, b.id)
        var moved = a
        moved.time = 99
        XCTAssertTrue(NoteTimeline.changes(from: [a], to: [moved]).isEmpty, "a time isn't an edit")
    }

    func testAParagraphFromAnotherDeviceGoesAtTheEndAndEditsAndDeletesInPlace() {
        let mine = TimedNote(time: 2, text: "Agenda: launch")
        let text = "Agenda: launch\n\nMy second thought\n"
        let anchors = NoteTimeline.anchors([mine], text: text)

        let theirs = SharedNote(id: UUID(), text: "From the phone\nwith a line break", time: 30)
        let added = NoteTimeline.applying(theirs, to: text, anchors: anchors)
        XCTAssertEqual(added.text, "Agenda: launch\n\nMy second thought\nFrom the phone with a line break", "the rest as it was")
        XCTAssertEqual(added.anchors.last, TimedNote(id: theirs.id, time: 30, text: "From the phone with a line break"))
        XCTAssertEqual(added.anchors.first, mine)

        let edit = SharedNote(id: theirs.id, text: "From the phone, edited", time: 30)
        let edited = NoteTimeline.applying(edit, to: added.text, anchors: added.anchors)
        XCTAssertEqual(edited.text, "Agenda: launch\n\nMy second thought\nFrom the phone, edited")
        XCTAssertEqual(edited.anchors.count, 3)

        let editMine = NoteTimeline.applying(SharedNote(id: mine.id, text: "Agenda: launch and pricing", time: 2), to: edited.text, anchors: edited.anchors)
        XCTAssertEqual(editMine.text, "Agenda: launch and pricing\n\nMy second thought\nFrom the phone, edited", "edited where it is")

        let deleted = NoteTimeline.applying(SharedNote(id: theirs.id, text: "", time: nil, deleted: true), to: editMine.text, anchors: editMine.anchors)
        XCTAssertEqual(deleted.text, "Agenda: launch and pricing\n\nMy second thought")
        XCTAssertFalse(deleted.anchors.contains { $0.id == theirs.id })

        // Typing afterwards keeps the shared paragraph's ID and time (NoteTimeline.reconcile).
        let again = NoteTimeline.applying(theirs, to: "", anchors: nil)
        let typed = NoteTimeline.reconcile(previous: again.anchors, text: again.text + "\nMine now", captureTime: 40)
        XCTAssertEqual(typed.first, TimedNote(id: theirs.id, time: 30, text: "From the phone with a line break"))
    }

    func testBookmarksFromAnotherDeviceAreKeptOnceByIDAndChangeByID() {
        var meeting = Meeting(title: "Design review")
        let mark = Highlight(time: 12, text: "")
        XCTAssertTrue(meeting.addSharedBookmark(mark))
        XCTAssertFalse(meeting.addSharedBookmark(mark), "once")
        meeting.applySharedBookmarkChange(id: mark.id, label: "Decision", deleted: false)
        XCTAssertEqual(meeting.highlights.map(\.text), ["Decision"])
        meeting.applySharedBookmarkChange(id: mark.id, label: nil, deleted: true)
        XCTAssertTrue(meeting.highlights.isEmpty)
    }

    // MARK: Meeting the synced copy

    /// The Mac applied the phone's paragraphs live as they arrived (at the end), the phone filed them
    /// in its own order: both copies hold every paragraph once, so neither the merge nor History has
    /// anything to say, with or without a common ancestor.
    func testTheLinksCopyAndTheSyncedCopyAreOneParagraphEach() {
        let id = UUID()
        let base = Meeting(id: id, title: "Design review", notes: "Agenda")
        let agenda = NoteTimeline.anchors(nil, text: "Agenda")[0]
        var mac = base
        mac.timedNotes = [agenda]
        let macNote = SharedNote(id: UUID(), text: "Mac at ten", time: 10)
        let phoneNote = SharedNote(id: UUID(), text: "Phone at thirty", time: 30)
        mac.applySharedNote(macNote)
        mac.applySharedNote(phoneNote)
        var phone = base
        phone.timedNotes = [agenda]
        phone.applySharedNote(phoneNote)
        phone.applySharedNote(macNote)
        XCTAssertNotEqual(mac.notes, phone.notes, "another order")

        for ancestor in [Optional(Meeting(id: id, title: "Design review", notes: "Agenda", timedNotes: [agenda])), nil] {
            let forward = MeetingMerge.merge(base: ancestor, local: mac, remote: phone)
            let reverse = MeetingMerge.merge(base: ancestor, local: phone, remote: mac)
            XCTAssertEqual(forward.meeting, reverse.meeting, "commutative")
            XCTAssertEqual(forward.meeting.notes.components(separatedBy: "\n").filter { !$0.isEmpty }.sorted(), ["Agenda", "Mac at ten", "Phone at thirty"], "each once")
            XCTAssertEqual(Set(forward.meeting.timedNotes?.map(\.id) ?? []), [agenda.id, macNote.id, phoneNote.id])
            XCTAssertFalse(forward.meeting.revisions.contains { $0.field.hasPrefix("sync:notes") }, "nothing for History")
            XCTAssertTrue(forward.warnings.isEmpty)
        }

        // Different paragraphs on each side are still a conflict kept in History, as before.
        var other = phone
        other.notes += "\nOnly here"
        other.timedNotes = NoteTimeline.anchors(other.timedNotes, text: other.notes)
        let ancestor = Meeting(id: id, title: "Design review", notes: "Agenda", timedNotes: [agenda])
        XCTAssertTrue(MeetingMerge.merge(base: ancestor, local: mac, remote: other).meeting.revisions.contains { $0.field == "sync:notes" })
    }

    func testAnEditOrDeleteOnOneDeviceReachesTheOtherThroughSync() {
        let id = UUID(), note = SharedNote(id: UUID(), text: "Launch on the 14th", time: 10)
        var both = Meeting(id: id, title: "Design review")
        both.applySharedNote(note)
        var edited = both
        edited.applySharedNote(SharedNote(id: note.id, text: "Launch on the 21st", time: 10))
        XCTAssertEqual(MeetingMerge.merge(base: both, local: both, remote: edited).meeting.notes, "Launch on the 21st")
        var deleted = both
        deleted.applySharedNote(SharedNote(id: note.id, text: "", time: nil, deleted: true))
        XCTAssertEqual(MeetingMerge.merge(base: both, local: deleted, remote: both).meeting.notes, "")
        let mark = Highlight(time: 12)
        var marked = both
        marked.addSharedBookmark(mark)
        var unmarked = marked
        unmarked.applySharedBookmarkChange(id: mark.id, label: nil, deleted: true)
        XCTAssertTrue(MeetingMerge.merge(base: marked, local: marked, remote: unmarked).meeting.highlights.isEmpty, "a delete propagates")
    }

    // MARK: A recorder's live audio and its own file

    private func track(_ id: String, serial: String? = "SN1", sha: String) -> RecordingTrack {
        RecordingTrack(source: .soundcore, relativePath: "Originals/\(sha).wav", fileName: "\(sha).wav", sha256: sha,
                       device: DeviceRecordingIdentity(kind: "soundcore.work", serial: serial, recordingID: id))
    }

    func testARecordersOwnFileReplacesItsLiveAudioForTranscriptionAndFusion() {
        let portion = track("1729000000~live", sha: "live"), whole = track("1729000000", sha: "file")
        let other = track("1729009999~live", sha: "other-live"), elsewhere = track("1729000000", serial: "SN2", sha: "elsewhere")
        var meeting = Meeting(title: "Shared", tracks: [portion, other])
        XCTAssertTrue(portion.isLivePortion)
        XCTAssertEqual(portion.wholeRecordingIdentity?.recordingID, "1729000000")
        XCTAssertEqual(meeting.transcribableTracks.map(\.id), [portion.id, other.id], "live audio alone is transcribed")
        meeting.tracks.append(elsewhere)
        XCTAssertTrue(meeting.supersededLivePortions.isEmpty, "another recorder's recording isn't its file")
        meeting.tracks.append(whole)
        XCTAssertEqual(meeting.supersededLivePortions, [portion.id: whole.id])
        XCTAssertEqual(Set(meeting.transcribableTracks.map(\.id)), [other.id, elsewhere.id, whole.id])

        // A transcript of the live audio made before the file arrived isn't fused once the file is transcribed.
        let words = "Thanks everyone for joining the quarterly planning review today"
        func transcript(_ track: UUID, created: TimeInterval) -> TrackTranscript {
            TrackTranscript(trackID: track, segments: [TranscriptSegment(trackID: track, start: 0, end: 4, text: words, confidence: 0.9)],
                            createdAt: Date(timeIntervalSince1970: created))
        }
        let tracks = [RecordingTrack(id: portion.id, source: .soundcore, relativePath: "a", fileName: "a", offset: 0, sha256: "live",
                                     device: portion.device),
                      RecordingTrack(id: whole.id, source: .soundcore, relativePath: "b", fileName: "b", offset: 0, sha256: "file",
                                     device: whole.device)]
        let result = TranscriptFusion.fuse([transcript(portion.id, created: 1), transcript(whole.id, created: 2)], tracks: tracks,
                                           inputs: FusionInputs())
        XCTAssertEqual(Set(result.segments.map(\.trackID)), [whole.id], "only the recorder's file")
        let report = result.summary?.sources.first { $0.trackID == portion.id }
        XCTAssertEqual(report?.note, "Replaced by the recorder’s own file.")
    }

    func testTheRecordersFileWithTheLiveAudiosBytesBecomesThatTrack() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookLive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try MeetingStore(rootURL: root)
        let audio = root.appendingPathComponent("recording.wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data((0..<4_000).map { UInt8($0 % 251) }).write(to: audio)
        let live = DeviceRecordingIdentity(kind: "soundcore.work", serial: "SN1", recordingID: "1729000000~live")
        let whole = DeviceRecordingIdentity(kind: "soundcore.work", serial: "SN1", recordingID: "1729000000")
        var meeting = try await store.importAudio(from: audio, into: Meeting(title: "Shared"), source: .soundcore, device: live)
        meeting = try await store.importAudio(from: audio, into: meeting, source: .soundcore, device: whole)
        XCTAssertEqual(meeting.tracks.count, 1, "one track")
        XCTAssertEqual(meeting.tracks[0].device, whole, "named for the whole recording")

        // Another recording's identity never renames it.
        let unrelated = DeviceRecordingIdentity(kind: "soundcore.work", serial: "SN1", recordingID: "1729005555")
        meeting = try await store.importAudio(from: audio, into: meeting, source: .soundcore, device: unrelated)
        XCTAssertEqual(meeting.tracks.map(\.device), [whole])
    }
}
