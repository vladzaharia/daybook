import XCTest
@testable import DaybookCore

/// The fusion review's probes (design pass 2026-11, FU-05 and FU-14) as tests: speech several recordings heard comes
/// out once however long the conversation, a run the matching rules miss isn't doubled, recognizers' confidences are
/// compared fairly, and four long recordings fuse within a budget.
final class FusionProbeTests: XCTestCase {
    /// A transcript of `words` (spoken one every 0.4 s from timeline 0), heard by `track` placed at `offset` with clock
    /// `rate`, in passages of `per` words.
    private func transcript(_ track: UUID, _ words: [String], per: Int, offset: Double, rate: Double = 1, speaker: String,
                            first: Int = 0, created: Double, confidence: Double = 0.8, model: String = "") -> TrackTranscript {
        var segments: [TranscriptSegment] = [], timed: [TranscriptWord] = []
        var index = 0
        while index < words.count {
            let chunk = Array(words[index..<min(words.count, index + per)])
            var times: [(Double, Double)] = []
            for (k, word) in chunk.enumerated() {
                let start = (Double(first + index + k) * 0.4 - offset) / rate
                times.append((start, start + 0.3 / rate))
                timed.append(TranscriptWord(text: " " + word, start: start, end: start + 0.3 / rate, confidence: confidence))
            }
            segments.append(TranscriptSegment(trackID: track, start: times[0].0, end: times[times.count - 1].1, text: chunk.joined(separator: " "),
                                              speakerID: speaker, confidence: confidence))
            index += per
        }
        return TrackTranscript(trackID: track, segments: segments, modelID: model, createdAt: Date(timeIntervalSince1970: created), words: timed)
    }

    private func count(_ result: FusionResult) -> Int { result.segments.reduce(0) { $0 + $1.text.split(separator: " ").count } }

    private func vocabulary(_ generator: inout SeededWords) -> [String] { (0..<3_000).map { _ in generator.word() } }

    private func stream(_ count: Int, from vocabulary: [String], _ generator: inout SeededWords) -> [String] {
        (0..<count).map { _ in vocabulary[Int(generator.next() % UInt64(vocabulary.count))] }
    }

    /// The call and a recorder heard the same 3,000 words, the recorder 30 s late and placed by sound up to 0.25 s off,
    /// each cut into passages differently. Fusion version 1 kept a word or two twice where its 240-item regions cut a
    /// passage (3,003); one banded alignment keeps every word once.
    func testThreeThousandSharedWordsComeOutOnce() {
        var generator = SeededWords(seed: 0x9E37_79B9_7F4A_7C15)
        let words = vocabulary(&generator)
        let call = UUID(), room = UUID()
        let tracks = [RecordingTrack(id: call, source: .systemAudio, relativePath: "a", fileName: "a", offset: 0, sha256: "a"),
                      RecordingTrack(id: room, source: .soundcore, relativePath: "b", fileName: "b", sha256: "b")]
        for error in [0, 0.1, 0.2, 0.25] {
            let spoken = stream(3_000, from: words, &generator)
            let transcripts = [transcript(call, spoken, per: 12, offset: 0, speaker: "a:1", created: 1),
                               transcript(room, spoken, per: 17, offset: 30, speaker: "b:1", created: 2)]
            let placed = FusionInputs(placements: [room: TrackPlacement(offset: 30 + error, method: .audio, confidence: 0.9)])
            XCTAssertEqual(count(TranscriptFusion.fuse(transcripts, tracks: tracks, inputs: placed)), 3_000, "placed \(error) s off")
            var before = placed
            before.options.version = 1
            XCTAssertGreaterThan(count(TranscriptFusion.fuse(transcripts, tracks: tracks, inputs: before)), 3_000, "What version 1 did")
        }
    }

    /// Four recordings of 40,000 words (about four and a half hours): the call, the microphone, a recorder on a clock 50
    /// ppm fast, and a phone 40 s early. Every word comes out once, and fusing them takes well under the budget.
    func testFourRecordingsOfFortyThousandWordsComeOutOnceWithinTheBudget() throws {
        var generator = SeededWords(seed: 0xC0FF_EE00_D15E_A5E5)
        let spoken = stream(40_000, from: vocabulary(&generator), &generator)
        let call = UUID(), mic = UUID(), room = UUID(), phone = UUID()
        let tracks = [RecordingTrack(id: call, source: .systemAudio, relativePath: "a", fileName: "a", offset: 0, sha256: "a"),
                      RecordingTrack(id: mic, source: .microphone, relativePath: "m", fileName: "m", offset: 0, sha256: "m"),
                      RecordingTrack(id: room, source: .soundcore, relativePath: "r", fileName: "r", sha256: "r"),
                      RecordingTrack(id: phone, source: .imported, relativePath: "p", fileName: "p", sha256: "p")]
        let transcripts = [transcript(call, spoken, per: 14, offset: 0, speaker: "c:1", created: 1),
                           transcript(mic, spoken, per: 11, offset: 0, speaker: "m:1", created: 2),
                           transcript(room, spoken, per: 19, offset: 12, rate: 1.000_05, speaker: "r:1", created: 3),
                           transcript(phone, spoken, per: 16, offset: -40, speaker: "p:1", created: 4)]
        let inputs = FusionInputs(placements: [room: TrackPlacement(offset: 12, rate: 1.000_05, method: .audio, confidence: 0.9),
                                               phone: TrackPlacement(offset: -40, method: .audio, confidence: 0.9)])
        // This thread's processor time, so a busy machine doesn't count against it.
        func working() -> TimeInterval {
            var time = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
            return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9
        }
        let started = working()
        let fused = TranscriptFusion.fuse(transcripts, tracks: tracks, inputs: inputs)
        let elapsed = working() - started
        XCTAssertEqual(count(fused), 40_000)
        XCTAssertEqual(fused.summary?.words, 40_000)
        // Under a second in a release build; a debug build's budget.
        XCTAssertLessThan(elapsed, 60, "Fusing four long recordings took \(elapsed) s")
        print("Four recordings of 40,000 words fused in \(String(format: "%.2f", elapsed)) s of processor time")
    }

    /// The recorder heard the call through the laptop's speakers and got most of a passage wrong, so too little of it
    /// matches for the matching rules to call it the same speech; but four words in a row are word for word the call's,
    /// at the same moment. Those four are merged, not shown twice; the rest stays the recorder's own.
    func testARunTheMatchingRulesMissIsntDoubled() throws {
        let call = UUID(), room = UUID()
        let tracks = [RecordingTrack(id: call, source: .systemAudio, relativePath: "a", fileName: "a", offset: 0, sha256: "a"),
                      RecordingTrack(id: room, source: .soundcore, relativePath: "b", fileName: "b", offset: 0, sha256: "b")]
        let heard = "we need the quarterly numbers before the board meeting so please send the final draft by tomorrow".split(separator: " ").map(String.init)
        var misheard = heard
        let garbled = ["wheat", "kneed", "thee", "partly", "lumbers", "bee", "fore", "thee", "bored", "eating", "sew"]
        for (index, word) in garbled.enumerated() { misheard[index] = word }
        // Words 11...14 ("send the final draft") are heard right.
        misheard[15] = "bye"; misheard[16] = "tomato"
        let transcripts = [transcript(call, heard, per: 18, offset: 0, speaker: "c:1", created: 1),
                           transcript(room, misheard, per: 18, offset: 0, speaker: "r:1", created: 2)]
        let fused = TranscriptFusion.fuse(transcripts, tracks: tracks)
        let text = fused.segments.map(\.text).joined(separator: " ")
        XCTAssertEqual(text.components(separatedBy: "send the final draft").count - 1, 1, text)
        XCTAssertEqual(count(fused), heard.count + garbled.count + 2)
        var before = FusionInputs()
        before.options.version = 1
        let old = TranscriptFusion.fuse(transcripts, tracks: tracks, inputs: before).segments.map(\.text).joined(separator: " ")
        XCTAssertEqual(old.components(separatedBy: "send the final draft").count - 1, 2, "What version 1 did")
    }

    /// The microphone's recognizer reports 0.95 on almost every word; the recorder's, a different model, about 0.4. The
    /// microphone's least sure word ("Tuesday", 0.9) and the recorder's surest ("Thursday", 0.7) disagree. Compared as
    /// they are, the microphone's 0.9 wins; compared as each recognizer's own ranks, the recorder's word, its surest,
    /// beats the microphone's least sure. With one recognizer, the numbers are compared as they are.
    func testConfidencesFromDifferentRecognizersAreComparedByRank() throws {
        let mic = UUID(), room = UUID()
        let tracks = [RecordingTrack(id: mic, source: .microphone, relativePath: "m", fileName: "m", offset: 0, sha256: "m"),
                      RecordingTrack(id: room, source: .soundcore, relativePath: "r", fileName: "r", offset: 0, sha256: "r")]
        let line = "i will send the revised plan to the team on tuesday after the review".split(separator: " ").map(String.init)
        let day = line.firstIndex(of: "tuesday")!
        func heard(_ track: UUID, _ words: [String], usual: Double, disputed: Double, model: String, created: Double) -> TrackTranscript {
            var output = transcript(track, words, per: words.count, offset: 0, speaker: "\(model):1", created: created, confidence: usual, model: model)
            output.words![day].confidence = disputed
            return output
        }
        var roomWords = line
        roomWords[day] = "thursday"
        let twoModels = [heard(mic, line, usual: 0.95, disputed: 0.9, model: "parakeet", created: 1),
                         heard(room, roomWords, usual: 0.4, disputed: 0.7, model: "whisper", created: 2)]
        let ranked = TranscriptFusion.fuse(twoModels, tracks: tracks)
        XCTAssertEqual(ranked.segments.map(\.text), [roomWords.joined(separator: " ")])
        var sameModel = twoModels
        sameModel[1].modelID = "parakeet"
        XCTAssertEqual(TranscriptFusion.fuse(sameModel, tracks: tracks).segments.map(\.text), [line.joined(separator: " ")])
        var before = FusionInputs()
        before.options.version = 1
        XCTAssertEqual(TranscriptFusion.fuse(twoModels, tracks: tracks, inputs: before).segments.map(\.text), [line.joined(separator: " ")],
                       "What version 1 did")
    }

    /// Upkeep re-fuses a conversation with the version it was fused with; anything else fuses with the current one.
    func testTheSummaryRecordsTheFusionVersion() {
        let call = UUID()
        let meeting = Meeting(tracks: [RecordingTrack(id: call, source: .systemAudio, relativePath: "a", fileName: "a", offset: 0, sha256: "a")],
                              transcripts: [transcript(call, ["hello", "everyone", "and", "welcome"], per: 4, offset: 0, speaker: "a:1", created: 1)])
        XCTAssertEqual(SourceFusion.fuse(meeting).fusion.summary?.version, FusionSummary.currentVersion)
        XCTAssertEqual(SourceFusion.fuse(meeting, version: 1).fusion.summary?.version, 1)
        XCTAssertEqual(SourceFusion.fuse(meeting, version: 99).fusion.summary?.version, FusionSummary.currentVersion)
        XCTAssertEqual(FusionSummary.currentVersion, 2)
    }
}
