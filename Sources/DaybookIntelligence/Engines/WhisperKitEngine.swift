// WhisperKit builds for the Mac only (Package.swift): the iPhone transcribes with Parakeet.
#if canImport(WhisperKit)
import AVFoundation
import DaybookCore
import DaybookKit
import Foundation
import WhisperKit

/// Whisper on Core ML through WhisperKit (argmax-oss-swift). An install has a "model" artifact (the
/// WhisperKit folder: AudioEncoder, TextDecoder, and MelSpectrogram bundles) and a "tokenizer" artifact.
public struct WhisperKitEngine: ModelEngine {
    public static let requiredBundles = ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
    public static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json", "config.json", "special_tokens_map.json", "added_tokens.json"]

    public init() {}

    public let descriptor = ModelEngineDescriptor(
        id: .whisperKit, name: "WhisperKit", version: 2, runtime: "argmax-oss-swift 1.1.1",
        roles: [.transcription], platforms: [.macOS, .iOS], residency: .shared)

    public func validate(_ installation: ModelInstallation) throws {
        try require(Self.requiredBundles, in: "model", of: installation)
        try require(["tokenizer.json"], in: "tokenizer", of: installation)
    }

    /// The tokenizer must parse before an install counts, as before the model system.
    public func verifyNewInstallation(_ installation: ModelInstallation) async throws {
        try validate(installation)
        _ = try await OfflineWhisperKit.localTokenizer(in: installation.folder(for: "tokenizer"))
    }

    /// Needs `subdirectory` (the WhisperKit folder in the repository) unless the folder is the
    /// repository root, and a tokenizer: in the same repository, or `tokenizerRepository`.
    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        let folder = request.options["subdirectory"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
        let prefix = folder.isEmpty ? "" : folder + "/"
        var problems: [String] = []
        for bundle in Self.requiredBundles where !repository.files.contains(where: { $0.path.hasPrefix(prefix + bundle + "/") }) {
            problems.append("\(prefix + bundle) is missing, so this isn’t a WhisperKit Core ML model.")
        }
        guard problems.isEmpty else { throw ModelAdditionError.invalid(problems) }
        let model = try repository.artifact("model", include: [prefix + "*"], root: folder.isEmpty ? nil : folder)
        let tokenizerSource: ModelRepositorySnapshot
        if let other = request.options["tokenizerRepository"] {
            tokenizerSource = try await repository.other(other, revision: request.options["tokenizerRevision"] ?? "main")
        } else {
            tokenizerSource = repository
        }
        guard tokenizerSource.contains("tokenizer.json") else {
            throw ModelAdditionError.invalid(["No tokenizer.json in \(tokenizerSource.repository). Name the tokenizer’s repository."])
        }
        let tokenizer = try tokenizerSource.artifact("tokenizer", include: Self.tokenizerFiles.filter(tokenizerSource.contains))
        return ModelAdditionProposal(artifacts: [model, tokenizer],
                                     capabilities: ModelCapabilities(wordTimestamps: true, wordConfidence: true, languages: ["*"],
                                                                     vocabularyPrompt: true, streaming: false),
                                     recommendedMemoryGB: model.files.reduce(0) { $0 + $1.size } > 600_000_000 ? 16 : 8)
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        let config = WhisperKitConfig(modelFolder: installation.folder(for: "model").path,
                                      tokenizerFolder: installation.folder(for: "tokenizer"),
                                      verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
        return WhisperKitTranscriber(whisper: try await OfflineWhisperKit(config))
    }
}

/// A loaded Whisper model.
final class WhisperKitTranscriber: Transcribing, @unchecked Sendable {
    let whisper: OfflineWhisperKit

    init(whisper: OfflineWhisperKit) { self.whisper = whisper }

    func transcribe(url: URL, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        try await transcribe(url: url, glossary: glossary, language: nil, progress: progress)
    }

    /// The language to prefill and whether to detect one. WhisperKit prefills English when it's given
    /// no language and isn't asked to detect one, so without a hint Whisper detects the language itself.
    static func languageSettings(for hint: String?) -> (language: String?, detect: Bool) {
        let code = whisperLanguage(hint)
        return (code, code == nil)
    }

    static func decodingOptions(language hint: String?) -> DecodingOptions {
        let settings = languageSettings(for: hint)
        return DecodingOptions(verbose: false, language: settings.language, temperature: 0, detectLanguage: settings.detect,
                               skipSpecialTokens: true, wordTimestamps: true, concurrentWorkerCount: 2, chunkingStrategy: .vad)
    }

    /// Whisper's code for a BCP-47 language ("pt-BR" → "pt"); nil when Whisper doesn't know it.
    static func whisperLanguage(_ code: String?) -> String? {
        guard let primary = code?.split(separator: "-").first.map({ $0.lowercased() }), Constants.languageCodes.contains(primary) else { return nil }
        return primary
    }

    func transcribe(url: URL, glossary: [String], language hint: String?,
                    progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        let audioFile = try AVAudioFile(forReading: url)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw LocalIntelligenceError.invalidAudio }
        var options = Self.decodingOptions(language: hint)
        if !glossary.isEmpty {
            options.promptTokens = Array((whisper.tokenizer?.encode(text: glossary.prefix(80).joined(separator: ", ")) ?? []).suffix(180))
        }
        var segments: [RecognizedSegment] = []
        var language: String?
        // Five-minute slabs bound decoded PCM memory for day-long recordings.
        // One second of context on each side prevents cutting words at a slab edge.
        let slab: Double = 300
        var coreStart: Double = 0
        while coreStart < duration {
            try Task.checkCancellation()
            let coreEnd = min(duration, coreStart + slab)
            let loadStart = max(0, coreStart - 1), loadEnd = min(duration, coreEnd + 1)
            let samples = try AudioSlabReader.samples(url: url, from: loadStart, to: loadEnd)
            let results: [TranscriptionResult] = try await whisper.transcribe(
                audioArray: samples, decodeOptions: options, callback: { _ in !Task.isCancelled })
            try Task.checkCancellation()
            for result in results {
                language = language ?? result.language
                for segment in result.segments {
                    let words = (segment.words ?? []).compactMap { word -> RecognizedWord? in
                        let start = Double(word.start) + loadStart, end = Double(word.end) + loadStart
                        let midpoint = (start + end) / 2
                        guard midpoint >= coreStart, midpoint < coreEnd else { return nil }
                        return .init(text: word.word, start: max(0, start), end: min(duration, end),
                                     confidence: Double(word.probability))
                    }
                    if let first = words.first, let last = words.last {
                        segments.append(.init(start: first.start, end: last.end,
                                              text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                                              confidence: words.map(\.confidence).reduce(0, +) / Double(words.count), words: words))
                    } else if segment.words == nil || segment.words?.isEmpty == true {
                        let start = Double(segment.start) + loadStart, end = Double(segment.end) + loadStart
                        guard (start + end) / 2 >= coreStart, (start + end) / 2 < coreEnd else { continue }
                        segments.append(.init(start: max(0, start), end: min(duration, end),
                                              text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                              confidence: min(1, max(0, exp(Double(segment.avgLogprob)))), words: []))
                    }
                }
            }
            coreStart = coreEnd
            progress(.init(coreEnd / duration, "Transcribed \(Int(coreEnd)) of \(Int(duration)) seconds"))
        }
        return RecognitionResult(segments: segments.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start },
                                 language: language, duration: duration)
    }
}
#endif
