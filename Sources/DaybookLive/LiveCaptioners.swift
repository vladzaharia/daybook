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
///
/// Models load when a capture starts, are shared between captures (You and Call), and go when the
/// last capture using them ends (`LiveModelHost`). Each capture backs off under load on its own
/// (`LiveLoadPolicy`).
public struct LiveCaptioners: Sendable {
    public let host: LiveModelHost
    public let policy: LiveLoadPolicy
    public let conditions: @Sendable () -> LiveConditions
    public let voices: (any KnownVoiceSource)?

    public init(host: LiveModelHost, policy: LiveLoadPolicy, voices: (any KnownVoiceSource)? = nil,
                conditions: @escaping @Sendable () -> LiveConditions = { .system() }) {
        self.host = host; self.policy = policy; self.voices = voices; self.conditions = conditions
    }

    /// One capture's captioner, or nil when neither a local recognizer nor `fallback` gives words.
    /// `backlog` and `timelineOrigin` are as for `SpeechCaptioner`.
    public func captioner(models: LiveModelSet, locale: Locale, backlog: Int, timelineOrigin: TimeInterval? = nil,
                          fallback: () -> (any LiveCaptioning)?) -> (any LiveCaptioning)? {
        // Each part judges its own backlog.
        let words: (any LiveCaptioning)?
        if let recognizer = models.transcription, models.transcribes(locale) {
            let use = LiveModelUse(host: host)
            words = LocalStreamingCaptioner(backlog: backlog, timelineOrigin: timelineOrigin,
                                            governor: LiveLoadGovernor(policy: policy, conditions: conditions),
                                            makeTranscriber: { locale in
                                                let shared = try await use.transcription(recognizer)
                                                return try await NemotronStreamingTranscriber(shared: shared, language: Self.language(locale))
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
                                            let diarizer = try NemotronLiveDiarizer(shared: try await use.diarization(speakers))
                                            guard let voiceModel, let space = voiceModel.capabilities.voiceEmbeddings?.space,
                                                  let voices else { return LiveSpeakerSession(diarizer: diarizer) }
                                            let known = await voices.knownVoices(in: space)
                                            // Nobody to recognize: no voice model to load.
                                            guard !known.isEmpty, let embedder = try? await use.embedding(voiceModel) else {
                                                return LiveSpeakerSession(diarizer: diarizer)
                                            }
                                            return LiveSpeakerSession(diarizer: diarizer,
                                                                      embedding: WeSpeakerVoiceEmbedding(embedder: embedder, space: space),
                                                                      voices: known)
                                        }, onEnd: { await use.release() })
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

    func release() async {
        let items = lock.withLock { () -> [(LiveModelHost.Kind, ModelInstallation)] in defer { held = [] }; return held }
        for (kind, installation) in items { await host.done(kind, installation) }
    }

    private func hold(_ kind: LiveModelHost.Kind, _ installation: ModelInstallation) {
        lock.withLock { held.append((kind, installation)) }
    }
}
