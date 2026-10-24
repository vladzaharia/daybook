import DaybookCore
import DaybookIntelligence
import DaybookKit
import Foundation

/// `Daybook --evaluate <folder>`: runs the current speech pipeline (language routing, transcription,
/// speaker detection, voice profiles, and fusion, exactly as processing runs them) over recordings
/// that have reference transcripts, and scores WER, CER, cpWER after fusion, DER/JER, and word-timing
/// error per model configuration. It never records, never touches a library, and downloads only with
/// `--download-models`. Folder format and flags: docs/validation.md, "Evaluating speech models".
@MainActor
enum SpeechEvaluation {
    static let audioExtensions: Set<String> = ["wav", "m4a", "caf", "aiff", "aif", "mp3", "flac", "mp4"]

    static func run(arguments: [String]) async -> Int32 {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        func list(_ flag: String) -> [String] {
            value(flag)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        }
        guard let folderPath = value("--evaluate") else {
            print("Usage: Daybook --evaluate <folder> [--output <json>] [--models <dir>] [--presets quick,balanced,detailed] "
                  + "[--transcription-model a,b] [--speaker-model a,b] [--language <code>] [--other-languages <model>] "
                  + "[--collar <seconds>] [--no-speakers] [--download-models]")
            return 2
        }
        let folder = URL(fileURLWithPath: (folderPath as NSString).expandingTildeInPath, isDirectory: true)
        let output = value("--output").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let models = value("--models").map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
            ?? AppState.libraryURL.appendingPathComponent("Models", isDirectory: true)
        let collar = value("--collar").flatMap(Double.init) ?? 0
        let detectSpeakers = !arguments.contains("--no-speakers")
        let language = TranscriptionLanguages.normalize(value("--language"))

        let runtime = LocalIntelligenceRuntime(modelsDirectory: models)
        await runtime.prepare()
        let catalog = await runtime.catalog
        let recordings = Self.recordings(in: folder)
        var report = EvaluationReport(folder: folder.path, collar: collar, language: language ?? "automatic",
                                      recordings: recordings.map(\.name), skippedRecordings: Self.skipped(in: folder, found: recordings))
        guard !recordings.isEmpty else {
            report.message = "No recordings with a reference transcript in \(folder.path)."
            return finish(report, output: output, success: false)
        }

        let configurations = Self.configurations(arguments: list, catalog: catalog, runtime: runtime)
        for var configuration in configurations {
            let installed = await runtime.installedModels()
            var needed = [configuration.transcription.model] + (detectSpeakers ? [configuration.speakerModel] : [])
            if arguments.contains("--download-models") {
                needed += [configuration.transcription.fallback, detectSpeakers ? configuration.voiceModel : nil].compactMap { $0 }
                for id in needed where !installed.contains(id) {
                    do { try await runtime.download(modelID: id) { print(String(format: "[%3.0f%%] %@", $0.fraction * 100, $0.message)) } }
                    catch { configuration.skipped = "Couldn’t download \(id): \(error.localizedDescription)" }
                }
            }
            let available = await runtime.installedModels()
            if configuration.skipped == nil, let missing = needed.first(where: { !available.contains($0) }) {
                configuration.skipped = "\(missing) isn’t installed. Run with --download-models to fetch it."
            }
            // Optional models, as in the app: without the other-languages model the language check
            // still runs and reports, but transcripts stay with the first model. Voice profiles need theirs.
            if let fallback = configuration.transcription.fallback, !available.contains(fallback) {
                configuration.notes.append("Other languages stay with the first model: \(fallback) isn’t installed.")
            }
            if let voice = configuration.voiceModel, !available.contains(voice) {
                configuration.notes.append("Voice profiles off: \(voice) isn’t installed.")
                configuration.voiceModel = nil
            }
            var result = ConfigurationResult(configuration)
            if configuration.skipped == nil {
                print("Evaluating \(configuration.name)…")
                for recording in recordings {
                    do {
                        result.add(try await evaluate(recording, configuration: configuration, detectSpeakers: detectSpeakers,
                                                      collar: collar, runtime: runtime))
                    } catch {
                        result.failures.append("\(recording.name): \(error.localizedDescription)")
                    }
                }
            }
            report.configurations.append(result)
        }
        try? await runtime.unload()
        report.message = "Evaluated \(recordings.count) recording(s) with \(report.configurations.filter { $0.configuration.skipped == nil }.count) configuration(s)."
        return finish(report, output: output, success: report.configurations.contains { $0.configuration.skipped == nil && !$0.recordings.isEmpty })
    }

    // MARK: Recordings

    struct Recording {
        var name: String
        var tracks: [URL]
        var text: String?
        var stm: [EvaluationReference.Segment]?
        var rttm: [SpeakerSpan]?
        var ctm: [TimedWord]?

        /// The reference text: the .txt file, else the STM's words in time order, else the CTM's.
        var referenceText: String? {
            text ?? stm.map { $0.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ") }
                ?? ctm.map { $0.map(\.text).joined(separator: " ") }
        }
    }

    /// Top-level audio files, and folders of audio files recorded together, that have a reference.
    static func recordings(in folder: URL) -> [Recording] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                        options: [.skipsHiddenFiles]) else { return [] }
        var result: [Recording] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            var recording: Recording
            if isDirectory {
                let inside = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let tracks = inside.filter { audioExtensions.contains($0.pathExtension.lowercased()) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
                guard !tracks.isEmpty else { continue }
                recording = Recording(name: entry.lastPathComponent, tracks: tracks)
                for base in ["reference", entry.lastPathComponent] { load(&recording, base: entry.appendingPathComponent(base)) }
            } else {
                guard audioExtensions.contains(entry.pathExtension.lowercased()) else { continue }
                recording = Recording(name: entry.deletingPathExtension().lastPathComponent, tracks: [entry])
                load(&recording, base: entry.deletingPathExtension())
            }
            if recording.referenceText != nil { result.append(recording) }
        }
        return result
    }

    private static func load(_ recording: inout Recording, base: URL) {
        func read(_ ext: String) -> String? { try? String(contentsOf: base.appendingPathExtension(ext), encoding: .utf8) }
        recording.text = recording.text ?? read("txt")
        recording.stm = recording.stm ?? read("stm").map(EvaluationReference.parseSTM)
        recording.rttm = recording.rttm ?? read("rttm").map(EvaluationReference.parseRTTM)
        recording.ctm = recording.ctm ?? read("ctm").map(EvaluationReference.parseCTM)
    }

    private static func skipped(in folder: URL, found: [Recording]) -> [String] {
        let names = Set(found.map(\.name))
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries.filter { audioExtensions.contains($0.pathExtension.lowercased()) && !names.contains($0.deletingPathExtension().lastPathComponent) }
            .map { "\($0.lastPathComponent): no reference transcript" }.sorted()
    }

    // MARK: Configurations

    struct Configuration: Codable {
        var name: String
        var transcription: TranscriptionRoute
        var speakerModel: String
        var voiceModel: String?
        var speakerQuality: SpeakerQuality
        var skipped: String?
        var notes: [String] = []
    }

    /// Presets (`--presets`), explicit models (`--transcription-model` × `--speaker-model`), or the
    /// first-launch selection.
    static func configurations(arguments list: (String) -> [String], catalog: ModelCatalog,
                               runtime: LocalIntelligenceRuntime) -> [Configuration] {
        let engines = runtime.engines
        let language = TranscriptionLanguages.normalize(list("--language").first)
        let otherChoice = list("--other-languages").first
        func make(name: String, selections: ModelSelections, quality: SpeakerQuality) -> Configuration {
            let transcription = selections[.transcription] ?? ""
            let other = TranscriptionRouting.otherLanguagesModel(selected: transcription, chosen: otherChoice, catalog: catalog, engines: engines)
            let route = TranscriptionRouting.route(selected: transcription, language: language, otherLanguages: other, catalog: catalog)
            let speaker = selections[.diarization] ?? ""
            let voice = ModelRouting.voiceEmbedder(diarizer: speaker,
                                                   selections: ModelRouting.withDefaultVoiceEmbedder(selections, catalog: catalog, engines: engines),
                                                   catalog: catalog, engines: engines)
            return Configuration(name: name, transcription: route, speakerModel: speaker, voiceModel: voice, speakerQuality: quality)
        }
        var result: [Configuration] = []
        for preset in list("--presets") {
            guard let quality = ModelQuality(rawValue: preset) else { continue }
            let models = ModelRecommendations.preset(quality, catalog: catalog, engines: engines)
            result.append(make(name: preset, selections: models.selections,
                               quality: models.speakerQuality.flatMap(SpeakerQuality.init(rawValue:)) ?? .balanced))
        }
        let initial = ModelRecommendations.initialSelections(catalog: catalog, engines: engines)
        let transcriptionModels = list("--transcription-model").map { catalog.model($0)?.key ?? $0 }
        let speakerModels = list("--speaker-model").map { catalog.model($0)?.key ?? $0 }
        if !transcriptionModels.isEmpty || !speakerModels.isEmpty {
            for transcription in transcriptionModels.isEmpty ? [initial[.transcription] ?? ""] : transcriptionModels {
                for speaker in speakerModels.isEmpty ? [initial[.diarization] ?? ""] : speakerModels {
                    var selections = initial
                    selections[.transcription] = transcription
                    selections[.diarization] = speaker
                    result.append(make(name: "\(transcription) + \(speaker)", selections: selections, quality: .balanced))
                }
            }
        }
        if result.isEmpty { result.append(make(name: "initial selection", selections: initial, quality: .balanced)) }
        return result
    }

    // MARK: Running and scoring

    static func evaluate(_ recording: Recording, configuration: Configuration, detectSpeakers: Bool, collar: Double,
                         runtime: LocalIntelligenceRuntime) async throws -> RecordingResult {
        let inference = RecordingInference(runtime)
        let engine = InferenceProcessingEngine(inference: inference, configuration: .init(
            transcriptionModel: ModelReference(configuration.transcription.model), summaryModel: "unused", detectSpeakers: detectSpeakers,
            speakerModel: ModelReference(configuration.speakerModel), voiceEmbeddingModel: configuration.voiceModel.map { ModelReference($0) },
            speakerOptions: SpeakerAnalysisOptions(quality: configuration.speakerQuality), fingerprint: "evaluation",
            speakerMatchThreshold: 0.82, speakerMatchMargin: 0.06,
            transcriptionLanguage: configuration.transcription.language,
            languageFallbackModel: configuration.transcription.fallback.map { ModelReference($0) }))
        let meetingID = UUID()
        var outputs: [TrackProcessingOutput] = []
        var tracks: [RecordingTrack] = []
        var analyses: [SpeakerAnalysis] = []
        var duration = 0.0
        let started = Date()
        for url in recording.tracks {
            // Tracks in one folder were recorded together: same start, no offset to find.
            let track = RecordingTrack(source: .imported, relativePath: url.lastPathComponent, fileName: url.lastPathComponent, offset: 0)
            let output = try await engine.transcribe(TrackProcessingInput(meetingID: meetingID, track: track, audioURL: url, mode: .newAudio),
                                                     progress: { _ in })
            outputs.append(output); tracks.append(track)
            analyses += inference.takeAnalyses()
            duration = max(duration, output.duration)
        }
        let seconds = Date().timeIntervalSince(started)
        let fused = TranscriptFusion.fuse(outputs.map(\.transcript), tracks: tracks).segments.sorted { $0.start < $1.start }
        let hypothesis = fused.map(\.text).joined(separator: " ")
        let reference = recording.referenceText ?? ""

        var result = RecordingResult(name: recording.name, tracks: recording.tracks.count, audioSeconds: duration, processingSeconds: seconds)
        result.transcriptModels = outputs.map(\.transcript.modelID)
        result.languages = outputs.map { $0.transcript.language ?? "" }
        result.routing = outputs.map { ($0.transcript.processingSettings?.parameters ?? [:]).filter { ["language", "languageCheck", "detectedLanguage", "routedFrom"].contains($0.key) } }
        result.notices = outputs.flatMap(\.notices)
        result.hypothesis = hypothesis
        result.wer = WordErrorRate.counts(reference: reference, hypothesis: hypothesis)
        result.cer = WordErrorRate.characterCounts(reference: reference, hypothesis: hypothesis)
        if let stm = recording.stm, detectSpeakers {
            result.cpwer = ConcatenatedPermutationWER.score(
                reference: stm.sorted { $0.start < $1.start }.map { SpeakerText(speaker: $0.speaker, text: $0.text) },
                hypothesis: fused.map { SpeakerText(speaker: $0.speakerID ?? "unlabelled", text: $0.text) }).counts
        }
        if let rttm = recording.rttm, detectSpeakers {
            // One track: the speaker model's own turns. Several: speakers as the fused transcript has them.
            let spans: [SpeakerSpan] = tracks.count == 1
                ? analyses.flatMap { $0.turns.map { SpeakerSpan(speaker: $0.speakerID, start: $0.start, end: $0.end) } }
                : fused.compactMap { segment in segment.speakerID.map { SpeakerSpan(speaker: $0, start: segment.start, end: segment.end) } }
            let der = DiarizationErrorRate.score(reference: rttm, hypothesis: spans, collar: collar)
            result.der = der
            result.hypothesisRTTM = EvaluationReference.rttm(spans, file: recording.name)
        }
        if let ctm = recording.ctm, let words = outputs.first?.transcript.words {
            result.wordTiming = WordTimingError.measure(reference: ctm, hypothesis: words.map { TimedWord(text: $0.text, start: $0.start, end: $0.end) })
        }
        result.voiceProfiles = outputs.reduce(0) { $0 + $1.speakers.filter { $0.embedding != nil }.count }
        return result
    }

    // MARK: Report

    struct RecordingResult: Codable {
        var name: String
        var tracks: Int
        var audioSeconds: Double
        /// Wall time for the whole pipeline, model loading included on a configuration's first recording.
        var processingSeconds: Double
        var transcriptModels: [String] = []
        var languages: [String] = []
        var routing: [[String: String]] = []
        var wer: ErrorCounts?
        var cer: ErrorCounts?
        var cpwer: ErrorCounts?
        var der: DiarizationErrorRate.Result?
        var wordTiming: WordTimingError.Result?
        var voiceProfiles = 0
        var notices: [String] = []
        var hypothesis = ""
        var hypothesisRTTM: String?

        var werRate: Double? { wer?.rate }
    }

    struct ConfigurationResult: Codable {
        var configuration: Configuration
        var recordings: [RecordingResult] = []
        var failures: [String] = []
        var totals = Totals()

        struct Totals: Codable {
            var audioSeconds = 0.0
            var processingSeconds = 0.0
            var realTimeFactor: Double?
            var wer: Double?
            var cer: Double?
            var cpwer: Double?
            var der: Double?
            var jer: Double?
            var meanWordStartError: Double?
            var werCounts = ErrorCounts()
            var cerCounts = ErrorCounts()
            var cpwerCounts = ErrorCounts()
            var derReferenceSeconds = 0.0
            var derErrorSeconds = 0.0
        }

        init(_ configuration: Configuration) { self.configuration = configuration }

        /// Pooled over recordings: error counts and seconds add up before dividing.
        mutating func add(_ recording: RecordingResult) {
            recordings.append(recording)
            totals.audioSeconds += recording.audioSeconds
            totals.processingSeconds += recording.processingSeconds
            totals.realTimeFactor = totals.processingSeconds > 0 ? totals.audioSeconds / totals.processingSeconds : nil
            if let wer = recording.wer { totals.werCounts = totals.werCounts + wer }
            if let cer = recording.cer { totals.cerCounts = totals.cerCounts + cer }
            if let cpwer = recording.cpwer { totals.cpwerCounts = totals.cpwerCounts + cpwer }
            if let der = recording.der { totals.derReferenceSeconds += der.referenceSeconds; totals.derErrorSeconds += der.errorSeconds }
            totals.wer = totals.werCounts.rate
            totals.cer = totals.cerCounts.rate
            totals.cpwer = recordings.contains { $0.cpwer != nil } ? totals.cpwerCounts.rate : nil
            totals.der = totals.derReferenceSeconds > 0 ? totals.derErrorSeconds / totals.derReferenceSeconds : nil
            let jers = recordings.compactMap { $0.der?.jaccardErrorRate }
            totals.jer = jers.isEmpty ? nil : jers.reduce(0, +) / Double(jers.count)
            let timed = recordings.compactMap(\.wordTiming).filter { $0.matchedWords > 0 }
            let matched = timed.reduce(0) { $0 + $1.matchedWords }
            totals.meanWordStartError = matched == 0 ? nil
                : timed.reduce(0) { $0 + ($1.meanStartError ?? 0) * Double($1.matchedWords) } / Double(matched)
        }
    }

    struct EvaluationReport: Codable {
        var started = Date()
        var folder: String
        var collar: Double
        var language: String
        var recordings: [String]
        var skippedRecordings: [String]
        var configurations: [ConfigurationResult] = []
        var message = ""
    }

    private static func finish(_ report: EvaluationReport, output: URL?, success: Bool) -> Int32 {
        for result in report.configurations {
            let totals = result.totals
            func percent(_ value: Double?) -> String { value.map { String(format: "%.2f%%", $0 * 100) } ?? "–" }
            print("\(result.configuration.name): " + (result.configuration.skipped ?? [
                "WER \(percent(totals.wer))", "CER \(percent(totals.cer))", "cpWER \(percent(totals.cpwer))",
                "DER \(percent(totals.der))", "JER \(percent(totals.jer))",
                "speed \(totals.realTimeFactor.map { String(format: "%.1f×", $0) } ?? "–")"].joined(separator: " · ")))
        }
        print(report.message)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(report)
            if let output {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: output, options: .atomic)
                print("Report: \(output.path)")
            }
        } catch {
            print("Could not write the evaluation report: \(error.localizedDescription)")
            return 1
        }
        return success ? 0 : 1
    }
}

/// The runtime, recording each speaker analysis (after voice profiles) so DER scores the speaker
/// model's own turns.
final class RecordingInference: MeetingInference, @unchecked Sendable {
    let base: LocalIntelligenceRuntime
    private let lock = NSLock()
    private var analyses: [SpeakerAnalysis] = []

    init(_ base: LocalIntelligenceRuntime) { self.base = base }

    func takeAnalyses() -> [SpeakerAnalysis] { lock.withLock { defer { analyses = [] }; return analyses } }

    func transcribe(url: URL, model: ModelReference, glossary: [String], progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        try await base.transcribe(url: url, model: model, glossary: glossary, progress: progress)
    }

    func transcribe(url: URL, model: ModelReference, glossary: [String], language: String?,
                    progress: @escaping IntelligenceProgressHandler) async throws -> RecognitionResult {
        try await base.transcribe(url: url, model: model, glossary: glossary, language: language, progress: progress)
    }

    func capabilities(of model: ModelReference) async -> ModelCapabilities? { await base.capabilities(of: model) }

    func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions,
                 progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
        let analysis = try await base.diarize(url: url, model: model, options: options, progress: progress)
        lock.withLock { analyses.append(analysis) }
        return analysis
    }

    func embedVoices(url: URL, analysis: SpeakerAnalysis, model: ModelReference,
                     progress: @escaping IntelligenceProgressHandler) async throws -> SpeakerAnalysis {
        try await base.embedVoices(url: url, analysis: analysis, model: model, progress: progress)
    }

    func summarize(transcript: String, notes: String, template: MeetingKind, glossary: [String], model: ModelReference,
                   templateInstructions: String?, highlightEvidence: String?,
                   progress: @escaping IntelligenceProgressHandler) async throws -> GeneratedMeetingNotes {
        try await base.summarize(transcript: transcript, notes: notes, template: template, glossary: glossary, model: model,
                                 templateInstructions: templateInstructions, highlightEvidence: highlightEvidence, progress: progress)
    }
}
