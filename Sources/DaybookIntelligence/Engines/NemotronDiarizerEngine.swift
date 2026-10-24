import CoreML
import DaybookCore
import DaybookKit
import FluidAudio
import Foundation

/// NVIDIA Nemotron 3 Diarization (a streaming Sortformer with eight speaker slots) through
/// FluidAudio's `Nemotron3Diarizer`. `engineOptions["preset"]` names the converted shape: "offline"
/// (the 30 s batch configuration in `monolithic/v2/`) or a split-graph W8A8 build such as
/// "c128-split-w8a8" (`split/`, plus the host-side projection). No voice embeddings: voice
/// profiles come from the speaker-embedding model (`ModelRouting.voiceEmbedder`).
public struct NemotronDiarizerEngine: ModelEngine {
    public init() {}

    public let descriptor = ModelEngineDescriptor(
        id: .nemotronDiarizer, name: "FluidAudio Nemotron 3 Diarization", version: 1, runtime: "FluidAudio 0.17.7",
        roles: [.diarization], platforms: [.macOS, .iOS], residency: .shared)

    /// The streaming configuration an install's options name, with `modelFileName` as the bundle's
    /// path inside the artifact; nil for a preset FluidAudio 0.17.7 doesn't know.
    static func configuration(_ options: [String: String]) -> Nemotron3Config? {
        guard var config = Nemotron3Config.preset(named: options["preset"] ?? "offline") else { return nil }
        config.modelFileName = bundlePath(config)
        return config
    }

    /// "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc", as in FluidInference's repository.
    static func bundlePath(_ config: Nemotron3Config) -> String {
        config.modelFileName.contains("/") ? config.modelFileName : "\(config.hubSubdirectory)/\(config.modelFileName)"
    }

    static func requiredFiles(_ config: Nemotron3Config) -> [String] {
        [config.modelFileName + "/coremldata.bin", config.modelFileName + "/model.mil", ModelNames.Nemotron3.silenceEmbeddingFile]
            + (config.splitGraph ? [ModelNames.Nemotron3.preEncodeProjectionFile] : [])
    }

    public func validate(_ installation: ModelInstallation) throws {
        guard let config = Self.configuration(installation.engineOptions) else {
            throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey)
        }
        try require(Self.requiredFiles(config), in: "model", of: installation)
    }

    /// `preset` picks the build (default "offline"); the repository must have FluidInference's layout.
    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        let preset = request.options["preset"] ?? "offline"
        guard let config = Self.configuration(["preset": preset]) else {
            throw ModelAdditionError.invalid(["“\(preset)” isn’t a Nemotron 3 preset this version of Daybook runs."])
        }
        let missing = Self.requiredFiles(config).filter { !repository.contains($0) }
        guard missing.isEmpty else { throw ModelAdditionError.invalid(missing.map { "\($0) is missing." }) }
        let include = [config.modelFileName + "/*", ModelNames.Nemotron3.silenceEmbeddingFile]
            + (config.splitGraph ? [ModelNames.Nemotron3.preEncodeProjectionFile] : [])
        return ModelAdditionProposal(artifacts: [try repository.artifact("model", include: include)],
                                     capabilities: ModelCapabilities(maxSpeakers: config.numSpeakers, expectedSpeakerCount: false, streaming: false),
                                     engineOptions: ["preset": preset], recommendedMemoryGB: 8)
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        guard let config = Self.configuration(installation.engineOptions) else {
            throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey)
        }
        progress(.init(0, "Loading speaker model locally"))
        // Local files only: `load(config:directory:)` never downloads.
        let models = try await Nemotron3Models.load(config: config, directory: installation.folder(for: "model"), computeUnits: .all)
        return NemotronDiarizer(models: models, config: config, maxSpeakers: installation.capabilities.maxSpeakers ?? config.numSpeakers)
    }
}

/// A loaded Nemotron 3 model. Each run gets a fresh streaming diarizer over the shared Core ML model
/// and reads the recording in 30-second blocks, so memory stays flat on long recordings.
final class NemotronDiarizer: Diarizing, @unchecked Sendable {
    let models: Nemotron3Models
    let config: Nemotron3Config
    let maxSpeakers: Int

    init(models: Nemotron3Models, config: Nemotron3Config, maxSpeakers: Int) {
        self.models = models; self.config = config; self.maxSpeakers = maxSpeakers
    }

    func diarize(url: URL, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
        let (duration, _) = try MonoAudioReader.describe(url)
        guard duration.isFinite, duration > 0 else { throw LocalIntelligenceError.invalidAudio }
        let diarizer = Nemotron3Diarizer(config: config, models: models)
        // 10 ms frames (`outputFrameSeconds` is a Float, whose 0.01 isn't exact).
        var activity = SpeakerActivity(speakers: config.numSpeakers, frameSeconds: 0.01)
        progress(.init(0, "Detecting speaker turns"))
        var read = 0
        try MonoAudioReader.read(url: url, blockSeconds: 30) { block in
            diarizer.appendAudio(block)
            for chunk in try diarizer.processBufferedAudio() { activity.append(chunk.probabilities, frames: chunk.frameCount) }
            read += block.count
            progress(.init(Double(read) / MonoAudioReader.sampleRate / duration * 0.95, "Detecting speaker turns"))
        }
        try Task.checkCancellation()
        for chunk in try diarizer.finishStream() { activity.append(chunk.probabilities, frames: chunk.frameCount) }
        let segments = activity.finish()
        let turns = segments.map {
            SpeakerTurn(speakerID: "S\($0.speaker + 1)", start: $0.start, end: min(duration, $0.end), confidence: $0.confidence)
        }.filter { $0.end > $0.start }
        var warnings: [String] = []
        let found = Set(turns.map(\.speakerID)).count
        if (options.expectedSpeakerCount ?? 0) > maxSpeakers || found >= maxSpeakers {
            warnings.append("Up to \(maxSpeakers) speakers can be told apart. For larger groups, choose Community-1 in Models.")
        }
        progress(.init(1, "Speaker detection complete"))
        return SpeakerAnalysis(turns: turns, embeddings: [:], embeddingModelID: nil, warnings: warnings)
    }
}

/// Speaker turns from per-frame speaker probabilities, built as frames arrive. A speaker is active
/// above `threshold`; same-speaker gaps shorter than `gap` are bridged, then turns shorter than
/// `minimumDuration` are dropped (pyannote's binarization order). Memory holds only open turns.
struct SpeakerActivity {
    struct Segment: Equatable {
        var speaker: Int
        var start: Double
        var end: Double
        /// Mean activity probability over the turn's active frames.
        var confidence: Double
    }

    let speakers: Int
    let frameSeconds: Double
    var threshold: Float = 0.5
    var gap: Double = 0.25
    var minimumDuration: Double = 0.2

    private var frame = 0
    private var open: [Run?]
    private var pending: [Run?]
    private var done: [Segment] = []

    private struct Run { var start: Int; var end: Int; var sum: Double; var count: Int }

    init(speakers: Int, frameSeconds: Double) {
        self.speakers = speakers; self.frameSeconds = frameSeconds
        open = Array(repeating: nil, count: speakers)
        pending = Array(repeating: nil, count: speakers)
    }

    /// `probabilities` holds `frames × speakers` values, frame-major.
    mutating func append(_ probabilities: [Float], frames: Int) {
        let usable = min(frames, probabilities.count / max(1, speakers))
        for index in 0..<usable {
            for speaker in 0..<speakers {
                let value = probabilities[index * speakers + speaker]
                if value > threshold {
                    if open[speaker] == nil { open[speaker] = Run(start: frame, end: frame + 1, sum: 0, count: 0) }
                    open[speaker]!.end = frame + 1
                    open[speaker]!.sum += Double(value)
                    open[speaker]!.count += 1
                } else if let run = open[speaker] {
                    close(run, speaker: speaker)
                    open[speaker] = nil
                }
            }
            frame += 1
        }
    }

    /// Every turn, in start order.
    mutating func finish() -> [Segment] {
        for speaker in 0..<speakers {
            if let run = open[speaker] { close(run, speaker: speaker); open[speaker] = nil }
            if let run = pending[speaker] { emit(run, speaker: speaker); pending[speaker] = nil }
        }
        return done.sorted { $0.start == $1.start ? $0.speaker < $1.speaker : $0.start < $1.start }
    }

    private mutating func close(_ run: Run, speaker: Int) {
        // Durations compare by whole frames, with a tolerance for the frame length's rounding.
        if var previous = pending[speaker], Double(run.start - previous.end) * frameSeconds < gap - 1e-9 {
            previous.end = run.end; previous.sum += run.sum; previous.count += run.count
            pending[speaker] = previous
        } else {
            if let previous = pending[speaker] { emit(previous, speaker: speaker) }
            pending[speaker] = run
        }
    }

    private mutating func emit(_ run: Run, speaker: Int) {
        let start = Double(run.start) * frameSeconds, end = Double(run.end) * frameSeconds
        guard Double(run.end - run.start) * frameSeconds >= minimumDuration - 1e-9 else { return }
        done.append(Segment(speaker: speaker, start: start, end: end, confidence: run.count > 0 ? run.sum / Double(run.count) : 0))
    }
}
