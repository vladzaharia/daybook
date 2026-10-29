import DaybookCaptions
import DaybookKit
import DaybookModelStore
import FluidAudio
import Foundation

/// Builds each capture's captioner from the live models a device has (docs/model-runtime.md, "Live"):
///
/// - Words come from the local streaming recognizer when one is installed and covers the language,
///   else from `fallback` (the system's speech recognizer, as before live models existed).
/// - With a live speaker model installed, captions are labelled with speakers, and named when a
///   voice matches a known voice in the voice-profile model's space.
/// - The local recognizer is biased toward `vocabulary` (the library's approved terms), following it
///   as it changes.
///
/// Models load when a capture starts, are shared between captures (You and Call), and go when the
/// last capture using them ends (`LiveModelHost`). Each capture backs off under load on its own
/// (`LiveLoadPolicy`).
public struct LiveCaptioners: Sendable {
    public let host: LiveModelHost
    public let policy: LiveLoadPolicy
    public let conditions: @Sendable () -> LiveConditions
    public let voices: (any KnownVoiceSource)?
    public let vocabulary: LiveVocabulary?

    /// What each capture's parts are made from: FluidAudio's models; tests script them.
    var parts = LiveParts.fluidAudio

    public init(host: LiveModelHost, policy: LiveLoadPolicy, voices: (any KnownVoiceSource)? = nil,
                vocabulary: LiveVocabulary? = nil, conditions: @escaping @Sendable () -> LiveConditions = { .system() }) {
        self.host = host; self.policy = policy; self.voices = voices; self.vocabulary = vocabulary; self.conditions = conditions
    }

    /// One capture's captioner, or nil when neither a local recognizer nor `fallback` gives words.
    /// `backlog` and `timelineOrigin` are as for `SpeechCaptioner`.
    public func captioner(models: LiveModelSet, locale: Locale, backlog: Int, timelineOrigin: TimeInterval? = nil,
                          fallback: () -> (any LiveCaptioning)?) -> (any LiveCaptioning)? {
        // Each part judges its own backlog.
        let words: (any LiveCaptioning)?
        let parts = self.parts
        if let recognizer = models.transcription, models.transcribes(locale) {
            let use = LiveModelUse(host: host)
            words = LocalStreamingCaptioner(backlog: backlog, timelineOrigin: timelineOrigin,
                                            governor: LiveLoadGovernor(policy: policy, conditions: conditions),
                                            vocabulary: vocabulary,
                                            makeTranscriber: { locale in
                                                try await parts.transcriber(use, recognizer, Self.language(locale))
                                            }, onEnd: { await use.release() })
        } else {
            words = fallback()
        }
        guard let words else { return nil }
        guard let speakers = models.diarization else { return words }
        let voiceModel = models.voiceProfiles, voices = self.voices
        let use = LiveModelUse(host: host)
        return SpeakerLabelledCaptioner(inner: words, backlog: backlog, timelineOrigin: timelineOrigin,
                                        governor: LiveLoadGovernor(policy: policy, conditions: conditions),
                                        makeSpeakers: {
                                            try await Self.speakers(parts: parts, use: use, diarization: speakers,
                                                                    voiceModel: voiceModel, voices: voices)
                                        }, onEnd: { await use.release() })
    }

    /// One capture's speaker model and, when there are voices to recognize, the voice-profile model.
    static func speakers(parts: LiveParts, use: LiveModelUse, diarization: ModelInstallation, voiceModel: ModelInstallation?,
                         voices: (any KnownVoiceSource)?) async throws -> LiveSpeakerSession {
        let diarizer = try await parts.diarizer(use, diarization)
        guard let voiceModel, let space = voiceModel.capabilities.voiceEmbeddings?.space,
              let voices else { return LiveSpeakerSession(diarizer: diarizer) }
        let known = await voices.knownVoices(in: space)
        // Nobody to recognize: no voice model to load.
        guard !known.isEmpty, let embedding = try? await parts.embedding(use, voiceModel, space) else {
            return LiveSpeakerSession(diarizer: diarizer)
        }
        return LiveSpeakerSession(diarizer: diarizer, embedding: embedding, voices: known)
    }

    /// The language the recognizer is prompted with: the captions' locale as BCP-47 ("en-US").
    static func language(_ locale: Locale) -> String? {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        if let region = locale.region?.identifier { return "\(code)-\(region)" }
        return code
    }
}

/// The models one captioner took from the host, given back exactly once when it ends.
final class LiveModelUse: @unchecked Sendable {
    private let host: LiveModelHost
    private let lock = NSLock()
    private var held: [(LiveModelHost.Kind, ModelInstallation)] = []

    init(host: LiveModelHost) { self.host = host }

    func transcription(_ installation: ModelInstallation) async throws -> SharedNemotronMultilingualModels {
        let value = try await host.useTranscription(installation)
        hold(.transcription, installation)
        return value
    }

    func diarization(_ installation: ModelInstallation) async throws -> LoadedDiarizer {
        let value = try await host.useDiarization(installation)
        hold(.diarization, installation)
        return value
    }

    func embedding(_ installation: ModelInstallation) async throws -> WeSpeakerEmbedder {
        let value = try await host.useEmbedding(installation)
        hold(.embedding, installation)
        return value
    }

    /// Any model of `kind`, loaded once by `load` and shared (tests' scripted models).
    func shared<Value: Sendable>(_ kind: LiveModelHost.Kind, _ installation: ModelInstallation,
                                 load: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let value = try await host.use(kind, installation, load: load)
        hold(kind, installation)
        return value
    }

    func release() async {
        let items = lock.withLock { () -> [(LiveModelHost.Kind, ModelInstallation)] in defer { held = [] }; return held }
        for (kind, installation) in items { await host.done(kind, installation) }
    }

    private func hold(_ kind: LiveModelHost.Kind, _ installation: ModelInstallation) {
        lock.withLock { held.append((kind, installation)) }
    }
}

/// How a capture's parts are made from the models the host shares: one recognizer, speaker model, and
/// voice-profile model loaded once; each capture gets its own decoder state over them.
struct LiveParts: Sendable {
    var transcriber: @Sendable (LiveModelUse, ModelInstallation, String?) async throws -> any LiveTranscribing
    var diarizer: @Sendable (LiveModelUse, ModelInstallation) async throws -> any LiveDiarizing
    var embedding: @Sendable (LiveModelUse, ModelInstallation, String) async throws -> any LiveVoiceEmbedding

    /// FluidAudio's Nemotron streaming recognizer and live speaker model, and Community-1's WeSpeaker.
    static let fluidAudio = LiveParts(
        transcriber: { use, installation, language in
            try await NemotronStreamingTranscriber(shared: try await use.transcription(installation), language: language)
        },
        diarizer: { use, installation in try NemotronLiveDiarizer(shared: try await use.diarization(installation)) },
        embedding: { use, installation, space in WeSpeakerVoiceEmbedding(embedder: try await use.embedding(installation), space: space) })
}
