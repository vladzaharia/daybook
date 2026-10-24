import DaybookCore
import DaybookKit
import Foundation

/// Runs one track's transcription along its route (docs/models.md, "Language routing"). With a
/// chosen language the job's model already covers it and gets the language as a hint. With
/// Automatic and a model that covers only some languages, the transcript's language is checked
/// (`LanguageCheck`): if it reads as another language, or can't be told, the other-languages model
/// transcribes too, and its own spoken-language detection decides which transcript is kept.
struct TranscriptionRouter {
    let inference: any MeetingInference
    let model: ModelReference
    /// The chosen language; nil for Automatic.
    let language: String?
    /// Automatic only: the other-languages model.
    let fallback: ModelReference?

    struct Outcome {
        var result: RecognitionResult
        /// The model that produced `result`.
        var model: ModelReference
        /// What the run records about the decision ("language", "languageCheck", "detectedLanguage").
        var parameters: [String: String] = [:]
        var notices: [String] = []
    }

    func run(url: URL, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> Outcome {
        let first = try await inference.transcribe(url: url, model: model, glossary: glossary, language: language, progress: progress)
        if let language {
            return Outcome(result: Self.labelled(first, language: first.language ?? language), model: model, parameters: ["language": language])
        }
        guard let fallback, fallback.id != model.id else { return Outcome(result: first, model: model) }
        let supported = await inference.capabilities(of: model)?.languages
        guard !TranscriptionLanguages.coversEverything(supported) else { return Outcome(result: first, model: model) }

        let text = first.segments.map(\.text).joined(separator: " ")
        let words = first.segments.flatMap(\.words)
        let confidence = words.isEmpty ? nil : words.map(\.confidence).reduce(0, +) / Double(words.count)
        let guesses = TranscriptLanguageDetector.guesses(text)
        let verdict = LanguageCheck.verdict(text: text, guesses: guesses, meanConfidence: confidence, supported: supported)
        var parameters = ["language": "automatic"]
        if let top = guesses.first { parameters["detectedLanguage"] = top.language }
        switch verdict {
        case .keep(let detected):
            parameters["languageCheck"] = "kept"
            return Outcome(result: Self.labelled(first, language: first.language ?? detected), model: model, parameters: parameters)
        case .outside, .uncertain:
            let second: RecognitionResult
            do {
                second = try await inference.transcribe(url: url, model: fallback, glossary: glossary, language: nil, progress: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                parameters["languageCheck"] = "unavailable"
                var outcome = Outcome(result: first, model: model, parameters: parameters)
                // A notice only when the transcript is probably in another language; an unclear
                // check of plausible text keeps the transcript quietly.
                if case .outside(let detected) = verdict {
                    outcome.result = Self.labelled(first, language: detected)
                    outcome.notices.append(Self.notice(language: detected, model: model, fallback: fallback, error: error))
                } else if LanguageCheck.likelyUnsupported(guesses: guesses, meanConfidence: confidence) {
                    outcome.notices.append(Self.notice(language: nil, model: model, fallback: fallback, error: error))
                }
                return outcome
            }
            if LanguageCheck.usesFallback(after: verdict, fallbackLanguage: second.language, supported: supported) {
                parameters["languageCheck"] = "switched"
                parameters["detectedLanguage"] = second.language ?? parameters["detectedLanguage"]
                parameters["routedFrom"] = model.id
                return Outcome(result: second, model: fallback, parameters: parameters)
            }
            parameters["languageCheck"] = "kept"
            parameters["detectedLanguage"] = second.language ?? parameters["detectedLanguage"]
            return Outcome(result: Self.labelled(first, language: first.language ?? TranscriptionLanguages.normalize(second.language)),
                           model: model, parameters: parameters)
        }
    }

    /// `result` with `language` recorded.
    static func labelled(_ result: RecognitionResult, language: String?) -> RecognitionResult {
        var labelled = RecognitionResult(segments: result.segments, language: TranscriptionLanguages.normalize(language) ?? result.language,
                                         duration: result.duration)
        labelled.provenance = result.provenance
        return labelled
    }

    static func notice(language: String?, model: ModelReference, fallback: ModelReference, error: Error) -> String {
        let place = language.map { "in \(TranscriptionLanguages.name($0))" }
            ?? "in a language \(ModelCatalog.builtIn.name(for: model.id)) doesn’t transcribe"
        let other = ModelCatalog.builtIn.name(for: fallback.id)
        if let failure = error as? LocalIntelligenceError, case .modelNotInstalled = failure {
            return "This recording may be \(place). Download \(other) in Models to transcribe it."
        }
        return "This recording may be \(place), but \(other) couldn’t transcribe it: \(error.localizedDescription)"
    }
}

extension LocalIntelligenceRuntime {
    /// The catalog's capabilities for `model` (language routing reads `languages`).
    public func capabilities(of model: ModelReference) async -> ModelCapabilities? {
        catalog.model(model.id)?.capabilities
    }
}
