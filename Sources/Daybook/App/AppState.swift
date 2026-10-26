import AppKit
import AVFoundation
import Combine
import DaybookCore
import DaybookIntelligence
import DaybookKit
import DaybookLink
import Foundation
import UniformTypeIdentifiers

/// The Mac app's state. The library itself (conversations, edits, saving, sync, requests) is
/// `library`, shared with the iPhone through DaybookKit; this adds what only the Mac does:
/// capture, the processing queue and local models, devices' wiring, windows, and panels. Library
/// members are forwarded so views and menus read them here as before.
@MainActor
final class AppState: ObservableObject {
    nonisolated static let libraryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Daybook", isDirectory: true)
    /// The library: conversations, folders, templates, vocabulary, and every edit.
    let library: LibraryController
    var meetings: [Meeting] {
        get { library.meetings }
        set { library.meetings = newValue }
    }
    @Published var selectedID: UUID?
    @Published var search = ""
    @Published var searchTokens: [SearchToken] = []
    @Published var searchScope: SearchScope = .all
    /// The sidebar selection: a library section, a folder, or a device.
    @Published var place: LibraryPlace = .section(.all)
    /// Asks the main window to present Add Device (from menus, Welcome, Settings, or a device page).
    @Published var addDeviceRequest: AddDeviceRequest?
    var libraryMetadata: LibraryMetadata { library.metadata }
    var folders: [LibraryFolder] { library.folders }
    var templates: [SummaryTemplate] { library.templates }
    var allTags: [String] { library.allTags }

    @Published var pageMode: PageMode = .summary
    /// A transcript passage the page should scroll to, from search or a bookmark.
    @Published var pageScrollTarget: UUID?
    /// Set to ask the window to confirm moving conversations to the Trash.
    @Published var trashRequestIDs: [UUID] = []
    var trashRequestID: UUID? {
        get { trashRequestIDs.count == 1 ? trashRequestIDs[0] : nil }
        set { trashRequestIDs = newValue.map { [$0] } ?? [] }
    }
    /// Several conversations selected in the list; empty when one or none is.
    @Published var multiSelection: Set<UUID> = []
    /// The folder being renamed in place in the sidebar.
    @Published var renamingFolderID: UUID?
    /// The conversation the device page is showing for a selected, already-imported recording.
    @Published var deviceConversationID: UUID?
    /// Set to move keyboard focus to a conversation's title on its page.
    @Published var titleFocusRequest: UUID?
    /// The one sheet the main window shows at a time.
    @Published var activeSheet: ActiveSheet?
    /// Set to ask the sidebar to create a folder, optionally moving conversations into it.
    @Published var newFolderRequest: NewFolderRequest?
    /// Incremented to move keyboard focus to the library search field.
    @Published var searchFocusRequest = 0
    /// View › Make Text Bigger scales only the reading surface.
    @Published var readingScale: Double { didSet { preferences.set(readingScale, forKey: "readingScale") } }
    /// App-owned so menu commands can drive it. Views observe it directly; its frequent
    /// position updates are deliberately not forwarded through this object.
    let playback = AudioPlaybackController()
    var errorMessage: String? {
        get { library.errorMessage }
        set { library.errorMessage = newValue }
    }
    var notice: String? {
        get { library.notice }
        set { library.notice = newValue }
    }
    @Published var isReady = false
    @Published var processingID: UUID?
    var readingPhotoID: UUID?
    var pendingPhotoReadings = Set<UUID>()
    /// Photos that couldn't be read wait before they're tried again (AppState+Photos.swift).
    var photoBackoff = PhotoReadingBackoff()
    var photoRetry: Task<Void, Never>?
    /// The running job's progress, throttled (`ActivityProgress`). The window is redrawn when its
    /// percent or message changes; views that draw it continuously observe `processingActivity`.
    let processingActivity = ActivityProgress(IntelligenceProgress(0, "Ready"))
    var processingProgress: IntelligenceProgress {
        get { processingActivity.value }
        set { processingActivity.set(newValue) }
    }
    @Published var processingQueue: [ProcessingJob] = []
    /// The job running now (`processingID`'s), with the request it carries out, if any.
    @Published var runningJob: ProcessingJob?
    var queuedIDs: [UUID] { processingQueue.map(\.meetingID) }
    /// Conversations the person paused; they resume only when asked.
    @Published var pausedIDs: Set<UUID> = []
    /// Conversations that start transcribing as soon as the selected models finish downloading.
    @Published var awaitingModels: Set<UUID> = []
    @Published var processingPreferences: ProcessingPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(processingPreferences.normalized) { preferences.set(data, forKey: "processingPreferences") }
            // The speaker model is the selection's diarization choice; keep the two in step.
            if modelSelections[.diarization] != processingPreferences.speakerModelID { modelSelections[.diarization] = processingPreferences.speakerModelID }
            presenceChanged()
        }
    }
    /// Variant keys ("whisper/base") with a verified revision on this Mac.
    @Published var installedModels: Set<String> = [] { didSet { presenceChanged() } }
    /// Variant key → the revision a new job freezes (the newest verified one).
    @Published var installedRevisions: [String: String] = [:]
    /// Every model Daybook knows here: built in plus the ones the person added.
    @Published var modelCatalog: ModelCatalog = .builtIn
    /// The model chosen for each role, by family and variant (docs/models.md).
    @Published var modelSelections: ModelSelections {
        didSet {
            if let data = try? JSONEncoder().encode(modelSelections) { preferences.set(data, forKey: "modelSelections") }
            if let speaker = modelSelections[.diarization], processingPreferences.speakerModelID != speaker {
                processingPreferences.speakerModelID = speaker
            }
            presenceChanged()
        }
    }
    @Published var downloadingID: String?
    /// The current download's progress, throttled like `processingActivity`.
    let downloadActivity = ActivityProgress(IntelligenceProgress(0, ""))
    var downloadProgress: IntelligenceProgress {
        get { downloadActivity.value }
        set { downloadActivity.set(newValue) }
    }
    var glossary: [GlossaryTerm] { library.glossary }
    @Published var recordingID: UUID?
    @Published var isStartingRecording = false
    @Published var isStoppingRecording = false
    @Published var recordingStartedAt: Date?
    /// The selected transcription and summary models' variant keys (`modelSelections`).
    var transcriptionModel: String {
        get { modelSelections[.transcription] ?? "" }
        set { modelSelections[.transcription] = newValue }
    }
    var summaryModel: String {
        get { modelSelections[.summarization] ?? "" }
        set { modelSelections[.summarization] = newValue }
    }
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
    @Published var processSyncedAudio: Bool { didSet { preferences.set(processSyncedAudio, forKey: "processSyncedAudio"); presenceChanged() } }
    @Published var detectSpeakers: Bool { didSet { preferences.set(detectSpeakers, forKey: "detectSpeakers"); presenceChanged() } }
    let sync: LibrarySyncController
    /// Daybook's local link to paired iPhones: pairing, record control, live progress.
    let phoneLink: PhoneLink
    /// Recorders: Soundcore Work, folders of exports, and whatever comes next.
    let devices: DeviceHub
    /// Moving a recorder between this Mac and an iPhone (AppState+Devices.swift).
    let recorderHandoff: RecorderHandoff
    /// Several recordings of one conversation: multipoint recording, matching, and enhancement.
    let sources: MultiSourceCoordinator
    let recorder = RecordingController()
    /// Live captions while this Mac records (You and Call), and their setting and language.
    let captions: LiveCaptionsController
    let captionSettings: LiveCaptionSettings
    let monitor = MeetingMonitor()
    let storageURL: URL
    private let preferences: UserDefaults
    let runtime: LocalIntelligenceRuntime
    var processingTask: Task<Void, Never>?
    private(set) var currentRequest: Task<Void, Error>?
    /// How requests from other devices are claimed and kept (tests shorten these).
    var requestTiming = RequestTiming()
    /// Conversations whose running job stopped because another device took its request over.
    var claimsLost: Set<UUID> = []
    var claimHeartbeat: Task<Void, Never>?
    var lastClaimRenewal = Date.distantPast
    var lastRenewedStage: ProcessingRequest.Stage?
    /// Conversations an iPhone recording moved out of, on their way to the Trash: not processed.
    var movedPhoneRecordings: Set<UUID> = []
    /// The last live progress sent to phones, and when; sends go out one after another, in order.
    var lastPhoneProgress: (message: LinkProcessingProgress, at: Date)?
    var phoneProgressSend: Task<Void, Never>?
    /// Recordings this Mac is making because a phone asked, by conversation.
    var phoneLeads: [UUID: CompanionLead] = [:]
    /// Starts and stops this Mac's capture when a phone asks. Tests replace it: no microphone.
    var phoneCapture = PhoneCapture()
    /// Whether this Mac may use the microphone without asking. Tests replace it.
    var microphoneAccess: () -> AVAuthorizationStatus = { AVCaptureDevice.authorizationStatus(for: .audio) }
    var wakeObserver: NSObjectProtocol?
    private var downloadTask: Task<Void, Never>?
    var subscriptions: Set<AnyCancellable> = []
    private var recordingWasAutomatic = false
    private var captureDirectory: URL?
    private var notesPanel: NotesPanelController?
    /// Bumped whenever the library's conversations change: the key for what's derived from them.
    private(set) var libraryRevision = 0
    private var visibleMemo: (place: LibraryPlace, revision: Int, meetings: [Meeting])?
    let searchMemo = LibrarySearchMemo()

    init(libraryURL: URL = AppState.libraryURL, defaults: UserDefaults = .standard) {
        let storedPreferences = defaults.data(forKey: "processingPreferences").flatMap { try? JSONDecoder().decode(ProcessingPreferences.self, from: $0) }
        var processingPreferences = storedPreferences ?? .init()
        let selections = Self.loadModelSelections(defaults: defaults, speakerModel: storedPreferences?.speakerModelID)
        processingPreferences.speakerModelID = selections[.diarization] ?? processingPreferences.speakerModelID
        modelSelections = selections
        self.processingPreferences = processingPreferences
        let sync = LibrarySyncController(localRoot: libraryURL, defaults: defaults)
        // Presence: other devices see this Mac and whether it can process. Updated as models change.
        sync.replica = .mac(displayName: ProcessingRequest.Device.currentName, canProcess: false)
        // The courier: what an iPhone records arrives through CloudKit ahead of iCloud Drive (docs/icloud-sync.md,
        // "Courier (CloudKit)"). Nil in builds without CloudKit (ad hoc, `swift run`, tests): iCloud Drive alone.
        sync.courier = CloudKitCourier.ifEntitled(containerIdentifier: sync.environment.containerIdentifier,
                                                  directory: libraryURL.appendingPathComponent("Sync/Courier", isDirectory: true),
                                                  deviceID: sync.deviceID)
        sync.courierRole = .receive
        // CKSyncEngine learns of new files through pushes, which need the app registered for them.
        sync.onCourierAvailable = { NSApplication.shared.registerForRemoteNotifications() }
        self.sync = sync
        library = LibraryController(rootURL: libraryURL, sync: sync)
        storageURL = libraryURL
        preferences = defaults
        #if DEBUG
        DeviceDemo.install()
        #endif
        let phoneLink = PhoneLink(identity: Self.linkIdentity(sync: sync, defaults: defaults))
        #if DEBUG
        // Demos never reach the network or the keychain: the link runs on loopback with keys in memory.
        if DeviceDemo.isRequested {
            let keys = MemoryLinkKeyStore()
            phoneLink.environment = .init { LinkService(identity: $0, keyStore: keys, configuration: .loopback()) }
        }
        #endif
        self.phoneLink = phoneLink
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: libraryURL.appendingPathComponent("DeviceImports", isDirectory: true))
        environment.phone.makeLinkConnection = { device in UUID(uuidString: device.id).map { PhoneLinkConnection(phoneID: $0, link: phoneLink) } }
        environment.phone.syncIsOn = { sync.folder != nil }
        environment.phone.pairedPhoneIDs = { Set(phoneLink.paired.map(\.deviceID.uuidString)) }
        devices = DeviceHub(environment: environment)
        recorderHandoff = RecorderHandoff(library: library, devices: devices, deviceClass: .mac, defaults: defaults)
        sources = MultiSourceCoordinator(defaults: defaults)
        automaticRecording = defaults.bool(forKey: "automaticRecording")
        includeComputerAudio = defaults.object(forKey: "includeComputerAudio") as? Bool ?? true
        processSyncedAudio = defaults.object(forKey: "processSyncedAudio") as? Bool ?? true
        detectSpeakers = defaults.object(forKey: "detectSpeakers") as? Bool ?? true
        readingScale = defaults.object(forKey: "readingScale") as? Double ?? 1
        runtime = LocalIntelligenceRuntime(modelsDirectory: libraryURL.appendingPathComponent("Models"), fetcher: ModelDemo.fetcher)
        let captionSettings = LiveCaptionSettings(defaults: defaults)
        self.captionSettings = captionSettings
        captions = LiveCaptionsController(store: LiveCaptionStore(libraryRoot: libraryURL),
                                          makeCaptioner: MacCaptioners.recordingFactory(settings: captionSettings))
        for publisher in [library.objectWillChange.eraseToAnyPublisher(), recorder.objectWillChange.eraseToAnyPublisher(), monitor.objectWillChange.eraseToAnyPublisher(), sync.objectWillChange.eraseToAnyPublisher(), devices.objectWillChange.eraseToAnyPublisher(), sources.objectWillChange.eraseToAnyPublisher(), phoneLink.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        }
        library.$meetings.sink { [weak self] _ in self?.libraryRevision &+= 1 }.store(in: &subscriptions)
        processingActivity.onChange = { [weak self] visible in
            if visible { self?.objectWillChange.send() }
            self?.processingProgressChanged()
        }
        downloadActivity.onChange = { [weak self] visible in if visible { self?.objectWillChange.send() } }
        searchMemo.onUpdate = { [weak self] in self?.objectWillChange.send() }
        sync.onSyncRequested = { [weak self] in await self?.synchronizeLibrary() }
        monitor.onMeetingStarted = { [weak self] candidate in
            guard let self, self.automaticRecording, self.recordingID == nil, !self.isStartingRecording else { return }
            Task { await self.startRecording(title: candidate.windowTitle, automatic: true) }
        }
        monitor.onMeetingEnded = { [weak self] in
            guard let self, self.recordingWasAutomatic else { return }
            Task { await self.stopRecording(manual: false) }
        }
        recorder.onUnexpectedStop = { [weak self] result in
            guard let self else { return }
            Task { await self.finishCapture(result) }
        }
        wireDevices()
        wirePhones()
        wireCaptions()
    }

    var selectedMeeting: Meeting? { meetings.first { $0.id == selectedID } }
    var isRecording: Bool { recordingID != nil }
    var canProcess: Bool { routedRequiredModelIDs.allSatisfy(installedModels.contains) }

    /// Selections from `modelSelections`, or, on the first launch after the model system arrived,
    /// migrated from the catalog IDs Daybook stored before ("whisper-base", "qwen-7b",
    /// "speaker-community-1"). The old keys are left in place for an older build.
    static func loadModelSelections(defaults: UserDefaults, speakerModel: String?) -> ModelSelections {
        if let data = defaults.data(forKey: "modelSelections"), var stored = try? JSONDecoder().decode(ModelSelections.self, from: data) {
            // Small tasks arrived after the model system: once, a selection without that role takes the initial one.
            if !defaults.bool(forKey: "modelSelections.smallTasksAdded") {
                defaults.set(true, forKey: "modelSelections.smallTasksAdded")
                if stored[.smallTasks] == nil, let initial = ModelRecommendations.initialSelections()[.smallTasks] {
                    stored[.smallTasks] = initial
                    if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: "modelSelections") }
                }
            }
            // Photos came later still: the same, once, for the photo role (Apple Vision).
            if !defaults.bool(forKey: "modelSelections.imageDescriptionAdded") {
                defaults.set(true, forKey: "modelSelections.imageDescriptionAdded")
                if stored[.imageDescription] == nil, let initial = ModelRecommendations.initialSelections()[.imageDescription] {
                    stored[.imageDescription] = initial
                    if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: "modelSelections") }
                }
            }
            return stored
        }
        let migrated = ModelSelections.migrating(
            legacy: [.transcription: defaults.string(forKey: "transcriptionModel"), .summarization: defaults.string(forKey: "summaryModel"),
                     .diarization: speakerModel],
            catalog: .builtIn, defaults: ModelRecommendations.initialSelections())
        if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: "modelSelections") }
        return migrated
    }
    /// Conversations in the selected place, newest first. Kept until the place or the library changes.
    var visibleMeetings: [Meeting] {
        if let memo = visibleMemo, memo.place == place, memo.revision == libraryRevision { return memo.meetings }
        let visible = meetings.filter { meeting in
            switch place {
            case .section(let section): return section.contains(meeting)
            case .folder(let id): return meeting.folderID == id
            case .device: return false
            }
        }.sorted { $0.date > $1.date }
        visibleMemo = (place, libraryRevision, visible)
        return visible
    }

    /// The library search's results for the current query, kept until it or the library changes;
    /// a large library is searched off the main actor (`LibrarySearchMemo`).
    var searchHits: [SearchHit] {
        searchMemo.hits(for: .init(text: search, tokens: searchTokens, scope: searchScope, revision: libraryRevision), in: meetings)
    }
    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty || !searchTokens.isEmpty }

    func initialize() async {
        guard !isReady else { return }
        do {
            try await library.load()
            // Installs from before the model system move into the store first, without downloading.
            let migration = await runtime.prepare()
            if !migration.failed.isEmpty {
                notice = "Some models need to be downloaded again: \(migration.failed.keys.sorted().map { ModelCatalog.builtIn.name(for: $0) }.joined(separator: ", "))."
            }
            modelCatalog = await runtime.catalog
            await refreshInstalledModels()
            selectedID = meetings.first?.id
            isReady = true
            await recoverRecordings()
            devices.start()
            sync.restore()
            if automaticRecording { monitor.startMonitoring() }
            await startPhoneLinkIfPaired()
            // Requests this Mac held when it last quit or crashed run again (or are given back).
            pickUpRequests()
        } catch { errorMessage = "Couldn’t open your library: \(error.localizedDescription)" }
    }

    /// A background import from a recorder (`selecting: false`) takes neither the place being viewed nor the selection.
    @discardableResult func newMeeting(title: String = "Untitled Conversation", date: Date = Date(), selecting: Bool = true) -> UUID {
        var folder: UUID?, placement: LibraryPlacement?
        switch place {
        case .folder(let id) where selecting: folder = id
        case .section(.work) where selecting: placement = .work
        case .section(.personal) where selecting: placement = .personal
        default: break
        }
        let id = library.newMeeting(title: title, date: date, folderID: folder, placement: placement)
        if selecting { selectedID = id }
        return id
    }

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) { library.update(id, change) }

    func resolvedTemplate(for meeting: Meeting) -> SummaryTemplate? { library.resolvedTemplate(for: meeting) }
    func saveTemplate(_ template: SummaryTemplate) { library.saveTemplate(template) }
    func removeTemplate(_ id: String) { library.removeTemplate(id) }
    func saveFolder(_ folder: LibraryFolder) { library.saveFolder(folder) }
    func removeFolder(_ id: UUID) {
        library.removeFolder(id)
        if place == .folder(id) { place = .section(.all) }
    }
    func setTags(_ id: UUID, text: String) { library.setTags(id, text: text) }

    /// While this Mac records the conversation, new paragraphs get the recording's time.
    func editNotes(_ id: UUID, text: String) {
        library.editNotes(id, text: text, captureTime: recordingID == id ? recorder.elapsedTime : nil)
    }

    func flush() async { await library.flush() }

    func chooseImport(attachTo id: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.title = id == nil ? "Import recordings" : "Add another recording of this conversation"
        panel.allowedContentTypes = [.audio, .movie]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            do { try await importFiles(panel.urls, source: .imported, attachTo: id) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func importFiles(_ urls: [URL], source: AudioSource, attachTo id: UUID?, device: DeviceRecordingIdentity? = nil) async throws {
        _ = try await importAudio(urls, source: source, attachTo: id, device: device)
    }

    /// Imports audio as new conversations, or into `id`, and returns the conversations that hold it.
    /// With a `device` identity the import is a background one from a recorder: it records where the
    /// audio came from, joins a conversation that already holds the same bytes, and never changes
    /// the selection.
    func importAudio(_ urls: [URL], source: AudioSource, attachTo id: UUID?,
                     device: DeviceRecordingIdentity? = nil) async throws -> [UUID] {
        // A cancelled import (a recorder that went away) stops waiting for the lock it never got.
        try await library.acquireLockUnlessCancelled()
        defer { releaseImportLock() }
        guard library.isLoaded else { throw AppError.libraryUnavailable }
        var meetingIDs: [UUID] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            // Validate before creating a library entry; zero-length and unsupported files remain outside the library.
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw AppError.invalidAudio(url.lastPathComponent) }
            var target = id
            if id == nil, let existing = try await library.existingMeeting(containingAudioAt: url) {
                guard device != nil else {
                    selectedID = existing.id
                    notice = "This audio is already in \(existing.title)."
                    continue
                }
                target = existing.id
            }
            var plan: SourceArrivalPlan?
            if target == nil, device != nil || sources.matchesImportedFiles {
                // Matching can compare sound for a while; this Mac's capture and other imports don't wait on it.
                releaseImportLock()
                plan = await planArrival(url: url, duration: duration, device: device)
                await acquireImportLock()
                if let chosen = plan?.attachTo, !meetings.contains(where: { $0.id == chosen }) { plan?.attachTo = nil; plan?.placement = nil; plan?.companion = nil }
            }
            target = target ?? plan?.attachTo
            let meetingID = target ?? device.map { newMeeting(title: deviceMeetingTitle(url, $0), date: deviceRecordingStart($0) ?? Date(), selecting: false) }
                ?? newMeeting(title: url.deletingPathExtension().lastPathComponent)
            await flush()
            guard let meeting = meetings.first(where: { $0.id == meetingID }) else { continue }
            let sidecar = url.deletingPathExtension().appendingPathExtension("highlights.json")
            let imported = try await library.ingest(url, into: meetingID, provenance: .file(source: source, device: device,
                sidecarURL: FileManager.default.fileExists(atPath: sidecar.path) ? sidecar : nil, duration: duration)).imported
            await sourceArrived(meetingID, before: meeting, imported: imported, url: url, device: device, plan: plan)
            if device == nil { selectedID = meetingID }
            meetingIDs.append(meetingID)
            enqueue(meetingID)
        }
        return meetingIDs
    }

    func enqueue(_ id: UUID, mode: ProcessingRequest.Mode = .newAudio) {
        guard id != recordingID, !queuedIDs.contains(id), let meeting = meetings.first(where: { $0.id == id }) else { return }
        let job = makeJob(meetingID: id, mode: mode)
        let hasNew = meeting.hasUntranscribedTranscribableAudio
        let missing = job.requiredModelIDs(hasUntranscribedAudio: hasNew).subtracting(installedModels)
        guard missing.isEmpty else {
            awaitingModels.insert(id)
            update(id) { $0.errorMessage = nil }
            // Missing models leave another device's request unclaimed, for a Mac that has them.
            releaseRequests(in: id)
            reportToPhones(id, phase: .waitingForModels)
            return
        }
        awaitingModels.remove(id)
        pausedIDs.remove(id)
        // A request for the same work is carried out by this job, so it's claimed and finished with it.
        processingQueue.append(carryingOpenRequest(job, in: meeting))
        reportToPhones(id, phase: .queued)
        runQueue()
    }

    func runQueue() {
        guard processingTask == nil, readingPhotoID == nil, downloadingID == nil, !library.isApplyingSync, !processingQueue.isEmpty else { return }
        processingTask = Task { [weak self] in
            guard let self else { return }
            while !self.processingQueue.isEmpty && !Task.isCancelled {
                let job = self.processingQueue.removeFirst(), id = job.meetingID
                // Never run a request another device holds, or one that finished elsewhere meanwhile.
                guard self.mayRun(job) else { continue }
                self.processingID = id
                self.runningJob = job
                self.claimsLost.remove(id)
                self.startClaimHeartbeat()
                self.reportToPhones(id)
                // Each job runs in its own task so pausing one conversation lets the queue continue.
                let work = Task { try await self.process(job) }
                self.currentRequest = work
                do {
                    try await work.value
                    self.finishRequests(of: self.runningJob ?? job, failure: nil)
                    self.reportToPhones(id, phase: .finished)
                }
                catch is CancellationError {
                    if self.claimsLost.remove(id) == nil {
                        self.pausedIDs.insert(id)
                        self.releaseRequests(in: id)
                        self.reportToPhones(id, phase: .paused)
                    }
                    self.update(id) { $0.status = $0.summary == nil ? .imported : .ready; $0.errorMessage = nil }
                }
                catch {
                    self.update(id) { $0.status = .failed; $0.errorMessage = error.localizedDescription }
                    self.finishRequests(of: self.runningJob ?? job, failure: error.localizedDescription)
                    self.reportToPhones(id, phase: .failed, detail: error.localizedDescription)
                }
                self.stopClaimHeartbeat()
                self.currentRequest = nil
                self.runningJob = nil
                self.processingID = nil
                // Requests that waited for this conversation, or arrived meanwhile (not after Cancel).
                if !Task.isCancelled { self.pickUpRequests(start: false) }
            }
            self.processingTask = nil
            self.processingProgress = IntelligenceProgress(0, "Ready")
            self.collectOldModelRevisions()
            self.startPendingDownload()
            self.readNextPhotosWhenIdle()
        }
    }

    /// Stops everything. Requests this Mac held go back, so another Mac can take them, and stay
    /// paused here until the person resumes them.
    func cancelProcessing() {
        for job in processingQueue where job.requestID != nil {
            pausedIDs.insert(job.meetingID)
            releaseRequests(in: job.meetingID)
        }
        // The running job's request goes back now, not when its work notices the cancellation, so
        // a save right after (quitting) has it.
        if let running = runningJob, let requestID = running.requestID, !claimsLost.contains(running.meetingID) {
            library.releaseProcessingRequest(requestID, in: running.meetingID)
        }
        processingTask?.cancel(); currentRequest?.cancel(); processingQueue.removeAll()
    }

    /// Stops work on one conversation and keeps it paused; other conversations keep processing.
    /// A request it carried out goes back, for another Mac or until it's resumed.
    func pauseProcessing(_ id: UUID) {
        if processingID == id { currentRequest?.cancel() }
        else if processingQueue.contains(where: { $0.meetingID == id }) {
            processingQueue.removeAll { $0.meetingID == id }
            pausedIDs.insert(id)
            releaseRequests(in: id)
            reportToPhones(id, phase: .paused)
        }
    }

    /// Removes a waiting conversation from the queue without marking it paused. A waiting request
    /// goes back and is paused here, so it isn't simply claimed again at the next sync.
    func cancelQueued(_ id: UUID) {
        let removed = processingQueue.filter { $0.meetingID == id }
        processingQueue.removeAll { $0.meetingID == id }
        if removed.contains(where: { $0.requestID != nil && $0.requestID != runningJob?.requestID }) {
            pausedIDs.insert(id)
            releaseRequests(in: id)
        }
    }

    /// The next step for a conversation: transcribe audio that has none yet, otherwise summarize again.
    func defaultProcessingMode(for meeting: Meeting) -> ProcessingRequest.Mode {
        meeting.hasUntranscribedTranscribableAudio ? .newAudio : .summaryOnly
    }

    /// This Mac's queue, as `ProcessingStatus` reads it.
    var processingQueueState: ProcessingStatus.LocalQueue {
        let message = processingProgress.message.lowercased()
        return ProcessingStatus.LocalQueue(running: processingID, fraction: processingProgress.fraction,
                                           identifyingSpeakers: message.contains("speaker") || message.contains("sortformer"),
                                           queued: queuedIDs, paused: pausedIDs, awaitingModels: awaitingModels, canProcess: canProcess)
    }

    /// The one status the list, the conversation page, and device pages show (shared with the iPhone).
    func processingStatus(for meeting: Meeting) -> ProcessingStatus { ProcessingStatus(meeting, queue: processingQueueState) }

    /// The template a job summarizes with: the one its request asked for, else the conversation's own.
    func template(for job: ProcessingJob, meeting: Meeting) -> SummaryTemplate? {
        guard let id = job.templateID else { return resolvedTemplate(for: meeting) }
        return SummaryTemplate.resolved(id: id, kind: meeting.kind, templates: templates)
    }

    /// The processing seam: this Mac's local models (or the tests' fake) as a `ProcessingEngine`,
    /// configured with what the job froze when it was queued.
    func processingEngine(for job: ProcessingJob) -> any ProcessingEngine {
        InferenceProcessingEngine(inference: sources.inference ?? runtime, configuration: job.engineConfiguration)
    }

    /// Runs one job. The engine turns recordings into transcripts, speakers, and a summary; this
    /// Mac decides what to process, places new recordings first, applies each result as it
    /// arrives (so a pause keeps finished recordings), and moves recordings between conversations.
    private func process(_ request: ProcessingJob) async throws {
        let id = request.meetingID
        guard library.isLoaded, let initial = meetings.first(where: { $0.id == id }) else { return }
        await flush()
        let options = request.preferences
        let engine = processingEngine(for: request)
        let terms = glossary.filter { $0.approved || $0.sourceMeetingIDs.contains(id) }.map(\.term)
        update(id) { $0.status = .transcribing; $0.errorMessage = nil }
        let activity = processingActivity
        let progress: ProcessingProgressHandler = { value in activity.report(IntelligenceProgress(value.fraction, value.message)) }
        let matching = options.matchSpeakersAcrossSources
            ? SpeakerMatchingConfiguration(minimumSimilarity: options.speakerMatchThreshold, minimumMargin: options.speakerMatchMargin) : nil
        if request.mode != .summaryOnly {
            // A synced iPhone recording finds its conversation first; one that moved isn't processed here.
            if await phoneRecordingsArrived(id, job: request) { return }
            try await placePendingSources(id)
        }
        // An original with a derived track (the microphone before echo removal) is transcribed through it.
        for track in initial.transcribableTracks where request.mode != .summaryOnly {
            try Task.checkCancellation()
            let previous = meetings.first(where: { $0.id == id })?.transcripts.filter { $0.trackID == track.id }.max { $0.createdAt < $1.createdAt }
            if request.mode == .newAudio && previous != nil { continue }
            let url = try await library.audioURL(for: track, in: id)
            let output = try await engine.transcribe(TrackProcessingInput(meetingID: id, track: track, audioURL: url, mode: request.mode,
                                                                          previousTranscript: previous, vocabulary: terms), progress: progress)
            post(output.notices)
            update(id) { $0.apply(output, matching: matching, allowSameSource: previous != nil) }
        }
        try Task.checkCancellation()
        await realign(id)
        if await sourcesAfterTranscription(id) { return }
        _ = try await readPhotos(id, engine: engine, progress: progress)
        guard let current = meetings.first(where: { $0.id == id }) else { return }
        let transcript = MeetingEvidence.transcript(current)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.noSpeech }
        update(id) { $0.status = .summarizing }
        renewRunningClaim(force: false)
        reportToPhones(id)
        let template = template(for: request, meeting: current)
        let generated = try await engine.summarize(current, template: template, vocabulary: terms, progress: progress)
        try Task.checkCancellation()
        let inputsChanged = meetings.first(where: { $0.id == id }).map {
            $0.notes != current.notes || $0.kind != current.kind || $0.templateID != current.templateID || $0.tracks != current.tracks ||
            $0.unifiedTranscript != current.unifiedTranscript || $0.speakers != current.speakers || $0.highlights != current.highlights || $0.timedNotes != current.timedNotes || $0.photos != current.photos
        } ?? false
        update(id) { meeting in
            meeting.setSummary(generated.summary)
            // Keep Auto selected so a new source or revised context can change the inferred kind.
            meeting.status = .ready
            meeting.errorMessage = generated.warnings.isEmpty ? nil : generated.warnings.joined(separator: "\n")
        }
        try await library.proposeTerms(generated.suggestedTerms, for: id)
        await flush()
        if inputsChanged { enqueue(id) }
    }

    /// Applies the sync folder's changes once nothing local is running, then queues new audio
    /// that arrived when the person processes synced audio on this Mac, and picks up requests.
    /// While this Mac carries out another device's request, passes still run: they publish the
    /// claim's heartbeat and progress, and show whether another device took the request over. The
    /// conversation being processed is protected from remote deletion and status, as a recording is.
    func synchronizeLibrary() async {
        guard isReady, sync.folder != nil, !library.isApplyingSync else { return }
        let carryingRequest = processingID != nil && runningJob?.requestID != nil
        guard processingID == nil || carryingRequest, recordingID == nil, !isStartingRecording, !isStoppingRecording else { sync.deferUntilIdle(); return }
        defer { runQueue() }
        guard let applied = await library.synchronize(protecting: processingID ?? recordingID) else { return }
        if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) { selectedID = meetings.sorted { $0.date > $1.date }.first?.id }
        reconcileClaims()
        await syncedLibraryIdentity()
        guard applied.acknowledged else { return }
        if processSyncedAudio && canProcess {
            // Only newly received sources trigger automatic work. Failed or paused local
            // jobs remain under manual control, including after a later model download.
            // Audio another device is already processing for a request is left to it.
            for id in applied.newAudio(in: meetings) where !isHeldElsewhere(id) && !movedPhoneRecordings.contains(id) { enqueue(id) }
        }
        pickUpRequests(start: false)
        requeueUnreadPhotos()
    }

    func realign(_ id: UUID) async { await library.realign(id) }

    /// Adds notices to the one the window shows, keeping every distinct one (the newest last, at
    /// most five) rather than letting each replace the one before.
    func post(_ messages: [String]) {
        var lines = (notice ?? "").components(separatedBy: "\n").filter { !$0.isEmpty }
        for message in messages where !message.isEmpty {
            lines.removeAll { $0 == message }
            lines.append(message)
        }
        guard !lines.isEmpty else { return }
        notice = lines.suffix(5).joined(separator: "\n")
    }

    func setOffset(_ id: UUID, trackID: UUID, seconds: Double?) { library.setOffset(id, trackID: trackID, seconds: seconds) }

    func download(_ modelID: String) {
        if readingPhotoID != nil {
            if !pendingDownloads.contains(modelID) { pendingDownloads.append(modelID) }
            return
        }
        guard downloadingID == nil, processingID == nil else { return }
        downloadingID = modelID; downloadProgress = IntelligenceProgress(0, "Preparing download…")
        downloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let activity = self.downloadActivity
                try await self.runtime.download(modelID: modelID) { progress in activity.report(progress) }
                await self.refreshInstalledModels()
                self.collectOldModelRevisions()
            } catch is CancellationError { self.notice = "Download cancelled." }
            catch { self.errorMessage = "Model download failed: \(error.localizedDescription)" }
            self.downloadingID = nil; self.downloadTask = nil
            if !Task.isCancelled, let next = self.pendingDownloads.first {
                self.pendingDownloads.removeFirst(); self.download(next)
            } else {
                self.pendingDownloads.removeAll()
                if self.canProcess { for id in self.awaitingModels.sorted(by: { $0.uuidString < $1.uuidString }) { self.enqueue(id) } }
                self.runQueue()
                self.readNextPhotosWhenIdle()
            }
        }
    }

    func cancelDownload() { pendingDownloads.removeAll(); downloadTask?.cancel() }

    /// Downloads every listed model that isn't installed, one after another.
    func downloadModels(_ ids: [String]) {
        let missing = ids.filter { !installedModels.contains($0) && $0 != downloadingID && !pendingDownloads.contains($0) }
        pendingDownloads += missing
        startPendingDownload()
    }
    /// The models the current choices need that aren't on this Mac yet.
    var missingSelectedModels: [String] {
        routedRequiredModelIDs.reduce(into: [String]()) { if !installedModels.contains($1) && !$0.contains($1) { $0.append($1) } }
    }
    func startPendingDownload() {
        guard downloadingID == nil, processingID == nil, readingPhotoID == nil, let next = pendingDownloads.first else { return }
        pendingDownloads.removeFirst(); download(next)
    }
    /// Models still to download after the current one.
    @Published private(set) var pendingDownloads: [String] = []
    /// Takes one waiting model off the download queue (the model manager's Cancel).
    func removePendingDownload(_ id: String) { pendingDownloads.removeAll { ModelReference($0).id == ModelReference(id).id } }
    func removeModel(_ id: String) { removeModels([id]) }

    /// Removes downloads one after another. A role that used a removed model moves to its preset's
    /// next installed choice, or keeps it and waits for a download; queued jobs keep what they froze.
    func removeModels(_ ids: [String]) {
        guard processingID == nil, downloadingID == nil else { return }
        Task {
            for id in ids {
                do {
                    try await runtime.remove(modelID: id)
                    await refreshInstalledModels()
                    applyRemovalFallback(id)
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }

    private func applyRemovalFallback(_ id: String) {
        let key = modelCatalog.model(id)?.key ?? id
        let quality = ModelPreset.current(in: self)?.quality ?? ModelRecommendations.recommendedQuality(catalog: modelCatalog)
        let preset = ModelRecommendations.preset(quality, catalog: modelCatalog, engines: runtime.engines)
        let result = modelSelections.removing(key, preset: preset, installed: installedModels)
        guard result.selections != modelSelections else { return }
        modelSelections = result.selections
        let switched = result.changes.compactMap { change -> String? in
            guard case .switched(let role, _, let to) = change else { return nil }
            return "\(Self.roleTitle(role)) now uses \(modelCatalog.name(for: to))."
        }
        if !switched.isEmpty { notice = switched.joined(separator: " ") }
    }

    private static func roleTitle(_ role: ModelRole) -> String {
        switch role {
        case .transcription: return "Transcription"
        case .diarization: return "Speaker detection"
        case .summarization: return "Summaries"
        default: return role.rawValue
        }
    }

    /// Re-reads what's installed (and the revisions new jobs freeze) from the runtime.
    func refreshInstalledModels() async {
        let usable = await runtime.installedModels()
        installedRevisions = await runtime.inventory().resolvedRevisions.filter { usable.contains($0.key) }
        installedModels = usable
    }

    /// The revisions a job queued now freezes, for its models.
    var frozenModelRevisions: [String: String] {
        let route = speechRoute
        let keys = [route.transcription.model, summaryModel, route.speakerModel] + [route.voiceEmbedder, route.transcription.fallback, photoModel?.id].compactMap { $0 }
        return installedRevisions.filter { keys.contains($0.key) }
    }

    /// The small-tasks model (titles, kind, vocabulary) a new job uses: the selection, when this
    /// device can run it now. Nil leaves those to the summary model.
    var smallTasksModel: String? {
        modelSelections[.smallTasks].flatMap { installedModels.contains($0) ? $0 : nil }
    }

    /// The model that makes voice profiles when the speaker model doesn't, chosen by capability.
    var voiceEmbeddingModel: String? { speechRoute.voiceEmbedder }

    /// Removes revisions updates replaced, once nothing selected, queued, running, or pinned uses them.
    func collectOldModelRevisions() {
        let references = (processingQueue + [runningJob].compactMap { $0 }).flatMap(\.modelReferences)
            + modelSelections.allKeys.map { ModelReference($0) }
        Task { await runtime.collectGarbage(protecting: references) }
    }

    func saveGlossaryTerm(_ term: GlossaryTerm) { library.saveGlossaryTerm(term) }
    func removeGlossaryTerm(_ id: UUID) { library.removeGlossaryTerm(id) }

    /// A bookmark at the recording's current time, while this Mac records the conversation.
    func addHighlight(_ id: UUID) {
        guard recordingID == id else { return }
        library.addBookmark(in: id, at: recorder.elapsedTime)
    }

    func addPlaybackHighlight(_ id: UUID, trackID: UUID, seconds: Double) {
        library.addBookmark(in: id, trackID: trackID, at: seconds)
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
        let directory = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)", isDirectory: true)
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    if json {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(meeting).write(to: url, options: .atomic)
                    } else {
                        try MeetingExport.write(meeting, markdownURL: url) { directory.appendingPathComponent($0.relativePath) }
                    }
                }.value
                notice = "Exported \(url.lastPathComponent)"
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func audioURL(for track: RecordingTrack, meetingID: UUID) async -> URL? {
        guard library.isLoaded else { return nil }
        do { return try await library.audioURL(for: track, in: meetingID) }
        catch { errorMessage = error.localizedDescription; return nil }
    }

    /// Imports, sync, and the Trash take turns with the library (`LibraryController`'s lock).
    private func acquireImportLock() async { await library.acquireLock() }
    private func releaseImportLock() { library.releaseLock() }

    func trashMeeting(_ id: UUID) {
        guard id != recordingID, id != processingID, !isStartingRecording, !isStoppingRecording else { return }
        processingQueue.removeAll { $0.meetingID == id }
        Task {
            do {
                guard library.isLoaded, try await library.moveToTrash(id, allowed: {
                    id != recordingID && id != processingID && !isStartingRecording && !isStoppingRecording
                }) else { return }
                if selectedID == id { selectedID = meetings.first?.id }
                notice = "Moved to the Trash."
            } catch { errorMessage = error.localizedDescription }
        }
    }
}

extension AppState {
    /// Records into `existing` when given (a notes-only conversation), otherwise into a new conversation.
    func startRecording(title: String? = nil, automatic: Bool = false, into existing: UUID? = nil) async {
        guard isReady, recordingID == nil, !isStartingRecording, !isStoppingRecording else { return }
        guard !automatic || automaticRecording else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        let defaultTitle = (title?.isEmpty == false ? title! : "Conversation") + " at \(Date().formatted(date: .omitted, time: .shortened))"
        let id = existing.flatMap { id in canRecordInto(id) ? id : nil } ?? newMeeting(title: defaultTitle)
        selectedID = id
        prepareSourceCapture(id)
        let directory = storageURL.appendingPathComponent("Staging").appendingPathComponent(id.uuidString)
        captureDirectory = directory
        recordingWasAutomatic = automatic
        prepareCaptions(for: id)
        do {
            // Record only the call app when it is known; otherwise all Mac audio.
            let callApp = includeComputerAudio
                ? monitor.activeCandidate.map(CallAppTarget.init) ?? CallAppResolver.activeCallApp(rules: monitor.rules) : nil
            try await recorder.start(in: directory, includeSystemAudio: includeComputerAudio, callApp: callApp)
            startCaptions()
            recordingID = id
            recordingStartedAt = recorder.startedAt ?? Date()
            update(id) { $0.status = .recording; $0.date = recordingStartedAt ?? Date() }
            recordingDidStart(id)
            if preferences.object(forKey: "showsFloatingNotesWhileRecording") as? Bool ?? true { showNotes(for: id) }
        } catch {
            finishCaptions()
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
        finishCaptions()
        recordingWillFinish(id, at: result.endedAt)
        recordingID = nil; recordingStartedAt = nil; recordingWasAutomatic = false
        phoneLeads[id] = nil
        do {
            try await ingestCapture(result, meetingID: id)
            sourcesAfterCapture(id, startedAt: result.startedAt, captureID: result.id)
            if !result.warnings.isEmpty { notice = result.warnings.joined(separator: "\n") }
            enqueue(id)
        } catch {
            update(id) { $0.status = .failed; $0.errorMessage = "Recording is preserved in the recovery folder: \(error.localizedDescription)" }
            errorMessage = error.localizedDescription
        }
        captureDirectory = nil
    }

    private func ingestCapture(_ result: CaptureResult, meetingID id: UUID) async throws {
        guard library.isLoaded, meetings.contains(where: { $0.id == id }) else { throw AppError.libraryUnavailable }
        // Remove the call's echo from the microphone before anything is transcribed. The captured
        // originals are only read; the cleaned microphone becomes a derived track. This touches
        // only the staging folder, so other imports don't wait for it.
        if result.echoRemoval == nil && result.tracks.contains(where: { $0.role == .systemAudio }) {
            update(id) { if $0.status == .recording { $0.status = .transcribing } }
        }
        let result = await detachedWork(priority: .userInitiated) { CaptureFinalizer.finalize(result) }
        await acquireImportLock()
        defer { releaseImportLock() }
        guard library.isLoaded, meetings.contains(where: { $0.id == id }) else { throw AppError.libraryUnavailable }
        var importedCount = 0
        var microphoneTrackID: UUID?
        for track in result.tracks where track.frameCount > 0 {
            let stored = try await importCaptured(track.url, source: track.role == .microphone ? .microphone : .systemAudio,
                offset: track.offsetSeconds, duration: track.duration, startedAt: track.startedAt,
                details: CaptureFinalizer.details(for: track, in: result), result: result, meetingID: id)
            if track.role == .microphone { microphoneTrackID = stored }
            importedCount += 1
        }
        var linked = true
        for derived in result.derivedTracks ?? [] where derived.derivedFrom == .microphone && derived.frameCount > 0 {
            // Unlinked, it would be transcribed beside the original; keep staging so recovery retries.
            guard let original = microphoneTrackID else { linked = false; continue }
            _ = try await importCaptured(derived.url, source: .microphone, offset: derived.offsetSeconds, duration: derived.duration,
                startedAt: derived.startedAt, details: CaptureFinalizer.details(for: derived, in: result), result: result,
                meetingID: id, derivedFrom: original, processing: derived.processing)
            importedCount += 1
        }
        try await library.flushDurably([id])
        // Retain empty/failed captures for diagnosis; remove staging only after durable imports.
        if importedCount > 0 && linked { try FileManager.default.removeItem(at: result.directory) }
    }

    /// Imports one captured file and returns its library track. Capture details and, for a derived
    /// track, its original are recorded on the track.
    private func importCaptured(_ url: URL, source: AudioSource, offset: TimeInterval, duration: TimeInterval, startedAt: Date,
                                details: TrackCaptureDetails, result: CaptureResult, meetingID id: UUID,
                                derivedFrom: UUID? = nil, processing: String? = nil) async throws -> UUID? {
        let provenance = RecordingProvenance(source: source, offset: offset, duration: duration, startedAt: startedAt, capture: details,
                                             derivedFrom: derivedFrom, processing: processing, conversationDate: result.startedAt,
                                             message: result.warnings.isEmpty ? nil : result.warnings.joined(separator: "\n"))
        return try await library.ingest(url, into: id, provenance: provenance).track?.id
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
                    library.add(Meeting(id: id, title: "Recovered recording", date: result.startedAt))
                }
                try await ingestCapture(result, meetingID: id)
                notice = "Recovered an interrupted recording."
            } catch { notice = "Couldn’t recover a recording: \(error.localizedDescription)" }
        }
    }
}

enum ActiveSheet: Identifiable, Equatable {
    case versionHistory, reviewCorrections
    /// Adjust timing for a recording; nil picks the first one that needs it.
    case adjustTiming(UUID?)
    /// One recording's own transcript, unchanged by corrections or merging.
    case originalTranscript(UUID)
    var id: String {
        switch self {
        case .versionHistory: return "history"
        case .reviewCorrections: return "corrections"
        case .adjustTiming(let id): return "timing:\(id?.uuidString ?? "")"
        case .originalTranscript(let id): return "original:\(id.uuidString)"
        }
    }
}

struct NewFolderRequest: Identifiable, Equatable {
    let id = UUID()
    var moving: [UUID] = []
}

/// The library's errors, shared with the devices that import into it.
typealias AppError = DaybookError
