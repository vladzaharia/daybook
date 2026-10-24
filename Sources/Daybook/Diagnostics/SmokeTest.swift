import DaybookIntelligence
import DaybookKit
import Foundation
import DaybookCore

/// Explicitly invoked diagnostics. Never creates a meeting in the user's library.
@MainActor
enum SmokeTest {
    static func run(arguments: [String]) async -> Int32 {
        let started = Date()
        var report = SmokeReport(started: started)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("Daybook-Smoke-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        let models = value("--models").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? AppState.libraryURL.appendingPathComponent("Models", isDirectory: true)
        let output = value("--output").map { URL(fileURLWithPath: $0) }
        // Flags accept variant keys ("qwen2.5/1.5b-4bit") or the older catalog IDs ("qwen-1.5b").
        let catalog = ModelCatalog.builtIn
        let initial = ModelRecommendations.initialSelections(catalog: catalog)
        func key(_ id: String?) -> String { id.map { catalog.model($0)?.key ?? $0 } ?? "" }
        let transcriptionModel = key(value("--transcription-model") ?? initial[.transcription])
        let summaryModel = key(value("--summary-model") ?? initial[.summarization])
        // "--speaker-model none" skips speaker detection, to check speech and summaries alone.
        let speakerModel = value("--speaker-model") == "none" ? "" : key(value("--speaker-model") ?? initial[.diarization])
        let smallTasksModel = initial[.smallTasks].map { key($0) }
        let speakerQuality = SpeakerQuality(rawValue: value("--speaker-quality") ?? "balanced") ?? .balanced
        let speakerOptions = SpeakerAnalysisOptions(quality: speakerQuality,
                                                    expectedSpeakerCount: value("--expected-speakers").flatMap(Int.init))
        // --skip-summary checks speech and speakers only; --language passes a transcription language;
        // --voice-model makes voice profiles for a speaker model without them (used only when installed
        // or named explicitly, so --download-models never fetches it unasked).
        let skipSummary = arguments.contains("--skip-summary")
        let language = TranscriptionLanguages.normalize(value("--language"))
        let voiceModel = value("--voice-model").map { key($0) }
        report.speakerModel = speakerModel
        report.speakerQuality = speakerQuality.rawValue
        let runtime = LocalIntelligenceRuntime(modelsDirectory: models)
        let progress: IntelligenceProgressHandler = { update in
            print(String(format: "[%3.0f%%] %@", update.fraction * 100, update.message))
        }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            await runtime.prepare()
            let identifiers = ([transcriptionModel] + (skipSummary ? [] : [summaryModel]) + [speakerModel] + [voiceModel].compactMap { $0 })
                .filter { !$0.isEmpty }
            if arguments.contains("--download-models") {
                for id in identifiers { try await runtime.download(modelID: id, progress: progress) }
            }
            let installed = await runtime.installedModels()
            guard identifiers.allSatisfy(installed.contains) else {
                throw SmokeFailure("Missing models: \(identifiers.filter { !installed.contains($0) }.joined(separator: ", ")). Run explicitly with --download-models once.")
            }
            let audio: URL
            let generatedFixture = value("--audio") == nil
            if let path = value("--audio") { audio = URL(fileURLWithPath: path) }
            else {
                audio = temporary.appendingPathComponent("fixture.aiff")
                // This system speech tool is used only to generate a diagnostic
                // fixture. Actual recognition, diarization, and summary inference
                // below run through the same embedded runtime as the application.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-v", "Samantha", "-r", "145", "-o", audio.path,
                    "Welcome to the project planning meeting. Our application is called Daybook. We agreed to ship the prototype on Friday. Alex will write the onboarding checklist. The audio capture is working. Our main blocker is testing speaker detection. We will review the results next Monday. Thank you for joining this meeting."]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw SmokeFailure("Could not generate the diagnostic audio fixture.") }
            }
            let transcriptionStarted = Date()
            let speech = try await runtime.transcribe(url: audio, model: ModelReference(transcriptionModel),
                                                     glossary: ["Daybook"], language: language, progress: progress)
            report.transcriptionSeconds = Date().timeIntervalSince(transcriptionStarted)
            report.transcriptionModel = speech.provenance?.variantKey ?? transcriptionModel
            report.language = speech.language
            let words = speech.segments.flatMap(\.words)
            report.recognizedWords = words.count
            report.meanWordConfidence = words.isEmpty ? nil : words.map(\.confidence).reduce(0, +) / Double(words.count)
            let transcript = speech.segments.map { String(format: "[%.1fs] %@", $0.start, $0.text) }.joined(separator: "\n")
            guard !speech.segments.isEmpty, transcript.count > 20 else { throw SmokeFailure("Speech recognition returned an empty transcript.") }
            if generatedFixture {
                let matches = ["Friday", "prototype", "checklist", "Monday"].filter { transcript.localizedCaseInsensitiveContains($0) }
                guard matches.count >= 3 else { throw SmokeFailure("The synthetic fixture was not recognized accurately enough: \(transcript)") }
            }
            report.transcript = transcript
            report.duration = speech.duration
            report.recognizedSegments = speech.segments.count
            if !speakerModel.isEmpty {
                let speakerStarted = Date()
                var speakers = try await runtime.diarize(url: audio, model: ModelReference(speakerModel), options: speakerOptions, progress: progress)
                report.speakerSeconds = Date().timeIntervalSince(speakerStarted)
                guard !speakers.turns.isEmpty else { throw SmokeFailure("Speaker detection returned no speech turns.") }
                if !ModelRouting.supportsVoiceMatching(speakerModel, catalog: catalog) {
                    let installedNow = await runtime.installedModels()
                    let routed = ModelRouting.voiceEmbedder(diarizer: speakerModel,
                                                            selections: ModelRouting.withDefaultVoiceEmbedder(initial, catalog: catalog, engines: runtime.engines),
                                                            catalog: catalog, engines: runtime.engines)
                    if let embedder = voiceModel ?? routed.flatMap({ installedNow.contains($0) ? $0 : nil }) {
                        speakers = try await runtime.embedVoices(url: audio, analysis: speakers, model: ModelReference(embedder), progress: progress)
                        report.voiceModel = embedder
                        guard speakers.embeddingModelID != nil, !speakers.embeddings.isEmpty,
                              speakers.embeddings.values.allSatisfy({ $0.count == 256 && $0.allSatisfy(\.isFinite) }) else {
                            throw SmokeFailure("The voice-profile model did not return usable local voice embeddings.")
                        }
                    } else if let routed {
                        report.warnings.append("Voice profiles not checked: \(routed) isn’t installed.")
                    }
                }
                if ModelRouting.supportsVoiceMatching(speakerModel, catalog: catalog) {
                    guard speakers.embeddingModelID != nil, !speakers.embeddings.isEmpty,
                          speakers.embeddings.values.allSatisfy({ $0.count == 256 && $0.allSatisfy(\.isFinite) }) else {
                        throw SmokeFailure("The speaker model did not return usable local voice embeddings.")
                    }
                }
                report.speakerCount = Set(speakers.turns.map(\.speakerID)).count
                report.speakerTurns = speakers.turns.count
                report.embeddingCount = speakers.embeddings.count
                report.embeddingModelID = speakers.embeddingModelID
                report.warnings += speakers.warnings
                report.speakerTurnsDetail = speakers.turns.map { "\($0.speakerID) \(String(format: "%.2f–%.2f", $0.start, $0.end))" }
            }
            if skipSummary {
                report.success = true
                report.message = speakerModel.isEmpty ? "Embedded transcription passed (summary skipped)."
                    : "Embedded transcription and speaker detection passed (summary skipped)."
                try await runtime.unload()
                report.elapsedSeconds = Date().timeIntervalSince(started)
                return write(report, to: output)
            }
            let notesHighlights = arguments.contains("--notes-highlights") && generatedFixture
            let notes = generatedFixture ? (notesHighlights
                ? "[00:10] USER NOTE, NOT SPOKEN: I want extra detail about the speaker-detection blocker. Focus on the Friday prototype milestone and Alex's onboarding checklist."
                : "Focus on the Friday prototype milestone and Alex's onboarding checklist.") : ""
            let selectedTemplate = notesHighlights ? SummaryTemplate.builtIns.first(where: { $0.id == "planning" }) : nil
            let templateInstructions = selectedTemplate?.instructions
            let highlightEvidence = notesHighlights
                ? "Highlighted recorded passage: Our main blocker is testing speaker detection. We will review the results next Monday."
                : nil
            let generated = try await runtime.summarize(transcript: transcript, notes: notes, template: selectedTemplate?.kind ?? .auto,
                                                       glossary: ["Daybook"], model: ModelReference(summaryModel),
                                                       templateInstructions: templateInstructions, highlightEvidence: highlightEvidence,
                                                       progress: progress)
            report.summary = generated.summary
            report.summaryModel = summaryModel
            report.summaryProvenance = generated.provenance
            report.summaryStatistics = generated.statistics
            report.warnings += generated.warnings
            report.rawSummary = generated.rawResponse
            // Titles and vocabulary from the system model, when this Mac has it; reported, never required.
            if let smallTasksModel, await runtime.installedModels().contains(smallTasksModel) {
                let begun = Date()
                if let small = try? await runtime.performSmallTasks(transcript: transcript, notes: notes, glossary: ["Daybook"],
                                                                     model: ModelReference(smallTasksModel)) {
                    report.smallTasks = SmokeSmallTasks(model: smallTasksModel, title: small.title, kind: small.kind?.rawValue,
                                                        terms: small.suggestedTerms, seconds: Date().timeIntervalSince(begun),
                                                        engineVersion: small.provenance?.engineVersion)
                }
            }
            guard !generated.summary.title.isEmpty, generated.summary.overview.count > 20,
                  !generated.summary.sections.isEmpty else {
                throw SmokeFailure("The language model did not return a coherent structured summary. See rawSummary in the report.")
            }
            if generatedFixture {
                let summaryText = generated.summary.overview + " " + generated.summary.sections.map(\.body).joined(separator: " ")
                guard summaryText.localizedCaseInsensitiveContains("prototype") || summaryText.localizedCaseInsensitiveContains("Friday") else {
                    throw SmokeFailure("The generated summary omitted the fixture's main milestone.")
                }
                guard generated.summary.actionItems.contains(where: {
                    $0.text.localizedCaseInsensitiveContains("checklist") && $0.owner?.localizedCaseInsensitiveContains("Alex") == true
                }) else {
                    throw SmokeFailure("The generated actions omitted Alex's explicitly assigned onboarding checklist.")
                }
                if notesHighlights {
                    guard summaryText.localizedCaseInsensitiveContains("speaker"),
                          summaryText.localizedCaseInsensitiveContains("test"),
                          summaryText.localizedCaseInsensitiveContains("block") || summaryText.localizedCaseInsensitiveContains("risk") else {
                        throw SmokeFailure("The highlighted speaker-detection blocker was omitted from the generated summary.")
                    }
                    guard !summaryText.localizedCaseInsensitiveContains("I want extra detail") else {
                        throw SmokeFailure("The private note instruction was repeated as conversation content.")
                    }
                }
            }
            report.success = true
            report.message = "Embedded transcription, speaker detection, and structured summarization passed."
            try await runtime.unload()
        } catch {
            report.message = error.localizedDescription
        }
        report.elapsedSeconds = Date().timeIntervalSince(started)
        return write(report, to: output)
    }

    private static func write(_ report: SmokeReport, to output: URL?) -> Int32 {
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            if let output {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
                print("Report: \(output.path)")
            }
            print(String(decoding: data, as: UTF8.self))
        } catch {
            print("Could not write smoke-test report: \(error.localizedDescription)")
            return 1
        }
        return report.success ? 0 : 1
    }
}

private struct SmokeFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct SmokeReport: Codable {
    let started: Date
    var success = false
    var message = ""
    var elapsedSeconds: Double = 0
    var duration: Double?
    var transcript: String?
    var recognizedSegments: Int?
    var speakerTurns: Int?
    var speakerCount: Int?
    var speakerModel: String?
    var speakerQuality: String?
    var transcriptionModel: String?
    var language: String?
    /// Timed words and their mean confidence: word timestamps and confidences are on.
    var recognizedWords: Int?
    var meanWordConfidence: Double?
    /// Transcription, including loading the speech model.
    var transcriptionSeconds: Double?
    var speakerSeconds: Double?
    var voiceModel: String?
    var speakerTurnsDetail: [String]?
    var embeddingCount: Int?
    var embeddingModelID: String?
    var summary: MeetingSummary?
    var rawSummary: String?
    var warnings: [String] = []
    var summaryModel: String?
    var summaryProvenance: ModelProvenance?
    /// The language model's load time and token throughput.
    var summaryStatistics: GenerationStatistics?
    var smallTasks: SmokeSmallTasks?
}

private struct SmokeSmallTasks: Codable {
    var model: String
    var title: String?
    var kind: String?
    var terms: [String]
    var seconds: Double
    var engineVersion: String?
}
