import AVFoundation
import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Apple's built-in sound classifier on synthetic recordings: speech from `say`, music from tones and
/// noise bursts, mixed at known levels. Nothing is downloaded or recorded. Then the engine: what it
/// keeps out of voice profiles, and that a recording is classified once.
final class SoundClassifierTests: XCTestCase {
    // MARK: Fixtures

    static let rate = 16_000.0

    /// Speech from `say` at 16 kHz, or a skip when the voice isn't installed.
    static func speech(_ text: String, voice: String, in folder: URL) throws -> [Float] {
        let url = folder.appendingPathComponent("\(voice)-\(abs(text.hashValue)).wav")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let samples = try? read(url), !samples.isEmpty else {
            throw XCTSkip("The \(voice) voice isn't available to `say` here.")
        }
        return samples
    }

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    static func write(_ samples: [Float], to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        try file.write(from: buffer)
    }

    /// Music-like sound at 120 bpm: a chord progression of harmonic voices, a plucked arpeggio, a bass
    /// line, and kick, snare, and hi-hat from decaying tones and noise. Deterministic.
    static func music(seconds: Double) -> [Float] {
        let count = Int(seconds * rate)
        var out = [Float](repeating: 0, count: count)
        var seed: UInt64 = 7
        func noise() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) * 2 - 1 }
        let beat = 0.5
        let chords: [[Double]] = [[261.63, 329.63, 392.0], [220.0, 261.63, 329.63], [174.61, 220.0, 261.63], [196.0, 246.94, 293.66]]
        for i in 0..<count {
            let t = Double(i) / rate
            let chord = chords[Int(t / (beat * 4)) % chords.count]
            var v = 0.0
            for f in chord { for h in 1...4 { v += sin(2 * .pi * f * Double(h) * t + 0.3 * sin(2 * .pi * 5 * t)) / Double(h * h) * 0.12 } }
            let eighth = Int(t / (beat / 2)), since = t - Double(eighth) * beat / 2
            let note = chord[eighth % 3] * 2
            v += sin(2 * .pi * note * t) * exp(-since * 8) * 0.25 + sin(2 * .pi * note * 2 * t) * exp(-since * 12) * 0.08
            let sinceBeat = t - Double(Int(t / beat)) * beat
            v += sin(2 * .pi * chord[0] / 2 * t) * exp(-sinceBeat * 3) * 0.3
            out[i] = Float(v)
        }
        for b in 0..<Int(seconds / beat) {
            let start = Int(Double(b) * beat * rate)
            for k in 0..<Int(0.25 * rate) where start + k < count {
                let t = Double(k) / rate
                out[start + k] += Float(b % 2 == 0 ? sin(2 * .pi * (60 + 80 * exp(-t * 30)) * t) * exp(-t * 12) * 0.5 : noise() * exp(-t * 20) * 0.3)
            }
            let hat = start + Int(beat / 2 * rate)
            for k in 0..<Int(0.05 * rate) where hat + k < count { out[hat + k] += Float(noise() * exp(-Double(k) / rate * 80) * 0.12) }
        }
        return out
    }

    static func rms(_ x: [Float]) -> Float { sqrt(x.reduce(0) { $0 + $1 * $1 } / Float(max(1, x.count))) }
    /// `x` at `decibels` relative to an RMS of 0.08 (about −22 dBFS).
    static func level(_ x: [Float], _ decibels: Float) -> [Float] {
        let gain = 0.08 * pow(10, decibels / 20) / max(rms(x), 1e-9)
        return x.map { $0 * gain }
    }

    /// Adds `part` into `mix` from `at` seconds, for at most `seconds`.
    static func add(_ part: [Float], into mix: inout [Float], at: Double, seconds: Double? = nil) {
        let start = Int(at * rate), length = seconds.map { Int($0 * rate) } ?? part.count
        for index in 0..<min(part.count, length) where start + index < mix.count { mix[start + index] += part[index] }
    }

    /// The living-room fixture, 64 s: a person alone; a TV across the room (a presenter 10 dB quieter
    /// than the person, over a music bed 3 dB under the presenter); the TV's music alone; the person
    /// over quiet music 20 dB down; a second person over music 12 dB down; the person alone again.
    struct LivingRoom {
        var url: URL
        /// Each stretch as the recognizer and the diarizer would report it, with its truth.
        var segments: [(segment: TranscriptSegment, background: Bool)]
    }

    static func livingRoom(in folder: URL) throws -> LivingRoom {
        let person = "Samantha", other = "Fred", presenter = "Daniel"
        let lines = [
            (person, "Okay, so let's go over the launch plan for next week. Priya will send the checklist on Friday."),
            (presenter, "Tonight on the evening news, heavy rain is expected across the region, and officials urge drivers to stay home."),
            (person, "Sorry, the radio is on in the kitchen. Anyway, I will review the budget numbers with finance before Monday."),
            (other, "That works for me. I think we can cut travel and hold marketing flat this quarter."),
            (person, "Great. Let's meet again on Thursday to make the final call on the launch date."),
        ]
        let voices = try lines.map { try level(speech($0.1, voice: $0.0, in: folder), 0) }
        let bed = music(seconds: 64)
        var mix = [Float](repeating: 0, count: Int(64 * rate))
        let track = UUID()
        var segments: [(TranscriptSegment, Bool)] = []
        func spoken(_ index: Int, at: Double, speaker: String, gain: Float = 0) {
            let samples = gain == 0 ? voices[index] : voices[index].map { $0 * pow(10, gain / 20) }
            add(samples, into: &mix, at: at)
            let end = at + min(11, Double(samples.count) / rate)
            segments.append((TranscriptSegment(trackID: track, start: at + 0.2, end: end, text: lines[index].1, speakerID: speaker), speaker == "TV"))
        }
        spoken(0, at: 0, speaker: "A")                                   // 0–11 s: the person alone
        add(level(bed, -13), into: &mix, at: 12, seconds: 20)            // 12–32 s: the TV's music bed
        spoken(1, at: 12, speaker: "TV", gain: -10)                      // 12–23 s: the presenter, across the room
        segments.append((TranscriptSegment(trackID: track, start: 24.5, end: 31.5, text: "Thank you for watching.", speakerID: "TV"), true))
        add(level(bed, -20), into: &mix, at: 32, seconds: 12)            // 32–44 s: quiet music under the person
        spoken(2, at: 32, speaker: "A")
        add(level(bed, -12), into: &mix, at: 44, seconds: 12)            // 44–56 s: music 12 dB down under the second person
        spoken(3, at: 44, speaker: "B")
        spoken(4, at: 56, speaker: "A")                                  // 56–64 s: the person alone
        let peak = mix.map(abs).max() ?? 1
        if peak > 0.99 { mix = mix.map { $0 / peak * 0.99 } }
        let url = folder.appendingPathComponent("living-room.wav")
        try write(mix, to: url)
        return LivingRoom(url: url, segments: segments)
    }

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("SoundClassifierTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    // MARK: The classifier

    func testTheClassifierTellsMusicFromSpeechInSyntheticAudio() throws {
        var fixture = [Float](repeating: 0, count: Int(24 * Self.rate))
        let voice = try Self.speech("Okay, so let's go over the launch plan for next week. Priya will send the checklist on Friday.",
                                    voice: "Samantha", in: folder)
        Self.add(Self.level(voice, 0), into: &fixture, at: 0, seconds: 10)
        Self.add(Self.level(Self.music(seconds: 12), 0), into: &fixture, at: 12)
        let spoken = min(10, Double(voice.count) / Self.rate)
        let url = folder.appendingPathComponent("speech-then-music.wav")
        try Self.write(fixture, to: url)
        let started = Date()
        let analysis = try SoundClassifier.analyze(url: url)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(analysis.classifier, "SoundAnalysis version1")
        XCTAssertEqual(Double(analysis.frameCount), 23, accuracy: 1)
        let speech = analysis.frames(from: 1, to: spoken - 1), music = analysis.frames(from: 14, to: 22)
        let mean = { (frames: [BackgroundAudioAnalysis.Frame], key: KeyPath<BackgroundAudioAnalysis.Frame, Double>) in
            frames.map { $0[keyPath: key] }.reduce(0, +) / Double(max(1, frames.count))
        }
        XCTAssertGreaterThan(mean(speech, \.speech), 0.8)
        XCTAssertLessThan(mean(speech, \.music), 0.3)
        XCTAssertGreaterThan(mean(music, \.music), 0.8)
        XCTAssertLessThan(mean(music, \.speech), 0.1)
        // Levels follow the signal: speech and music were mixed at the same RMS (about −22 dBFS).
        XCTAssertEqual(speech.compactMap(\.level).sorted()[speech.count / 2], -22, accuracy: 4)
        XCTAssertLessThan(elapsed, 10, "24 s of audio classifies in well under real time")
        print("SoundClassifierTests: speech \(mean(speech, \.speech)) / music \(mean(speech, \.music)); music \(mean(music, \.music)) / speech \(mean(music, \.speech)); \(elapsed) s")
    }

    func testTheLivingRoomKeepsTheConversationAndLeavesTheTVOut() throws {
        let room = try Self.livingRoom(in: folder)
        let analysis = try SoundClassifier.analyze(url: room.url)
        let verdict = BackgroundAudio.judge(room.segments.map(\.segment), analysis: analysis)
        var report: [String] = []
        for (segment, background) in room.segments {
            let frames = analysis.frames(from: segment.start, to: segment.end)
            let speech = frames.map(\.speech).reduce(0, +) / Double(max(1, frames.count))
            let music = frames.map(\.music).reduce(0, +) / Double(max(1, frames.count))
            let judged = verdict.segments[segment.id]
            report.append(String(format: "%@ %.0f–%.0f s speech %.2f music %.2f → %@", segment.speakerID ?? "-", segment.start, segment.end,
                                 speech, music, judged?.rawValue ?? "kept"))
            XCTAssertEqual(judged != nil, background, "\(segment.speakerID ?? "") at \(segment.start) s: \(segment.text)")
        }
        print("SoundClassifierTests living room:\n" + report.joined(separator: "\n"))
        XCTAssertEqual(verdict.speakers["TV"], .broadcast)
        XCTAssertNil(verdict.speakers["A"]); XCTAssertNil(verdict.speakers["B"])
    }

    // MARK: The engine

    private final class Listening: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [String] = []
        private var _embeddedTurns: [SpeakerTurn] = []
        var calls: [String] { lock.withLock { _calls } }
        var embeddedTurns: [SpeakerTurn] { lock.withLock { _embeddedTurns } }
        let analysis: BackgroundAudioAnalysis?

        init(analysis: BackgroundAudioAnalysis?) { self.analysis = analysis }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            lock.withLock { _calls.append("transcribe") }
            func words(_ text: String, from start: Double, to end: Double) -> [RecognizedWord] {
                let parts = text.split(separator: " "), step = (end - start) / Double(parts.count)
                return parts.enumerated().map { RecognizedWord(text: " " + $1, start: start + Double($0) * step, end: start + Double($0 + 1) * step, confidence: 0.9) }
            }
            let lines = [("Let's look at the budget first today", 0.5, 11.5), ("Tonight on the evening news heavy rain", 12.5, 23.5),
                         ("Sorry the TV is on where were we", 24.5, 35.5)]
            return RecognitionResult(segments: lines.map { RecognizedSegment(start: $1, end: $2, text: " " + $0, confidence: 0.9, words: words($0, from: $1, to: $2)) },
                                     language: "en", duration: 36)
        }

        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            lock.withLock { _calls.append("diarize") }
            return SpeakerAnalysis(turns: [SpeakerTurn(speakerID: "0", start: 0, end: 12, confidence: 1), SpeakerTurn(speakerID: "1", start: 12, end: 24, confidence: 1),
                                           SpeakerTurn(speakerID: "0", start: 24, end: 36, confidence: 1)], embeddings: [:])
        }

        func embedVoices(url: URL, analysis: SpeakerAnalysis, model: ModelReference, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            lock.withLock { _calls.append("embed"); _embeddedTurns = analysis.turns }
            return SpeakerAnalysis(turns: analysis.turns, embeddings: ["0": [1, 0], "1": [0, 1]], embeddingModelID: "community-1")
        }

        func classifySound(url: URL, progress: @escaping IntelligenceProgressHandler) async throws -> BackgroundAudioAnalysis? {
            lock.withLock { _calls.append("classify") }
            return analysis
        }

        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            GeneratedMeetingNotes(summary: MeetingSummary(overview: ""), suggestedTerms: [], rawResponse: "", warnings: [])
        }
    }

    /// 0–12 s the person; 12–24 s a quieter presenter over a music bed; 24–36 s the person.
    private func livingRoomFrames() -> BackgroundAudioAnalysis {
        let frames = Array(repeating: (0.95, 0.1, -20.0), count: 12) + Array(repeating: (0.8, 0.7, -28.0), count: 12)
            + Array(repeating: (0.95, 0.1, -20.0), count: 12)
        return BackgroundAudioAnalysis(classifier: "test", analyzedAt: Date(timeIntervalSince1970: 0), hop: 1, window: 2,
                                       speech: frames.map(\.0), music: frames.map(\.1), audience: frames.map { _ in 0 }, level: frames.map(\.2))
    }

    private let configuration = InferenceProcessingEngine.Configuration(
        transcriptionModel: "parakeet/ultra", summaryModel: "gemma-4/12b-4bit", detectSpeakers: true, speakerModel: "nemotron-3-diarization/offline",
        voiceEmbeddingModel: "community-1/offline", speakerOptions: SpeakerAnalysisOptions(), fingerprint: "f",
        speakerMatchThreshold: 0.82, speakerMatchMargin: 0.06)

    private func input(_ track: RecordingTrack) -> TrackProcessingInput {
        TrackProcessingInput(meetingID: UUID(), track: track, audioURL: URL(fileURLWithPath: "/tmp/room.caf"), mode: .newAudio)
    }

    func testABroadcastVoiceGetsNoVoiceProfileAndItsTurnsArentEmbedded() async throws {
        let inference = Listening(analysis: livingRoomFrames())
        let engine = InferenceProcessingEngine(inference: inference, configuration: configuration)
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/room.caf", fileName: "room.caf", duration: 36, sha256: "r")
        let output = try await engine.transcribe(input(track), progress: { _ in })
        XCTAssertEqual(inference.calls, ["transcribe", "diarize", "classify", "embed"])
        XCTAssertEqual(inference.embeddedTurns.map(\.speakerID), ["0", "0"], "The presenter's turn isn't evidence for any voice profile")
        let run = output.transcript.id.uuidString
        XCTAssertEqual(output.speakers.first { $0.id == "\(run):0" }?.embedding, [1, 0])
        XCTAssertNil(output.speakers.first { $0.id == "\(run):1" }?.embedding, "A TV's voice gets no profile")
        XCTAssertEqual(output.transcript.segments.count, 3, "The run keeps every passage")
        XCTAssertEqual(output.backgroundAudio, livingRoomFrames())

        // Applied, the analysis stays on the track, and fusion leaves the presenter out.
        var meeting = Meeting(tracks: [track])
        meeting.apply(output, matching: nil, allowSameSource: false)
        XCTAssertNotNil(meeting.tracks[0].backgroundAudio)
        meeting.applyFusion(SourceFusion.fuse(meeting).fusion)
        XCTAssertEqual(meeting.unifiedTranscript.map(\.text), ["Let's look at the budget first today", "Sorry the TV is on where were we"])
        XCTAssertEqual(meeting.backgroundPassages?.map(\.text), ["Tonight on the evening news heavy rain"])
        XCTAssertFalse(MeetingEvidence.transcript(meeting).contains("evening news"), "The summary never reads it")
    }

    func testARecordingIsClassifiedOnceAndAFailedClassifierLeavesEverythingIn() async throws {
        var track = RecordingTrack(source: .microphone, relativePath: "Originals/room.caf", fileName: "room.caf", duration: 36, sha256: "r")
        track.backgroundAudio = livingRoomFrames()
        let stored = Listening(analysis: nil)
        let output = try await InferenceProcessingEngine(inference: stored, configuration: configuration).transcribe(input(track), progress: { _ in })
        XCTAssertFalse(stored.calls.contains("classify"), "The track's analysis is reused: the audio hasn't changed")
        XCTAssertEqual(output.backgroundAudio, track.backgroundAudio)

        let silent = Listening(analysis: nil)
        track.backgroundAudio = nil
        let unheard = try await InferenceProcessingEngine(inference: silent, configuration: configuration).transcribe(input(track), progress: { _ in })
        XCTAssertNil(unheard.backgroundAudio)
        XCTAssertEqual(silent.embeddedTurns.count, 3, "Without an analysis nothing is left out")
        XCTAssertTrue(unheard.notices.isEmpty)
    }
}
