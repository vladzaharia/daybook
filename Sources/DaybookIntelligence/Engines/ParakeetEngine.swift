import CoreML
import DaybookCore
import DaybookKit
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B v3 and its post-trains (Moondream's Ultra and Redux) on Core ML through
/// FluidAudio's `AsrManager`. An install has one "model" artifact: the preprocessor, encoder,
/// decoder, and joint bundles plus the vocabulary. `engineOptions["version"]` names the build
/// ("ultra", "redux", "v3", "phonon2"). Loading reads only the install's folder; FluidAudio's own
/// download path is never used.
public struct ParakeetEngine: ModelEngine {
    public static let bundles = ["Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"]
    public static let vocabulary = "parakeet_vocab.json"
    /// The 25 languages of the v3 family.
    public static let languages = ["bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it",
                                   "lt", "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk"]

    public init() {}

    public let descriptor = ModelEngineDescriptor(
        id: .parakeet, name: "FluidAudio Parakeet", version: 1, runtime: "FluidAudio 0.17.7",
        roles: [.transcription], platforms: [.macOS, .iOS], residency: .shared)

    /// The FluidAudio model version an install's options name; nil for one this engine doesn't run.
    static func version(_ options: [String: String]) -> AsrModelVersion? {
        switch options["version"] ?? "v3" {
        case "ultra": return .ultra
        case "redux": return .redux
        case "phonon2": return .phonon2
        case "v3": return .v3
        default: return nil
        }
    }

    public func validate(_ installation: ModelInstallation) throws {
        guard Self.version(installation.engineOptions) != nil else {
            throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey)
        }
        try require(Self.bundles.map { $0 + "/coremldata.bin" } + [Self.vocabulary], in: "model", of: installation)
    }

    /// The vocabulary must hold every token below the blank ID, as decoding needs.
    public func verifyNewInstallation(_ installation: ModelInstallation) async throws {
        try validate(installation)
        let url = installation.folder(for: "model").appendingPathComponent(Self.vocabulary)
        guard let version = Self.version(installation.engineOptions),
              let tokens = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: String],
              (0..<version.blankId).allSatisfy({ tokens[String($0)] != nil }) else {
            throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey)
        }
    }

    /// `subdirectory` names the folder holding the bundles (default: the repository root);
    /// `version` defaults from the repository name.
    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        let folder = request.options["subdirectory"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
        let prefix = folder.isEmpty ? "" : folder + "/"
        let name = repository.repository.lowercased()
        let version = request.options["version"]
            ?? (name.contains("ultra") ? "ultra" : name.contains("redux") ? "redux" : name.contains("phonon") ? "phonon2" : "v3")
        var problems: [String] = []
        if Self.version(["version": version]) == nil { problems.append("Parakeet version must be ultra, redux, phonon2, or v3.") }
        for bundle in Self.bundles where !repository.contains(prefix + bundle + "/coremldata.bin") {
            problems.append("\(prefix + bundle) is missing, so this isn’t a Parakeet v3 Core ML model.")
        }
        if !repository.contains(prefix + Self.vocabulary) { problems.append("\(prefix + Self.vocabulary) is missing.") }
        guard problems.isEmpty else { throw ModelAdditionError.invalid(problems) }
        let model = try repository.artifact("model", include: Self.bundles.map { prefix + $0 + "/*" } + [prefix + Self.vocabulary],
                                            root: folder.isEmpty ? nil : folder)
        return ModelAdditionProposal(artifacts: [model],
                                     capabilities: ModelCapabilities(wordTimestamps: true, wordConfidence: true,
                                                                     languages: version == "phonon2" ? ["en"] : Self.languages,
                                                                     vocabularyPrompt: false, streaming: false),
                                     engineOptions: ["version": version], recommendedMemoryGB: 8)
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        guard let version = Self.version(installation.engineOptions) else {
            throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey)
        }
        progress(.init(0, "Loading speech model locally"))
        let folder = installation.folder(for: "model")
        let models = try await Task.detached(priority: .userInitiated) {
            try AsrModels.loadLocal(from: folder, version: version)
        }.value
        return ParakeetTranscriber(models: models)
    }
}

/// A loaded Parakeet model. Each transcription gets a fresh `AsrManager` (cheap; the Core ML models
/// are shared), so progress and decoder state never carry over between recordings.
final class ParakeetTranscriber: Transcribing, @unchecked Sendable {
    let models: AsrModels

    init(models: AsrModels) { self.models = models }

    func transcribe(url: URL, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        try await transcribe(url: url, glossary: glossary, language: nil, progress: progress)
    }

    /// `glossary` isn't used: Parakeet takes no decoding prompt (its capabilities say
    /// `vocabularyPrompt: false`). A language hint keeps output in that language's script.
    func transcribe(url: URL, glossary: [String], language: String?,
                    progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        let (duration, channels) = try MonoAudioReader.describe(url)
        guard duration.isFinite, duration > 0 else { throw LocalIntelligenceError.invalidAudio }
        let code = TranscriptionLanguages.normalize(language)
        // Too short to decode (FluidAudio needs about a third of a second): no words.
        guard duration >= 0.35 else { return RecognitionResult(segments: [], language: code, duration: duration) }

        // FluidAudio's file reader keeps only the first channel; mix others in first.
        var source = url
        var temporary: URL?
        if channels > 1 {
            let mono = FileManager.default.temporaryDirectory.appendingPathComponent("daybook-parakeet-\(UUID().uuidString).caf")
            try MonoAudioReader.writeMonoCopy(of: url, to: mono)
            source = mono; temporary = mono
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        let manager = AsrManager(config: .default, models: models)
        let stream = await manager.transcriptionProgressStream
        let reporter = Task {
            do {
                for try await fraction in stream {
                    progress(.init(fraction, "Transcribed \(Int(fraction * duration)) of \(Int(duration)) seconds"))
                }
            } catch {}
        }
        defer { reporter.cancel() }
        progress(.init(0, "Transcribing"))
        var state = try TdtDecoderState(decoderLayers: models.version.decoderLayers)
        let result: ASRResult
        do {
            result = try await manager.transcribe(source, decoderState: &state, language: code.flatMap(Language.init(rawValue:)))
        } catch ASRError.invalidAudioData {
            return RecognitionResult(segments: [], language: code, duration: duration)
        }
        try Task.checkCancellation()
        let tokens = (result.tokenTimings ?? []).map {
            ParakeetWords.Token(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: Double($0.confidence))
        }
        let words = ParakeetWords.words(from: tokens, duration: duration)
        progress(.init(1, "Transcribed \(Int(duration)) of \(Int(duration)) seconds"))
        return RecognitionResult(segments: ParakeetWords.segments(from: words), language: code, duration: duration)
    }
}

/// Parakeet's sub-word tokens as words and passages, the shape the rest of the pipeline (speaker
/// assignment, ROVER fusion) uses for every recognizer.
enum ParakeetWords {
    struct Token: Equatable {
        var text: String
        var start: Double
        var end: Double
        var confidence: Double
    }

    /// The shortest span a word gets: one encoder frame. A zero-length word would overlap no speaker turn.
    static let minimumWordSeconds = 0.08

    /// Merges SentencePiece tokens into words. A token beginning with a space ("▁" in the
    /// vocabulary), or following a bare "▁" token (before digits: "▁", "2", "5"), starts a word;
    /// others continue it; punctuation-only tokens attach to the word before. Words carry Whisper's convention of a leading space (" Friday."), so their texts
    /// join into passages directly.
    ///
    /// A word's confidence is the **minimum** of its sub-word tokens' confidences, punctuation
    /// excluded. A word is wrong when any of its pieces is, so its weakest piece bounds it; the
    /// mean would hide one doubtful piece among confident ones ("Day" "brook" for "Daybook"),
    /// and the product would mark long words down for their length alone, which would make
    /// ROVER prefer another recognizer's shorter, often wrong, split of the same word.
    /// Punctuation tokens are left out because their doubt is about sentence boundaries, which
    /// fusion doesn't score.
    static func words(from tokens: [Token], duration: Double? = nil) -> [RecognizedWord] {
        struct Building { var text: String; var start: Double; var end: Double; var confidences: [Double]; var punctuation: [Double] }
        var words: [RecognizedWord] = []
        var current: Building?
        var boundary = false
        func finish() {
            guard let word = current else { return }
            current = nil
            let text = word.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            let confidence = (word.confidences.isEmpty ? word.punctuation : word.confidences).min() ?? 0
            var end = max(word.end, word.start + minimumWordSeconds)
            if let duration { end = min(end, max(duration, word.start)) }
            words.append(RecognizedWord(text: " " + text, start: max(0, word.start), end: end, confidence: min(1, max(0, confidence))))
        }
        for token in tokens {
            let raw = token.text.replacingOccurrences(of: "▁", with: " ")
            guard !raw.isEmpty, !["<blank>", "<pad>", "<unk>", "<s>", "</s>"].contains(raw.trimmingCharacters(in: .whitespaces)) else { continue }
            let piece = raw.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else {
                // A bare word boundary: the next piece starts a word.
                boundary = boundary || raw.hasPrefix(" ")
                continue
            }
            let isPunctuation = piece.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) }
            let confidence = token.confidence.isFinite ? token.confidence : 0
            if isPunctuation, current != nil {
                current!.text += piece
                current!.end = max(current!.end, token.end)
                current!.punctuation.append(confidence)
                continue
            }
            if raw.hasPrefix(" ") || boundary || current == nil {
                boundary = false
                finish()
                current = Building(text: piece, start: token.start, end: token.end,
                                   confidences: isPunctuation ? [] : [confidence], punctuation: isPunctuation ? [confidence] : [])
            } else {
                current!.text += piece
                current!.end = max(current!.end, token.end)
                current!.confidences.append(confidence)
            }
        }
        finish()
        return words
    }

    /// Words grouped into passages: a new passage after a sentence ends, after a pause of
    /// `pause` seconds, or once a passage reaches `maximumSeconds`.
    static func segments(from words: [RecognizedWord], pause: Double = 1.0, maximumSeconds: Double = 30) -> [RecognizedSegment] {
        var segments: [RecognizedSegment] = []
        var group: [RecognizedWord] = []
        func close() {
            guard let first = group.first, let last = group.last else { return }
            let text = group.map(\.text).joined().trimmingCharacters(in: .whitespaces)
            segments.append(RecognizedSegment(start: first.start, end: last.end, text: text,
                                              confidence: group.map(\.confidence).reduce(0, +) / Double(group.count), words: group))
            group = []
        }
        for word in words {
            if let previous = group.last, let first = group.first {
                let sentenceEnded = previous.text.trimmingCharacters(in: .whitespaces).last.map { ".?!…。？！".contains($0) } ?? false
                if sentenceEnded || word.start - previous.end >= pause || word.end - first.start > maximumSeconds { close() }
            }
            group.append(word)
        }
        close()
        return segments
    }
}
