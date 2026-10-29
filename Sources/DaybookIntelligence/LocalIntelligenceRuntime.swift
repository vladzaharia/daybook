import DaybookCore
import DaybookKit
import Foundation

/// Own one instance for the application. It coordinates the catalog (data), the store (files), and
/// the engines (code): it resolves a model reference to a verified install, asks the model's engine
/// to load it, and runs it through the role's protocol. Expensive operations are serialized;
/// actor reentrancy is guarded so a model cannot be removed while in use.
///
/// Residency: at most one loaded model per role. Loading a model whose engine is exclusive (MLX)
/// releases every other model; loading any other model releases exclusive ones. That keeps today's
/// behaviour: speech and speaker models share memory, the language model has it to itself. A system
/// model (Apple Foundation Models) lives outside Daybook's memory: it neither releases nor is released.
///
/// Models Daybook holds itself are released once nothing has used them for `idleUnloadDelay`, and at
/// once when the system warns that memory is short (after the job using them, if one is running), so
/// an always-running menu-bar app doesn't keep a 16–34 GB language model resident.
public actor LocalIntelligenceRuntime {
    public let modelsDirectory: URL
    public let store: ModelStore
    public nonisolated let registry: ModelEngineRegistry
    /// The engines this build runs, for availability ("Needs a newer Daybook") on any actor. Read
    /// afresh each time: a system engine's availability changes with the device's settings.
    public nonisolated var engines: [ModelEngineDescriptor] { registry.descriptors }
    /// Built in plus the person's manifest.
    public private(set) var catalog: ModelCatalog
    private let builtIn: ModelManifestReader.Result?
    private let fetcher: any ModelArtifactFetcher
    private var busy = false
    private var loaded: [ModelRole: Loaded] = [:]
    /// How long loaded models stay after the last operation before they're released; the next
    /// operation loads them again.
    public private(set) var idleUnloadDelay: Duration = .seconds(120)
    /// Bumped when an operation starts, so an idle release scheduled before it stands down.
    private var activity = 0
    private var idleRelease: Task<Void, Never>?
    /// Memory ran short while an operation held the models: release them when it ends.
    private var releaseWhenIdle = false
    private let memoryPressure: DispatchSourceMemoryPressure

    private struct Loaded {
        let key: ModelInstallKey
        let residency: ModelResidency
        let model: any LoadedModel
        let lease: UUID
    }

    /// - Parameters:
    ///   - builtIn: the built-in manifest; nil reads DaybookKit's ModelCatalog folder.
    ///   - fetcher: how files arrive; nil uses Hugging Face through HubApi.
    public init(modelsDirectory: URL, registry: ModelEngineRegistry = .standard, builtIn: ModelManifestReader.Result? = nil,
                fetcher: (any ModelArtifactFetcher)? = nil) {
        self.modelsDirectory = modelsDirectory
        self.store = ModelStore(root: modelsDirectory)
        self.registry = registry
        self.builtIn = builtIn
        self.fetcher = fetcher ?? HubSnapshotFetcher()
        self.catalog = Self.makeCatalog(builtIn: builtIn, user: UserModelManifest(url: modelsDirectory.appendingPathComponent("UserModels.json")))
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        memoryPressure = source
        source.setEventHandler { [weak self] in Task { await self?.memoryPressureRaised() } }
        source.resume()
    }

    deinit { memoryPressure.cancel() }

    /// How long models stay loaded once nothing uses them.
    public func setIdleUnloadDelay(_ delay: Duration) {
        idleUnloadDelay = delay
        if !busy { scheduleIdleRelease() }
    }

    private var userManifest: UserModelManifest { UserModelManifest(url: modelsDirectory.appendingPathComponent("UserModels.json")) }

    private static func makeCatalog(builtIn: ModelManifestReader.Result?, user: UserModelManifest) -> ModelCatalog {
        let base: ModelManifestReader.Result
        if let builtIn { base = builtIn }
        else if let read = try? ModelCatalog.readBuiltInManifest() { base = read }
        else { base = .init(manifest: ModelManifest(), warnings: ["The built-in model list couldn’t be read."]) }
        let personal = user.read()
        return ModelCatalog(builtIn: base.manifest, user: personal.manifest, warnings: base.warnings + personal.warnings)
    }

    /// Re-reads the person's manifest.
    @discardableResult
    public func reloadCatalog() -> ModelCatalog {
        catalog = Self.makeCatalog(builtIn: builtIn, user: userManifest)
        return catalog
    }

    // MARK: Start-up

    /// Moves installs from before the model system into the store, without downloading. Run once
    /// at launch, before processing; safe to run again.
    @discardableResult
    public func prepare() async -> ModelMigrationReport {
        guard FileManager.default.fileExists(atPath: modelsDirectory.path) else { return ModelMigrationReport() }
        await store.removeStaleStaging()
        let registry = registry
        return await store.migrateLegacyInstalls(catalog: catalog) { installation in
            guard let engine = registry.engine(ModelEngineID(installation.key.engine)) else {
                throw LocalIntelligenceError.unknownModel(installation.key.variantKey)
            }
            try engine.validate(installation)
        }
    }

    // MARK: Inventory

    public func inventory() async -> ModelInventory { await store.inventory() }

    /// Variant keys with a verified revision this build can run, plus system models (nothing to
    /// download) that this device provides.
    public func installedModels() async -> Set<String> {
        let inventory = await store.inventory()
        var usable = Set(inventory.revisions.filter { revision in
            guard revision.isReady, registry.engine(ModelEngineID(revision.key.engine)) != nil else { return false }
            return catalog.model(revision.key.variantKey).map { $0.availability(engines: engines).isAvailable } ?? true
        }.map(\.key.variantKey))
        for model in catalog.models where model.isSystemModel && model.availability(engines: engines).isAvailable {
            if let engine = registry.engine(model.engine), (try? engine.validate(systemInstallation(model))) != nil { usable.insert(model.key) }
        }
        return usable
    }

    /// A model the operating system provides (Apple Foundation Models): no files, no revisions.
    /// Its engine's `validate` decides whether this device has it.
    private func systemInstallation(_ model: CatalogModel) -> ModelInstallation {
        let revision = ModelRevisionEntry(id: "system", artifacts: [])
        return ModelInstallation(receipt: ModelInstallReceipt(model: model, revision: revision, installedAt: .distantPast),
                                 directory: modelsDirectory)
    }

    public func diskUsage() async -> ModelDiskUsage { await store.diskUsage() }

    // MARK: Downloads

    /// Downloads a variant's newest revision (or the revision `modelID` names with "@"), beside any
    /// revision already installed. Downloads resume; every file is verified before it counts.
    public func download(modelID: String, progress: @escaping IntelligenceProgressHandler = { _ in }) async throws {
        try begin(); defer { finish() }
        let reference = ModelReference(modelID)
        guard let model = catalog.model(reference.id) else { throw LocalIntelligenceError.unknownModel(modelID) }
        let availability = model.availability(engines: engines)
        guard availability.isAvailable else { throw LocalIntelligenceError.unavailable(model: model.key, reason: availability.label ?? "") }
        if model.isSystemModel { progress(.init(1, "Already available")); return }
        guard let engine = registry.engine(model.engine),
              let revision = reference.revision.flatMap(model.revision) ?? model.latestRevision else {
            throw LocalIntelligenceError.unknownModel(modelID)
        }
        try await store.install(model, revision: revision, fetcher: fetcher,
                                validate: { try await engine.verifyNewInstallation($0) },
                                progress: { progress(.init($0, $1)) })
    }

    /// Removes every revision of a variant and its partial download. The selection fallback
    /// (`ModelSelections.removing`) is the caller's.
    public func remove(modelID: String) async throws {
        try begin(); defer { finish() }
        let key = catalog.model(modelID)?.key ?? ModelReference(modelID).id
        guard catalog.model(modelID) != nil || key.contains("/") else { throw LocalIntelligenceError.unknownModel(modelID) }
        for (role, entry) in loaded where entry.key.variantKey == key { await release(role) }
        try await store.remove(variantKey: key)
    }

    public func unload() async throws {
        try begin(); defer { finish() }
        for role in Array(loaded.keys) { await release(role) }
    }

    /// The system warned that memory is short: models Daybook holds are released now, or as soon as
    /// the operation using them ends. System models (Apple Vision, Foundation Models) stay.
    func memoryPressureRaised() {
        if busy { releaseWhenIdle = true } else { releaseResidentModels() }
    }

    /// Whether a model Daybook holds itself is loaded (tests).
    var holdsResidentModels: Bool { loaded.values.contains { $0.residency != .system } }

    /// Removes revisions newer ones replaced, keeping those `protecting` references resolve to
    /// (selections, queued jobs), pinned ones, and loaded ones. Nothing is removed while an
    /// operation runs: a revision it's resolving or loading isn't leased yet. Callers try again later.
    @discardableResult
    public func collectGarbage(protecting references: [ModelReference]) async -> [ModelInstallKey] {
        guard !busy else { return [] }
        let inventory = await store.inventory()
        var keep = Set<ModelInstallKey>()
        for reference in references {
            let key = catalog.model(reference.id)?.key ?? reference.id
            if let resolved = inventory.resolve(key, revision: reference.revision) { keep.insert(resolved.key) }
            if let revision = reference.revision {
                keep.formUnion(inventory.revisions(of: key).filter { $0.key.revision == revision }.map(\.key))
            }
        }
        return await store.collectGarbage(protecting: keep)
    }

    // MARK: Updates and added models

    /// Opt-in: asks Hugging Face for newer revisions of `models` (default: the installed ones).
    public func checkForUpdates(client: any ModelHubClient, models keys: Set<String>? = nil) async -> [ModelUpdate] {
        let installed = await installedModels()
        let tracked = keys ?? installed
        let candidates = catalog.models.filter { tracked.contains($0.key) && $0.availability(engines: engines).isAvailable }
        return await ModelUpdateChecker(client: client).check(candidates)
    }

    /// Records an update's revision in the person's manifest and downloads it beside the current
    /// one. Once verified, selections of the variant resolve to it; jobs that froze the old
    /// revision keep it until garbage collection finds it unused.
    public func installUpdate(_ update: ModelUpdate, progress: @escaping IntelligenceProgressHandler = { _ in }) async throws {
        guard let model = catalog.model(update.model) else { throw LocalIntelligenceError.unknownModel(update.model) }
        if model.revision(update.revision.id) == nil {
            let current = userManifest.read().manifest ?? ModelManifest()
            try userManifest.write(UserModelManifest.adding(update.revision, to: model, in: current))
            reloadCatalog()
        }
        try await download(modelID: "\(update.model)@\(update.revision.id)", progress: progress)
    }

    /// Adds a model from Hugging Face after its engine has checked it, labelled "Added by you".
    /// Nothing is downloaded until `download(modelID:)`.
    @discardableResult
    public func addModel(_ request: ModelAdditionRequest, client: any ModelHubClient) async throws -> CatalogModel {
        guard let engine = registry.engine(request.engine) else { throw ModelAdditionError.unknownEngine(request.engine) }
        guard engine.descriptor.roles.contains(request.role) else { throw ModelAdditionError.unsupportedRole(request.role, request.engine) }
        let info = try? await client.info(repository: request.repository)
        if info?.gated == true { throw ModelAdditionError.gated(request.repository) }
        let snapshot = try await ModelRepositorySnapshot.load(request.repository, revision: request.revision, client: client)
        let proposal = try await engine.proposeAddition(request, repository: snapshot)
        if let existing = catalog.models.first(where: { model in
            model.variant.revisions.contains { $0.artifacts == proposal.artifacts }
        }) { throw ModelAdditionError.duplicate(existing.name) }

        let familyID = request.familyID ?? ModelIdentifier.slug(request.repository.split(separator: "/").last.map(String.init) ?? request.repository)
        let existingFamily = catalog.models.first { $0.familyID == familyID }
        var variantID = ModelIdentifier.slug(request.variantName)
        while catalog.model("\(familyID)/\(variantID)") != nil { variantID += "-2" }
        let day = snapshot.commit.date.map { ModelUpdateChecker.day.string(from: $0) }
        let revision = ModelRevisionEntry(id: snapshot.commit.id, releaseDate: day, summary: snapshot.commit.title,
                                          artifacts: proposal.artifacts)
        let license = ModelIdentifier.license(from: info, repository: request.repository)
        let variant = ModelVariantEntry(
            id: variantID, name: request.variantName, engine: request.engine, roles: [request.role], license: license,
            homepage: "https://huggingface.co/\(request.repository)", releaseDate: day,
            recommendedMemoryGB: proposal.recommendedMemoryGB, capabilities: proposal.capabilities,
            engineOptions: proposal.engineOptions, minimumEngineVersion: engine.descriptor.version, revisions: [revision])
        let family = ModelFamilyEntry(id: familyID, name: request.familyName ?? existingFamily?.familyName ?? request.variantName,
                                      maker: existingFamily?.maker ?? request.repository.split(separator: "/").first.map(String.init),
                                      engine: request.engine, roles: [request.role])
        let current = userManifest.read().manifest ?? ModelManifest()
        try userManifest.write(UserModelManifest.adding(variant, to: family, in: current))
        reloadCatalog()
        guard let added = catalog.model("\(familyID)/\(variantID)") else { throw LocalIntelligenceError.unknownModel(variantID) }
        return added
    }

    /// Removes a model the person added: its files and its manifest entry.
    public func removeAddedModel(_ variantKey: String) async throws {
        try await remove(modelID: variantKey)
        if let current = userManifest.read().manifest {
            try userManifest.write(UserModelManifest.removing(variantKey, from: current))
            reloadCatalog()
        }
    }

    // MARK: Running

    public func transcribe(url: URL, model: ModelReference, glossary: [String] = [],
                           progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> RecognitionResult {
        try await transcribe(url: url, model: model, glossary: glossary, language: nil, progress: progress)
    }

    /// `language` (a BCP-47 code) reaches transcribers that take a hint; nil detects it.
    public func transcribe(url: URL, model: ModelReference, glossary: [String] = [], language: String?,
                           progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> RecognitionResult {
        try begin(); defer { finish() }
        let (loaded, provenance) = try await use(model, for: .transcription, message: "Loading speech model locally", progress: progress)
        guard let transcriber = loaded as? any Transcribing else {
            throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "transcription")
        }
        var result = try await transcriber.transcribe(url: url, glossary: glossary, language: language, progress: progress)
        result.provenance = provenance
        return result
    }

    public func diarize(url: URL, model: ModelReference, options: SpeakerAnalysisOptions = .init(),
                        progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> SpeakerAnalysis {
        try begin(); defer { finish() }
        let (loaded, provenance) = try await use(model, for: .diarization, message: nil, progress: progress)
        guard let diarizer = loaded as? any Diarizing else {
            throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "speaker detection")
        }
        var analysis = try await diarizer.diarize(url: url, options: options, progress: progress)
        analysis.provenance = provenance
        return analysis
    }

    public func embedVoices(url: URL, analysis: SpeakerAnalysis, model: ModelReference,
                            progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> SpeakerAnalysis {
        try begin(); defer { finish() }
        let (loaded, provenance) = try await use(model, for: .speakerEmbedding, message: nil, progress: progress)
        guard let embedder = loaded as? any EmbeddingVoices else {
            throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "voice profiles")
        }
        var result = try await embedder.embedVoices(url: url, analysis: analysis, progress: progress)
        result.embeddingProvenance = provenance
        result.provenance = analysis.provenance
        return result
    }

    public func summarize(transcript: String, notes: String, template: MeetingKind = .auto, glossary: [String] = [],
                          model: ModelReference, templateInstructions: String? = nil, highlightEvidence: String? = nil,
                          progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> GeneratedMeetingNotes {
        try await summarize(transcript: transcript, notes: notes, template: template, glossary: glossary, model: model,
                            templateInstructions: templateInstructions, highlightEvidence: highlightEvidence, photos: [], progress: progress)
    }

    /// The same, with photos the summary may place under its sections.
    public func summarize(transcript: String, notes: String, template: MeetingKind = .auto, glossary: [String] = [],
                          model: ModelReference, templateInstructions: String? = nil, highlightEvidence: String? = nil,
                          photos: [PhotoEvidence],
                          progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> GeneratedMeetingNotes {
        try begin(); defer { finish() }
        let (loaded, provenance) = try await use(model, for: .summarization, message: "Loading language model locally", progress: progress)
        guard let summarizer = loaded as? any Summarizing else {
            throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "summaries")
        }
        try Task.checkCancellation()
        var notes = try await summarizer.summarize(
            SummaryRequest(transcript: transcript, notes: notes, template: template, glossary: glossary,
                           templateInstructions: templateInstructions, highlightEvidence: highlightEvidence, modelID: model.id,
                           photos: photos),
            progress: progress)
        notes.provenance = provenance
        return notes
    }

    /// What Apple's built-in sound classifier hears in a recording, off the actor: it loads no model
    /// Daybook manages, so it neither waits for nor holds one.
    public nonisolated func classifySound(url: URL, progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> BackgroundAudioAnalysis? {
        try await detachedWork(priority: .userInitiated) { try SoundClassifier.analyze(url: url, progress: progress) }
    }

    /// Titles, the meeting kind, and vocabulary suggestions from a small-tasks model (Apple
    /// Foundation Models). Throws when the model can't run here; callers keep the summarizer's.
    public func performSmallTasks(transcript: String, notes: String, template: MeetingKind = .auto, glossary: [String] = [],
                                  model: ModelReference,
                                  progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> SmallTaskResult {
        try begin(); defer { finish() }
        let (loaded, provenance) = try await use(model, for: .smallTasks, message: nil, progress: progress)
        guard let worker = loaded as? any PerformingSmallTasks else {
            throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "titles")
        }
        var result = try await worker.performSmallTasks(
            SmallTaskRequest(transcript: transcript, notes: notes, template: template, glossary: glossary, modelID: model.id),
            progress: progress)
        result.provenance = provenance
        return result
    }

    /// Photos to captions, text, labels, sharpness, and near copies (`DescribingImages`): Apple Vision,
    /// or a vision-language model for captions. One result per request, in order.
    public func describeImages(_ requests: [ImageDescriptionRequest], model: ModelReference,
                               progress: @escaping IntelligenceProgressHandler = { _ in }) async throws -> [ImageDescription] {
        try begin(); defer { finish() }
        let (loaded, provenance) = try await use(model, for: .imageDescription, message: "Loading photo model locally", progress: progress)
        guard let describer = loaded as? any DescribingImages else {
            throw LocalIntelligenceError.unsupportedRole(model: model.id, role: "photos")
        }
        var results = try await describer.describe(requests, progress: progress)
        for index in results.indices { results[index].provenance = provenance }
        return results
    }

    // MARK: Loading

    /// Resolves `reference` to a verified install (failing before anything is released or read),
    /// applies the residency rule, and loads it unless it is already loaded for `role`.
    private func use(_ reference: ModelReference, for role: ModelRole, message: String?,
                     progress: @escaping IntelligenceProgressHandler) async throws -> (any LoadedModel, ModelProvenance) {
        let (installation, engine) = try await resolve(reference, for: role)
        let provenance = installation.provenance(engine: engine.descriptor)
        switch engine.descriptor.residency {
        case .exclusive:
            for (other, entry) in loaded where other != role && entry.residency != .system { await release(other) }
        case .shared:
            for (other, entry) in loaded where other != role && entry.residency == .exclusive { await release(other) }
        case .system:
            break
        }
        if let current = loaded[role], current.key == installation.key { return (current.model, provenance) }
        await release(role)
        // Leased before loading, so garbage collection can't remove the revision while it loads.
        let lease = await store.lease([installation.key])
        if let message { progress(.init(0, message)) }
        let model: any LoadedModel
        do { model = try await engine.load(installation, role: role, progress: progress) }
        catch { await store.endLease(lease); throw error }
        loaded[role] = Loaded(key: installation.key, residency: engine.descriptor.residency, model: model, lease: lease)
        return (model, provenance)
    }

    private func resolve(_ reference: ModelReference, for role: ModelRole) async throws -> (ModelInstallation, any ModelEngine) {
        let variantKey: String
        if let model = catalog.model(reference.id) {
            guard model.serves(role) else { throw LocalIntelligenceError.unsupportedRole(model: reference.id, role: role.rawValue) }
            let availability = model.availability(engines: engines)
            guard availability.isAvailable else { throw LocalIntelligenceError.unavailable(model: model.key, reason: availability.label ?? "") }
            if model.isSystemModel, let engine = registry.engine(model.engine) {
                let installation = systemInstallation(model)
                do { try engine.validate(installation) } catch { throw LocalIntelligenceError.modelNotInstalled(reference.id) }
                return (installation, engine)
            }
            variantKey = model.key
        } else if reference.id.contains("/") {
            variantKey = reference.id   // an install the catalog no longer lists still runs from its receipt
        } else {
            throw LocalIntelligenceError.unknownModel(reference.id)
        }
        guard let installed = await store.inventory().resolve(variantKey, revision: reference.revision),
              let engine = registry.engine(ModelEngineID(installed.key.engine)) else {
            throw LocalIntelligenceError.modelNotInstalled(reference.id)
        }
        do { try engine.validate(installed.installation) }
        catch { throw LocalIntelligenceError.modelNotInstalled(reference.id) }
        return (installed.installation, engine)
    }

    private func release(_ role: ModelRole) async {
        guard let entry = loaded.removeValue(forKey: role) else { return }
        entry.model.unload()
        await store.endLease(entry.lease)
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !busy else { throw LocalIntelligenceError.busy }
        busy = true
        activity &+= 1
        idleRelease?.cancel(); idleRelease = nil
    }

    /// An operation ended: release now if memory ran short meanwhile, otherwise once idle.
    private func finish() {
        busy = false
        if releaseWhenIdle {
            releaseWhenIdle = false
            releaseResidentModels()
        } else {
            scheduleIdleRelease()
        }
    }

    private func scheduleIdleRelease() {
        idleRelease?.cancel(); idleRelease = nil
        guard holdsResidentModels else { return }
        let generation = activity, delay = idleUnloadDelay
        idleRelease = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            await self?.releaseIfIdle(since: generation)
        }
    }

    private func releaseIfIdle(since generation: Int) {
        guard !busy, activity == generation else { return }
        releaseResidentModels()
    }

    /// Releases every model Daybook holds itself, at once: the entries leave `loaded` before any
    /// await, so an operation starting meanwhile loads afresh. Their leases end right after.
    private func releaseResidentModels() {
        idleRelease?.cancel(); idleRelease = nil
        let resident = loaded.filter { $0.value.residency != .system }
        guard !resident.isEmpty else { return }
        for role in resident.keys { loaded[role] = nil }
        for entry in resident.values { entry.model.unload() }
        let leases = resident.values.map(\.lease), store = store
        Task { for lease in leases { await store.endLease(lease) } }
    }
}
