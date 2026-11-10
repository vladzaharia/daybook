import AVFoundation
import DaybookCore
import DaybookKit
import DaybookTestSupport
import Foundation
import Synchronization
import XCTest
@testable import DaybookIntelligence

/// The system's speech model (Apple Speech) without the system: availability, the catalog entry, the locale each
/// recording asks for, the system's assets prepared on first use, the vocabulary, and results turned into words and
/// passages, against a scripted `System`. The real `SpeechTranscriber` runs only in the opt-in smoke test
/// (`--smoke-test --transcription-model apple-speech/system`, docs/model-runtime.md).
final class AppleSpeechEngineTests: XCTestCase {
    private var root: URL!
    private let key = "apple-speech/system"

    override func setUp() { root = SyntheticModels.temporaryDirectory() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// What the scripted system was asked, in order.
    private final class Asked: @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [String] = []
        private var _terms: [String] = []
        private var _channels: [AVAudioChannelCount] = []
        var entries: [String] { lock.withLock { _entries } }
        var terms: [String] { lock.withLock { _terms } }
        var channels: [AVAudioChannelCount] { lock.withLock { _channels } }
        func add(_ entry: String) { lock.withLock { _entries.append(entry) } }
        func transcribed(_ url: URL, terms: [String]) {
            let channels = (try? AVAudioFile(forReading: url))?.processingFormat.channelCount ?? 0
            lock.withLock { _terms = terms; _channels.append(channels) }
        }
    }

    /// The results the real transcriber gave for the smoke test's fixture, its first two sentences.
    private let fixture: [[AppleSpeechEngine.Run]] = [
        [.init(text: "Welcome", start: 0, end: 0.54, confidence: 0.992), .init(text: " to", start: 0.54, end: 0.66, confidence: 0.999),
         .init(text: " the", start: 0.66, end: 0.78, confidence: 0.995), .init(text: " project", start: 0.78, end: 0.96, confidence: 0.683),
         .init(text: " planning", start: 0.96, end: 1.44, confidence: 0.649), .init(text: " meeting.", start: 1.44, end: 2.22, confidence: 0.824)],
        [.init(text: " Our", start: 2.34, end: 2.64, confidence: 0.969), .init(text: " application", start: 2.64, end: 3.18, confidence: 0.995),
         .init(text: " is", start: 3.18, end: 3.6, confidence: 0.995), .init(text: " called", start: 3.6, end: 3.9, confidence: 0.643),
         .init(text: " Daybook.", start: 3.9, end: 4.56, confidence: 0.816)]]

    /// A system that transcribes the languages in `supported` (each in the locale given, or the language's own) and
    /// answers every recording with `phrases`.
    private func system(_ asked: Asked, supported: Set<String> = ["en", "de", "ja"], phrases: [[AppleSpeechEngine.Run]]? = nil,
                        installing: [Double] = []) -> AppleSpeechEngine.System {
        let phrases = phrases ?? fixture
        return AppleSpeechEngine.System(supportedLocale: { locale in
            asked.add("locale \(locale.identifier)")
            return supported.contains(locale.language.languageCode?.identifier ?? "") ? locale : nil
        }, prepare: { locale, progress in
            asked.add("prepare \(locale.identifier)")
            for fraction in installing { progress(fraction) }
        }, transcribe: { url, locale, terms, heard in
            asked.add("transcribe \(locale.identifier)")
            asked.transcribed(url, terms: terms)
            for phrase in phrases { if let end = phrase.last?.end { heard(end) } }
            return phrases
        })
    }

    private func engine(_ asked: Asked, availability: AppleSpeechEngine.SystemAvailability = .available, device: String = "en_US",
                        supported: Set<String> = ["en", "de", "ja"], phrases: [[AppleSpeechEngine.Run]]? = nil,
                        installing: [Double] = []) -> AppleSpeechEngine {
        AppleSpeechEngine(availability: { availability },
                          system: system(asked, supported: supported, phrases: phrases, installing: installing),
                          deviceLocale: { Locale(identifier: device) })
    }

    private func manifest() throws -> ModelManifest {
        let builtIn = try ModelCatalog.readBuiltInManifest().manifest
        return ModelManifest(families: builtIn.families.filter { $0.id == "apple-speech" })
    }

    private func runtime(_ engine: AppleSpeechEngine) throws -> LocalIntelligenceRuntime {
        LocalIntelligenceRuntime(modelsDirectory: root, registry: .standard.registering(engine), builtIn: .init(manifest: try manifest()),
                                 fetcher: FakeFetcher())
    }

    /// `seconds` of a quiet tone at 16 kHz, with `channels` channels.
    private func recording(seconds: Double = 5, channels: AVAudioChannelCount = 1) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).wav")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000.0, AVNumberOfChannelsKey: channels,
                                       AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * 16_000)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            for index in 0..<Int(frames) { buffer.floatChannelData![channel][index] = Float(sin(Double(index) * 0.05) * 0.1) }
        }
        try file.write(from: buffer)
        return url
    }

    // MARK: The engine and its catalog entry

    func testAvailabilityFollowsTheSystemAndSaysWhy() throws {
        let catalog = ModelCatalog(builtIn: try manifest())
        let model = try XCTUnwrap(catalog.model(key))
        let cases: [(AppleSpeechEngine.SystemAvailability, String?)] = [
            (.available, nil), (.needsNewerSystem, "Needs macOS 26 or later"), (.deviceNotEligible, "Not available on this Mac")]
        for (state, label) in cases {
            let engine = engine(Asked(), availability: state)
            XCTAssertEqual(engine.descriptor.unavailableReason, label)
            XCTAssertEqual(model.availability(engines: [engine.descriptor], appVersion: nil, platform: .macOS).label, label)
            let installation = ModelInstallation(receipt: ModelInstallReceipt(model: model, revision: ModelRevisionEntry(id: "system", artifacts: [])),
                                                 directory: root)
            if label == nil { XCTAssertNoThrow(try engine.validate(installation)) } else { XCTAssertThrowsError(try engine.validate(installation)) }
        }
        let descriptor = AppleSpeechEngine().descriptor
        XCTAssertEqual(descriptor.id, .appleSpeech)
        XCTAssertEqual(descriptor.roles, [.transcription])
        XCTAssertEqual(descriptor.platforms, [.macOS, .iOS])
        XCTAssertEqual(descriptor.residency, .system, "It runs in the system: it releases nothing and nothing releases it")
        XCTAssertTrue(descriptor.runtime.hasPrefix("Speech, macOS "), "Provenance records the system version that provided the model")
    }

    func testTheBuiltInCatalogListsTheSystemSpeechModelBelowEveryChoice() throws {
        let catalog = ModelCatalog.builtIn
        let model = try XCTUnwrap(catalog.model(key))
        XCTAssertEqual(model.engine, .appleSpeech)
        XCTAssertEqual(model.roles, [.transcription])
        XCTAssertEqual(model.name, "Apple Speech")
        XCTAssertTrue(model.isSystemModel)
        XCTAssertTrue(model.variant.revisions.isEmpty, "Nothing to download")
        XCTAssertEqual(model.approximateBytes, 0)
        XCTAssertEqual(model.capabilities.wordTimestamps, true)
        XCTAssertEqual(model.capabilities.wordConfidence, true)
        XCTAssertEqual(model.capabilities.vocabularyPrompt, true, "The vocabulary goes in as contextual strings")
        let languages = try XCTUnwrap(model.capabilities.languages)
        XCTAssertFalse(TranscriptionLanguages.coversEverything(languages), "Only the languages the system transcribes")
        for code in ["en", "de", "fr", "es", "it", "pt", "ja", "ko", "zh", "yue", "hi"] { XCTAssertTrue(languages.contains(code), code) }
        XCTAssertFalse(languages.contains("nl"), "Dutch isn't one")
        let rank = try XCTUnwrap(model.quality(for: .transcription))
        for other in catalog.models(for: .transcription) where other.key != key {
            let theirs = try XCTUnwrap(other.quality(for: .transcription), other.key)
            XCTAssertGreaterThanOrEqual(theirs - rank, UpgradeRole.transcription.margin,
                                        "\(other.key) is offered over its transcripts, Parakeet Redux included")
        }
        let registry = ModelEngineRegistry.standard
        XCTAssertEqual(registry.engine(model.engine)?.descriptor.roles, [.transcription])
    }

    // MARK: Transcribing

    func testTheRuntimeTranscribesWithTheSystemModelWithoutDownloading() async throws {
        let asked = Asked()
        let runtime = try runtime(engine(asked))
        let installed = await runtime.installedModels()
        XCTAssertEqual(installed, [key], "Available without a download")
        try await runtime.download(modelID: key)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("appleSpeech").path), "Nothing is stored")

        let url = try recording()
        let result = try await runtime.transcribe(url: url, model: ModelReference(key), glossary: ["Daybook", " Daybook ", "", "Priya"],
                                                  language: "de")
        XCTAssertEqual(asked.entries, ["locale de-DE", "prepare de-DE", "transcribe de-DE"],
                       "A language the device doesn't speak is asked for in its likeliest region; its assets first")
        XCTAssertEqual(asked.terms, ["Daybook", "Priya"], "The approved vocabulary, each term once")
        XCTAssertEqual(result.language, "de")
        XCTAssertEqual(result.duration, 5, accuracy: 0.01)
        XCTAssertEqual(result.provenance?.engine, "appleSpeech")
        XCTAssertEqual(result.provenance?.variantKey, key)
        XCTAssertEqual(result.segments.map(\.text), ["Welcome to the project planning meeting.", "Our application is called Daybook."])
        let words = result.segments.flatMap(\.words)
        XCTAssertEqual(words.count, 11)
        XCTAssertEqual(words.first?.text, " Welcome", "Leading spaces, as Whisper's and Parakeet's words have")
        XCTAssertEqual(words[3].confidence, 0.683, accuracy: 1e-9, "The system's own confidence")
        XCTAssertEqual(words.last?.end ?? 0, 4.56, accuracy: 1e-9)
    }

    func testAutomaticTranscribesInTheDevicesOwnLocale() async throws {
        let asked = Asked()
        let model = try await engine(asked, device: "en_GB").load(systemInstallation(), role: .transcription, progress: { _ in }) as? any Transcribing
        let transcriber = try XCTUnwrap(model)
        let url = try recording()
        let automatic = try await transcriber.transcribe(url: url, glossary: [], language: nil, progress: { _ in })
        _ = try await transcriber.transcribe(url: url, glossary: [], language: "en-US", progress: { _ in })
        _ = try await transcriber.transcribe(url: url, glossary: [], language: "ja", progress: { _ in })
        XCTAssertEqual(asked.entries.filter { $0.hasPrefix("locale") }, ["locale en_GB", "locale en_GB", "locale ja-JP"],
                       "The device's language keeps its region; another goes to its own")
        XCTAssertEqual(automatic.language, "en")
        XCTAssertEqual(asked.terms, [], "No vocabulary, no contextual strings")
    }

    func testALanguageTheSystemDoesntTranscribeFailsWithAReason() async throws {
        let asked = Asked()
        let runtime = try runtime(engine(asked))
        do {
            _ = try await runtime.transcribe(url: try recording(), model: ModelReference(key), language: "nl")
            XCTFail("The system doesn't transcribe Dutch")
        } catch LocalIntelligenceError.unavailable(let model, let reason) {
            XCTAssertEqual(model, key)
            XCTAssertEqual(reason, "Doesn’t transcribe \(TranscriptionLanguages.name("nl"))")
        }
        XCTAssertEqual(asked.entries, ["locale nl-NL"], "Nothing is installed or transcribed")
    }

    func testFirstUseWaitsWhileTheSystemInstallsItsModelAndSaysSo() async throws {
        let asked = Asked()
        let reports = Mutex<[IntelligenceProgress]>([])
        let model = try await engine(asked, installing: [0.25, 0.251, 0.5, 1]).load(systemInstallation(), role: .transcription,
                                                                                 progress: { _ in }) as? any Transcribing
        _ = try await XCTUnwrap(model).transcribe(url: try recording(), glossary: [], language: "en") { update in
            reports.withLock { $0.append(update) }
        }
        let seen = reports.withLock { $0 }
        let preparing = seen.filter { $0.message == "Preparing the system’s speech model" }
        XCTAssertEqual(preparing.map(\.fraction), [0.25, 0.5, 1], "Whole percents, as the installation moves")
        let first = try XCTUnwrap(seen.firstIndex { $0.message == "Transcribing" })
        XCTAssertLessThan(seen.lastIndex { $0.message == "Preparing the system’s speech model" } ?? 0, first, "Before transcribing")
        XCTAssertEqual(seen.last?.fraction, 1)
        XCTAssertEqual(seen.last?.message, "Transcribed 5 of 5 seconds")
    }

    func testARecordingWithSeveralChannelsIsMixedDownFirst() async throws {
        let asked = Asked()
        let model = try await engine(asked).load(systemInstallation(), role: .transcription, progress: { _ in }) as? any Transcribing
        _ = try await XCTUnwrap(model).transcribe(url: try recording(channels: 2), glossary: [], language: nil, progress: { _ in })
        XCTAssertEqual(asked.channels, [1], "Every channel is heard")
    }

    func testWhenTheSystemCantRunItNothingIsInstalledOrRun() async throws {
        let asked = Asked()
        let runtime = try runtime(engine(asked, availability: .needsNewerSystem))
        let installed = await runtime.installedModels()
        XCTAssertTrue(installed.isEmpty)
        do {
            _ = try await runtime.transcribe(url: try recording(), model: ModelReference(key))
            XCTFail("Unavailable")
        } catch LocalIntelligenceError.unavailable(let model, let reason) {
            XCTAssertEqual(model, key)
            XCTAssertEqual(reason, "Needs macOS 26 or later")
        }
        XCTAssertTrue(asked.entries.isEmpty)
    }

    // MARK: Words and locales

    func testRunsBecomeWordsWithTheirTimesAndConfidences() {
        let words = AppleSpeechWords.words(from: [
            [.init(text: "New York", start: 0, end: 1.0, confidence: 0.9), .init(text: ",", confidence: nil),
             .init(text: " ok", start: 1.2, end: 1.5, confidence: nil), .init(text: " ")],
            [.init(text: " ", start: nil, end: nil), .init(text: " then", start: 2.0, end: 2.0, confidence: 0.7),
             .init(text: " later", start: 2.9, end: 3.4, confidence: .nan)]], spaced: true, duration: 3.0)
        XCTAssertEqual(words.map(\.text), [" New", " York,", " ok", " then", " later"],
                       "Split at spaces; untimed punctuation joins the word before; a result's first word gets a space")
        XCTAssertEqual(words[0].end, 3.0 / 7.0, accuracy: 1e-9, "Time shared by length: \"New\" has 3 of 7 letters")
        XCTAssertEqual(words[1].start, 3.0 / 7.0, accuracy: 1e-9)
        XCTAssertEqual(words[2].confidence, 0.9, accuracy: 1e-9, "No confidence: its result's mean")
        XCTAssertEqual(words[3].end, 2.08, accuracy: 1e-9, "A zero-length word gets one 80 ms frame")
        XCTAssertEqual(words[4].end, 3.0, accuracy: 1e-9, "Clamped to the recording")
        XCTAssertEqual(words[4].confidence, 0.7, accuracy: 1e-9, "A confidence that isn't a number counts as none")
        XCTAssertEqual(ParakeetWords.segments(from: words).map(\.text), ["New York, ok then later"], "Passages as Parakeet's are")
    }

    func testLanguagesWithoutSpacesKeepTheirTextAsItIs() {
        let words = AppleSpeechWords.words(from: [[.init(text: "今日は", start: 0, end: 0.6, confidence: 0.9),
                                                   .init(text: "晴れ。", start: 0.6, end: 1.0, confidence: 0.8)]],
                                           spaced: false)
        XCTAssertEqual(words.map(\.text), ["今日は", "晴れ。"])
        XCTAssertEqual(ParakeetWords.segments(from: words).map(\.text), ["今日は晴れ。"])
        XCTAssertFalse(AppleSpeechLocales.separatesWords(Locale(identifier: "ja_JP")))
        XCTAssertFalse(AppleSpeechLocales.separatesWords(Locale(identifier: "zh_HK")))
        XCTAssertTrue(AppleSpeechLocales.separatesWords(Locale(identifier: "de_DE")))
    }

    func testTheLocaleAskedForIsTheDevicesForItsOwnLanguage() {
        let british = Locale(identifier: "en_GB")
        XCTAssertEqual(AppleSpeechLocales.requested(language: nil, device: british).identifier, "en_GB")
        XCTAssertEqual(AppleSpeechLocales.requested(language: "en", device: british).identifier, "en_GB")
        XCTAssertEqual(AppleSpeechLocales.requested(language: "de-AT", device: british).identifier, "de-DE",
                       "A chosen language is a language, not a region")
        XCTAssertEqual(AppleSpeechLocales.requested(language: "pt", device: british).identifier, "pt-BR")
        XCTAssertEqual(AppleSpeechLocales.language(of: Locale(identifier: "pt_PT")), "pt")
        XCTAssertEqual(AppleSpeechWords.terms([" Daybook", "Daybook", "", "  ", "QA"]), ["Daybook", "QA"])
    }

    // MARK: Helpers

    private func systemInstallation() throws -> ModelInstallation {
        let model = try XCTUnwrap(ModelCatalog(builtIn: try manifest()).model(key))
        return ModelInstallation(receipt: ModelInstallReceipt(model: model, revision: ModelRevisionEntry(id: "system", artifacts: [])),
                                 directory: root)
    }
}
