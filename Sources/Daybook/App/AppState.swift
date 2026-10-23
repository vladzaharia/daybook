import AppKit
import AVFoundation
import Combine
import DaybookCore
import Foundation
import UniformTypeIdentifiers

@MainActor
final class AppState: ObservableObject {
    nonisolated static let libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Daybook", isDirectory: true)
    @Published var meetings: [Meeting] = []
    @Published var selectedID: UUID?
    @Published var search = ""
    @Published var folderFilter: UUID?
    @Published var tagFilter: String?
    @Published private(set) var libraryMetadata = LibraryMetadata()
    var folders: [LibraryFolder] { libraryMetadata.folders.compactMap(\.value).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var templates: [SummaryTemplate] { SummaryTemplate.catalog(templates: libraryMetadata.templates.compactMap(\.value)) }
    var allTags: [String] { Array(Set(meetings.flatMap { $0.tags ?? [] })).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    @Published var section: LibrarySection = .all
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var isReady = false
    @Published var processingID: UUID?
    @Published var processingProgress = IntelligenceProgress(0, "Ready")
    @Published private(set) var processingQueue: [ProcessingRequest] = []
    var queuedIDs: [UUID] { processingQueue.map(\.meetingID) }
    @Published var processingPreferences: ProcessingPreferences {
        didSet { if let data = try? JSONEncoder().encode(processingPreferences.normalized) { preferences.set(data, forKey: "processingPreferences") } }
    }
    @Published var installedModels: Set<String> = []
    @Published var downloadingID: String?
    @Published var downloadProgress = IntelligenceProgress(0, "")
    @Published var glossary: [GlossaryTerm] = []
    @Published var recordingID: UUID?
    @Published var isStartingRecording = false
    @Published var isStoppingRecording = false
    @Published var recordingStartedAt: Date?
    @Published var transcriptionModel: String { didSet { preferences.set(transcriptionModel, forKey: "transcriptionModel") } }
    @Published var summaryModel: String { didSet { preferences.set(summaryModel, forKey: "summaryModel") } }
    @Published var automaticRecording: Bool {
        didSet {
            preferences.set(automaticRecording, forKey: "automaticRecording")
            if automaticRecording { monitor.startMonitoring() }
            else {
                monitor.stopMonitoring()
                if recordingWasAutomatic { Task { await stopRecording(manual: false) } }
            }
        }
    }
    @Published var includeComputerAudio: Bool { didSet { preferences.set(includeComputerAudio, forKey: "includeComputerAudio") } }
    @Published var processSyncedAudio: Bool { didSet { preferences.set(processSyncedAudio, forKey: "processSyncedAudio") } }
    @Published var detectSpeakers: Bool { didSet { preferences.set(detectSpeakers, forKey: "detectSpeakers") } }
    let sync: LibrarySyncController
    let soundcore = SoundcoreController()
    private var isApplyingSync = false
    let recorder = RecordingController()
    let monitor = MeetingMonitor()
    let folderWatcher: ImportFolderWatcher
    let storageURL: URL
    private let preferences: UserDefaults
    let runtime: LocalIntelligenceRuntime
    private let liveRuntime: LocalIntelligenceRuntime
    private var store: MeetingStore?
    private var glossaryStore: GlossaryStore?
    private var persistence: Task<Void, Never>?
    private var persistenceErrors: [String: String] = [:]
    private var processingTask: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var notesTasks: [UUID: Task<Void, Never>] = [:]
    private var noteOriginals: [UUID: String] = [:]
    private var subscriptions: Set<AnyCancellable> = []
    private var recordingWasAutomatic = false
    private var captureDirectory: URL?
    private var notesPanel: NotesPanelController?
    private var importLocked = false
    private var importWaiters: [CheckedContinuation<Void, Never>] = []

    init(libraryURL: URL = AppState.libraryURL, defaults: UserDefaults = .standard) {
        processingPreferences = defaults.data(forKey: "processingPreferences").flatMap { try? JSONDecoder().decode(ProcessingPreferences.self, from: $0) } ?? .init()
        sync = LibrarySyncController(localRoot: libraryURL, defaults: defaults)
        storageURL = libraryURL
        preferences = defaults
        folderWatcher = ImportFolderWatcher(defaults: defaults)
        transcriptionModel = defaults.string(forKey: "transcriptionModel") ?? DaybookModelCatalog.defaultTranscription
        summaryModel = defaults.string(forKey: "summaryModel") ?? DaybookModelCatalog.defaultSummarization
        automaticRecording = defaults.bool(forKey: "automaticRecording")
        includeComputerAudio = defaults.object(forKey: "includeComputerAudio") as? Bool ?? true
        processSyncedAudio = defaults.object(forKey: "processSyncedAudio") as? Bool ?? true
        detectSpeakers = defaults.object(forKey: "detectSpeakers") as? Bool ?? true
        runtime = LocalIntelligenceRuntime(modelsDirectory: libraryURL.appendingPathComponent("Models"))
        liveRuntime = LocalIntelligenceRuntime(modelsDirectory: libraryURL.appendingPathComponent("Models"))
        for publisher in [recorder.objectWillChange.eraseToAnyPublisher(), monitor.objectWillChange.eraseToAnyPublisher(), folderWatcher.objectWillChange.eraseToAnyPublisher(), sync.objectWillChange.eraseToAnyPublisher(), soundcore.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        sync.onSyncRequested = { [weak self] in await self?.synchronizeLibrary() }
        soundcore.transcribeLiveAudio = { [weak self] url in
            guard let self else { throw AppError.libraryUnavailable }
            let modelID = self.transcriptionModel
            guard self.installedModels.contains(modelID) else { throw LocalIntelligenceError.modelNotInstalled(modelID) }
            let words = self.glossary.filter(\.approved).map(\.term)
            do {
                let result = try await self.liveRuntime.transcribe(url: url, modelID: modelID, glossary: words, progress: { _ in })
                try await self.liveRuntime.unload()
                return result.segments.map(\.text).joined(separator: " ")
            } catch { try? await self.liveRuntime.unload(); throw error }
        }
        soundcore.onRecordingReady = { [weak self] url in
            guard let self else { return }
            Task { do { try await self.importFiles([url], source: .soundcore, attachTo: nil) } catch { self.errorMessage = error.localizedDescription } }
        }
        monitor.onMeetingStarted = { [weak self] candidate in
            guard let self, self.automaticRecording, self.recordingID == nil, !self.isStartingRecording else { return }
            Task { await self.startRecording(title: candidate.windowTitle, automatic: true) }
        }
        monitor.onMeetingEnded = { [weak self] in
            guard let self, self.recordingWasAutomatic else { return }
            Task { await self.stopRecording(manual: false) }
        }
        folderWatcher.onImport = { [weak self] url in
            guard let self else { return }
            try await self.importFiles([url], source: .soundcore, attachTo: nil)
        }
        recorder.onUnexpectedStop = { [weak self] result in
            guard let self else { return }
            Task { await self.finishCapture(result) }
        }
    }

    var selectedMeeting: Meeting? { meetings.first { $0.id == selectedID } }
    var isRecording: Bool { recordingID != nil }
    var canProcess: Bool { installedModels.contains(transcriptionModel) && installedModels.contains(summaryModel) && (!detectSpeakers || installedModels.contains(processingPreferences.speakerModelID)) }
    var visibleMeetings: [Meeting] {
        meetings.filter { meeting in
            let kind = meeting.displayKind
            let matchesSection = section == .all || (section == .personal && [.therapy, .personal].contains(kind)) || (section == .work && ![.therapy, .personal].contains(kind))
            let matchesFolder = folderFilter == nil || meeting.folderID == folderFilter
            let matchesTag = tagFilter == nil || (meeting.tags ?? []).contains(tagFilter!)
            guard matchesSection && matchesFolder && matchesTag else { return false }
            guard !search.isEmpty else { return true }
            let shortFields = [meeting.title, meeting.notes, meeting.summary?.overview ?? ""] + (meeting.tags ?? [])
            return shortFields.contains { $0.localizedCaseInsensitiveContains(search) }
                || meeting.unifiedTranscript.contains { $0.text.localizedCaseInsensitiveContains(search) }
                || (meeting.summary?.sections.contains { $0.body.localizedCaseInsensitiveContains(search) } ?? false)
        }.sorted { $0.date > $1.date }
    }

    func initialize() async {
        guard !isReady else { return }
        do {
            store = try MeetingStore(rootURL: storageURL)
            glossaryStore = try GlossaryStore(rootURL: storageURL)
            guard let store, let glossaryStore else { return }
            meetings = try await store.list()
            glossary = try await glossaryStore.list()
            if let data = try? Data(contentsOf: storageURL.appendingPathComponent("library.json")) {
                libraryMetadata = try JSONDecoder().decode(LibraryMetadata.self, from: data)
                guard libraryMetadata.schemaVersion == 1 else { throw AppError.libraryUnavailable }
                if !libraryMetadata.vocabulary.isEmpty { glossary = libraryMetadata.vocabulary.compactMap(\.value) }
            } else {
                libraryMetadata.vocabulary = glossary.map { .init(id: $0.id.uuidString, value: $0) }
            }
            for index in meetings.indices where [.transcribing, .summarizing, .recording].contains(meetings[index].status) {
                meetings[index].status = .imported
                meetings[index].errorMessage = "The previous session was interrupted. Your saved audio and notes are intact; choose Process to continue."
                try await store.save(meetings[index])
            }
            let warnings = await store.warnings
            if !warnings.isEmpty { notice = warnings.joined(separator: "\n") }
            installedModels = await runtime.installedModels()
            selectedID = meetings.first?.id
            isReady = true
            await recoverRecordings()
            folderWatcher.restore()
            sync.restore()
            if automaticRecording { monitor.startMonitoring() }
        } catch { errorMessage = "Couldn’t open your library: \(error.localizedDescription)" }
    }

    @discardableResult func newMeeting(title: String = "Untitled meeting") -> UUID {
        let meeting = Meeting(title: title, folderID: folderFilter, tags: tagFilter.map { [$0] })
        meetings.insert(meeting, at: 0)
        selectedID = meeting.id
        persist(meeting)
        return meeting.id
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        let before = meetings[index]
        change(&meetings[index])
        guard meetings[index] != before else { return }
        meetings[index].updatedAt = Date()
        persist(meetings[index])
    }

    private func persist(_ meeting: Meeting) {
        guard let store else { return }
        if !isApplyingSync { sync.requestSync() }
        let prior = persistence
        persistence = Task { [weak self] in
            await prior?.value
            do { try await store.save(meeting); self?.persistenceErrors.removeValue(forKey: meeting.id.uuidString) }
            catch { self?.persistenceErrors[meeting.id.uuidString] = error.localizedDescription; self?.errorMessage = "Couldn’t save \(meeting.title): \(error.localizedDescription)" }
        }
    }

    func resolvedTemplate(for meeting: Meeting) -> SummaryTemplate? {
        guard meeting.templateID != nil || meeting.kind != .auto else { return nil }
        return SummaryTemplate.resolved(id: meeting.templateID, kind: meeting.kind, templates: templates)
    }

    func saveTemplate(_ template: SummaryTemplate) {
        var value = template; value.updatedAt = Date()
        libraryMetadata.templates.removeAll { $0.id == value.id }
        libraryMetadata.templates.append(.init(id: value.id, value: value)); persistLibraryMetadata()
    }
    func removeTemplate(_ id: String) {
        libraryMetadata.templates.removeAll { $0.id == id }
        libraryMetadata.templates.append(.init(id: id, value: nil)); persistLibraryMetadata()
    }
    func saveFolder(_ folder: LibraryFolder) {
        let name = folder.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        libraryMetadata.folders.removeAll { $0.id == folder.id.uuidString }
        libraryMetadata.folders.append(.init(id: folder.id.uuidString, value: LibraryFolder(id: folder.id, name: name)))
        persistLibraryMetadata()
    }
    func removeFolder(_ id: UUID) {
        libraryMetadata.folders.removeAll { $0.id == id.uuidString }
        libraryMetadata.folders.append(.init(id: id.uuidString, value: nil)); persistLibraryMetadata()
        for meeting in meetings where meeting.folderID == id { update(meeting.id) { $0.folderID = nil } }
        if folderFilter == id { folderFilter = nil }
    }
    func setTags(_ id: UUID, text: String) {
        var seen = Set<String>()
        let tags = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
        update(id) { $0.tags = tags }
    }
    private func persistLibraryMetadata() {
        if !isApplyingSync { sync.requestSync() }
        let snapshot = libraryMetadata, url = storageURL.appendingPathComponent("library.json"), prior = persistence
        persistence = Task { [weak self] in
            await prior?.value
            do {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(snapshot).write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                self?.persistenceErrors.removeValue(forKey: "library-settings")
            } catch { self?.persistenceErrors["library-settings"] = error.localizedDescription; self?.errorMessage = "Couldn’t save library settings: \(error.localizedDescription)" }
        }
    }

    func editNotes(_ id: UUID, text: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        if noteOriginals[id] == nil { noteOriginals[id] = meetings[index].notes }
        let previous = meetings[index].timedNotes ?? NoteTimeline.reconcile(previous: [], text: meetings[index].notes, captureTime: nil)
        meetings[index].timedNotes = NoteTimeline.reconcile(previous: previous, text: text, captureTime: recordingID == id ? recorder.elapsedTime : nil)
        meetings[index].notes = text
        // Save the current text immediately, while grouping history entries after typing pauses.
        meetings[index].updatedAt = Date(); persist(meetings[index])
        notesTasks[id]?.cancel()
        notesTasks[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(900)); self?.finishNoteEdit(id) } catch { }
        }
    }

    private func finishNoteEdit(_ id: UUID) {
        notesTasks.removeValue(forKey: id)?.cancel()
        guard let original = noteOriginals.removeValue(forKey: id) else { return }
        update(id) { meeting in
            if original != meeting.notes { meeting.revisions.append(.init(field: "notes", oldValue: original, newValue: meeting.notes)) }
        }
    }

    func flush() async {
        for id in Array(noteOriginals.keys) { finishNoteEdit(id) }
        await persistence?.value
    }

    func chooseImport(attachTo id: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.title = id == nil ? "Import recordings" : "Add another recording of this conversation"
        panel.message = id == nil ? "Import audio exported by Soundcore or any other recorder." : "Daybook will align this source with the existing transcript and preserve both originals."
        panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            do { try await importFiles(panel.urls, source: .imported, attachTo: id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func importFiles(_ urls: [URL], source: AudioSource, attachTo id: UUID?) async throws {
        await acquireImportLock()
        defer { releaseImportLock() }
        guard let store else { throw AppError.libraryUnavailable }
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            // Validate before creating a library entry; zero-length and unsupported files remain outside the library.
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw AppError.invalidAudio(url.lastPathComponent) }
            if id == nil, let existing = try await store.existingMeeting(containingAudioAt: url) {
                selectedID = existing.id
                notice = "This audio is already in \(existing.title)."
                continue
            }
            let meetingID = id ?? newMeeting(title: url.deletingPathExtension().lastPathComponent)
            await flush()
            guard let meeting = meetings.first(where: { $0.id == meetingID }) else { continue }
            let sidecar = url.deletingPathExtension().appendingPathExtension("highlights.json")
            let imported = try await store.importAudio(from: url, into: meeting, source: source,
                sidecarURL: FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil)
            update(meetingID) { current in
                for track in imported.tracks where !current.tracks.contains(where: { $0.id == track.id }) { current.tracks.append(track) }
                for index in current.tracks.indices where imported.tracks.contains(where: { $0.id == current.tracks[index].id && $0.fileName == url.lastPathComponent }) && current.tracks[index].duration == nil { current.tracks[index].duration = duration }
                for highlight in imported.highlights where !current.highlights.contains(where: { $0.id == highlight.id }) { current.highlights.append(highlight) }
                current.status = .imported; current.errorMessage = nil
            }
            selectedID = meetingID
            enqueue(meetingID)
        }
    }

    func chooseImportFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Export or AirDrop Soundcore audio into this folder. Stable audio files will be imported automatically."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try folderWatcher.watch(url) } catch { errorMessage = error.localizedDescription }
    }

    func enqueue(_ id: UUID, mode: ProcessingRequest.Mode = .newAudio) {
        guard id != recordingID, !queuedIDs.contains(id), let meeting = meetings.first(where: { $0.id == id }) else { return }
        let request = ProcessingRequest(meetingID: id, mode: mode, transcriptionModelID: transcriptionModel,
            summaryModelID: summaryModel, detectSpeakers: detectSpeakers, preferences: processingPreferences)
        let hasNew = meeting.tracks.contains { track in !meeting.transcripts.contains { $0.trackID == track.id } }
        let missing = request.requiredModelIDs(hasUntranscribedAudio: hasNew).subtracting(installedModels)
        guard missing.isEmpty else {
            update(id) { $0.errorMessage = "Audio is saved. Download the selected models in Settings: " + missing.sorted().joined(separator: ", ") }
            return
        }
        processingQueue.append(request); runQueue()
    }

    private func runQueue() {
        guard processingTask == nil, downloadingID == nil, !isApplyingSync, !processingQueue.isEmpty else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            while !self.processingQueue.isEmpty && !Task.isCancelled {
                let request = self.processingQueue.removeFirst(), id = request.meetingID
                self.processingID = id
                do { try await self.process(request) }
                catch is CancellationError { self.update(id) { $0.status = .imported; $0.errorMessage = "Processing paused. Choose Process to continue." } }
                catch { self.update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription } }
                self.processingID = nil
            }
            self.processingTask = nil
            self.processingProgress = IntelligenceProgress(0, "Ready")
        }
    }

    func cancelProcessing() { processingTask?.cancel(); processingQueue.removeAll() }

    private func process(_ request: ProcessingRequest) async throws {
        let id = request.meetingID
        guard let store, let initial = meetings.first(where: { $0.id == id }) else { return }
        await flush()
        let asr = request.transcriptionModelID, llm = request.summaryModelID, options = request.preferences
        let terms = glossary.filter { $0.approved || $0.sourceMeetingIDs.contains(id) }.map(\.term)
        update(id) { $0.status = .transcribing; $0.errorMessage = nil }
        let progress: IntelligenceProgressHandler = { [weak self] value in
            Task { @MainActor in self?.processingProgress = value }
        }
        for track in initial.tracks where request.mode != .summaryOnly {
            try Task.checkCancellation()
            let previous = meetings.first(where: { $0.id == id })?.transcripts.filter { $0.trackID == track.id }.max { $0.createdAt < $1.createdAt }
            if request.mode == .newAudio && previous != nil { continue }
            let url = try await store.audioURL(for: track, in: id)
            let result: RecognitionResult
            var transcriptModel = asr
            if request.mode == .speakerRefresh, let previous {
                transcriptModel = previous.modelID
                if let words = previous.words, !words.isEmpty {
                    let restored = words.map { RecognizedWord(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence ?? 1) }
                    result = RecognitionResult(segments: [.init(start: restored.first!.start, end: restored.last!.end,
                        text: restored.map(\.text).joined(), confidence: 1, words: restored)], language: previous.language,
                        duration: track.duration ?? restored.last!.end)
                } else {
                    result = RecognitionResult(segments: previous.segments.map { .init(start: $0.start, end: $0.end, text: $0.text, confidence: $0.confidence ?? 1, words: []) },
                        language: previous.language, duration: track.duration ?? previous.segments.last?.end ?? 0)
                    notice = "This older transcript has no saved word timings. Speaker labels use passage boundaries; re-transcribe for finer speaker changes."
                }
            } else { result = try await runtime.transcribe(url: url, modelID: asr, glossary: terms, progress: progress) }
            var analysis: SpeakerAnalysis?
            if request.detectSpeakers {
                do { analysis = try await runtime.diarize(url: url, modelID: options.speakerModelID, options: options.speakerOptions, progress: progress) }
                catch is CancellationError { throw CancellationError() }
                catch {
                    if request.mode == .speakerRefresh { throw error }
                    notice = "Transcription succeeded, but speaker detection failed for \(track.fileName): \(error.localizedDescription)"
                }
            }
            if let warnings = analysis?.warnings, !warnings.isEmpty { notice = warnings.joined(separator: "\n") }
            let runID = UUID()
            var segments = TranscriptBuilder.segments(result: result, speakers: analysis, track: track, runID: runID)
            let settings = ProcessingSettings(modelID: transcriptModel, parameters: [
                "mode": request.mode.rawValue, "configuration": request.configurationFingerprint,
                "speakerModel": request.detectSpeakers ? options.speakerModelID : "disabled",
                "speakerQuality": options.speakerOptions.quality.rawValue,
                "matchThreshold": String(options.speakerMatchThreshold), "matchMargin": String(options.speakerMatchMargin)])
            update(id) { meeting in
                let labels = Set(segments.compactMap(\.speakerID)).sorted()
                let incoming = labels.enumerated().map { index, label in
                    let cluster = String(label.dropFirst(runID.uuidString.count + 1))
                    return Speaker(id: label, name: "Speaker \(meeting.speakers.count + index + 1)", sourceTrackID: track.id,
                        embedding: analysis?.embeddings[cluster], embeddingModelID: analysis?.embeddingModelID,
                        analysisSettings: ProcessingSettings(modelID: options.speakerModelID, parameters: settings.parameters))
                }
                if options.matchSpeakersAcrossSources && analysis?.embeddingModelID != nil {
                    let matches = SpeakerMatcher.match(incoming: incoming, in: meeting,
                        configuration: .init(minimumSimilarity: options.speakerMatchThreshold, minimumMargin: options.speakerMatchMargin),
                        allowSameSource: previous != nil)
                    meeting.speakerMatches = (meeting.speakerMatches ?? []) + matches
                    let accepted = Dictionary(matches.compactMap { match -> (String, String)? in
                        guard let target = match.targetSpeakerID else { return nil }; return (match.sourceSpeakerID, target)
                    }, uniquingKeysWith: { first, _ in first })
                    for index in segments.indices {
                        if let speaker = segments[index].speakerID, let target = accepted[speaker] { segments[index].speakerID = target }
                    }
                }
                meeting.speakers += incoming
                let words = result.segments.flatMap(\.words).map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end, confidence: $0.confidence) }
                meeting.transcripts.append(TrackTranscript(id: runID, trackID: track.id, segments: segments, language: result.language,
                    modelID: transcriptModel, knownOffset: track.offset, processingSettings: settings, words: words.isEmpty ? nil : words))
                if let index = meeting.tracks.firstIndex(where: { $0.id == track.id }) { meeting.tracks[index].duration = result.duration }
            }
        }
        try Task.checkCancellation()
        await realign(id)
        guard let current = meetings.first(where: { $0.id == id }) else { return }
        let transcript = MeetingEvidence.transcript(current)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.noSpeech }
        update(id) { $0.status = .summarizing }
        let template = resolvedTemplate(for: current)
        let generated = try await runtime.summarize(transcript: transcript, notes: MeetingEvidence.notes(current), template: template?.kind ?? current.kind,
            glossary: terms, modelID: llm, templateInstructions: template?.instructions, highlightEvidence: MeetingEvidence.highlights(current), progress: progress)
        try Task.checkCancellation()
        let inputsChanged = meetings.first(where: { $0.id == id }).map {
            $0.notes != current.notes || $0.kind != current.kind || $0.templateID != current.templateID || $0.tracks != current.tracks ||
            $0.unifiedTranscript != current.unifiedTranscript || $0.speakers != current.speakers || $0.highlights != current.highlights || $0.timedNotes != current.timedNotes
        } ?? false
        update(id) { meeting in
            var summary = generated.summary
            summary.processingSettings = ProcessingSettings(modelID: llm, parameters: ["configuration": request.configurationFingerprint,
                "templateID": template?.id ?? "auto", "templateInstructions": template?.instructions ?? "Automatic selection"])
            meeting.setSummary(summary)
            // Keep Auto selected so a new source or revised context can change the inferred kind.
            meeting.status = .ready
            meeting.errorMessage = generated.warnings.isEmpty ? nil : generated.warnings.joined(separator: "\n")
        }
        if let glossaryStore {
            await flush()
            let before = glossary
            try await glossaryStore.propose(generated.suggestedTerms.map { GlossaryTerm(term: $0) }, for: id)
            let loaded = try await glossaryStore.list()
            let removed = Set(before.map(\.id)).subtracting(glossary.map(\.id))
            let edited = glossary.filter { term in before.first(where: { $0.id == term.id }) != term }
            var merged = loaded.filter { !removed.contains($0.id) }
            for term in edited {
                if let index = merged.firstIndex(where: { $0.id == term.id }) { merged[index] = term } else { merged.append(term) }
            }
            glossary = merged
            persistGlossary()
        }
        await flush()
        if inputsChanged { enqueue(id) }
    }

    func synchronizeLibrary() async {
        guard isReady, sync.folder != nil, !isApplyingSync else { return }
        guard processingID == nil, recordingID == nil, !isStartingRecording, !isStoppingRecording else { sync.deferUntilIdle(); return }
        isApplyingSync = true
        await acquireImportLock()
        defer { releaseImportLock(); isApplyingSync = false; runQueue() }
        await flush()
        guard let store else { return }
        do {
            let snapshot = meetings
            let trash = storageURL.appendingPathComponent("Trash")
            let deleted = Set((try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil))?.compactMap { UUID(uuidString: $0.lastPathComponent) } ?? [])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            guard let result = try await sync.synchronize(meetings: snapshot, deletedMeetingIDs: deleted, metadata: encoder.encode(libraryMetadata)) else { return }
            // Save edits made while iCloud hydrated files before applying a remote deletion.
            await flush()
            guard sync.canApply(result) else { return }
            for id in result.deletedMeetingIDs {
                guard sync.canApply(result) else { return }
                if meetings.contains(where: { $0.id == id }), id != recordingID {
                    _ = try await store.moveToTrash(id)
                    meetings.removeAll { $0.id == id }
                    // A completed local move must be reflected in memory even if the account changed
                    // during the store await. Remaining changes from that receipt are discarded.
                    guard sync.canApply(result) else { return }
                }
            }
            var mergeWarnings = result.warnings
            for remote in result.meetings where !result.deletedMeetingIDs.contains(remote.id) {
                var merged = remote
                let local = meetings.first(where: { $0.id == remote.id })
                if let local {
                    let rebased = MeetingMerge.merge(base: snapshot.first { $0.id == remote.id }, local: local, remote: remote)
                    merged = rebased.meeting; mergeWarnings += rebased.warnings
                }
                // Remote process status describes another Mac, not a job running here.
                if [.recording, .transcribing, .summarizing].contains(merged.status), merged.id != recordingID { merged.status = merged.summary == nil ? .imported : .ready }
                if merged != local {
                    if let index = meetings.firstIndex(where: { $0.id == merged.id }) { meetings[index] = merged } else { meetings.append(merged) }
                    persist(merged)
                } else if persistenceErrors[merged.id.uuidString] != nil {
                    // Retry a prior failed save even when the in-memory snapshot is unchanged.
                    persist(merged)
                }
            }
            let metadataBeforeMerge = libraryMetadata
            for data in result.metadataVersions {
                let remote = try JSONDecoder().decode(LibraryMetadata.self, from: data)
                guard remote.schemaVersion == 1 else { throw AppError.libraryUnavailable }
                libraryMetadata = libraryMetadata.merging(remote)
            }
            let mergedGlossary = libraryMetadata.vocabulary.compactMap(\.value)
            if mergedGlossary != glossary || libraryMetadata != metadataBeforeMerge ||
                persistenceErrors["library-settings"] != nil || persistenceErrors["glossary"] != nil {
                glossary = mergedGlossary
                persistGlossary()
            }
            if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) { selectedID = meetings.sorted { $0.date > $1.date }.first?.id }
            if !mergeWarnings.isEmpty { notice = Array(Set(mergeWarnings)).sorted().joined(separator: "\n") }
            await flush()
            guard sync.canApply(result) else { return }
            guard persistenceErrors.isEmpty else { throw AppError.saveFailed(persistenceErrors.values.sorted().joined(separator: "\n")) }
            try await sync.acknowledge(result)
            if processSyncedAudio && canProcess {
                for id in result.meetings.map(\.id) {
                    let previousTrackIDs = Set(snapshot.first(where: { $0.id == id })?.tracks.map(\.id) ?? [])
                    guard let meeting = meetings.first(where: { $0.id == id }),
                          meeting.tracks.contains(where: { track in
                              !previousTrackIDs.contains(track.id) && !meeting.transcripts.contains(where: { $0.trackID == track.id })
                          }) else { continue }
                    // Only newly received sources trigger automatic work. Failed or paused local
                    // jobs remain under manual control, including after a later model download.
                    enqueue(id)
                }
            }
        } catch { sync.reportFailure(error.localizedDescription) }
    }

    func realign(_ id: UUID) async {
        guard let snapshot = meetings.first(where: { $0.id == id }) else { return }
        let fusion = await Task.detached(priority: .userInitiated) {
            TranscriptFusion.fuse(snapshot.transcripts, tracks: snapshot.tracks)
        }.value
        guard let current = meetings.first(where: { $0.id == id }),
              current.transcripts == snapshot.transcripts, current.tracks == snapshot.tracks else { return }
        update(id) { $0.applyFusion(fusion) }
    }

    func setOffset(_ id: UUID, trackID: UUID, seconds: Double?) {
        update(id) { meeting in
            if let index = meeting.tracks.firstIndex(where: { $0.id == trackID }) { meeting.tracks[index].offset = seconds }
            for index in meeting.transcripts.indices where meeting.transcripts[index].trackID == trackID { meeting.transcripts[index].knownOffset = seconds }
        }
        Task { await realign(id) }
    }

    func download(_ modelID: String) {
        guard downloadingID == nil, processingID == nil else { return }
        downloadingID = modelID; downloadProgress = IntelligenceProgress(0, "Preparing download…")
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.runtime.download(modelID: modelID) { [weak self] progress in
                    Task { @MainActor in self?.downloadProgress = progress }
                }
                self.installedModels = await self.runtime.installedModels()
            } catch is CancellationError { self.notice = "Download cancelled. You can try again in Models." }
            catch { self.errorMessage = "Model download failed: \(error.localizedDescription)" }
            self.downloadingID = nil; self.downloadTask = nil; self.runQueue()
        }
    }

    func cancelDownload() { downloadTask?.cancel() }
    func removeModel(_ id: String) {
        guard processingID == nil, downloadingID == nil else { return }
        Task {
            do { try await runtime.remove(modelID: id); installedModels = await runtime.installedModels() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func saveGlossaryTerm(_ term: GlossaryTerm) {
        if let index = glossary.firstIndex(where: { $0.id == term.id }) { glossary[index] = term } else { glossary.append(term) }
        persistGlossary()
    }
    func removeGlossaryTerm(_ id: UUID) { glossary.removeAll { $0.id == id }; persistGlossary() }
    private func persistGlossary() {
        let ids = Set(glossary.map { $0.id.uuidString })
        for index in libraryMetadata.vocabulary.indices where !ids.contains(libraryMetadata.vocabulary[index].id) && libraryMetadata.vocabulary[index].value != nil {
            libraryMetadata.vocabulary[index].value = nil; libraryMetadata.vocabulary[index].modifiedAt = Date()
        }
        for term in glossary {
            if let index = libraryMetadata.vocabulary.firstIndex(where: { $0.id == term.id.uuidString }) {
                if libraryMetadata.vocabulary[index].value != term { libraryMetadata.vocabulary[index] = .init(id: term.id.uuidString, value: term) }
            } else { libraryMetadata.vocabulary.append(.init(id: term.id.uuidString, value: term)) }
        }
        persistLibraryMetadata()
        guard let glossaryStore else { return }
        let snapshot = glossary, prior = persistence
        persistence = Task { [weak self] in
            await prior?.value
            do { try await glossaryStore.save(snapshot); self?.persistenceErrors.removeValue(forKey: "glossary") }
            catch { self?.persistenceErrors["glossary"] = error.localizedDescription; self?.errorMessage = error.localizedDescription }
        }
    }

    func addHighlight(_ id: UUID) {
        guard recordingID == id else { return }
        let seconds = recorder.elapsedTime
        update(id) { $0.highlights.append(Highlight(time: max(0, seconds), text: "Marked moment")) }
    }

    func addPlaybackHighlight(_ id: UUID, trackID: UUID, seconds: Double) {
        guard seconds.isFinite, seconds >= 0, meetings.first(where: { $0.id == id })?.tracks.contains(where: { $0.id == trackID }) == true else { return }
        update(id) { $0.highlights.append(Highlight(trackID: trackID, time: seconds, text: "Marked during review")) }
    }

    func showNotes(for id: UUID) {
        if notesPanel == nil { notesPanel = NotesPanelController() }
        notesPanel?.show(state: self, meetingID: id)
    }

    func export(_ id: UUID, json: Bool = false) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = json ? [.json] : [.plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + (json ? ".json" : ".md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            if json { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; try encoder.encode(meeting).write(to: url, options: .atomic) }
            else { try MeetingExport.markdown(meeting).write(to: url, atomically: true, encoding: .utf8) }
            notice = "Exported \(url.lastPathComponent)"
        } catch { errorMessage = error.localizedDescription }
    }

    func audioURL(for track: RecordingTrack, meetingID: UUID) async -> URL? {
        do { return try await store?.audioURL(for: track, in: meetingID) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    private func acquireImportLock() async {
        if !importLocked { importLocked = true; return }
        await withCheckedContinuation { importWaiters.append($0) }
    }
    private func releaseImportLock() {
        if importWaiters.isEmpty { importLocked = false } else { importWaiters.removeFirst().resume() }
    }

    func trashMeeting(_ id: UUID) {
        guard id != recordingID, id != processingID, !isStartingRecording, !isStoppingRecording else { return }
        processingQueue.removeAll { $0.meetingID == id }
        Task {
            await acquireImportLock()
            defer { releaseImportLock() }
            await flush()
            guard id != recordingID, id != processingID, !isStartingRecording, !isStoppingRecording else { return }
            do {
                _ = try await store?.moveToTrash(id)
                meetings.removeAll { $0.id == id }
                sync.requestSync()
                if selectedID == id { selectedID = meetings.first?.id }
                notice = "Moved conversation to the library’s Trash folder. Original audio and notes are preserved there."
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

extension AppState {
    func startRecording(title: String? = nil, automatic: Bool = false) async {
        guard isReady, recordingID == nil, !isStartingRecording, !isStoppingRecording else { return }
        guard !automatic || automaticRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        let id = newMeeting(title: title?.isEmpty == false ? title! : "Conversation · \(Date().formatted(date: .abbreviated, time: .shortened))")
        let directory = storageURL.appendingPathComponent("Staging").appendingPathComponent(id.uuidString)
        captureDirectory = directory
        recordingWasAutomatic = automatic
        do {
            try await recorder.start(in: directory, includeSystemAudio: includeComputerAudio)
            recordingID = id
            recordingStartedAt = recorder.startedAt ?? Date()
            update(id) { $0.status = .recording; $0.date = recordingStartedAt ?? Date() }
            showNotes(for: id)
        } catch {
            if let partial = recorder.lastResult, !partial.tracks.isEmpty {
                recordingID = id
                await finishCapture(partial)
            } else { update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription } }
            if automatic { monitor.suppressCurrentMeeting() }
            errorMessage = error.localizedDescription
        }
    }

    func stopRecording(manual: Bool = true) async {
        guard !isStoppingRecording else { return }
        if manual { monitor.suppressCurrentMeeting() }
        isStoppingRecording = true
        if let result = await recorder.stop() { await finishCapture(result) }
        isStoppingRecording = false
    }

    private func finishCapture(_ result: CaptureResult) async {
        guard let id = recordingID ?? UUID(uuidString: result.directory.lastPathComponent) else { return }
        recordingID = nil; recordingStartedAt = nil; recordingWasAutomatic = false
        do {
            try await ingestCapture(result, meetingID: id)
            if !result.warnings.isEmpty { notice = result.warnings.joined(separator: "\n") }
            enqueue(id)
        } catch {
            update(id) { $0.status = .failed; $0.errorMessage = "Recording is preserved in the recovery folder: \(error.localizedDescription)" }
            errorMessage = error.localizedDescription
        }
        captureDirectory = nil
    }

    private func ingestCapture(_ result: CaptureResult, meetingID id: UUID) async throws {
        await acquireImportLock()
        defer { releaseImportLock() }
        guard let store else { throw AppError.libraryUnavailable }
        guard meetings.contains(where: { $0.id == id }) else { throw AppError.libraryUnavailable }
        var importedCount = 0
        for track in result.tracks where track.frameCount > 0 {
            await flush()
            guard let meeting = meetings.first(where: { $0.id == id }) else { throw AppError.libraryUnavailable }
            let imported = try await store.importAudio(from: track.url, into: meeting,
                source: track.role == .microphone ? .microphone : .systemAudio, offset: track.offsetSeconds)
            update(id) { current in
                for track in imported.tracks where !current.tracks.contains(where: { $0.id == track.id }) { current.tracks.append(track) }
                if let index = current.tracks.firstIndex(where: { $0.fileName == track.url.lastPathComponent }) {
                    current.tracks[index].duration = track.duration
                    current.tracks[index].createdAt = track.startedAt
                }
                current.date = result.startedAt
                current.status = .imported
                current.errorMessage = result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n")
            }
            importedCount += 1
        }
        await flush()
        // Retain empty/failed captures for diagnosis; remove staging only after durable imports.
        if importedCount > 0 { try FileManager.default.removeItem(at: result.directory) }
    }

    private func recoverRecordings() async {
        let staging = storageURL.appendingPathComponent("Staging")
        guard let folders = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            // An interrupted recovery must never resurrect something the user trashed.
            let trash = storageURL.appendingPathComponent("Trash").appendingPathComponent(id.uuidString)
            guard !FileManager.default.fileExists(atPath: trash.path) else { continue }
            do {
                guard let result = try CaptureRecovery.recover(in: folder), !result.tracks.isEmpty else { continue }
                if !meetings.contains(where: { $0.id == id }) {
                    let meeting = Meeting(id: id, title: "Recovered recording", date: result.startedAt)
                    meetings.append(meeting); persist(meeting)
                }
                try await ingestCapture(result, meetingID: id)
                notice = "Recovered an interrupted recording. Select it and choose Process to continue."
            } catch { notice = "A recording is still in recovery storage: \(error.localizedDescription)" }
        }
    }
}

enum LibrarySection: String, CaseIterable, Identifiable { case all = "All conversations", work = "Work", personal = "Personal"; var id: String { rawValue } }
enum AppError: LocalizedError {
    case libraryUnavailable, invalidAudio(String), noSpeech, saveFailed(String)
    var errorDescription: String? {
        switch self {
        case .saveFailed(let message): return "Local changes could not be saved: " + message
        case .libraryUnavailable: return "Your library is not available yet."
        case .invalidAudio(let name): return "\(name) contains no readable audio."
        case .noSpeech: return "No speech was recognized. Your recording is saved; check the source audio or try another transcription model."
        }
    }
}

enum TimeLabel {
    static func format(_ seconds: Double) -> String {
        let safe = seconds.isFinite ? min(abs(seconds), Double(Int.max / 2)) : 0
        let value = Int(safe), sign = seconds < 0 ? "−" : ""
        return sign + (value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60) : String(format: "%02d:%02d", value / 60, value % 60))
    }
}

enum MeetingExport {
    static func markdown(_ meeting: Meeting) -> String {
        var lines = ["# \(meeting.title)", "", "\(meeting.date.formatted()) · \(meeting.displayKind.title)", ""]
        if let summary = meeting.summary {
            lines += [summary.overview, ""]
            for section in summary.sections { lines += ["## \(section.heading)", "", section.body, ""] }
            if !summary.actionItems.isEmpty {
                lines += ["## Actions", ""]
                lines += summary.actionItems.map { "- [\($0.completed ? "x" : " ")] \($0.owner.map { $0 + ": " } ?? "")\($0.text)" }
            }
        }
        if !meeting.notes.isEmpty { lines += ["", "## My notes", "", meeting.notes] }
        lines += ["", "## Transcript", ""]
        lines += MeetingTimelineItem.items(in: meeting).map { item in
            switch item {
            case .speech(let segment):
                let name = meeting.speakers.first { $0.id == segment.speakerID }?.name ?? "Speaker"
                return "[\(TimeLabel.format(segment.start))] **\(name):** \(segment.text)"
            case .note(let note): return "[\(TimeLabel.format(note.time ?? 0))] **Your note:** \(note.text)"
            case .highlight(let highlight, let time): return "[\(TimeLabel.format(time))] **Marked moment:** \(highlight.text)"
            }
        }
        if let highlights = MeetingEvidence.highlights(meeting) { lines += ["", "## Marked moments and source context", "", highlights] }
        for report in meeting.alignmentReports where report.method == .unaligned {
            let track = meeting.tracks.first { $0.id == report.trackID }
            lines += ["", "## Unaligned source: \(track?.fileName ?? report.trackID.uuidString)", "", report.explanation, ""]
            lines += meeting.transcripts.filter { $0.trackID == report.trackID }.max { $0.createdAt < $1.createdAt }?.segments.map { "[\(TimeLabel.format($0.start))] \($0.text)" } ?? []
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
