import DaybookCaptions
import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookLive
import DaybookModelStore
import Foundation
import Observation
import UIKit

/// The iPhone's models: those that process its own recordings (docs/iphone.md, "Processing on this
/// iPhone": transcription, speakers, voice profiles, and summaries where it has the memory) and those
/// live captions use ("Live transcription"). Which model each role uses, downloading and removing them,
/// what this iPhone can do with them (`capabilities`), the engine and summarizer a processing job gets,
/// and the captioner a recording gets.
///
/// Models download into a store of their own (`Application Support/Models`, the Mac's layout and
/// verification, kept out of backups because they can be downloaded again), over Wi‑Fi unless the
/// person allows cellular, in background sessions that go on while the app is suspended
/// (`BackgroundModelFetcher`). Until the live models are downloaded, or where they can't run, captions
/// come from the system's speech recognizer as before; until the processing models are, recordings
/// wait for a Mac as before.
@MainActor
@Observable
final class PhoneModels {
    /// One model's state on this iPhone.
    enum Status: Equatable {
        case notDownloaded
        /// Queued until Wi‑Fi (cellular downloads are off).
        case waitingForWiFi
        case downloading(Double)
        case downloaded
        /// The last download stopped, in the system's words.
        case failed(String)
        /// It can't run here: "Not available on iPhone", "Needs an iPhone with more memory".
        case unavailable(String)

        var isTransferring: Bool {
            switch self {
            case .waitingForWiFi, .downloading: return true
            default: return false
            }
        }
    }

    let store: ModelStore
    let catalog: ModelCatalog
    /// The processing engines (DaybookIntelligence): what the processing models need to run here.
    let registry: ModelEngineRegistry
    /// Loads processing models for a job, over the same store, and lets them go after it.
    let runtime: LocalIntelligenceRuntime
    /// How much this iPhone can take on, from its memory.
    let tier: PhoneTier
    /// The most memory iOS lets Daybook use: what a summary model must fit in (`PhoneMemory`).
    let memoryLimit: UInt64
    /// Language models run here: never in the simulator, whose graphics MLX can't use.
    let runsLanguageModels: Bool
    /// Live captions' captioners, with the models they share and the voices they recognize.
    let captioners: LiveCaptioners
    /// Battery, heat, and whether the app is in front, for live captions' backing off.
    let conditions: PhoneLiveConditions
    /// The voices live captions recognize: the library's named speakers until profiles sync.
    let voices: PhoneLibraryVoices
    /// The terms the local recognizer is biased toward: the library's approved vocabulary, kept
    /// current by the app model.
    let vocabulary = LiveVocabulary()

    private(set) var inventory = ModelInventory(revisions: [])
    /// The person's choice per live role (`ModelRole.live`); defaults fill the rest.
    private(set) var selections: ModelSelections
    private(set) var progress: [String: Double] = [:]
    private(set) var waiting: Set<String> = []
    private(set) var failures: [String: String] = [:]
    /// Downloads may use cellular data. Off by default: the models are hundreds of megabytes.
    var allowsCellular: Bool {
        didSet {
            defaults.set(allowsCellular, forKey: Keys.cellular)
            (fetcher as? BackgroundModelFetcher)?.allowsCellular = allowsCellular
            if allowsCellular { resumeWaiting() }
        }
    }

    /// The app's model downloads: background sessions, so a download goes on while the app is
    /// suspended or after iOS ends it (`BackgroundModelFetcher`). One per process: iOS hands a relaunched
    /// app its sessions' events through it (`PhoneAppDelegate`).
    static let downloads = BackgroundModelFetcher()

    /// Models were downloaded, removed, or chosen: what this iPhone can process may have changed.
    @ObservationIgnored var changed: (() -> Void)?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let fetcher: any ModelArtifactFetcher
    @ObservationIgnored private let network: PhoneNetwork
    @ObservationIgnored private let physicalMemory: UInt64
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    /// Each live role's model, as last resolved, and the other recognizers to try for a language.
    @ObservationIgnored private var resolvedChoices: [ModelRole: String] = [:]
    @ObservationIgnored private var alternatives: [String] = []

    enum Keys {
        static let selections = "phone.liveModels"
        static let cellular = "phone.liveModels.cellular"
        /// Models asked for and not finished: they carry on after a relaunch.
        static let downloading = "phone.liveModels.downloading"
    }

    /// The store's folder: Application Support, out of iPhone backups.
    nonisolated static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Models", isDirectory: true)
    }

    init(root: URL = PhoneModels.defaultRoot, defaults: UserDefaults, catalog: ModelCatalog = .builtIn,
         fetcher: any ModelArtifactFetcher = PhoneModels.downloads, network: PhoneNetwork = .system,
         physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory, memoryLimit: UInt64? = nil,
         runsLanguageModels: Bool = PhoneMemory.runsLanguageModels) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var folder = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
        let store = ModelStore(root: root)
        self.store = store
        self.catalog = catalog
        registry = .standard
        runtime = LocalIntelligenceRuntime(modelsDirectory: root, store: store)
        tier = PhoneTier(physicalMemory: physicalMemory)
        self.memoryLimit = memoryLimit ?? PhoneMemory.limit() ?? AppMemoryLimit.estimate(physicalMemory: physicalMemory, increasedLimit: false)
        self.runsLanguageModels = runsLanguageModels
        self.defaults = defaults
        self.fetcher = fetcher
        self.network = network
        self.physicalMemory = physicalMemory
        let stored = defaults.data(forKey: Keys.selections).flatMap { try? JSONDecoder().decode(ModelSelections.self, from: $0) }
        selections = stored ?? ModelSelections()
        allowsCellular = defaults.bool(forKey: Keys.cellular)
        let conditions = PhoneLiveConditions()
        self.conditions = conditions
        let voices = PhoneLibraryVoices()
        self.voices = voices
        // Models go as soon as a recording ends: an iPhone keeps nothing it isn't using.
        captioners = LiveCaptioners(host: LiveModelHost(idleRelease: .zero, store: store), policy: .iPhone, voices: voices,
                                    vocabulary: vocabulary, conditions: { conditions.current })
        (fetcher as? BackgroundModelFetcher)?.allowsCellular = allowsCellular
        network.onChange { [weak self] in Task { @MainActor in self?.networkChanged() } }
        Task {
            await refresh()
            await resumeAfterRelaunch()
        }
    }

    // MARK: Which models

    /// The live roles this iPhone offers, in order.
    var roles: [ModelRole] { ModelRole.live }

    /// The roles this iPhone processes its own recordings with, in order: transcription, speakers,
    /// voice profiles (shared with live captions), and summaries.
    var processingRoles: [ModelRole] { PhoneProcessingModels.roles }

    /// Every engine this build has: the processing engines, and the live ones they don't cover.
    var engines: [ModelEngineDescriptor] {
        let processing = registry.descriptors
        return processing + LiveEngines.descriptors.filter { live in !processing.contains { $0.id == live.id } }
    }

    /// The model `role` uses: the person's choice, else the catalog's default for this iPhone. A live
    /// role's from the live defaults; a processing role's from this iPhone's tier (a summary model
    /// only where one fits in memory).
    func choice(for role: ModelRole) -> CatalogModel? {
        let key: String?
        if ModelRole.live.contains(role) {
            key = LiveModelChoices.choice(for: role, selections: selections, platform: .iOS, catalog: catalog, engines: LiveEngines.descriptors)
        } else {
            key = PhoneProcessingModels.choice(for: role, selections: selections, tier: tier, memoryLimit: memoryLimit,
                                               catalog: catalog, engines: engines)
        }
        return key.flatMap { catalog.model($0) }
    }

    /// Every model that can serve `role` here, in catalog order (a processing role's, the catalog's
    /// iPhone choices).
    func options(for role: ModelRole) -> [CatalogModel] {
        if ModelRole.live.contains(role) {
            return catalog.models(for: role).filter { $0.availability(engines: LiveEngines.descriptors, platform: .iOS).isAvailable }
        }
        return PhoneProcessingModels.options(for: role, catalog: catalog, engines: engines).compactMap { catalog.model($0) }
    }

    func select(_ key: String, for role: ModelRole) {
        selections[role] = key
        if let data = try? JSONEncoder().encode(selections) { defaults.set(data, forKey: Keys.selections) }
        resolve()
        changed?()
    }

    func status(of model: CatalogModel) -> Status {
        let availability = model.availability(engines: engines, platform: .iOS)
        if let label = availability.label { return .unavailable(label) }
        if model.serves(.summarization), !runsLanguageModels { return .unavailable("Not available in Simulator") }
        if !fits(model) { return .unavailable("Needs an iPhone with more memory") }
        if inventory.resolve(model.key) != nil { return .downloaded }
        if let fraction = progress[model.key] { return .downloading(fraction) }
        if waiting.contains(model.key) { return .waitingForWiFi }
        if let failure = failures[model.key] { return .failed(failure) }
        return .notDownloaded
    }

    /// The chosen live models not yet on this iPhone that can run here.
    var missing: [CatalogModel] { missing(in: roles) }

    var missingBytes: Int64 { missing.reduce(0) { $0 + $1.approximateBytes } }

    /// The chosen processing models for transcribing here (transcription, speakers, voice profiles)
    /// not yet on this iPhone. The summary model is downloaded on its own: it's gigabytes.
    var processingMissing: [CatalogModel] { missing(in: [.transcription, .diarization, .speakerEmbedding]) }

    var processingMissingBytes: Int64 { processingMissing.reduce(0) { $0 + $1.approximateBytes } }

    /// The chosen models for `roles` not yet on this iPhone that can run here.
    func missing(in roles: [ModelRole]) -> [CatalogModel] {
        var seen = Set<String>()
        return roles.compactMap(choice(for:)).filter { model in
            guard seen.insert(model.key).inserted else { return false }
            switch status(of: model) {
            case .notDownloaded, .failed: return true
            default: return false
            }
        }
    }

    /// What the chosen live models take on disk.
    var bytesOnDisk: Int64 { inventory.revisions.reduce(0) { $0 + $1.bytes } }

    // MARK: Downloads

    func downloadMissing() { for model in missing { download(model) } }

    /// Downloads `model` (its newest revision), now on Wi‑Fi or when cellular is allowed, else when
    /// Wi‑Fi returns. Interrupted downloads resume with the files they hadn't finished.
    func download(_ model: CatalogModel) {
        let key = model.key
        guard tasks[key] == nil, case .available = model.availability(engines: engines, platform: .iOS) else { return }
        failures[key] = nil
        remember(key, downloading: true)
        guard allowsCellular || network.condition() == .unrestricted else { waiting.insert(key); return }
        waiting.remove(key)
        guard let revision = model.latestRevision else { return }
        // A processing model is checked by its engine, as on the Mac (Community-1, which live captions
        // share, the same way); a live model by what live captions load.
        let engine = processingRoles.contains(where: model.serves) ? registry.engine(model.engine) : nil
        guard engine != nil || roles.contains(where: model.serves) else { return }
        let liveRole = roles.first(where: model.serves)
        progress[key] = 0
        let store = self.store, fetcher = self.fetcher
        tasks[key] = Task { [weak self] in
            // The files go on arriving in the background session while the app is suspended; this
            // asks for time to check and install them if they finish just as the app leaves the screen.
            let background = UIApplication.shared.beginBackgroundTask(withName: "Daybook model download")
            defer { UIApplication.shared.endBackgroundTask(background) }
            do {
                try await store.install(model, revision: revision, fetcher: fetcher,
                                        validate: { installation in
                                            if let engine { try await engine.verifyNewInstallation(installation) }
                                            else if let liveRole { try LiveEngines.validate(installation, role: liveRole) }
                                        },
                                        progress: { fraction, _ in Task { @MainActor in self?.progress[key] = fraction } })
                await self?.finished(key, error: nil)
            } catch {
                await self?.finished(key, error: error)
            }
        }
    }

    func cancel(_ model: CatalogModel) {
        tasks[model.key]?.cancel()
        waiting.remove(model.key)
        remember(model.key, downloading: false)
    }

    /// Downloads asked for and not finished, kept so they carry on after iOS ends the app; with
    /// background sessions, their files may have gone on arriving meanwhile.
    private func remember(_ key: String, downloading: Bool) {
        var keys = Set(defaults.stringArray(forKey: Keys.downloading) ?? [])
        if downloading { keys.insert(key) } else { keys.remove(key) }
        defaults.set(keys.sorted(), forKey: Keys.downloading)
    }

    /// After a relaunch: the downloads that were going on carry on, and those the system finished
    /// while the app was away are verified and installed. The background sessions are made again,
    /// which reconnects their tasks; each install waits for its files' tasks instead of starting others.
    func resumeAfterRelaunch() async {
        var keys = Set(defaults.stringArray(forKey: Keys.downloading) ?? [])
        if let downloads = fetcher as? BackgroundModelFetcher {
            for file in await downloads.inFlight() { if let key = store.variantKey(downloading: file) { keys.insert(key) } }
        }
        for key in keys.sorted() {
            guard let model = catalog.model(key), inventory.resolve(key) == nil else { remember(key, downloading: false); continue }
            download(model)
        }
    }

    /// Removes every revision of `model` and any partial download. A model a recording is using now
    /// stays until the recording ends.
    func remove(_ model: CatalogModel) async {
        cancel(model)
        await captioners.host.releaseIdle()
        do { try await store.remove(variantKey: model.key) } catch { failures[model.key] = error.localizedDescription }
        await refresh()
    }

    func refresh() async {
        inventory = await store.inventory()
        resolve()
        changed?()
    }

    private func finished(_ key: String, error: Error?) async {
        tasks[key] = nil
        progress[key] = nil
        if let error {
            if error is CancellationError || Task.isCancelled || (error as? URLError)?.code == .cancelled {
                // Cancelled, or Wi‑Fi went away: the partial download waits.
                if !allowsCellular, network.condition() != .unrestricted { waiting.insert(key) }
            } else {
                failures[key] = error.localizedDescription
                remember(key, downloading: false)
            }
        } else {
            remember(key, downloading: false)
        }
        await refresh()
    }

    private func networkChanged() {
        if network.condition() == .unrestricted || allowsCellular {
            resumeWaiting()
        } else {
            // Off Wi‑Fi: running downloads stop and wait for it.
            for (key, task) in tasks { task.cancel(); waiting.insert(key) }
        }
    }

    private func resumeWaiting() {
        for key in waiting { if let model = catalog.model(key) { download(model) } }
    }

    // MARK: Captioning

    /// Whether this iPhone has the memory a model needs. A live recognizer or speaker model: the memory
    /// it suggests. A summary model: its measured peak within what iOS lets Daybook use
    /// (`PhoneProcessingModels.fits`), and only where language models run at all. Speech and speaker
    /// models fit every iPhone; the voice-profile model too (its suggestion is for the Mac's
    /// whole-recording speaker analysis, and live captions load only its small embedding models).
    func fits(_ model: CatalogModel) -> Bool {
        if model.serves(.summarization) { return runsLanguageModels && PhoneProcessingModels.fits(model, memoryLimit: memoryLimit) }
        guard model.serves(.liveTranscription) || model.serves(.liveDiarization) else { return true }
        return LiveModelChoices.fitsMemory(model, physicalMemory: physicalMemory)
    }

    /// Each live role's model that fits this iPhone, and the recognizers to fall back on per language.
    private func resolve() {
        var choices: [ModelRole: String] = [:]
        for role in roles {
            guard let model = choice(for: role), fits(model) else { continue }
            choices[role] = model.key
        }
        resolvedChoices = choices
        alternatives = LiveModelChoices.defaults(for: .liveTranscription, platform: .iOS, catalog: catalog, engines: LiveEngines.descriptors)
            .filter { catalog.model($0).map(fits) ?? false }
    }

    /// The downloaded live models a recording in `locale` would use.
    func installedSet(for locale: Locale) -> LiveModelSet {
        LiveModelSet.resolve(resolvedChoices, inventory: inventory, locale: locale, alternatives: alternatives)
    }

    /// Saved captions the live speaker model missed some of, labelled from their recording with the
    /// downloaded models (`LiveSpeakerPass`), off the main actor at utility priority. Nil when
    /// there's nothing to label or no speaker model, or the recording couldn't be read.
    func labelSpeakers(_ captions: LiveCaptions, recording: URL) async throws -> LiveCaptions? {
        let set = installedSet(for: Locale(identifier: captions.localeIdentifier))
        guard set.diarization != nil else { return nil }
        let captioners = self.captioners
        let work = Task.detached(priority: .utility) { try await captioners.labelSpeakers(captions, recording: recording, models: set) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    /// A recording's captioner: the live models' when they're downloaded, with `fallback` (the
    /// system's recognizer) for words when the transcription model isn't, or doesn't cover `locale`.
    func captioner(locale: Locale, backlog: Int = 64, fallback: () -> (any LiveCaptioning)?) -> (any LiveCaptioning)? {
        captioners.captioner(models: installedSet(for: locale), locale: locale, backlog: backlog, timelineOrigin: nil, fallback: fallback)
    }
}

/// Whether the iPhone is on Wi‑Fi, and when that changes. Tests script it.
struct PhoneNetwork: Sendable {
    var condition: @Sendable () -> SyncNetworkCondition
    var onChange: @Sendable (@escaping @Sendable () -> Void) -> Void

    static var system: PhoneNetwork {
        let monitor = NetworkConditionMonitor()
        return PhoneNetwork(condition: { monitor.condition }, onChange: { handler in monitor.onChange { _ in handler() } })
    }
}

/// Battery, heat, Low Power Mode, and whether the app is in front, as live captions read them from
/// their own tasks: kept current from the main thread's notifications, read from anywhere.
final class PhoneLiveConditions: @unchecked Sendable {
    private let lock = NSLock()
    private var battery: Float = -1
    private var charging = false
    private var visible = true
    private var observers: [NSObjectProtocol] = []

    @MainActor init() {
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        battery = device.batteryLevel
        charging = [.charging, .full].contains(device.batteryState)
        visible = UIApplication.shared.applicationState != .background
        let center = NotificationCenter.default
        let update: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in self?.read() }
        }
        observers = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
                     UIApplication.didEnterBackgroundNotification, UIApplication.willEnterForegroundNotification]
            .map { center.addObserver(forName: $0, object: nil, queue: .main, using: update) }
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }

    @MainActor private func read() {
        let device = UIDevice.current
        let level = device.batteryLevel, state = device.batteryState
        let front = UIApplication.shared.applicationState != .background
        lock.withLock {
            battery = level
            charging = state == .charging || state == .full
            visible = front
        }
    }

    /// Now. Heat and Low Power Mode come straight from `ProcessInfo`, which is safe anywhere.
    var current: LiveConditions {
        let (battery, charging, visible) = lock.withLock { (battery, charging, visible) }
        return .system(batteryLevel: battery >= 0 ? Double(battery) : nil, isCharging: charging, isVisible: visible)
    }
}

/// The library's voice profiles, synced from the Mac: the people live captions recognize.
@MainActor
final class PhoneLibraryVoices: KnownVoiceSource {
    var metadata: () -> LibraryMetadata = { LibraryMetadata() }

    nonisolated func knownVoices(in space: String) async -> [KnownVoice] {
        let current = await MainActor.run { self.metadata() }
        return KnownVoices.fromProfiles(current, space: space)
    }
}
