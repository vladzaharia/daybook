import AppKit
import AVFoundation
import DaybookCore
import DaybookDevices
import DaybookIntelligence
import DaybookKit
import DaybookLink
import DaybookUI
import Foundation
import Observation
import os
import UniformTypeIdentifiers

/// The Mac app's state. The library itself (conversations, edits, saving, sync, requests) is
/// `library`, shared with the iPhone through DaybookKit; this adds what only the Mac does:
/// capture, the processing queue and local models, devices' wiring, windows, and panels. Library
/// members are forwarded so views and menus read them here as before.
///
/// It's `@Observable`, like everything views read here (the library, sync, devices, the recorder, the
/// link): a view redraws for the properties it reads, and nothing is forwarded by hand. Memos and tasks
/// are `@ObservationIgnored`, so working something out never redraws anything.
@MainActor
@Observable
final class AppState {
    /// `Application Support/Daybook` for the app; `Daybook Development` for unbundled runs (`LibraryLocation`).
    nonisolated static let libraryURL = LibraryLocation.standard
    /// The library: conversations, folders, templates, vocabulary, and every edit.
    let library: LibraryController
    /// The library's conversations. Every change goes through `library` (`update`, `add`, …), which saves it.
    var meetings: [Meeting] { library.meetings }
    var selectedID: UUID?
    var search = ""
    var searchTokens: [SearchToken] = []
    var searchScope: SearchScope = .all
    /// The sidebar selection: a library section, a folder, or a device.
    var place: LibraryPlace = .section(.all)
    /// Asks the main window to present Add Device (from menus, Welcome, Settings, or a device page).
    var addDeviceRequest: AddDeviceRequest?
    var libraryMetadata: LibraryMetadata { library.metadata }
    var folders: [LibraryFolder] { library.folders }
    var templates: [SummaryTemplate] { library.templates }
    var allTags: [String] { library.allTags }

    var pageMode: PageMode = .summary
    /// A transcript passage the page should scroll to, from search or a bookmark.
    var pageScrollTarget: UUID?
    /// Set to ask the window to confirm moving conversations to the Trash.
    var trashRequestIDs: [UUID] = []
    var trashRequestID: UUID? {
        get { trashRequestIDs.count == 1 ? trashRequestIDs[0] : nil }
        set { trashRequestIDs = newValue.map { [$0] } ?? [] }
    }
    /// Several conversations selected in the list; empty when one or none is.
    var multiSelection: Set<UUID> = []
    /// The folder being renamed in place in the sidebar.
    var renamingFolderID: UUID?
    /// The conversation the device page is showing for a selected, already-imported recording.
    var deviceConversationID: UUID?
    /// Set to move keyboard focus to a conversation's title on its page.
    var titleFocusRequest: UUID?
    /// The one sheet the main window shows at a time.
    var activeSheet: ActiveSheet?
    /// Set to ask the sidebar to create a folder, optionally moving conversations into it.
    var newFolderRequest: NewFolderRequest?
    /// Incremented to move keyboard focus to the library search field.
    var searchFocusRequest = 0
    /// Incremented to ask the main window for the inspector (Tags…, the byline's people), which a window too narrow
    /// for it widens to show (`LibraryView`).
    var inspectorRequest = 0
    /// A moment's word over the page after something that leaves nothing else to see: Copy Summary's "Copied", from
    /// whichever menu it came (`ConfirmationBeat`).
    var confirmation: ConfirmationBeat?
    /// View › Make Text Bigger scales only the reading surface.
    var readingScale: Double { didSet { preferences.set(readingScale, forKey: Preference.readingScale) } }
    /// App-owned so menu commands can drive it. Only what shows the playhead reads its position, which
    /// moves ten times a second; the Controls menu reads only whether it's playing.
    let playback = AudioPlaybackController()
    /// What couldn't be done, for the window's alert (`report(_:_:_:)`, AppProblem.swift).
    var problem: AppProblem?
    /// The alert's sentence: a reported problem's, else a library save that failed.
    var errorMessage: String? { problem?.message ?? library.errorMessage }
    var notice: String? {
        get { library.notice }
        set {
            library.notice = newValue
            if newValue == nil { noticeAction = nil }
        }
    }
    var isReady = false
    /// The library couldn't open: said on the page with Try Again (`LibraryProblemPage`), until it opens.
    var libraryProblem: AppProblem?
    /// A library in the wrong place for this build (docs/sandbox.md): the library doesn't open until the person decides.
    var libraryMoveOffer: LibraryMoveOffer?
    var isMovingLibrary = false
    var libraryMoveError: AppProblem?
    /// A library just copied into the container, before the person decides about the old copy.
    var movedLibrary: MovedLibrary?
    /// Said once the library opens (`LaunchCheck`).
    var launchNotice: String?
    /// The library notice's button and the message it belongs to (`post(_:action:)`).
    private var noticeAction: (message: String, action: LibraryNoticeAction)?
    /// Recordings this Mac's capture ended on its own (a microphone that failed, sleep, a disk that couldn't keep up),
    /// by conversation: the recorder's one sentence for why. What was recorded is saved either way.
    private(set) var unexpectedStops: [UUID: String] = [:]

    /// The reason is said; the person has seen it.
    func dismissUnexpectedStop(_ id: UUID) { unexpectedStops[id] = nil }
    var readingPhotoID: UUID?
    var pendingPhotoReadings = Set<UUID>()
    /// Photos that couldn't be read wait before they're tried again (AppState+Photos.swift).
    var photoBackoff = PhotoReadingBackoff()
    /// The reading running now, and the wait before failed photos are tried again (AppState+Photos.swift).
    @ObservationIgnored var photoReading: Task<Void, Never>?
    @ObservationIgnored var photoRetry: Task<Void, Never>?
    /// Listening to recordings transcribed before Daybook listened for music and TV, when idle
    /// (AppState+BackgroundAudio.swift): the pass, whether it has started, and the recordings tried.
    @ObservationIgnored var backgroundListening: Task<Void, Never>?
    var isListeningToEarlierRecordings = false
    var listenedRecordings = Set<UUID>()
    var backgroundListeningDelay: Duration = .seconds(20)
    /// This Mac's processing queue and model downloads (ProcessingQueue.swift). The views, menus, and tests read it
    /// through the names below, as they always have.
    let queue: ProcessingQueue
    /// The conversation being processed now.
    var processingID: UUID? {
        get { queue.runningID }
        set { queue.runningID = newValue }
    }
    /// The running job's progress, throttled (`ActivityProgress`). The window isn't redrawn by it: the
    /// views that draw it observe `processingActivity`, and redraw when its percent, message, or step changes.
    var processingActivity: ActivityProgress { queue.activity }
    var processingProgress: IntelligenceProgress {
        get { queue.activity.value }
        set { queue.activity.set(newValue) }
    }
    /// Waiting, in order.
    var processingQueue: [ProcessingJob] {
        get { queue.jobs }
        set { queue.jobs = newValue }
    }
    /// The job running now (`processingID`'s), with the request it carries out, if any.
    var runningJob: ProcessingJob? {
        get { queue.running }
        set { queue.running = newValue }
    }
    var queuedIDs: [UUID] { queue.queuedIDs }
    /// Conversations the person paused; they resume only when asked.
    var pausedIDs: Set<UUID> {
        get { queue.paused }
        set { queue.paused = newValue }
    }
    /// Conversations that start transcribing as soon as the selected models finish downloading.
    var awaitingModels: Set<UUID> {
        get { queue.awaitingModels }
        set { queue.awaitingModels = newValue }
    }
    var processingPreferences: ProcessingPreferences {
        didSet {
            if let data = try? JSONEncoder().encode(processingPreferences.normalized) { preferences.set(data, forKey: Preference.processingPreferences) }
            // The speaker model is the selection's diarization choice; keep the two in step.
            if modelSelections[.diarization] != processingPreferences.speakerModelID { modelSelections[.diarization] = processingPreferences.speakerModelID }
            presenceChanged()
        }
    }
    /// Variant keys ("whisper/base") with a verified revision on this Mac.
    var installedModels: Set<String> = [] { didSet { presenceChanged() } }
    /// The devices in the library's presence records, as of the last sync pass: other Macs and the models they run, for
    /// "Upgrade" offers (AppState+Upgrade.swift).
    var syncDevices: [KnownSyncDevice] = []
    /// Variant key → the revision a new job freezes (the newest verified one).
    var installedRevisions: [String: String] = [:]
    /// Every model Daybook knows here: built in plus the ones the person added.
    var modelCatalog: ModelCatalog = .builtIn { didSet { catalogRevision &+= 1 } }
    /// Bumped whenever the catalog changes: part of the key for the routed models (`routedRequiredModelIDs`).
    private(set) var catalogRevision = 0
    /// The routed models and what they were worked out from (AppState+SpeechRouting.swift).
    @ObservationIgnored var routeMemo: (key: SpeechRoute.Inputs, models: [String])?
    /// The model chosen for each role, by family and variant (docs/models.md).
    var modelSelections: ModelSelections {
        didSet {
            if let data = try? JSONEncoder().encode(modelSelections) { preferences.set(data, forKey: Preference.modelSelections) }
            if let speaker = modelSelections[.diarization], processingPreferences.speakerModelID != speaker {
                processingPreferences.speakerModelID = speaker
            }
            presenceChanged()
        }
    }
    /// The model downloading now (`ProcessingQueue`).
    var downloadingID: String? {
        get { queue.downloadingID }
        set { queue.downloadingID = newValue }
    }
    /// The current download's progress, throttled like `processingActivity`.
    var downloadActivity: ActivityProgress { queue.downloadActivity }
    var downloadProgress: IntelligenceProgress {
        get { queue.downloadActivity.value }
        set { queue.downloadActivity.set(newValue) }
    }
    /// Models still to download after the current one.
    var pendingDownloads: [String] { queue.pendingDownloads }
    var glossary: [GlossaryTerm] { library.glossary }
    var recordingID: UUID?
    var isStartingRecording = false
    var isStoppingRecording = false
    var recordingStartedAt: Date?
    /// The selected transcription and summary models' variant keys (`modelSelections`).
    var transcriptionModel: String {
        get { modelSelections[.transcription] ?? "" }
        set { modelSelections[.transcription] = newValue }
    }
    var summaryModel: String {
        get { modelSelections[.summarization] ?? "" }
        set { modelSelections[.summarization] = newValue }
    }
    /// What happens when a call starts (`CallRecordingPolicy`): Off, Ask (the call prompt), or Record Automatically.
    var callPolicy: CallRecordingPolicy {
        didSet {
            guard callPolicy != oldValue else { return }
            CallPolicy.save(callPolicy, choices: callAppChoices, in: preferences)
            if callPolicy == .off {
                monitor.stopMonitoring()
                CallPromptWindow.shared.dismiss()
                if recordingWasAutomatic { Task { await stopRecording(manual: false) } }
            } else {
                startCallMonitoring()
            }
        }
    }
    /// Apps whose calls get their own answer, ahead of `callPolicy` (Always Record, Never, Ask).
    var callAppChoices: [String: CallAppChoice] {
        didSet { CallPolicy.save(callPolicy, choices: callAppChoices, in: preferences) }
    }
    /// Whether every call is recorded as soon as it starts: Record Automatically.
    var automaticRecording: Bool { callPolicy == .record }

    /// Looks at this Mac for calls, except under XCTest, whose AppStates must never read the real audio server or ask
    /// about a call the developer is on (the monitor's own tests drive it with scripted looks).
    private func startCallMonitoring() {
        guard !MacCaptioners.isRunningTests else { return }
        monitor.startMonitoring()
    }
    var includeComputerAudio: Bool { didSet { preferences.set(includeComputerAudio, forKey: Preference.includeComputerAudio) } }
    var processSyncedAudio: Bool { didSet { preferences.set(processSyncedAudio, forKey: Preference.processSyncedAudio); presenceChanged() } }
    var detectSpeakers: Bool { didSet { preferences.set(detectSpeakers, forKey: Preference.detectSpeakers); presenceChanged() } }
    let sync: LibrarySyncController
    /// Daybook's local link to paired iPhones: pairing, record control, live progress.
    let phoneLink: PhoneLink
    /// Recorders: Soundcore Work, folders of exports, and whatever comes next.
    let devices: DeviceHub
    /// Moving a recorder between this Mac and an iPhone (AppState+Devices.swift).
    let recorderHandoff: RecorderHandoff
    /// Several recordings of one conversation: multipoint recording, matching, and enhancement.
    let sources: MultiSourceCoordinator
    let recorder: RecordingController
    /// Live captions while this Mac records (You and Call), and their setting and language.
    let captions: LiveCaptionsController
    /// The input levels iPhones recording along send, for Floating Notes' meters (App/PhoneLevels.swift).
    let phoneLevels = PhoneLevels()
    let captionSettings: LiveCaptionSettings
    /// Live transcription from local models, when they're downloaded (Captions/MacLiveModels.swift).
    let liveModels: MacLiveModels
    let monitor = MeetingMonitor()
    let storageURL: URL
    /// This Mac's preferences (the app's, or a test's own suite).
    let preferences: UserDefaults
    /// Cloud summaries' keys, models, and this Mac's preferences (Settings › Cloud; docs/cloud.md): the one place the
    /// summary step reads them. Made when first used (Settings, or a summary step), so a launch that never needs it
    /// never reads the keychain. Demos and tests set their own (`CloudSetup.demo`).
    var cloud: CloudSetup {
        get {
            if let cloudSetup { return cloudSetup }
            #if DEBUG
            return adopt(CloudSettingsDemo.setup(defaults: preferences) ?? CloudSetup(keys: KeychainCloudKeyStore.system, defaults: preferences))
            #else
            return adopt(CloudSetup(keys: KeychainCloudKeyStore.system, defaults: preferences))
            #endif
        }
        set { adopt(newValue) }
    }
    private var cloudSetup: CloudSetup?

    @discardableResult
    private func adopt(_ setup: CloudSetup) -> CloudSetup {
        cloudSetup = setup
        // A key, the models offered, or the preferences changed: every countdown follows.
        setup.onChange = { [weak self] in self?.placementOptionsChanged() }
        placementOptionsChanged()
        return setup
    }
    /// Whether `cloud` has been made: until then nothing is being placed with it.
    var hasCloudSetup: Bool { cloudSetup != nil }
    let runtime: LocalIntelligenceRuntime
    /// Keeps speaker profiles and conversations in step (AppState+SpeakerProfiles.swift).
    @ObservationIgnored lazy var speakerProfileCoordinator = makeSpeakerProfileCoordinator()
    /// Gives voices to speakers found without them, when this Mac is idle (AppState+SpeakerProfiles.swift).
    var voicingID: UUID?
    @ObservationIgnored var voicingTask: Task<Void, Never>?
    /// Runs given voices (or tried) this session.
    var voicedRuns = Set<UUID>()
    var processingTask: Task<Void, Never>? {
        get { queue.task }
        set { queue.task = newValue }
    }
    var currentRequest: Task<Void, Error>? { queue.currentRequest }
    /// How requests from other devices are claimed and kept (tests shorten these).
    var requestTiming = RequestTiming()
    /// The memory a summary model must fit in (tests set it, so they don't depend on the machine's).
    var physicalMemory = ProcessInfo.processInfo.physicalMemory
    /// Where each summary runs, with the countdown before it (AppState+SummaryPlacement.swift). Only views that
    /// show a countdown read it.
    let placements: SummaryPlacements
    /// Summaries in the cloud with the person's own keys: `cloud`'s directory, sent as this Mac. Demos and tests set
    /// one of their own.
    var cloudSummarizer: any CloudSummarizing {
        get { cloudSummarizerOverride ?? CloudSummarizer(directory: cloud.directory, deviceName: ProcessingRequest.Device.currentName) }
        set { cloudSummarizerOverride = newValue }
    }
    @ObservationIgnored private var cloudSummarizerOverride: (any CloudSummarizing)?
    /// Conversations whose running job stopped because another device took its request over.
    var claimsLost: Set<UUID> {
        get { queue.claimsLost }
        set { queue.claimsLost = newValue }
    }
    var claimHeartbeat: Task<Void, Never>? {
        get { queue.claimHeartbeat }
        set { queue.claimHeartbeat = newValue }
    }
    var lastClaimRenewal: Date {
        get { queue.lastClaimRenewal }
        set { queue.lastClaimRenewal = newValue }
    }
    var lastRenewedStage: ProcessingRequest.Stage? {
        get { queue.lastRenewedStage }
        set { queue.lastRenewedStage = newValue }
    }
    /// Daybook on iPhone from this Mac's side, as state (PhoneCoordinator.swift). `AppState+Phone.swift`,
    /// `AppState+SharedNotes.swift`, and the tests read it through the names below, as they always have.
    let phones = PhoneCoordinator()
    /// Conversations an iPhone recording moved out of, on their way to the Trash: not processed.
    var movedPhoneRecordings: Set<UUID> {
        get { phones.movedRecordings }
        set { phones.movedRecordings = newValue }
    }
    /// Conversations of an iPhone's own queued only to check where its recording belongs.
    var checkingPhoneTranscripts: Set<UUID> {
        get { phones.checkingTranscripts }
        set { phones.checkingTranscripts = newValue }
    }
    /// The last live progress sent to phones, and when; sends go out one after another, in order.
    var lastPhoneProgress: (message: LinkProcessingProgress, at: Date)? {
        get { phones.lastProgress }
        set { phones.lastProgress = newValue }
    }
    var phoneProgressSend: Task<Void, Never>? {
        get { phones.progressSend }
        set { phones.progressSend = newValue }
    }
    /// Recordings this Mac is making because a phone asked, by conversation.
    var phoneLeads: [UUID: CompanionLead] {
        get { phones.leads }
        set { phones.leads = newValue }
    }
    /// The device whose word is stopping this Mac's recording now, by session ID: it isn't asked to stop in turn.
    var stopCause: String? {
        get { phones.stopCause }
        set { phones.stopCause = newValue }
    }
    /// A recorder whose own button is starting this Mac's recording, by session ID.
    var pendingRecorderLead: String? {
        get { phones.pendingRecorderLead }
        set { phones.pendingRecorderLead = newValue }
    }
    /// Notes and bookmarks of this Mac's recording, kept in step with the phones recording it too.
    var sharedNotes: SharedNotesTracker { phones.sharedNotes }
    var sharedNotesWatch: ObservationWatch? {
        get { phones.sharedNotesWatch }
        set { phones.sharedNotesWatch = newValue }
    }
    var sharedNotesSend: Task<Void, Never>? {
        get { phones.sharedNotesSend }
        set { phones.sharedNotesSend = newValue }
    }
    /// Starts and stops this Mac's capture when a phone asks. Tests replace it: no microphone.
    var phoneCapture: PhoneCapture {
        get { phones.capture }
        set { phones.capture = newValue }
    }
    /// Whether this Mac may use the microphone without asking. Tests replace it.
    var microphoneAccess: () -> AVAuthorizationStatus {
        get { phones.microphoneAccess }
        set { phones.microphoneAccess = newValue }
    }
    /// What this state follows in the models it holds (`ObservationWatch`), for as long as it lives.
    @ObservationIgnored var watches: [ObservationWatch] = []
    private var recordingWasAutomatic = false
    /// This Mac's recording started on its own (a detected meeting).
    var recordingWasStartedAutomatically: Bool { recordingWasAutomatic }
    @ObservationIgnored private var captureDirectory: URL?
    /// Changes whenever the library's conversations do: the key for what's derived from them.
    var libraryRevision: Int { library.revision }
    /// Bumped when a search that ran off the main actor has its results, so the views showing them read them again.
    private var searchResultsArrived = 0
    @ObservationIgnored private var visibleMemo: (place: LibraryPlace, revision: Int, meetings: [Meeting])?
    let searchMemo = LibrarySearchMemo()

    /// `capture` is this Mac's microphone and call audio; tests pass fakes.
    init(libraryURL: URL = AppState.libraryURL, defaults: UserDefaults = .standard, capture: CaptureEnvironment = .live) {
        // Where the library is, before anything here writes preferences or sync resolves its identity (docs/sandbox.md).
        let launch = Self.launchCheck(library: libraryURL, defaults: defaults)
        recorder = RecordingController(environment: capture)
        queue = ProcessingQueue(owedURL: libraryURL.appendingPathComponent("local-queue.json"))
        let storedPreferences = defaults.data(forKey: Preference.processingPreferences).flatMap { try? JSONDecoder().decode(ProcessingPreferences.self, from: $0) }
        var processingPreferences = storedPreferences ?? .init()
        let selections = Self.loadModelSelections(defaults: defaults, speakerModel: storedPreferences?.speakerModelID)
        processingPreferences.speakerModelID = selections[.diarization] ?? processingPreferences.speakerModelID
        modelSelections = selections
        self.processingPreferences = processingPreferences
        // The cloud's options and preferences reach it when a summary is placed (`placementOptionsChanged`).
        placements = SummaryPlacements(waitsForMacs: false)
        let sync = LibrarySyncController(localRoot: libraryURL, defaults: defaults)
        // Presence: other devices see this Mac and whether it can process. Updated as models change.
        sync.replica = .mac(displayName: ProcessingRequest.Device.currentName, canProcess: false)
        // An encrypted library's key, from iCloud Keychain. Nil in builds without the shared keychain group (ad hoc,
        // `swift run`, tests), which can't sync anyway.
        sync.replica.keyStore = KeychainLibraryKeyStore.system
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
        let environment = DeviceEnvironment(defaults: defaults, stagingDirectory: libraryURL.appendingPathComponent("DeviceImports", isDirectory: true))
        environment.phone.makeLinkConnection = { device in UUID(uuidString: device.id).map { PhoneLinkConnection(phoneID: $0, link: phoneLink) } }
        environment.phone.syncIsOn = { sync.folder != nil }
        environment.phone.pairedPhoneIDs = { Set(phoneLink.paired.map(\.deviceID.uuidString)) }
        devices = DeviceHub(environment: environment)
        recorderHandoff = RecorderHandoff(library: library, devices: devices, deviceClass: .mac, defaults: defaults)
        sources = MultiSourceCoordinator(defaults: defaults)
        callPolicy = CallPolicy.stored(in: defaults)
        callAppChoices = CallPolicy.storedChoices(in: defaults)
        includeComputerAudio = defaults.object(forKey: Preference.includeComputerAudio) as? Bool ?? true
        processSyncedAudio = defaults.object(forKey: Preference.processSyncedAudio) as? Bool ?? true
        detectSpeakers = defaults.object(forKey: Preference.detectSpeakers) as? Bool ?? true
        readingScale = defaults.object(forKey: Preference.readingScale) as? Double ?? 1
        runtime = LocalIntelligenceRuntime(modelsDirectory: libraryURL.appendingPathComponent("Models"), fetcher: ModelDemo.fetcher)
        let captionSettings = LiveCaptionSettings(defaults: defaults)
        self.captionSettings = captionSettings
        liveModels = MacLiveModels(store: runtime.store)
        captions = LiveCaptionsController(store: LiveCaptionStore(libraryRoot: libraryURL),
                                          makeCaptioner: MacCaptioners.recordingFactory(settings: captionSettings))
        processingActivity.onChange = { [weak self] _ in self?.processingProgressChanged() }
        searchMemo.onUpdate = { [weak self] in self?.searchResultsArrived &+= 1 }
        sync.onSyncRequested = { [weak self] in await self?.synchronizeLibrary() }
        monitor.onMeetingStarted = { [weak self] candidate in
            guard let self else { return .notRecorded }
            switch CallPolicy.decision(for: candidate.bundleID, policy: self.callPolicy, choices: self.callAppChoices,
                                       busy: self.recordingID != nil || self.isStartingRecording) {
            case .record:
                Task { await self.startRecording(title: candidate.windowTitle, automatic: true) }
                return .recording
            case .ask:
                self.askToRecord(candidate)
                return .asking
            case .ignore:
                // A recording already under way carries on as it is; a call its app says Never to is left alone.
                return self.recordingID != nil || self.isStartingRecording ? .recording : .notRecorded
            }
        }
        monitor.onMeetingEnded = { [weak self] call in
            guard let self else { return false }
            CallPromptWindow.shared.callEnded()
            if self.recordingWasAutomatic {
                Task { await self.stopRecording(manual: false) }
                return true
            }
            // A recording the person started is theirs to stop: asked, never stopped.
            if self.recordingID != nil, !self.isStoppingRecording, let call { self.askToStop(after: call) }
            return false
        }
        recorder.onUnexpectedStop = { [weak self] result, reason in
            guard let self else { return }
            // Why it stopped, in the recorder's one sentence, for the conversation's page to say.
            if let id = self.recordingID ?? UUID(uuidString: result.directory.lastPathComponent) {
                self.unexpectedStops[id] = reason
            }
            Task { await self.finishCapture(result) }
        }
        wireDevices()
        wirePhones()
        wireCaptions()
        wireSummaryPlacements()
        libraryMoveOffer = launch.offer
        launchNotice = launch.notice
    }

    /// The preferences this Mac's state keeps, by name, in the app's preferences or a `--library` run's own suite.
    enum Preference {
        static let readingScale = "readingScale"
        static let processingPreferences = "processingPreferences"
        static let modelSelections = "modelSelections"
        /// Roles that arrived after the model system, each added to a stored selection once.
        static let smallTasksAdded = "modelSelections.smallTasksAdded"
        static let imageDescriptionAdded = "modelSelections.imageDescriptionAdded"
        static let liveModelsAdded = "modelSelections.liveAdded"
        /// The catalog IDs stored before the model system ("whisper-base"), read once to migrate.
        static let legacyTranscriptionModel = "transcriptionModel"
        static let legacySummaryModel = "summaryModel"
        static let automaticRecording = "automaticRecording"
        static let includeComputerAudio = "includeComputerAudio"
        static let processSyncedAudio = "processSyncedAudio"
        static let detectSpeakers = "detectSpeakers"
        static let showsFloatingNotesWhileRecording = "showsFloatingNotesWhileRecording"
        static let isInspectorPresented = "isInspectorPresented"
        static let showsMenuBarExtra = "showsMenuBarExtra"
        static let onboardingCompleted = "onboardingCompleted"
    }

    /// What the launch check found: a move to offer, or something to say once the library opens.
    struct LaunchCheck: Equatable {
        var offer: LibraryMoveOffer?
        var notice: String?
    }

    /// Where the library is, before anything writes preferences or sync resolves its identity (docs/sandbox.md). A
    /// library that moved gets this Mac's identity back (`ReplicaIdentity`). Then, for the app's own library only (never
    /// `--library`, `swift run`, or tests): unsandboxed, whether to move it back out of the sandboxed build's container
    /// (`LegacyLibraryReturn`); sandboxed, whether it's in place in the container (`SandboxMigration`).
    static func launchCheck(library: URL, defaults: UserDefaults, bundle: Bundle = .main,
                            sandboxed: Bool = SandboxEnvironment.isSandboxed) -> LaunchCheck {
        let priorUse = SandboxMigration.preferencesShowPriorUse(defaults)
        ReplicaIdentity.restore(library: library, defaults: defaults, machine: ReplicaIdentity.currentMachine)
        guard library.standardizedFileURL.path == LibraryLocation.standard.standardizedFileURL.path,
              LibraryLocation.folderName(bundleURL: bundle.bundleURL) == LibraryLocation.appFolder,
              let identifier = bundle.bundleIdentifier else { return LaunchCheck() }
        return launchCheck(library: library, bundleIdentifier: identifier, defaults: defaults, sandboxed: sandboxed, priorUse: priorUse)
    }

    static func launchCheck(library: URL, bundleIdentifier: String, defaults: UserDefaults, sandboxed: Bool, priorUse: Bool,
                            home: URL = UserHome.url,
                            store: (URL) -> SyncDeviceIdentityStore = { SyncDeviceIdentityStore.keychain(for: $0) }) -> LaunchCheck {
        guard sandboxed else {
            // Only the app itself goes back: its library is the old place its bundle ID's sandboxed build moved from.
            guard SandboxMigration.legacyFolderName(bundleIdentifier: bundleIdentifier) == library.lastPathComponent else { return LaunchCheck() }
            let plan = LegacyLibraryReturn.plan(library: library, bundleIdentifier: bundleIdentifier, home: home, defaults: defaults)
            return LaunchCheck(offer: plan.map { .returnFromContainer($0) })
        }
        guard let legacy = SandboxMigration.legacyLibrary(bundleIdentifier: bundleIdentifier, home: home) else { return LaunchCheck() }
        switch SandboxMigration.check(library: library, legacy: legacy, defaults: defaults, priorUse: priorUse, store: store) {
        case .fresh, .moved:
            return LaunchCheck()
        case .stillAtOldLocation:
            return LaunchCheck(offer: .moveIntoContainer(.init(legacy: legacy, library: library, legacyExists: LibraryContents.looksLikeLibrary(legacy))))
        case .bothPresent:
            guard defaults.string(forKey: SandboxMigration.keptOldCopyKey) != legacy.path else { return LaunchCheck() }
            return LaunchCheck(offer: .oldCopyRemains(legacy))
        case .identityMissing:
            return LaunchCheck(notice: "If your iPhone can’t find this Mac, pair it again in Settings › Devices.")
        }
    }

    /// Moves the library as offered. Back out of the container: moved, then the app starts over. Into the container: the
    /// person chooses the old library (the sandbox can read it only then), it's copied into place, and the sheet asks
    /// about the old copy (`finishLibraryMove`).
    func acceptLibraryMove() {
        guard let offer = libraryMoveOffer, !isMovingLibrary else { return }
        libraryMoveError = nil
        switch offer {
        case .returnFromContainer(let plan):
            isMovingLibrary = true
            Task {
                do {
                    _ = try await detachedWork(priority: .userInitiated) { try LegacyLibraryReturn.move(plan) }
                    LegacyLibraryReturn.finish(plan, defaults: preferences)
                    AppRelaunch.relaunch()
                } catch {
                    isMovingLibrary = false
                    libraryMoveError = AppProblem(title: "Couldn’t Move Your Library", fallback: "Your library couldn’t be moved. Try again.", error: error)
                }
            }
        case .moveIntoContainer(let plan):
            guard let source = SandboxMigration.chooseLibrary(near: plan.legacy) else { return }
            isMovingLibrary = true
            let scoped = source.startAccessingSecurityScopedResource()
            Task {
                do {
                    try await detachedWork(priority: .userInitiated) { try SandboxMigration.copyLibrary(from: source, to: plan.library) }
                    movedLibrary = MovedLibrary(source: source, scoped: scoped, legacy: plan.legacy)
                } catch {
                    if scoped { source.stopAccessingSecurityScopedResource() }
                    libraryMoveError = AppProblem(title: "Couldn’t Move Your Library", fallback: "Your library couldn’t be moved. Try again.", error: error)
                }
                isMovingLibrary = false
            }
        case .oldCopyRemains(let legacy):
            NSWorkspace.shared.activateFileViewerSelecting([legacy])
            keepOldLibraryCopy(legacy)
        }
    }

    /// After a move into the container: the old copy goes to the Trash or stays, and the app starts over with the
    /// library in place.
    func finishLibraryMove(trashingOldCopy: Bool) {
        guard let moved = movedLibrary else { return }
        var trashed = false
        if trashingOldCopy {
            trashed = (try? FileManager.default.trashItem(at: moved.source, resultingItemURL: nil)) != nil
            if !trashed { NSWorkspace.shared.activateFileViewerSelecting([moved.source]) }
        }
        if !trashed { preferences.set(moved.legacy.path, forKey: SandboxMigration.keptOldCopyKey) }
        if moved.scoped { moved.source.stopAccessingSecurityScopedResource() }
        AppRelaunch.relaunch()
    }

    /// Not Now (or Quit, Start Fresh, Keep It), depending on the offer.
    func declineLibraryMove() async {
        guard let offer = libraryMoveOffer, !isMovingLibrary else { return }
        switch offer {
        case .returnFromContainer(let plan): LegacyLibraryReturn.decline(plan, defaults: preferences)
        case .moveIntoContainer(let plan):
            // With a library at the old place, nothing opens without it; with none there, start a new one.
            guard !plan.legacyExists else { NSApp.terminateFromRunLoop(); return }
            preferences.set(true, forKey: SandboxMigration.startedFreshKey)
        case .oldCopyRemains(let legacy):
            keepOldLibraryCopy(legacy)
            return
        }
        libraryMoveOffer = nil
        await initialize()
    }

    private func keepOldLibraryCopy(_ legacy: URL) {
        preferences.set(legacy.path, forKey: SandboxMigration.keptOldCopyKey)
        libraryMoveOffer = nil
    }

    var selectedMeeting: Meeting? { meetings.first { $0.id == selectedID } }
    var isRecording: Bool { recordingID != nil }
    var canProcess: Bool { routedRequiredModelIDs.allSatisfy(installedModels.contains) }

    /// Selections from `modelSelections`, or, on the first launch after the model system arrived,
    /// migrated from the catalog IDs Daybook stored before ("whisper-base", "qwen-7b",
    /// "speaker-community-1"). The old keys are left in place for an older build.
    static func loadModelSelections(defaults: UserDefaults, speakerModel: String?) -> ModelSelections {
        if let data = defaults.data(forKey: Preference.modelSelections), var stored = try? JSONDecoder().decode(ModelSelections.self, from: data) {
            // Small tasks arrived after the model system: once, a selection without that role takes the initial one.
            if !defaults.bool(forKey: Preference.smallTasksAdded) {
                defaults.set(true, forKey: Preference.smallTasksAdded)
                if stored[.smallTasks] == nil, let initial = ModelRecommendations.initialSelections()[.smallTasks] {
                    stored[.smallTasks] = initial
                    if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Preference.modelSelections) }
                }
            }
            // Photos came later still: the same, once, for the photo role (Apple Vision).
            if !defaults.bool(forKey: Preference.imageDescriptionAdded) {
                defaults.set(true, forKey: Preference.imageDescriptionAdded)
                if stored[.imageDescription] == nil, let initial = ModelRecommendations.initialSelections()[.imageDescription] {
                    stored[.imageDescription] = initial
                    if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Preference.modelSelections) }
                }
            }
            // Live transcription's roles, once, so Settings › Models shows the live models captions would use.
            if !defaults.bool(forKey: Preference.liveModelsAdded) {
                defaults.set(true, forKey: Preference.liveModelsAdded)
                stored = LiveModelChoices.addingDefaults(to: stored, platform: .macOS)
                if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Preference.modelSelections) }
            }
            return stored
        }
        let migrated = ModelSelections.migrating(
            legacy: [.transcription: defaults.string(forKey: Preference.legacyTranscriptionModel), .summarization: defaults.string(forKey: Preference.legacySummaryModel),
                     .diarization: speakerModel],
            catalog: .builtIn, defaults: LiveModelChoices.addingDefaults(to: ModelRecommendations.initialSelections(), platform: .macOS))
        defaults.set(true, forKey: Preference.liveModelsAdded)
        if let data = try? JSONEncoder().encode(migrated) { defaults.set(data, forKey: Preference.modelSelections) }
        return migrated
    }
    /// Conversations in the selected place, newest first. Kept until the place or the library changes.
    var visibleMeetings: [Meeting] {
        if let memo = visibleMemo, memo.place == place, memo.revision == libraryRevision { return memo.meetings }
        let visible = meetings.filter { meeting in
            switch place {
            case .section(let section): return section.contains(meeting)
            case .folder(let id): return meeting.folderID == id
            case .device, .trash: return false
            }
        }.sorted { $0.date > $1.date }
        visibleMemo = (place, libraryRevision, visible)
        return visible
    }

    /// The library search's results for the current query, kept until it or the library changes;
    /// a large library is searched off the main actor (`LibrarySearchMemo`).
    var searchHits: [SearchHit] {
        _ = searchResultsArrived
        return searchMemo.hits(for: .init(text: search, tokens: searchTokens, scope: searchScope, revision: libraryRevision), in: meetings)
    }
    var isSearching: Bool { !search.trimmingCharacters(in: .whitespaces).isEmpty || !searchTokens.isEmpty }

    /// Returns once the library is open and the app ready (`isReady`); at once when it is already.
    func whenReady() async {
        await ObservationWatch.until { [weak self] in self?.isReady != false }
    }

    func initialize() async {
        guard !isReady else { return }
        // A library to move first: nothing opens until the person decides (`libraryMoveOffer`).
        guard libraryMoveOffer?.holdsLibrary != true else { return }
        do {
            try await library.load()
            // What this Mac owed when it last quit, restarted, or crashed, before anything is queued now.
            queue.loadOwedWork()
            recordReplicaIdentity()
            if let launchNotice { post([launchNotice]); self.launchNotice = nil }
            // Installs from before the model system move into the store first, without downloading.
            let migration = await runtime.prepare()
            if !migration.failed.isEmpty {
                notice = "Some models need to be downloaded again: \(migration.failed.keys.sorted().map { ModelCatalog.builtIn.name(for: $0) }.joined(separator: ", "))."
            }
            modelCatalog = await runtime.catalog
            await refreshInstalledModels()
            replaceRetiredChoices()
            selectedID = meetings.first?.id
            isReady = true
            speakerProfileCoordinator.start()
            await recoverRecordings()
            devices.start()
            sync.restore()
            if callPolicy != .off { startCallMonitoring() }
            await startPhoneLinkIfPaired()
            closeRecoveredLinks()
            // Requests this Mac held when it last quit or crashed run again (or are given back), and so does its own
            // work.
            pickUpRequests()
            resumeOwedWork()
            Task { await library.relabelStrandedWords() }
            listenToEarlierRecordingsWhenIdle()
        } catch {
            // On the page, where it can be looked at and tried again: what stops a folder opening is still there after a
            // relaunch.
            libraryProblem = AppProblem(title: "Couldn’t Open Your Library",
                                        fallback: "Its folder couldn’t be opened. Check it in Finder, then try again.", error: error)
        }
    }

    /// Keeps this Mac's sync and link identity with the library (`ReplicaIdentity`), for when the library moves.
    func recordReplicaIdentity() {
        guard library.isLoaded else { return }
        ReplicaIdentity.save(ReplicaIdentity(syncDeviceID: sync.deviceID, installation: sync.installation,
                                             linkDeviceID: phoneLink.identity.deviceID.uuidString,
                                             libraryPath: storageURL.standardizedFileURL.path,
                                             machine: ReplicaIdentity.currentMachine ?? "", savedAt: Date()), in: storageURL)
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
        // A paragraph a phone wrote a moment ago that the editor hadn't shown yet isn't deleted by it.
        var text = text
        if sharedNotes.conversationID == id, let meeting = meetings.first(where: { $0.id == id }) {
            text = sharedNotes.keepingArrivals(text, anchors: NoteTimeline.anchors(meeting.timedNotes, text: meeting.notes))
        }
        library.editNotes(id, text: text, captureTime: recordingID == id ? recorder.elapsedTime : nil)
    }

    func flush() async { await library.flush() }

    func chooseImport(attachTo id: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.title = id == nil ? "Import recordings" : "Add another recording of this conversation"
        // A recording's bookmarks file ("call.highlights.json") can be chosen with it (`separatingSidecars`).
        panel.allowedContentTypes = [.audio, .movie, .json]; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        Task {
            do { try await importFiles(panel.urls, source: .imported, attachTo: id) }
            catch { report("Couldn’t Import Audio", "Choose an audio or video file and try again.", error) }
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
        let (audioURLs, chosenSidecars) = Self.separatingSidecars(urls)
        for url in audioURLs {
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
            let sidecar = readableSidecar(for: url, chosen: chosenSidecars)
            defer { sidecar.close() }
            let imported = try await library.ingest(url, into: meetingID, provenance: .file(source: source, device: device,
                sidecarURL: sidecar.url, duration: duration,
                recorderClock: device.flatMap(DeviceRecordingStart.clock(of:)))).imported
            await sourceArrived(meetingID, before: meeting, imported: imported, url: url, device: device, plan: plan)
            if device == nil { selectedID = meetingID }
            meetingIDs.append(meetingID)
            enqueue(meetingID)
        }
        return meetingIDs
    }

    /// Recordings to import and the highlights sidecars ("call.highlights.json") chosen or dropped with them, keyed by
    /// the recording they belong to: its path without the extension. Other JSON files are left out.
    nonisolated static func separatingSidecars(_ urls: [URL]) -> (audio: [URL], sidecars: [String: URL]) {
        var audio: [URL] = [], sidecars: [String: URL] = [:]
        for url in urls {
            if let recording = sidecarRecordingPath(url) { sidecars[recording] = url }
            else if url.pathExtension.lowercased() != "json" { audio.append(url) }
        }
        return (audio, sidecars)
    }

    /// "/a/call.highlights.json" → "/a/call"; nil for anything that isn't a highlights sidecar.
    nonisolated static func sidecarRecordingPath(_ url: URL) -> String? {
        let suffix = ".highlights.json", name = url.lastPathComponent
        guard name.lowercased().hasSuffix(suffix), name.count > suffix.count else { return nil }
        return url.deletingLastPathComponent().appendingPathComponent(String(name.dropLast(suffix.count))).standardizedFileURL.path
    }

    /// What a drop imports: its recordings and the highlights sidecars beside them; nothing when it holds no recording.
    nonisolated static func droppedRecordings(_ urls: [URL]) -> [URL] {
        let audio = urls.filter { UTType(filenameExtension: $0.pathExtension)?.conforms(to: .audiovisualContent) == true }
        guard !audio.isEmpty else { return [] }
        return audio + urls.filter { sidecarRecordingPath($0) != nil }
    }

    /// The highlights sidecar to import with `audio`: one chosen or dropped with it, else the file beside it
    /// ("call.highlights.json"). One that exists but can't be read is left out with a notice, and the recording imports
    /// without its bookmarks: in the App Sandbox only files the person chose are readable, so a sidecar beside a chosen
    /// recording usually isn't.
    private func readableSidecar(for audio: URL, chosen: [String: URL]) -> ImportSidecar {
        let recording = audio.deletingPathExtension().standardizedFileURL.path
        let candidate = chosen[recording] ?? audio.deletingPathExtension().appendingPathExtension("highlights.json")
        guard FileManager.default.fileExists(atPath: candidate.path) else { return ImportSidecar(url: nil, scoped: false) }
        let scoped = candidate.startAccessingSecurityScopedResource()
        if (try? Data(contentsOf: candidate, options: .mappedIfSafe)) != nil { return ImportSidecar(url: candidate, scoped: scoped) }
        if scoped { candidate.stopAccessingSecurityScopedResource() }
        post(["Imported “\(audio.lastPathComponent)” without its bookmarks. To include them, choose “\(candidate.lastPathComponent)” with it."])
        return ImportSidecar(url: nil, scoped: false)
    }

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
    func process(_ request: ProcessingJob) async throws {
        let id = request.meetingID
        guard library.isLoaded, meetings.contains(where: { $0.id == id }) else { return }
        await flush()
        // A recording the iPhone transcribed itself finds its conversation first, once (AppState+Phone.swift).
        if await phoneTranscriptArrived(id, job: request) { return }
        guard let initial = meetings.first(where: { $0.id == id }) else { return }
        let options = request.preferences
        let engine = processingEngine(for: request)
        let terms = glossary.filter { $0.approved || $0.sourceMeetingIDs.contains(id) }.map(\.term)
        update(id) { $0.status = .transcribing; $0.errorMessage = nil }
        let activity = processingActivity
        let progress: ProcessingProgressHandler = { value in activity.report(IntelligenceProgress(value.fraction, value.message, stage: value.stage)) }
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
        await labelSpeakers(before: id)
        guard let before = meetings.first(where: { $0.id == id }) else { return }
        let transcript = MeetingEvidence.transcript(before)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.noSpeech }
        update(id) { $0.status = .summarizing }
        processingActivity.enter(.summarizing)
        renewRunningClaim(force: false)
        reportToPhones(id)
        let template = template(for: request, meeting: before)
        // Where it runs: here, or in the cloud if the person chooses during the countdown (AppState+SummaryPlacement.swift).
        guard let placed = try await placedSummary(id, job: request, engine: engine, template: template, vocabulary: terms, progress: progress) else {
            // Another device is summarizing it; its summary arrives through sync.
            update(id) { $0.status = $0.summary == nil ? .imported : .ready }
            return
        }
        try Task.checkCancellation()
        let current = placed.meeting, generated = placed.output
        // What was said, written, or chosen meanwhile is summarized again; a speaker's new name follows into this one.
        let inputsChanged = meetings.first(where: { $0.id == id })?.summaryInputsChanged(since: current) ?? false
        // A summary another device wrote meanwhile stays: one summary per conversation.
        if meetings.first(where: { $0.id == id })?.summaryWrittenElsewhere(after: placed.started, excluding: library.thisDevice.id) == true {
            update(id) { $0.status = .ready }
            return
        }
        let summary = generated.summary.placed(placed.place, by: library.thisDevice, inputs: current.modelsBehindTranscript)
        update(id) { meeting in
            meeting.setSummary(summary, writtenFrom: current)
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
        // While recording, only library settings apply (recorder ownership, handoffs), so another device's handoff
        // or claim is seen; conversations wait until the recording is filed.
        if let recordingID, !isStartingRecording, !isStoppingRecording {
            _ = await library.synchronize(protecting: recordingID, scope: .metadataOnly)
            return
        }
        let carryingRequest = processingID != nil && runningJob?.requestID != nil
        guard processingID == nil || carryingRequest, recordingID == nil, !isStartingRecording, !isStoppingRecording else { sync.deferUntilIdle(); return }
        defer { runQueue() }
        guard let applied = await library.synchronize(protecting: processingID ?? recordingID) else { return }
        if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) { selectedID = meetings.sorted { $0.date > $1.date }.first?.id }
        reconcileClaims()
        await syncedLibraryIdentity()
        await refreshSyncDevices()
        guard applied.acknowledged else { return }
        if canProcess {
            // Only newly received sources trigger automatic work. Failed or paused local
            // jobs remain under manual control, including after a later model download.
            // Audio another device is already processing for a request is left to it. A recording
            // a conversation was waiting for is added whatever "Transcribe synced recordings" says:
            // it completes a recording made with this Mac (docs/multipoint.md, "Mac first").
            for id in applied.newAudio(in: meetings) where !isHeldElsewhere(id) && !movedPhoneRecordings.contains(id) {
                guard processSyncedAudio || meetings.first(where: { $0.id == id })?.hasAwaitedRecordingToAdd() == true else { continue }
                enqueue(id)
            }
            // A recording an iPhone transcribed itself may belong to a conversation of this Mac's: checked once.
            for id in phoneTranscriptsToCheck() {
                checkingPhoneTranscripts.insert(id)
                enqueue(id)
            }
        }
        pickUpRequests(start: false)
        requeueUnreadPhotos()
        listenToEarlierRecordingsWhenIdle()
    }

    func realign(_ id: UUID) async { await library.realign(id) }

    /// Adds notices to the one the window shows, keeping every distinct one (the newest last, at
    /// most five) rather than letting each replace the one before.
    func post(_ messages: [String]) {
        var lines = noticeLines
        for message in messages where !message.isEmpty {
            lines.removeAll { $0 == message }
            lines.append(message)
        }
        guard !lines.isEmpty else { return }
        notice = lines.suffix(5).joined(separator: "\n")
    }

    /// Adds `message` to the library notice with `action` as a text button at the end of its line (Undo, Show,
    /// Show in Finder). The button stays while the notice still says `message`, and goes with it.
    func post(_ message: String, action: LibraryNoticeAction) {
        post([message])
        noticeAction = (message, action)
    }

    /// Takes `line` out of the library notice (what it said was undone), with its button.
    func withdraw(_ line: String) {
        let rest = noticeLines.filter { $0 != line }
        guard rest.count != noticeLines.count else { return }
        notice = rest.isEmpty ? nil : rest.joined(separator: "\n")
        if noticeAction?.message == line { noticeAction = nil }
    }

    /// The library notice's lines, oldest first.
    var noticeLines: [String] { (notice ?? "").components(separatedBy: "\n").filter { !$0.isEmpty } }

    /// The library notice's button, while the notice still says what it came with.
    var shownNoticeAction: LibraryNoticeAction? {
        guard let noticeAction, noticeLines.contains(noticeAction.message) else { return nil }
        return noticeAction.action
    }

    /// The button that ends `line`, if it's the one the notice's action came with.
    func noticeAction(on line: String) -> LibraryNoticeAction? {
        noticeAction?.message == line ? shownNoticeAction : nil
    }

    /// Runs the notice's button, and its line goes; the notice's other lines stay.
    func performNoticeAction() {
        guard let noticeAction, let action = shownNoticeAction else { return }
        let rest = noticeLines.filter { $0 != noticeAction.message }
        notice = rest.isEmpty ? nil : rest.joined(separator: "\n")
        self.noticeAction = nil
        action.perform()
    }

    func setOffset(_ id: UUID, trackID: UUID, seconds: Double?) { library.setOffset(id, trackID: trackID, seconds: seconds) }

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
                } catch { report("Couldn’t Remove the Model", "Try again.", error) }
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

    /// A choice the catalog no longer offers for its role (Qwen 2.5 1.5B for summaries) moves to the preset's
    /// model, installed first; one that isn't downloaded waits for its download, and the notice says where.
    func replaceRetiredChoices() {
        let quality = ModelPreset.current(in: self)?.quality ?? ModelRecommendations.recommendedQuality(catalog: modelCatalog)
        let preset = ModelRecommendations.preset(quality, catalog: modelCatalog, engines: runtime.engines)
        let result = modelSelections.replacingRetired(catalog: modelCatalog, preset: preset, installed: installedModels)
        guard result.selections != modelSelections else { return }
        modelSelections = result.selections
        post(result.changes.compactMap { change -> String? in
            guard case .switched(let role, let from, let to) = change else { return nil }
            let title = Self.roleTitle(role), verb = role == .summarization ? "use" : "uses"
            let switched = "\(modelCatalog.name(for: from)) no longer works for \(title.lowercased()). \(title) now \(verb) \(modelCatalog.name(for: to))"
            return installedModels.contains(to) ? switched + "." : switched + ": download it in Settings › Models."
        })
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

    /// Floating Notes on a conversation (there's one panel for the app).
    func showNotes(for id: UUID) {
        FloatingNotesWindow.shared.show(state: self, focus: id)
    }

    func export(_ id: UUID, json: Bool = false) {
        guard let meeting = meetings.first(where: { $0.id == id }) else { return }
        let directory = library.rootURL.appendingPathComponent("Meetings/\(id.uuidString)", isDirectory: true)
        // Markdown with photos is a file and a folder beside it: the person chooses where both go.
        if !json && !meeting.visiblePhotos.isEmpty { exportWithPhotos(meeting, from: directory); return }
        let panel = NSSavePanel(); panel.allowedContentTypes = json ? [.json] : [.plainText]
        panel.nameFieldStringValue = MeetingExport.fileName(for: meeting) + (json ? ".json" : ".md")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await detachedWork(priority: .userInitiated) {
                    if json {
                        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(meeting).write(to: url, options: .atomic)
                    } else {
                        try MeetingExport.write(meeting, markdownURL: url) { directory.appendingPathComponent($0.relativePath) }
                    }
                }
                postExported(url)
            } catch { report("Couldn’t Export", "Try again, or choose another folder.", error) }
        }
    }

    /// Markdown with photos goes into a folder the person chooses, as `<title>.md` and `<title> Photos/`, never
    /// replacing anything there. A save panel grants only the file it names; in the App Sandbox the photos folder beside
    /// it couldn't be created.
    private func exportWithPhotos(_ meeting: Meeting, from directory: URL) {
        let panel = NSOpenPanel()
        panel.title = "Export “\(meeting.title)”"
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let name = MeetingExport.fileName(for: meeting)
        Task {
            do {
                let written = try await detachedWork(priority: .userInitiated) {
                    let scoped = folder.startAccessingSecurityScopedResource()
                    defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
                    return try MeetingExport.write(meeting, to: folder, name: name) { directory.appendingPathComponent($0.relativePath) }
                }
                postExported(written.markdown)
            } catch { report("Couldn’t Export the Conversation", "It couldn’t be exported. Try again, or choose another folder.", error) }
        }
    }

    /// "Exported Standup.md", with Show in Finder.
    private func postExported(_ file: URL) {
        post("Exported \(file.lastPathComponent)", action: LibraryNoticeAction(title: "Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        })
    }

    /// A recording's audio for something the person did (play it, show it in Finder): a problem is said in the window's
    /// alert. Work that runs on its own uses `availableAudioURL(for:in:)`, which never interrupts.
    func audioURL(for track: RecordingTrack, meetingID: UUID) async -> URL? {
        guard library.isLoaded else { return nil }
        do { return try await audioURL(for: track, in: meetingID) }
        catch { report("Couldn’t Open the Audio", "Try again.", error); return nil }
    }

    /// A recording's audio, or why it can't be had (the library isn't open, iCloud hasn't brought it yet).
    func audioURL(for track: RecordingTrack, in meetingID: UUID) async throws -> URL {
        guard library.isLoaded else { throw AppError.libraryUnavailable }
        return try await library.audioURL(for: track, in: meetingID)
    }

    /// A recording's audio for work the person didn't start (placing a recording that arrived, comparing sound): nil
    /// when it can't be had, which is written to the log rather than shown, so no alert appears over what the person is
    /// doing.
    func availableAudioURL(for track: RecordingTrack, in meetingID: UUID) async -> URL? {
        do { return try await audioURL(for: track, in: meetingID) }
        catch {
            Self.log.notice("Audio for a recording isn't available: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    nonisolated static let log = Logger(subsystem: "local.daybook", category: "AppState")

    /// Imports, sync, and the Trash take turns with the library (`LibraryController`'s lock).
    private func acquireImportLock() async { await library.acquireLock() }
    private func releaseImportLock() { library.releaseLock() }

    /// Recorded or processed now, or with a recording starting or stopping: it can't go to the Trash.
    func isBusy(_ id: UUID) -> Bool {
        id == recordingID || id == processingID || isStartingRecording || isStoppingRecording
    }

    func trashMeeting(_ id: UUID, undoManager: UndoManager? = nil) { trashMeetings([id], undoManager: undoManager) }

    /// Moves conversations to the library's Trash (docs/architecture.md, "Storage and recovery"). Edit › Undo ("Undo
    /// Move to Trash", with `undoManager`) and the notice's Undo put them back. When the selected one goes, the row after
    /// them in the list is selected (the one before, at the end), so the person keeps their place. That happens as its row
    /// goes: each move lets the list look, and the list selects its first row once the selected one is gone (`LibraryView`).
    /// One that's busy (`isBusy`) stays.
    func trashMeetings(_ ids: [UUID], undoManager: UndoManager?) {
        let ids = ids.filter { !isBusy($0) }
        guard !ids.isEmpty else { return }
        let neighbour = Self.neighbour(of: Set(ids), in: listedMeetingIDs)
        let titles = ids.map { id in meetings.first { $0.id == id }?.title ?? "" }
        for id in ids {
            queue.removeJobs(for: id)
            queue.settle(id)
        }
        Task { [weak self] in
            guard let self else { return }
            var trashed: [UUID] = []
            do {
                for id in ids {
                    guard library.isLoaded, try await library.moveToTrash(id, allowed: { !self.isBusy(id) }) else { continue }
                    trashed.append(id)
                    if selectedID == id { selectedID = neighbour }
                }
            } catch { report("Couldn’t Move to Trash", "Try again.", error) }
            guard !trashed.isEmpty else { return }
            multiSelection.subtract(trashed)
            let title = trashed.count == 1 ? titles[ids.firstIndex(of: trashed[0]) ?? 0].trimmingCharacters(in: .whitespaces) : ""
            let message = trashed.count > 1 ? "Moved \(trashed.count) conversations to the Trash."
                : title.isEmpty ? "Moved a conversation to the Trash." : "Moved “\(title)” to the Trash."
            let record = TrashRecord(ids: trashed, message: message)
            if let undoManager {
                Self.registerUndo(on: undoManager, name: "Move to Trash", target: record) { [weak self, record] in
                    self?.restore(record, undoManager: undoManager)
                }
            }
            post(message, action: LibraryNoticeAction(title: "Undo") { [weak self, record] in
                undoManager?.removeAllActions(withTarget: record)
                self?.restore(record, undoManager: nil)
            })
        }
    }

    /// Puts trashed conversations back and selects the first. With `undoManager` (Edit › Undo), Redo moves them to the
    /// Trash again. A deletion that has synced comes back under a new ID (`LibraryController.restoreFromTrash`).
    private func restore(_ record: TrashRecord, undoManager: UndoManager?) {
        if let undoManager {
            Self.registerUndo(on: undoManager, name: "Move to Trash", target: record) { [weak self, record] in
                self?.trashMeetings(record.ids, undoManager: undoManager)
            }
        }
        withdraw(record.message)
        let ids = record.ids
        Task {
            var restored: [UUID] = []
            for id in ids {
                do { restored.append(try await library.restoreFromTrash(id).id) }
                catch { report("Couldn’t Put It Back", "Try again.", error) }
            }
            record.ids = restored
            guard let first = restored.first else { return }
            if !visibleMeetings.contains(where: { $0.id == first }) { place = .section(.all) }
            selectedID = first
        }
    }

    /// Registers an undo, in a group of its own when nothing has opened one (an undo manager that doesn't group by
    /// event, as tests use).
    private static func registerUndo(on undoManager: UndoManager, name: String, target: TrashRecord, _ handler: @escaping @MainActor () -> Void) {
        let opens = !undoManager.groupsByEvent && undoManager.groupingLevel == 0 && !undoManager.isUndoing && !undoManager.isRedoing
        if opens { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: target) { _ in MainActor.assumeIsolated { handler() } }
        undoManager.setActionName(name)
        if opens { undoManager.endUndoGrouping() }
    }

    /// The conversations the list shows now, in its order: the search's results while searching.
    var listedMeetingIDs: [UUID] { isSearching ? searchHits.map(\.meetingID) : visibleMeetings.map(\.id) }

    /// The row to select when `removed` leave `order`: the first after them, else the last before them.
    nonisolated static func neighbour(of removed: Set<UUID>, in order: [UUID]) -> UUID? {
        guard let last = order.lastIndex(where: removed.contains) else { return nil }
        if let next = order[(last + 1)...].first(where: { !removed.contains($0) }) { return next }
        return order[..<last].last { !removed.contains($0) }
    }
}

extension AppState {
    /// A new recording's title: the call's name, or "Conversation", and when it started ("Conversation at 10:15 AM").
    nonisolated static func recordingTitle(_ name: String?, at date: Date) -> String {
        "\(name.flatMap { $0.isEmpty ? nil : $0 } ?? "Conversation") at \(date.formatted(date: .omitted, time: .shortened))"
    }

    /// Records into `existing` when given (a notes-only conversation), otherwise into a new conversation.
    func startRecording(title: String? = nil, automatic: Bool = false, into existing: UUID? = nil) async {
        guard isReady, recordingID == nil, !isStartingRecording, !isStoppingRecording else { return }
        guard !automatic || callPolicy != .off else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        let previousSelection = selectedID
        let into = existing.flatMap { id in canRecordInto(id) ? id : nil }
        let id = into ?? newMeeting(title: Self.recordingTitle(title, at: Date()))
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
            // A conversation recorded into again, however it was started, is no longer one that stopped short.
            unexpectedStops[id] = nil
            recordingStartedAt = recorder.startedAt ?? Date()
            update(id) { $0.status = .recording; $0.date = recordingStartedAt ?? Date() }
            recordingDidStart(id)
            sync.publishActivity(recording: id, since: recordingStartedAt)
            if preferences.object(forKey: Preference.showsFloatingNotesWhileRecording) as? Bool ?? true { showNotes(for: id) }
        } catch {
            finishCaptions()
            if let partial = recorder.lastResult, !partial.tracks.isEmpty {
                recordingID = id
                await finishCapture(partial)
            } else {
                // Nothing was recorded. A conversation made for it goes again, so no empty one claims a recording was
                // saved; one recorded into (notes, or a phone's) stays as it was. Why is the alert's to say.
                sources.captures[id] = nil
                if into == nil { await discardUnrecorded(id, selecting: previousSelection) }
            }
            if automatic { monitor.suppressCurrentMeeting() }
            var problem = AppProblem(title: "Couldn’t Start Recording", fallback: "Try again.", error: error)
            problem.privacyPane = PrivacySettings.pane(for: error)
            self.problem = problem
        }
    }

    /// A conversation `startRecording` made for a recording that never started: it goes to the Trash (the library's one
    /// way out, so a copy that already synced goes too), and the selection goes back to where it was. Notes, photos, or
    /// bookmarks added while it tried to start (a permission prompt can take a while) keep it.
    private func discardUnrecorded(_ id: UUID, selecting previous: UUID?) async {
        guard let meeting = meetings.first(where: { $0.id == id }), meeting.tracks.isEmpty, meeting.highlights.isEmpty,
              meeting.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, meeting.visiblePhotos.isEmpty else { return }
        if selectedID == id { selectedID = previous.flatMap { previous in meetings.contains { $0.id == previous } ? previous : nil } }
        do { _ = try await library.moveToTrash(id) }
        catch { Self.log.notice("An empty conversation couldn't be removed: \(error.localizedDescription, privacy: .public)") }
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
        sync.publishActivity(recording: nil)
        phones.recordingEnded(id)
        do {
            try await ingestCapture(result, meetingID: id)
            sourcesAfterCapture(id, startedAt: result.startedAt, captureID: result.id)
            // Added to the notice: it may already say why the recording stopped.
            if !result.warnings.isEmpty { post(result.warnings) }
            enqueue(id)
        } catch {
            update(id) { $0.status = .failed; $0.errorMessage = "Recording is preserved in the recovery folder: \(error.localizedDescription)" }
            report("Couldn’t Add the Recording", "It’s kept, and Daybook adds it the next time it opens.", error)
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
                    library.add(Meeting(id: id, title: Self.recordingTitle(nil, at: result.startedAt), date: result.startedAt))
                }
                try await ingestCapture(result, meetingID: id)
                sources.recovered.append((id, result.startedAt, result.endedAt))
                // Transcribed as a recording that stopped normally is, and said by name, with a way to it.
                enqueue(id)
                let title = meetings.first { $0.id == id }?.title ?? ""
                post(title.isEmpty ? "Recovered a recording." : "Recovered “\(title)”.",
                     action: LibraryNoticeAction(title: "Show") { [weak self] in self?.showConversation(id) })
            } catch { report("Couldn’t Recover a Recording", "An interrupted recording couldn’t be recovered. Its files are kept.", error) }
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

/// A highlights sidecar an import reads, with the access it was granted held until the import is done.
struct ImportSidecar {
    let url: URL?
    let scoped: Bool
    func close() { if scoped { url?.stopAccessingSecurityScopedResource() } }
}

/// The library's errors, shared with the devices that import into it.
typealias AppError = DaybookError

/// Conversations moved to the Trash together, for Undo and Redo: their IDs change when a synced deletion comes back.
@MainActor
final class TrashRecord {
    var ids: [UUID]
    /// The notice's line for it.
    let message: String
    init(ids: [UUID], message: String) { self.ids = ids; self.message = message }
}

/// A text button the library notice offers with what it says (`AppState.post(_:action:)`): Undo, Show, Show in Finder.
struct LibraryNoticeAction {
    /// The button's words, a verb: "Undo", "Show", "Show in Finder".
    let title: String
    let perform: @MainActor () -> Void
}
