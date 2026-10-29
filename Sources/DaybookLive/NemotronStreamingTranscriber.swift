import CoreML
import FluidAudio
import Foundation

/// Nemotron 3.5 ASR Streaming through FluidAudio's `StreamingNemotronMultilingualAsrManager`: a
/// cache-aware RNN-T that decodes each chunk (1.12 s or 2.24 s, fixed by the bundle) once, so its
/// words never change after they appear. Each capture gets its own manager over models loaded once
/// (`SharedNemotronMultilingualModels`), so a Mac captioning You and Call holds one copy.
final class NemotronStreamingTranscriber: LiveTranscribing, @unchecked Sendable {
    private let manager: StreamingNemotronMultilingualAsrManager
    private var consumed = 0

    /// `language`: a BCP-47 code ("de", "en-US") the model prompts with; nil lets it detect.
    init(shared: SharedNemotronMultilingualModels, language: String?) async throws {
        manager = StreamingNemotronMultilingualAsrManager(configuration: shared.mlConfiguration)
        try await manager.loadFromShared(shared)
        await manager.setLanguage(Self.promptLanguage(language))
    }

    func transcribe(_ samples: [Float]) async throws -> [LiveToken] {
        guard !samples.isEmpty else { return [] }
        _ = try await manager.process(samples: samples)
        return newTokens(await manager.getTokenTimings())
    }

    func finish() async throws -> [LiveToken] {
        let (_, timings) = try await manager.finishWithTokenTimings()
        let tokens = newTokens(timings)
        await manager.cleanup()
        return tokens
    }

    private func newTokens(_ timings: [TokenTiming]) -> [LiveToken] {
        guard timings.count > consumed else { return [] }
        let fresh = timings[consumed...].map {
            LiveToken(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: Double($0.confidence))
        }
        consumed = timings.count
        return fresh
    }

    /// The model's prompts are FLEURS-style locales ("de-DE"); a bare language code is matched by the
    /// model's own table, which falls back to automatic detection when it doesn't know it.
    static func promptLanguage(_ language: String?) -> String {
        guard let language, !language.isEmpty else { return "auto" }
        let known = ["en": "en-US", "es": "es-ES", "fr": "fr-FR", "it": "it-IT", "pt": "pt-BR", "de": "de-DE",
                     "zh": "zh-CN", "ja": "ja-JP", "ko": "ko-KR", "ru": "ru-RU", "ar": "ar-AR", "hi": "hi-IN",
                     "nl": "nl-NL", "pl": "pl-PL", "sv": "sv-SE", "tr": "tr-TR", "uk": "uk-UA", "vi": "vi-VN"]
        if language.contains("-") { return language }
        return known[language.lowercased()] ?? language
    }

    /// Loads a bundle's models once, on the Neural Engine (and the CPU), never the GPU: an iPhone
    /// recording with the screen locked can't use the GPU.
    static func loadShared(from folder: URL) async throws -> SharedNemotronMultilingualModels {
        guard SystemInfo.isAppleSilicon else { throw LiveModelError.unsupportedDevice }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        return try await StreamingNemotronMultilingualAsrManager.preloadShared(from: folder, configuration: configuration)
    }
}
