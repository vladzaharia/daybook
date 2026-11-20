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

    func testBehaviorAnswersToUnsureWordsFollowTheirRecordingsAndStillAnswerAfterTheMerge() throws {
        var survivor = recorded("Standup", at: start, seconds: 600)
        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300)
        let kept = TranscriptFlag(trackID: survivor.tracks[0].id, start: 12, end: 13, text: "Friday", reason: .lowConfidence)
        let asked = TranscriptFlag(trackID: later.tracks[0].id, start: 40, end: 41, text: "Kestrel", reason: .lowConfidence)
        survivor.transcriptFlagDismissals = [TranscriptFlagDismissal(flag: kept, outcome: .kept, at: start)]
        later.transcriptFlagDismissals = [TranscriptFlagDismissal(flag: asked, outcome: .kept, at: start)]

        var merged = survivor
        let placement = try XCTUnwrap(ConversationMerge.placements([later, survivor])[later.id])
        let copies = fold(later, into: &merged, placement: placement)
        let copyID = try XCTUnwrap(copies[later.tracks[0].id])
        let answers = try XCTUnwrap(merged.transcriptFlagDismissals)
        XCTAssertEqual(answers.count, 2, "the survivor's own answer stays")
        let moved = try XCTUnwrap(answers.first { $0.id == asked.id })
        XCTAssertEqual(moved.trackID, copyID)
        XCTAssertEqual(moved.start, 40, "in its recording's own time, wherever the recording lands")
        // The same words flagged again on the copy, as transcribing the merged conversation again finds them.
        let again = TranscriptFlag(trackID: copyID, start: 40.02, end: 41.01, text: "Kestrel", reason: .lowConfidence)
        XCTAssertEqual(TranscriptFlags.answered([again], by: answers), [again.id])

        // Folding the same conversation again adds nothing.
        ConversationMerge.fold(later, into: &merged, placement: placement, copies: copies, fresh: [], at: start)
        XCTAssertEqual(merged.transcriptFlagDismissals?.count, 2)
    }

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
        XCTAssertEqual(placements[later.id], .init(kind: .after, shift: 600, stretch: later.id), "right where the survivor's recording ends")

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
        XCTAssertEqual(placements[later.id], .init(kind: .after, shift: 600, stretch: later.id))
        XCTAssertEqual(placements[alongside.id], .init(kind: .alongsideLater, shift: 660, stretch: later.id), "60 s into the later one, by the clocks")

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

    func testBehaviorAConversationMergedIntoOneThatHoldsAMergeIsPlacedAgainstTheStretchItOverlaps() throws {
        let survivor = recorded("Morning", at: start, seconds: 1_800)
        let afternoon = recorded("Afternoon", at: start.addingTimeInterval(14_400), seconds: 1_800)
        var merged = survivor
        let first = ConversationMerge.placements([survivor, afternoon])[afternoon.id]!
        XCTAssertEqual(first, .init(kind: .after, shift: 1_800, stretch: afternoon.id))
        _ = fold(afternoon, into: &merged, placement: first)

        // Made alongside what was folded in (14:05 to 14:35): beside it, not after everything.
        let alongsideFolded = recorded("Afternoon on iPhone", at: start.addingTimeInterval(14_700), seconds: 1_800)
        XCTAssertEqual(ConversationMerge.placements([merged, alongsideFolded])[alongsideFolded.id], .init(kind: .alongsideLater, shift: 2_100, stretch: afternoon.id),
                       "5 min into the afternoon, which sits at 30 min")
        // Made at another time that the folded one's place on the timeline (30 to 60 min) must not make look like the morning's.
        let elsewhere = recorded("Midday", at: start.addingTimeInterval(2_400), seconds: 1_800)
        XCTAssertEqual(ConversationMerge.placements([merged, elsewhere])[elsewhere.id], .init(kind: .after, shift: 3_600, stretch: elsewhere.id),
                       "never compared by sound with the morning's recording")
        // Alongside the survivor's own recording: still the sound's.
        let alongsideOwn = recorded("Morning on iPhone", at: start.addingTimeInterval(120), seconds: 600)
        XCTAssertEqual(ConversationMerge.placements([merged, alongsideOwn])[alongsideOwn.id], .init(kind: .alongside, shift: 120))
    }

    func testBehaviorOneAlongsideAnEarlierFoldIsLinedUpAgainstARecordingOnItsOwnStretch() throws {
        var merged = recorded("Morning", at: start, seconds: 1_800)
        let afternoon = recorded("Afternoon", at: start.addingTimeInterval(14_400), seconds: 1_800)
        let copies = fold(afternoon, into: &merged, placement: ConversationMerge.placements([merged, afternoon])[afternoon.id]!)
        let afterCopy = try XCTUnwrap(copies[afternoon.tracks[0].id])
        // The morning's own recording is the one an iPhone made at the same time is lined up against, not one 4 hours later.
        let ownMic = merged.tracks[0].id
        XCTAssertEqual(merged.alignmentReference(onStretchOf: UUID())?.id, ownMic)
        XCTAssertEqual(merged.alignmentReference(excluding: [ownMic], onStretchOf: UUID())?.id, nil, "the folded one's isn't on the morning's stretch")
        XCTAssertEqual(merged.alignmentReference(onStretchOf: afterCopy)?.id, afterCopy, "its own stretch's reference is its own recording")
    }

    func testBehaviorAConversationThatHoldsAMergeKeepsWhatItPlacedAfterWhenItJoinsAnotherAlongside() throws {
        var held = recorded("Held", at: start.addingTimeInterval(60), seconds: 600)
        let evening = recorded("Evening", at: start.addingTimeInterval(36_000), seconds: 600)
        let eveningCopies = fold(evening, into: &held, placement: ConversationMerge.placements([held, evening])[evening.id]!)
        let survivor = recorded("Standup", at: start, seconds: 900)

        let placement = ConversationMerge.placements([survivor, held])[held.id]!
        XCTAssertEqual(placement, .init(kind: .alongside, shift: 60), "its own recording overlaps the survivor's")
        var merged = survivor
        let copies = fold(held, into: &merged, placement: placement)
        let own = try XCTUnwrap(merged.tracks.first { $0.id == copies[held.tracks[0].id] })
        XCTAssertTrue(own.alignment?.isPending == true, "lined up from the sound, as the survivor's overlap it")
        let later = try XCTUnwrap(merged.tracks.first { $0.id == copies[eveningCopies[evening.tracks[0].id]!] })
        XCTAssertEqual(later.alignment?.method, .manual, "made hours later: never offered to the sound")
        XCTAssertEqual(later.alignment?.offset, 60 + 600)
        XCTAssertEqual(later.mergedFrom, evening.id, "still the evening's")
        XCTAssertEqual(later.stretch, evening.id, "on the evening's stretch")
        XCTAssertNil(own.stretch, "the survivor's")
    }

    func testBehaviorACopyPlacedAlongsideALaterStretchStaysOnItSoAnotherIsPlacedByTheRealTimes() throws {
        var merged = recorded("Morning", at: start, seconds: 1_800)
        let afternoon = recorded("Afternoon", at: start.addingTimeInterval(18_000), seconds: 1_800)
        let afternoonCopies = fold(afternoon, into: &merged, placement: ConversationMerge.placements([merged, afternoon])[afternoon.id]!)
        let afternoonCopy = try XCTUnwrap(afternoonCopies[afternoon.tracks[0].id])
        XCTAssertEqual(merged.tracks.first { $0.id == afternoonCopy }?.stretch, afternoon.id, "placed after: the afternoon's stretch")
        // An iPhone recording of the afternoon, merged in next, waits to be lined up on the afternoon's stretch.
        let phone = recorded("Afternoon on iPhone", at: start.addingTimeInterval(18_300), seconds: 1_200)
        let placement = try XCTUnwrap(ConversationMerge.placements([merged, phone])[phone.id])
        XCTAssertEqual(placement.kind, .alongsideLater)
        let phoneCopies = fold(phone, into: &merged, placement: placement)
        let copy = try XCTUnwrap(merged.tracks.first { $0.id == phoneCopies[phone.tracks[0].id] })
        XCTAssertTrue(copy.alignment?.isPending == true)
        XCTAssertEqual(copy.stretch, afternoon.id, "on the afternoon's stretch while it waits, not the morning's")
        XCTAssertEqual(try JSONDecoder().decode(RecordingTrack.self, from: JSONEncoder().encode(copy)).stretch, afternoon.id, "kept as it's saved")
        XCTAssertEqual(merged.alignmentReference(onStretchOf: copy.id)?.id, afternoonCopy, "what it would be lined up against is the afternoon's")

        // Midday (11:40 to 12:20) is at a time neither stretch covers: the morning's isn't stretched to the afternoon's iPhone.
        let midday = recorded("Midday", at: start.addingTimeInterval(9_600), seconds: 2_400)
        XCTAssertEqual(ConversationMerge.placements([merged, midday])[midday.id]?.kind, .after, "never compared by sound with the morning's")
    }

    func testBehaviorAdjustingACopysTimingKeepsItOnItsStretch() throws {
        var merged = recorded("Morning", at: start, seconds: 1_800)
        let ownMic = merged.tracks[0].id
        let afternoon = recorded("Afternoon", at: start.addingTimeInterval(18_000), seconds: 1_800)
        let after = try XCTUnwrap(fold(afternoon, into: &merged, placement: ConversationMerge.placements([merged, afternoon])[afternoon.id]!)[afternoon.tracks[0].id])
        let phone = recorded("Morning on iPhone", at: start.addingTimeInterval(120), seconds: 600)
        let placement = try XCTUnwrap(ConversationMerge.placements([merged, phone])[phone.id])
        XCTAssertEqual(placement.kind, .alongside)
        let along = try XCTUnwrap(fold(phone, into: &merged, placement: placement)[phone.tracks[0].id])

        // Adjust Timing places the morning's iPhone copy by hand (as `LibraryController.setOffset` does): still the morning's.
        merged.applyPlacements([along: SourceAlignment(method: .manual, offset: 118)])
        XCTAssertNil(merged.tracks.first { $0.id == along }?.stretch)
        XCTAssertEqual(merged.alignmentReference(excluding: [ownMic], onStretchOf: ownMic)?.id, along, "a recording of the morning to line up against")

        // Clearing the afternoon copy's timing leaves it on the afternoon's stretch: the morning's isn't stretched to it.
        let index = try XCTUnwrap(merged.tracks.firstIndex { $0.id == after })
        merged.tracks[index].alignment = nil
        merged.tracks[index].offset = nil
        XCTAssertEqual(merged.tracks[index].stretch, afternoon.id)
        let own = try XCTUnwrap(ConversationMerge.stretches(of: merged, startOf: { $0.startedAt }).first(where: \.isOwn))
        XCTAssertEqual(own.span.end, start.addingTimeInterval(1_800))

        // Nor is it taken for one of the conversation's own captures and set waiting to be separated from them.
        merged.tracks[0].capture = TrackCaptureDetails()
        merged.tracks[index].capture = TrackCaptureDetails()
        merged.tracks[index].offset = 1_800
        XCTAssertNil(merged.separatingCaptureGroups(now: start)[after])
        XCTAssertEqual(merged.tracks[index].stretch, afternoon.id)
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
        XCTAssertEqual(unnamed.name, "Speaker 4", "goes on from the speakers here")
        XCTAssertEqual(unnamed.sourceTrackID, copies[theirs])
        // The rename of the owner stays in Version History, about no speaker here.
        XCTAssertTrue(merged.revisions.contains { $0.kind == .speaker("\(later.id.uuidString):owner") && $0.newValue == "Vlad" })
        XCTAssertFalse(merged.renamedSpeakerIDs.contains("owner"), "the survivor's name for the owner stands")
    }

    func testBehaviorANumberDaybookGaveNeverRepeatsOneTheSurvivorHas() throws {
        var survivor = recorded("Standup", at: start, seconds: 60)
        let mine = survivor.tracks[0].id
        survivor.speakers = [Speaker(id: "a", name: "Speaker 1", sourceTrackID: mine), Speaker(id: "b", name: "Speaker 3", sourceTrackID: mine)]
        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 60)
        let theirs = later.tracks[0].id
        later.speakers = [Speaker(id: "c", name: "Speaker 1", sourceTrackID: theirs), Speaker(id: "d", name: "Speaker 2", sourceTrackID: theirs)]
        later.transcripts = [TrackTranscript(trackID: theirs, segments: [
            TranscriptSegment(trackID: theirs, start: 0, end: 3, text: "Hi", speakerID: "c"),
            TranscriptSegment(trackID: theirs, start: 3, end: 6, text: "Hello", speakerID: "d"),
        ])]
        var merged = survivor
        _ = fold(later, into: &merged, placement: ConversationMerge.placements([survivor, later])[later.id]!)
        let names = merged.speakers.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "no two speakers are called the same: \(names)")
        XCTAssertEqual(names, ["Speaker 1", "Speaker 3", "Speaker 4", "Speaker 5"])
    }

    func testBehaviorACorrectionNeedingReviewIsShiftedOntoTheMergedTimeline() throws {
        let survivor = recorded("Standup", at: start, seconds: 60)
        var later = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 40)
        let trackID = later.tracks[0].id
        let passage = TranscriptSegment(trackID: trackID, start: 10, end: 14, text: "Welcome to pricing.")
        later.correctionTransferIssues = [CorrectionTransferIssue(originalSegment: passage, reason: "No passage matched")]
        var merged = survivor
        let copies = fold(later, into: &merged, placement: ConversationMerge.placements([survivor, later])[later.id]!)
        let issue = try XCTUnwrap(merged.correctionTransferIssues?.first)
        XCTAssertEqual(issue.originalSegment.start, 70, "10 s into the planning, which starts at 60")
        XCTAssertEqual(issue.originalSegment.end, 74)
        XCTAssertEqual(issue.originalSegment.trackID, copies[trackID])
    }

    func testBehaviorWhatWasTimedBeforeTheMergedTimelineBeginsIsKeptWhereTheModelAllowsIt() throws {
        let survivor = recorded("Standup", at: start, seconds: 600)
        var later = recorded("Planning", at: start.addingTimeInterval(-30), seconds: 600)
        later.tracks[0].offset = 20
        later.highlights = [Highlight(time: 5, text: "Before its recording"), Highlight(time: 40, text: "During it")]
        later.notes = "Early note"
        later.timedNotes = [TimedNote(time: 5, text: "Early note")]
        later.photos = [MeetingPhoto(relativePath: "Originals/Photos/p.jpg", fileName: "p.jpg", sha256: "p", capturedAt: start, time: 5)]
        var merged = survivor
        let copies = copying(later, into: &merged)
        let photo = try XCTUnwrap(later.photos?.first)
        ConversationMerge.fold(later, into: &merged, placement: .init(kind: .alongside, shift: -30), copies: copies, fresh: Set(copies.values),
                               photos: [photo.id: photo], at: start)
        // A note may sit before zero, as a passage another recording heard first does; a bookmark's time can't (the library
        // refuses it), so one before even its recording sits at zero; a photo then goes by when it was taken.
        XCTAssertEqual(merged.timedNotes?.first { $0.text == "Early note" }?.time, -25)
        XCTAssertEqual(merged.highlights.first { $0.text == "Before its recording" }?.time, 0)
        XCTAssertNil(merged.highlights.first { $0.text == "Before its recording" }?.trackID)
        XCTAssertEqual(merged.highlights.first { $0.text == "During it" }?.trackID, copies[later.tracks[0].id], "held by its recording")
        XCTAssertNil(merged.photos?.first?.time)
        XCTAssertTrue(merged.highlights.allSatisfy { $0.time >= 0 }, "the library can save it")
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

    /// A merge that stopped partway on one device, from a Daybook that left its copies in the conversation marked moved
    /// out to where they came from, and the same merge completed on another.
    private func waitingAndCompleted() throws -> (survivor: Meeting, folded: Meeting, waiting: Meeting, completed: Meeting, copyID: UUID) {
        let survivor = recorded("Standup", at: start, seconds: 600)
        var folded = recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300)
        folded.notes = "Planning notes"
        let original = folded.tracks[0]
        let copyID = ConversationMerge.copyID(of: original.id, folded: folded.id, into: survivor.id)
        let raw = RecordingTrack(id: copyID, source: original.source, relativePath: "Originals/\(copyID.uuidString).wav", fileName: "download.wav",
                                 createdAt: start.addingTimeInterval(99_999), sha256: original.sha256)
        var waiting = survivor
        var waitingCopy = raw
        waitingCopy.mergedFrom = folded.id
        waitingCopy.removal = RecordingRemoval(removedAt: start.addingTimeInterval(99_999), movedTo: folded.id)
        waiting.tracks.append(waitingCopy)
        var completed = survivor
        completed.tracks.append(raw)
        ConversationMerge.fold(folded, into: &completed, placement: try XCTUnwrap(ConversationMerge.placements([survivor, folded])[folded.id]),
                               copies: [original.id: copyID], fresh: [copyID], at: start)
        return (survivor, folded, waiting, completed, copyID)
    }

    func testBehaviorAFoldedCopyBeatsAWaitingCopyOfTheSameRecordingWhicheverWayTheyMeet() throws {
        let (survivor, folded, waiting, completed, copyID) = try waitingAndCompleted()
        let expected = try XCTUnwrap(completed.tracks.first { $0.id == copyID })
        XCTAssertNil(expected.removal)
        for base in [nil, survivor, waiting] as [Meeting?] {
            for (local, remote) in [(waiting, completed), (completed, waiting)] {
                let result = MeetingMerge.merge(base: base, local: local, remote: remote)
                let label = base == nil ? "no ancestor" : base == survivor ? "before the merge" : "the waiting copy"
                XCTAssertEqual(result.meeting.tracks.first { $0.id == copyID }, expected, label)
                XCTAssertEqual(result.meeting.presentTracks.count, 2, label)
                XCTAssertEqual(result.warnings, [], label)
                XCTAssertFalse(result.meeting.revisions.contains { if case .sync = $0.kind { return true } else { return false } }, label)
                XCTAssertTrue(ConversationMerge.hasFolded(folded.id, into: result.meeting), label)
            }
        }
    }

    func testBehaviorAWaitingCopyOfAConversationFoldedInAlreadyIsInTheConversationAgain() throws {
        let (_, folded, waiting, completed, copyID) = try waitingAndCompleted()
        // The state the blocker left: the conversation folded in, its recording's copy still marked waiting.
        var broken = completed
        let index = try XCTUnwrap(broken.tracks.firstIndex { $0.id == copyID })
        broken.tracks[index].removal = RecordingRemoval(removedAt: start, movedTo: folded.id)
        XCTAssertTrue(broken.settleMergeCopies())
        XCTAssertNil(broken.tracks[index].removal)
        XCTAssertEqual(broken.tracks[index], completed.tracks[index])
        XCTAssertFalse(broken.settleMergeCopies(), "once")
        // One whose conversation isn't folded in yet is left for the merge asked for again.
        var stopped = waiting
        XCTAssertFalse(stopped.settleMergeCopies())
        XCTAssertEqual(stopped, waiting)
    }

    // MARK: Pages

    /// A conversation with two notebook pages, the first read: a passage on its recording and one on the timeline's own clock.
    private func writtenIn(_ meeting: Meeting, orders: [Double] = [3, 1]) -> (meeting: Meeting, pages: [NotebookPage]) {
        var meeting = meeting
        let track = meeting.tracks[0].id
        let ids = orders.map { _ in UUID() }
        var pages = zip(ids, orders).map { NotebookFixtures.page($0, order: $1, tag: "page-\($0)") }
        let held = NotebookFixtures.passage(ids[0], key: "1-3-10-10", words: "on the recording", trackID: track, time: 12)
        let own = NotebookFixtures.passage(ids[0], key: "2-3-10-60", words: "on the clock", at: 30, time: 40)
        pages[0].reading = NotebookFixtures.reading(of: pages[0].drawing!, [held, own])
        meeting.pages = pages
        return (meeting, pages)
    }

    func testBehaviorFoldCarriesPagesAfterSurvivorsWithCopiedTrackAnchors() throws {
        var survivor = recorded("Standup", at: start, seconds: 600)
        survivor.pages = [NotebookFixtures.page(UUID(), order: 7, tag: "mine")]
        let (later, pages) = writtenIn(recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300))
        var merged = survivor
        let copies = copying(later, into: &merged)
        ConversationMerge.fold(later, into: &merged, placement: ConversationMerge.placements([survivor, later])[later.id]!, copies: copies,
                               fresh: Set(copies.values), pageFiles: Set(pages.map(\.id)), at: start)
        XCTAssertEqual(merged.pages?.count, 3)
        XCTAssertEqual(merged.pages?.first, survivor.pages?.first, "the survivor's own, untouched")
        let carried = Array(try XCTUnwrap(merged.pages).dropFirst())
        XCTAssertEqual(carried.map(\.id), [pages[1].id, pages[0].id], "in the folded conversation's order, after the survivor's")
        XCTAssertEqual(carried.map(\.order), [8, 9])
        XCTAssertEqual(carried[1].drawing, pages[0].drawing, "the same files: page IDs are global")
        let held = try XCTUnwrap(carried[1].passages.first { $0.words == "on the recording" })
        XCTAssertEqual(held.trackID, copies[later.tracks[0].id], "on the recording's copy")
        XCTAssertEqual(held.time, 12)
        XCTAssertEqual(carried[1].reading?.passages.map(\.id), pages[0].reading?.passages.map(\.id), "passage IDs follow their page")
        XCTAssertNotNil(merged.visiblePages.last)
        // A recording that wasn't carried leaves its passages on the timeline by when they were written.
        var orphaned = survivor
        ConversationMerge.fold(later, into: &orphaned, placement: .init(kind: .after, shift: 0), copies: [:], fresh: [], pageFiles: Set(pages.map(\.id)), at: start)
        let unplaced = try XCTUnwrap(orphaned.pages?.last?.passages.first { $0.words == "on the recording" })
        XCTAssertNil(unplaced.trackID)
        XCTAssertNil(unplaced.time)
    }

    func testBehaviorFoldShiftsTimelinePassages() throws {
        let survivor = recorded("Standup", at: start, seconds: 600)
        let (later, pages) = writtenIn(recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300))
        // After: the timeline moves, and what was written on its own clock moves with it; what would land before zero has no time.
        var after = survivor
        let copies = copying(later, into: &after)
        ConversationMerge.fold(later, into: &after, placement: .init(kind: .after, shift: 700), copies: copies, fresh: Set(copies.values),
                               pageFiles: [pages[0].id], at: start)
        let moved = try XCTUnwrap(after.page(pages[0].id)?.passages.first { $0.words == "on the clock" })
        XCTAssertNil(moved.trackID)
        XCTAssertEqual(moved.time, 740)
        var early = later
        early.pages?[1] = pages[1]
        early.pages?[0].reading?.passages[1].time = 5
        var before = survivor
        let earlyCopies = copying(early, into: &before)
        ConversationMerge.fold(early, into: &before, placement: .init(kind: .after, shift: -30), copies: earlyCopies, fresh: Set(earlyCopies.values),
                               pageFiles: [pages[0].id], at: start)
        XCTAssertNil(before.page(pages[0].id)?.passages.first { $0.words == "on the clock" }?.time)
        // Alongside, with its recording lined up later: held by the lead recording, so it follows it.
        var lead = later
        lead.tracks[0].offset = 20
        var alongside = survivor
        let leadCopies = copying(lead, into: &alongside)
        ConversationMerge.fold(lead, into: &alongside, placement: .init(kind: .alongside, shift: -30), copies: leadCopies, fresh: Set(leadCopies.values),
                               pageFiles: [pages[0].id], at: start)
        let held = try XCTUnwrap(alongside.page(pages[0].id)?.passages.first { $0.words == "on the clock" })
        XCTAssertEqual(held.trackID, leadCopies[lead.tracks[0].id], "40 s on the timeline is 20 s into the lead recording")
        XCTAssertEqual(held.time, 20)
    }

    func testBehaviorFoldCarriesPageAndPassageRevisions() throws {
        let survivor = recorded("Standup", at: start, seconds: 600)
        var (later, pages) = writtenIn(recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300))
        let passage = try XCTUnwrap(pages[0].passages.first)
        later.addPage(NotebookFixtures.page(UUID(), order: 9, tag: "unfiled"))
        let lone = try XCTUnwrap(later.pages?.last)
        later.correctPassage(pageID: pages[0].id, passageID: passage.id, text: "fixed words", now: start.addingTimeInterval(5))
        later.removePage(pages[1].id, at: start.addingTimeInterval(6))
        later.removePage(lone.id, at: start.addingTimeInterval(7))
        var merged = survivor
        let copies = copying(later, into: &merged)
        ConversationMerge.fold(later, into: &merged, placement: ConversationMerge.placements([survivor, later])[later.id]!, copies: copies,
                               fresh: Set(copies.values), pageFiles: [pages[0].id, pages[1].id], at: start)
        let fields = merged.revisions.map(\.field)
        XCTAssertTrue(fields.contains("passage:\(passage.id.uuidString)"), "the correction is in the merged conversation's History")
        XCTAssertTrue(fields.contains("page:\(pages[1].id.uuidString)"))
        XCTAssertFalse(fields.contains("page:\(lone.id.uuidString)"), "a page that wasn't carried has no History here")
        XCTAssertEqual(merged.revisions.first { $0.kind == .passage(passage.id) }?.newValue, "fixed words")
        XCTAssertEqual(merged.revisions.filter { $0.kind == .page(pages[1].id) }.map(\.newValue), ["removed"])
        XCTAssertEqual(merged.page(pages[0].id)?.corrections?.first?.text, "fixed words", "the correction came with its page")
    }

    func testBehaviorFoldCarriesTheRecordingClockWithTheTrackAndTheNotebooksLog() throws {
        let survivor = recorded("Standup", at: start, seconds: 600)
        var (later, pages) = writtenIn(recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300))
        let samples = [RecordingClockSample(at: start.addingTimeInterval(3_600), elapsed: 0, running: true),
                       RecordingClockSample(at: start.addingTimeInterval(3_660), elapsed: 60, running: false)]
        later.tracks[0].clockSamples = samples
        let track = later.tracks[0].id
        pages[0].erased = [ErasedStroke(key: "1-3-10-10", madeAt: start, erasedAt: start.addingTimeInterval(8), trackID: track, time: 8),
                           ErasedStroke(key: "2-3-10-60", madeAt: start, erasedAt: start.addingTimeInterval(9), time: 40)]
        later.pages = pages
        let unfiled = UUID()
        later.pageTurns = [PageTurn(at: start.addingTimeInterval(1), pages: [pages[0].id], trackID: track, time: 5),
                           PageTurn(at: start.addingTimeInterval(2), pages: [pages[0].id, pages[1].id], time: 30),
                           PageTurn(at: start.addingTimeInterval(3), pages: [unfiled])]
        var merged = survivor
        let copies = copying(later, into: &merged)
        ConversationMerge.fold(later, into: &merged, placement: .init(kind: .after, shift: 700), copies: copies, fresh: Set(copies.values),
                               pageFiles: Set(pages.map(\.id)), at: start)
        let copy = try XCTUnwrap(merged.tracks.first { $0.id == copies[track] })
        XCTAssertEqual(copy.clockSamples, samples, "the samples go with the recording they describe")
        let carried = try XCTUnwrap(merged.page(pages[0].id)?.erased)
        XCTAssertEqual(carried[0].trackID, copies[track], "an erasure on the recording follows its copy")
        XCTAssertEqual(carried[0].time, 8)
        XCTAssertNil(carried[1].trackID)
        XCTAssertEqual(carried[1].time, 740, "one on the timeline's clock moves with the timeline")
        XCTAssertEqual(merged.pageTurns?.map(\.pages), [[pages[0].id], [pages[0].id, pages[1].id]], "turns to pages that weren't carried are left out")
        XCTAssertEqual(merged.pageTurns?.first?.trackID, copies[track])
        XCTAssertEqual(merged.pageTurns?.last?.time, 730)

        // The same audio was in both: the survivor's copy without samples takes the folded one's.
        var shared = survivor
        shared.tracks[0].sha256 = later.tracks[0].sha256
        ConversationMerge.fold(later, into: &shared, placement: .init(kind: .after, shift: 0), copies: [track: shared.tracks[0].id], fresh: [],
                               pageFiles: [], at: start)
        XCTAssertEqual(shared.tracks[0].clockSamples, samples)
        // Nothing carried, no turns.
        var bare = survivor
        let bareCopies = copying(later, into: &bare)
        ConversationMerge.fold(later, into: &bare, placement: .init(kind: .after, shift: 0), copies: bareCopies, fresh: Set(bareCopies.values), at: start)
        XCTAssertNil(bare.pageTurns)
    }

    func testBehaviorFoldSkipsPageWhoseFilesWerentCopied() throws {
        let survivor = recorded("Standup", at: start, seconds: 600)
        var (later, pages) = writtenIn(recorded("Planning", at: start.addingTimeInterval(3_600), seconds: 300))
        // One of its pages is the survivor's already (the two held the same page).
        var merged = survivor
        merged.pages = [pages[1]]
        later.correctPassage(pageID: pages[0].id, passageID: pages[0].passages[0].id, text: "typed")
        let copies = copying(later, into: &merged)
        let placement = ConversationMerge.placements([survivor, later])[later.id]!
        ConversationMerge.fold(later, into: &merged, placement: placement, copies: copies, fresh: Set(copies.values), pageFiles: [pages[1].id], at: start)
        XCTAssertEqual(merged.pages?.map(\.id), [pages[1].id], "no files copied for the other page, so it isn't carried; the known one isn't repeated")
        XCTAssertEqual(merged.pages?.first, pages[1], "and isn't touched")
        XCTAssertFalse(merged.revisions.contains { $0.kind == .passage(pages[0].passages[0].id) })
        // Nothing copied at all (the default): no pages.
        var none = survivor
        let noneCopies = copying(later, into: &none)
        ConversationMerge.fold(later, into: &none, placement: placement, copies: noneCopies, fresh: Set(noneCopies.values), at: start)
        XCTAssertNil(none.pages)
    }

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
