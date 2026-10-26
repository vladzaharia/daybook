import XCTest
@testable import DaybookCore

/// Matching arriving recordings to conversations, and fusing several recordings of one
/// conversation with stored placements. Pure values: no audio, no models.
final class MultiSourceTests: XCTestCase {
    private let mac = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let recorder = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let system = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let start = Date(timeIntervalSince1970: 1_780_000_000)
    private let phrases = ["We should ship the calendar feature tomorrow", "Jordan will review the database migration next",
                           "The onboarding experiment improved activation rates substantially", "Let us schedule another review for Monday",
                           "Priya owns the pricing page copy this sprint"]

    private func segment(_ track: UUID, _ time: Double, _ text: String, confidence: Double = 0.7, speaker: String? = nil) -> TranscriptSegment {
        TranscriptSegment(trackID: track, start: time, end: time + 4, text: text, speakerID: speaker ?? "\(track)-1", confidence: confidence)
    }

    private func spoken(_ track: UUID, every spacing: Double = 30, from origin: Double = 0, rate: Double = 1) -> [TranscriptSegment] {
        phrases.enumerated().map { segment(track, origin + Double($0.offset) * spacing * rate, $0.element) }
    }

    /// A conversation recorded on this Mac: its microphone sets the timeline, transcribed.
    private func macConversation(id: UUID = UUID(), at date: Date? = nil, seconds: Double = 150) -> Meeting {
        let date = date ?? start
        let track = RecordingTrack(id: mac, source: .microphone, relativePath: "Originals/mac.caf", fileName: "microphone.caf",
                                   createdAt: date, duration: seconds, offset: 0, startedAt: date)
        var meeting = Meeting(id: id, title: "Call", date: date, tracks: [track],
                              transcripts: [TrackTranscript(trackID: mac, segments: spoken(mac), knownOffset: 0)])
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
        return meeting
    }

    private func recorderTrack(_ alignment: SourceAlignment?, startedAt: Date? = nil, seconds: Double = 150) -> RecordingTrack {
        RecordingTrack(id: recorder, source: .soundcore, relativePath: "Originals/r.wav", fileName: "r.wav", duration: seconds,
                       device: DeviceRecordingIdentity(kind: "soundcore.work", serial: "SN1", recordingID: "1780000010"),
                       startedAt: startedAt, alignment: alignment)
    }

    // MARK: Matching

    func testMultipointLinkClaimsTheRecorderRecordingByIDOrStart() {
        var linked = Meeting(title: "Linked")
        var link = CompanionRecording(deviceID: "d", deviceKind: "soundcore.work", deviceSerial: "SN1", deviceName: "Soundcore Work",
                                      macStartedAt: start, state: .stopped, startedByDaybook: true)
        link.recorderStartedAt = start.addingTimeInterval(2)
        linked.companions = [link]
        let identity = DeviceRecordingIdentity(kind: "soundcore.work", serial: "SN1", recordingID: "1780000002")
        XCTAssertEqual(SourceMatcher.linked(identity, start: start.addingTimeInterval(2), in: [linked])?.meetingID, linked.id)
        XCTAssertNil(SourceMatcher.linked(identity, start: start.addingTimeInterval(40), in: [linked]), "A different recording")
        let otherSerial = DeviceRecordingIdentity(kind: "soundcore.work", serial: "SN2", recordingID: "1780000002")
        XCTAssertNil(SourceMatcher.linked(otherSerial, start: start.addingTimeInterval(2), in: [linked]), "Another recorder of the same kind")

        linked.companions?[0].recordingID = "1780000002"
        XCTAssertEqual(SourceMatcher.linked(identity, start: nil, in: [linked])?.companionID, link.id, "The recording ID decides")
        linked.companions?[0].state = .unavailable
        linked.companions?[0].recordingID = nil
        XCTAssertNil(SourceMatcher.linked(identity, start: start.addingTimeInterval(2), in: [linked]), "A recorder that never started reserves nothing")
    }

    func testOverlapInTimeThenSoundDecides() {
        let call = macConversation(at: start, seconds: 1_800)
        let later = macConversation(at: start.addingTimeInterval(7_200), seconds: 1_800)
        let arrival = SourceArrival(start: start.addingTimeInterval(60), duration: 1_500, startIsReliable: true)
        let candidates = SourceMatcher.candidates(for: arrival, in: [call, later])
        XCTAssertEqual(candidates.map(\.meetingID), [call.id])
        XCTAssertEqual(candidates[0].clockOffset, 60, accuracy: 0.001)
        guard case .compareSound(let candidate) = SourceMatcher.decide(candidates) else { return XCTFail("One overlap compares the sound") }

        XCTAssertEqual(SourceMatcher.decide(candidate, sound: AudioAlignment(offset: 61.2, confidence: 0.92), startIsReliable: true), .attach(call.id))
        XCTAssertEqual(SourceMatcher.decide(candidate, sound: AudioAlignment(offset: 61.2, confidence: 0.4), startIsReliable: true),
                       .suggest([call.id], .lowConfidence, confidence: 0.4))
        XCTAssertEqual(SourceMatcher.decide(candidate, sound: nil, startIsReliable: true), .suggest([call.id], .checkingTranscript, confidence: nil),
                       "No verdict from the sound: the transcript decides later")
        XCTAssertEqual(SourceMatcher.decide(candidate, sound: AudioAlignment(offset: 900, confidence: 0.95), startIsReliable: true),
                       .suggest([call.id], .lowConfidence, confidence: 0.95), "Sound that contradicts trustworthy clocks isn't proof")

        let overlapsBoth = SourceArrival(start: start.addingTimeInterval(900), duration: 6_900, startIsReliable: true)
        XCTAssertEqual(SourceMatcher.decide(SourceMatcher.candidates(for: overlapsBoth, in: [call, later])),
                       .suggest([call.id, later.id], .severalConversations, confidence: nil))
        let elsewhere = SourceArrival(start: start.addingTimeInterval(-86_400), duration: 600, startIsReliable: true)
        XCTAssertEqual(SourceMatcher.decide(SourceMatcher.candidates(for: elsewhere, in: [call, later])), .standalone)
    }

    func testAConversationBeingRecordedNowIsACandidate() {
        let live = Meeting(title: "Recording now", date: start)
        let arrival = SourceArrival(start: start.addingTimeInterval(5), duration: 600, startIsReliable: true)
        let candidates = SourceMatcher.candidates(for: arrival, in: [live], live: [live.id: DateInterval(start: start, duration: 900)])
        XCTAssertEqual(candidates.map(\.meetingID), [live.id])
        XCTAssertEqual(candidates[0].clockOffset, 5, accuracy: 0.001)
        XCTAssertTrue(SourceMatcher.candidates(for: arrival, in: [live]).isEmpty, "A conversation with no audio and no live span has no time")
    }

    // MARK: Placement and fusion

    func testSoundPlacementDrivesFusedTimesAndDriftWhileProvenanceKeepsSourceTimes() throws {
        var meeting = macConversation()
        let placement = SourcePlacement.compose(AudioAlignment(offset: 12.5, rate: 1.001, confidence: 0.9), onto: (0, 1))
        meeting.tracks.append(recorderTrack(SourceAlignment(method: .audio, offset: placement.offset, rate: placement.rate,
                                                            confidence: 0.9, referenceTrackID: mac)))
        meeting.transcripts.append(TrackTranscript(trackID: recorder, segments: [segment(recorder, 100, "A remark only the recorder heard clearly today")]))
        let fused = SourceFusion.fuse(meeting)
        let report = try XCTUnwrap(fused.fusion.alignments.first { $0.trackID == recorder })
        XCTAssertEqual(report.offset, 12.5, accuracy: 0.0001)
        XCTAssertEqual(report.rate, 1.001, accuracy: 0.000_001)
        XCTAssertTrue(report.explanation.contains("sound"), report.explanation)
        let heard = try XCTUnwrap(fused.fusion.segments.first { $0.trackID == recorder })
        XCTAssertEqual(heard.start, 12.5 + 100 * 1.001, accuracy: 0.0001)
        XCTAssertEqual(heard.provenance.first?.start, 100, "Provenance keeps the recording's own time")
        XCTAssertTrue(fused.settled.isEmpty)

        meeting.applyFusion(fused.fusion)
        XCTAssertEqual(meeting.alignedTime(for: Highlight(trackID: recorder, time: 100)) ?? 0, 12.5 + 100.1, accuracy: 0.0001,
                       "Bookmarks on the recorder follow its drift")
    }

    func testWaitingSourceSettlesByTranscriptThenByClock() throws {
        var meeting = macConversation()
        meeting.tracks.append(recorderTrack(SourceAlignment(method: .pending, clockOffset: 9, audioChecked: true)))
        // The recorder started 8 s after the Mac, so its phrases come 8 s earlier in its own time.
        meeting.transcripts.append(TrackTranscript(trackID: recorder, segments: spoken(recorder, from: -8).filter { $0.start >= 0 }))
        let byTranscript = SourceFusion.fuse(meeting)
        let settled = try XCTUnwrap(byTranscript.settled[recorder])
        XCTAssertEqual(settled.method, .transcript)
        XCTAssertEqual(settled.offset ?? 0, 8, accuracy: 0.01)
        XCTAssertGreaterThan(settled.confidence ?? 0, 0.55)
        XCTAssertEqual(settled.clockOffset, 9, "The clocks' guess is kept for reference")

        var unrelated = macConversation()
        unrelated.tracks.append(recorderTrack(SourceAlignment(method: .pending, clockOffset: 9, audioChecked: true)))
        unrelated.transcripts.append(TrackTranscript(trackID: recorder, segments: [segment(recorder, 3, "Something about gardening this weekend instead")]))
        let byClock = SourceFusion.fuse(unrelated)
        XCTAssertEqual(byClock.settled[recorder]?.method, .clock)
        XCTAssertEqual(byClock.settled[recorder]?.offset, 9)
        XCTAssertTrue(byClock.fusion.segments.contains { $0.trackID == recorder && $0.start == 12 }, "The clocks place it in the unified transcript")

        unrelated.tracks[1].alignment?.clockOffset = nil
        let separate = SourceFusion.fuse(unrelated)
        XCTAssertEqual(separate.settled[recorder]?.method, .unaligned)
        XCTAssertFalse(separate.fusion.segments.contains { $0.trackID == recorder }, "Without clocks it stays separate, as before")
    }

    /// Post-hoc enhancement: a new recording joins, and everything the person made survives.
    func testAddingASourceKeepsCorrectionsRenamesNoteTimesAndBookmarks() throws {
        var meeting = macConversation()
        meeting.speakers = [Speaker(id: "\(mac)-1", name: "Speaker 1", sourceTrackID: mac)]
        meeting.renameSpeaker(id: "\(mac)-1", name: "Dana")
        let corrected = try XCTUnwrap(meeting.unifiedTranscript.first { $0.text == phrases[1] })
        meeting.correctSegment(id: corrected.id, text: "Jordan will review the Postgres migration next")
        meeting.timedNotes = [TimedNote(time: 31, text: "Migration owner"), TimedNote(text: "Before the call")]
        meeting.highlights = [Highlight(time: 61, text: "Activation"), Highlight(trackID: mac, time: 91, text: "Monday")]
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
        let before = meeting

        // The recorder heard the same conversation, more clearly, starting 4 s after the Mac.
        meeting.tracks.append(recorderTrack(SourceAlignment(method: .audio, offset: 4, confidence: 0.9, referenceTrackID: mac)))
        meeting.transcripts.append(TrackTranscript(trackID: recorder, segments: spoken(recorder, from: -4).filter { $0.start >= 0 }.map {
            var clearer = $0; clearer.confidence = 0.95; return clearer
        } + [segment(recorder, 136, "Only the recorder caught this closing remark", confidence: 0.95)]))
        let issues = meeting.applyFusion(SourceFusion.fuse(meeting).fusion)

        XCTAssertTrue(issues.isEmpty)
        let kept = try XCTUnwrap(meeting.unifiedTranscript.first { $0.id == corrected.id })
        XCTAssertEqual(kept.text, "Jordan will review the Postgres migration next", "The correction survives on the merged passage")
        XCTAssertTrue(kept.provenance.contains { $0.trackID == recorder }, "…which both recordings now support")
        XCTAssertEqual(meeting.speakers.first?.name, "Dana")
        XCTAssertEqual(kept.speakerID, "\(mac)-1", "The clearer recording's words, still attributed to the person named Dana")
        XCTAssertEqual(meeting.timedNotes, before.timedNotes)
        XCTAssertEqual(meeting.highlights.map { meeting.alignedTime(for: $0) }, before.highlights.map { before.alignedTime(for: $0) })
        XCTAssertTrue(meeting.unifiedTranscript.contains { $0.text == "Only the recorder caught this closing remark" && $0.start == 140 })
        XCTAssertEqual(meeting.alignmentReports.first { $0.trackID == mac }?.method, .reference, "The timeline's origin doesn't move")
    }

    /// The other direction: this Mac records into a conversation whose timeline a recorder set.
    func testMacRecordingJoinsARecorderTimelineAndItsNotesFollow() throws {
        let recorderStart = start
        var meeting = Meeting(title: "Workshop", date: recorderStart, tracks: [recorderTrack(nil, startedAt: recorderStart, seconds: 600)])
        meeting.transcripts = [TrackTranscript(trackID: recorder, segments: spoken(recorder, from: 120))]
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
        XCTAssertEqual(meeting.knownTimelineStart(), recorderStart)

        // This Mac started 119.6 s into the recorder's recording; a note was written 10 s in.
        let note = TimedNote(time: 10, text: "Ask about the migration")
        meeting.timedNotes = [note]
        let pending = SourceAlignment(method: .pending, referenceTrackID: recorder, clockOffset: 119.65, clockID: UUID(),
                                      heldNoteIDs: [note.id], captureOffset: 0.05)
        meeting.tracks.append(RecordingTrack(id: mac, source: .microphone, relativePath: "Originals/m.caf", fileName: "microphone.caf",
                                             createdAt: recorderStart.addingTimeInterval(119.65), duration: 200, alignment: pending))
        meeting.transcripts.append(TrackTranscript(trackID: mac, segments: spoken(mac, from: 0.4)))
        XCTAssertNil(meeting.timelinePlacement(of: mac), "Waiting to be lined up")

        // The sound places it 120 s in (the clocks were 0.35 s off).
        meeting.applyPlacements([mac: SourceAlignment(method: .audio, offset: 120 - 0.4, confidence: 0.88, referenceTrackID: recorder)])
        XCTAssertEqual(meeting.timedNotes?.first?.time ?? 0, 119.6 + 10 - 0.05, accuracy: 0.0001, "The note moves onto the timeline with its recording")
        XCTAssertNil(meeting.tracks[1].alignment?.heldNoteIDs)
        meeting.applyPlacements([mac: SourceAlignment(method: .manual, offset: 119)])
        XCTAssertEqual(meeting.timedNotes?.first?.time ?? 0, 129.55, accuracy: 0.0001, "…only once")

        meeting.applyPlacements([mac: SourceAlignment(method: .audio, offset: 119.6, confidence: 0.88, referenceTrackID: recorder)])
        let fused = SourceFusion.fuse(meeting)
        meeting.applyFusion(fused.fusion)
        XCTAssertEqual(fused.fusion.alignments.first { $0.trackID == recorder }?.method, .reference, "The recorder still sets the timeline")
        XCTAssertEqual(meeting.unifiedTranscript.filter { $0.text == phrases[0] }.count, 1, "Both recordings of a phrase become one passage")
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.text == phrases[0] }?.start ?? 0, 120, accuracy: 0.01)
    }

    func testRecordingsOnOneClockMoveTogether() throws {
        let clock = UUID()
        var meeting = Meeting(title: "Call", tracks: [
            recorderTrack(nil, startedAt: start),
            RecordingTrack(id: mac, source: .microphone, relativePath: "Originals/m.caf", fileName: "m.caf",
                           alignment: SourceAlignment(method: .audio, offset: 30.5, confidence: 0.9, clockOffset: 30, clockID: clock)),
            RecordingTrack(id: system, source: .systemAudio, relativePath: "Originals/s.caf", fileName: "s.caf",
                           alignment: SourceAlignment(method: .pending, clockOffset: 30.02, clockID: clock, audioChecked: true))
        ])
        let following = SourcePlacement.followingClockSiblings(meeting.tracks, placed: SourceFusion.currentPlacements(meeting))
        XCTAssertEqual(following[system]?.method, .audio)
        XCTAssertEqual(following[system]?.offset ?? 0, 30.52, accuracy: 0.0001)
        meeting.applyPlacements(following)
        XCTAssertEqual(meeting.tracks[2].offset ?? 0, 30.52, accuracy: 0.0001)
    }

    func testCompanionLinksMergeFromEitherMac() {
        let base = Meeting(title: "Call")
        var remote = base
        remote.companions = [CompanionRecording(deviceID: "d", deviceKind: "soundcore.work", deviceName: "Soundcore Work", macStartedAt: start, state: .stopped)]
        var local = base
        local.notes = "Local edit"
        let merged = MeetingMerge.merge(base: base, local: local, remote: remote).meeting
        XCTAssertEqual(merged.companions, remote.companions, "Another Mac can attach the recorder's recording")
        XCTAssertEqual(merged.notes, "Local edit")
    }

    func testLibrariesWithoutMultipointDecodeAndFuseAsBefore() throws {
        let legacy = Meeting(title: "Old", tracks: [RecordingTrack(id: mac, source: .microphone, relativePath: "Originals/a.caf", fileName: "a.caf", offset: 0),
                                                    RecordingTrack(id: recorder, source: .soundcore, relativePath: "Originals/b.wav", fileName: "b.wav")],
                             transcripts: [TrackTranscript(trackID: mac, segments: spoken(mac), knownOffset: 0),
                                           TrackTranscript(trackID: recorder, segments: spoken(recorder, from: 0, rate: 1 / 1.01))])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        json.removeValue(forKey: "companions"); json.removeValue(forKey: "sourceSuggestions")
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.companions)
        XCTAssertNil(decoded.tracks[1].alignment)
        let wrapped = SourceFusion.fuse(decoded)
        let plain = TranscriptFusion.fuse(decoded.transcripts, tracks: decoded.tracks)
        XCTAssertEqual(wrapped.fusion.segments, plain.segments)
        XCTAssertEqual(wrapped.fusion.alignments, plain.alignments)
        XCTAssertTrue(wrapped.settled.isEmpty)
    }

    func testAnotherDevicesNotesJoinOnceEachHeldByItsRecordingUntilPlaced() {
        var meeting = macConversation()
        meeting.notes = "Agenda"
        meeting.timedNotes = [TimedNote(time: 1, text: "Agenda")]
        let phone = RecordingTrack(id: recorder, source: .microphone, relativePath: "Originals/phone.m4a", fileName: "iPhone recording.m4a")
        meeting.tracks.append(phone)
        let notes = [TimedNote(time: 2, text: "Agenda"), TimedNote(time: 5, text: "Owners"), TimedNote(time: 9, text: "Owners"),
                     TimedNote(text: "Untimed")]
        let mark = Highlight(time: 4)
        meeting.addRecordingWork(trackID: recorder, notes: notes, bookmarks: [mark], joining: true, shift: 10)
        // A paragraph the Mac also typed is still the phone's own, and a repeat keeps its own time.
        XCTAssertEqual(meeting.notes, "Agenda\nAgenda\nOwners\nOwners\nUntimed")
        XCTAssertEqual(meeting.paragraphTimes(), [1, 12, 15, 19, nil])
        XCTAssertEqual(meeting.tracks[1].alignment?.heldNoteIDs, notes.prefix(3).map(\.id))
        XCTAssertEqual(meeting.tracks[1].alignment?.captureOffset, 10)
        XCTAssertEqual(meeting.highlights.map(\.trackID), [recorder], "its bookmark follows its recording")

        // Filing again adds nothing.
        let once = meeting
        meeting.addRecordingWork(trackID: recorder, notes: notes, bookmarks: [mark], joining: true, shift: 10)
        XCTAssertEqual(meeting, once)

        // Placed 7 s in (sound, then the Mac's own pending placement keeping the held notes), they follow it.
        meeting.applyPlacements([recorder: SourceAlignment(method: .pending, clockOffset: 8)])
        XCTAssertEqual(meeting.tracks[1].alignment?.heldNoteIDs?.count, 3)
        XCTAssertEqual(meeting.tracks[1].alignment?.captureOffset, 10, "a pending placement keeps where the held notes were timed from")
        meeting.applyPlacements([recorder: SourceAlignment(method: .audio, offset: 7, confidence: 0.9)])
        XCTAssertEqual(meeting.paragraphTimes(), [1, 9, 12, 16, nil])
        XCTAssertNil(meeting.tracks[1].alignment?.heldNoteIDs)
    }

    /// The iPhone led and this Mac joined later, so this Mac's recording sets the timeline and the
    /// phone's is placed before its zero. Notes the phone took before this Mac started keep their time
    /// in the phone's recording, before the timeline's zero, as its passages do; editing keeps them.
    func testNotesFromBeforeTheTimelinesZeroKeepTheirPlaceBeforeIt() {
        var meeting = macConversation()
        meeting.tracks.append(RecordingTrack(id: recorder, source: .microphone, relativePath: "Originals/phone.m4a", fileName: "iPhone recording.m4a"))
        let notes = [TimedNote(time: 30, text: "Walking over"), TimedNote(time: 150, text: "Budget agreed")]
        meeting.addRecordingWork(trackID: recorder, notes: notes, bookmarks: [], joining: true)
        XCTAssertEqual(meeting.paragraphTimes(), [30, 150], "by the phone's clock until it's placed")

        // This Mac started two minutes after the phone.
        meeting.applyPlacements([recorder: SourceAlignment(method: .audio, offset: -120, confidence: 0.9)])
        XCTAssertEqual(meeting.paragraphTimes(), [-90, 30])
        XCTAssertNil(meeting.tracks[1].alignment?.heldNoteIDs)

        meeting.notes = "Walking over to the office\nBudget agreed"
        meeting.timedNotes = NoteTimeline.reconcile(previous: meeting.timedNotes ?? [], text: meeting.notes, captureTime: nil)
        XCTAssertEqual(meeting.paragraphTimes(), [-90, 30], "an edit keeps the time before zero")
        let copy = Meeting(id: meeting.id, title: meeting.title, date: meeting.date, notes: "Mac notes",
                           timedNotes: [TimedNote(time: 12, text: "Mac notes")])
        let merged = MeetingMerge.merge(base: nil, local: meeting, remote: copy).meeting
        XCTAssertEqual(merged.paragraphTimes(), [-90, 12, 30], "and so does a merge")
    }

    func testARecordingOfItsOwnConversationBringsItsNotesAsTheyWere() {
        var meeting = Meeting(title: "Walk", date: start)
        let mark = Highlight(time: 3)
        meeting.addRecordingWork(trackID: recorder, notes: [TimedNote(time: 2, text: "Decisions")], bookmarks: [mark], joining: false, shift: 30)
        XCTAssertEqual(meeting.notes, "Decisions")
        XCTAssertEqual(meeting.paragraphTimes(), [2], "its own timeline: no shift, nothing held")
        XCTAssertEqual(meeting.highlights, [mark])
    }
}
