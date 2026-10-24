import Accelerate
import XCTest
@testable import DaybookCore

/// All audio here is synthesized in the test (see `SyntheticAudio.swift`): nothing is recorded or downloaded.
final class AudioAlignerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DaybookAlignerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    /// The call as the Mac captures it: remote talker only, clean, 16 kHz PCM, its clock is the reference.
    private func callCapture(_ event: SyntheticEvent, start: Double, duration: Double, name: String = "call.wav") throws -> URL {
        let file = url(name)
        try SyntheticCapture(sampleRate: 16_000, format: .wav16, start: start, duration: duration).write(event.remote, event: event, to: file)
        return file
    }

    /// A room recorder: both talkers with reverb and noise, its own clock and gain, 44.1 kHz AAC.
    private func roomRecorder(_ event: SyntheticEvent, start: Double, duration: Double, rate: Double,
                              name: String = "recorder.m4a") throws -> URL {
        let file = url(name)
        try SyntheticCapture(sampleRate: 44_100, format: .aac, start: start, duration: duration, rate: rate,
                             gains: [1, 0.35, 1.6, 0.6], gainSegment: 47).write(event.room, event: event, to: file)
        return file
    }

    private func analyze(_ other: URL, _ reference: URL, expected: Double? = nil, radius: Double = 0) throws -> AudioAlignmentReport {
        try AudioAligner.analyze(other: other, reference: reference, expectedOffset: expected, searchRadius: radius, cache: nil)
    }

    // MARK: Building blocks

    func testFFTCorrelationMatchesDirectDotProducts() {
        var random = SeededRandom(7)
        let reference = (0..<5_000).map { _ in Float(random.uniform(-1...1)) }
        let correlator = WindowCorrelator(reference: reference)
        let window = reference[1_200..<1_700]
        let wide = correlator.normalizedCorrelation(window: window, positions: 0...4_000)
        let middle = correlator.normalizedCorrelation(window: window, positions: 1_000...1_400)
        let narrow = correlator.normalizedCorrelation(window: window, positions: 1_180...1_220)
        XCTAssertEqual(wide[1_200], 1, accuracy: 1e-4)
        XCTAssertEqual(middle[200], 1, accuracy: 1e-4)
        XCTAssertEqual(narrow[20], 1, accuracy: 1e-4)
        for position in [1_100, 1_250, 1_390] { XCTAssertEqual(wide[position], middle[position - 1_000], accuracy: 1e-4) }
        XCTAssertLessThan(wide.enumerated().filter { abs($0.offset - 1_200) > 2 }.map { abs($0.element) }.max() ?? 1, 0.3)
    }

    func testRobustFitIgnoresOutlyingWindows() {
        var points = (0..<40).map { LagObservation(time: Double($0) * 20, lag: 12.5 + 0.0002 * Double($0) * 20, weight: 1, group: $0) }
        points[5].lag += 3; points[17].lag -= 40; points[30].lag += 0.5
        let consensus = RobustLineFit.consensus(points, primary: points.map { _ in true }, tolerance: 0.06,
                                                maximumSlope: 0.001, minimumSpan: 10, distinctLag: 0.25)
        XCTAssertEqual(consensus?.inliers.count, 37)
        // Huber bounds each outlier's pull; refitting on the close windows removes it.
        let robust = RobustLineFit.huber(points, start: consensus!.line, delta: 0.01)
        XCTAssertEqual(robust.intercept, 12.5, accuracy: 0.002)
        let line = RobustLineFit.huber(points.filter { abs($0.lag - robust.lag(at: $0.time)) <= 0.03 }, start: robust, delta: 0.01)
        XCTAssertEqual(line.intercept, 12.5, accuracy: 1e-6)
        XCTAssertEqual(line.slope, 0.0002, accuracy: 1e-9)
    }

    func testFeaturesRoundTripThroughDiskCache() throws {
        let event = SyntheticEvent.conversation(seed: 3, duration: 40)
        let file = try callCapture(event, start: 0, duration: 39)
        let cacheDirectory = url("cache")
        let digest = try AudioDigest.sha256(fileURL: file)
        let cache = AudioFeatureCache(directory: cacheDirectory)
        let first = try cache.features(for: file, digest: digest)
        XCTAssertEqual(first.frameCount, 3_897, accuracy: 3)
        XCTAssertEqual(first.duration, 39, accuracy: 0.01)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDirectory.appendingPathComponent("\(digest)-v\(AudioFeatures.currentVersion).features").path))
        let reloaded = try AudioFeatureCache(directory: cacheDirectory).features(for: file, digest: digest)
        XCTAssertEqual(reloaded, first)
        XCTAssertEqual(AudioFeatures(serialized: first.serialized()), first)
    }

    // MARK: Accuracy

    /// The recorder starts minutes into the call, runs 200 ppm fast or slow, records at 44.1 kHz
    /// AAC with reverb, noise, a louder local talker, and gain swings; the call is 16 kHz PCM with
    /// only the remote talker. Wide search: no prior.
    private func checkDegradedRecorder(drift ppm: Double, seed: UInt64) throws {
        let event = SyntheticEvent.conversation(seed: seed, duration: 560)
        let call = try callCapture(event, start: 20, duration: 520)
        let recorderStart = 20 + 197.3
        let rate = 1 + ppm / 1_000_000
        let recorder = try roomRecorder(event, start: recorderStart, duration: 300, rate: rate)
        let report = try analyze(recorder, call)
        let alignment = try XCTUnwrap(report.alignment, report.explanation)
        XCTAssertEqual(alignment.offset, 197.3, accuracy: 0.02, report.explanation)
        XCTAssertEqual(alignment.driftPPM, ppm, accuracy: 20, report.explanation)
        XCTAssertGreaterThan(alignment.confidence, 0.4, report.explanation)
        print("degraded \(ppm) ppm: offset error \(String(format: "%.2f", (alignment.offset - 197.3) * 1000)) ms, drift error \(String(format: "%.2f", alignment.driftPPM - ppm)) ppm, confidence \(String(format: "%.3f", alignment.confidence)); \(report.explanation)")
    }

    func testAlignsDegradedRecorderRunningFast() throws { try checkDegradedRecorder(drift: 200, seed: 101) }
    func testAlignsDegradedRecorderRunningSlow() throws { try checkDegradedRecorder(drift: -200, seed: 202) }

    func testPartialOverlapWhereRecorderStartsEarlierAndEndsLater() throws {
        let event = SyntheticEvent.conversation(seed: 303, duration: 520)
        let call = try callCapture(event, start: 110, duration: 300)
        let recorder = try roomRecorder(event, start: 20, duration: 470, rate: 1 + 150e-6)
        let report = try analyze(recorder, call)
        let alignment = try XCTUnwrap(report.alignment, report.explanation)
        XCTAssertEqual(alignment.offset, -90, accuracy: 0.02, report.explanation)
        XCTAssertEqual(alignment.driftPPM, 150, accuracy: 20, report.explanation)
        let overlap = try XCTUnwrap(report.overlap)
        XCTAssertEqual(overlap.lowerBound, 90, accuracy: 0.5)
        XCTAssertEqual(overlap.upperBound, 390, accuracy: 0.5)
        print("partial overlap: offset error \(String(format: "%.2f", (alignment.offset + 90) * 1000)) ms, confidence \(String(format: "%.3f", alignment.confidence)); \(report.explanation)")
    }

    func testRecordingsWithNoSharedSoundReturnNil() throws {
        let first = SyntheticEvent.conversation(seed: 404, duration: 320)
        let second = SyntheticEvent.conversation(seed: 405, duration: 320)
        let call = try callCapture(first, start: 10, duration: 300)
        let unrelated = try roomRecorder(second, start: 10, duration: 300, rate: 1)
        let report = try analyze(unrelated, call)
        XCTAssertNil(report.alignment, "unexpected \(String(describing: report.alignment)): \(report.explanation)")
        XCTAssertNil(try AudioAligner.align(other: unrelated, reference: call, expectedOffset: nil, searchRadius: 0))
        // Same conversation, but the recorder only covers a later stretch the call never captured.
        let later = try roomRecorder(first, start: 220, duration: 95, rate: 1, name: "later.m4a")
        let earlyCall = try callCapture(first, start: 10, duration: 200, name: "early.wav")
        let adjacent = try analyze(later, earlyCall)
        XCTAssertNil(adjacent.alignment, "unexpected \(String(describing: adjacent.alignment)): \(adjacent.explanation)")
    }

    func testConfidenceOrdersCleanDegradedAndShortOverlap() throws {
        let event = SyntheticEvent.conversation(seed: 505, duration: 400)
        let call = try callCapture(event, start: 10, duration: 380)
        let clean = url("clean.wav")
        try SyntheticCapture(sampleRate: 22_050, format: .wav16, start: 70, duration: 240).write(event.remote, event: event, to: clean)
        let degraded = try roomRecorder(event, start: 70, duration: 240, rate: 1 + 80e-6)
        // Only the last 40 seconds of this recorder overlap the call.
        let short = try roomRecorder(event, start: 10 + 380 - 40, duration: 150, rate: 1, name: "short.m4a")
        let a = try XCTUnwrap(try analyze(clean, call).alignment)
        let b = try XCTUnwrap(try analyze(degraded, call).alignment)
        let shortReport = try analyze(short, call)
        let c = try XCTUnwrap(shortReport.alignment, shortReport.explanation)
        XCTAssertEqual(a.offset, 60, accuracy: 0.02); XCTAssertEqual(b.offset, 60, accuracy: 0.02); XCTAssertEqual(c.offset, 340, accuracy: 0.02)
        XCTAssertGreaterThan(a.confidence, b.confidence)
        XCTAssertGreaterThan(b.confidence, c.confidence)
        print("confidence clean \(a.confidence), degraded \(b.confidence), short overlap \(c.confidence)")
    }

    func testPriorNarrowsSearchAndWrongPriorFindsNothing() throws {
        let event = SyntheticEvent.conversation(seed: 606, duration: 300)
        let call = try callCapture(event, start: 5, duration: 280)
        let recorder = try roomRecorder(event, start: 65, duration: 180, rate: 1 - 60e-6)
        let near = try XCTUnwrap(try analyze(recorder, call, expected: 52, radius: 20).alignment)
        XCTAssertEqual(near.offset, 60, accuracy: 0.02)
        XCTAssertNil(try analyze(recorder, call, expected: -200, radius: 30).alignment)
    }

    // MARK: Pipeline

    /// Plan, measure, store, and fuse: the recorder's transcript lands on the call's timeline from
    /// the sound alone (its words are too different to align by text).
    func testMeasuredAlignmentPlacesRecorderTranscriptInFusion() throws {
        let event = SyntheticEvent.conversation(seed: 808, duration: 220)
        let callURL = try callCapture(event, start: 10, duration: 200)
        let recorderURL = try roomRecorder(event, start: 40, duration: 160, rate: 1 + 80e-6)
        let call = RecordingTrack(source: .systemAudio, relativePath: "call.wav", fileName: "call.wav", offset: 0,
                                  sha256: try AudioDigest.sha256(fileURL: callURL))
        let recorder = RecordingTrack(source: .soundcore, relativePath: "recorder.m4a", fileName: "recorder.m4a",
                                      sha256: try AudioDigest.sha256(fileURL: recorderURL))
        func segment(_ track: UUID, _ start: Double, _ text: String) -> TranscriptSegment {
            TranscriptSegment(trackID: track, start: start, end: start + 3, text: text, confidence: 0.8)
        }
        let callTranscript = TrackTranscript(trackID: call.id, segments: [segment(call.id, 50, "Let us review the budget for the spring offsite")])
        // Recorder time = (call time − 30) / rate.
        let local = (50 - 30) / (1 + 80e-6)
        let recorderTranscript = TrackTranscript(trackID: recorder.id, segments: [segment(recorder.id, local, "Let us review the budget for the spring off site"),
                                                                                  segment(recorder.id, 120, "Someone in the room speaking quietly")])
        var meeting = Meeting(tracks: [call, recorder], transcripts: [callTranscript, recorderTranscript])
        let requests = MeetingAudioAlignment.requests(for: meeting)
        XCTAssertEqual(requests.map(\.referenceTrackID), [call.id])
        let measured = MeetingAudioAlignment.measure(requests, in: meeting, urls: [call.id: callURL, recorder.id: recorderURL],
                                                     cache: AudioFeatureCache())
        let alignment = try XCTUnwrap(measured.first?.alignment, measured.first?.explanation ?? "")
        XCTAssertEqual(alignment.offset, 30, accuracy: 0.02)
        XCTAssertEqual(alignment.driftPPM, 80, accuracy: 20)
        meeting.recordAudioAlignments(measured)
        XCTAssertTrue(MeetingAudioAlignment.requests(for: meeting).isEmpty)
        meeting.applyFusion(TranscriptFusion.fuse(meeting: meeting))
        let report = try XCTUnwrap(meeting.alignmentReports.first { $0.trackID == recorder.id })
        XCTAssertEqual(report.method, .audio)
        XCTAssertEqual(report.offset, 30, accuracy: 0.02)
        XCTAssertEqual(meeting.unifiedTranscript.filter { $0.text.contains("budget") }.count, 1)
        XCTAssertEqual(meeting.unifiedTranscript.first { $0.text.contains("quietly") }?.start ?? 0, 150, accuracy: 0.05)
        XCTAssertEqual(meeting.fusionSummary?.sources.first { $0.trackID == recorder.id }?.method, .audio)
    }

    // MARK: Runtime

    /// Budget: under 15 seconds for 30 minutes of each recording in a debug build, decoding
    /// included (measured 2.5 s at load average 50; the margin absorbs a busy machine). That is
    /// 120× real time for the pair. Alignment runs once per attached recording, off the main actor,
    /// so a two-hour meeting stays well under a minute even unoptimized, and cached features make
    /// later alignments against the same recording cheap. Decoding and feature extraction dominate
    /// (about 0.6 s for the PCM file and 1.3 s for the AAC file; the full-range search is about
    /// 0.45 s), so this mainly guards against whole-file buffers or per-sample loops creeping in.
    func testThirtyMinutePairAlignsWithinBudget() throws {
        let event = SyntheticEvent.conversation(seed: 707, duration: 1_920)
        let call = try callCapture(event, start: 10, duration: 1_800)
        let recorder = try roomRecorder(event, start: 105, duration: 1_800, rate: 1 + 120e-6)
        let started = Date()
        let report = try analyze(recorder, call)
        let elapsed = Date().timeIntervalSince(started)
        let alignment = try XCTUnwrap(report.alignment, report.explanation)
        XCTAssertEqual(alignment.offset, 95, accuracy: 0.02)
        XCTAssertEqual(alignment.driftPPM, 120, accuracy: 20)
        XCTAssertLessThan(elapsed, 15, "30-minute pair took \(elapsed) s")
        print("30-minute pair: \(String(format: "%.2f", elapsed)) s; offset error \(String(format: "%.2f", (alignment.offset - 95) * 1000)) ms; drift error \(String(format: "%.2f", alignment.driftPPM - 120)) ppm; \(report.explanation)")
    }
}
