import DaybookCore
import DaybookKit
import Foundation

/// The Mac's `ProcessingEngine`: local models through `MeetingInference` (`LocalIntelligenceRuntime`,
/// or a fake in tests). It transcribes with the chosen speech model, identifies speakers when asked,
/// and summarizes with the chosen language model, recording on every run exactly which model
/// (family, variant, revision, engine version) produced it. When a small-tasks model is selected
/// (Apple Foundation Models), it chooses the title, the meeting kind, and vocabulary suggestions
/// first; when it isn't, or can't run, the summarizer does that as it always has.
public struct InferenceProcessingEngine: ProcessingEngine {
    /// The models and options one job runs with, fixed when it was queued.
    public struct Configuration: Sendable {
        public var transcriptionModel: ModelReference
        public var summaryModel: ModelReference
        public var detectSpeakers: Bool
        public var speakerModel: ModelReference
        /// Computes voice profiles when the speaker model doesn't (`ModelRouting.voiceEmbedder`); nil otherwise.
        public var voiceEmbeddingModel: ModelReference?
        /// Titles, the meeting kind, and vocabulary suggestions (`ModelSelections[.smallTasks]`), when
        /// one is selected and available; nil leaves them to the summarizer.
        public var smallTasksModel: ModelReference?
        public var speakerOptions: SpeakerAnalysisOptions
        /// Identifies equivalent settings across runs (`ProcessingSettings` "configuration").
        public var fingerprint: String
        public var speakerMatchThreshold: Double
        public var speakerMatchMargin: Double
        /// The chosen transcription language (a BCP-47 code); nil for Automatic (`TranscriptionRoute`).
        public var transcriptionLanguage: String?
        /// Automatic only: transcribes instead when the first transcript is in a language
        /// `transcriptionModel` doesn't cover (`TranscriptionRouter`).
        public var languageFallbackModel: ModelReference?
        /// Writes photo captions (`ModelSelections[.imageDescription]`) when it isn't Apple Vision, which
        /// reads every photo's text, sharpness, and near copies either way. Nil leaves captions to Vision.
        public var photoModel: ModelReference?

        public init(transcriptionModel: ModelReference, summaryModel: ModelReference, detectSpeakers: Bool, speakerModel: ModelReference,
                    voiceEmbeddingModel: ModelReference? = nil, smallTasksModel: ModelReference? = nil,
                    speakerOptions: SpeakerAnalysisOptions, fingerprint: String,
                    speakerMatchThreshold: Double, speakerMatchMargin: Double,
                    transcriptionLanguage: String? = nil, languageFallbackModel: ModelReference? = nil,
                    photoModel: ModelReference? = nil) {
            self.transcriptionModel = transcriptionModel; self.summaryModel = summaryModel; self.detectSpeakers = detectSpeakers
            self.speakerModel = speakerModel; self.voiceEmbeddingModel = voiceEmbeddingModel; self.smallTasksModel = smallTasksModel
            self.speakerOptions = speakerOptions
            self.fingerprint = fingerprint; self.speakerMatchThreshold = speakerMatchThreshold; self.speakerMatchMargin = speakerMatchMargin
            self.transcriptionLanguage = transcriptionLanguage; self.languageFallbackModel = languageFallbackModel
            self.photoModel = photoModel
        }

        /// What a transcript run records about how it was made.
        func parameters(mode: ProcessingRequest.Mode) -> [String: String] {
            var values = ["mode": mode.rawValue, "configuration": fingerprint,
                          "speakerModel": detectSpeakers ? speakerModel.id : "disabled",
                          "speakerQuality": speakerOptions.quality.rawValue,
                          "matchThreshold": String(speakerMatchThreshold), "matchMargin": String(speakerMatchMargin)]
            if detectSpeakers, let embedder = voiceEmbeddingModel { values["voiceEmbeddingModel"] = embedder.id }
            return values
        }
    }

    public let inference: any MeetingInference
    public let configuration: Configuration

    public init(inference: any MeetingInference, configuration: Configuration) {
        self.inference = inference
        self.configuration = configuration
    }

    public func transcribe(_ input: TrackProcessingInput, progress: @escaping ProcessingProgressHandler) async throws -> TrackProcessingOutput {
        let report: IntelligenceProgressHandler = { progress(ProcessingProgress(fraction: $0.fraction, message: $0.message)) }
        let result: RecognitionResult
        var transcriptModel = configuration.transcriptionModel.id
        var transcriptProvenance: ModelProvenance?
        var notices: [String] = []
        var routing: [String: String] = [:]
        if input.mode == .speakerRefresh, let previous = input.previousTranscript {
            // Speakers again from the saved transcript: its words, or its passages for older runs.
            transcriptModel = previous.modelID
            transcriptProvenance = previous.processingSettings?.model
            if let words = previous.words, !words.isEmpty {
                let restored = words.map { RecognizedWord(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence ?? 1) }
                result = RecognitionResult(segments: [.init(start: restored.first!.start, end: restored.last!.end,
                    text: restored.map(\.text).joined(), confidence: 1, words: restored)], language: previous.language,
                    duration: input.track.duration ?? restored.last!.end)
            } else {
                result = RecognitionResult(segments: previous.segments.map { .init(start: $0.start, end: $0.end, text: $0.text, confidence: $0.confidence ?? 1, words: []) },
                    language: previous.language, duration: input.track.duration ?? previous.segments.last?.end ?? 0)
                notices.append("This older transcript has no saved word timings. Speaker labels use passage boundaries; re-transcribe for finer speaker changes.")
            }
        } else {
            // Language routing: the model that actually transcribed is the one recorded.
            let routed = try await TranscriptionRouter(inference: inference, model: configuration.transcriptionModel,
                                                       language: configuration.transcriptionLanguage,
                                                       fallback: configuration.languageFallbackModel)
                .run(url: input.audioURL, glossary: input.vocabulary, progress: report)
            result = routed.result
            transcriptModel = routed.model.id
            transcriptProvenance = result.provenance
            routing = routed.parameters
            notices += routed.notices
        }
        var analysis: SpeakerAnalysis?
        if configuration.detectSpeakers {
            do {
                analysis = try await inference.diarize(url: input.audioURL, model: configuration.speakerModel,
                                                       options: configuration.speakerOptions, progress: report)
            } catch is CancellationError { throw CancellationError() }
            catch {
                if input.mode == .speakerRefresh { throw error }
                notices.append("Transcription succeeded, but speaker detection failed for \(input.track.fileName): \(error.localizedDescription)")
            }
        }
        let background = try await backgroundAudio(input, progress: report)
        let runID = UUID()
        let segments = TranscriptBuilder.segments(result: result, speakers: analysis, track: input.track, runID: runID)
        // Music, a TV, or radio: its passages stay in the run (fusion leaves them out of the transcript),
        // and it's never evidence for anyone's voice profile.
        let verdict = BackgroundAudio.judge(segments, analysis: background)
        if configuration.detectSpeakers, let found = analysis, found.embeddingModelID == nil, let embedder = configuration.voiceEmbeddingModel {
            // Routing by capability: a diarizer without voice profiles gets them from the embedding model.
            do {
                let embedded = try await inference.embedVoices(url: input.audioURL, analysis: Self.withoutBackground(found, verdict: verdict,
                                                               segments: segments, runID: runID), model: embedder, progress: report)
                analysis = SpeakerAnalysis(turns: found.turns, embeddings: embedded.embeddings, embeddingModelID: embedded.embeddingModelID,
                                           warnings: embedded.warnings, provenance: embedded.provenance ?? found.provenance,
                                           embeddingProvenance: embedded.embeddingProvenance)
            }
            catch is CancellationError { throw CancellationError() }
            catch { notices.append("Speakers were found, but voice profiles couldn’t be made for \(input.track.fileName): \(error.localizedDescription)") }
        }
        if let warnings = analysis?.warnings, !warnings.isEmpty { notices.append(warnings.joined(separator: "\n")) }
        let settings = ProcessingSettings(modelID: transcriptModel,
                                          parameters: configuration.parameters(mode: input.mode).merging(routing) { $1 },
                                          model: transcriptProvenance)
        let speakers = Set(segments.compactMap(\.speakerID)).sorted().map { label in
            let cluster = String(label.dropFirst(runID.uuidString.count + 1))
            // A broadcast voice (a TV's presenter) gets no voice profile: it's no one in the conversation.
            let embedding = verdict.speakers[label] == nil ? analysis?.embeddings[cluster] : nil
            return Speaker(id: label, name: "", sourceTrackID: input.track.id, embedding: embedding,
                           embeddingModelID: analysis?.embeddingModelID,
                           analysisSettings: ProcessingSettings(modelID: configuration.speakerModel.id, parameters: settings.parameters,
                                                                model: analysis?.provenance))
        }
        let words = result.segments.flatMap(\.words).map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence) }
        let transcript = TrackTranscript(id: runID, trackID: input.track.id, segments: segments, language: result.language,
                                         modelID: transcriptModel, knownOffset: input.track.offset, processingSettings: settings,
                                         words: words.isEmpty ? nil : words)
        return TrackProcessingOutput(transcript: transcript, speakers: speakers, speakerEmbeddingModelID: analysis?.embeddingModelID,
                                     duration: result.duration, notices: notices, backgroundAudio: background)
    }

    /// What the sound classifier hears in the recording: the track's stored analysis when it's
    /// current (the audio hasn't changed), otherwise measured now. Nil when it can't run, so nothing
    /// is left out; that needs no notice.
    private func backgroundAudio(_ input: TrackProcessingInput, progress: @escaping IntelligenceProgressHandler) async throws -> BackgroundAudioAnalysis? {
        if let stored = input.track.backgroundAudio, stored.version == BackgroundAudioAnalysis.currentVersion { return stored }
        do { return try await inference.classifySound(url: input.audioURL, progress: progress) }
        catch is CancellationError { throw CancellationError() }
        catch { return nil }
    }

    /// Speaker turns without background audio, for voice profiles: a broadcast voice's turns, and
    /// turns at least half inside passages judged music or broadcast, are left out.
    static func withoutBackground(_ analysis: SpeakerAnalysis, verdict: BackgroundAudio.Verdict, segments: [TranscriptSegment],
                                  runID: UUID) -> SpeakerAnalysis {
        guard !verdict.isEmpty else { return analysis }
        let ranges = segments.filter { verdict.segments[$0.id] != nil }.map { ($0.start, $0.end) }
        let turns = analysis.turns.filter { turn in
            if verdict.speakers["\(runID.uuidString):\(turn.speakerID)"] != nil { return false }
            let length = turn.end - turn.start
            guard length > 0 else { return true }
            let covered = ranges.reduce(0.0) { $0 + max(0, min($1.1, turn.end) - max($1.0, turn.start)) }
            return covered < length / 2
        }
        return SpeakerAnalysis(turns: turns, embeddings: analysis.embeddings, embeddingModelID: analysis.embeddingModelID,
                               warnings: analysis.warnings, provenance: analysis.provenance, embeddingProvenance: analysis.embeddingProvenance)
    }

    public func summarize(_ meeting: Meeting, template: SummaryTemplate?, vocabulary: [String],
                          progress: @escaping ProcessingProgressHandler) async throws -> SummaryProcessingOutput {
        let transcript = MeetingEvidence.transcript(meeting)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DaybookError.noSpeech }
        let report: IntelligenceProgressHandler = { progress(ProcessingProgress(fraction: $0.fraction, message: $0.message)) }
        let notes = MeetingEvidence.notes(meeting)
        let requestedKind = template?.kind ?? meeting.kind
        let small = try await smallTasks(transcript: transcript, notes: notes, kind: requestedKind, vocabulary: vocabulary, progress: report)
        // The small-tasks model's kind guides the summary's sections, as a chosen kind would.
        let summaryKind = requestedKind == .auto ? (small?.kind ?? .auto) : requestedKind
        let photos = PhotoPlacement.candidates(in: meeting)
        let generated = try await inference.summarize(
            transcript: transcript, notes: notes, template: summaryKind,
            glossary: vocabulary, model: configuration.summaryModel, templateInstructions: template?.instructions,
            highlightEvidence: MeetingEvidence.highlights(meeting), photos: photos, progress: report)
        // The model's photo placements, kept only where valid, plus the time fallback (PhotoPlacement).
        var summary = PhotoPlacement.arrange(generated.summary, in: meeting)
        var parameters = ["configuration": configuration.fingerprint, "templateID": template?.id ?? "auto",
                          "templateInstructions": template?.instructions ?? "Automatic selection"]
        var suggestedTerms = generated.suggestedTerms
        if !photos.isEmpty { parameters["photos"] = String(photos.count) }
        if let small, let model = configuration.smallTasksModel {
            if let title = small.title { summary.title = title }
            if requestedKind == .auto, let kind = small.kind { summary.kind = kind }
            suggestedTerms = Self.merging(small.suggestedTerms, into: suggestedTerms)
            parameters["smallTasksModel"] = model.id
            if let provenance = small.provenance { parameters["smallTasksEngine"] = "\(provenance.engine) \(provenance.engineVersion)" }
        }
        summary.processingSettings = ProcessingSettings(modelID: configuration.summaryModel.id, parameters: parameters,
                                                        model: generated.provenance)
        return SummaryProcessingOutput(summary: summary, suggestedTerms: suggestedTerms, warnings: generated.warnings)
    }

    /// Reads photos with Apple Vision (text, labels, sharpness, near copies), then, when a caption model
    /// other than Vision is chosen, has it caption the informative ones. Photos analysed before are only
    /// compared for near copies. A photo that can't be read is a failure of its own (`failures`) while
    /// the others are read. A caption model that can't run leaves Vision's captions, with a notice, and
    /// is recorded on each analysis so it isn't tried again for those photos until it changes; photos
    /// never stop a summary.
    public func describePhotos(_ meeting: Meeting, photos: [PhotoProcessingInput],
                               progress: @escaping ProcessingProgressHandler) async throws -> PhotoProcessingOutput {
        let pending = photos.filter { Self.needsReading($0.photo, captionModel: configuration.photoModel) }
        guard !pending.isEmpty else { return PhotoProcessingOutput() }
        let report: IntelligenceProgressHandler = { progress(ProcessingProgress(fraction: $0.fraction, message: $0.message)) }
        let ordered = photos.sorted { $0.photo.capturedAt == $1.photo.capturedAt ? $0.photo.id.uuidString < $1.photo.id.uuidString : $0.photo.capturedAt < $1.photo.capturedAt }
        let pendingIDs = Set(pending.map(\.photo.id))
        let requests = ordered.map { ImageDescriptionRequest(url: $0.url, compareOnly: !pendingIDs.contains($0.photo.id)) }
        var notices: [String] = []
        let read: [ImageDescription]
        do { read = try await inference.describeImages(requests, model: PhotoReading.visionModel, progress: report) }
        catch is CancellationError { throw CancellationError() }
        catch LocalIntelligenceError.busy { throw LocalIntelligenceError.busy }
        catch {
            // Vision couldn't run at all: every photo waiting is a failure, tried again later.
            let failures = Dictionary(uniqueKeysWithValues: pending.map { ($0.photo.id, error.localizedDescription) })
            return PhotoProcessingOutput(notices: ["Photos couldn’t be read: \(error.localizedDescription)"], failures: failures)
        }
        guard read.count == ordered.count else { return PhotoProcessingOutput() }
        var failures: [UUID: String] = [:]
        for (index, input) in ordered.enumerated() where pendingIDs.contains(input.photo.id) {
            if let failure = read[index].failure { failures[input.photo.id] = failure }
        }
        if !failures.isEmpty {
            notices.append(failures.count == 1 ? "A photo couldn’t be read: \(failures.values.first!)" : "\(failures.count) photos couldn’t be read.")
        }
        let readable = pendingIDs.subtracting(failures.keys)
        var captions = read.map(\.caption)
        var captionModels = Array(repeating: PhotoReading.visionModel.id, count: read.count)
        var captionProvenance = read.map(\.provenance)
        var captionFailed: String?
        if let model = configuration.photoModel, model.id != PhotoReading.visionModel.id {
            let informative = ordered.indices.filter { readable.contains(ordered[$0].photo.id) && PhotoReading.isInformative(read[$0], caption: read[$0].caption) }
            if !informative.isEmpty {
                do {
                    let described = try await inference.describeImages(informative.map { ImageDescriptionRequest(url: ordered[$0].url, recognizedText: read[$0].recognizedText) },
                                                                       model: model, progress: report)
                    for (position, index) in informative.enumerated() where position < described.count {
                        if let caption = described[position].caption, !caption.isEmpty {
                            captions[index] = caption
                            captionModels[index] = model.id
                            captionProvenance[index] = described[position].provenance
                        }
                    }
                } catch is CancellationError { throw CancellationError() }
                catch LocalIntelligenceError.busy { throw LocalIntelligenceError.busy }
                catch {
                    notices.append("Photo captions use Apple Vision: \(error.localizedDescription)")
                    captionFailed = model.description
                }
            }
        }
        var analyses: [UUID: PhotoAnalysis] = [:]
        let now = Date()
        for (index, input) in ordered.enumerated() where readable.contains(input.photo.id) {
            let found = read[index]
            let duplicate = found.duplicateOf.flatMap { (0..<index).contains($0) ? ordered[$0].photo.id : nil }
            var parameters = ["textModel": PhotoReading.visionModel.id]
            if let vision = found.provenance { parameters["textEngine"] = "\(vision.engine) \(vision.engineVersion)" }
            if !PhotoReading.isInformative(found, caption: found.caption) {
                // A model change must not repeatedly process photos excluded from captioning.
                parameters["captionSkipped"] = "uninformative"
            } else if let captionFailed, captionModels[index] == PhotoReading.visionModel.id {
                // The chosen caption model failed for this photo: not tried again until it changes.
                parameters["captionFailed"] = captionFailed
            }
            let settings = ProcessingSettings(modelID: captionModels[index], parameters: parameters, createdAt: now, model: captionProvenance[index])
            analyses[input.photo.id] = PhotoAnalysis(caption: captions[index], recognizedText: found.recognizedText,
                                                     labels: found.labels.isEmpty ? nil : found.labels, sharpness: found.sharpness,
                                                     duplicateOf: duplicate,
                                                     isInformative: PhotoReading.isInformative(found, caption: captions[index]),
                                                     settings: settings, createdAt: now)
        }
        return PhotoProcessingOutput(analyses: analyses, notices: notices, failures: failures)
    }

    /// A photo is read when it has no analysis, or its caption came from another model than the one
    /// chosen now, unless that model (this revision of it) already failed to caption it.
    public static func needsReading(_ photo: MeetingPhoto, captionModel: ModelReference?) -> Bool {
        guard !photo.isRemoved else { return false }
        guard let analysis = photo.analysis else { return true }
        if analysis.settings?.parameters["captionSkipped"] == "uninformative" { return false }
        let wanted = captionModel?.id ?? PhotoReading.visionModel.id
        if analysis.settings?.modelID != wanted {
            if let captionModel, analysis.settings?.parameters["captionFailed"] == captionModel.description { return false }
            return true
        }
        if let revision = captionModel?.revision { return analysis.settings?.model?.revision != revision }
        return false
    }

    /// The small-tasks step: nil when no small-tasks model is selected, or it can't run (Apple
    /// Intelligence off, a refusal, an unreadable answer), so the summarizer's own title, kind, and
    /// terms stand exactly as before.
    private func smallTasks(transcript: String, notes: String, kind: MeetingKind, vocabulary: [String],
                            progress: @escaping IntelligenceProgressHandler) async throws -> SmallTaskResult? {
        guard let model = configuration.smallTasksModel else { return nil }
        do {
            return try await inference.performSmallTasks(transcript: transcript, notes: notes, template: kind,
                                                         glossary: vocabulary, model: model, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
    }

    /// Both models' suggestions, the small-tasks model's first, without duplicates, at most 12.
    static func merging(_ first: [String], into second: [String]) -> [String] {
        var seen = Set<String>()
        return Array((first + second).filter { seen.insert($0.lowercased()).inserted }.prefix(12))
    }
}
