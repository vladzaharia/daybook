import DaybookCaptions
import ActivityKit
import Combine
import CryptoKit
import DaybookKit
import DaybookLink
import DaybookModelStore
import Foundation
import Observation
import SwiftUI
import UIKit
import WidgetKit

/// The phone app's coordinator: the recorder, the library and its sync, the local link to Macs,
/// recorders, the Live Activity, and the state the widgets read. Intents, the Live Activity's
/// buttons, a Mac's record requests, and the interface all go through it.
///
/// For the reading UI (docs in Apps/iOS/README.md, "Services for the interface"):
/// - `macPresence`: whether a Mac that transcribes is around ("Waiting for your Mac · last seen 2 h ago").
/// - `liveProgress[meetingID]`: a Mac's live progress over the link ("Transcribing on Studio Mac · 40%").
/// - `audio`: the sync-backed `AudioProviding`, also injected as `\.audioProvider`.
@MainActor
@Observable
final class PhoneAppModel: RecordingCommandHandling {
    let recorder: PhoneRecorder
    let library: PhoneLibrary
    let posture: DevicePosture
    let options: LaunchOptions
    let settings: PhoneSettings
    let sync: PhoneSync
    let link: PhoneLink
    let devices: PhoneDevices
    let audio: SyncAudioProvider
    /// The rolling input meter on the recording screen.
    let levels = LevelHistory()
    /// Tentative on-device captions while recording (never the transcript).
    let captions: LiveCaptionsController
    /// The models live captions run on this iPhone, and those that process its recordings, when
    /// downloaded (Settings › Models).
    let models: PhoneModels
    /// Cloud summaries' keys, models, and this iPhone's preferences (Settings › Cloud; docs/cloud.md): the one place the
    /// summary placement reads them (`placement.cloud`, set at launch). Tests keep keys in memory.
    @ObservationIgnored lazy var cloudSummaries: CloudSetup = {
        #if DEBUG
        if let demo = PhoneCloudDemo.setup(defaults: .standard) { return demo }
        #endif
        if LaunchOptions.isTestHost { return CloudSetup(keys: MemoryCloudKeyStore(), defaults: Self.testDefaults()) }
        return CloudSetup(keys: KeychainCloudKeyStore.system, defaults: .standard)
    }()
    /// Processing this iPhone's own recordings with those models (docs/iphone.md, "Processing on this iPhone").
    let processor: PhoneProcessor
    /// Where this iPhone's summaries run, with the countdown before them (docs/multipoint.md, "Where summaries run").
    let placement: PhoneSummaryPlacement
    /// "Upgrade" offers on the conversation page (docs/multipoint.md, "Upgrade").
    let upgrades: PhoneUpgrades
    /// One line for the person, when something needs saying: what happened, in plain words.
    private(set) var notice: String? {
        didSet { noticeDetails = nil; noticeFix = nil }
    }
    /// The system's own words behind the notice, shown only behind Details.
    private(set) var noticeDetails: String?
    /// What the notice's button does, when there's a fix.
    private(set) var noticeFix: NoticeFix?
    /// The recording is being saved to the library.
    private(set) var isFiling = false
    /// The conversation filed last, for the interface to point at.
    private(set) var lastFiledID: UUID?
    /// Files being imported from Files or the share sheet.
    private(set) var importing = 0
    /// The conversation imported last.
    private(set) var lastImportedID: UUID?
    /// While a Mac records this conversation too, or asked this iPhone to. Kept in the recording's
    /// journal, so a recording recovered after Daybook was killed still joins and stops its Macs.
    var multipoint: MultipointSession? {
        didSet { if multipoint != oldValue { recorder.setMultipoint(multipoint?.journaled) } }
    }
    /// The Mac whose device page started this recording (a conversation of this iPhone's own).
    @ObservationIgnored private var startedFromMac: UUID?
    /// A shared recording this iPhone takes part in only through its recorder: its button started it
    /// while Daybook was in the background, where iOS doesn't let this iPhone start its microphone.
    var recorderOnly: RecorderOnlyRecording?
    /// Notes and bookmarks of the shared recording, kept in step with the Macs recording it too.
    @ObservationIgnored let sharedNotes = SharedNotesTracker()
    @ObservationIgnored var notesShare: Task<Void, Never>?
    /// Until when a Mac that connects is asked to join this iPhone's recording on its own (the link can
    /// take a few seconds to come back as the app comes forward or wakes in the background).
    @ObservationIgnored var cascadeAsksUntil: Date?
    /// The stop under way came from a Mac (it asked, or this iPhone followed it): that Mac isn't asked
    /// to stop in turn.
    @ObservationIgnored var stopIsFromMac = false
    /// Notifications for a recorder recording while this iPhone can't (the app's own; none in tests).
    @ObservationIgnored var cascadeNotices = CascadeNotices.silent
    /// Recording here asks the connected Macs on its own (a cascading start). Tests of the person's own
    /// "Record on Studio Mac too" turn it off.
    @ObservationIgnored var cascadesToMacs = true
    /// A recorder's button is starting a recording here.
    @ObservationIgnored var startingFromRecorder = false
    /// Stops this iPhone owes Macs it started, by Mac: the conversation to stop. Kept in a file in the
    /// library's folder that never syncs (`owedStops`), so a relaunch still sends them as the Mac connects.
    @ObservationIgnored private(set) var pendingStops: [UUID: UUID] = [:] {
        didSet { if pendingStops != oldValue { saveOwedStops() } }
    }
    /// When each of `pendingStops` was first owed.
    @ObservationIgnored private var owedSince: [UUID: Date] = [:]
    @ObservationIgnored private let owedStops: OwedStopsStore<OwedMacStop>
    @ObservationIgnored private var stopsInFlight: Set<UUID> = []
    private(set) var isForeground = true

    @ObservationIgnored private let activities = RecordingActivityController()
    @ObservationIgnored private var demo: Task<Void, Never>?
    @ObservationIgnored private var launched = false
    @ObservationIgnored private let sharedState = SharedStatePublisher()
    @ObservationIgnored private var lastStateSent = Date.distantPast
    /// The recorders this iPhone manages, as last sent to Macs.
    @ObservationIgnored var lastRecorders: [LinkRecorderState]?
    /// The audio session synthetic demos use, so a script can interrupt the recording.
    @ObservationIgnored var demoAudioSession: ScriptedAudioSession?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    /// Labelling saved captions' speakers from their recordings (`labelCaptionSpeakers`).
    @ObservationIgnored private var speakerPass: (id: UUID, task: Task<Void, Never>)?
    /// Recorders recording along: their live audio's captions join this iPhone's.
    @ObservationIgnored let recorderCaptions = LiveCaptureCaptions()
    /// This iPhone's captions going to each Mac recording the same conversation (`shareCaptions`).
    @ObservationIgnored private var captionShares: [UUID: CaptionShare] = [:]
    @ObservationIgnored private var captionSharing: Task<Void, Never>?
    /// Heat, power, and battery changes the processor backs off for.
    @ObservationIgnored private var processingObservers: [NSObjectProtocol] = []

    init(recorder: PhoneRecorder, library: PhoneLibrary, posture: DevicePosture, options: LaunchOptions,
         settings: PhoneSettings? = nil, link: PhoneLink? = nil, devices: PhoneDevices? = nil) {
        let settings = settings ?? PhoneSettings(defaults: LaunchOptions.isTestHost ? Self.testDefaults() : .standard)
        self.recorder = recorder
        self.library = library
        self.posture = posture
        self.options = options
        self.settings = settings
        sync = PhoneSync(library: library.controller)
        self.link = link ?? PhoneLink(identity: PhoneLink.identity(installation: library.installationID, name: ProcessingRequest.Device.currentName,
                                                                   libraryID: nil, syncDeviceID: library.controller.thisDevice.id),
                                      keyStore: LaunchOptions.isTestHost ? MemoryLinkKeyStore() : KeychainLinkKeyStore())
        self.devices = devices ?? PhoneDevices(library: library, settings: settings,
                                               mode: LaunchOptions.isTestHost ? .inert : (options.deviceSimulator ? .simulator : .live),
                                               defaults: LaunchOptions.isTestHost ? Self.testDefaults() : .standard)
        audio = SyncAudioProvider(library: library, sync: sync, budget: settings.audioCacheBudget)
        // Stops a previous run owed, sent as each Mac connects.
        let owedStops = OwedStopsStore<OwedMacStop>(file: library.rootURL.appendingPathComponent(Self.owedStopsFile))
        let owed = owedStops.load()
        self.owedStops = owedStops
        owedSince = Dictionary(owed.map { ($0.macID, $0.owedAt) }, uniquingKeysWith: { _, later in later })
        pendingStops = Dictionary(owed.map { ($0.macID, $0.conversationID) }, uniquingKeysWith: { _, later in later })
        let models = PhoneModels(root: LaunchOptions.isTestHost ? FileManager.default.temporaryDirectory
                                    .appendingPathComponent("DaybookPhoneModels-\(UUID().uuidString)", isDirectory: true) : PhoneModels.defaultRoot,
                                 defaults: LaunchOptions.isTestHost ? Self.testDefaults() : .standard,
                                 // Tests never download, nor reach the system's background sessions.
                                 fetcher: LaunchOptions.isTestHost ? HubSnapshotFetcher() : PhoneModels.downloads)
        self.models = models
        let audio = self.audio
        processor = PhoneProcessor(library: library.controller, services: PhoneProcessor.Services(
            engine: { [weak models] in models?.processingEngine() },
            summarizer: { [weak models] in models?.summarizer() },
            capabilities: { [weak models, weak settings] in
                models?.capabilities(enabled: settings?.processesOnThisIPhone ?? false)
                    ?? ProcessingCapabilities(transcribes: false, findsSpeakers: false, summarizes: false)
            },
            owns: { [weak library] in library?.ownsTrack ?? { _ in false } },
            // Its own recordings are kept here until iCloud has them; one that went back since comes down again.
            audio: { track, id in try await audio.localAudio(for: track, in: id, progress: { _ in }) },
            release: { [weak models] in await models?.releaseProcessingModels() }),
            // The system's continued-processing task, never in tests.
            continued: ContinuedProcessing(scheduler: LaunchOptions.isTestHost || options.isRunningTests ? nil : SystemContinuedProcessingScheduler()))
        let sync = self.sync, link = self.link
        placement = PhoneSummaryPlacement(library: library.controller, link: link, presence: { sync.devices })
        upgrades = PhoneUpgrades(library: library.controller, placement: placement, link: link, presence: { sync.devices })
        captions = LiveCaptionsController(store: LiveCaptionStore(libraryRoot: library.rootURL),
                                          makeCaptioner: Self.captioner(settings: settings, options: options, models: models))
        models.voices.metadata = { [weak library] in library?.controller.metadata ?? LibraryMetadata() }
        // Live recognizers are biased toward the library's approved vocabulary, as it changes.
        library.controller.$glossary
            .map { $0.filter(\.approved).map(\.term) }
            .removeDuplicates()
            .sink { [weak models] terms in models?.vocabulary.update(terms) }
            .store(in: &subscriptions)
        // A recorder's Listen Live is captioned like recordings: the live models when downloaded.
        self.devices.hub.environment.liveCaptions.makeCaptioner = Self.listenLiveCaptioner(settings: settings, options: options, models: models)
        self.devices.hub.environment.liveCaptions.locale = { [weak settings] in settings?.captionLocale ?? .current }
        recorder.onChange = { [weak self] in self?.recorderChanged() }
        recorder.onLevel = { [weak self] level in self?.levelChanged(level) }
        recorder.onUnexpectedStop = { [weak self] recording in
            Task { await self?.finishUnexpectedly(recording) }
        }
        sync.protectedConversation = { [weak self] in self?.recorder.captureID }
        sync.onApplied = { [weak self] _ in
            self?.publish()
            // What a Mac did may stop a summary here, or end a countdown it has taken.
            self?.placement.syncApplied()
            // A pass may have made a folder an encrypted library keeps out of backups.
            self?.applyBackupExclusion()
            // Work another device took over stops here; new work starts.
            self?.processor.reconcileClaims()
        }
        self.link.recordRequestHandler = { [weak self] mac, request in
            await self?.answer(mac, request) ?? .refused(LinkRecordRefusal(reason: .unsupported))
        }
        self.link.onProcessingFinished = { [weak self] _ in
            Task { await self?.sync.synchronize(.linkFinished) }
        }
        self.link.onMacRecordingState = { [weak self] mac, state in self?.macReported(state, from: mac) }
        self.link.onMacConnected = { [weak self] mac in self?.macConnected(mac) }
        self.link.onSharedNotes = { [weak self] message, mac in self?.macSharedNotes(message, from: mac) }
        self.devices.hub.onRecorderButton = { [weak self] session, on in self?.recorderButton(session, on) }
        self.devices.cascade.onChange = { [weak self] in self?.sendRecordingState(force: true) }
        if !LaunchOptions.isTestHost { cascadeNotices = .app }
        self.link.onLibraryKeyMessage = { [weak self] message, mac in self?.libraryKeyMessage(message, from: mac) }
        self.devices.onImported = { [weak self] filed in self?.filedElsewhere(filed) }
        wireRecorderHandoff()
        // Macs hear what the recorders this iPhone manages are doing, when that changes.
        self.devices.hub.recorderChanges()
            .sink { [weak self] in
                guard let self else { return }
                let cascade = self.devices.cascade
                guard self.devices.hub.recorderStates(conversation: { cascade.sharedConversation(of: $0) }) != self.lastRecorders else { return }
                self.sendRecordingState(force: true)
            }
            .store(in: &subscriptions)
        // An encrypted library keeps its conversations out of backups (`BackupExclusion`).
        library.controller.sync?.$encryption.removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.applyBackupExclusion() } }
            .store(in: &subscriptions)
        // A recorder recording along is captioned from its live audio, beside this iPhone's captions.
        recorderCaptions.follow(self.devices.hub, conversation: { [weak self] in self?.captions.activeMeetingID }) { [weak self] update in
            self?.recorderCaptioned(update)
        }
        // A conversation moved to the Trash takes its live captions with it.
        library.controller.$meetings.map(\.count).removeDuplicates().dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.pruneCaptions() } }
            .store(in: &subscriptions)
        wireProcessing()
    }

    /// Which captioner a recording gets: the live models when they're downloaded (`PhoneModels`:
    /// local transcription, speakers, and names), else the Speech framework (downloading its
    /// language only for a real recording, never in simulator demos); a script for
    /// `--demo-captions`; none in tests (they inject one) or when the setting is off.
    static func captioner(settings: PhoneSettings, options: LaunchOptions, models: PhoneModels? = nil) -> () -> (any LiveCaptioning)? {
        { [weak settings, weak models] in
            guard let settings, settings.liveCaptions else { return nil }
            if options.demoCaptions { return ScriptedCaptioner.demo() }
            if LaunchOptions.isTestHost { return nil }
            // A real recording may download the language and, if the analyzer needs it, ask once for
            // speech-recognition permission; simulator demos with synthetic audio never do either.
            let speech = { SpeechCaptioner(allowsDownload: !options.syntheticAudio, asksForAuthorization: !options.syntheticAudio) as any LiveCaptioning }
            guard let models, !options.syntheticAudio else { return speech() }
            return models.captioner(locale: settings.captionLocale, fallback: speech)
        }
    }

    /// Listen Live's captioner: the same choice as recordings, with the recorder's longer backlog.
    static func listenLiveCaptioner(settings: PhoneSettings, options: LaunchOptions, models: PhoneModels) -> () -> (any LiveCaptioning)? {
        { [weak settings, weak models] in
            // Tests inject their own; the device simulator's demos never load models or download a language.
            guard !LaunchOptions.isTestHost, let settings, settings.liveCaptions else { return nil }
            let speech = { LiveCaptionHooks.speechCaptioner(allowsDownload: false) }
            guard let models, !options.syntheticAudio, !options.deviceSimulator else { return speech() }
            return models.captioner(locale: settings.captionLocale, backlog: LiveCaptionHooks.backlog, fallback: speech)
        }
    }

    /// Recorder handoff over the link: Macs on Wi‑Fi are its peers; its messages go to and from them.
    private func wireRecorderHandoff() {
        let link = self.link, handoff = devices.handoff
        handoff.link = RecorderHandoff.Link(peers: {
            link.connectedMacs.map { mac in
                RecorderHandoff.Peer(linkID: mac.id, syncID: mac.syncDeviceID ?? mac.id.uuidString, name: mac.name,
                                     deviceClass: .mac, handsOffRecorders: mac.handsOffRecorders)
            }
        }, send: { message, mac in try await link.send(message, to: mac) })
        handoff.handsBackAutomatically = settings.handsRecorderBackToMac
        link.onHandoffMessage = { message, mac in handoff.receive(message, from: mac) }
        link.onMacsChanged = { [weak self] in
            DispatchQueue.main.async {
                handoff.peersChanged()
                // A Mac that comes or goes changes where a summary can go.
                self?.placement.refresh()
            }
        }
    }

    private func pruneCaptions() {
        captions.prune(trashed: Set(library.controller.trashedMeetingIDs()))
    }

    // MARK: Library keys

    /// A Mac waiting for the encrypted library's key asked for it (it gets it when its library is this one), or a Mac
    /// sent it.
    private func libraryKeyMessage(_ message: LinkMessage, from macID: UUID) {
        guard let controller = sync.controller else { return }
        switch message {
        case .libraryKeyRequest(let request):
            guard let mac = link.macs.first(where: { $0.id == macID }) else { return }
            Task {
                let grants = await controller.libraryKeyGrants(for: request, peerLibraryID: mac.libraryID)
                var sent = false
                for grant in grants where (try? await link.send(.libraryKeyGrant(grant), to: macID)) != nil { sent = true }
                if sent { notice = "Sent this library’s key to \(mac.name)." }
            }
        case .libraryKeyGrant(let grant):
            Task { await controller.accept(grant) }
        default:
            break
        }
    }

    /// Asks a connected Mac for the encrypted library's key this iPhone is waiting for.
    func requestLibraryKey(from macID: UUID) async {
        guard let request = await sync.controller?.libraryKeyRequest() else { return }
        try? await link.send(.libraryKeyRequest(request), to: macID)
    }

    private static func testDefaults() -> UserDefaults {
        UserDefaults(suiteName: "DaybookPhoneTests-\(ProcessInfo.processInfo.processIdentifier)") ?? .standard
    }

    var isRecordingActive: Bool { recorder.isActive }

    /// Whether the library's iCloud container is reachable, for the interface to say so plainly.
    var cloud: CloudAvailability {
        switch sync.connection {
        case .checking: return .checking
        case .connected(let url): return .available(url)
        case .unavailable(let reason): return .unavailable(reason)
        }
    }

    /// Whether a Mac that transcribes is around: live over the link, or by its last sync.
    var macPresence: MacPresence {
        let reason: String? = { if case .unavailable(let reason) = sync.connection { return reason } else { return nil } }()
        return MacPresence.resolve(connectedMac: link.connectedMacs.first(where: \.canProcess)?.name, devices: sync.devices,
                                   syncAvailable: sync.isConnected, syncReason: reason, devicesListed: sync.devicesListed)
    }

    /// A paired Mac the link has no recording state for, but whose presence in the library says it's
    /// recording ("Recording now" in Settings › Macs).
    func isRecordingBySync(_ mac: PhoneLink.Mac, now: Date = Date()) -> Bool {
        guard mac.recording == nil else { return false }
        let id = mac.syncDeviceID ?? mac.id.uuidString
        return sync.devices.contains { $0.id == id && $0.deviceClass == .mac && $0.isRecording(at: now) }
    }

    /// A Mac's live processing progress by conversation, finer than what sync carries.
    var liveProgress: [UUID: LiveProgress] { link.liveProgress }

    /// The one honest line for a conversation's processing on the phone, or nil when there's
    /// nothing to say (done, or nothing asked): live progress over the link first, then what sync
    /// says (a Mac's claim with its coarse progress, a request waiting, a failure).
    ///
    /// A Mac claims a request only when the job starts, so "Waiting" can last while it's busy; the
    /// line says so when the link knows ("Waiting for Studio Mac, which is transcribing another
    /// conversation").
    func processingLine(for meeting: Meeting, now: Date = Date()) -> String? {
        if let live = liveProgress[meeting.id] { return live.line }
        switch ProcessingStatus.phone(meeting, now: now) {
        case .processing(let progress):
            let verb: String
            switch progress.stage {
            case .summarizing: verb = "Summarizing"
            case .identifyingSpeakers: verb = "Identifying speakers"
            case .transcribing: verb = "Transcribing"
            }
            let percent = progress.fraction.map { " · \(Int(($0 * 100).rounded(.down)))%" } ?? ""
            // No device: this iPhone's own work (`ProcessingStatus.phone`).
            return "\(verb) on \(progress.device?.name ?? "this iPhone")\(percent)"
        case .requested(.device):
            let presence = macPresence
            if case .connected(let name) = presence, let mac = link.connectedMacs.first(where: { $0.name == name }) {
                if mac.isRecording { return "Waiting for \(name), which is recording" }
                if liveProgress.values.contains(where: { $0.macName == name && !$0.isFinished && $0.meetingID != meeting.id }) {
                    return "Waiting for \(name), which is transcribing another conversation"
                }
            }
            return presence.waitingLine(now: now)
        case .recorded:
            return "Not transcribed yet"
        case .transcribed:
            return "Not summarized yet"
        case .failed(let failure):
            return failure.device.map { "\($0.name) couldn’t finish" } ?? "Couldn’t finish"
        case .awaitingRecordings(let recordings):
            return ProcessingStatus.awaitingLine(recordings)
        case .requested(.queued):
            return "Waiting on this iPhone"
        case .requested(.paused):
            return processor.pause.map(StatusPresentation.pausedLine) ?? "Paused"
        case .requested, .done:
            return nil
        }
    }

    /// First appearance: load the library, file anything a previous run left behind, connect sync
    /// and the link, and run any debug launch script.
    func launch() async {
        guard !launched else { return }
        launched = true
        do { try await library.reload() }
        catch {
            launched = false
            say(Self.libraryUnavailable, details: error.localizedDescription)
            return
        }
        if let folder = options.syncFolder {
            try? sync.connect(toFolder: URL(fileURLWithPath: folder, isDirectory: true), monitor: true)
            if let mac = options.demoMac { Self.writeDemoPresence(name: mac.name, hoursAgo: mac.hoursAgo, in: URL(fileURLWithPath: folder)) }
        } else if !options.isRunningTests {
            await sync.connect()
        }
        guard !options.isRunningTests else { return }
        if !recorder.isActive { activities.endOrphans() }
        await recoverLeftovers()
        pruneCaptions()
        if let probe = options.captionProbe { Task { await CaptionProbe.run(file: probe.isEmpty ? nil : probe, locale: settings.captionLocale) } }
        publish()
        devices.start()
        if !LaunchOptions.isTestHost {
            if options.demoLink || options.demoMultipointMac != nil { applyLinkDemo() } else { await link.start() }
        }
        await sync.synchronize(.launch)
        // Settings › Cloud: whether a summary can go to the cloud, and which model.
        placement.cloud = cloudSummaries
        await placement.reloadCloud()
        // Work a previous run claimed or paused carries on, and anything filed since is picked up.
        processor.pickUp()
        // Summaries this iPhone held when Daybook stopped (mid-countdown, say) are placed again.
        await placement.resumeHeldSummaries()
        let libraryID = await sync.libraryID()
        await link.updateLibrary(libraryID)
        await audio.setBudget(settings.audioCacheBudget)
        if let path = options.importFile { await importFiles([URL(fileURLWithPath: path)]) }
        if options.deviceAutopilot { runDeviceAutopilot() }
        if options.handoffDemo != nil || options.demoLiveCaptions || options.demoTransfer != nil { runStatusDemo() }
        #if DEBUG
        if PhonePlacementDemo.scenario != nil { Task { await PhonePlacementDemo.apply(to: self) } }
        #endif
        if options.startRecording, !recorder.isActive {
            try? await startRecording()
            runDemoScript()
        }
        if let name = options.demoRecorderOnly, !recorder.isActive {
            // After the scene has come forward, which would otherwise record along at once.
            try? await Task.sleep(for: .seconds(1))
            recorderOnly = RecorderOnlyRecording(conversationID: UUID(), title: "Conversation at \(Date().formatted(date: .omitted, time: .shortened))",
                                                 startedAt: Date(), recorderID: "demo", recorderName: name)
        }
    }

    // MARK: Scene phase

    /// The scene moved to the foreground or background: sync, the link, and devices follow.
    func scenePhaseChanged(_ phase: ScenePhase) {
        isForeground = phase == .active
        sync.isForeground = isForeground
        processor.conditions.screen = phase == .active ? .active : phase == .inactive ? .inactive : .background
        devices.foregroundChanged(isForeground)
        DeviceNotifications.isInForeground = { [weak self] in self?.isForeground ?? false }
        switch phase {
        case .active:
            if recorderOnly != nil, !recorder.isActive { Task { await recordAlongWithRecorder() } }
            labelCaptionSpeakers()
            Task {
                await sync.synchronize(.foreground)
                await link.setActivity(.foreground)
                let libraryID = await sync.libraryID()
                await link.updateLibrary(libraryID)
                // A key added on another device meanwhile arrives through iCloud Keychain.
                await placement.reloadCloud()
            }
        case .background:
            // A countdown can't run in the background: each one's default happens now.
            placement.leftForeground()
            // Out of sight it stops; it starts over the next time the app is in front.
            speakerPass?.task.cancel()
            speakerPass = nil
            sync.scheduleBackgroundRefresh()
            if sync.localChanges > 0 || sync.isSyncing { sync.synchronizeFinishing(.edit) }
            Task { await link.setActivity(recorder.isActive || recorderOnly != nil ? .backgroundRecording : .background) }
        default:
            break
        }
    }

    /// Captions saved while the live speaker model missed part of the recording (speakers shed under
    /// heat, Low Power Mode, or a low battery, or the model failed) get their speakers from the
    /// recording itself (`LiveSpeakerPass`), once the app is in front and not recording. Leaving the
    /// screen stops it; it starts over next time.
    func labelCaptionSpeakers() {
        // Processing this iPhone's recordings goes first: one heavy job at a time.
        guard isForeground, !recorder.isActive, speakerPass == nil, !processor.isBusy else { return }
        let waiting = captions.waitingForSpeakers()
        guard !waiting.isEmpty else { return }
        let id = UUID()
        let task = Task { [weak self] in
            for saved in waiting {
                guard let self, !Task.isCancelled, self.isForeground, !self.recorder.isActive, !self.processor.isBusy else { break }
                guard let meeting = self.library.controller.meeting(saved.meetingID), meeting.showsLiveCaptions,
                      let track = meeting.tracks.first(where: { $0.id == saved.trackID }),
                      let url = try? await self.library.audioURL(for: track, in: meeting.id),
                      FileManager.default.fileExists(atPath: url.path) else { continue }
                guard let labelled = try? await self.models.labelSpeakers(saved, recording: url), !Task.isCancelled else { continue }
                self.captions.saveLabelled(labelled)
            }
            if self?.speakerPass?.id == id { self?.speakerPass = nil }
        }
        speakerPass = (id, task)
    }

    // MARK: Processing this iPhone's recordings

    /// What this iPhone can do with its own models now, for the summary step and other devices.
    var processingCapabilities: ProcessingCapabilities { models.capabilities(enabled: settings.processesOnThisIPhone) }

    /// This iPhone's own summarizer: its summary model, downloaded and fitting, while Transcribe on This iPhone is on.
    private var processingSummarizer: (any LocalSummarizing)? {
        settings.processesOnThisIPhone && processingCapabilities.summarizes ? models.summarizer() : nil
    }

    /// A processing model was downloaded or removed, or Transcribe on This iPhone changed: the placement learns whether
    /// this iPhone can summarize, and the processor picks up what it can do now.
    func processingChanged() {
        placement.localSummarizer = processingSummarizer
        processor.pickUp()
    }

    /// The processor's ties to the rest of the app: which recordings it may claim as they're filed, the
    /// models changing, the speaker pass giving way, and the heat, power, and battery it backs off for.
    private func wireProcessing() {
        PhoneProcessor.current = processor
        let processor = self.processor, models = self.models, placement = self.placement
        library.processesHere = { [weak self] in self?.processor.device }
        models.changed = { [weak self] in self?.processingChanged() }
        // One summary path: transcribed and fused here, the summary goes to the placement (a countdown, then this
        // iPhone, a Mac, or the cloud); one placed here comes back to the processor, under its rules.
        processor.services.summaryDue = { [weak placement] id, templateID, askedFor in
            guard let placement else { return }
            if askedFor { placement.summarize(id, templateID: templateID) }
            else { Task { await placement.summaryIsDue(id, templateID: templateID) } }
        }
        placement.runHere = { [weak processor] id, request in processor?.summarizeHere(id, request: request) }
        placement.localSummarizer = processingSummarizer
        // An upgrade of this iPhone's own recordings is its processor's work; what it can do is what its models can.
        upgrades.capabilities = { [weak self] in self?.processingCapabilities ?? .none }
        upgrades.owns = { [weak self] in self?.library.ownsTrack ?? { _ in false } }
        upgrades.pickUp = { [weak processor] in processor?.pickUp() }
        processor.services.willStart = { [weak self] in
            self?.speakerPass?.task.cancel()
            self?.speakerPass = nil
        }
        processor.services.changed = { [weak self] in
            self?.publish()
            if self?.processor.isBusy == false { self?.labelCaptionSpeakers() }
        }
        let conditions = models.conditions
        let read: @Sendable (Notification) -> Void = { [weak processor] _ in
            // After the conditions' own observers have read the battery.
            Task { @MainActor in processor?.conditions.live = conditions.current }
        }
        for name in [ProcessInfo.thermalStateDidChangeNotification, Notification.Name.NSProcessInfoPowerStateDidChange,
                     UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification] {
            processingObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: read))
        }
        processor.conditions.live = conditions.current
        // Launched in the background (a download's events), work waits for the screen: no scene phase
        // says so until one connects.
        switch UIApplication.shared.applicationState {
        case .active: processor.conditions.screen = .active
        case .inactive: processor.conditions.screen = .inactive
        default: processor.conditions.screen = .background
        }
    }

    // MARK: Captions from every source

    /// A recorder recording along captioned its live audio, which starts with its recording: its lines
    /// move onto this iPhone's recording by when each began.
    func recorderCaptioned(_ update: LiveCaptureCaptions.Update) {
        guard let start = recorder.startedAt else { return }
        let began = update.startedAt ?? start
        captions.received(update.segments, from: .device(update.recorderID), name: update.name, offset: began.timeIntervalSince(start))
    }

    /// While recording, this iPhone's captions (and its recorder's) go to the Macs recording the same
    /// conversation that show them, a second at a time, over the local link: the Mac's captions then
    /// have every device's lines (`LinkCaptions`).
    private func startSharingCaptions() {
        captionShares = [:]
        captionSharing?.cancel()
        captionSharing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.captionShareInterval)
                guard !Task.isCancelled else { return }
                self?.shareCaptions()
            }
        }
    }

    private func stopSharingCaptions() {
        shareCaptions()
        captionSharing?.cancel()
        captionSharing = nil
        captionShares = [:]
    }

    static let captionShareInterval: Duration = .seconds(1)

    /// Sends each Mac the lines that changed since it last heard.
    func shareCaptions() {
        guard let id = recorder.captureID, let start = recorder.startedAt, captions.activeMeetingID == id else { return }
        for mac in macsShowingCaptions(id) {
            var share = captionShares[mac] ?? CaptionShare()
            let lines = share.changes(captions.segments, names: captions.sourceNames)
            captionShares[mac] = share
            guard !lines.isEmpty else { continue }
            link.sendShared([.captions(LinkCaptions(conversationID: id, startedAt: start, lines: lines))], to: [mac])
        }
    }

    /// The connected Macs recording this conversation too that show other devices' captions.
    func macsShowingCaptions(_ id: UUID) -> [UUID] {
        link.connectedMacs.filter { mac in
            mac.showsCaptions && (mac.recording?.takesPart(in: id) == true
                || multipoint.map { $0.conversationID == id && $0.macs.contains { $0.id == mac.id && $0.state == .recording } } == true)
        }.map(\.id)
    }

    // MARK: RecordingCommandHandling

    func startRecording() async throws {
        try await startRecording(into: nil, title: nil, multipoint: nil)
    }

    /// Starts recording, into a given conversation ID when a Mac asked (multipoint). Every device it
    /// reaches records too (a cascading start): its recorders, and (unless a Mac leads) the Macs connected
    /// now; `trigger` says why, and `leadRecorder` is the recorder whose button began it.
    func startRecording(into requestedID: UUID?, title requestedTitle: String?, multipoint session: MultipointSession?,
                        trigger: LinkCascade.Trigger = .person, leadRecorder: String? = nil, asksMacs: Bool = true) async throws {
        guard !recorder.isActive else { return }
        // Intents can start before the first scene loads. Never record into an unopenable library.
        do { try await library.reload() }
        catch { say(Self.libraryUnavailable, details: error.localizedDescription); throw error }
        // Another start won while the library loaded (an intent and a Mac at once): leave its recording
        // be. Asked for that same recording, this one is it; asked for another, it can't start.
        guard !recorder.isActive else {
            if requestedID == nil || requestedID == recorder.captureID { return }
            throw RecordingCommandError.failed(PhoneRecorderError.alreadyRecording.localizedDescription)
        }
        let id = requestedID ?? UUID()
        let recordingID = UUID()
        // Processing pauses first: a recording never waits for it, or shares the iPhone with it.
        processor.conditions.isRecording = true
        let title = requestedTitle ?? "Conversation at \(Date().formatted(date: .omitted, time: .shortened))"
        // Staged by the recording's own ID: the conversation may hold an earlier one still being filed.
        let directory = library.stagingURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        notice = nil
        levels.reset()
        multipoint = session
        recorder.audioTap = captions.prepare(meetingID: id)
        do {
            try await recorder.start(in: directory, id: id, recordingID: recordingID, title: title)
            recorder.setMultipoint(multipoint?.journaled)
        } catch {
            multipoint = nil
            recorder.audioTap = nil
            processor.conditions.isRecording = recorder.isActive
            await captions.finish()
            sayStartFailed(error)
            publish()
            throw Self.commandFailure(error, starting: true)
        }
        sync.controller?.publishActivity(recording: id, since: Date())
        // Captions start beside the recording, never in its way.
        let locale = settings.captionLocale
        Task { await self.captions.start(locale: locale) }
        startSharingCaptions()
        link.sampleClocks()
        // The system requires a Live Activity for a recording started in the background (an intent,
        // a Mac's request); otherwise the setting decides.
        let background = UIApplication.shared.applicationState != .active
        if !options.isRunningTests, settings.showsLiveActivity || background {
            activities.start(conversationID: id, title: title, state: activityState())
        }
        if !isForeground { Task { await link.setActivity(.backgroundRecording) } }
        sendRecordingState(force: true)
        publish()
        beginCascade(id, title: session?.title ?? title, date: session?.date ?? Date(), session: session, trigger: trigger,
                     leadRecorder: leadRecorder, asksMacs: asksMacs)
    }

    func stopRecording() async throws {
        guard recorder.isActive else { throw RecordingCommandError.notRecording }
        // A stop from a Mac (it asked, or this iPhone follows it) doesn't go back to that Mac.
        let cascadesUp = !stopIsFromMac
        stopIsFromMac = false
        let stopping = recorder.captureID
        flushSharedNotes()
        stopSharingCaptions()
        var final = activityState()
        final.phase = .saved
        final.frozenElapsed = recorder.pausedAt ?? recorder.elapsedTime
        activities.end(final)
        isFiling = true
        defer { isFiling = false }
        let session = multipoint
        let clocks = link.peerClocks { mac in session?.macs.first(where: { $0.id == mac.id })?.startedAt ?? mac.recording?.startedAt }
        // Finishing and filing must complete even if the caller is cancelled (an intent that timed
        // out, a view that went away): an unstructured task doesn't inherit cancellation.
        await Task { @MainActor in
            guard var recording = await self.recorder.stop() else {
                if let reason = self.recorder.lastError {
                    self.say("Couldn’t finish the recording. It’s kept, and Daybook tries again the next time it opens.", details: reason)
                }
                self.publish()
                return
            }
            if !clocks.isEmpty { recording.capture.peerClocks = clocks }
            self.recorder.audioTap = nil
            await self.captions.finish()
            await self.file(recording, session: session)
        }.value
        stopMacsStartedHere(session)
        endCascade(stopping, session: session, cascadesUp: cascadesUp)
        multipoint = nil
        sync.controller?.publishActivity(recording: nil)

        startedFromMac = nil
        sendRecordingState(force: true)
        if !isForeground { Task { await link.setActivity(.background) } }
    }

    func resumeRecording() async throws {
        guard recorder.isPaused else { throw RecordingCommandError.notRecording }
        do { try await recorder.resume() } catch { throw Self.commandFailure(error, starting: false) }
    }

    @discardableResult
    func addBookmark() async throws -> TimeInterval {
        guard let mark = recorder.addBookmark() else { throw RecordingCommandError.notRecording }
        if let id = recorder.captureID, multipoint != nil {
            // The same ID as the phone's own bookmark, so the Mac's copy and the synced one are one bookmark.
            link.sendBookmark(LinkBookmark(id: mark.id, conversationID: id, recordingTime: mark.time))
            sharedNotes.bookmarkShared(mark)
        }
        return mark.time
    }

    func editNotes(_ text: String) {
        // A paragraph a Mac wrote a moment ago that the editor hadn't shown yet isn't deleted by it.
        let text = sharedNotes.isActive ? sharedNotes.keepingArrivals(text, anchors: recorder.timedNotes) : text
        recorder.editNotes(text)
        scheduleNotesShare()
    }

    /// A photo from the camera opened during recording `id`. While that recording runs, the photo
    /// goes with it. If it ended while the camera was open (a Mac's Stop, a failure), the photo joins
    /// the conversation it's filed as, once filing (which holds the library's lock) is done.
    func addPhoto(_ photo: CameraPhoto, recording id: UUID?) async {
        do {
            if recorder.captureID == id, try await recorder.addPhoto(photo) != nil { return }
            guard let id else { return }
            let deadline = Date().addingTimeInterval(Self.lateFilingWait)
            while library.controller.meeting(id) == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            guard library.controller.meeting(id) != nil else {
                say(Self.photoNotSaved)
                publish()
                return
            }
            try await library.controller.addCameraPhoto(photo, to: id, origin: .thisIPhone(installation: library.installationID))
        } catch {
            say(Self.photoNotSaved, details: error.localizedDescription)
            publish()
        }
    }

    /// How long a photo taken as the recording ended waits for it to be filed.
    static let lateFilingWait: TimeInterval = 60

    func dismissNotice() { notice = nil }

    /// What a notice's button does.
    enum NoticeFix: Equatable {
        /// Daybook's page in Settings (the microphone's switch is there).
        case openSettings
    }

    /// Shows a notice: `message` in plain words, the system's text behind Details, and a fix if there is one.
    func say(_ message: String, details: String? = nil, fix: NoticeFix? = nil) {
        notice = message
        noticeDetails = details.flatMap { $0.isEmpty || $0 == message ? nil : $0 }
        noticeFix = fix
    }

    /// A recording that couldn't start: the recorder's own sentences are already plain; anything
    /// else (an audio session error) gets one, with its words behind Details.
    private func sayStartFailed(_ error: Error) {
        switch error as? PhoneRecorderError {
        case .microphoneDenied?: say("Allow Daybook to use the microphone in Settings.", fix: .openSettings)
        case let known?: say(known.localizedDescription, details: known.details)
        case nil: say("Couldn’t start recording. Try again.", details: error.localizedDescription)
        }
    }

    /// What a Shortcut, the control, or a Live Activity button says when recording couldn't start or resume: Daybook's
    /// own sentence, never the system's words (those are in the app's notice).
    static func commandFailure(_ error: Error, starting: Bool) -> RecordingCommandError {
        switch error as? PhoneRecorderError {
        case .microphoneDenied?: return .failed("Allow Daybook to use the microphone in Settings.")
        case let known? where known.details == nil: return .failed(known.localizedDescription)
        default: return .failed(starting ? "Couldn’t start recording. Open Daybook to try again." : "Couldn’t resume recording. Open Daybook to try again.")
        }
    }

    static let libraryUnavailable = "Couldn’t open your library. Close Daybook and open it again."

    /// The library is encrypted in iCloud: this iPhone syncs it so, waits for its key, or synced it so before.
    var libraryIsEncrypted: Bool {
        sync.encryption.isOn || sync.encryption == .waitingForKey || LibrarySyncEngine.hasSyncedEncryptedLibrary(localRoot: library.rootURL)
    }

    /// Keeps what Settings › Storage says out of iPhone backups (`BackupExclusion`).
    func applyBackupExclusion() {
        BackupExclusion.apply(libraryRoot: library.rootURL, inbox: library.inboxURL, library: BackupExclusion.library(
            includesLibrary: settings.includesLibraryInBackups, encrypted: libraryIsEncrypted,
            includesEncryptedLibrary: settings.includesEncryptedLibraryInBackups))
    }
    static let photoNotSaved = "Couldn’t save that photo. Take it again."

    /// What the recording screen says about a problem the recorder reported while it keeps recording
    /// (`PhoneRecorder.lastError`): nil when there's none.
    static func recorderWarning(_ lastError: String?) -> (message: String, details: String?)? {
        guard let lastError, !lastError.isEmpty else { return nil }
        let prefix = PhoneRecorder.journalWarning + ": "
        guard lastError.hasPrefix(prefix) else { return ("Something went wrong with the recording. It’s still recording.", lastError) }
        let reason = String(lastError.dropFirst(prefix.count))
        let full = reason.lowercased().contains("space")
        return (full ? "Notes and bookmarks aren’t being saved as you go. Free up space on this iPhone."
                     : "Notes and bookmarks aren’t being saved as you go.", reason)
    }

    func refreshCloud() async {
        await sync.connect()
        await sync.synchronize(.manual)
    }

    /// Before the app is terminated while recording: leave a complete file for the next launch.
    func prepareForTermination() {
        recorder.prepareForTermination()
    }

    // MARK: Multipoint

    /// Macs connected now that could record this conversation too.
    var macsToRecordWith: [PhoneLink.Mac] {
        guard recorder.isCapturing, multipoint?.isMacLed != true else { return [] }
        // A Mac that said no, or never answered, can be asked again.
        let involved = Set(multipoint?.macs.filter { [.asking, .recording, .stopped].contains($0.state) }.map(\.id) ?? [])
        return link.connectedMacs.filter { !involved.contains($0.id) && !$0.isRecording }
    }

    /// The multipoint line for the recording screen: the session, plus any Mac that reports
    /// recording this conversation on its own.
    var multipointLine: String? {
        if let line = multipoint?.line { return line }
        guard let id = recorder.captureID else { return nil }
        let names = link.connectedMacs.filter { $0.recording?.conversationID == id && $0.isRecording }.map(\.name)
        return names.isEmpty ? nil : "Also recording on \(ListFormatter.localizedString(byJoining: names))"
    }

    /// "Record on Studio Mac too": asks a connected Mac to record this conversation, with this
    /// iPhone's timing so it can be placed at once.
    ///
    /// An answer that doesn't come (a reconnect, a microphone prompt on the Mac) is asked for again
    /// with the same request, for up to `startRetryWindow`; the Mac answers a repeat with its first
    /// answer, so whether it started because of this iPhone is never lost. A Mac whose start comes
    /// back after this iPhone stopped, or that never answered, is stopped with it.
    func recordOnMac(_ macID: UUID, cascade: LinkCascade? = nil) async {
        guard let mac = link.macs.first(where: { $0.id == macID }) else { return }
        // This iPhone's own recording, or (in the background) only its recorder's.
        let own = recorder.isCapturing ? recorder.captureID : nil
        guard let id = own ?? recorderOnly?.conversationID else { return }
        // Only Macs that understand it are asked to record along with a recorder alone: an older one
        // would expect a recording from this iPhone.
        if own == nil, !mac.cascades { return }
        var session = multipoint ?? MultipointSession(conversationID: id, role: .phoneLed)
        // A Mac asked already (on its own as recording began, or by the person) isn't asked twice.
        if let asked = session.macs.first(where: { $0.id == macID }), asked.state == .asking || asked.state == .recording { return }
        // A Mac that didn't answer before is asked the same request again.
        let requestID = session.macs.first(where: { $0.id == macID && $0.state.isUnanswered })?.startRequestID ?? UUID()
        session.macs.removeAll { $0.id == macID }
        session.macs.append(MultipointSession.Mac(id: macID, name: mac.name, state: .asking, startedAt: nil, startedByPhone: true,
                                                  startRequestID: requestID))
        multipoint = session
        // This iPhone's recording (or its recorder's) sets its conversation's timeline.
        let start = own != nil ? recorder.startedAt : recorderOnly?.startedAt
        let timing = LinkTiming(startedAt: start, elapsed: start.map { max(0, Date().timeIntervalSince($0)) },
                                clockOffset: mac.clock?.offset, clockUncertainty: mac.clock?.uncertainty, timelineStart: start)
        // The conversation as this iPhone will file it, so a Mac that creates it makes the same one.
        let (title, date) = own != nil ? (recorder.title, recorder.startedAt) : (recorderOnly?.title ?? recorder.title, start)
        let stillAsking = { [weak self] in self?.multipoint?.conversationID == id && self?.multipoint?.macs.first { $0.id == macID }?.state == .asking }
        let deadline = Date().addingTimeInterval(Self.startRetryWindow)
        var result = await link.request(.start, id: requestID, conversationID: id, timing: timing, title: title, date: date,
                                        cascade: cascade, from: macID)
        while case .failure(.unreachable) = result, stillAsking(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(250))
            guard link.macs.first(where: { $0.id == macID })?.isConnected == true else { continue }
            result = await link.request(.start, id: requestID, conversationID: id, timing: timing, title: title, date: date,
                                        cascade: cascade, from: macID)
        }
        guard stillAsking() else {
            // This iPhone stopped meanwhile (and asked it to stop then); a start it made anyway is stopped too.
            if case .success(let ack) = result, !ack.wasAlreadyRecording { queueStop(of: macID, conversation: id) }
            return
        }
        switch result {
        case .success(let ack):
            multipoint?.update(macID) { entry in
                entry.state = .recording
                entry.startedAt = ack.startedAt
                entry.startedByPhone = !ack.wasAlreadyRecording
            }
        case .failure(let failure):
            let message = failure.message(mac: mac.name)
            multipoint?.update(macID) { $0.state = failure == .unreachable ? .noAnswer(message) : .failed(message) }
            notice = message
        }
        updateActivity()
        publish()
    }

    /// How long a start that gets no answer is asked again.
    static let startRetryWindow: TimeInterval = 30

    /// A Mac said what it's recording. One this iPhone records with that has stopped, or moved on to
    /// another conversation, is marked so on the recording screen. When it's the Mac that asked this
    /// iPhone to record, this iPhone stops too, and says so: its stop may never have arrived.
    private func macReported(_ state: LinkRecordingState, from macID: UUID) {
        guard let session = multipoint, let mac = session.macs.first(where: { $0.id == macID }) else { return }
        let recordsThis = state.conversationID == session.conversationID && state.phase != .idle
        guard !recordsThis else { return }
        if mac.state == .recording { multipoint?.update(macID) { $0.state = .stopped } }
        if case .macLed(let lead) = session.role, lead == macID {
            stopFollowing(lead: mac.name, conversation: session.conversationID, because: "\(mac.name) stopped recording, so this iPhone stopped too.")
            return
        }
        updateActivity()
        publish()
    }

    /// Recording because a Mac asked, and that Mac has stopped (or can't be reached any more): stop too.
    private func stopFollowing(lead name: String, conversation: UUID, because message: String) {
        guard recorder.isActive, recorder.captureID == conversation, !isFiling else { return }
        stopIsFromMac = true
        Task {
            try? await self.stopRecording()
            self.notice = message
            self.publish()
        }
    }

    /// A Mac this iPhone records for, not heard from for this long, is taken to have stopped.
    static let leaderSilenceLimit: TimeInterval = 30 * 60

    /// While recording for a Mac: one that has been unreachable for `leaderSilenceLimit` won't stop
    /// this recording itself, so this iPhone does.
    func checkLead(now: Date = Date()) {
        guard let session = multipoint, case .macLed(let lead) = session.role,
              let mac = link.macs.first(where: { $0.id == lead }), !mac.isConnected,
              let last = mac.lastConnectedAt, now.timeIntervalSince(last) > Self.leaderSilenceLimit else { return }
        stopFollowing(lead: mac.name, conversation: session.conversationID,
                      because: "\(mac.name) couldn’t be reached for \(Int(Self.leaderSilenceLimit / 60)) minutes, so this iPhone stopped recording.")
    }

    /// Whether a Mac may stop this iPhone's recording: the one that started it, or one this iPhone
    /// asked to record along. The person can always stop it here.
    func mayStop(_ macID: UUID) -> Bool {
        startedFromMac == macID || multipoint?.macs.contains(where: { $0.id == macID }) == true
    }

    /// A Mac connected: it hears this iPhone's recording state at once, and a stop that didn't reach
    /// it before goes now.
    private func macConnected(_ macID: UUID) {
        sendRecordingState(force: true)
        sendPendingStop(to: macID)
        macConnectedDuringCascade(macID)
    }

    /// Stopping here stops the Macs this iPhone started, those still being asked, and those that never
    /// answered; a Mac that was already recording keeps going.
    func stopMacsStartedHere(_ session: MultipointSession?) {
        guard let session, !session.isMacLed else { return }
        for mac in session.macs where mac.needsStop {
            multipoint?.update(mac.id) { $0.state = .stopped }
            queueStop(of: mac.id, conversation: session.conversationID)
        }
    }

    /// A stop for a Mac this iPhone started: sent now, and again whenever it connects, until it answers,
    /// even after a relaunch.
    func queueStop(of macID: UUID, conversation: UUID) {
        if pendingStops[macID] != conversation { owedSince[macID] = Date() }
        pendingStops[macID] = conversation
        sendPendingStop(to: macID)
    }

    /// Where the stops this iPhone owes are kept, in the library's folder.
    static let owedStopsFile = "owed-stops.json"

    private func saveOwedStops() {
        owedSince = owedSince.filter { pendingStops[$0.key] != nil }
        owedStops.save(pendingStops.map { OwedMacStop(macID: $0.key, conversationID: $0.value, owedAt: owedSince[$0.key] ?? Date()) })
    }

    private func sendPendingStop(to macID: UUID) {
        guard let conversation = pendingStops[macID], link.macs.first(where: { $0.id == macID })?.isConnected == true,
              !stopsInFlight.contains(macID) else { return }
        stopsInFlight.insert(macID)
        Task {
            let result = await link.request(.stop, conversationID: conversation, timing: nil, from: macID)
            stopsInFlight.remove(macID)
            // Stopped, or it says it isn't recording that (or won't stop it): either way, done.
            if case .failure(.unreachable) = result { return }
            if pendingStops[macID] == conversation { pendingStops[macID] = nil }
        }
    }

    /// A Mac's record request: start recording its conversation here (with its timing), or stop.
    func answer(_ mac: PhoneLink.Mac, _ request: LinkRecordRequest) async -> LinkRecordReply.Outcome {
        // A recorder this iPhone manages, which the Mac records along with through it. A stop names the
        // recording it means, so it never pauses one the person started since.
        if let target = request.recorder {
            guard settings.acceptsMacRecordRequests else {
                return .refused(LinkRecordRefusal(reason: .declined, message: "Recording with a Mac is turned off on this iPhone."))
            }
            let answer = await RecorderRemoteControl.answer(request, target: target, sessions: devices.sessions, cascade: devices.cascade)
            if request.action == .stop { recorderStoppedRemotely(request.conversationID) }
            return answer
        }
        // The recording's own ID, which its track carries, so the Mac's link finds it when it syncs.
        var recordingID: String? { recorder.recordingID?.uuidString }
        switch request.action {
        case .start:
            guard settings.acceptsMacRecordRequests else {
                return .refused(LinkRecordRefusal(reason: .declined, message: "Recording with a Mac is turned off on this iPhone."))
            }
            guard settings.macMayStartRecording(mac.id, pairedAt: mac.pairedAt) else {
                return .refused(LinkRecordRefusal(reason: .declined,
                                                  message: "It hasn’t allowed this Mac to start recording. Allow it in Settings › Macs on the iPhone."))
            }
            if recorder.isActive {
                if recorder.captureID == request.conversationID {
                    return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: recorder.startedAt,
                                                   recordingID: recordingID, wasAlreadyRecording: true))
                }
                return .refused(LinkRecordRefusal(reason: .recordingSomethingElse, conversationID: recorder.captureID))
            }
            // Only its recorder records another conversation (the iPhone was in the background): it can't
            // join this one as well.
            if let only = recorderOnly, only.conversationID != request.conversationID {
                return .refused(LinkRecordRefusal(reason: .recordingSomethingElse, conversationID: only.conversationID))
            }
            // A device page's Start Recording on iPhone: a conversation of this iPhone's own, which that
            // Mac may stop. Otherwise this iPhone records the Mac's conversation alongside it.
            let session = request.isStandalone ? nil : MultipointSession(
                conversationID: request.conversationID, role: .macLed(macID: mac.id),
                macs: [MultipointSession.Mac(id: mac.id, name: mac.name, state: .recording, startedAt: request.timing?.startedAt, startedByPhone: false)],
                leadStartedAt: request.timing?.startedAt, timelineStart: request.timing?.timelineStart,
                leadClockOffset: mac.clock?.offset ?? request.timing?.clockOffset.map { -$0 },
                title: request.title, date: request.date)
            // The title shown while recording; filing never writes it on the Mac's conversation.
            let title = library.controller.meeting(request.conversationID)?.title ?? request.title
            do {
                // A Mac asked: this iPhone's recorders record along; Macs aren't asked (the one that asked leads).
                try await startRecording(into: request.conversationID, title: title, multipoint: session, trigger: .device, asksMacs: false)
                if session == nil { startedFromMac = mac.id }
            } catch {
                if recorder.isActive, recorder.captureID != request.conversationID {
                    return .refused(LinkRecordRefusal(reason: .recordingSomethingElse, conversationID: recorder.captureID))
                }
                let denied = recorder.lastError == PhoneRecorderError.microphoneDenied.localizedDescription
                return .refused(LinkRecordRefusal(reason: denied ? .permissionDenied : .microphoneUnavailable, message: recorder.lastError))
            }
            // The first sample fixes the recording's start; it arrives within a few buffers.
            for _ in 0..<30 where recorder.startedAt == nil {
                try? await Task.sleep(for: .milliseconds(50))
                recorder.updateLevels()
            }
            return .accepted(LinkRecordAck(conversationID: request.conversationID, startedAt: recorder.startedAt ?? Date(),
                                           recordingID: recordingID, wasAlreadyRecording: false))
        case .stop:
            if !recorder.isActive, let only = recorderOnly, only.conversationID == request.conversationID, mayStop(mac.id) {
                // Only its recorder records this conversation: it stops with the Mac.
                Task { await self.endRecorderOnly(because: nil) }
                return .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: Date()))
            }
            guard recorder.isActive, recorder.captureID == request.conversationID else {
                return .refused(LinkRecordRefusal(reason: .notRecording, conversationID: recorder.captureID))
            }
            // Only the Mac this recording is with: the one that started it, or one this iPhone asked to record.
            guard mayStop(mac.id) else {
                return .refused(LinkRecordRefusal(reason: .declined, message: "This recording was started on the iPhone. Stop it there."))
            }
            let stoppedAt = Date(), stopped = recordingID
            // Answer now; finishing and filing a long recording can outlast the request's timeout.
            stopIsFromMac = true
            Task { try? await self.stopRecording() }
            return .accepted(LinkRecordAck(conversationID: request.conversationID, stoppedAt: stoppedAt, recordingID: stopped))
        default:
            return .refused(LinkRecordRefusal(reason: .unsupported))
        }
    }

    /// How a recording made with a Mac joins its conversation: always when a Mac leads it, and when
    /// this iPhone led, once a Mac recorded it too (or may have). Its notes and bookmarks then stay
    /// with its track until the Mac places it. Nil files it as a conversation of its own.
    func join(for recording: PhoneRecording, session: MultipointSession?) -> PhoneLibrary.Join? {
        guard let session, session.conversationID == recording.id else { return nil }
        guard session.isMacLed else {
            return session.macs.contains(where: \.mayHaveRecorded) ? PhoneLibrary.Join() : nil
        }
        // Where the phone's recording probably starts on the Mac's timeline, by the link's clocks. A
        // Mac that didn't say where its timeline began (an older one) began it with its own recording.
        let offset = session.leadClockOffset
        let zero = (session.timelineStart ?? session.leadStartedAt).map { start in offset.map { start.addingTimeInterval(-$0) } ?? start }
        return PhoneLibrary.Join(estimatedOffset: zero.map { recording.startedAt.timeIntervalSince($0) }, title: session.title, date: session.date)
    }

    // MARK: Importing

    /// Files or the share sheet: each file becomes a conversation, with a Transcribe request.
    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        importing += urls.count
        defer { importing = max(0, importing - urls.count) }
        var failures: [(name: String, reason: String)] = []
        for url in urls {
            do {
                let filed = try await library.importFile(url, requestTranscription: settings.requestsTranscription)
                lastImportedID = filed.meeting.id
                if let request = filed.request { link.nudge(request) }
            } catch {
                failures.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        if !failures.isEmpty {
            say(failures.count == 1 ? "Couldn’t import “\(failures[0].name)”." : "Couldn’t import \(failures.count) files.",
                details: failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
        }
        sync.synchronizeFinishing(.filed)
        processor.pickUp()
        publish()
    }

    /// A recorder's recording was filed: upload it now and tell a connected Mac.
    private func filedElsewhere(_ filed: PhoneLibrary.Filed) {
        if let request = filed.request { link.nudge(request) }
        sync.synchronizeFinishing(.filed)
        processor.pickUp()
        publish()
    }

    // MARK: Filing and recovery

    private func file(_ recording: PhoneRecording, session: MultipointSession? = nil) async {
        let join = join(for: recording, session: session)
        // A Mac's conversation that hasn't synced here yet: one pass first, so this files into its copy.
        if join != nil, library.controller.meeting(recording.id) == nil, sync.isConnected { await sync.synchronize(.filed) }
        do {
            let filed = try await library.fileRecording(recording, join: join, requestTranscription: settings.requestsTranscription)
            lastFiledID = filed.meeting.id
            let identity = PhoneDevice.identity(recordingID: recording.recordingID, installation: library.installationID)
            if let track = filed.meeting.tracks.first(where: { $0.device == identity }) {
                captions.attach(trackID: track.id, meetingID: filed.meeting.id)
                // Speakers the live model missed, from the recording, while the app is in front.
                labelCaptionSpeakers()
            }
            if recording.recovered { notice = "Recovered a recording Daybook was making when it quit." }
            if let request = filed.request { link.nudge(request) }
            if !options.isRunningTests { sync.synchronizeFinishing(.filed) }
            // Transcribed here when this iPhone has the models (it claimed the request as it filed it).
            processor.pickUp()
        } catch {
            say("Couldn’t add the recording to your library. It’s saved and will be added next time Daybook opens.", details: error.localizedDescription)
        }
        publish()
    }

    private func finishUnexpectedly(_ recording: PhoneRecording?) async {
        var final = activityState()
        final.phase = .saved
        activities.end(final)
        let session = multipoint
        stopMacsStartedHere(session)
        endCascade(recording?.id ?? session?.conversationID ?? devices.cascade.conversation?.id, session: session, cascadesUp: false)
        multipoint = nil
        startedFromMac = nil
        stopSharingCaptions()
        recorder.audioTap = nil
        await captions.finish()
        if let recording { await Task { @MainActor in await self.file(recording, session: session) }.value }
        say("Recording stopped. Everything up to then is saved.", details: recorder.lastError)
        publish()
    }

    /// Files recordings a killed or crashed run left in staging.
    private func recoverLeftovers() async {
        for folder in PhoneRecorder.pendingCaptures(in: library.stagingURL) where folder.standardizedFileURL != recorder.stagingDirectory?.standardizedFileURL {
            do {
                let recording = try await PhoneRecorder.recover(in: folder)
                // Made with Macs: it joins their conversation, and the ones this iPhone started are stopped.
                let session = MultipointSession(conversationID: recording.id, journaled: recording.multipoint)
                await file(recording, session: session)
                for mac in session?.macsToStop ?? [] { queueStop(of: mac.id, conversation: recording.id) }
            } catch PhoneRecorderError.nothingRecorded {
                // No audio at all. Keep the folder only if it holds notes worth saving.
                let journal = try? PhoneCaptureJournal.load(from: folder)
                if journal?.notes.isEmpty != false, journal?.highlights.isEmpty != false, journal?.photos?.isEmpty != false {
                    try? FileManager.default.removeItem(at: folder)
                }
            } catch {
                say("Couldn’t recover a recording. Daybook tries again the next time it opens.", details: error.localizedDescription)
            }
        }
    }

    // MARK: Live Activity, widgets, and the link's recording state

    private func recorderChanged() {
        if !recorder.isCapturing { levels.reset() }
        // Processing never runs beside a recording.
        processor.conditions.isRecording = recorder.isActive
        updateActivity()
        sendRecordingState(force: true)
        publish()
    }

    private func levelChanged(_ level: AudioLevel) {
        levels.append(recorder.state == .recording ? level.meterValue : 0)
        updateActivity()
        sendRecordingState(force: false)
        // The widgets' confirmation that it's still recording, once a minute.
        if sharedState.isDue() { publish() }

        checkLead()
    }

    /// The recorder's state to connected Macs: on every change, and every 15 s while recording.
    func sendRecordingState(force: Bool) {
        guard !link.connectedMacs.isEmpty, force || Date().timeIntervalSince(lastStateSent) >= 15 else { return }
        lastStateSent = Date()
        let phase: LinkRecordingState.Phase
        switch recorder.state {
        case .idle: phase = .idle
        case .starting: phase = .starting
        case .recording: phase = .recording
        case .paused: phase = .paused
        case .stopping: phase = .stopping
        }
        let cascade = devices.cascade
        let recorders = devices.hub.recorderStates(conversation: { cascade.sharedConversation(of: $0) })
        lastRecorders = recorders
        link.sendRecordingState(LinkRecordingState(phase: phase, conversationID: recorder.captureID, startedAt: recorder.startedAt,
                                                   elapsed: recorder.isActive ? recorder.elapsedTime : 0, recorders: recorders,
                                                   sharedConversationID: recorder.isActive ? nil : recorderOnly?.conversationID))
    }

    private func activityState() -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            phase: recorder.isPaused ? .paused : .recording,
            timerStart: recorder.startedAt ?? Date(),
            frozenElapsed: recorder.isPaused ? recorder.pausedAt : nil,
            level: recorder.isPaused ? 0 : RecordingActivityAttributes.ContentState.levelBucket(recorder.level.meterValue),
            bookmarkCount: recorder.bookmarkCount,
            multipoint: multipoint?.shortLine,
            caption: Self.activityCaption(captionsOn: settings.liveCaptions, showing: captions.isShowing,
                                          forThisRecording: recorder.captureID != nil && captions.activeMeetingID == recorder.captureID,
                                          paused: recorder.isPaused, newest: captions.segments.last?.text))
    }

    /// The newest live caption for the Live Activity: only while captions are on and showing for this
    /// recording, and it isn't paused.
    static func activityCaption(captionsOn: Bool, showing: Bool, forThisRecording: Bool, paused: Bool, newest: String?) -> String? {
        guard captionsOn, showing, forThisRecording, !paused else { return nil }
        return RecordingActivityAttributes.ContentState.captionLine(newest)
    }

    func updateActivity() {
        guard recorder.state == .recording || recorder.isPaused else { return }
        activities.update(activityState())
    }

    /// Writes what the widgets and the control show, and asks them to refresh when it changed.
    func publish() {
        var state = SharedRecordingState()
        state.phase = recorder.isPaused ? .paused : (recorder.isActive && recorder.state != .stopping ? .recording : .idle)
        if state.phase != .idle {
            // Nil for the instant before the first sample; the recorder reports again when it's known.
            state.startedAt = recorder.startedAt
            state.title = recorder.title
            state.bookmarkCount = recorder.bookmarkCount
            state.multipoint = multipoint?.shortLine
            state.pausedElapsed = recorder.isPaused ? recorder.pausedAt : nil
        }
        if let latest = library.conversations.first {
            state.lastRecordingTitle = latest.title
            state.lastRecordingDate = latest.date
            state.lastRecordingDuration = latest.tracks.compactMap(\.duration).max()
        }
        sharedState.writes = !options.isRunningTests
        sharedState.publish(state)
    }

    // MARK: Debug scripts

    /// `--demo-notes`, `--simulate-interruption`, and `--stop-after`: a scripted recording for
    /// screenshots, with synthetic audio.
    private func runDemoScript() {
        let notes = options.demoNotes
        let stopAfter = options.stopAfter
        let interruptAfter = options.interruptAfter
        if let mac = options.demoMultipointMac, let id = recorder.captureID {
            multipoint = MultipointSession(conversationID: id, role: .phoneLed,
                                           macs: [MultipointSession.Mac(id: UUID(), name: mac, state: .recording, startedAt: Date(), startedByPhone: true)])
            updateActivity()
        }
        demo = Task { [weak self] in
            if notes {
                let script: [(TimeInterval, String?)] = [
                    (2, "Agenda: what the phone app records, and what waits for the Mac."),
                    (2.5, nil),
                    (3, "Recording keeps going with the screen locked; calls pause it."),
                    (2.5, "Next: measure both iPhone Duo displays before fixing layout constants."),
                    (1.5, nil),
                ]
                var text = ""
                for (delay, line) in script {
                    try? await Task.sleep(for: .seconds(delay))
                    guard let self, !Task.isCancelled, self.recorder.isActive else { return }
                    if let line {
                        text += (text.isEmpty ? "" : "\n") + line
                        self.editNotes(text)
                    } else {
                        _ = try? await self.addBookmark()
                    }
                }
            }
            if let interruptAfter {
                try? await Task.sleep(for: .seconds(max(0, interruptAfter - (notes ? 11.5 : 0))))
                guard let self, !Task.isCancelled, self.recorder.isActive else { return }
                self.demoAudioSession?.send(.interruptionBegan(reason: nil))
                // The call ends four seconds later; iOS doesn't ask to resume, so Resume is offered.
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self.demoAudioSession?.send(.interruptionEnded(shouldResume: false))
            }
            if let stopAfter {
                try? await Task.sleep(for: .seconds(max(0, stopAfter - (notes ? 11.5 : 0))))
                guard let self, !Task.isCancelled, self.recorder.isActive else { return }
                try? await self.stopRecording()
            }
        }
    }

    /// `--demo-link`: paired Macs and a Mac to pair with, with nothing on the network.
    private func applyLinkDemo() {
        #if DEBUG
        var studio = PhoneLink.Mac(id: UUID(), name: options.demoMultipointMac ?? "Studio Mac", pairedAt: Date().addingTimeInterval(-86_400 * 12),
                                   state: .connected, canProcess: true, appVersion: "1.0",
                                   clock: LinkClockEstimate(offset: 0.012, roundTrip: 0.008, sampleCount: 6, measuredAt: Date()),
                                   lastConnectedAt: Date())
        studio.handsOffRecorders = true
        let laptop = PhoneLink.Mac(id: UUID(), name: "MacBook Air", pairedAt: Date().addingTimeInterval(-86_400 * 40),
                                   state: .idle, canProcess: false, lastConnectedAt: Date().addingTimeInterval(-3 * 86_400))
        let progress = library.conversations.first.map {
            LiveProgress(LinkProcessingProgress(meetingID: $0.id, phase: .transcribing, fraction: 0.4, macName: studio.name))
        }
        let office = PhoneLink.PairingCandidate(id: "Office iMac", name: "Office iMac", endpoint: LinkEndpoint(host: "192.0.2.10", port: 7000),
                                                isPairing: true, isPaired: false, sharesLibrary: true)
        link.applyDemo(macs: options.demoMultipointMac != nil ? [studio] : [studio, laptop],
                       candidates: [office], progress: progress.map { [$0] } ?? [])
        #endif
    }

    /// `--device-autopilot`: Add Device › Soundcore Work against the simulated recorder, connect,
    /// and import what it holds, as a person would.
    private func runDeviceAutopilot() {
        Task { [weak self] in
            guard let self, let kind = DeviceCatalog.kind(SoundcoreWorkIntegration.id) else { return }
            guard self.devices.sessions.isEmpty, let session = self.devices.beginSetup(kind),
                  let soundcore = session.direct as? SoundcoreConnection else { return }
            soundcore.search()
            for _ in 0..<100 where soundcore.discovered.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            guard let recorder = soundcore.discovered.first else { return }
            soundcore.connect(to: recorder)
            for _ in 0..<100 where !soundcore.state.isConnected { try? await Task.sleep(for: .milliseconds(100)) }
            guard soundcore.state.isConnected else { return }
            self.devices.commitSetup()
            for _ in 0..<50 where session.newRecordings.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            session.importRecordings(Array(session.newRecordings.prefix(1)), automatic: true)
        }
    }

    /// `--handoff-demo <state>` and `--demo-live-captions` (debug), after the device autopilot has set up
    /// the simulated recorder: a recorder handoff state, or the recorder recording and streaming
    /// scripted captions, for screenshots. Nothing reaches the network.
    private func runStatusDemo() {
        #if DEBUG
        Task { [weak self] in
            guard let self else { return }
            for _ in 0..<300 {
                if let session = self.devices.sessions.first, session.isLinked, session.recorderSerial != nil, !session.links.recent.isEmpty { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let session = self.devices.sessions.first, let serial = session.recorderSerial else { return }
            if self.options.demoLiveCaptions, let soundcore = session.direct as? SoundcoreConnection {
                soundcore.startRecording()
                for _ in 0..<50 where session.status?.isRecording != true { try? await Task.sleep(for: .milliseconds(100)) }
                let lines = ["So the launch moves to the 14th, and Priya owns the checklist.",
                             "We still need legal to sign off on the pricing page before Friday.",
                             "Can someone check the date with the venue"]
                soundcore.live.isListening = true
                soundcore.live.receivedSeconds = 236
                for index in lines.indices {
                    // Demo captions: the earlier lines final, the newest still tentative.
                    soundcore.live.captions = lines.prefix(index + 1).enumerated().map { offset, line in
                        LiveCaptionSegment(start: Double(offset) * 4, end: Double(offset) * 4 + 3.5, text: line,
                                           isTentative: offset == index)
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                }
            }
            if let demo = self.options.demoTransfer, let recorder = self.devices.simulatedRecorder,
               let next = session.newRecordings.first, let id = UInt32(next.id) {
                // Slow enough to see: the import over Wi‑Fi, or another app's long transfer it waits for.
                recorder.pace = .milliseconds(400)
                if demo == "other-app" {
                    recorder.beginAnotherAppsTransfer(recordingID: id &+ 1, slices: 30_000, pace: .milliseconds(60))
                    try? await Task.sleep(for: .milliseconds(300))
                }
                session.importRecordings([next], automatic: true, overWiFi: demo == "wifi")
            }
            guard let state = self.options.handoffDemo else { return }
            let mac = ProcessingRequest.Device(id: "demo-studio-mac", name: "Studio Mac")
            if ["managed", "asking", "finishing", "waiting", "overdue", "refused"].contains(state) {
                self.library.controller.claimRecorder(kind: session.kind.id, serial: serial, deviceClass: .mac, by: mac)
                self.devices.applyOwnership()
                // This iPhone lets go first (it was taken over); the demo state goes on top of that.
                for _ in 0..<60 where session.isLinked || session.isHandingOff { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(600))
            }
            let now = Date()
            let demo: RecorderHandoff.State
            switch state {
            case "asking": demo = .asking(owner: mac.name)
            case "finishing": demo = .ownerFinishing(owner: mac.name, finishing: .importing(title: "Today, 10:02 AM", secondsLeft: 140))
            case "waiting": demo = .waitingForSync(owner: mac.name, since: now.addingTimeInterval(-20))
            case "overdue": demo = .waitingForSync(owner: mac.name, since: now.addingTimeInterval(-14 * 60))
            case "refused": demo = .refused(by: mac.name, message: "Studio Mac is already handing Soundcore Work to another device.")
            case "connecting": demo = .connecting(from: mac.name)
            case "done": demo = .done(at: now)
            case "handing": demo = .handingOver(to: mac.name, finishing: .importing(title: "Today, 10:02 AM", secondsLeft: 140))
            default: demo = .idle
            }
            try? await Task.sleep(for: .milliseconds(400))
            self.devices.handoff.applyDemo(demo, for: session)
        }
        #endif
    }

    /// `--demo-mac`: a Mac's presence record in the sync folder, in the documented format
    /// (docs/icloud-sync.md, "Devices and presence"), as if it last synced `hoursAgo` hours ago.
    static func writeDemoPresence(name: String, hoursAgo: Double, in folder: URL) {
        let deviceID = "demo-mac-" + name.lowercased().filter { $0.isLetter || $0.isNumber }
        let digest = SHA256.hash(data: Data(deviceID.utf8)).map { String(format: "%02x", $0) }.joined()
        let record: [String: Any] = [
            "format": "DaybookDevice", "schemaVersion": 1, "deviceID": deviceID, "deviceClass": "mac", "displayName": name,
            "canProcess": true, "audioPolicy": "eager",
            "lastSeen": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-hoursAgo * 3_600)),
        ]
        let directory = folder.appendingPathComponent("Devices", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent(digest + ".json"), options: .atomic)
        }
    }
}

/// A stop this iPhone owes a Mac it started (`PhoneAppModel.pendingStops`), as kept across relaunches.
struct OwedMacStop: OwedStop {
    var macID: UUID
    /// The conversation the Mac is to stop recording.
    var conversationID: UUID
    var owedAt: Date
}
