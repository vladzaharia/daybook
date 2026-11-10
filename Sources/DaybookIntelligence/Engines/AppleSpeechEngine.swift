import AVFoundation
import DaybookCore
import DaybookKit
import Foundation
import Speech
import Synchronization

/// Apple's on-device speech model through the Speech framework: `SpeechAnalyzer` with a `SpeechTranscriber`, on
/// macOS 26 or iOS 26 and later. There is nothing for Daybook to download, so its catalog variant is `systemProvided`;
/// the system installs and shares its own speech assets, a language at a time, the first time one is needed
/// (`AssetInventory`). Whether this device has the transcriber is decided each time (`descriptor.unavailableReason`).
///
/// It serves `transcription`: word timings and confidences from each result's attributes, the approved vocabulary as
/// the analyzer's contextual strings, and a language hint as the transcriber's locale (Automatic transcribes in the
/// device's language). It gives no speakers. It's the transcriber a job can use while the model chosen for it isn't on
/// this device yet (docs/models.md, "Apple Speech"), ranked below every model a person chooses, so the Upgrade offer
/// redoes its transcript once theirs is here.
public struct AppleSpeechEngine: ModelEngine {
    /// Whether the system's transcriber can run here.
    public enum SystemAvailability: Equatable, Sendable {
        case available
        /// macOS 15: no `SpeechTranscriber`.
        case needsNewerSystem
        /// The system has no transcriber on this device (`SpeechTranscriber.isAvailable` is false, as in Simulator).
        case deviceNotEligible

        /// The availability label: why it can't run, in a few words.
        public var reason: String? {
            switch self {
            case .available: return nil
            case .needsNewerSystem: return ModelPlatform.current == .iOS ? "Needs iOS 26 or later" : "Needs macOS 26 or later"
            case .deviceNotEligible: return ModelPlatform.current == .iOS ? "Not available on this iPhone" : "Not available on this Mac"
            }
        }
    }

    /// One piece of a result's text as the transcriber reports it: a word with its leading space, or text it gave no
    /// time to.
    public struct Run: Equatable, Sendable {
        public var text: String
        /// Seconds into the recording; nil when the system gave the run no time range.
        public var start: Double?
        public var end: Double?
        public var confidence: Double?

        public init(text: String, start: Double? = nil, end: Double? = nil, confidence: Double? = nil) {
            self.text = text; self.start = start; self.end = end; self.confidence = confidence
        }
    }

    /// What transcribing asks of the system. Tests answer for it; `speechFramework` calls the Speech framework.
    public struct System: Sendable {
        /// The locale the system transcribes `locale` in, or nil when it doesn't transcribe that language.
        public var supportedLocale: @Sendable (_ locale: Locale) async -> Locale?
        /// Makes sure the system's speech assets for `locale` are on this device, installing them when they aren't, and
        /// reports the installation's progress (0–1) while it lasts.
        public var prepare: @Sendable (_ locale: Locale, _ progress: @escaping @Sendable (Double) -> Void) async throws -> Void
        /// Transcribes `url` in `locale`, expecting `terms`: each result's runs, in order. `heard` gets the end of each
        /// result, in seconds, as it arrives.
        public var transcribe: @Sendable (_ url: URL, _ locale: Locale, _ terms: [String],
                                          _ heard: @escaping @Sendable (Double) -> Void) async throws -> [[Run]]

        public init(supportedLocale: @escaping @Sendable (Locale) async -> Locale?,
                    prepare: @escaping @Sendable (Locale, @escaping @Sendable (Double) -> Void) async throws -> Void,
                    transcribe: @escaping @Sendable (URL, Locale, [String], @escaping @Sendable (Double) -> Void) async throws -> [[Run]]) {
            self.supportedLocale = supportedLocale; self.prepare = prepare; self.transcribe = transcribe
        }
    }

    let availability: @Sendable () -> SystemAvailability
    let system: System
    let deviceLocale: @Sendable () -> Locale

    /// - Parameters:
    ///   - availability: nil reads `SpeechTranscriber.isAvailable` (and the system version).
    ///   - system: nil uses the Speech framework.
    ///   - deviceLocale: the locale Automatic transcribes in; nil reads `Locale.current`.
    public init(availability: (@Sendable () -> SystemAvailability)? = nil, system: System? = nil,
                deviceLocale: (@Sendable () -> Locale)? = nil) {
        self.availability = availability ?? Self.systemAvailability
        self.system = system ?? .speechFramework
        self.deviceLocale = deviceLocale ?? { Locale.current }
    }

    public var descriptor: ModelEngineDescriptor {
        ModelEngineDescriptor(id: .appleSpeech, name: "Apple Speech", version: 1, runtime: Self.runtime,
                              roles: [.transcription], platforms: [.macOS, .iOS], residency: .system,
                              unavailableReason: availability().reason)
    }

    /// The system's model changes with the OS, so provenance records the OS version.
    static var runtime: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let system = ModelPlatform.current == .iOS ? "iOS" : "macOS"
        return "Speech, \(system) \(version.majorVersion).\(version.minorVersion)"
    }

    /// Only system installs (no files), and only while the system's transcriber is available.
    public func validate(_ installation: ModelInstallation) throws {
        guard installation.receipt.artifacts.isEmpty else { throw LocalIntelligenceError.modelNotInstalled(installation.key.variantKey) }
        if let reason = availability().reason {
            throw LocalIntelligenceError.unavailable(model: installation.key.variantKey, reason: reason)
        }
    }

    public func proposeAddition(_ request: ModelAdditionRequest, repository: ModelRepositorySnapshot) async throws -> ModelAdditionProposal {
        throw ModelAdditionError.invalid(["Apple’s speech model is part of the system, so there’s nothing to add."])
    }

    public func load(_ installation: ModelInstallation, role: ModelRole,
                     progress: @escaping IntelligenceProgressHandler) async throws -> any LoadedModel {
        try validate(installation)
        return AppleSpeechTranscriber(model: installation.key.variantKey, system: system, deviceLocale: deviceLocale())
    }

    // MARK: The system

    /// Read at most every few seconds: the interface asks for every model row it draws.
    static let systemAvailability: @Sendable () -> SystemAvailability = { availabilityCache.value(readSystemAvailability) }
    private static let availabilityCache = RecentValue<SystemAvailability>(lifetime: 5)

    private static func readSystemAvailability() -> SystemAvailability {
        if #available(macOS 26.0, iOS 26.0, *) { return SpeechTranscriber.isAvailable ? .available : .deviceNotEligible }
        return .needsNewerSystem
    }
}

extension AppleSpeechEngine.System {
    /// The Speech framework, on macOS 26 or iOS 26 and later; before that every question fails.
    public static var speechFramework: Self {
        Self(supportedLocale: { locale in
            guard #available(macOS 26.0, iOS 26.0, *) else { return nil }
            return await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        }, prepare: { locale, progress in
            guard #available(macOS 26.0, iOS 26.0, *) else { throw SystemSpeech.tooOld }
            try await SystemSpeech.prepare(locale: locale, progress: progress)
        }, transcribe: { url, locale, terms, heard in
            guard #available(macOS 26.0, iOS 26.0, *) else { throw SystemSpeech.tooOld }
            return try await SystemSpeech.transcribe(url: url, locale: locale, terms: terms, heard: heard)
        })
    }
}

/// The loaded system transcriber: each recording asks for its locale, the system's assets for it, and a fresh analyzer.
final class AppleSpeechTranscriber: Transcribing, @unchecked Sendable {
    let model: String
    let system: AppleSpeechEngine.System
    let deviceLocale: Locale

    init(model: String, system: AppleSpeechEngine.System, deviceLocale: Locale) {
        self.model = model; self.system = system; self.deviceLocale = deviceLocale
    }

    func transcribe(url: URL, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        try await transcribe(url: url, glossary: glossary, language: nil, progress: progress)
    }

    /// `language` is the transcriber's locale (`AppleSpeechLocales.requested`); without one it's the device's. The
    /// glossary is given to the analyzer as contextual strings.
    func transcribe(url: URL, glossary: [String], language: String?,
                    progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        let (duration, channels) = try MonoAudioReader.describe(url)
        guard duration.isFinite, duration > 0 else { throw LocalIntelligenceError.invalidAudio }
        let requested = AppleSpeechLocales.requested(language: language, device: deviceLocale)
        guard let locale = await system.supportedLocale(requested) else {
            let code = TranscriptionLanguages.normalize(language ?? requested.identifier) ?? requested.identifier
            throw LocalIntelligenceError.unavailable(model: model, reason: "Doesn’t transcribe \(TranscriptionLanguages.name(code))")
        }
        try Task.checkCancellation()
        // The first recording in a language waits while the system installs that language's model.
        let preparing = WholePercents()
        try await system.prepare(locale) { fraction in
            if preparing.changed(to: fraction) { progress(.init(fraction, "Preparing the system’s speech model")) }
        }
        try Task.checkCancellation()

        // Mixed to mono first, as for Parakeet, so every channel is heard. The copy is the conversation's audio, so it's
        // made where a crash leaves nothing for long (`ProcessingScratch`).
        var source = url
        var temporary: URL?
        if channels > 1 {
            let mono = try ProcessingScratch.file(extension: "caf")
            try MonoAudioReader.writeMonoCopy(of: url, to: mono)
            source = mono; temporary = mono
        }
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }

        progress(.init(0, "Transcribing"))
        let phrases = try await system.transcribe(source, locale, AppleSpeechWords.terms(glossary)) { seconds in
            guard seconds.isFinite else { return }
            progress(.init(seconds / duration, "Transcribed \(Int(min(seconds, duration))) of \(Int(duration)) seconds"))
        }
        try Task.checkCancellation()
        let words = AppleSpeechWords.words(from: phrases, spaced: AppleSpeechLocales.separatesWords(locale), duration: duration)
        progress(.init(1, "Transcribed \(Int(duration)) of \(Int(duration)) seconds"))
        return RecognitionResult(segments: ParakeetWords.segments(from: words), language: AppleSpeechLocales.language(of: locale),
                                 duration: duration)
    }
}

/// Which locale the system transcribes in.
enum AppleSpeechLocales {
    /// Languages written without spaces between words.
    static let unspaced: Set<String> = ["ja", "zh", "yue", "th", "lo", "km", "my", "bo"]

    /// The locale to ask the system for: the device's own for Automatic, or when the language is the device's (so a
    /// British English speaker keeps en-GB); otherwise the language in its likeliest region ("de" as de-DE), since the
    /// system matches a language alone to any of its regions.
    static func requested(language: String?, device: Locale) -> Locale {
        guard let code = TranscriptionLanguages.normalize(language), code != Self.language(of: device) else { return device }
        return Locale(identifier: Locale.Language(identifier: code).maximalIdentifier)
    }

    /// "en" for en-GB, "yue" for Cantonese; nil when the locale names no language.
    static func language(of locale: Locale) -> String? {
        TranscriptionLanguages.normalize(locale.language.languageCode?.identifier)
    }

    /// Whether the locale's language puts spaces between words, so each passage's first word gets one too.
    static func separatesWords(_ locale: Locale) -> Bool {
        language(of: locale).map { !unspaced.contains($0) } ?? true
    }
}

/// The transcriber's results as words, the shape the rest of the pipeline (speaker assignment, ROVER fusion) uses for
/// every recognizer, then grouped into passages as Parakeet's are (`ParakeetWords.segments`).
enum AppleSpeechWords {
    /// The approved vocabulary as contextual strings: each term once, trimmed.
    static func terms(_ glossary: [String]) -> [String] {
        var seen = Set<String>()
        return glossary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Words from each result's runs. A run is usually one word with its leading space and its punctuation (" Friday.");
    /// one holding several is split at its spaces, its time shared by their lengths. Text with no time joins the word
    /// before it, or the next one at a result's start (a lone space only when that word has none). In a language
    /// written with spaces, a result's first word gets one, as Whisper's and Parakeet's words have, so passages join
    /// directly. A run's confidence is the system's; one without takes its result's mean. Each word lasts at least one
    /// 80 ms frame, so it overlaps a speaker turn.
    static func words(from phrases: [[AppleSpeechEngine.Run]], spaced: Bool, duration: Double? = nil) -> [RecognizedWord] {
        var words: [RecognizedWord] = []
        func appending(_ text: String, to word: RecognizedWord) -> RecognizedWord {
            RecognizedWord(text: word.text + text, start: word.start, end: word.end, confidence: word.confidence)
        }
        for runs in phrases {
            let known = runs.compactMap(\.confidence).filter(\.isFinite)
            let fallback = known.isEmpty ? 0.5 : known.reduce(0, +) / Double(known.count)
            var phrase: [RecognizedWord] = []
            var pending = ""
            for run in runs {
                let blank = run.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                guard let start = run.start, let end = run.end, start.isFinite, end.isFinite, end >= start, !blank else {
                    if !blank, let last = phrase.last { phrase[phrase.count - 1] = appending(run.text, to: last) } else { pending += run.text }
                    continue
                }
                let confidence = min(1, max(0, run.confidence.flatMap { $0.isFinite ? $0 : nil } ?? fallback))
                let pieces = split(run.text)
                let letters = Double(pieces.reduce(0) { $0 + $1.trimmingCharacters(in: .whitespaces).count })
                var at = start
                for piece in pieces {
                    let share = letters > 0 ? Double(piece.trimmingCharacters(in: .whitespaces).count) / letters : 1 / Double(pieces.count)
                    let pieceEnd = at + (end - start) * share
                    let lead = piece.first?.isWhitespace == true && pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : pending
                    phrase.append(word(lead + piece, start: at, end: pieceEnd, confidence: confidence, duration: duration))
                    pending = ""
                    at = pieceEnd
                }
            }
            if let first = phrase.first, spaced, !(first.text.first?.isWhitespace ?? true) {
                phrase[0] = RecognizedWord(text: " " + first.text, start: first.start, end: first.end, confidence: first.confidence)
            }
            // A result whose last text has no time keeps it on the word before.
            if !pending.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let last = phrase.last ?? words.last {
                if phrase.isEmpty { words[words.count - 1] = appending(pending, to: last) } else { phrase[phrase.count - 1] = appending(pending, to: last) }
            }
            words += phrase
        }
        return words
    }

    /// " New York" → [" New", " York"]: each piece keeps the space before it.
    static func split(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = ""
        for character in text {
            if character.isWhitespace, !current.trimmingCharacters(in: .whitespaces).isEmpty {
                pieces.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { pieces.append(current) }
        else if let last = pieces.popLast() { pieces.append(last + current) }
        return pieces
    }

    private static func word(_ text: String, start: Double, end: Double, confidence: Double, duration: Double?) -> RecognizedWord {
        var end = max(end, start + ParakeetWords.minimumWordSeconds)
        if let duration { end = min(end, max(duration, start)) }
        return RecognizedWord(text: text, start: max(0, start), end: end, confidence: confidence)
    }
}

/// Reports a fraction only when it reaches another whole percent.
private final class WholePercents: Sendable {
    private let last = Mutex(-1)
    func changed(to fraction: Double) -> Bool {
        let percent = ModelStatus.percent(fraction)
        return last.withLock { last in
            guard percent != last else { return false }
            last = percent
            return true
        }
    }
}

// MARK: - The Speech framework

/// The Speech framework's side of `AppleSpeechEngine.System.speechFramework`.
enum SystemSpeech {
    static var tooOld: LocalIntelligenceError {
        .unavailable(model: "apple-speech/system", reason: AppleSpeechEngine.SystemAvailability.needsNewerSystem.reason ?? "")
    }

    /// Timed words with confidences, final results only.
    @available(macOS 26.0, iOS 26.0, *)
    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }

    /// Asks the system for `locale`'s assets. It answers nil when they're installed; otherwise it installs them, which
    /// also reserves the language for Daybook.
    @available(macOS 26.0, iOS 26.0, *)
    static func prepare(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)]) else { return }
        // Told as the installation moves (KVO), rather than polled.
        let watcher = request.progress.observe(\.fractionCompleted, options: [.new]) { installation, _ in
            guard installation.totalUnitCount > 0 else { return }
            progress(installation.fractionCompleted)
        }
        defer { watcher.invalidate() }
        try await request.downloadAndInstall()
        progress(1)
    }

    /// One recording through a fresh analyzer that finishes at the file's end. Cancelling the task stops the analyzer.
    @available(macOS 26.0, iOS 26.0, *)
    static func transcribe(url: URL, locale: Locale, terms: [String],
                           heard: @escaping @Sendable (Double) -> Void) async throws -> [[AppleSpeechEngine.Run]] {
        let transcriber = transcriber(locale)
        // Kept a while after use, so a conversation's next recording doesn't load the model again.
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering))
        if !terms.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = terms
            // A context the analyzer won't take leaves the transcript as it would be without the vocabulary.
            try? await analyzer.setContext(context)
        }
        let file = try AVAudioFile(forReading: url)
        return try await withTaskCancellationHandler {
            let results = Task { () -> [[AppleSpeechEngine.Run]] in
                var phrases: [[AppleSpeechEngine.Run]] = []
                for try await result in transcriber.results {
                    phrases.append(runs(of: result.text))
                    heard(result.range.end.seconds)
                }
                return phrases
            }
            do {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
            return try await results.value
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// A result's text as runs, each with the time range and confidence the system attached to it.
    @available(macOS 26.0, iOS 26.0, *)
    static func runs(of text: AttributedString) -> [AppleSpeechEngine.Run] {
        text.runs.map { run in
            let range = run.audioTimeRange
            return AppleSpeechEngine.Run(text: String(text[run.range].characters), start: range?.start.seconds, end: range?.end.seconds,
                                         confidence: run.transcriptionConfidence)
        }
    }
}
