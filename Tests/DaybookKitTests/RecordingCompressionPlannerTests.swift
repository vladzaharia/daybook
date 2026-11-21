import DaybookCore
import Foundation
import XCTest
@testable import DaybookKit

/// The wiring of a Mac's compression pass (`RecordingCompressionPlanner`): which conversations it reads, which tracks
/// are this Mac's, and what keeps a conversation out (in use, the Trash, a voice profile, settings not yet synced, the
/// clock).
final class RecordingCompressionPlannerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func conversation(_ title: String, digest: Character, recordedBy device: String? = nil) -> Meeting {
        let then = now.addingTimeInterval(-60 * day)
        var track = RecordingTrack(source: .microphone, relativePath: "Originals/\(title).caf", fileName: "\(title).caf", createdAt: then,
                                   sha256: String(repeating: digest, count: 64))
        if let device { track.capture = TrackCaptureDetails(); track.capture?.deviceID = device }
        let segment = TranscriptSegment(trackID: track.id, start: 0, end: 1, text: "Hi", speakerID: "s1")
        var meeting = Meeting(title: title, date: then, updatedAt: then, tracks: [track],
                              transcripts: [TrackTranscript(trackID: track.id, segments: [segment], createdAt: then)],
                              unifiedTranscript: [segment], summary: MeetingSummary(overview: "Hi", createdAt: then),
                              speakers: [Speaker(id: "s1", name: "A")], status: .ready)
        meeting.updatedAt = then
        return meeting
    }

    private func inputs(_ meetings: [Meeting], change: (inout RecordingCompressionPlanner.Inputs) -> Void = { _ in }) -> RecordingCompressionPlanner.Inputs {
        var inputs = RecordingCompressionPlanner.Inputs(now: now, age: .after30Days, startsAt: now.addingTimeInterval(-day), settingsApplied: true,
                                                        everyDeviceCompresses: true, clockLooksAhead: false, thisDevice: "M", macs: [],
                                                        done: Set(meetings.map(\.id)))
        change(&inputs)
        return inputs
    }

    private func voiceprint(_ meeting: Meeting) -> Voiceprint {
        Voiceprint(id: "vp-\(meeting.id)", profileID: UUID(), origin: .named, vector: VoiceVector(space: "s", values: [1]), meetingID: meeting.id,
                   speakerID: "s1", trackID: meeting.tracks[0].id, speechSeconds: 30, recordedAt: now)
    }

    private func ids(_ meetings: [Meeting], _ inputs: RecordingCompressionPlanner.Inputs) -> Set<UUID> {
        Set(RecordingCompressionPlanner.candidates(meetings, inputs).map(\.meetingID))
    }

    func testBehaviorEachInputKeepsAConversationOut() {
        let a = conversation("a", digest: "a"), b = conversation("b", digest: "b")
        let all = [a, b]
        XCTAssertEqual(ids(all, inputs(all)), [a.id, b.id])
        XCTAssertEqual(ids(all, inputs(all) { $0.inUse = [a.id] }), [b.id])
        XCTAssertEqual(ids(all, inputs(all) { $0.trashed = [a.id] }), [b.id])
        XCTAssertEqual(ids(all, inputs(all) { $0.done = [b.id] }), [b.id])
        XCTAssertEqual(ids(all, inputs(all) { $0.upgradeOffered = [a.id] }), [b.id])
        XCTAssertEqual(ids(all, inputs(all) { $0.voiceprints = [self.voiceprint(a)] }), [b.id])
        XCTAssertEqual(ids(all, inputs(all) { $0.settingsApplied = false }), [], "the library's choices haven't arrived")
        XCTAssertEqual(ids(all, inputs(all) { $0.clockLooksAhead = true }), [])
        XCTAssertEqual(ids(all, inputs(all) { $0.age = .never }), [])
        XCTAssertEqual(ids(all, inputs(all) { $0.startsAt = self.now.addingTimeInterval(self.day) }), [])
        XCTAssertEqual(ids(all, inputs(all) { $0.everyDeviceCompresses = false }), [])
    }

    func testBehaviorAClockBehindTheLibraryStopsThePass() {
        let a = conversation("a", digest: "a")
        var future = conversation("b", digest: "b")
        future.revisions.append(.init(date: now.addingTimeInterval(day), kind: .notes, oldValue: "", newValue: "x"))
        XCTAssertEqual(ids([a, future], inputs([a, future])), [], "nothing, not even the old one")
    }

    func testBehaviorOnlyThisMacsTracksAreReadOldestFirst() {
        var older = conversation("older", digest: "a", recordedBy: "M")
        older.updatedAt = now.addingTimeInterval(-90 * day)
        let other = conversation("other", digest: "b", recordedBy: "Z")
        let newer = conversation("newer", digest: "c")
        let all = [newer, other, older]
        let found = RecordingCompressionPlanner.candidates(all, inputs(all) { $0.macs = [.init(id: "Z", lastSeen: self.now), .init(id: "A", lastSeen: self.now)] })
        // "newer" has no recorder: the smallest Mac ID ("A") runs it, not this one.
        XCTAssertEqual(found.map(\.meetingID), [older.id])
        XCTAssertEqual(found.first?.trackIDs, [older.tracks[0].id])
    }

    func testBehaviorAVoiceProfilesAudioStaysProtectedThroughMergesAndMoves() {
        let taught = conversation("taught", digest: "a")
        var merged = conversation("merged", digest: "m")
        var copy = taught.tracks[0]
        copy.id = UUID(); copy.mergedFrom = taught.id; copy.sha256 = String(repeating: "x", count: 64)
        merged.tracks.append(copy)
        // Moved out of the taught conversation into one of its own: the old one marks where it went.
        var source = conversation("source", digest: "s")
        // Another digest, so only the mark finds it (its bytes would too, here or before a later compression).
        let moved = conversation("moved", digest: "t")
        source.tracks[0].removal = RecordingRemoval(removedAt: now, movedTo: moved.id)
        let unrelated = conversation("unrelated", digest: "u")
        var sameBytes = conversation("same", digest: "u")
        sameBytes.tracks[0].sha256 = taught.tracks[0].sha256
        let learned = RecordingCompressionPlanner.learnedFrom([taught, merged, source, moved, unrelated, sameBytes],
                                                               voiceprints: [voiceprint(taught), voiceprint(source)])
        XCTAssertEqual(learned, [taught.id, merged.id, source.id, moved.id, sameBytes.id])
        // A voiceprint naming a conversation now in the Trash (merged away) still protects what it was merged into.
        let afterMerge = RecordingCompressionPlanner.learnedFrom([merged, unrelated], voiceprints: [voiceprint(taught)])
        XCTAssertEqual(afterMerge, [taught.id, merged.id])
    }

    func testBehaviorAMoveStaysProtectedAfterItsSourceIsDeleted() {
        var source = conversation("source", digest: "s")
        var moved = conversation("moved", digest: "t")
        let unrelated = conversation("unrelated", digest: "u")
        source.tracks[0].removal = RecordingRemoval(removedAt: now, movedTo: moved.id)
        moved.revisions.append(MeetingRevision(date: now.addingTimeInterval(-60 * day), field: RecordingRemoval.movedHereField(moved.tracks[0].id),
                                               oldValue: "", newValue: "Moved from “source”"))
        let print = voiceprint(source)
        // The source is in the Trash now: followed there.
        XCTAssertEqual(RecordingCompressionPlanner.learnedFrom([moved, unrelated], voiceprints: [print], lineage: [source]), [source.id, moved.id])
        // Gone from the Trash too, or never on this device: the move can't be followed from the conversation it left, so
        // every conversation a recording was moved into is protected while that voiceprint's conversation can't be found.
        XCTAssertEqual(RecordingCompressionPlanner.learnedFrom([moved, unrelated], voiceprints: [print]), [source.id, moved.id])
        // With every voiceprint's conversation found, only what descends from them.
        XCTAssertEqual(RecordingCompressionPlanner.learnedFrom([moved, unrelated], voiceprints: [voiceprint(unrelated)]), [unrelated.id])
        XCTAssertEqual(ids([moved, unrelated], inputs([moved, unrelated]) { $0.voiceprints = [print] }), [unrelated.id])
        XCTAssertEqual(ids([moved, unrelated], inputs([moved, unrelated]) { $0.voiceprints = [voiceprint(unrelated)] }), [moved.id])
    }

    func testBehaviorTheClockRule() {
        let lastPass = now.addingTimeInterval(-3_600)
        XCTAssertTrue(RecordingCompressionClock.trusts(now: now, lastPass: nil, newestOtherDevice: nil))
        XCTAssertTrue(RecordingCompressionClock.trusts(now: now, lastPass: lastPass, newestOtherDevice: now.addingTimeInterval(-day)))
        XCTAssertFalse(RecordingCompressionClock.trusts(now: now, lastPass: now.addingTimeInterval(-4 * day), newestOtherDevice: nil), "a jump")
        XCTAssertFalse(RecordingCompressionClock.trusts(now: now, lastPass: now.addingTimeInterval(2 * 3_600), newestOtherDevice: nil), "went back")
        XCTAssertFalse(RecordingCompressionClock.trusts(now: now, lastPass: lastPass, newestOtherDevice: now.addingTimeInterval(-8 * day)))
        // In the same boot, the wall clock must have moved as the continuous clock did: days off are fine, a jump isn't.
        XCTAssertTrue(RecordingCompressionClock.trusts(now: now, lastPass: now.addingTimeInterval(-5 * day), elapsed: 5 * day - 60, newestOtherDevice: nil))
        XCTAssertFalse(RecordingCompressionClock.trusts(now: now, lastPass: now.addingTimeInterval(-2 * day), elapsed: 3_600, newestOtherDevice: nil),
                       "two days ahead in an hour")
        XCTAssertFalse(RecordingCompressionClock.trusts(now: now, lastPass: now.addingTimeInterval(-60), elapsed: 3 * 3_600, newestOtherDevice: nil),
                       "set back")
        XCTAssertFalse(RecordingCompressionClock.trusts(now: now, lastPass: now.addingTimeInterval(-day), elapsed: day,
                                                        newestOtherDevice: now.addingTimeInterval(-8 * day)), "the others still count")
        let a = conversation("a", digest: "a")
        XCTAssertEqual(ids([a], inputs([a]) { $0.clockSteady = false }), [])
    }

    func testBehaviorARefusedRecordingIsntReadAgain() {
        let a = conversation("a", digest: "a")
        XCTAssertEqual(ids([a], inputs([a]) { $0.refused = [a.tracks[0].sha256] }), [])
    }

    func testBehaviorStillAllowedSeesWhatStartedSince() {
        let a = conversation("a", digest: "a")
        XCTAssertTrue(RecordingCompressionPlanner.stillAllowed(a, among: [a], inputs([a])))
        XCTAssertFalse(RecordingCompressionPlanner.stillAllowed(a, among: [a], inputs([a]) { $0.inUse = [a.id] }))
        XCTAssertFalse(RecordingCompressionPlanner.stillAllowed(a, among: [a], inputs([a]) { $0.age = .never }))
    }
}
