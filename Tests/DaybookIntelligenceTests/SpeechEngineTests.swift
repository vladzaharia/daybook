import CoreML
import DaybookCore
import DaybookKit
import Foundation
import XCTest
@testable import DaybookIntelligence

/// Parakeet and Nemotron 3 without their weights: token merging, speaker activity, installs and
/// additions against synthetic files and a scripted Hugging Face, voice-profile spans, and the
/// language router over a scripted `MeetingInference`.
final class SpeechEngineTests: XCTestCase {
    private var root: URL!
    private var hub: FakeHubClient!

    override func setUp() { root = SyntheticModels.temporaryDirectory(); hub = FakeHubClient() }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: Parakeet words

    private func token(_ text: String, _ start: Double, _ end: Double, _ confidence: Double) -> ParakeetWords.Token {
        .init(text: text, start: start, end: end, confidence: confidence)
    }

    func testSubwordTokensMergeIntoWordsWithTheirWeakestPiecesConfidence() {
        let words = ParakeetWords.words(from: [
            token(" Ship", 0.0, 0.3, 0.9), token(" it", 0.4, 0.5, 0.8), token("<blank>", 0.5, 0.5, 0.1),
            token(" Fri", 0.6, 0.8, 0.95), token("day", 0.8, 0.9, 0.6), token(".", 0.9, 0.92, 0.2),
            token("▁Day", 1.5, 1.7, 0.7), token("book", 1.7, 1.9, 0.99)])
        XCTAssertEqual(words.map(\.text), [" Ship", " it", " Friday.", " Daybook"], "Leading spaces, as Whisper's words have")
        XCTAssertEqual(words.map(\.confidence), [0.9, 0.8, 0.6, 0.7], "Minimum over pieces; punctuation doesn't count")
        XCTAssertEqual(words[2].start, 0.6)
        XCTAssertEqual(words[2].end, 0.92, "Punctuation extends the word")
    }

    func testWordsAlwaysSpanTimeAndStayInsideTheRecording() {
        let words = ParakeetWords.words(from: [token("hello", 1.0, 1.0, 0.9), token(" there", 2.98, 2.98, 0.9), token(" ,", 3.0, 3.0, 0.4)],
                                        duration: 3.0)
        XCTAssertEqual(words.map(\.text), [" hello", " there,"], "A first piece without a space still starts a word")
        XCTAssertEqual(words[0].end, 1.08, accuracy: 1e-9, "Zero-length words get one encoder frame, so they overlap a speaker turn")
        XCTAssertEqual(words[1].end, 3.0, accuracy: 1e-9, "Clamped to the recording")
        XCTAssertEqual(words[1].confidence, 0.9, "Punctuation's doubt is left out")
        XCTAssertTrue(ParakeetWords.words(from: [token("<blank>", 0, 0.1, 1), token(" ", 0.1, 0.2, 1)]).isEmpty)
    }

    func testABareWordBoundaryTokenStartsTheNextWord() {
        // Parakeet writes numbers as a bare "▁" followed by digit pieces; seen on real output as "handles25".
        let words = ParakeetWords.words(from: [token(" handles", 0, 0.4, 0.99), token("▁", 0.4, 0.45, 0.9), token("2", 0.45, 0.5, 0.95),
                                               token("5", 0.5, 0.6, 0.97), token(" European", 0.7, 1.1, 0.99), token(" ", 1.1, 1.1, 0.5),
                                               token(",", 1.1, 1.12, 0.6), token("ok", 1.3, 1.5, 0.9)])
        XCTAssertEqual(words.map(\.text), [" handles", " 25", " European,", " ok"], "Punctuation attaches; the boundary still holds")
        XCTAssertEqual(words[1].start, 0.45)
        XCTAssertEqual(words[1].confidence, 0.95)
    }

    func testWordsGroupIntoPassagesAtSentencesPausesAndLength() {
        func word(_ text: String, _ start: Double) -> RecognizedWord { RecognizedWord(text: text, start: start, end: start + 0.3, confidence: 0.8) }
        let segments = ParakeetWords.segments(from: [word(" Ship", 0), word(" it.", 0.4), word(" Then", 1.0), word(" review", 1.4),
                                                     word(" Monday", 3.0), word(" ok", 3.4)], pause: 1.0, maximumSeconds: 30)
        XCTAssertEqual(segments.map(\.text), ["Ship it.", "Then review", "Monday ok"])
        XCTAssertEqual(segments[1].words.count, 2)
        XCTAssertEqual(segments[0].confidence, 0.8, accuracy: 1e-9)
        let long = ParakeetWords.segments(from: (0..<10).map { word(" w\($0)", Double($0) * 0.5) }, maximumSeconds: 2)
        XCTAssertTrue(long.allSatisfy { $0.end - $0.start <= 2.0 + 1e-9 })
        XCTAssertEqual(long.flatMap(\.words).count, 10)
        XCTAssertTrue(ParakeetWords.segments(from: []).isEmpty)
    }

    // MARK: Parakeet installs

    private func parakeetFiles(vocabulary: Bool = true, joint: Bool = true, tokens: Int = 8192) -> [String: String] {
        var files: [String: String] = [:]
        for bundle in ParakeetEngine.bundles where joint || bundle != "JointDecisionv3.mlmodelc" {
            files[bundle + "/coremldata.bin"] = "data of \(bundle)"
            files[bundle + "/model.mil"] = "program of \(bundle)"
        }
        if vocabulary {
            let entries = (0..<tokens).map { "\"\($0)\": \"t\($0)\"" }.joined(separator: ",")
            files[ParakeetEngine.vocabulary] = "{\(entries)}"
        }
        return files
    }

    func testParakeetAdditionsAreCheckedAgainstTheRepositoryListing() async throws {
        hub.publish("someone/parakeet-ultra-coreml", commit: "p1", files: parakeetFiles(), license: "cc-by-4.0")
        let snapshot = try await ModelRepositorySnapshot.load("someone/parakeet-ultra-coreml", revision: "main", client: hub)
        let proposal = try await ParakeetEngine().proposeAddition(
            ModelAdditionRequest(repository: "someone/parakeet-ultra-coreml", role: .transcription, engine: .parakeet, variantName: "Ultra"),
            repository: snapshot)
        XCTAssertEqual(proposal.engineOptions["version"], "ultra", "From the repository name")
        XCTAssertEqual(proposal.capabilities.languages?.count, 25)
        XCTAssertEqual(proposal.capabilities.wordConfidence, true)
        XCTAssertEqual(proposal.capabilities.vocabularyPrompt, false)
        XCTAssertEqual(Set(proposal.artifacts[0].files.map(\.path)), Set(parakeetFiles().keys))

        hub.publish("someone/broken", commit: "b1", files: parakeetFiles(vocabulary: false, joint: false))
        let broken = try await ModelRepositorySnapshot.load("someone/broken", revision: "main", client: hub)
        do {
            _ = try await ParakeetEngine().proposeAddition(
                ModelAdditionRequest(repository: "someone/broken", role: .transcription, engine: .parakeet, variantName: "Broken"), repository: broken)
            XCTFail("Missing pieces")
        } catch ModelAdditionError.invalid(let problems) {
            XCTAssertEqual(problems.count, 2)
            XCTAssertTrue(problems.contains { $0.contains("JointDecisionv3.mlmodelc") })
        }
    }

    /// A synthetic Parakeet install through the runtime, verified without loading Core ML.
    private func parakeetRuntime(files: [String: String], options: [String: String] = ["version": "ultra"]) async throws -> LocalIntelligenceRuntime {
        hub.publish("toy/parakeet", commit: "rev-p", files: files)
        let fetcher = FakeFetcher(hub.contents("toy/parakeet", commit: "rev-p"))
        let listed = try await hub.files(repository: "toy/parakeet", revision: "rev-p", path: nil).map(\.manifestFile)
        let artifact = ModelArtifact(name: "model", repository: "toy/parakeet", revision: "rev-p", include: ["*"], files: listed)
        let manifest = ModelManifest(families: [ModelFamilyEntry(
            id: "parakeet", name: "Parakeet", engine: .parakeet, roles: [.transcription],
            variants: [ModelVariantEntry(id: "ultra", name: "Parakeet Ultra", capabilities: .init(languages: ParakeetEngine.languages),
                                         engineOptions: options,
                                         revisions: [ModelRevisionEntry(id: "rev-p", releaseDate: "2026-09-24", artifacts: [artifact])])])])
        return LocalIntelligenceRuntime(modelsDirectory: root, registry: ModelEngineRegistry([ParakeetEngine()]),
                                        builtIn: .init(manifest: manifest), fetcher: fetcher)
    }

    func testAParakeetInstallCountsOnlyWithEveryBundleAndAFullVocabulary() async throws {
        let runtime = try await parakeetRuntime(files: parakeetFiles())
        try await runtime.download(modelID: "parakeet/ultra")
        let installed = await runtime.installedModels()
        XCTAssertEqual(installed, ["parakeet/ultra"])
        let inventory = await runtime.inventory()
        let installation = try XCTUnwrap(inventory.resolve("parakeet/ultra")?.installation)
        XCTAssertNoThrow(try ParakeetEngine().validate(installation))
        XCTAssertEqual(ParakeetEngine.version(installation.engineOptions), .ultra)
        XCTAssertNil(ParakeetEngine.version(["version": "v9"]))
    }

    func testAParakeetDownloadWithAShortVocabularyIsRejected() async throws {
        let runtime = try await parakeetRuntime(files: parakeetFiles(tokens: 100))
        do {
            try await runtime.download(modelID: "parakeet/ultra")
            XCTFail("Every token below the blank ID is needed")
        } catch {}
        let installed = await runtime.installedModels()
        XCTAssertTrue(installed.isEmpty)
    }

    // MARK: Nemotron 3

    func testNemotronPresetsNameTheirBundlesInFluidInferencesLayout() throws {
        let offline = try XCTUnwrap(NemotronDiarizerEngine.configuration(["preset": "offline"]))
        XCTAssertEqual(offline.modelFileName, "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc")
        XCTAssertEqual(NemotronDiarizerEngine.requiredFiles(offline), [
            "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/coremldata.bin", "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/model.mil",
            "learnable_sil_emb.bin"])
        let compact = try XCTUnwrap(NemotronDiarizerEngine.configuration(["preset": "c128-split-w8a8"]))
        XCTAssertEqual(compact.modelFileName, "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc")
        XCTAssertTrue(NemotronDiarizerEngine.requiredFiles(compact).contains("pre_encode_proj_t.bin"))
        XCTAssertEqual(NemotronDiarizerEngine.configuration([:])?.modelFileName, offline.modelFileName, "Offline by default")
        XCTAssertNil(NemotronDiarizerEngine.configuration(["preset": "turbo"]))
    }

    func testNemotronAdditionsAndInstallsNeedTheBundleAndItsAssets() async throws {
        let files = ["monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/coremldata.bin": "c", "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/model.mil": "m",
                     "monolithic/v2/Nemotron3Diarizer_offline.mlmodelc/weights/weight.bin": "w", "learnable_sil_emb.bin": "s",
                     "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc/coremldata.bin": "x", "README.md": "readme"]
        hub.publish("someone/nemotron", commit: "n1", files: files, license: "openmdw-1.1")
        let snapshot = try await ModelRepositorySnapshot.load("someone/nemotron", revision: "main", client: hub)
        let proposal = try await NemotronDiarizerEngine().proposeAddition(
            ModelAdditionRequest(repository: "someone/nemotron", role: .diarization, engine: .nemotronDiarizer, variantName: "Nemotron"),
            repository: snapshot)
        XCTAssertEqual(proposal.capabilities.maxSpeakers, 8)
        XCTAssertNil(proposal.capabilities.voiceEmbeddings)
        XCTAssertEqual(Set(proposal.artifacts[0].files.map(\.path)), Set(files.keys.filter { $0.hasPrefix("monolithic") || $0 == "learnable_sil_emb.bin" }),
                       "Only the preset's bundle and the silence embedding")
        do {
            _ = try await NemotronDiarizerEngine().proposeAddition(
                ModelAdditionRequest(repository: "someone/nemotron", role: .diarization, engine: .nemotronDiarizer, variantName: "Compact",
                                     options: ["preset": "c128-split-w8a8"]), repository: snapshot)
            XCTFail("The split build needs its projection")
        } catch ModelAdditionError.invalid(let problems) {
            XCTAssertTrue(problems.contains { $0.contains("pre_encode_proj_t.bin") })
        }
    }

    func testSpeakerActivityBecomesTurnsAsFramesArrive() {
        // Two speakers at 10 ms per frame: A 0–0.5 s with a 0.1 s dip, B 0.6–0.65 s (too short) and 1.0–1.4 s.
        let frames = 150
        var probabilities = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<50 where !(20..<30).contains(frame) { probabilities[frame * 2] = 0.9 }
        for frame in 60..<65 { probabilities[frame * 2 + 1] = 0.8 }
        for frame in 100..<140 { probabilities[frame * 2 + 1] = 0.7 }
        var whole = SpeakerActivity(speakers: 2, frameSeconds: 0.01)
        whole.append(probabilities, frames: frames)
        let turns = whole.finish()
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speaker, 0)
        XCTAssertEqual(turns[0].start, 0, accuracy: 1e-9)
        XCTAssertEqual(turns[0].end, 0.5, accuracy: 1e-9, "The 0.1 s dip is bridged")
        XCTAssertEqual(turns[0].confidence, 0.9, accuracy: 1e-6)
        XCTAssertEqual(turns[1].speaker, 1)
        XCTAssertEqual(turns[1].start, 1.0, accuracy: 1e-9, "0.05 s of B is dropped as too short")
        XCTAssertEqual(turns[1].end, 1.4, accuracy: 1e-9)

        // Arriving in uneven chunks gives the same turns.
        var streamed = SpeakerActivity(speakers: 2, frameSeconds: 0.01)
        var offset = 0
        for size in [7, 33, 1, 59, 50] {
            streamed.append(Array(probabilities[(offset * 2)..<((offset + size) * 2)]), frames: size)
            offset += size
        }
        XCTAssertEqual(streamed.finish(), turns)

        // Exactly the minimum length (20 frames) is kept; exactly the gap (25 frames) isn't bridged.
        var edges = SpeakerActivity(speakers: 1, frameSeconds: 0.01)
        let edge: [Float] = Array(repeating: 0.9, count: 20) + Array(repeating: 0, count: 25) + Array(repeating: 0.9, count: 20)
        edges.append(edge, frames: edge.count)
        XCTAssertEqual(edges.finish().map { [$0.start, $0.end] }.flatMap { $0 }.map { ($0 * 100).rounded() / 100 }, [0, 0.2, 0.45, 0.65])
    }

    // MARK: Voice profiles for another model's turns

    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn {
        SpeakerTurn(speakerID: speaker, start: start, end: end, confidence: 1)
    }

    func testVoiceProfilesUseEachSpeakersCleanestSpeech() {
        let plan = VoiceSpans.select([turn("S1", 0, 4), turn("S2", 3, 5.5), turn("S1", 6, 30), turn("S3", 31, 31.6), turn("S3", 32, 32.3)])
        // S1 alone: 0–3, then 6–30 split into the model's 10 s windows.
        XCTAssertEqual(plan["S1"], [.init(start: 0, end: 3), .init(start: 6, end: 16), .init(start: 16, end: 26), .init(start: 26, end: 30)])
        XCTAssertEqual(plan["S2"], [.init(start: 4, end: 5.5)], "Only the part after the overlap")
        XCTAssertEqual(plan["S3"], [.init(start: 31, end: 31.6)], "Never alone for a second: the longest turn of at least 0.5 s")
        XCTAssertEqual(VoiceSpans.select([turn("S1", 0, 0.3)]), [:], "Too little speech for a profile")
        XCTAssertEqual(VoiceSpans.select([turn("S1", 0, 100)], limit: 3)["S1"]?.count, 3)
    }

    func testVoiceProfilesAverageByDuration() throws {
        let mean = try XCTUnwrap(VoiceSpans.average([(vector: [1, 0], weight: 3), (vector: [0, 1], weight: 1)]))
        XCTAssertEqual(mean[0], 0.75, accuracy: 1e-6)
        XCTAssertEqual(mean[1], 0.25, accuracy: 1e-6)
        XCTAssertNil(VoiceSpans.average([]))
        XCTAssertNil(VoiceSpans.average([(vector: [1, 0], weight: 1), (vector: [1], weight: 1)]))
    }

    func testFBankFeaturesRecenterOnFramesWithSignal() throws {
        // Frames of 400 samples every 160: frames 0 and 1 hold only digital silence, frames 2 and 3 hold signal.
        var audio = [Float](repeating: 0, count: 1_000)
        for index in 560..<1_000 { audio[index] = 0.1 }
        let features = try MLMultiArray(shape: [1, 1, 2, 4], dataType: .float32)
        let values: [Float] = [-10, -10, 2, 4, /* band 2 */ -9, -9, 1, 3]
        for (index, value) in values.enumerated() { features[index] = NSNumber(value: value) }
        WeSpeakerSpanEmbedder.recenterOnSignal(features, audio: audio)
        XCTAssertEqual((0..<8).map { features[$0].floatValue }, [-13, -13, -1, 1, -11, -11, -1, 1])

        let untouched = try MLMultiArray(shape: [1, 1, 1, 2], dataType: .float32)
        untouched[0] = 5; untouched[1] = 7
        WeSpeakerSpanEmbedder.recenterOnSignal(untouched, audio: [Float](repeating: 0.2, count: 600))
        XCTAssertEqual([untouched[0].floatValue, untouched[1].floatValue], [5, 7], "No silent frame: left as the model made it")
        XCTAssertEqual(WeSpeakerSpanEmbedder.floats(features).count, 8)
    }

    // MARK: Language routing

    private final class Scripted: MeetingInference, @unchecked Sendable {
        struct Reply { var text: String; var language: String?; var confidence: Double }
        private let lock = NSLock()
        private var _calls: [String] = []
        var replies: [String: Reply] = [:]
        var missing: Set<String> = []
        var languages: [String: [String]] = ["parakeet/ultra": ParakeetEngine.languages, "whisper/large-v3-turbo": ["*"]]
        var calls: [String] { lock.withLock { _calls } }

        func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            try await transcribe(url: url, model: model, glossary: glossary, language: nil, progress: progress)
        }

        func transcribe(url: URL, model: ModelReference, glossary: [String], language: String?,
                        progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
            lock.withLock { _calls.append("transcribe \(model.id) \(language ?? "auto")") }
            if missing.contains(model.id) { throw LocalIntelligenceError.modelNotInstalled(model.id) }
            let reply = replies[model.id] ?? Reply(text: "Hello", language: nil, confidence: 0.9)
            let words = reply.text.split(separator: " ").enumerated().map {
                RecognizedWord(text: " " + $0.element, start: Double($0.offset) * 0.5, end: Double($0.offset) * 0.5 + 0.4, confidence: reply.confidence)
            }
            var result = RecognitionResult(segments: [RecognizedSegment(start: 0, end: words.last?.end ?? 0, text: reply.text,
                                                                        confidence: reply.confidence, words: words)],
                                           language: language ?? reply.language, duration: 10)
            result.provenance = ModelProvenance(family: model.id.components(separatedBy: "/")[0], variant: model.id.components(separatedBy: "/")[1],
                                                revision: "rev", engine: "toy", engineVersion: "1")
            return result
        }

        func capabilities(of model: ModelReference) async -> ModelCapabilities? { ModelCapabilities(languages: languages[model.id]) }

        func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions, progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
            SpeakerAnalysis(turns: [], embeddings: [:])
        }

        func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                       templateInstructions: String?, highlightEvidence: String?, progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
            throw CancellationError()
        }
    }

    private let english = "We agreed to ship the prototype on Friday and review the results next Monday"
    private let turkish = "Bu toplantıda prototipi cuma günü göndermeye ve sonuçları pazartesi incelemeye karar verdik"
    private let url = URL(fileURLWithPath: "/tmp/a.caf")

    private func router(_ inference: Scripted, language: String? = nil) -> TranscriptionRouter {
        TranscriptionRouter(inference: inference, model: "parakeet/ultra", language: language, fallback: "whisper/large-v3-turbo")
    }

    func testAChosenLanguageIsPassedAndNoCheckRuns() async throws {
        let inference = Scripted()
        let outcome = try await router(inference, language: "de").run(url: url, glossary: [], progress: { _ in })
        XCTAssertEqual(inference.calls, ["transcribe parakeet/ultra de"])
        XCTAssertEqual(outcome.result.language, "de")
        XCTAssertEqual(outcome.parameters, ["language": "de"])
    }

    func testAConfidentCoveredTranscriptIsKeptWithoutASecondPass() async throws {
        let inference = Scripted()
        inference.replies["parakeet/ultra"] = .init(text: english, language: nil, confidence: 0.92)
        let outcome = try await router(inference).run(url: url, glossary: [], progress: { _ in })
        XCTAssertEqual(inference.calls, ["transcribe parakeet/ultra auto"])
        XCTAssertEqual(outcome.model.id, "parakeet/ultra")
        XCTAssertEqual(outcome.result.language, "en")
        XCTAssertEqual(outcome.parameters["languageCheck"], "kept")
    }

    func testAnotherLanguageIsTranscribedByTheOtherModelAndRecordedAsSo() async throws {
        let inference = Scripted()
        inference.replies["parakeet/ultra"] = .init(text: turkish, language: nil, confidence: 0.7)
        inference.replies["whisper/large-v3-turbo"] = .init(text: turkish, language: "tr", confidence: 0.8)
        let outcome = try await router(inference).run(url: url, glossary: [], progress: { _ in })
        XCTAssertEqual(inference.calls, ["transcribe parakeet/ultra auto", "transcribe whisper/large-v3-turbo auto"])
        XCTAssertEqual(outcome.model.id, "whisper/large-v3-turbo")
        XCTAssertEqual(outcome.result.provenance?.variantKey, "whisper/large-v3-turbo")
        XCTAssertEqual(outcome.parameters["languageCheck"], "switched")
        XCTAssertEqual(outcome.parameters["detectedLanguage"], "tr")
        XCTAssertEqual(outcome.parameters["routedFrom"], "parakeet/ultra")
    }

    func testAnUnclearTranscriptStaysWhenTheOtherModelHearsACoveredLanguage() async throws {
        let inference = Scripted()
        inference.replies["parakeet/ultra"] = .init(text: english, language: nil, confidence: 0.3)
        inference.replies["whisper/large-v3-turbo"] = .init(text: "we agreed to ship", language: "en", confidence: 0.5)
        let outcome = try await router(inference).run(url: url, glossary: [], progress: { _ in })
        XCTAssertEqual(inference.calls.count, 2)
        XCTAssertEqual(outcome.model.id, "parakeet/ultra")
        XCTAssertEqual(outcome.result.segments.first?.text, english)
        XCTAssertEqual(outcome.result.language, "en")
        XCTAssertEqual(outcome.parameters["languageCheck"], "kept")
    }

    func testAMissingOtherModelKeepsTheTranscriptAndSaysWhatToDownloadOnlyWhenItMatters() async throws {
        let inference = Scripted()
        inference.missing = ["whisper/large-v3-turbo"]
        inference.replies["parakeet/ultra"] = .init(text: turkish, language: nil, confidence: 0.7)
        let outside = try await router(inference).run(url: url, glossary: [], progress: { _ in })
        XCTAssertEqual(outside.model.id, "parakeet/ultra")
        XCTAssertEqual(outside.parameters["languageCheck"], "unavailable")
        XCTAssertEqual(outside.notices.count, 1)
        XCTAssertTrue(outside.notices[0].contains("Download Whisper Large v3 Turbo in Models"), outside.notices[0])

        inference.replies["parakeet/ultra"] = .init(text: english, language: nil, confidence: 0.3)
        let unclear = try await router(inference).run(url: url, glossary: [], progress: { _ in })
        XCTAssertTrue(unclear.notices.isEmpty, "Plausible English heard with little confidence stays quiet")

        // Parakeet's actual output for Japanese speech: no clear language, little confidence.
        inference.replies["parakeet/ultra"] = .init(text: "O hayogo zaimas, kinjobini xsak hingo škashte getsuyobini kekkaokakuninximas.",
                                                    language: nil, confidence: 0.36)
        let foreign = try await router(inference).run(url: url, glossary: [], progress: { _ in })
        XCTAssertEqual(foreign.notices, ["This recording may be in a language Parakeet Ultra doesn’t transcribe. Download Whisper Large v3 Turbo in Models to transcribe it."])
    }

    func testTheProcessingEngineRecordsTheModelThatActuallyTranscribed() async throws {
        let inference = Scripted()
        inference.replies["parakeet/ultra"] = .init(text: turkish, language: nil, confidence: 0.7)
        inference.replies["whisper/large-v3-turbo"] = .init(text: turkish, language: "tr", confidence: 0.8)
        let engine = InferenceProcessingEngine(inference: inference, configuration: .init(
            transcriptionModel: "parakeet/ultra", summaryModel: "unused", detectSpeakers: false, speakerModel: "unused",
            speakerOptions: .init(), fingerprint: "f", speakerMatchThreshold: 0.8, speakerMatchMargin: 0.05,
            languageFallbackModel: "whisper/large-v3-turbo"))
        let track = RecordingTrack(source: .microphone, relativePath: "Originals/a.caf", fileName: "a.caf", duration: 10, sha256: "a")
        let output = try await engine.transcribe(TrackProcessingInput(meetingID: UUID(), track: track, audioURL: url, mode: .newAudio), progress: { _ in })
        XCTAssertEqual(output.transcript.modelID, "whisper/large-v3-turbo")
        XCTAssertEqual(output.transcript.processingSettings?.model?.variantKey, "whisper/large-v3-turbo")
        XCTAssertEqual(output.transcript.language, "tr")
        XCTAssertEqual(output.transcript.processingSettings?.parameters["languageCheck"], "switched")
        XCTAssertEqual(output.transcript.processingSettings?.parameters["mode"], "newAudio", "The usual parameters stay")
    }

    func testWhisperDetectsTheLanguageUnlessOneIsChosen() {
        // WhisperKit prefills English when given no language and no detection; Automatic must detect.
        XCTAssertTrue(WhisperKitTranscriber.languageSettings(for: nil) == (nil, true))
        XCTAssertTrue(WhisperKitTranscriber.languageSettings(for: "ja") == ("ja", false))
        XCTAssertTrue(WhisperKitTranscriber.languageSettings(for: "pt-BR") == ("pt", false), "Whisper takes the primary subtag")
        XCTAssertTrue(WhisperKitTranscriber.languageSettings(for: "DE") == ("de", false))
        XCTAssertTrue(WhisperKitTranscriber.languageSettings(for: "xx") == (nil, true), "A language Whisper doesn't know is detected")
    }
}
