import Foundation
import NaturalLanguage

// Language routing (docs/models.md, "Language routing"): which transcription model a job runs for
// the transcription language the person chose, and, for Automatic, whether a transcript turned out
// to be in a language its model doesn't cover. Decisions read the `languages` capability, never
// model IDs: nil or ["*"] covers every language.

/// Language codes as transcription choices use them: lowercased primary subtags ("en", "pt").
public enum TranscriptionLanguages {
    /// Whisper's languages, the set a `["*"]` capability stands for (the large-v3 tokenizer's list;
    /// Javanese as its ISO code "jv" rather than Whisper's "jw").
    public static let whisper: [String] = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it", "id", "hi", "fi", "vi",
        "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur", "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk",
        "te", "fa", "lv", "bn", "sr", "az", "sl", "kn", "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw",
        "gl", "mr", "pa", "si", "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha", "ba", "jv", "su", "yue"]

    /// "en-US" → "en", "pt_BR" → "pt", "zh-Hant" → "zh", "jw" → "jv"; nil for an empty code.
    public static func normalize(_ code: String?) -> String? {
        guard let code else { return nil }
        let primary = code.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        switch primary {
        case "": return nil
        case "jw": return "jv"
        case "iw": return "he"
        case "nb": return "no"
        default: return primary
        }
    }

    /// Whether a `languages` capability covers every language (nil, empty, or "*").
    public static func coversEverything(_ languages: [String]?) -> Bool {
        guard let languages, !languages.isEmpty else { return true }
        return languages.contains("*")
    }

    /// Whether a `languages` capability covers `code`.
    public static func covers(_ languages: [String]?, _ code: String?) -> Bool {
        if coversEverything(languages) { return true }
        guard let code = normalize(code) else { return false }
        return languages!.contains { normalize($0) == code }
    }

    /// Every language some transcription model in the catalog covers, for the language picker:
    /// explicit lists plus Whisper's set when a model covers everything.
    public static func choices(in catalog: ModelCatalog, engines: [ModelEngineDescriptor]? = nil,
                               appVersion: ModelVersion? = ModelVersion.app) -> [String] {
        var codes = Set<String>()
        for model in catalog.models(for: .transcription) {
            if let engines, !model.availability(engines: engines, appVersion: appVersion).isAvailable { continue }
            if coversEverything(model.capabilities.languages) { codes.formUnion(whisper) }
            else { codes.formUnion(model.capabilities.languages!.compactMap(normalize)) }
        }
        return codes.sorted { name($0).localizedCaseInsensitiveCompare(name($1)) == .orderedAscending }
    }

    /// The language's name in the reader's language ("German"), or the code when unknown.
    public static func name(_ code: String, locale: Locale = .current) -> String {
        locale.localizedString(forLanguageCode: code) ?? code
    }
}

/// Which transcription model a job runs, decided when it's queued and frozen with it.
public struct TranscriptionRoute: Codable, Equatable, Sendable {
    /// The model that transcribes first: the selected one, or the other-languages model when the
    /// chosen language is one the selected model doesn't cover.
    public var model: String
    /// Automatic only: the model to transcribe with instead when the first transcript turns out to
    /// be in a language `model` doesn't cover (or can't be told).
    public var fallback: String?
    /// The chosen language; nil for Automatic.
    public var language: String?

    public init(model: String, fallback: String? = nil, language: String? = nil) {
        self.model = model; self.fallback = fallback; self.language = language
    }
}

public enum TranscriptionRouting {
    /// The route for `selected` and `language` (nil for Automatic), with `otherLanguages` standing in
    /// for languages `selected` doesn't cover.
    public static func route(selected: String, language: String?, otherLanguages: String?, catalog: ModelCatalog) -> TranscriptionRoute {
        let languages = catalog.model(selected)?.capabilities.languages
        let other = otherLanguages.flatMap { $0 == selected ? nil : catalog.model($0) }
        if let code = TranscriptionLanguages.normalize(language) {
            if TranscriptionLanguages.covers(languages, code) { return TranscriptionRoute(model: selected, language: code) }
            if let other, TranscriptionLanguages.covers(other.capabilities.languages, code) {
                return TranscriptionRoute(model: other.key, language: code)
            }
            // Nothing covers it: the selected model tries, rather than failing the job.
            return TranscriptionRoute(model: selected, language: code)
        }
        guard !TranscriptionLanguages.coversEverything(languages), let other, extends(other.capabilities.languages, beyond: languages) else {
            return TranscriptionRoute(model: selected)
        }
        return TranscriptionRoute(model: selected, fallback: other.key)
    }

    /// The model for languages `selected` doesn't cover: the person's choice when it still serves,
    /// otherwise the best transcription model that covers every language, preferring one already
    /// installed, in the presets' order (Detailed first). Nil when `selected` covers everything.
    public static func otherLanguagesModel(selected: String, chosen: String?, catalog: ModelCatalog,
                                           engines: [ModelEngineDescriptor]? = nil, installed: Set<String> = [],
                                           appVersion: ModelVersion? = ModelVersion.app) -> String? {
        let languages = catalog.model(selected)?.capabilities.languages
        guard !TranscriptionLanguages.coversEverything(languages) else { return nil }
        func usable(_ model: CatalogModel) -> Bool {
            model.key != catalog.model(selected)?.key && model.serves(.transcription)
                && (engines.map { model.availability(engines: $0, appVersion: appVersion).isAvailable } ?? true)
        }
        if let chosen, let model = catalog.model(chosen), usable(model), extends(model.capabilities.languages, beyond: languages) {
            return model.key
        }
        let presetOrder = ["detailed", "balanced", "quick"].compactMap { id in catalog.presets.first { $0.id == id } }
            .flatMap { $0.choices.roles[ModelRole.transcription.rawValue] ?? [] }
        let ordered = presetOrder.compactMap { catalog.model($0) } + catalog.models(for: .transcription)
        let candidates = ordered.filter { usable($0) && TranscriptionLanguages.coversEverything($0.capabilities.languages) }
        return (candidates.first { installed.contains($0.key) } ?? candidates.first)?.key
    }

    /// Whether `other` covers some language `languages` doesn't.
    static func extends(_ other: [String]?, beyond languages: [String]?) -> Bool {
        if TranscriptionLanguages.coversEverything(languages) { return false }
        if TranscriptionLanguages.coversEverything(other) { return true }
        let base = Set(languages!.compactMap(TranscriptionLanguages.normalize))
        return other!.compactMap(TranscriptionLanguages.normalize).contains { !base.contains($0) }
    }
}

// MARK: - Checking an Automatic transcript's language

/// One language a text may be in, with the detector's probability.
public struct LanguageGuess: Codable, Equatable, Sendable {
    public var language: String
    public var probability: Double
    public init(language: String, probability: Double) { self.language = language; self.probability = probability }
}

/// Whether an Automatic transcript stays with its model or is transcribed again with the
/// other-languages model. Text alone can't prove the language: a model that doesn't know a
/// language still writes words in the scripts it knows, with low confidence. So an unclear or
/// low-confidence transcript runs the other model too, and that model's own spoken-language
/// detection settles it.
public enum LanguageCheck {
    /// Fewer words than this (and fewer than 16 letters, for scripts written without spaces) can't
    /// be judged; the first transcript stays.
    public static let minimumWords = 4
    /// The detector's top guess must reach this to count.
    public static let minimumProbability = 0.6
    /// Mean word confidence below this makes an in-set guess uncertain.
    public static let minimumConfidence = 0.5

    public enum Verdict: Equatable, Sendable {
        /// The transcript is in a covered language (nil: too little text to tell).
        case keep(language: String?)
        /// The transcript reads clearly as a language the model doesn't cover.
        case outside(language: String)
        /// Unclear; transcribe again and let the other model's detection decide.
        case uncertain
    }

    public static func verdict(text: String, guesses: [LanguageGuess], meanConfidence: Double?, supported: [String]?) -> Verdict {
        if TranscriptionLanguages.coversEverything(supported) { return .keep(language: guesses.max { $0.probability < $1.probability }?.language) }
        let words = TranscriptNormalizer.words(text)
        guard words.count >= minimumWords || words.joined().count >= 16 else { return .keep(language: nil) }
        guard let top = guesses.max(by: { $0.probability < $1.probability }), top.probability >= minimumProbability,
              let code = TranscriptionLanguages.normalize(top.language) else { return .uncertain }
        guard TranscriptionLanguages.covers(supported, code) else { return .outside(language: code) }
        if let meanConfidence, meanConfidence < minimumConfidence { return .uncertain }
        return .keep(language: code)
    }

    /// Whether an unclear transcript is probably in another language: no language reads clearly and
    /// the recognizer wasn't sure of its words (Parakeet on Japanese speech: top guess 0.26, mean
    /// word confidence 0.36). Used to say so when the other model can't run.
    public static func likelyUnsupported(guesses: [LanguageGuess], meanConfidence: Double?) -> Bool {
        guard let meanConfidence, meanConfidence < minimumConfidence else { return false }
        return (guesses.map(\.probability).max() ?? 0) < minimumProbability
    }

    /// After the other model ran: use its transcript unless it heard a language the first model
    /// covers. When it reports no language, a clear outside verdict decides.
    public static func usesFallback(after verdict: Verdict, fallbackLanguage: String?, supported: [String]?) -> Bool {
        if let detected = TranscriptionLanguages.normalize(fallbackLanguage) { return !TranscriptionLanguages.covers(supported, detected) }
        if case .outside = verdict { return true }
        return false
    }
}

/// The languages a transcript's text reads as, from the system's language identifier.
public enum TranscriptLanguageDetector {
    /// Up to `maximum` guesses for `text`, sampled across long texts.
    public static func guesses(_ text: String, maximum: Int = 3) -> [LanguageGuess] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample(text))
        return recognizer.languageHypotheses(withMaximum: maximum)
            .compactMap { language, probability in
                TranscriptionLanguages.normalize(language.rawValue).map { LanguageGuess(language: $0, probability: probability) }
            }
            .sorted { $0.probability > $1.probability }
    }

    /// At most `limit` characters: the whole text, or evenly spaced passages of a long one.
    static func sample(_ text: String, limit: Int = 6_000) -> String {
        guard text.count > limit else { return text }
        let pieces = 6, length = limit / pieces
        let stride = (text.count - length) / (pieces - 1)
        return (0..<pieces).map { index in
            let start = text.index(text.startIndex, offsetBy: index * stride)
            return String(text[start..<text.index(start, offsetBy: length)])
        }.joined(separator: " ")
    }
}
