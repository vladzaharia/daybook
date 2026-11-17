import DaybookTestSupport
import XCTest
@testable import DaybookCore

/// Merging conversations (`ConversationMerge`): where each one's timeline lands on the merged one, and what it brings
/// with it: recordings on their copies, every transcript run with its words, one speaker per person, the corrections
/// the person made, bookmarks, photos, notes, and tags. Values only; the library's half (files, the Trash) is DaybookKit's.
final class ConversationMergeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_780_000_000)

    /// A conversation recorded on this Mac at `date`: its microphone, at the timeline's zero, `seconds` long.
    private func recorded(_ title: String, at date: Date, seconds: TimeInterval) -> Meeting {
        let mic = RecordingTrack(source: .microphone, relativePath: "Originals/\(UUID().uuidString).wav", fileName: "\(title).wav",
                                 createdAt: date, duration: seconds, offset: 0, sha256: UUID().uuidString, startedAt: date)
        return Meeting(title: title, date: date, tracks: [mic])
    }

    /// The survivor with copies of `folded`'s recordings appended, as the library's import makes them, and the map.
    private func copying(_ folded: Meeting, into merged: inout Meeting) -> [UUID: UUID] {
        var copies: [UUID: UUID] = [:]
        for track in folded.tracks where !track.isMovedOut {
            let copy = RecordingTrack(source: track.source, relativePath: "Originals/\(UUID().uuidString).wav", fileName: "copy.wav",
                                      sha256: track.sha256)
            merged.tracks.append(copy)
            copies[track.id] = copy.id
        }
        return copies
    }

    private func fold(_ folded: Meeting, into merged: inout Meeting, placement: ConversationMerge.Placement,
                      profiles: SpeakerProfileMerges? = nil) -> [UUID: UUID] {
        let copies = copying(folded, into: &merged)
        ConversationMerge.fold(folded, into: &merged, placement: placement, copies: copies, fresh: Set(copies.values), profiles: profiles, at: start)
        return copies
    }

    func testBehaviorTheEarliestSurvivesAndTheRestFollowByDate() {
        let later = recorded("Later", at: start.addingTimeInterval(7_200), seconds: 60)
        let earliest = recorded("Earliest", at: start, seconds: 60)
        let middle = recorded("Middle", at: start.addingTimeInterval(3_600), seconds: 60)
        XCTAssertEqual(ConversationMerge.ordered([later, earliest, middle]).map(\.title), ["Earliest", "Middle", "Later"])
    }

    // MARK: Placement

    func testBehaviorAConversationRecordedAtAnotherTimeFollowsTheOneBeforeItKeepingItsRecordingsPlaces() throws {
        let survivor = recorded("Standup", at: start, seconds: 600)
        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300)
        // A recorder the sound placed 5 s in, at its own clock rate, and a bookmark and a note on the conversation's clock.
        let recorder = RecordingTrack(source: .soundcore, relativePath: "Originals/r.wav", fileName: "r.wav", duration: 290, sha256: "r",
                                      alignment: SourceAlignment(method: .audio, offset: 5, rate: 1.0002, confidence: 0.9))
        later.tracks.append(recorder)
        later.highlights = [Highlight(time: 10, text: "On the timeline"), Highlight(trackID: recorder.id, time: 4, text: "On the recorder")]
        later.notes = "Pricing first"
        later.timedNotes = [TimedNote(time: 20, text: "Pricing first")]
        later.photos = [MeetingPhoto(relativePath: "Originals/Photos/p.jpg", fileName: "p.jpg", sha256: "p", capturedAt: start, time: 30)]

        let placements = ConversationMerge.placements([later, survivor])
        XCTAssertEqual(placements[later.id], .init(kind: .after, shift: 600), "right where the survivor's recording ends")

        var merged = survivor
        let copies = copying(later, into: &merged)
        let photo = try XCTUnwrap(later.photos?.first)
        ConversationMerge.fold(later, into: &merged, placement: placements[later.id]!, copies: copies, fresh: Set(copies.values),
                               photos: [photo.id: photo], at: start)
        let mic = try XCTUnwrap(merged.tracks.first { $0.id == copies[later.tracks[0].id] })
        let copiedRecorder = try XCTUnwrap(merged.tracks.first { $0.id == copies[recorder.id] })
        XCTAssertEqual(mic.alignment?.method, .manual, "placed as by hand: never compared by sound with the survivor's")
        XCTAssertEqual(mic.alignment?.offset, 600)
        XCTAssertEqual(copiedRecorder.alignment?.method, .manual)
        XCTAssertEqual(copiedRecorder.alignment?.offset, 605, "5 s after its microphone, as it was")
        XCTAssertEqual(copiedRecorder.alignment?.rate, 1.0002)
        XCTAssertEqual(merged.clock(of: copiedRecorder.id)?.offset, 605)
        XCTAssertEqual(copiedRecorder.source, .soundcore, "the copy is the same recording")
        XCTAssertEqual(copiedRecorder.mergedFrom, later.id)
        XCTAssertTrue(merged.wasMovedHere(copiedRecorder.id), "where the person filed it: never matched elsewhere")

        XCTAssertEqual(merged.highlights.first { $0.text == "On the timeline" }?.time, 610)
        XCTAssertNil(merged.highlights.first { $0.text == "On the timeline" }?.trackID)
        let onRecorder = try XCTUnwrap(merged.highlights.first { $0.text == "On the recorder" })
        XCTAssertEqual(onRecorder.trackID, copiedRecorder.id)
        XCTAssertEqual(onRecorder.time, 4, "in the recording's own time")
        XCTAssertEqual(merged.timedNotes?.first { $0.text == "Pricing first" }?.time, 620)
        XCTAssertEqual(merged.photos?.first?.time, 630)
    }

    func testBehaviorARecordingOfTheSameConversationWaitsForTheSoundFromWhereTheClocksPutIt() throws {
        let survivor = recorded("Design review", at: start, seconds: 1_800)
        var phone = recorded("iPhone recording", at: start.addingTimeInterval(120), seconds: 900)
        phone.highlights = [Highlight(time: 50, text: "Pricing")]
        phone.notes = "Ask about the launch"
        phone.timedNotes = [TimedNote(time: 40, text: "Ask about the launch")]

        let placements = ConversationMerge.placements([survivor, phone])
        XCTAssertEqual(placements[phone.id], .init(kind: .alongside, shift: 120))
        var merged = survivor
        let copies = fold(phone, into: &merged, placement: placements[phone.id]!)
        let copy = try XCTUnwrap(merged.tracks.first { $0.id == copies[phone.tracks[0].id] })
        let alignment = try XCTUnwrap(copy.alignment)
        XCTAssertTrue(alignment.isPending, "lined up from the sound when it's processed, as an added recording is")
        XCTAssertNil(alignment.audioChecked)
        XCTAssertEqual(alignment.clockOffset, 120, "the clocks' estimate is the prior")
        XCTAssertNil(merged.clock(of: copy.id))
        // Its notes wait with its recording and move with it; a bookmark on its timeline is on its recording.
        let note = try XCTUnwrap(merged.timedNotes?.first { $0.text == "Ask about the launch" })
        XCTAssertEqual(alignment.heldNoteIDs, [note.id])
        XCTAssertEqual(note.time, 160, "about right meanwhile")
        XCTAssertEqual(merged.highlights.first?.trackID, copy.id)
        XCTAssertEqual(merged.highlights.first?.time, 50)

        // The sound puts it 118.5 s in: the note follows.
        var placed = alignment
        placed.method = .audio; placed.offset = 118.5; placed.confidence = 0.9
        merged.applyPlacements([copy.id: placed])
        XCTAssertEqual(merged.timedNotes?.first { $0.id == note.id }?.time ?? 0, 158.5, accuracy: 0.001)
        XCTAssertEqual(merged.alignedTime(for: merged.highlights[0]), 168.5)
    }

    func testBehaviorOneRecordedAlongsideALaterOneWaitsForPhrasesThenClocksButNeverTheSound() throws {
        func said(_ text: String, in meeting: inout Meeting) {
            let track = meeting.tracks[0].id
            meeting.transcripts = [TrackTranscript(trackID: track, segments: [TranscriptSegment(trackID: track, start: 1, end: 4, text: text)])]
        }
        var survivor = recorded("Standup", at: start, seconds: 600)
        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300)
        var alongside = recorded("Planning on iPhone", at: start.addingTimeInterval(3_660), seconds: 200)
        said("Morning everyone", in: &survivor)
        said("Budget review first", in: &later)
        said("Hiring after lunch", in: &alongside)
        let placements = ConversationMerge.placements([alongside, later, survivor])
        XCTAssertEqual(placements[later.id], .init(kind: .after, shift: 600))
        XCTAssertEqual(placements[alongside.id], .init(kind: .alongsideLater, shift: 660), "60 s into the later one, by the clocks")

        var merged = survivor
        _ = fold(later, into: &merged, placement: placements[later.id]!)
        let copies = fold(alongside, into: &merged, placement: placements[alongside.id]!)
        let alignment = try XCTUnwrap(merged.tracks.first { $0.id == copies[alongside.tracks[0].id] }?.alignment)
        XCTAssertTrue(alignment.isPending)
        XCTAssertEqual(alignment.audioChecked, true, "the survivor's recording, what the sound would compare it with, was made at another time")
        XCTAssertEqual(alignment.clockOffset, 660)

        // Nothing shared: the clocks place it.
        let settled = SourceFusion.fuse(merged).settled
        XCTAssertEqual(settled[copies[alongside.tracks[0].id]!]?.method, .clock)
        XCTAssertEqual(settled[copies[alongside.tracks[0].id]!]?.offset, 660)
    }

    // MARK: What comes along

    func testBehaviorEveryRunComesAlongWithItsWordsAndTheCorrectionsSurviveFusion() throws {
        let survivor = recorded("Standup", at: start, seconds: 60)
        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 40)
        let trackID = later.tracks[0].id
        let words = [TranscriptWord(text: "Welcome", start: 0, end: 0.5), TranscriptWord(text: "to", start: 0.5, end: 0.7),
                     TranscriptWord(text: "pricing", start: 0.7, end: 1.2)]
        let older = TrackTranscript(trackID: trackID, segments: [TranscriptSegment(trackID: trackID, start: 0, end: 4, text: "Welcome to pricing")],
                                    modelID: "old", createdAt: start, words: words)
        let newer = TrackTranscript(trackID: trackID, segments: [TranscriptSegment(trackID: trackID, start: 0, end: 4, text: "Welcome to prizing")],
                                    modelID: "new", createdAt: start.addingTimeInterval(60), words: words)
        later.transcripts = [older, newer]
        later.applyFusion(SourceFusion.fuse(later).fusion)
        let passage = try XCTUnwrap(later.unifiedTranscript.first)
        later.correctSegment(id: passage.id, text: "Welcome to pricing.")

        var merged = survivor
        let copies = fold(later, into: &merged, placement: ConversationMerge.placements([survivor, later])[later.id]!)
        let copy = try XCTUnwrap(copies[trackID])
        XCTAssertEqual(merged.transcripts.filter { $0.trackID == copy }.map(\.modelID), ["old", "new"], "every run, the earlier ones too")
        XCTAssertEqual(merged.transcripts.first { $0.modelID == "old" }?.words, words, "with its words, to compare with")
        XCTAssertTrue(merged.correctedSegmentIDs.contains(passage.id))
        XCTAssertEqual(merged.unifiedTranscript.first { $0.id == passage.id }?.start, 60, "on the merged timeline")

        merged.applyFusion(SourceFusion.fuse(merged).fusion)
        XCTAssertEqual(merged.unifiedTranscript.first { $0.trackID == copy }?.text, "Welcome to pricing.", "the correction carries over")
        XCTAssertNil(merged.correctionTransferIssues)
    }

    func testBehaviorThePersonRecordingIsOneAndANamedPersonInBothIsOneSpeaker() throws {
        var survivor = recorded("Standup", at: start, seconds: 60)
        let mine = survivor.tracks[0].id
        survivor.speakers = [Speaker(id: "owner", name: "Me", sourceTrackID: mine), Speaker(id: "run1:S1", name: "Speaker 2", sourceTrackID: mine),
                             Speaker(id: "S0", name: "Priya", sourceTrackID: mine)]
        survivor.transcripts = [TrackTranscript(trackID: mine, segments: [
            TranscriptSegment(trackID: mine, start: 0, end: 5, text: "Morning", speakerID: "owner"),
            TranscriptSegment(trackID: mine, start: 5, end: 9, text: "Hello there", speakerID: "run1:S1"),
            TranscriptSegment(trackID: mine, start: 9, end: 12, text: "Ready", speakerID: "S0"),
        ])]
        survivor.renameSpeaker(id: "run1:S1", name: "Dana")

        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 60)
        let theirs = later.tracks[0].id
        later.speakers = [Speaker(id: "owner", name: "Me", sourceTrackID: theirs, embedding: [1, 0], embeddingModelID: "voices"),
                          Speaker(id: "run2:S1", name: "Speaker 2", sourceTrackID: theirs),
                          Speaker(id: "run2:S2", name: "Speaker 3", sourceTrackID: theirs),
                          Speaker(id: "S0", name: "Speaker 4", sourceTrackID: theirs)]
        later.transcripts = [TrackTranscript(trackID: theirs, segments: [
            TranscriptSegment(trackID: theirs, start: 0, end: 5, text: "Let's plan", speakerID: "owner"),
            TranscriptSegment(trackID: theirs, start: 5, end: 9, text: "Budget first", speakerID: "run2:S1"),
            TranscriptSegment(trackID: theirs, start: 9, end: 12, text: "Agreed", speakerID: "run2:S2"),
            TranscriptSegment(trackID: theirs, start: 12, end: 15, text: "Me too", speakerID: "S0"),
        ])]
        later.renameSpeaker(id: "owner", name: "Vlad")
        later.renameSpeaker(id: "run2:S1", name: "dana")
        later.renameSpeaker(id: "S0", name: "Omar")
        later.setSpeakerIdentity(SpeakerIdentity(speakerID: "run2:S1", profileID: SpeakerProfile.id(forName: "Dana"), source: .named), for: "run2:S1")

        var merged = survivor
        let copies = fold(later, into: &merged, placement: ConversationMerge.placements([survivor, later])[later.id]!)
        let run = try XCTUnwrap(merged.transcripts.first { $0.trackID == copies[theirs] })
        XCTAssertEqual(merged.speakers.filter { $0.id == "owner" }.map(\.name), ["Me"], "one owner, the survivor's name")
        XCTAssertEqual(merged.speakers.first { $0.id == "owner" }?.embedding, [1, 0], "with the voice it lacked")
        XCTAssertEqual(run.segments.first { $0.text == "Let's plan" }?.speakerID, "owner")
        XCTAssertEqual(merged.speakers.filter { $0.name == "Dana" }.count, 1, "Dana is one speaker")
        XCTAssertEqual(run.segments.first { $0.text == "Budget first" }?.speakerID, "run1:S1")
        XCTAssertEqual(merged.speakerIdentity("run1:S1")?.profileID, SpeakerProfile.id(forName: "Dana"), "who she is comes too")
        // Another person whose ID the survivor already uses keeps their name under an ID of their own.
        let omar = try XCTUnwrap(merged.speakers.first { $0.name == "Omar" })
        XCTAssertNotEqual(omar.id, "S0")
        XCTAssertEqual(run.segments.first { $0.text == "Me too" }?.speakerID, omar.id)
        XCTAssertEqual(merged.speakers.first { $0.id == "S0" }?.name, "Priya")
        XCTAssertTrue(merged.renamedSpeakerIDs.contains(omar.id), "the name the person gave is still theirs")
        // A number Daybook gave goes on from the survivor's.
        let unnamed = try XCTUnwrap(merged.speakers.first { $0.id == "run2:S2" })
        XCTAssertEqual(unnamed.name, "Speaker \(merged.speakers.firstIndex { $0.id == "run2:S2" }! + 1)")
        XCTAssertEqual(unnamed.sourceTrackID, copies[theirs])
        // The rename of the owner stays in Version History, about no speaker here.
        XCTAssertTrue(merged.revisions.contains { $0.kind == .speaker("\(later.id.uuidString):owner") && $0.newValue == "Vlad" })
        XCTAssertFalse(merged.renamedSpeakerIDs.contains("owner"), "the survivor's name for the owner stands")
    }

    func testBehaviorTheSameVoiceProfileUnderTwoNamesIsOneSpeakerWithTheSurvivorsName() throws {
        let alex = UUID()
        var survivor = recorded("Standup", at: start, seconds: 60)
        let mine = survivor.tracks[0].id
        survivor.speakers = [Speaker(id: "a", name: "Alex", sourceTrackID: mine)]
        survivor.setSpeakerIdentity(SpeakerIdentity(speakerID: "a", profileID: alex, source: .named), for: "a")
        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 60)
        let theirs = later.tracks[0].id
        later.speakers = [Speaker(id: "b", name: "Alexander", sourceTrackID: theirs)]
        later.transcripts = [TrackTranscript(trackID: theirs, segments: [TranscriptSegment(trackID: theirs, start: 0, end: 3, text: "Hi", speakerID: "b")])]
        later.setSpeakerIdentity(SpeakerIdentity(speakerID: "b", profileID: alex, source: .recognized, appliedName: "Alexander"), for: "b")

        var merged = survivor
        _ = fold(later, into: &merged, placement: ConversationMerge.placements([survivor, later])[later.id]!)
        XCTAssertEqual(merged.speakers.map(\.name), ["Alex"])
        XCTAssertEqual(merged.transcripts.flatMap(\.segments).first { $0.text == "Hi" }?.speakerID, "a")
    }

    func testBehaviorNotesFollowInOrderTagsJoinAndVersionHistorySaysWhatMerged() throws {
        var survivor = recorded("Standup", at: start, seconds: 60)
        survivor.notes = "Agenda\n"
        survivor.tags = ["Launch", "pricing"]
        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 60)
        later.notes = "Follow up with Dana"
        later.tags = ["launch", "Q3"]
        let ink = NoteInk(drawing: Data([1, 2, 3]), width: 300, height: 80, recognized: "Sketch")
        later.addInk(ink, after: nil)

        var merged = survivor
        let placement = ConversationMerge.placements([survivor, later])[later.id]!
        _ = fold(later, into: &merged, placement: placement)
        XCTAssertEqual(merged.notes, "Agenda\n\nFollow up with Dana\nSketch")
        XCTAssertEqual(merged.tags, ["Launch", "pricing", "Q3"])
        XCTAssertEqual(merged.ink?.map(\.id), [ink.id])
        XCTAssertEqual(merged.inkPlacements().compactMap { $0?.id }, [ink.id], "the handwriting keeps its paragraph")
        XCTAssertEqual(merged.revisions.last?.newValue, "Merged “Planning”")
        XCTAssertTrue(ConversationMerge.hasFolded(later.id, into: merged))
        XCTAssertEqual(merged.title, "Standup")

        // Folding it again changes nothing: a merge asked for again finds it in.
        let once = merged
        ConversationMerge.fold(later, into: &merged, placement: placement, copies: [:], fresh: [])
        XCTAssertEqual(merged, once)
    }

    // MARK: Sync

    func testBehaviorSyncCountsARecordingMovedToTheConversationItWasMergedIntoOnce() async throws {
        let root = makeTemporaryFolder("DaybookMergeSync")
        let local = root.appendingPathComponent("A")
        let audio = root.appendingPathComponent("audio.wav")
        try Data("the same recording".utf8).write(to: audio)
        let store = try MeetingStore(rootURL: local)
        let survivor = try await store.importAudio(from: audio, into: Meeting(title: "Standup"))
        var folded = try await store.importAudio(from: audio, into: Meeting(title: "Planning"))
        let engine = try LibrarySyncEngine(localRoot: local, remoteRoot: root.appendingPathComponent("Remote"), deviceID: "A",
                                           replica: SyncReplicaConfiguration())
        let warning = "The same recording is in more than one conversation. They stay separate."
        let separate = try await engine.synchronize(meetings: [survivor, folded])
        XCTAssertTrue(separate.warnings.contains(warning), "two conversations holding one recording is worth knowing")
        // Merged: the folded one's recording is marked moved to the survivor until it's in the Trash.
        folded.tracks[0].removal = RecordingRemoval(removedAt: start, movedTo: survivor.id)
        let merged = try await engine.synchronize(meetings: [survivor, folded])
        XCTAssertFalse(merged.warnings.contains(warning))
    }
}
