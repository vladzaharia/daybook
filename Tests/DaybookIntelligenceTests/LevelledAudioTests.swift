import AVFoundation
import DaybookCore
import DaybookKit
import DaybookTestSupport
import Foundation
import XCTest
@testable import DaybookIntelligence

/// What the speech models hear of a recording (`LevelledAudio`): a quiet recording raised in a copy with the original's
/// rate, channels, and length, removed when the run ends however it ends; the stored file only read; the gain recorded
/// with the run. Synthetic speech-like sound only; the models are faked.
final class LevelledAudioTests: XCTestCase {
    /// A 32-bit float CAF: `samples` in the first channel, at half level in a second when `stereo`.
    private func recording(_ samples: [Float], rate: Double, stereo: Bool = false, in folder: URL, name: String = "a.caf") throws -> URL {
        let url = folder.appendingPathComponent(name)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rate, channels: stereo ? 2 : 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices {
            buffer.floatChannelData![0][index] = samples[index]
            if stereo { buffer.floatChannelData![1][index] = samples[index] / 2 }
        }
        try file.write(from: buffer)
        return url
    }

    /// Every channel of `url`, its rate, and its length.
    private func contents(_ url: URL) throws -> (channels: [[Float]], rate: Double, length: Int64) {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let channels = (0..<Int(buffer.format.channelCount)).map { Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength))) }
        return (channels, file.processingFormat.sampleRate, file.length)
    }

    private func copies(in base: URL) -> [URL] {
        let folder = ProcessingScratch.root(in: base).appendingPathComponent(String(getpid()))
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    // MARK: The copy

    func testBehaviorQuietSpeechIsRaisedInACopyWithTheSameRateChannelsAndLength() throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        let url = try recording(SyntheticAudio.syllables(level: -50, seconds: 4, rate: 48_000, floor: -85), rate: 48_000, stereo: true, in: folder)
        let stored = try Data(contentsOf: url)

        let levelled = try LevelledAudio.prepare(url, in: scratch)
        let adjustment = try XCTUnwrap(levelled.adjustment)
        // Channels averaged: 0.75 of the first, so the speech measures 2.5 dB under −50.
        XCTAssertEqual(try XCTUnwrap(adjustment.speechLevel), -52.5, accuracy: 0.3)
        XCTAssertEqual(adjustment.gain, 29.5, accuracy: 0.3, "raised to −23 dBFS")
        let copy = try XCTUnwrap(levelled.copy)
        XCTAssertEqual(levelled.url, copy)
        XCTAssertEqual(copies(in: scratch).map { $0.resolvingSymlinksInPath().path }, [copy.resolvingSymlinksInPath().path],
                       "made where processing keeps its copies")

        let original = try contents(url), raised = try contents(copy)
        XCTAssertEqual(raised.rate, 48_000)
        XCTAssertEqual(raised.length, original.length)
        XCTAssertEqual(raised.channels.count, 2)
        for channel in 0..<2 {
            XCTAssertTrue(raised.channels[channel] == original.channels[channel].map { $0 * adjustment.factor },
                          "channel \(channel): every sample the original's times the gain, none added or lost")
        }
        XCTAssertEqual(try Data(contentsOf: url), stored, "the stored recording is only read")

        levelled.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testBehaviorNormalSpeechSilenceAndUnreadableAudioAreReadAsStored() throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        let normal = try recording(SyntheticAudio.syllables(level: -20, seconds: 4, floor: -70), rate: 16_000, in: folder, name: "normal.caf")
        let levelled = try LevelledAudio.prepare(normal, in: scratch)
        XCTAssertEqual(levelled.url, normal)
        XCTAssertNil(levelled.copy)
        XCTAssertEqual(levelled.adjustment?.gain, 0)
        XCTAssertEqual(try XCTUnwrap(levelled.adjustment?.speechLevel), -20, accuracy: 0.3)

        let silent = try recording([Float](repeating: 0, count: 64_000), rate: 16_000, in: folder, name: "silent.caf")
        XCTAssertEqual(try LevelledAudio.prepare(silent, in: scratch).adjustment, LevelAdjustment(speechLevel: nil, peak: nil, gain: 0))

        let missing = folder.appendingPathComponent("missing.caf")
        let unread = try LevelledAudio.prepare(missing, in: scratch)
        XCTAssertEqual(unread.url, missing)
        XCTAssertNil(unread.adjustment, "levels never stop a recording from being processed")
        XCTAssertTrue(copies(in: scratch).isEmpty)
    }

    func testBehaviorTheSameRecordingGetsTheSameGainEachTime() throws {
        let folder = makeTemporaryFolder(), scratch = makeTemporaryFolder()
        let url = try recording(SyntheticAudio.syllables(level: -47, seconds: 3, floor: -65, seed: 9), rate: 16_000, in: folder)
        let first = try LevelledAudio.prepare(url, in: scratch), second = try LevelledAudio.prepare(url, in: scratch)
        defer { first.remove(); second.remove() }
        XCTAssertEqual(first.adjustment, second.adjustment)
        XCTAssertEqual(try contents(XCTUnwrap(first.copy)).channels, try contents(XCTUnwrap(second.copy)).channels)
    }

    // MARK: Through the engine

    /// Models that note which file they were given, and can fail.
    private final class Heard: MeetingInference, @unchecked Sendable {
        private let lock = NSLock()
        private var _urls: [String: URL] = [:]
        var failure: (any Error)?
        var urls: [String: URL] { lock.withLock { _urls } }
        private func heard(_ step: String, _ url: URL) {
            lock.withLock { _urls[step] = url }
        }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            heard("transcribe", url)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the copy is there while the model reads it")
            if let failure { throw failure }
            let words = [RecognizedWord(text: " Ship", start: 0, end: 0.4, confidence: 0.9)]
            return RecognitionResult(segments: [RecognizedSegment(start: 0, end: 0.4, text: " Ship", confidence: 0.9, words: words)],
                                     language: "en", duration: 4)
        }

        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            heard("diarize", url)
            if let failure { throw failure }
            return SpeakerAnalysis(turns: [SpeakerTurn(speakerID: "0", start: 0, end: 4, confidence: 1)], embeddings: ["0": [1, 0]],
                                   embeddingModelID: "community-1", warnings: [])
        }

        func classifySound(url: URL, progress: @escaping IntelligenceProgressHandler) async throws -> BackgroundAudioAnalysis? {
            heard("classifySound", url)
            return nil
        }

        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            throw CancellationError()
        }
    }

    private let configuration = InferenceProcessingEngine.Configuration(
        transcriptionModel: "parakeet/ultra", summaryModel: "gemma-4/e2b-4bit", detectSpeakers: true,
        speakerModel: "community-1/offline", speakerOptions: SpeakerAnalysisOptions(), fingerprint: "levels",
        speakerMatchThreshold: 0.82, speakerMatchMargin: 0.06)

    private func input(_ url: URL, mode: ProcessingRequest.Mode = .newAudio, previous: TrackTranscript? = nil) -> TrackProcessingInput {
        let track = RecordingTrack(source: .systemAudio, relativePath: "Originals/call.caf", fileName: "call.caf", duration: 4, offset: 0, sha256: "c")
        return TrackProcessingInput(meetingID: UUID(), track: track, audioURL: url, mode: mode, previousTranscript: previous)
    }

    func testBehaviorTheModelsHearTheRaisedCopyAndTheRunRecordsTheGain() async throws {
        let url = try recording(SyntheticAudio.syllables(level: -48, seconds: 4, floor: -80), rate: 16_000, in: makeTemporaryFolder())
        let stored = try Data(contentsOf: url)
        let inference = Heard()
        let output = try await InferenceProcessingEngine(inference: inference, configuration: configuration).transcribe(input(url), progress: { _ in })

        let heard = try XCTUnwrap(inference.urls["transcribe"])
        XCTAssertNotEqual(heard, url, "the transcriber hears the raised copy")
        XCTAssertEqual(inference.urls["diarize"], heard, "and so do the speaker models")
        XCTAssertEqual(inference.urls["classifySound"], url, "background audio is measured on the recording as stored")
        XCTAssertFalse(FileManager.default.fileExists(atPath: heard.path), "the copy is gone when the run ends")
        XCTAssertEqual(try Data(contentsOf: url), stored)

        let adjustment = try XCTUnwrap(output.transcript.processingSettings?.levelAdjustment)
        XCTAssertEqual(adjustment.gain, 25, accuracy: 0.3)
        XCTAssertEqual(output.speakers.first?.analysisSettings?.levelAdjustment, adjustment)
        XCTAssertEqual(output.transcript.segments.map(\.text), ["Ship"], "timings and words as the models gave them")
    }

    func testBehaviorTheCopyIsRemovedWhenTheRunFailsOrIsCancelled() async throws {
        let url = try recording(SyntheticAudio.syllables(level: -50, seconds: 4, floor: -80), rate: 16_000, in: makeTemporaryFolder())
        struct Failure: Error {}
        for failure in [Failure() as any Error, CancellationError()] {
            let inference = Heard()
            inference.failure = failure
            do {
                _ = try await InferenceProcessingEngine(inference: inference, configuration: configuration).transcribe(input(url), progress: { _ in })
                XCTFail("the run fails with its model")
            } catch {}
            let heard = try XCTUnwrap(inference.urls["transcribe"])
            XCTAssertNotEqual(heard, url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: heard.path), "removed after \(failure)")
        }
    }

    func testBehaviorIdentifyingSpeakersAgainRaisesTheirAudioAndKeepsTheWordsOwnLevel() async throws {
        let url = try recording(SyntheticAudio.syllables(level: -48, seconds: 4, floor: -80), rate: 16_000, in: makeTemporaryFolder())
        let earlier = LevelAdjustment(speechLevel: -48, peak: -40, gain: 0)
        let previous = TrackTranscript(trackID: UUID(), segments: [], language: "en", modelID: "parakeet/ultra",
                                       processingSettings: ProcessingSettings(modelID: "parakeet/ultra", levelAdjustment: earlier),
                                       words: [TranscriptWord(text: " Hello", start: 0, end: 0.5, confidence: 0.9)])
        let inference = Heard()
        let output = try await InferenceProcessingEngine(inference: inference, configuration: configuration)
            .transcribe(input(url, mode: .speakerRefresh, previous: previous), progress: { _ in })
        XCTAssertNil(inference.urls["transcribe"])
        let heard = try XCTUnwrap(inference.urls["diarize"])
        XCTAssertNotEqual(heard, url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: heard.path))
        XCTAssertEqual(output.transcript.processingSettings?.levelAdjustment, earlier, "the words were heard as that run heard them")
        XCTAssertEqual(try XCTUnwrap(output.speakers.first?.analysisSettings?.levelAdjustment?.gain), 25, accuracy: 0.3)
    }
}
