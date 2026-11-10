import XCTest
@testable import DaybookCore

/// One clock per recording (`Meeting.clock(of:)`): every reader places a recording the same way, rates stay within
/// what a clock can drift, only sure placements anchor others, and a conversation keeps one origin.
final class TimelineClockTests: XCTestCase {
    private let raw = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    private let echo = UUID(uuidString: "00000000-0000-0000-0000-0000000000A2")!
    private let call = UUID(uuidString: "00000000-0000-0000-0000-0000000000A3")!
    private let recorder = UUID(uuidString: "00000000-0000-0000-0000-0000000000A4")!
    private let phone = UUID(uuidString: "00000000-0000-0000-0000-0000000000A5")!

    /// Passages, a word every 0.35 s from each one's start on the timeline, as `track` heard them: `local` maps a
    /// timeline time to the recording's own.
    private func heard(_ track: UUID, _ lines: [(text: String, at: Double)], local: (Double) -> Double, speaker: String? = nil,
                       created: Double = 1) -> TrackTranscript {
        var segments: [TranscriptSegment] = [], timed: [TranscriptWord] = []
        for line in lines {
            let words = line.text.split(separator: " ").map(String.init).enumerated().map { index, word in
                TranscriptWord(text: " " + word, start: local(line.at + 0.35 * Double(index)), end: local(line.at + 0.35 * Double(index) + 0.3),
                               confidence: 0.85)
            }
            segments.append(TranscriptSegment(trackID: track, start: words[0].start, end: words[words.count - 1].end, text: line.text,
                                              speakerID: speaker ?? "\(track.uuidString.suffix(2)):1", confidence: 0.85))
            timed += words
        }
        return TrackTranscript(trackID: track, segments: segments, createdAt: Date(timeIntervalSince1970: created), words: timed)
    }

    private func heard(_ track: UUID, _ text: String, at start: Double, local: (Double) -> Double, speaker: String? = nil,
                       created: Double = 1) -> TrackTranscript {
        heard(track, [(text, start)], local: local, speaker: speaker, created: created)
    }

    // MARK: One clock

    /// An hour into a call: the raw microphone's clock runs 200 ppm fast against the capture's (its capture measured
    /// it), the echo-cancelled copy is resampled onto the capture's clock, the call is on it, and a recorder (its own
    /// clock, starting 30 s in and 150 ppm slow) is lined up by sound against the raw microphone. Something said at
    /// 3600 s lands within 50 ms of 3600 s in every one of them, and the three that heard it become one passage there.
    func testEveryRecordingOfAnHourLongCallLandsOnOneTimeline() throws {
        var rawTrack = RecordingTrack(id: raw, source: .microphone, relativePath: "m", fileName: "m", offset: 0, sha256: "m")
        rawTrack.capture = TrackCaptureDetails(method: "microphone", clockRate: 1.0002)
        var echoTrack = RecordingTrack(id: echo, source: .microphone, relativePath: "e", fileName: "e", offset: 0, sha256: "e",
                                       derivedFrom: raw, processing: RecordingTrack.echoCancelledProcessing)
        echoTrack.capture = TrackCaptureDetails(method: "echo-cancelled", clockRate: 1)
        let callTrack = RecordingTrack(id: call, source: .systemAudio, relativePath: "c", fileName: "c", offset: 0, sha256: "c")
        var meeting = Meeting(tracks: [rawTrack, callTrack, echoTrack])

        // The recorder's second t is capture second 30 + 0.99985 t; the aligner measures it in the raw microphone's seconds.
        let recorderStart = 30.0, recorderRate = 0.99985
        let sound = AudioAlignment(offset: recorderStart / 1.0002, rate: recorderRate / 1.0002, confidence: 0.9)
        let placed = SourcePlacement.compose(sound, onto: try XCTUnwrap(meeting.timelinePlacement(of: raw)))
        meeting.tracks.append(RecordingTrack(id: recorder, source: .soundcore, relativePath: "r", fileName: "r", sha256: "r",
                                             alignment: SourceAlignment(method: .audio, offset: placed.offset, rate: placed.rate,
                                                                        confidence: 0.9, referenceTrackID: raw)))
        let local: [UUID: (Double) -> Double] = [raw: { $0 / 1.0002 }, echo: { $0 }, call: { $0 },
                                                  recorder: { ($0 - recorderStart) / recorderRate }]
        let said = 3600.0
        for (track, toLocal) in local {
            let clock = try XCTUnwrap(meeting.clock(of: track))
            XCTAssertEqual(clock.timeline(toLocal(said)), said, accuracy: 0.05, "\(track)")
        }
        XCTAssertEqual(meeting.clock(of: echo)?.rate, 1, "The copy runs on the capture's clock, not at its original's rate")
        XCTAssertEqual(meeting.alignedTime(for: Highlight(trackID: echo, time: said)) ?? 0, said, accuracy: 0.05, "Bookmarks read the same clock")

        let words = "we will ship the release candidate to the customer on friday"
        meeting.transcripts = [heard(call, words, at: said, local: local[call]!, created: 1),
                               heard(echo, words, at: said, local: local[echo]!, created: 2),
                               heard(recorder, words, at: said, local: local[recorder]!, created: 3)]
        let fused = SourceFusion.fuse(meeting).fusion
        let passages = fused.segments.filter { $0.text == words }
        XCTAssertEqual(passages.count, 1, "\(fused.segments.map(\.text))")
        XCTAssertEqual(passages.first?.start ?? 0, said, accuracy: 0.05)
        XCTAssertEqual(Set(passages.first?.provenance.map(\.trackID) ?? []), [call, echo, recorder])
        XCTAssertEqual(fused.alignments.first { $0.trackID == echo }?.rate, 1)
    }

    /// A capture rate no clock runs at (the shipped v0.2.2 fixture stored a sample rate there) is ignored.
    func testACaptureRateNoClockRunsAtIsIgnored() throws {
        var track = RecordingTrack(id: raw, source: .microphone, relativePath: "m", fileName: "m", offset: 0.25, sha256: "m")
        track.capture = TrackCaptureDetails(method: "microphone", clockRate: 48_000.5)
        XCTAssertEqual(track.captureRate, 1)
        var meeting = Meeting(tracks: [track], transcripts: [heard(raw, "the budget review starts now", at: 10.25, local: { $0 - 0.25 })])
        XCTAssertEqual(meeting.clock(of: raw), TimelineClock(offset: 0.25, rate: 1, method: .capture))
        XCTAssertEqual(SourceFusion.fuse(meeting).fusion.segments.first?.start ?? 0, 10.25, accuracy: 1e-9)

        meeting.tracks[0].capture?.clockRate = 1.000_02
        XCTAssertEqual(meeting.clock(of: raw)?.rate, 1.000_02, "A clock's drift is kept")
        XCTAssertNil(ClockRate.bounded(1.0011))
        XCTAssertNil(ClockRate.bounded(0.97))
        XCTAssertEqual(ClockRate.bounded(0.999), 0.999)
    }

    /// Three shared phrases 14 s apart place a recording, but can't measure its clock: the fit is an offset at rate 1,
    /// and the end of a four-hour recording stays where it belongs (fusion version 1 took a 2% rate from them and put
    /// it 285 s off).
    func testThreePhrasesFourteenSecondsApartGiveAnOffsetAtRateOne() {
        var generator = SeededWords(seed: 0x9E37_79B9_7F4A_7C15)
        let reference = UUID(), source = UUID()
        let phrases = (0..<2_000).map { _ in generator.phrase(6) }
        let referenceSegments = phrases.enumerated().map { index, text in
            TranscriptSegment(trackID: reference, start: Double(index) * 7.2, end: Double(index) * 7.2 + 3, text: text)
        }
        // The source starts 700 s into the reference and shares three of its phrases, with a little jitter.
        let sourceSegments = [100, 101, 102].enumerated().map { index, phrase in
            let start = Double(phrase) * 7.2 - 700 + [0, 0.15, 0.3][index]
            return TranscriptSegment(trackID: source, start: start, end: start + 3, text: phrases[phrase])
        }
        let fit = TranscriptFusion.estimate(sourceSegments, reference: referenceSegments, trackID: source, referenceOffset: 0)
        XCTAssertEqual(fit.method, .anchors)
        XCTAssertEqual(fit.rate, 1)
        XCTAssertEqual(fit.offset, 699.85, accuracy: 0.01)
        XCTAssertEqual(14_000 * fit.rate + fit.offset, 14_700, accuracy: 0.5)
        XCTAssertLessThan(fit.confidence ?? 1, SourceMatcher.Policy().transcriptConfidence,
                          "Too short a stretch to move a recording into another conversation on its own")
        let before = TranscriptFusion.estimate(sourceSegments, reference: referenceSegments, trackID: source, referenceOffset: 0, version: 1)
        XCTAssertGreaterThan(abs(14_000 * before.rate + before.offset - 14_700), 100, "What version 1 did")

        // Phrases spread over half an hour on a clock 200 ppm fast do measure it.
        let spread = stride(from: 120, to: 370, by: 10).map { phrase -> TranscriptSegment in
            let start = (Double(phrase) * 7.2 - 700) / 1.0002
            return TranscriptSegment(trackID: source, start: start, end: start + 3, text: phrases[phrase])
        }
        let measured = TranscriptFusion.estimate(spread, reference: referenceSegments, trackID: source, referenceOffset: 0)
        XCTAssertEqual(measured.rate, 1.0002, accuracy: 0.000_02)
        XCTAssertEqual(measured.offset, 700, accuracy: 0.05)
        XCTAssertGreaterThan(measured.confidence ?? 0, 0.8)
    }

    /// A phrase fit stored with a rate no clock runs at (fusion version 1 allowed 3%) is fitted again when the
    /// conversation is fused.
    func testAStoredPhraseFitWithAnImpossibleRateIsFittedAgain() throws {
        let phrases = ["We should ship the calendar feature tomorrow", "Jordan will review the database migration next",
                       "The onboarding experiment improved activation rates substantially", "Let us schedule another review for Monday"]
        func spoken(_ track: UUID, from origin: Double) -> [TranscriptSegment] {
            phrases.enumerated().map { TranscriptSegment(trackID: track, start: origin + Double($0.offset) * 30, end: origin + Double($0.offset) * 30 + 4,
                                                         text: $0.element, speakerID: "\(track)-1") }
        }
        var meeting = Meeting(tracks: [RecordingTrack(id: raw, source: .microphone, relativePath: "m", fileName: "m", offset: 0, sha256: "m"),
                                       RecordingTrack(id: recorder, source: .soundcore, relativePath: "r", fileName: "r", sha256: "r",
                                                      alignment: SourceAlignment(method: .transcript, offset: 8, rate: 0.98, confidence: 0.7))],
                              transcripts: [TrackTranscript(trackID: raw, segments: spoken(raw, from: 10)),
                                            TrackTranscript(trackID: recorder, segments: spoken(recorder, from: 2))])
        XCTAssertEqual(meeting.clock(of: recorder)?.rate, 1, "Read at a clock's rate meanwhile")
        let upkeep = SourceFusion.fuse(meeting, version: 1)
        XCTAssertTrue(upkeep.settled.isEmpty, "Upkeep at version 1 leaves stored fits alone")
        XCTAssertEqual(upkeep.fusion.alignments.first { $0.trackID == recorder }?.rate, 0.98, "…and fuses with them as version 1 did")
        var long = meeting
        long.tracks[1].duration = 3_600
        XCTAssertEqual(long.clock(of: recorder)?.offset ?? 0, 8 - 0.02 * 1_800, accuracy: 1e-9, "Kept right at its middle")
        let fused = SourceFusion.fuse(meeting)
        let refitted = try XCTUnwrap(fused.settled[recorder])
        XCTAssertEqual(refitted.method, .transcript)
        XCTAssertEqual(refitted.rate, 1)
        XCTAssertEqual(refitted.offset ?? 0, 8, accuracy: 0.01)
        meeting.applyPlacements(fused.settled)
        XCTAssertTrue(SourceFusion.fuse(meeting).settled.isEmpty, "Once")
    }

    // MARK: References and dependents

    /// Only a sure placement is lined up against: never one placed by shared phrases or the clocks alone.
    func testOnlyASurelyPlacedRecordingIsLinedUpAgainst() {
        let meeting = Meeting(tracks: [
            RecordingTrack(id: recorder, source: .soundcore, relativePath: "r", fileName: "r", duration: 600, sha256: "r"),
            RecordingTrack(id: phone, source: .microphone, relativePath: "p", fileName: "p", duration: 3_000, sha256: "p",
                           alignment: SourceAlignment(method: .transcript, offset: 4, confidence: 0.8)),
            RecordingTrack(id: call, source: .systemAudio, relativePath: "c", fileName: "c", duration: 3_000, sha256: "c",
                           alignment: SourceAlignment(method: .clock, offset: 5, confidence: 0.2))])
        XCTAssertEqual(meeting.alignmentReference()?.id, recorder, "The origin, not the longer microphone placed by phrases")
        XCTAssertTrue(meeting.clock(of: recorder)?.isStrong == true)
        XCTAssertFalse(meeting.clock(of: phone)?.isStrong == true)
        XCTAssertNil(meeting.alignmentReference(excluding: [recorder]))
    }

    /// A recording lined up against one that later moves (its sound checked again) moves with it, and so do the
    /// recordings lined up against it in turn.
    func testRecordingsLinedUpAgainstOneThatMovesMoveWithIt() throws {
        var meeting = Meeting(tracks: [
            RecordingTrack(id: raw, source: .microphone, relativePath: "m", fileName: "m", offset: 0, sha256: "m"),
            RecordingTrack(id: recorder, source: .soundcore, relativePath: "r", fileName: "r", sha256: "r",
                           alignment: SourceAlignment(method: .transcript, offset: 10, confidence: 0.7)),
            RecordingTrack(id: phone, source: .microphone, relativePath: "p", fileName: "p", sha256: "p",
                           alignment: SourceAlignment(method: .audio, offset: 15, rate: 1.0001, confidence: 0.9, referenceTrackID: recorder)),
            RecordingTrack(id: call, source: .imported, relativePath: "c", fileName: "c", sha256: "c",
                           alignment: SourceAlignment(method: .audio, offset: 20, confidence: 0.9, referenceTrackID: phone))])
        let phoneAt = (local: 100.0, timeline: 15 + 1.0001 * 100)
        // The sound puts the recorder 2 s later, on a clock 100 ppm fast.
        meeting.applyPlacements([recorder: SourceAlignment(method: .audio, offset: 12, rate: 1.0001, confidence: 0.9, referenceTrackID: raw)])
        // Whatever the recorder heard at a moment the phone also heard, they still hear together.
        let recorderLocal = (phoneAt.timeline - 10) / 1
        let moved = try XCTUnwrap(meeting.clock(of: phone))
        XCTAssertEqual(moved.timeline(phoneAt.local), 12 + 1.0001 * recorderLocal, accuracy: 1e-6)
        XCTAssertEqual(meeting.tracks[2].offset ?? 0, moved.offset, accuracy: 1e-9)
        XCTAssertEqual(meeting.clock(of: call)?.offset ?? 0, 12 + 1.0001 * (20 - 10), accuracy: 1e-6, "Transitively")
        XCTAssertEqual(meeting.clock(of: raw)?.offset, 0, "The reference itself never moves")
    }

    /// A recording that waited on the same capture clock as one the sound placed follows it at its own rate: the
    /// echo-cancelled copy never takes the raw microphone's drift.
    func testAClockSiblingFollowsAtItsOwnRate() throws {
        let clock = UUID()
        var micTrack = RecordingTrack(id: raw, source: .microphone, relativePath: "m", fileName: "m", sha256: "m",
                                      alignment: SourceAlignment(method: .audio, offset: 30.5, rate: 1.0003, confidence: 0.9, clockOffset: 30, clockID: clock))
        micTrack.capture = TrackCaptureDetails(method: "microphone", clockRate: 1.0002)
        var echoTrack = RecordingTrack(id: echo, source: .microphone, relativePath: "e", fileName: "e", sha256: "e", derivedFrom: raw,
                                       alignment: SourceAlignment(method: .pending, clockOffset: 30, clockID: clock))
        echoTrack.capture = TrackCaptureDetails(method: "echo-cancelled", clockRate: 1)
        let meeting = Meeting(tracks: [RecordingTrack(id: recorder, source: .soundcore, relativePath: "r", fileName: "r", sha256: "r"), micTrack, echoTrack])
        let following = try XCTUnwrap(SourcePlacement.followingClockSiblings(meeting.tracks, placed: SourceFusion.currentPlacements(meeting))[echo])
        XCTAssertEqual(following.offset ?? 0, 30.5, accuracy: 1e-9)
        XCTAssertEqual(following.rate, 1.0003 / 1.0002, accuracy: 1e-12)
        XCTAssertEqual(following.referenceTrackID, raw, "It follows the microphone, and moves when that does")
    }

    // MARK: One origin

    /// An iPhone asked two Macs to record along; each filed its recording as the conversation's origin. After sync, the
    /// one that started first keeps the timeline; the other waits to be placed, and the iPhone's measurements of both
    /// Macs' clocks put it within 100 ms though the Macs' own clocks disagree by 7 s.
    func testTwoMacsThatRecordedOneConversationKeepOneOrigin() throws {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let late = 20.0, skew = 7.0
        let studio = UUID(), desk = UUID()
        func capture(_ mic: UUID, _ system: UUID, id: UUID, device: String, startedAt: Date) -> [RecordingTrack] {
            var microphone = RecordingTrack(id: mic, source: .microphone, relativePath: "Originals/\(mic).caf", fileName: "microphone.caf",
                                            createdAt: startedAt, duration: 300, offset: 0.1, sha256: "\(mic)", startedAt: startedAt.addingTimeInterval(0.1))
            microphone.capture = TrackCaptureDetails(method: "microphone", captureID: id, deviceID: device)
            var computer = RecordingTrack(id: system, source: .systemAudio, relativePath: "Originals/\(system).caf", fileName: "systemAudio.caf",
                                          createdAt: startedAt, duration: 300, offset: 0.3, sha256: "\(system)", startedAt: startedAt.addingTimeInterval(0.3))
            computer.capture = TrackCaptureDetails(method: "process-tap", captureID: id, deviceID: device)
            return [microphone, computer]
        }
        let base = Meeting(title: "Planning", date: start)
        let (studioMic, studioCall, deskMic, deskCall) = (UUID(), UUID(), UUID(), UUID())
        var studioCopy = base, deskCopy = base
        studioCopy.tracks = capture(studioMic, studioCall, id: studio, device: "studio-mac", startedAt: start)
        studioCopy.transcripts = [heard(studioMic, "lets start with the budget for next quarter", at: 5.1, local: { $0 - 0.1 }, created: 1)]
        // The desk Mac's clock reads 7 s ahead; it joined 20 s after the studio Mac.
        deskCopy.tracks = capture(deskMic, deskCall, id: desk, device: "desk-mac", startedAt: start.addingTimeInterval(late + skew))
        deskCopy.transcripts = [heard(deskMic, "someone near the window asked about parking", at: 40.1, local: { $0 - late - 0.1 }, created: 2),
                                heard(deskCall, "the remote side dropped for a moment", at: 60.3, local: { $0 - late - 0.3 }, created: 3)]
        // The iPhone measured both while it recorded: each Mac's clock minus its own.
        var iPhone = RecordingTrack(id: phone, source: .microphone, relativePath: "Originals/iphone.m4a", fileName: "iphone.m4a", duration: 320,
                                    sha256: "iphone", device: DeviceRecordingIdentity(kind: "daybook.iphone", serial: "phone", recordingID: "1"),
                                    alignment: SourceAlignment(method: .pending))
        iPhone.capture = TrackCaptureDetails(method: "iphone-microphone", peerClocks: [
            CapturePeerClock(deviceID: "studio-mac", offset: 1.5, uncertainty: 0.004, sampleCount: 8, measuredAt: start),
            CapturePeerClock(deviceID: "desk-mac", offset: 1.5 + skew, uncertainty: 0.006, sampleCount: 8, measuredAt: start)])
        deskCopy.tracks.append(iPhone)
        // A recorder the desk Mac lined up by sound against its own microphone, 3 s into its timeline.
        let lined = UUID()
        deskCopy.tracks.append(RecordingTrack(id: lined, source: .soundcore, relativePath: "Originals/r.wav", fileName: "r.wav", sha256: "r",
                                              alignment: SourceAlignment(method: .audio, offset: 3, confidence: 0.9, referenceTrackID: deskMic,
                                                                         audioChecked: true)))

        var merged = MeetingMerge.merge(base: base, local: studioCopy, remote: deskCopy).meeting
        XCTAssertEqual(Set(merged.tracks.map(\.id)), [studioMic, studioCall, deskMic, deskCall, phone, lined])
        let separated = merged.separatingCaptureGroups(now: start)
        XCTAssertEqual(Set(separated.keys), [deskMic, deskCall, lined], "The studio Mac, first to start, keeps the timeline")
        XCTAssertTrue(separated.values.allSatisfy { $0.method == .pending })
        XCTAssertEqual(separated[deskMic]?.clockID, desk)
        XCTAssertEqual(separated[lined]?.clockOffset ?? 0, 3 + late, accuracy: 0.1, "What rests on the desk Mac waits too, moved as far")
        XCTAssertNil(separated[lined]?.audioChecked, "…and is compared by sound again")
        XCTAssertEqual(separated[deskMic]?.clockOffset ?? 0, late + 0.1, accuracy: 0.1)
        XCTAssertEqual(separated[deskCall]?.clockOffset ?? 0, late + 0.3, accuracy: 0.1)

        let fused = SourceFusion.fuse(merged, now: start)
        let placed = try XCTUnwrap(fused.settled[deskMic])
        XCTAssertEqual(placed.method, .clock, "Nothing shared to hear or read: the clocks place it")
        XCTAssertEqual(placed.offset ?? 0, late + 0.1, accuracy: 0.1)
        XCTAssertEqual(fused.settled[deskCall]?.offset ?? 0, late + 0.3, accuracy: 0.1)
        merged.applyFusion(fused.fusion)
        merged.applyPlacements(fused.settled)
        XCTAssertEqual(merged.clock(of: studioMic)?.offset, 0.1, "The origin didn't move")
        let remark = try XCTUnwrap(merged.unifiedTranscript.first { $0.text.hasPrefix("someone near the window") })
        XCTAssertEqual(remark.start, 40.1, accuracy: 0.1)
        XCTAssertTrue(merged.separatingCaptureGroups(now: start).isEmpty, "Once")

        // Without the iPhone's measurements, the Macs' own clocks are the prior, 7 s off: the sound searches around it.
        var unmeasured = MeetingMerge.merge(base: base, local: studioCopy, remote: deskCopy).meeting
        unmeasured.tracks.removeAll { $0.id == phone }
        XCTAssertEqual(unmeasured.separatingCaptureGroups(now: start)[deskMic]?.clockOffset ?? 0, late + skew + 0.1, accuracy: 0.1)
    }

    /// A conversation one Mac recorded, microphone, computer audio, and the echo-cancelled copy, is one capture.
    func testOneMacsRecordingIsOneCapture() {
        var mic = RecordingTrack(id: raw, source: .microphone, relativePath: "m", fileName: "m", offset: 0, sha256: "m", startedAt: Date())
        mic.capture = TrackCaptureDetails(method: "microphone")
        var system = RecordingTrack(id: call, source: .systemAudio, relativePath: "c", fileName: "c", offset: 0.4, sha256: "c", startedAt: Date())
        system.capture = TrackCaptureDetails(method: "process-tap")
        var copy = RecordingTrack(id: echo, source: .microphone, relativePath: "e", fileName: "e", offset: 0, sha256: "e", derivedFrom: raw)
        copy.capture = TrackCaptureDetails(method: "echo-cancelled", clockRate: 1)
        XCTAssertTrue(Meeting(tracks: [mic, system, copy]).separatingCaptureGroups().isEmpty)
    }

    // MARK: Names and determinism

    /// A room recorder heard the call through the laptop's speakers, and its diarization put that voice in a cluster
    /// the person named for someone in the room. The call's passage, which the call's own diarization gives to an
    /// unnamed remote speaker, stays theirs. A name that stood on the passage before stays.
    func testANameGivenToARoomClusterDoesntLabelTheCallsPassage() throws {
        let words = "the vendor can deliver the hardware by the end of the month"
        let callTrack = RecordingTrack(id: call, source: .systemAudio, relativePath: "c", fileName: "c", offset: 0, sha256: "c")
        let roomTrack = RecordingTrack(id: recorder, source: .soundcore, relativePath: "r", fileName: "r", offset: 0, sha256: "r")
        var meeting = Meeting(tracks: [callTrack, roomTrack],
                              transcripts: [heard(call, words, at: 3, local: { $0 }, speaker: "remote", created: 1),
                                            heard(recorder, words, at: 3, local: { $0 }, speaker: "roomA", created: 2)],
                              speakers: [Speaker(id: "remote", name: "Speaker 1"), Speaker(id: "roomA", name: "Speaker 2")])
        meeting.renameSpeaker(id: "roomA", name: "Alex (in the room)")
        let fused = SourceFusion.fuse(meeting).fusion
        XCTAssertEqual(fused.segments.map(\.speakerID), ["remote"])
        XCTAssertEqual(SourceFusion.fuse(meeting, version: 1).fusion.segments.map(\.speakerID), ["roomA"], "What version 1 did")

        // A name that stood on the passage itself stays when it's fused again.
        meeting.applyFusion(fused)
        let passage = try XCTUnwrap(meeting.unifiedTranscript.first)
        meeting.unifiedTranscript[0].speakerID = "roomA"
        XCTAssertEqual(SourceFusion.fuse(meeting).fusion.segments.first { $0.id == passage.id }?.speakerID, "roomA")
    }

    /// The Mac and the iPhone fuse the same synced conversation to the same bytes.
    func testTheMacAndTheIPhoneFuseASyncedConversationAlike() throws {
        let words = ["thanks everyone for joining the planning review today", "the launch moves to the second week of march",
                     "we cannot slip the date again so plan for it"]
        var micTrack = RecordingTrack(id: raw, source: .microphone, relativePath: "m", fileName: "m", offset: 0, sha256: "m")
        micTrack.capture = TrackCaptureDetails(method: "microphone", clockRate: 1.000_04)
        let callTrack = RecordingTrack(id: call, source: .systemAudio, relativePath: "c", fileName: "c", offset: 0, sha256: "c")
        let room = RecordingTrack(id: recorder, source: .soundcore, relativePath: "r", fileName: "r", sha256: "r",
                                  alignment: SourceAlignment(method: .pending, clockOffset: 12, audioChecked: true))
        var meeting = Meeting(tracks: [micTrack, callTrack, room])
        let lines = words.enumerated().map { (text: $0.element, at: 20 + Double($0.offset) * 40) }
        meeting.transcripts = [heard(call, lines, local: { $0 }, created: 1), heard(raw, lines, local: { $0 / 1.000_04 }, created: 2),
                               heard(recorder, lines, local: { ($0 - 12.2) / 1.0001 }, created: 3)]
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let synced = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        let onMac = SourceFusion.fuse(meeting, now: now), onPhone = SourceFusion.fuse(synced, now: now)
        var mac = meeting, iPhone = synced
        mac.applyFusion(onMac.fusion); mac.applyPlacements(onMac.settled)
        iPhone.applyFusion(onPhone.fusion); iPhone.applyPlacements(onPhone.settled)
        mac.updatedAt = now; iPhone.updatedAt = now
        XCTAssertEqual(try encoder.encode(mac.unifiedTranscript), try encoder.encode(iPhone.unifiedTranscript))
        XCTAssertEqual(try encoder.encode(mac.fusionSummary), try encoder.encode(iPhone.fusionSummary))
        XCTAssertEqual(try encoder.encode(mac.tracks), try encoder.encode(iPhone.tracks))
        XCTAssertEqual(mac.fusionSummary?.version, FusionSummary.currentVersion)
    }
}

/// Made-up words from a fixed seed, so a test's transcripts are the same every run.
struct SeededWords {
    private var state: UInt64
    private static let syllables = ["ka", "lo", "mi", "ne", "ru", "ta", "po", "se", "vi", "do", "ga", "fe", "zu", "ho", "bi", "ch", "sh", "tr", "pl", "qu"]
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return state }
    mutating func word() -> String {
        var word = ""
        for _ in 0..<(2 + Int(next() % 2)) { word += Self.syllables[Int(next() % UInt64(Self.syllables.count))] }
        return word
    }
    mutating func phrase(_ count: Int) -> String { (0..<count).map { _ in word() }.joined(separator: " ") }
}
