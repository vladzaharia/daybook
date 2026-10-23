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
        let summaryModel = value("--summary-model") ?? DaybookModelCatalog.defaultSummarization
        let speakerModel = value("--speaker-model") ?? DaybookModelCatalog.diarization
        let speakerQuality = SpeakerQuality(rawValue: value("--speaker-quality") ?? "balanced") ?? .balanced
        let speakerOptions = SpeakerAnalysisOptions(quality: speakerQuality,
                                                    expectedSpeakerCount: value("--expected-speakers").flatMap(Int.init))
        report.speakerModel = speakerModel
        report.speakerQuality = speakerQuality.rawValue
        let runtime = LocalIntelligenceRuntime(modelsDirectory: models)
        let progress: IntelligenceProgressHandler = { update in
            print(String(format: "[%3.0f%%] %@", update.fraction * 100, update.message))
        }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let identifiers = [DaybookModelCatalog.defaultTranscription, summaryModel,
                               speakerModel]
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
            let speech = try await runtime.transcribe(url: audio, modelID: DaybookModelCatalog.defaultTranscription,
                                                     glossary: ["Daybook"], progress: progress)
            let transcript = speech.segments.map { String(format: "[%.1fs] %@", $0.start, $0.text) }.joined(separator: "\n")
            guard !speech.segments.isEmpty, transcript.count > 20 else { throw SmokeFailure("Speech recognition returned an empty transcript.") }
            if generatedFixture {
                let matches = ["Friday", "prototype", "checklist", "Monday"].filter { transcript.localizedCaseInsensitiveContains($0) }
                guard matches.count >= 3 else { throw SmokeFailure("The synthetic fixture was not recognized accurately enough: \(transcript)") }
            }
            report.transcript = transcript
            report.duration = speech.duration
            report.recognizedSegments = speech.segments.count
            let speakers = try await runtime.diarize(url: audio, modelID: speakerModel, options: speakerOptions, progress: progress)
            guard !speakers.turns.isEmpty else { throw SmokeFailure("Speaker detection returned no speech turns.") }
            if DaybookModelCatalog.supportsVoiceMatching(speakerModel) {
                guard speakers.embeddingModelID != nil, !speakers.embeddings.isEmpty,
                      speakers.embeddings.values.allSatisfy({ $0.count == 256 && $0.allSatisfy(\.isFinite) }) else {
                    throw SmokeFailure("The speaker model did not return usable local voice embeddings.")
                }
            }
            report.speakerCount = Set(speakers.turns.map(\.speakerID)).count
            report.speakerTurns = speakers.turns.count
            report.embeddingCount = speakers.embeddings.count
            report.embeddingModelID = speakers.embeddingModelID
            report.warnings = speakers.warnings
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
                                                       glossary: ["Daybook"], modelID: summaryModel,
                                                       templateInstructions: templateInstructions, highlightEvidence: highlightEvidence,
                                                       progress: progress)
            report.summary = generated.summary
            report.warnings += generated.warnings
            report.rawSummary = generated.rawResponse
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
    var embeddingCount: Int?
    var embeddingModelID: String?
    var summary: MeetingSummary?
    var rawSummary: String?
    var warnings: [String] = []
}
