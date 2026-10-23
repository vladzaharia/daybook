import Foundation
import AVFoundation
import CoreML
import WhisperKit
import FluidAudio
import MLXLLM
import MLXLMCommon
import MLX
import Hub
import Tokenizers
import DaybookCore

/// Own one instance for the application. Expensive operations are serialized;
/// actor reentrancy is guarded so a model cannot be removed while in use.
actor LocalIntelligenceRuntime {
    static let catalog = DaybookModelCatalog.models
    let modelsDirectory: URL
    private var busy = false
    private var whisper: OfflineWhisperKit?
    private var whisperID: String?
    private var languageModel: ModelContainer?
    private var languageModelID: String?
    private var speakerModels: OfflineDiarizerModels?
    private var sortformerModels: OfflineSortformerModels?
    private var sortformerID: String?

    init(modelsDirectory: URL) { self.modelsDirectory = modelsDirectory }

    func installedModels() -> Set<String> {
        Set(Self.catalog.compactMap { (try? installation(for: $0.id)) != nil ? $0.id : nil })
    }

    func download(modelID: String, progress: @escaping IntelligenceProgressHandler = { _ in }) async throws {
        try begin(); defer { busy = false }
        let model = try descriptor(modelID)
        if (try? installation(for: modelID)) != nil { progress(.init(1, "Already downloaded")); return }
        let root = modelRoot(modelID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        progress(.init(0, "Downloading \(model.name)"))
        let folder: URL
        var tokenizerFolder: URL?
        switch model.role {
        case .transcription:
            let hub = HubApi(downloadBase: root, hfToken: "", useOfflineMode: false)
            let subdirectory = model.modelSubdirectory!
            let repoFolder = try await hub.snapshot(from: model.repository, revision: model.revision,
                                                    matching: ["\(subdirectory)/*"]) {
                progress(.init($0.fractionCompleted * 0.94, "Downloading \(model.name)"))
            }
            try Task.checkCancellation()
            folder = repoFolder.appendingPathComponent(subdirectory)
            tokenizerFolder = try await hub.snapshot(from: model.tokenizerRepository!, revision: model.tokenizerRevision!,
                                                     matching: ["tokenizer.json", "tokenizer_config.json", "config.json", "special_tokens_map.json", "added_tokens.json"]) {
                progress(.init(0.94 + $0.fractionCompleted * 0.05, "Downloading tokenizer"))
            }
            // Validate the tokenizer before recording a successful installation.
            _ = try await AutoTokenizer.from(modelFolder: tokenizerFolder!, hubApi: HubApi(useOfflineMode: true))
        case .summarization:
            folder = try await HubApi(downloadBase: root, hfToken: "", useOfflineMode: false).snapshot(
                from: model.repository, revision: model.revision, matching: ["*.safetensors", "*.json", "*.jinja"]) {
                    progress(.init($0.fractionCompleted * 0.99, "Downloading \(model.name)"))
                }
        case .diarization:
            if modelID == DaybookModelCatalog.diarization {
                try await ModelHub.download(.diarizer, to: root, variant: "offline") {
                    progress(.init($0.fractionCompleted * 0.99, "Downloading speaker models"))
                }
                folder = root.appendingPathComponent(Repo.diarizer.folderName)
            } else {
                let subdirectory = model.modelSubdirectory!
                let repoFolder = try await HubApi(downloadBase: root, hfToken: "", useOfflineMode: false).snapshot(
                    from: model.repository, revision: model.revision, matching: ["\(subdirectory)/*"]) {
                        progress(.init($0.fractionCompleted * 0.99, "Downloading \(model.name)"))
                    }
                folder = repoFolder.appendingPathComponent(subdirectory)
            }
        }
        try Task.checkCancellation()
        let marker = ModelInstallation(modelID: modelID, revision: model.revision,
                                       modelPath: relative(folder, to: root),
                                       tokenizerPath: tokenizerFolder.map { relative($0, to: root) },
                                       files: try fileInventory(at: root))
        guard !marker.files.isEmpty else { throw LocalIntelligenceError.modelNotInstalled(modelID) }
        try JSONEncoder().encode(marker).write(to: root.appendingPathComponent("installed.json"), options: .atomic)
        progress(.init(1, "\(model.name) is ready for offline use"))
    }

    func remove(modelID: String) throws {
        try begin(); defer { busy = false }
        _ = try descriptor(modelID)
        if whisperID == modelID { whisper = nil; whisperID = nil }
        if languageModelID == modelID { releaseLanguageModel() }
        if modelID == DaybookModelCatalog.diarization { speakerModels = nil }
        if modelID == sortformerID { sortformerModels = nil; sortformerID = nil }
        let root = modelRoot(modelID)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }

    func unload() throws {
        try begin(); defer { busy = false }
        whisper = nil; whisperID = nil; releaseLanguageModel(); releaseSpeakerModels()
    }

    func transcribe(url: URL, modelID: String, glossary: [String] = [],
                    progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> RecognitionResult {
        try begin(); defer { busy = false }
        let install = try installation(for: modelID, role: .transcription)
        releaseLanguageModel()
        progress(.init(0, "Loading speech model locally"))
        if whisperID != modelID || whisper == nil {
            whisper = nil; whisperID = nil
            let root = modelRoot(modelID)
            let config = WhisperKitConfig(modelFolder: root.appendingPathComponent(install.modelPath).path,
                                          tokenizerFolder: root.appendingPathComponent(install.tokenizerPath!),
                                          verbose: false, logLevel: .error, prewarm: false, load: true, download: false)
            whisper = try await OfflineWhisperKit(config)
            whisperID = modelID
        }
        guard let engine = whisper else { throw LocalIntelligenceError.modelNotInstalled(modelID) }
        let audioFile = try AVAudioFile(forReading: url)
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw LocalIntelligenceError.invalidAudio }
        var options = DecodingOptions(verbose: false, temperature: 0, skipSpecialTokens: true,
                                      wordTimestamps: true, concurrentWorkerCount: 2, chunkingStrategy: .vad)
        if !glossary.isEmpty {
            options.promptTokens = Array((engine.tokenizer?.encode(text: glossary.prefix(80).joined(separator: ", ")) ?? []).suffix(180))
        }
        var segments: [RecognizedSegment] = []
        var language: String?
        // Five-minute slabs bound decoded PCM memory for day-long recordings.
        // One second of context on each side prevents cutting words at a slab edge.
        let slab: Double = 300
        var coreStart: Double = 0
        while coreStart < duration {
            try Task.checkCancellation()
            let coreEnd = min(duration, coreStart + slab)
            let loadStart = max(0, coreStart - 1), loadEnd = min(duration, coreEnd + 1)
            let samples = try AudioSlabReader.samples(url: url, from: loadStart, to: loadEnd)
            let results: [TranscriptionResult] = try await engine.transcribe(
                audioArray: samples, decodeOptions: options, callback: { _ in !Task.isCancelled })
            try Task.checkCancellation()
            for result in results {
                language = language ?? result.language
                for segment in result.segments {
                    let words = (segment.words ?? []).compactMap { word -> RecognizedWord? in
                        let start = Double(word.start) + loadStart, end = Double(word.end) + loadStart
                        let midpoint = (start + end) / 2
                        guard midpoint >= coreStart, midpoint < coreEnd else { return nil }
                        return .init(text: word.word, start: max(0, start), end: min(duration, end),
                                     confidence: Double(word.probability))
                    }
                    if let first = words.first, let last = words.last {
                        segments.append(.init(start: first.start, end: last.end,
                                              text: words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                                              confidence: words.map(\.confidence).reduce(0, +) / Double(words.count), words: words))
                    } else if segment.words == nil || segment.words?.isEmpty == true {
                        let start = Double(segment.start) + loadStart, end = Double(segment.end) + loadStart
                        guard (start + end) / 2 >= coreStart, (start + end) / 2 < coreEnd else { continue }
                        segments.append(.init(start: max(0, start), end: min(duration, end),
                                              text: segment.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                              confidence: min(1, max(0, exp(Double(segment.avgLogprob)))), words: []))
                    }
                }
            }
            coreStart = coreEnd
            progress(.init(coreEnd / duration, "Transcribed \(Int(coreEnd)) of \(Int(duration)) seconds"))
        }
        return RecognitionResult(segments: segments.filter { !$0.text.isEmpty }.sorted { $0.start < $1.start },
                                 language: language, duration: duration)
    }

    func diarize(url: URL, modelID: String = DaybookModelCatalog.diarization,
                 options: SpeakerAnalysisOptions = .init(),
                 progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> SpeakerAnalysis {
        try begin(); defer { busy = false }
        let install = try installation(for: modelID, role: .diarization)
        releaseLanguageModel()
        let folder = modelRoot(modelID).appendingPathComponent(install.modelPath)
        if modelID != DaybookModelCatalog.diarization {
            speakerModels = nil
            if sortformerID != modelID || sortformerModels == nil {
                sortformerModels = nil; sortformerID = nil
                progress(.init(0, "Loading Sortformer locally"))
                let precision: ModelNames.Sortformer.ModelPrecision =
                    modelID == DaybookModelCatalog.sortformerCompact ? .palettized : .fp16
                sortformerModels = try await OfflineSortformerModels.load(
                    config: .init(precision: precision), modelPath: folder)
                sortformerID = modelID
            }
            return try BoundedSortformer.process(url: url, models: sortformerModels!, options: options,
                                                 progress: progress)
        }
        sortformerModels = nil; sortformerID = nil
        if speakerModels == nil {
            progress(.init(0, "Loading speaker models locally"))
            speakerModels = try loadSpeakerModels(at: folder)
        }
        // A fresh manager prevents a previous run's settings or clustering state
        // from leaking into this run. The expensive Core ML models remain cached.
        let manager = OfflineDiarizerManager(config: options.communityConfiguration())
        manager.initialize(models: speakerModels!)
        try Task.checkCancellation()
        let result = try await manager.process(url) { completed, total in
            progress(.init(Double(completed) / Double(max(1, total)) * 0.95, "Detecting speaker turns"))
        }
        try Task.checkCancellation()
        progress(.init(1, "Speaker detection complete"))
        return SpeakerAnalysis(turns: result.segments.map {
            .init(speakerID: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds),
                  confidence: Double($0.qualityScore))
        }, embeddings: result.speakerDatabase ?? [:], embeddingModelID: DaybookModelCatalog.communityEmbeddingID)
    }

    func summarize(transcript: String, notes: String, template: MeetingKind = .auto, glossary: [String] = [],
                   modelID: String, templateInstructions: String? = nil, highlightEvidence: String? = nil,
                   progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> GeneratedMeetingNotes {
        try begin(); defer { busy = false }
        let install = try installation(for: modelID, role: .summarization)
        whisper = nil; whisperID = nil; releaseSpeakerModels()
        progress(.init(0, "Loading language model locally"))
        if languageModelID != modelID || languageModel == nil {
            releaseLanguageModel()
            GPU.set(cacheLimit: 256 * 1_024 * 1_024)
            languageModel = try await LLMModelFactory.shared.loadContainer(
                hub: HubApi(useOfflineMode: true),
                configuration: ModelConfiguration(directory: modelRoot(modelID).appendingPathComponent(install.modelPath)))
            languageModelID = modelID
        }
        try Task.checkCancellation()
        return try await MeetingSynthesis.generate(model: languageModel!, modelID: modelID,
                                                   transcript: transcript, notes: notes, template: template,
                                                   glossary: glossary, templateInstructions: templateInstructions,
                                                   highlightEvidence: highlightEvidence, progress: progress)
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !busy else { throw LocalIntelligenceError.busy }
        busy = true
    }

    private func releaseLanguageModel() {
        languageModel = nil; languageModelID = nil
        // The MLX allocator otherwise retains freed weights in its buffer cache.
        GPU.clearCache()
    }

    private func releaseSpeakerModels() {
        speakerModels = nil; sortformerModels = nil; sortformerID = nil
    }

    private func descriptor(_ id: String) throws -> LocalModelDescriptor {
        guard let model = Self.catalog.first(where: { $0.id == id }) else { throw LocalIntelligenceError.unknownModel(id) }
        return model
    }

    private func modelRoot(_ id: String) -> URL { modelsDirectory.appendingPathComponent(id, isDirectory: true) }

    private func installation(for id: String, role: LocalModelRole? = nil) throws -> ModelInstallation {
        let model = try descriptor(id)
        guard role == nil || model.role == role else { throw LocalIntelligenceError.unknownModel(id) }
        let root = modelRoot(id)
        guard let data = try? Data(contentsOf: root.appendingPathComponent("installed.json")),
              let marker = try? JSONDecoder().decode(ModelInstallation.self, from: data),
              marker.modelID == id, marker.revision == model.revision, !marker.files.isEmpty,
              marker.files.allSatisfy({ path, size in
                  guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                        let values = try? root.appendingPathComponent(path).resourceValues(forKeys: [.fileSizeKey]) else { return false }
                  return Int64(values.fileSize ?? -1) == size
              }),
              !marker.modelPath.hasPrefix("/"),
              !marker.modelPath.split(separator: "/").contains(".."),
              FileManager.default.fileExists(atPath: root.appendingPathComponent(marker.modelPath).path),
              marker.tokenizerPath.map({ !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..") }) ?? true,
              model.role != .transcription || marker.tokenizerPath != nil
        else { throw LocalIntelligenceError.modelNotInstalled(id) }
        return marker
    }

    private func relative(_ url: URL, to root: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count + 1))
    }

    private func fileInventory(at root: URL) throws -> [String: Int64] {
        var result: [String: Int64] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                        options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values.isRegularFile == true, url.lastPathComponent != "installed.json", !url.lastPathComponent.hasSuffix(".partial") {
                result[relative(url, to: root)] = Int64(values.fileSize ?? 0)
            }
        }
        return result
    }

    /// Loading Core ML assets directly avoids ModelHub's online repair fallback.
    private func loadSpeakerModels(at folder: URL) throws -> OfflineDiarizerModels {
        let started = Date()
        func load(_ name: String, units: MLComputeUnits = .all) throws -> MLModel {
            let config = MLModelConfiguration(); config.computeUnits = units
            return try MLModel(contentsOf: folder.appendingPathComponent(name + ".mlmodelc"), configuration: config)
        }
        let parameters = try JSONDecoder().decode(PLDAParameters.self,
                                                  from: Data(contentsOf: folder.appendingPathComponent("plda-parameters.json")))
        guard let bytes = Data(base64Encoded: parameters.tensors.psi.data_base64), bytes.count % 4 == 0, !bytes.isEmpty else {
            throw LocalIntelligenceError.modelNotInstalled(DaybookModelCatalog.diarization)
        }
        let psi: [Double] = bytes.withUnsafeBytes { buffer in
            stride(from: 0, to: bytes.count, by: 4).map {
                Double(Float(bitPattern: UInt32(littleEndian: buffer.loadUnaligned(fromByteOffset: $0, as: UInt32.self))))
            }
        }
        return try OfflineDiarizerModels(segmentationModel: load("Segmentation"), fbankModel: load("FBank", units: .cpuOnly),
                                         embeddingModel: load("Embedding"), pldaRhoModel: load("PldaRho"), pldaPsi: psi,
                                         compilationDuration: Date().timeIntervalSince(started))
    }
}

private struct ModelInstallation: Codable {
    let modelID: String
    let revision: String
    let modelPath: String
    let tokenizerPath: String?
    let files: [String: Int64]
}

private struct PLDAParameters: Decodable {
    struct Tensors: Decodable { let psi: Tensor }
    struct Tensor: Decodable { let data_base64: String }
    let tensors: Tensors
}
