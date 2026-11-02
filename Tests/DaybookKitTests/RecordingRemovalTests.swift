import DaybookCore
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookKit

/// Taking a recording out of a conversation (Info › Audio on both apps): Remove Recording… marks it, so it leaves
/// the transcript and processing but stays in the library to put back, and the mark syncs; Move to New Conversation
/// gives it a conversation of its own with its transcript, names, corrections, and bookmarks. Synthetic files in a
/// temporary library; nothing is transcribed.
@MainActor
final class RecordingRemovalTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = makeTemporaryFolder("DaybookRecordingRemoval")
    }

    private func open() async throws -> LibraryController {
        let library = LibraryController(rootURL: root.appendingPathComponent("Library"), sync: nil)
        try await library.load()
        return library
    }

    private func undoManager() -> UndoManager {
        let undo = UndoManager()
        undo.groupsByEvent = false
        return undo
    }

    private func grouped(_ undo: UndoManager, _ action: () async throws -> Void) async rethrows {
        undo.beginUndoGrouping()
        try await action()
        undo.endUndoGrouping()
    }

    /// A file of distinct bytes; nothing reads it as audio.
    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data((name + UUID().uuidString).utf8).write(to: url)
        return url
    }

    /// A conversation of two recordings, the microphone (Alex, then Sam, whom the person named) and a dropped file
    /// (a stranger), each transcribed and fused; a bookmark on each (the microphone's near enough to the file's
    /// passage that the file's words are around it), and a correction to the file's passage.
    private func twoRecordings(_ library: LibraryController) async throws -> (id: UUID, mic: UUID, file: UUID, corrected: UUID) {
        let id = library.newMeeting(title: "Weekly sync")
        await library.acquireLock()
        let mic = try await library.ingest(try file("mic.wav"), into: id, provenance: .file(source: .microphone))
        let dropped = try await library.ingest(try file("Interview.m4a"), into: id, provenance: .file(source: .imported))
        library.releaseLock()
        let micID = try XCTUnwrap(mic.track?.id), fileID = try XCTUnwrap(dropped.track?.id)
        let micRun = UUID(), fileRun = UUID()
        library.update(id) { meeting in
            // Placed one after the other, as their start times would.
            for index in meeting.tracks.indices { meeting.tracks[index].offset = meeting.tracks[index].id == micID ? 0 : 60 }
            meeting.transcripts = [
                TrackTranscript(id: micRun, trackID: micID, segments: [
                    TranscriptSegment(trackID: micID, start: 0, end: 30, text: "Shall we start with the launch?", speakerID: "alex"),
                    TranscriptSegment(trackID: micID, start: 30, end: 50, text: "The dates hold for now.", speakerID: "sam"),
                ]),
                TrackTranscript(id: fileRun, trackID: fileID, segments: [
                    TranscriptSegment(trackID: fileID, start: 0, end: 40, text: "Welcome to the interview about pricing.", speakerID: "guest"),
                ]),
            ]
            meeting.speakers = [Speaker(id: "alex", name: "Alex", sourceTrackID: micID), Speaker(id: "sam", name: "Speaker 2", sourceTrackID: micID),
                                Speaker(id: "guest", name: "Speaker 3", sourceTrackID: fileID)]
            meeting.highlights = [Highlight(trackID: micID, time: 5, text: "Launch"), Highlight(trackID: fileID, time: 12, text: "Pricing")]
            meeting.renameSpeaker(id: "sam", name: "Sam")
            meeting.renameSpeaker(id: "guest", name: "Dana")
        }
        await library.realign(id)
        let passage = try XCTUnwrap(library.meeting(id)?.unifiedTranscript.first { $0.text.contains("interview") })
        library.correctPassage(passage.id, text: "Welcome to the interview about prices.", in: id)
        return (id, micID, fileID, passage.id)
    }

    func testBehaviorRemovingARecordingTakesItOutOfTheTranscriptButKeepsItToPutBack() async throws {
        let library = try await open()
        let (id, mic, dropped, _) = try await twoRecordings(library)
        let undo = undoManager()

        await grouped(undo) { XCTAssertTrue(library.removeRecording(dropped, from: id, undoManager: undo)) }
        var meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(meeting.tracks.count, 2, "the original stays in the conversation")
        XCTAssertEqual(meeting.presentTracks.map(\.id), [mic])
        XCTAssertEqual(meeting.removedTracks.map(\.id), [dropped])
        XCTAssertFalse(meeting.transcribableTracks.contains { $0.id == dropped }, "it isn't transcribed again")
        XCTAssertEqual(meeting.revisions.last?.newValue, "Removed “Interview.m4a”")
        await library.realign(id)
        meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertFalse(meeting.unifiedTranscript.contains { $0.trackID == dropped }, "its words leave the transcript")
        XCTAssertEqual(meeting.peopleSpeakers.map(\.speaker.name), ["Alex", "Sam"], "nor is its speaker one of the people")
        XCTAssertNil(meeting.peopleLine?.range(of: "Dana"))
        // Its bookmark goes with it, from the lists and from what the summary written again is given, with its words.
        XCTAssertEqual(meeting.presentHighlights.map(\.text), ["Launch"])
        XCTAssertEqual(meeting.highlights.count, 2, "kept, to come back with it")
        XCTAssertEqual(MeetingTimelineItem.items(in: meeting).filter { if case .highlight = $0 { true } else { false } }.count, 1)
        let evidence = try XCTUnwrap(MeetingEvidence.highlights(meeting))
        XCTAssertTrue(evidence.contains("Launch"))
        XCTAssertFalse(evidence.contains("Pricing"), "its bookmark isn't given to the summary")
        XCTAssertFalse(evidence.contains("interview"), "nor are its words")

        undo.undo()
        await library.realign(id)
        meeting = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(Set(meeting.presentTracks.map(\.id)), [mic, dropped])
        XCTAssertTrue(meeting.unifiedTranscript.contains { $0.trackID == dropped }, "putting it back puts its words back")
        XCTAssertEqual(meeting.revisions.last?.newValue, "Put back “Interview.m4a”")
        XCTAssertEqual(meeting.presentHighlights.map(\.text), ["Launch", "Pricing"], "and its bookmark")
        let back = try XCTUnwrap(MeetingEvidence.highlights(meeting))
        XCTAssertTrue(back.contains("Pricing") && back.contains("interview"))
    }

    func testBehaviorARemovalAndAnotherDevicesWorkOnTheSameRecordingBothSurvive() throws {
        // Removed on the iPhone while the Mac transcribes it: the Mac writes the recording's timing as it finishes.
        let track = RecordingTrack(source: .imported, relativePath: "Originals/a.m4a", fileName: "a.m4a")
        let base = Meeting(title: "Sync", tracks: [track])
        var phone = base
        phone.tracks[0].removal = RecordingRemoval(removedAt: Date(timeIntervalSince1970: 1_000))
        var mac = base
        mac.tracks[0].duration = 42
        mac.tracks[0].offset = 3
        for merged in [MeetingMerge.merge(base: base, local: phone, remote: mac), MeetingMerge.merge(base: base, local: mac, remote: phone)] {
            XCTAssertEqual(merged.meeting.tracks[0].removal, phone.tracks[0].removal, "the removal survives the Mac's work")
            XCTAssertEqual(merged.meeting.tracks[0].duration, 42, "and the Mac's work survives the removal")
            XCTAssertEqual(merged.meeting.tracks[0].offset, 3)
            XCTAssertTrue(merged.warnings.isEmpty, "nothing conflicted")
            XCTAssertFalse(merged.meeting.revisions.contains { $0.field.hasPrefix("sync:") })
        }

        // Put back on one device while the other works on it: it's back, with the work.
        var removed = base
        removed.tracks[0].removal = phone.tracks[0].removal
        var putBack = removed
        putBack.tracks[0].removal = nil
        var working = removed
        working.tracks[0].duration = 42
        for merged in [MeetingMerge.merge(base: removed, local: putBack, remote: working), MeetingMerge.merge(base: removed, local: working, remote: putBack)] {
            XCTAssertNil(merged.meeting.tracks[0].removal)
            XCTAssertEqual(merged.meeting.tracks[0].duration, 42)
        }

        // Without a common ancestor (two devices made the same conversation), a mark on one side is kept.
        XCTAssertEqual(MeetingMerge.merge(base: nil, local: phone, remote: base).meeting.tracks[0].removal, phone.tracks[0].removal)
        XCTAssertEqual(MeetingMerge.merge(base: nil, local: base, remote: phone).meeting.tracks[0].removal, phone.tracks[0].removal)
    }

    func testBehaviorARemovalSyncsAndAnotherDevicesUnchangedCopyDoesntBringItBack() throws {
        let track = RecordingTrack(source: .imported, relativePath: "Originals/a.m4a", fileName: "a.m4a")
        let base = Meeting(title: "Sync", tracks: [track])
        var local = base
        local.tracks[0].removal = RecordingRemoval(removedAt: Date())
        let merged = MeetingMerge.merge(base: base, local: local, remote: base).meeting
        XCTAssertEqual(merged.tracks.count, 1)
        XCTAssertNotNil(merged.tracks[0].removal, "an unchanged copy elsewhere doesn't undo the removal")
        XCTAssertNotNil(MeetingMerge.merge(base: base, local: base, remote: local).meeting.tracks[0].removal)

        // The mark round-trips through the conversation's file.
        let data = try JSONEncoder().encode(local)
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: data).tracks[0].removal, local.tracks[0].removal)
    }

    func testBehaviorMovingARecordingGivesItAConversationWithItsWordsNamesAndBookmarks() async throws {
        let library = try await open()
        let (id, mic, dropped, corrected) = try await twoRecordings(library)
        let source = try XCTUnwrap(library.meeting(id))
        let undo = undoManager()
        var newID: UUID?
        try await grouped(undo) {
            newID = try await library.moveRecordingToNewConversation(dropped, from: id, audio: { track in
                try await library.audioURL(for: track, in: id)
            }, undoManager: undo)
        }
        let moved = try XCTUnwrap(newID.flatMap(library.meeting))
        XCTAssertEqual(moved.title, "Interview")
        XCTAssertEqual(moved.tracks.count, 1)
        let copy = try XCTUnwrap(moved.tracks.first)
        XCTAssertEqual(copy.sha256, source.tracks.first { $0.id == dropped }?.sha256, "the same recording")
        XCTAssertEqual(moved.transcripts.map(\.trackID), [copy.id], "its transcript came along, so it isn't transcribed again")
        XCTAssertFalse(moved.hasUntranscribedAudio)
        XCTAssertEqual(moved.peopleSpeakers.map(\.speaker.name), ["Dana"], "with the name the person gave")
        XCTAssertTrue(moved.revisions.contains { $0.field == "speaker:guest" }, "a name the person gave, as Version History keeps it")
        XCTAssertEqual(moved.highlights.map(\.trackID), [copy.id])
        XCTAssertEqual(moved.unifiedTranscript.first { $0.id == corrected }?.text, "Welcome to the interview about prices.",
                       "the correction made to its passage carries over")

        let left = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(left.presentTracks.map(\.id), [mic])
        XCTAssertEqual(left.tracks.first { $0.id == dropped }?.removal?.movedTo, newID)
        XCTAssertTrue(left.removedTracks.isEmpty, "a moved recording isn't one to put back")
        XCTAssertFalse(left.unifiedTranscript.contains { $0.trackID == dropped })
        XCTAssertEqual(left.revisions.last?.newValue, "Moved “Interview.m4a” to “Interview”")
        // Its bookmark is in its new conversation only, and neither it nor the recording's words stay behind.
        XCTAssertEqual(moved.presentHighlights.map(\.text), ["Pricing"])
        XCTAssertEqual(left.presentHighlights.map(\.text), ["Launch"])
        let evidence = try XCTUnwrap(MeetingEvidence.highlights(left))
        XCTAssertFalse(evidence.contains("Pricing"))
        XCTAssertFalse(evidence.contains("interview"))

        undo.undo()
        try await waitUntil("the new conversation goes to the Trash") { library.meeting(newID!) == nil }
        let back = try XCTUnwrap(library.meeting(id))
        XCTAssertEqual(Set(back.presentTracks.map(\.id)), [mic, dropped], "back where it was")
        XCTAssertTrue(library.trashedMeetingIDs().contains(newID!), "the conversation made for it is in the Trash")
        XCTAssertEqual(back.presentHighlights.map(\.text), ["Launch", "Pricing"], "with its bookmark")
        let restored = try XCTUnwrap(MeetingEvidence.highlights(back))
        XCTAssertTrue(restored.contains("Pricing") && restored.contains("interview"))
    }

    func testBehaviorTakingARecordingOutWritesTheSummaryAgainOnlyWhereThereWasOne() async throws {
        let library = try await open()
        let (id, _, dropped, _) = try await twoRecordings(library)
        let meeting = try XCTUnwrap(library.meeting(id))
        // Transcribed, with its summary stopped before it was written: nothing writes one.
        XCTAssertNil(LibraryController.processing(after: meeting, hadSummary: false))
        XCTAssertEqual(LibraryController.processing(after: meeting, hadSummary: true), .summaryOnly)
        // A recording not yet transcribed is transcribed, summary or not.
        var untranscribed = meeting
        untranscribed.transcripts.removeAll { $0.trackID == dropped }
        XCTAssertEqual(LibraryController.processing(after: untranscribed, hadSummary: false), .newAudio)
        // With every recording out, there's nothing to do.
        var emptied = meeting
        for index in emptied.tracks.indices { emptied.tracks[index].removal = RecordingRemoval(removedAt: Date()) }
        XCTAssertNil(LibraryController.processing(after: emptied, hadSummary: true))

        // It had a summary: removing a recording, and putting it back, each write it again.
        library.update(id) { $0.summary = MeetingSummary(overview: "They covered the launch and pricing.") }
        var heard: [(UUID, ProcessingRequest.Mode)] = []
        let changed: @MainActor (UUID, ProcessingRequest.Mode) -> Void = { heard.append(($0, $1)) }
        XCTAssertTrue(library.removeRecording(dropped, from: id, undoManager: nil, changed: changed))
        try await waitUntil("the conversation to be summarized again") { heard.count == 1 }
        XCTAssertTrue(library.putBackRecording(dropped, in: id, undoManager: nil, changed: changed))
        try await waitUntil("and again") { heard.count == 2 }
        XCTAssertEqual(heard.map(\.0), [id, id])
        XCTAssertEqual(heard.map(\.1), [.summaryOnly, .summaryOnly])
    }

    func testBehaviorAMovedRecordingsConversationIsSummarizedWhereTheOneItLeftWas() async throws {
        let library = try await open()
        let (id, mic, dropped, _) = try await twoRecordings(library)
        var heard: [UUID: ProcessingRequest.Mode] = [:]
        let changed: @MainActor (UUID, ProcessingRequest.Mode) -> Void = { heard[$0] = $1 }
        // No summary was written (it was stopped, say): neither conversation gets one.
        _ = try await library.moveRecordingToNewConversation(dropped, from: id, audio: { track in
            try await library.audioURL(for: track, in: id)
        }, undoManager: nil, changed: changed)
        XCTAssertTrue(heard.isEmpty)

        // It had one: the new conversation, transcribed already, is summarized; the one left has nothing in it.
        library.update(id) { $0.summary = MeetingSummary(overview: "They covered the launch.") }
        let second = try await library.moveRecordingToNewConversation(mic, from: id, audio: { track in
            try await library.audioURL(for: track, in: id)
        }, undoManager: nil, changed: changed)
        XCTAssertEqual(heard, [second: .summaryOnly])
    }

    func testBehaviorAMovedRecordingsAudioIsFoundInItsNewConversation() async throws {
        let library = try await open()
        let (id, _, dropped, _) = try await twoRecordings(library)
        let newID = try await library.moveRecordingToNewConversation(dropped, from: id, audio: { track in
            try await library.audioURL(for: track, in: id)
        }, undoManager: nil)
        // The conversation it left comes first, as a later one does in a library opened again.
        library.update(id) { $0.date = Date().addingTimeInterval(3_600) }
        await library.flush()
        let reopened = try await open()
        XCTAssertEqual(reopened.meetings.first?.id, id)
        let found = try await reopened.existingMeeting(containingAudioAt: root.appendingPathComponent("Interview.m4a"))
        XCTAssertEqual(found?.id, newID, "importing it again finds the conversation it moved to, which lists it")
        let stays = try await reopened.existingMeeting(containingAudioAt: root.appendingPathComponent("mic.wav"))
        XCTAssertEqual(stays?.id, id)
    }
}
