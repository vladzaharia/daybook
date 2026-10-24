import XCTest
@testable import DaybookCore

/// A call recorded three ways: computer audio (remote side), the Mac microphone (raw and
/// echo-cancelled), and a room recorder started 95 s earlier on a clock 100 ppm fast.
final class MultiSourceFusionTests: XCTestCase {
    let system = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    let micRaw = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    let mic = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    let room = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    struct Line { var start: Double; var text: String; var speaker: String?; var confidence: Double = 0.85 }

    let r1 = "Thanks everyone for joining the quarterly planning review today"
    let o1 = "Happy to be here and I have the latest numbers ready"
    let r2 = "Could you walk us through the revenue forecast for next quarter"
    let o2 = "Revenue should grow about twelve percent if the launch stays on schedule"
    let r3 = "That sounds reasonable but we cannot slip the launch again"
    let o3 = "Agreed I will confirm the date with engineering by Friday"
    let r4 = "Great please send the summary to the whole team afterwards"
    let c1 = "I can help with the slides for that meeting"

    /// Room recorder clock: mic time = −95 + 1.0001 × room time.
    let roomAlignment = AudioAlignment(offset: -95, rate: 1.0001, confidence: 0.92)
    func roomLocal(_ meeting: Double) -> Double { (meeting + 95) / 1.0001 }

    /// One segment per group of lines, with recognizer word timings (0.35 s per word) in the
    /// recording's own clock. `edits` replaces words to simulate recognition errors.
    func transcript(_ track: UUID, _ segments: [[Line]], local: (Double) -> Double = { $0 },
                    edits: [String: (String, Double)] = [:], created: TimeInterval = 1) -> TrackTranscript {
        var output: [TranscriptSegment] = [], words: [TranscriptWord] = []
        for group in segments {
            var texts: [String] = [], times: [(Double, Double)] = [], confidences: [Double] = []
            for line in group {
                for (index, word) in line.text.split(separator: " ").map(String.init).enumerated() {
                    let start = line.start + 0.35 * Double(index)
                    let replaced = edits[word]
                    texts.append(replaced?.0 ?? word)
                    times.append((local(start), local(start + 0.3)))
                    confidences.append(replaced?.1 ?? line.confidence)
                    words.append(TranscriptWord(text: " " + (replaced?.0 ?? word), start: local(start), end: local(start + 0.3),
                                                confidence: replaced?.1 ?? line.confidence))
                }
            }
            output.append(TranscriptSegment(trackID: track, start: times.first!.0, end: times.last!.1, text: texts.joined(separator: " "),
                                            speakerID: group[0].speaker, confidence: confidences.reduce(0, +) / Double(confidences.count)))
        }
        return TrackTranscript(trackID: track, segments: output, createdAt: Date(timeIntervalSince1970: created), words: words)
    }

    var tracks: [RecordingTrack] {
        [RecordingTrack(id: system, source: .systemAudio, relativePath: "s.caf", fileName: "Computer audio", offset: 0, sha256: "system"),
         RecordingTrack(id: micRaw, source: .microphone, relativePath: "m.caf", fileName: "Microphone", offset: 0, sha256: "mic"),
         RecordingTrack(id: mic, source: .microphone, relativePath: "e.caf", fileName: "Microphone (echo-cancelled)",
                        sha256: "aec", derivedFrom: micRaw, processing: "echo-cancelled"),
         RecordingTrack(id: room, source: .soundcore, relativePath: "r.m4a", fileName: "Recorder", sha256: "room")]
    }

    var systemTranscript: TrackTranscript {
        // The call audio misrecognizes "summary" with low confidence.
        transcript(system, [[Line(start: 0, text: r1, speaker: "sys:S1")], [Line(start: 10, text: r2, speaker: "sys:S2")],
                            [Line(start: 23, text: r3, speaker: "sys:S1")], [Line(start: 35, text: r4, speaker: "sys:S2")]],
                   edits: ["summary": ("summery", 0.4)])
    }
    /// The raw microphone also hears the call through the laptop speakers; it must not be fused.
    var rawMicTranscript: TrackTranscript {
        transcript(micRaw, [[Line(start: 0, text: r1, speaker: "raw:S2")], [Line(start: 5, text: o1, speaker: "raw:S1")],
                            [Line(start: 10, text: r2, speaker: "raw:S2")], [Line(start: 16, text: o2, speaker: "raw:S1")],
                            [Line(start: 23, text: r3, speaker: "raw:S2")], [Line(start: 29, text: o3, speaker: "raw:S1")],
                            [Line(start: 35, text: r4, speaker: "raw:S2")]], created: 2)
    }
    /// Echo cancellation leaves two quiet fragments of the call.
    var micTranscript: TrackTranscript {
        transcript(mic, [[Line(start: 5, text: o1, speaker: "mic:S1", confidence: 0.9)],
                         [Line(start: 10, text: "Could you walk us through the revenue forecast", speaker: "mic:S2", confidence: 0.7)],
                         [Line(start: 16, text: o2, speaker: "mic:S1", confidence: 0.9)],
                         [Line(start: 29, text: o3, speaker: "mic:S1", confidence: 0.9)],
                         [Line(start: 35, text: "Great please send the summary to the whole team", speaker: "mic:S2", confidence: 0.8)]],
                   created: 3)
    }
    /// The room recorder hears everyone, segments differently, mishears one word, and also catches
    /// a colleague far from the Mac.
    var roomTranscript: TrackTranscript {
        transcript(room, [[Line(start: 0, text: r1, speaker: "room:B", confidence: 0.75)],
                          [Line(start: 5, text: o1, speaker: "room:A", confidence: 0.8)],
                          [Line(start: 10, text: "Could you walk us through", speaker: "room:B", confidence: 0.75)],
                          [Line(start: 11.75, text: "the revenue forecast for next quarter", speaker: "room:B", confidence: 0.75)],
                          [Line(start: 16, text: o2, speaker: "room:A", confidence: 0.8)],
                          [Line(start: 23, text: r3, speaker: "room:B", confidence: 0.75)],
                          [Line(start: 29, text: o3, speaker: "room:A", confidence: 0.8)],
                          [Line(start: 35, text: r4, speaker: "room:B", confidence: 0.8)],
                          [Line(start: 42, text: c1, speaker: "room:C", confidence: 0.8)]],
                   local: roomLocal, edits: ["reasonable": ("seasonable", 0.6)], created: 4)
    }
    var roomRecord: TrackAudioAlignment {
        TrackAudioAlignment(trackID: room, referenceTrackID: micRaw, alignment: roomAlignment, trackDigest: "room", referenceDigest: "mic")
    }

    func fuseAll() -> FusionResult {
        TranscriptFusion.fuse([systemTranscript, rawMicTranscript, micTranscript, roomTranscript], tracks: tracks,
                              inputs: FusionInputs(audioAlignments: [roomRecord]))
    }

    // MARK: Timing

    func testAudioAlignmentPlacesRecorderAndDerivedMicrophoneInheritsCaptureTiming() throws {
        let result = fuseAll()
        let recorder = try XCTUnwrap(result.alignments.first { $0.trackID == room })
        XCTAssertEqual(recorder.method, .audio)
        XCTAssertEqual(recorder.offset, -95, accuracy: 1e-9)
        XCTAssertEqual(recorder.driftPPM, 100, accuracy: 1e-6)
        XCTAssertEqual(recorder.confidence, 0.92)
        XCTAssertEqual(recorder.referenceTrackID, micRaw)
        XCTAssertEqual(result.alignments.first { $0.trackID == mic }?.method, .provided)
        XCTAssertEqual(result.alignments.first { $0.trackID == micRaw }?.method, .provided)
        let summary = try XCTUnwrap(result.summary)
        let reports = Dictionary(uniqueKeysWithValues: summary.sources.map { ($0.trackID, $0) })
        XCTAssertEqual(reports[room]?.method, .audio)
        XCTAssertEqual(reports[room]?.role, .room)
        XCTAssertEqual(reports[room]?.driftPPM ?? 0, 100, accuracy: 1e-6)
        XCTAssertEqual(reports[micRaw]?.included, false)
        XCTAssertEqual(reports[mic]?.included, true)
        XCTAssertEqual(reports[system]?.role, .call)
    }

    /// The pipeline may decide placements itself, or (as `SourceFusion` does) rescale a recording's
    /// segments and cite their original times in provenance. Both must give the same transcript,
    /// with provenance in the recorder's own clock.
    func testCallerPlacementsAndRescaledSegmentsMatchMeasuredAlignment() throws {
        let system = systemTranscript, raw = rawMicTranscript, mic = micTranscript, room = roomTranscript
        let measured = TranscriptFusion.fuse([system, raw, mic, room], tracks: tracks, inputs: FusionInputs(audioAlignments: [roomRecord]))
        let placed = TranscriptFusion.fuse([system, raw, mic, room], tracks: tracks, inputs: FusionInputs(placements: [
            self.room: TrackPlacement(offset: -95, rate: 1.0001, method: .audio, confidence: 0.92)]))
        XCTAssertEqual(placed.segments, measured.segments)
        XCTAssertEqual(placed.alignments.first { $0.trackID == self.room }?.method, .audio)
        var rescaled = room
        rescaled.knownOffset = -95
        rescaled.segments = room.segments.map { segment in
            var copy = segment
            copy.provenance = [SegmentProvenance(trackID: segment.trackID, segmentID: segment.id, start: segment.start, end: segment.end,
                                                 text: segment.text, confidence: segment.confidence)]
            copy.start = segment.start * 1.0001; copy.end = segment.end * 1.0001
            return copy
        }
        var stamped = tracks
        stamped[3].offset = -95
        let legacy = TranscriptFusion.fuse([system, raw, mic, rescaled], tracks: stamped)
        XCTAssertEqual(legacy.segments.map(\.text), measured.segments.map(\.text))
        XCTAssertEqual(legacy.segments.map(\.speakerID), measured.segments.map(\.speakerID))
        let third = try XCTUnwrap(legacy.segments.first { $0.text == r3 }?.provenance.first { $0.trackID == self.room })
        XCTAssertEqual(third.start, roomLocal(23), accuracy: 1e-9)
        for (a, b) in zip(legacy.segments, measured.segments) { XCTAssertEqual(a.start, b.start, accuracy: 1e-6) }
    }

    func testFallsBackFromWeakAudioToSharedPhrasesThenToStartTimes() throws {
        var weak = roomRecord
        weak.alignment?.confidence = 0.1
        let anchored = TranscriptFusion.fuse([systemTranscript, micTranscript, roomTranscript], tracks: tracks,
                                             inputs: FusionInputs(audioAlignments: [weak]))
        let viaText = try XCTUnwrap(anchored.alignments.first { $0.trackID == room })
        XCTAssertEqual(viaText.method, .anchors)
        XCTAssertEqual(viaText.offset, -95, accuracy: 0.05)
        XCTAssertEqual(viaText.rate, 1.0001, accuracy: 0.001)

        // Different bytes than measured: the measurement is ignored.
        var stale = roomRecord
        stale.trackDigest = "other-bytes"
        let ignored = TranscriptFusion.fuse([systemTranscript, micTranscript, roomTranscript], tracks: tracks,
                                            inputs: FusionInputs(audioAlignments: [stale]))
        XCTAssertEqual(ignored.alignments.first { $0.trackID == room }?.method, .anchors)

        // A recording sharing neither sound nor phrases is placed by start times, flagged as weak.
        let unrelated = TrackTranscript(trackID: room, segments: [TranscriptSegment(trackID: room, start: 3, end: 7, text: "Completely different words about gardening")])
        let start = Date(timeIntervalSince1970: 1_000)
        let placed = TranscriptFusion.fuse([systemTranscript, unrelated], tracks: tracks,
                                           inputs: FusionInputs(recordingStartDates: [system: start, room: start.addingTimeInterval(60)]))
        let byClock = try XCTUnwrap(placed.alignments.first { $0.trackID == room })
        XCTAssertEqual(byClock.method, .timestamps)
        XCTAssertEqual(byClock.offset, 60, accuracy: 1e-9)
        XCTAssertEqual(byClock.confidence, 0.2)
        XCTAssertTrue(placed.segments.contains { $0.text.contains("gardening") && abs($0.start - 63) < 1e-9 })
        // Without start times it stays out of the unified transcript.
        let unplaced = TranscriptFusion.fuse([systemTranscript, unrelated], tracks: tracks)
        XCTAssertEqual(unplaced.unalignedTrackIDs, [room])
    }

    // MARK: Words

    func testEachUtteranceAppearsOnceAcrossSources() {
        let result = fuseAll()
        let texts = result.segments.map(\.text)
        for line in [r1, o1, r2, o2, r3, o3, r4, c1] {
            XCTAssertEqual(texts.filter { $0 == line }.count, 1, "\(line) in \(texts)")
        }
        XCTAssertEqual(result.segments.count, 8, "\(texts)")
        let words = [r1, o1, r2, o2, r3, o3, r4, c1].map { $0.split(separator: " ").count }.reduce(0, +)
        XCTAssertEqual(result.summary?.words, words)
        // The raw microphone's copy of the call contributed nothing.
        XCTAssertFalse(result.segments.flatMap(\.provenance).contains { $0.trackID == micRaw })
        let reports = Dictionary(uniqueKeysWithValues: result.summary!.sources.map { ($0.trackID, $0) })
        XCTAssertEqual(reports[room]?.wordsMerged, words - c1.split(separator: " ").count)
        XCTAssertGreaterThan(reports[mic]?.wordsMerged ?? 0, 0)
    }

    func testBestSourceWinsPerRegion() throws {
        let result = fuseAll()
        // Remote speech: the call's wording beats the room's confident mishearing ("seasonable").
        let third = try XCTUnwrap(result.segments.first { $0.text == r3 })
        XCTAssertEqual(third.trackID, system)
        // But two recordings agreeing outvote the call's low-confidence "summery".
        XCTAssertTrue(result.segments.contains { $0.text == r4 })
        XCTAssertFalse(result.segments.contains { $0.text.contains("summery") })
        // Local speech: the microphone is the primary source.
        XCTAssertEqual(result.segments.first { $0.text == o2 }?.trackID, mic)
        // Only the recorder heard the colleague.
        XCTAssertEqual(result.segments.first { $0.text == c1 }?.trackID, room)
    }

    func testCrosstalkSharingCommonWordsStaysSeparate() {
        let remote = "We need to ship the release candidate to the customer today"
        let owner = "I think the team wants to wait until the review"
        let call = transcript(system, [[Line(start: 0, text: remote, speaker: "sys:S1")]])
        let local = transcript(mic, [[Line(start: 0.4, text: owner, speaker: "mic:S1")]], created: 2)
        let result = TranscriptFusion.fuse([call, local], tracks: [tracks[0], tracks[2]].map { var t = $0; t.offset = 0; return t })
        XCTAssertEqual(Set(result.segments.map(\.text)), [remote, owner])
        XCTAssertTrue(result.segments.allSatisfy { $0.provenance.count == 1 })
        XCTAssertEqual(result.segments.first { $0.text == owner }?.speakerID, "owner")
    }

    func testSignalQualityDecidesBetweenRecordersForLocalSpeech() {
        let left = UUID(), right = UUID()
        let tracks = [RecordingTrack(id: left, source: .soundcore, relativePath: "l", fileName: "l", offset: 0, sha256: "l"),
                      RecordingTrack(id: right, source: .imported, relativePath: "r", fileName: "r", offset: 0, sha256: "r")]
        let a = transcript(left, [[Line(start: 0, text: "Please book the larger meeting room for Thursday", speaker: "l:1", confidence: 0.8)]],
                           edits: ["larger": ("lager", 0.8)])
        let b = transcript(right, [[Line(start: 0, text: "Please book the larger meeting room for Thursday", speaker: "r:1", confidence: 0.8)]], created: 2)
        func fused(_ leftSNR: Float, _ rightSNR: Float) -> String {
            TranscriptFusion.fuse([a, b], tracks: tracks, inputs: FusionInputs(signalQuality: [
                left: SignalQualityProfile(interval: 1, snr: Array(repeating: leftSNR, count: 10)),
                right: SignalQualityProfile(interval: 1, snr: Array(repeating: rightSNR, count: 10))])).segments.map(\.text).joined()
        }
        XCTAssertEqual(fused(5, 30), "Please book the larger meeting room for Thursday")
        XCTAssertEqual(fused(30, 5), "Please book the lager meeting room for Thursday")
    }

    func testProvenanceRecordsWhichSourceSuppliedEachWord() throws {
        let result = fuseAll()
        let third = try XCTUnwrap(result.segments.first { $0.text == r3 })
        let bySource = Dictionary(uniqueKeysWithValues: third.provenance.map { ($0.trackID, $0) })
        XCTAssertEqual(Set(bySource.keys), [system, room])
        let index = r3.split(separator: " ").firstIndex(of: "reasonable")!
        XCTAssertEqual(bySource[system]?.wordIndices, Array(0..<10))
        XCTAssertEqual(bySource[room]?.wordIndices, Array(0..<10).filter { $0 != index })
        XCTAssertTrue(bySource[room]?.text.contains("seasonable") ?? false)
        // Source times stay in each recording's own clock.
        XCTAssertEqual(bySource[system]?.start ?? 0, 23, accuracy: 1e-9)
        XCTAssertEqual(bySource[room]?.start ?? 0, roomLocal(23), accuracy: 1e-9)
        // A passage the recorder split in two is one passage here, citing both of its segments.
        let second = try XCTUnwrap(result.segments.first { $0.text == r2 })
        XCTAssertEqual(second.provenance.filter { $0.trackID == room }.count, 2)
        XCTAssertEqual(second.provenance.first?.trackID, system)
        XCTAssertTrue(second.provenance.contains { $0.trackID == mic && $0.wordIndices == Array(0..<8) })
    }

    // MARK: Speakers

    func testOwnerComesFromMicrophoneAndRemoteSpeakersFromCall() throws {
        let result = fuseAll()
        let summary = try XCTUnwrap(result.summary)
        XCTAssertEqual(summary.ownerSpeakerID, "owner")
        XCTAssertEqual(result.addedSpeakers, [Speaker(id: "owner", name: "Me", sourceTrackID: mic)])
        func speaker(_ text: String) -> String? { result.segments.first { $0.text == text }?.speakerID }
        XCTAssertEqual([o1, o2, o3].map(speaker), ["owner", "owner", "owner"])
        XCTAssertEqual([r1, r2, r3, r4].map(speaker), ["sys:S1", "sys:S2", "sys:S1", "sys:S2"])
        XCTAssertEqual(speaker(c1), "room:C")
        let mappings = summary.speakerMappings.map { "\($0.sourceSpeakerID ?? "-")>\($0.speakerID):\($0.reason.rawValue)" }
        XCTAssertTrue(mappings.contains("mic:S1>owner:owner"), "\(mappings)")
        XCTAssertTrue(mappings.contains("mic:S2>sys:S2:sharedSpeech"), "\(mappings)")
        XCTAssertTrue(mappings.contains("room:A>owner:sharedSpeech"), "\(mappings)")
        // The room hears both remote voices through one speaker: no single mapping.
        XCTAssertFalse(mappings.contains { $0.hasPrefix("room:B>") }, "\(mappings)")
    }

    func testCooccurrenceMatchingRequiresDominantSharedSpeech() {
        let matches = SpeakerMatcher.matchByCooccurrence([
            .init(sourceSpeakerID: "a", targetSpeakerID: "x", weight: 9), .init(sourceSpeakerID: "a", targetSpeakerID: "y", weight: 1),
            .init(sourceSpeakerID: "b", targetSpeakerID: "x", weight: 3), .init(sourceSpeakerID: "b", targetSpeakerID: "y", weight: 3),
            .init(sourceSpeakerID: "c", targetSpeakerID: "z", weight: 2),
            .init(sourceSpeakerID: "d", targetSpeakerID: "x", weight: 8)])
        let byID = Dictionary(uniqueKeysWithValues: matches.map { ($0.sourceSpeakerID, $0) })
        XCTAssertEqual(byID["a"]?.status, .conflictingAssignment) // "d" claims x with similar weight
        XCTAssertEqual(byID["d"]?.status, .conflictingAssignment)
        XCTAssertEqual(byID["b"]?.status, .belowThreshold)
        XCTAssertEqual(byID["c"]?.status, .belowThreshold)
        let clear = SpeakerMatcher.matchByCooccurrence([.init(sourceSpeakerID: "a", targetSpeakerID: "x", weight: 9),
                                                        .init(sourceSpeakerID: "d", targetSpeakerID: "x", weight: 3)])
        XCTAssertEqual(clear.first { $0.sourceSpeakerID == "a" }?.targetSpeakerID, "x")
    }

    // MARK: Rebuilds

    func testCorrectionsAndSpeakerNamesSurviveAddingRecorder() throws {
        var meeting = Meeting(tracks: Array(tracks.prefix(3)), transcripts: [systemTranscript, rawMicTranscript, micTranscript])
        meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        XCTAssertTrue(meeting.speakers.contains { $0.id == "owner" && $0.name == "Me" })
        let target = try XCTUnwrap(meeting.unifiedTranscript.first { $0.text == o2 })
        let corrected = "Revenue should grow about 12 percent if the launch stays on schedule"
        meeting.correctSegment(id: target.id, text: corrected)
        meeting.renameSpeaker(id: "owner", name: "Alex")
        let before = meeting.unifiedTranscript

        meeting.tracks.append(tracks[3])
        meeting.transcripts.append(roomTranscript)
        meeting.recordAudioAlignments([roomRecord])
        let issues = meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        XCTAssertTrue(issues.isEmpty, "\(issues)")
        let after = try XCTUnwrap(meeting.unifiedTranscript.first { $0.id == target.id })
        XCTAssertEqual(after.text, corrected)
        XCTAssertEqual(after.speakerID, "owner")
        XCTAssertTrue(after.provenance.contains { $0.trackID == room })
        XCTAssertEqual(meeting.speakers.filter { $0.id == "owner" }.map(\.name), ["Alex"])
        // Every earlier passage keeps its identity; the recorder only adds the colleague.
        XCTAssertEqual(Set(before.map(\.id)).subtracting(meeting.unifiedTranscript.map(\.id)), [])
        XCTAssertEqual(meeting.unifiedTranscript.count, before.count + 1)
        XCTAssertEqual(meeting.fusionSummary?.sources.count, 4)
        // And again: rebuilding is stable.
        let again = meeting
        meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        XCTAssertEqual(meeting.unifiedTranscript, again.unifiedTranscript)
        XCTAssertEqual(meeting.fusionSummary, again.fusionSummary)
    }

    /// The recorder runs the owner's reply and the next remote sentence together, so one recorder
    /// segment is cited by two passages. A correction on either must stay on its passage.
    func testCorrectionStaysOnItsPassageWhenARecorderSegmentSpansTwo() throws {
        var combined = roomTranscript
        let merged = transcript(room, [[Line(start: 29, text: o3, speaker: "room:A", confidence: 0.8),
                                        Line(start: 35, text: r4, speaker: "room:A", confidence: 0.8)]], local: roomLocal)
        combined.segments = combined.segments.filter { ![o3, r4].contains($0.text) } + merged.segments
        combined.words = nil
        var meeting = Meeting(tracks: tracks, transcripts: [systemTranscript, micTranscript, combined])
        meeting.recordAudioAlignments([roomRecord])
        meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        let reply = try XCTUnwrap(meeting.unifiedTranscript.first { $0.text == o3 })
        let remote = try XCTUnwrap(meeting.unifiedTranscript.first { $0.text == r4 })
        XCTAssertEqual(Set(reply.provenance.map(\.segmentID)).intersection(remote.provenance.map(\.segmentID)), [merged.segments[0].id])
        meeting.correctSegment(id: reply.id, text: "Agreed I will confirm the date with engineering by Thursday")
        meeting.correctSegment(id: remote.id, text: "Great please send the summary to the whole team afterward")
        let issues = meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        XCTAssertTrue(issues.isEmpty, "\(issues)")
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.id == reply.id }?.text, "Agreed I will confirm the date with engineering by Thursday")
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.id == remote.id }?.text, "Great please send the summary to the whole team afterward")
    }

    func testRenamedMicrophoneSpeakerKeepsItsNameAsOwner() throws {
        var meeting = Meeting(tracks: [tracks[0], tracks[2]], transcripts: [systemTranscript])
        meeting.speakers = [Speaker(id: "mic:S1", name: "Speaker 1", sourceTrackID: mic)]
        meeting.renameSpeaker(id: "mic:S1", name: "Alex")
        meeting.transcripts.append(micTranscript)
        meeting.tracks[1].offset = 0
        let result = TranscriptFusion.fuse(meeting: meeting)
        XCTAssertEqual(result.summary?.ownerSpeakerID, "mic:S1")
        XCTAssertTrue(result.addedSpeakers.isEmpty)
        XCTAssertEqual(result.segments.first { $0.text == o1 }?.speakerID, "mic:S1")
    }

    func testFusionIsDeterministicAndRoundTripsThroughJSON() throws {
        let transcripts = [systemTranscript, rawMicTranscript, micTranscript, roomTranscript]
        let inputs = FusionInputs(audioAlignments: [roomRecord])
        let first = TranscriptFusion.fuse(transcripts, tracks: tracks, inputs: inputs)
        let second = TranscriptFusion.fuse(transcripts.reversed().reversed(), tracks: tracks, inputs: inputs)
        XCTAssertEqual(first.segments, second.segments)
        XCTAssertEqual(first.summary, second.summary)
        var meeting = Meeting(tracks: tracks, transcripts: transcripts)
        meeting.recordAudioAlignments([roomRecord])
        meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(decoded, meeting)
        // Libraries written before these fields existed still decode.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        object.removeValue(forKey: "fusionSummary"); object.removeValue(forKey: "audioAlignments")
        let legacy = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.fusionSummary); XCTAssertNil(legacy.audioAlignments)
    }

    func testSyncKeepsNewestMeasurementAndFusionSummaryWithItsTranscript() {
        var base = Meeting(tracks: tracks, transcripts: [systemTranscript, micTranscript, roomTranscript])
        base.applyFusion(TranscriptFusion.fuse(meeting: base))
        var local = base, remote = base
        var older = roomRecord; older.measuredAt = Date(timeIntervalSince1970: 100)
        var newer = roomRecord; newer.measuredAt = Date(timeIntervalSince1970: 200); newer.alignment?.confidence = 0.95
        local.recordAudioAlignments([older]); remote.recordAudioAlignments([newer])
        remote.applyFusion(TranscriptFusion.fuse(meeting: remote))
        let merged = MeetingMerge.merge(base: base, local: local, remote: remote)
        XCTAssertEqual(merged.meeting.audioAlignments, [newer])
        XCTAssertFalse(merged.warnings.contains { $0.contains("audio-alignment") })
        XCTAssertEqual(merged.meeting.unifiedTranscript, remote.unifiedTranscript)
        XCTAssertEqual(merged.meeting.fusionSummary, remote.fusionSummary)
    }

    // MARK: Planning audio alignment

    func testPlansRecorderAgainstRawMicrophoneThenCallAndSkipsMeasuredPairs() {
        var meeting = Meeting(tracks: tracks)
        let start = Date(timeIntervalSince1970: 5_000)
        let requests = MeetingAudioAlignment.requests(for: meeting, recordingStartDates: [room: start, micRaw: start.addingTimeInterval(97)])
        XCTAssertEqual(requests.map(\.trackID), [room, room])
        XCTAssertEqual(requests.map(\.referenceTrackID), [micRaw, system])
        XCTAssertEqual(requests[0].expectedOffset, -97)
        XCTAssertEqual(requests[0].searchRadius, 600)
        XCTAssertNil(requests[1].expectedOffset)
        meeting.recordAudioAlignments([roomRecord])
        XCTAssertEqual(MeetingAudioAlignment.requests(for: meeting).map(\.referenceTrackID), [system])
    }
}
