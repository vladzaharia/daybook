import AVFoundation
import DaybookCore
import DaybookKit
import FluidAudio
import XCTest
@testable import DaybookIntelligence

final class IntelligenceTests: XCTestCase {
    func testMissingInstallationsRejectInferenceBeforeReadingAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = LocalIntelligenceRuntime(modelsDirectory: root, registry: Self.withoutAppleIntelligence)
        let installed = await runtime.installedModels()
        XCTAssertEqual(installed, ["apple-vision/system"], "only the system's own photo reader, which needs no download")
        do {
            _ = try await runtime.transcribe(url: root.appendingPathComponent("missing.wav"), model: "whisper-base")
            XCTFail("Missing model must fail before touching audio or the network")
        } catch LocalIntelligenceError.modelNotInstalled(let id) { XCTAssertEqual(id, "whisper-base") }
        do {
            _ = try await runtime.diarize(url: root.appendingPathComponent("missing.wav"), model: "community-1/offline")
            XCTFail("Missing speaker model must fail")
        } catch LocalIntelligenceError.modelNotInstalled(let id) { XCTAssertEqual(id, "community-1/offline") }
        for model in ["sortformer-2.1/fp16", "sortformer-2.1/compact"] {
            do {
                _ = try await runtime.diarize(url: root.appendingPathComponent("missing.wav"), model: ModelReference(model))
                XCTFail("Sortformer must not download models implicitly")
            } catch LocalIntelligenceError.modelNotInstalled(let id) { XCTAssertEqual(id, model) }
        }
        do {
            _ = try await runtime.summarize(transcript: "Hello", notes: "", model: "qwen-1.5b")
            XCTFail("Missing summary model must fail")
        } catch LocalIntelligenceError.modelNotInstalled(let id) { XCTAssertEqual(id, "qwen-1.5b") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "Inference must not create a download directory")
    }

    func testIncompleteMarkerDoesNotCountAsInstalled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("whisper-base")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("installed.json"))
        let installed = await LocalIntelligenceRuntime(modelsDirectory: root, registry: Self.withoutAppleIntelligence).installedModels()
        XCTAssertEqual(installed, ["apple-vision/system"])
    }

    /// The standard engines, with Apple's system model reporting it's off, so results don't depend
    /// on whether this Mac has Apple Intelligence turned on.
    static let withoutAppleIntelligence = ModelEngineRegistry.standard
        .registering(AppleFoundationModelsEngine(availability: { .appleIntelligenceNotEnabled }))

    func testSummaryRespectsUserTemplateAndRejectsUnobservedTerms() {
        let json = #"{"kind":"scrum","title":"Check-in","overview":"Alex described a blocker in Daybook.","sections":[{"heading":"Themes","body":"Daybook needs testing."}],"actionItems":[{"text":"Test capture","owner":null}],"terms":["Daybook","InventedName"]}"#
        let result = MeetingSynthesis.parse(json, requestedTemplate: .oneOnOne, modelID: "test-model", source: "Alex discussed Daybook.")
        XCTAssertEqual(result.summary.kind, .oneOnOne)
        XCTAssertEqual(result.suggestedTerms, ["Daybook"])
        XCTAssertNil(result.summary.actionItems.first?.owner)
        XCTAssertEqual(result.rawResponse, json)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMalformedSummaryPreservesModelResponseAndSignalsFallback() {
        let result = MeetingSynthesis.parse("The conversation explored priorities.", requestedTemplate: .auto,
                                            modelID: "test-model", source: "Priorities")
        XCTAssertEqual(result.summary.overview, "The conversation explored priorities.")
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertTrue(result.suggestedTerms.isEmpty)
    }

    func testActionVerificationRejectsInventedSourceEvidenceAndOwner() {
        let response = #"{"actions":[{"text":"Write the checklist","owner":"Alex","evidence":"[0.0s] Alex will write the checklist."},{"text":"Delete records","owner":"Sam","evidence":"Sam agreed to delete all records."},{"text":"Review results","owner":"Invented","evidence":"We will review the results Monday."}]}"#
        let actions = MeetingSynthesis.verifiedActions(response, source: "Alex will write the checklist. We will review the results Monday.")
        XCTAssertEqual(actions?.count, 2)
        XCTAssertEqual(actions?.first?.owner, "Alex")
        XCTAssertNil(actions?.last?.owner)
    }

    func testSpeakerPresetsChangeActualInferenceWorkAndNormalizeCount() {
        let fast = SpeakerAnalysisOptions(quality: .fast).communityConfiguration()
        let detailed = SpeakerAnalysisOptions(quality: .accurate, expectedSpeakerCount: 3).communityConfiguration()
        XCTAssertLessThan(detailed.segmentation.stepRatio, fast.segmentation.stepRatio)
        XCTAssertGreaterThan(detailed.vbx.maxIterations, fast.vbx.maxIterations)
        XCTAssertTrue(detailed.zeroVoteReembed.enabled)
        XCTAssertEqual(detailed.clustering.numSpeakers, 3)
        if case .maskSimilarity(let threshold) = fast.embedding.skipStrategy { XCTAssertEqual(threshold, 0.95) }
        else { XCTFail("Fast processing must actually reuse similar embeddings") }
        XCTAssertNil(SpeakerAnalysisOptions(expectedSpeakerCount: -1).normalized.expectedSpeakerCount)
        XCTAssertNil(SpeakerAnalysisOptions(expectedSpeakerCount: 1000).normalized.expectedSpeakerCount)
    }

    func testSortformerStitchingRecoversPermutedSpeakerColumns() {
        let original: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        let permuted: [Float] = [0,0,1,0, 1,0,0,0, 0,0,0,1, 0,1,0,0]
        XCTAssertEqual(BoundedSortformer.align(existing: original, incoming: permuted, frames: 4), [1,3,0,2])
        XCTAssertEqual(BoundedSortformer.align(existing: Array(repeating: 0, count: 16), incoming: permuted, frames: 4), [0,1,2,3])
        XCTAssertEqual(BoundedSortformer.align(existing: [], incoming: [], frames: 0), [0,1,2,3])
    }

    func testCustomSummaryPreferencesAndHighlightsPreserveSourceSeparation() {
        let prompt = MeetingSynthesis.finalPrompt(evidence: #"{"highlighted_evidence":"[1:30] Discussed rest","written_user_context":"[1:32] My own reflection"}"#,
                                                  template: .therapy, glossary: [], templateInstructions: "Use a Reflections section")
        XCTAssertTrue(prompt.contains("Use a Reflections section"))
        XCTAssertTrue(prompt.contains("extra factual detail"))
        XCTAssertTrue(prompt.contains("never spoken quotes"))
        XCTAssertTrue(prompt.contains("cannot authorize invented facts"))
        XCTAssertTrue(prompt.contains("Use the user's selected kind: therapy"))
        XCTAssertTrue(prompt.contains("Preserve those names"))
        XCTAssertFalse(prompt.contains("Kinds and section guidance:"), "A custom template must not compete with generic headings")
    }

    func testSortformerWindowMelMatchesWholeRecordingAwayFromEdges() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 640_000))
        buffer.frameLength = 640_000
        let samples = (0..<640_000).map { index in
            Float(sin(Double(index) * 0.12) * (0.1 + Double(index % 16_000) / 80_000))
        }
        let destination = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { destination.update(from: $0.baseAddress!, count: $0.count) }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        let whole = AudioMelSpectrogram().computeFlatTransposed(audio: samples)
        let window = try BoundedSortformer.melWindow(url: url, startFrame: 100, duration: 40, mel: AudioMelSpectrogram())
        XCTAssertEqual(window.frames, 3_072)
        let expected = Array(whole.mel[(800 * 128)..<((800 + 3_072) * 128)])
        let difference = zip(expected, window.values).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        XCTAssertLessThan(difference, 0.002, "Window offsets must preserve the original mel timeline")
    }

    func testSlabConversionPreservesRequestedTimeRange() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for channel in 0..<2 {
            let data = try XCTUnwrap(buffer.floatChannelData?[channel])
            for frame in 0..<96_000 {
                let amplitude: Float = frame < 48_000 ? 0.1 : 0.4
                data[frame] = sin(Float(frame) * 2 * .pi * 440 / 48_000) * amplitude
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        let samples = try AudioSlabReader.samples(url: url, from: 0.5, to: 1.5)
        XCTAssertEqual(samples.count, 16_000, accuracy: 64)
        XCTAssertGreaterThan(samples.map { abs($0) }.max() ?? 0, 0.05)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        let quiet = samples[500..<7_000].reduce(0) { $0 + abs($1) }
        let loud = samples[8_500..<15_000].reduce(0) { $0 + abs($1) }
        XCTAssertGreaterThan(loud, quiet * 3, "The slice must straddle the source's amplitude change at one second")
    }
}
