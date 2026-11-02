import DaybookCaptions
import ActivityKit
import DaybookDevices
import DaybookKit
import DaybookLink
import DaybookModelStore
import Foundation
import Observation
import SwiftUI
import UIKit
import WidgetKit

/// The phone app's coordinator: the recorder, the library and its sync, recorders, the Live Activity,
/// and the state the widgets read. Intents, the Live Activity's buttons, a Mac's record requests, and the
/// interface all go through it. Two parts have types of their own: recording with Macs and recorders
/// (`MultipointCoordinator`: record requests, owed stops, the cascade) and what goes to the Macs over the
/// local link while recording (`LinkSharing`: captions, levels, notes, the recording state). Filing and
/// recovery are in `PhoneAppModel+Filing.swift`, the debug launch scripts in `PhoneAppModel+Demos.swift`.
/// What it reaches in the system comes from its `PhoneAppEnvironment`.
///
/// For the reading UI (docs in Apps/iOS/README.md, "Services for the interface"):
/// - `macPresence`: whether a Mac that transcribes is around ("Waiting for your Mac · last seen 2 h ago").
/// - `liveProgress[meetingID]`: a Mac's live progress over the link ("Transcribing on Studio Mac · 40%").
/// - `audio`: the sync-backed `AudioProviding`, also injected as `\.audioProvider`.
/// - `destination`: where Daybook was asked to open (a notification, Open Conversation, New Note).
@MainActor
@Observable
final class PhoneAppModel: RecordingCommandHandling {
    let recorder: PhoneRecorder
    let library: PhoneLibrary
    let posture: DevicePosture
    let options: DebugLaunch
    /// What the model reaches in the system (`.live` in the app, inert in tests).
    @ObservationIgnored let environment: PhoneAppEnvironment
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
    /// summary placement reads them (`placement.cloud`, set at launch).
    @ObservationIgnored lazy var cloudSummaries: CloudSetup = {
        #if DEBUG
        if let demo = PhoneCloudDemo.setup(defaults: .standard) { return demo }
        #endif
        return CloudSetup(keys: environment.cloudKeys(), defaults: environment.defaults)
    }()
    /// Processing this iPhone's own recordings with those models (docs/iphone.md, "Processing on this iPhone").
    let processor: PhoneProcessor
    /// Where this iPhone's summaries run, with the countdown before them (docs/multipoint.md, "Where summaries run").
    let placement: PhoneSummaryPlacement
    /// "Upgrade" offers on the conversation page (docs/multipoint.md, "Upgrade").
    let upgrades: PhoneUpgrades
    /// Recording with Macs and the recorders this iPhone manages.
    @ObservationIgnored private(set) lazy var multipoints = MultipointCoordinator(app: self, sharing: sharing)
    /// What goes to the Macs over the local link while recording.
    @ObservationIgnored private(set) lazy var sharing = LinkSharing(recorder: recorder, link: link, devices: devices, captions: captions)
    /// One line for the person, when something needs saying: what happened, in plain words.
    private(set) var notice: String? {
        didSet { noticeDetails = nil; noticeFix = nil }
    }
    /// The system's own words behind the notice, shown only behind Details.
    private(set) var noticeDetails: String?
    /// What the notice's button does, when there's a fix.
    private(set) var noticeFix: NoticeFix?
    /// The library couldn't be opened at launch: the notice says so, and Welcome stops waiting for it.
    private(set) var libraryFailedToOpen = false
    /// The recording is being saved to the library.
    private(set) var isFiling = false
    /// The conversation filed last, for the interface to point at.
    private(set) var lastFiledID: UUID?
    /// How the recording this iPhone stopped last was filed, set as Stop (or a recording that stopped on its own)
    /// finishes: saved into a conversation, or why it couldn't be.
    private(set) var lastFiling: Filing?
    /// What the last Stop came to, for what Siri and Shortcuts say.
    private(set) var lastStopResult: RecordingStopResult = .saved
    /// Where Daybook was asked to open, until the interface has gone there (`reached`).
    private(set) var destination: DestinationRequest?

    /// Where a stopped recording went (`lastFiling`).
    enum Filing: Equatable {
        /// Saved into this conversation, then.
        case saved(UUID, Date)
        /// Not added to the library; the sentence says why and what happens to it.
        case failed(String)
    }
    /// Files being imported from Files or the share sheet.
    private(set) var importing = 0
    /// The conversation imported last.
    private(set) var lastImportedID: UUID?
    private(set) var isForeground = true
    /// The notifications Daybook posts (none in tests).
    @ObservationIgnored var notices: PhoneNotices

    @ObservationIgnored let activities = RecordingActivityController()
    @ObservationIgnored private var launched = false
    @ObservationIgnored private let sharedState = SharedStatePublisher()
    /// The audio session synthetic demos use, so a script can interrupt the recording.
    @ObservationIgnored var demoAudioSession: ScriptedAudioSession?
    #if DEBUG
    /// The scripted recording `--demo-notes` and `--stop-after` run.
    @ObservationIgnored var demo: Task<Void, Never>?
    #endif
    /// What the model follows in the library, the recorders, and sync (`ObservationWatch`).
    @ObservationIgnored private var watches: [ObservationWatch] = []
    /// Labelling saved captions' speakers from their recordings (`labelCaptionSpeakers`).
    @ObservationIgnored private var speakerPass: (id: UUID, task: Task<Void, Never>)?
    /// Recorders recording along: their live audio's captions join this iPhone's.
    @ObservationIgnored let recorderCaptions = LiveCaptureCaptions()
    /// Heat, power, and battery changes the processor backs off for.
    @ObservationIgnored private var processingObservers: [NSObjectProtocol] = []
    /// Each recording being filed, by conversation: a photo taken as it ended waits for it (`whileFiling`).
    @ObservationIgnored var filings: [UUID: Task<Void, Never>] = [:]
    /// The stop under way (Stop, a Mac's, or the recording stopping by itself) until it has ended the Live Activity,
    /// filed the recording, and said what it came to: a Stop meanwhile waits for it (`stopRecording`).
    @ObservationIgnored var stopUnderway: StopUnderway?
    /// Stops asked for while the recording stops by itself, until that stop is under way (`stoppedByItself`).
    @ObservationIgnored private var waitingForStopByItself: [CheckedContinuation<Void, Never>] = []
    /// What Spotlight lists of the library.
    @ObservationIgnored private(set) var conversationIndex: ConversationIndex?

    init(recorder: PhoneRecorder, library: PhoneLibrary, posture: DevicePosture, options: DebugLaunch,
         environment: PhoneAppEnvironment? = nil, settings: PhoneSettings? = nil, link: PhoneLink? = nil, devices: PhoneDevices? = nil) {
        // Built without one (tests that don't say), nothing real.
        let environment = environment ?? .inert
        let settings = settings ?? PhoneSettings(defaults: environment.defaults)
        self.recorder = recorder
        self.library = library
        self.posture = posture
        self.options = options
        self.environment = environment
        self.settings = settings
        notices = environment.notices
        sync = PhoneSync(library: library.controller)
        self.link = link ?? PhoneLink(identity: PhoneLink.identity(installation: library.installationID, name: ProcessingRequest.Device.currentName,
                                                                   libraryID: nil, syncDeviceID: library.controller.thisDevice.id),
                                      keyStore: environment.linkKeys())
        self.devices = devices ?? PhoneDevices(library: library, settings: settings, mode: environment.deviceMode, defaults: environment.defaults)
        audio = SyncAudioProvider(library: library, sync: sync, budget: settings.audioCacheBudget)
        let models = PhoneModels(root: environment.modelRoot(), defaults: environment.defaults,
                                 fetcher: environment.modelFetcher(), network: environment.network)
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
            continued: ContinuedProcessing(scheduler: environment.continuedProcessing()))
        let sync = self.sync, link = self.link
        placement = PhoneSummaryPlacement(library: library.controller, link: link, presence: { sync.devices })
        upgrades = PhoneUpgrades(library: library.controller, placement: placement, link: link, presence: { sync.devices })
        captions = LiveCaptionsController(store: LiveCaptionStore(libraryRoot: library.rootURL),
                                          makeCaptioner: Self.captioner(settings: settings, options: options, models: models,
                                                                        makesCaptioners: environment.makesCaptioners))
        models.voices.metadata = { [weak library] in library?.controller.metadata ?? LibraryMetadata() }
        // Live recognizers are biased toward the library's approved vocabulary, as it changes.
        let controller = library.controller
        watches.append(ObservationWatch.distinctValues(of: { controller.glossary.filter(\.approved).map(\.term) }) { [weak models] terms in
            models?.vocabulary.update(terms)
        })
        // A recorder's Listen Live is captioned like recordings: the live models when downloaded.
        self.devices.hub.environment.liveCaptions.makeCaptioner = Self.listenLiveCaptioner(settings: settings, options: options, models: models,
                                                                                         makesCaptioners: environment.makesCaptioners)
        self.devices.hub.environment.liveCaptions.locale = { [weak settings] in settings?.captionLocale ?? .current }
        wireRecorder()
        wireSync()
        multipoints.wire()
        sharing.multipoints = multipoints
        // A Mac's note or bookmark changes what the Live Activity shows.
        sharing.changed = { [weak self] in self?.updateActivity() }
        wireRecorderHandoff()
        self.link.onLibraryKeyMessage = { [weak self] message, mac in self?.libraryKeyMessage(message, from: mac) }
        self.link.onProcessingFinished = { [weak self] _ in
            Task { await self?.sync.synchronize(.linkFinished) }
        }
        self.devices.onImported = { [weak self] filed in self?.filedElsewhere(filed) }
        // Macs hear what the recorders this iPhone manages are doing, when that changes.
        watches.append(self.devices.hub.watchRecorders { [weak self] in
            guard let self else { return }
            let cascade = self.devices.cascade
            guard self.devices.hub.recorderStates(conversation: { cascade.sharedConversation(of: $0) }) != self.sharing.lastRecorders else { return }
            self.sharing.sendRecordingState(force: true)
        })
        // An encrypted library keeps its conversations out of backups (`BackupExclusion`).
        watches.append(ObservationWatch.distinctValues(of: { controller.sync?.encryption }, initial: false) { [weak self] _ in
            self?.applyBackupExclusion()
        })
        // A recorder recording along is captioned from its live audio, beside this iPhone's captions.
        recorderCaptions.follow(self.devices.hub, conversation: { [weak self] in self?.captions.activeMeetingID }) { [weak self] update in
            self?.recorderCaptioned(update)
        }
        // A conversation moved to the Trash takes its live captions with it, and a transcript replaces them.
        watches.append(ObservationWatch.distinctValues(of: { LiveCaptionStore.transcriptDates(controller.meetings) }, initial: false) { [weak self] _ in
            self?.pruneCaptions()
        })
        // Spotlight lists the library's conversations, Personal ones never.
        if environment.spotlight.isActive {
            let index = ConversationIndex(indexer: environment.spotlight)
            conversationIndex = index
            watches.append(ObservationWatch.distinctValues(of: { ConversationIndex.entries(controller.meetings) }) { entries in
                index.update(entries)
            })
        }
        wireProcessing()
    }

    /// The recorder's news reaches the Live Activity, the widgets, the Macs, and the person.
    private func wireRecorder() {
        recorder.onChange = { [weak self] in self?.recorderChanged() }
        recorder.onLevel = { [weak self] level in self?.levelChanged(level) }
        recorder.onUnexpectedStop = { [weak self] recording in self?.stoppedByItself(recording) }
        // The interruption ended and iOS asked to continue, but recording couldn't: the person hears why.
        recorder.onResumeFailed = { [weak self] error in self?.sayResumeFailed(error) }
    }

    private func wireSync() {
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
    }

    /// Which captioner a recording gets: the live models when they're downloaded (`PhoneModels`:
    /// local transcription, speakers, and names), else the Speech framework (downloading its
    /// language only for a real recording, never in simulator demos); a script for
    /// `--demo-captions`; none in tests (they inject one) or when the setting is off.
    static func captioner(settings: PhoneSettings, options: DebugLaunch, models: PhoneModels? = nil,
                          makesCaptioners: Bool = false) -> () -> (any LiveCaptioning)? {
        { [weak settings, weak models] in
            guard let settings, settings.liveCaptions else { return nil }
            if options.demoCaptions { return ScriptedCaptioner.demo() }
            guard makesCaptioners else { return nil }
            // A real recording may download the language and, if the analyzer needs it, ask once for
            // speech-recognition permission; simulator demos with synthetic audio never do either.
            let speech = { SpeechCaptioner(allowsDownload: !options.syntheticAudio, asksForAuthorization: !options.syntheticAudio) as any LiveCaptioning }
            guard let models, !options.syntheticAudio else { return speech() }
            return models.captioner(locale: settings.captionLocale, fallback: speech)
        }
    }

    /// Listen Live's captioner: the same choice as recordings, with the recorder's longer backlog.
    static func listenLiveCaptioner(settings: PhoneSettings, options: DebugLaunch, models: PhoneModels,
                                    makesCaptioners: Bool = false) -> () -> (any LiveCaptioning)? {
        { [weak settings, weak models] in
            // Tests inject their own; the device simulator's demos never load models or download a language.
            guard makesCaptioners, let settings, settings.liveCaptions else { return nil }
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
            Task { @MainActor in
                handoff.peersChanged()
                // A Mac that comes or goes changes where a summary can go.
                self?.placement.refresh()
            }
        }
    }

    private func pruneCaptions() {
        guard library.controller.isLoaded else { return }
        captions.prune(meetings: library.controller.meetings, trashed: library.controller.trashedMeetingIDs())
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
            // Kept only when it answers a request this iPhone sent that Mac (`requestLibraryKey(from:)`).
            Task { await controller.accept(grant, from: macID) }
        default:
            break
        }
    }

    /// Asks a connected Mac for the encrypted library's key this iPhone is waiting for. Only that Mac's answer is
    /// kept. Throws when the Mac can't be reached, so Settings can say so.
    func requestLibraryKey(from macID: UUID) async throws {
        guard link.macs.first(where: { $0.id == macID })?.isConnected == true else { throw LinkError.notConnected }
        guard let controller = sync.controller, let request = await controller.libraryKeyRequest() else { return }
        // Noted before sending, so an answer that comes back at once already finds it.
        controller.noteKeyRequested(from: macID)
        try await link.send(.libraryKeyRequest(request), to: macID)
    }

    var isRecordingActive: Bool { recorder.isActive }

    /// Never asked about the microphone: a start from the background continues in front first.
    var microphoneNeedsAsking: Bool { recorder.microphonePermission == .notAsked }

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

    /// First appearance: load the library, file anything a previous run left behind, connect sync
    /// and the link, and run any debug launch script.
    func launch() async {
        guard !launched else { return }
        launched = true
        do { try await library.reload() }
        catch {
            launched = false
            libraryFailedToOpen = true
            say(Self.libraryUnavailable, details: error.localizedDescription)
            return
        }
        if libraryFailedToOpen { libraryFailedToOpen = false }
        if let folder = options.syncFolder {
            try? sync.connect(toFolder: URL(fileURLWithPath: folder, isDirectory: true), monitor: true)
            #if DEBUG
            if let mac = options.demoMac { Self.writeDemoPresence(name: mac.name, hoursAgo: mac.hoursAgo, in: URL(fileURLWithPath: folder)) }
            #endif
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
        if environment.startsLink {
            #if DEBUG
            if options.demoLink || options.demoMultipointMac != nil { applyLinkDemo() } else { await link.start() }
            #else
            await link.start()
            #endif
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
        #if DEBUG
        runLaunchDemos()
        #endif
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
            if multipoints.recorderOnly != nil, !recorder.isActive { Task { await multipoints.recordAlongWithRecorder() } }
            labelCaptionSpeakers()
            // A courier that's off only because the account couldn't be checked (woken in the background soon after the
            // iPhone started) tries again now.
            sync.controller?.resumeCourier()
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
            sync.finishOnLeavingForeground()
            Task { await link.setActivity(recorder.isActive || multipoints.recorderOnly != nil ? .backgroundRecording : .background) }
        default:
            break
        }
    }

    /// Daybook is in front: its scene is active, and iOS says so (a background relaunch for the recorder
    /// has no scene to say otherwise).
    var isInFront: Bool { isForeground && UIApplication.shared.applicationState == .active }

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
                guard let meeting = self.library.controller.meeting(saved.meetingID), SavedCaptions.shown(saved, for: meeting) != nil,
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

    // MARK: Opening somewhere

    /// Opens Daybook at `destination` (a notification, Open Conversation, New Note): the interface goes
    /// there (`OpensDestinations`) and says it has (`reached`).
    func open(_ destination: AppDestination) {
        self.destination = DestinationRequest(destination: destination)
    }

    /// The interface went where `request` asked.
    func reached(_ request: DestinationRequest) {
        if destination == request { destination = nil }
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
        let title = requestedTitle ?? Meeting.defaultTitle()
        // Staged by the recording's own ID: the conversation may hold an earlier one still being filed.
        let directory = library.stagingURL.appendingPathComponent(recordingID.uuidString, isDirectory: true)
        notice = nil
        levels.reset()
        multipoints.session = session
        recorder.audioTap = captions.prepare(meetingID: id)
        do {
            try await recorder.start(in: directory, id: id, recordingID: recordingID, title: title)
            recorder.setMultipoint(multipoints.session?.journaled)
        } catch {
            multipoints.session = nil
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
        sharing.startSharingCaptions()
        link.sampleClocks()
        // The system requires a Live Activity for a recording started in the background (an intent,
        // a Mac's request); otherwise the setting decides.
        let background = UIApplication.shared.applicationState != .active
        if !options.isRunningTests, settings.showsLiveActivity || background {
            activities.start(conversationID: id, title: title, state: activityState())
        }
        // A recording that stops by itself in a pocket says so with a notification: asked about now,
        // with Daybook in front and recording. Not in simulator demos, whose prompt would cover their screenshots.
        if !background, !options.syntheticAudio { notices.askPermission() }
        if !isForeground { Task { await link.setActivity(.backgroundRecording) } }
        sharing.sendRecordingState(force: true)
        publish()
        multipoints.beginCascade(id, title: session?.title ?? title, date: session?.date ?? Date(), session: session, trigger: trigger,
                                 leadRecorder: leadRecorder, asksMacs: asksMacs)
    }

    func stopRecording() async throws {
        // Stop again while a stop finishes (tapped twice as it saves, a Mac's stop with the person's): it waits for that
        // one and comes to what it came to. It never ends the Live Activity, files, or says anything itself.
        if let underway = stopUnderway, !recorder.isActive || recorder.recordingID == underway.recordingID {
            multipoints.stopIsFromMac = false
            return await underway.task.value
        }
        // The recording is stopping by itself (storage, the encoder): that stop is this one.
        if recorder.state == .stopping {
            multipoints.stopIsFromMac = false
            await withCheckedContinuation { waitingForStopByItself.append($0) }
            await stopUnderway?.task.value
            return
        }
        guard recorder.isActive else { throw RecordingCommandError.notRecording }
        // A stop from a Mac (it asked, or this iPhone follows it) doesn't go back to that Mac.
        let cascadesUp = !multipoints.stopIsFromMac
        multipoints.stopIsFromMac = false
        let stopping = recorder.captureID
        sharing.flushSharedNotes()
        sharing.stopSharingCaptions()
        // What the Live Activity shows from now on, its clock frozen where it stopped: read now, before the recorder resets.
        var final = activityState()
        final.frozenElapsed = recorder.pausedAt ?? recorder.elapsedTime
        isFiling = true
        defer { isFiling = false }
        let session = multipoints.session
        let clocks = link.peerClocks { mac in session?.macs.first(where: { $0.id == mac.id })?.startedAt ?? mac.recording?.startedAt }
        // Finishing and filing must complete even if the caller is cancelled (an intent that timed
        // out, a view that went away): an unstructured task doesn't inherit cancellation.
        let filing = Task { @MainActor [final] () -> StopOutcome in
            // Saving, with no buttons, as the recorder starts to finish (nothing updates the activity after this).
            self.activities.showSaving(Self.savingActivity(final))
            let stopped = await self.recorder.stop()
            // Saved only once there's a recording to save.
            self.activities.end(Self.endedActivity(final, recorded: stopped != nil, failure: self.recorder.lastFailure,
                                                   kept: self.recorder.unfinishedFolder != nil))
            guard var recording = stopped else {
                self.recorder.audioTap = nil
                await self.captions.finish()
                let outcome = await self.fileUnfinished(self.recorder.unfinishedFolder, failure: self.recorder.lastFailure,
                                                        reason: self.recorder.lastError)
                self.publish()
                return outcome
            }
            if !clocks.isEmpty { recording.capture.peerClocks = clocks }
            self.recorder.audioTap = nil
            await self.captions.finish()
            let filed = await self.file(recording, session: session)
            return StopOutcome(filing: filed)
        }
        await beginStop(of: recorder.recordingID) {
            self.noteStopped(await self.whileFiling(stopping, filing))
            self.multipoints.stopMacsStartedHere(session)
            self.multipoints.endCascade(stopping, session: session, cascadesUp: cascadesUp)
            self.multipoints.session = nil
            self.sync.controller?.publishActivity(recording: nil)
            self.multipoints.recordingEnded()
            self.sharing.sendRecordingState(force: true)
            if !self.isForeground { Task { await self.link.setActivity(.background) } }
        }.value
    }

    /// The recording stopped by itself: finishing it is the stop under way, and a Stop asked for as it stopped
    /// waits for it.
    private func stoppedByItself(_ recording: PhoneRecording?) {
        beginStop(of: recording?.recordingID) { await self.finishUnexpectedly(recording) }
        let waiting = waitingForStopByItself
        waitingForStopByItself = []
        for stop in waiting { stop.resume() }
    }

    /// Filing put a conversation in the library (`PhoneAppModel+Filing.swift`).
    func noteFiled(_ id: UUID) { lastFiledID = id }

    /// A stop (by the person, a Mac, or the recording itself) came to `outcome`: where it went, and what
    /// Siri says.
    func noteStopped(_ outcome: StopOutcome) {
        if let filing = outcome.filing { lastFiling = filing }
        lastStopResult = outcome.result
    }

    func resumeRecording() async throws {
        guard recorder.isPaused else { throw RecordingCommandError.notRecording }
        do { try await recorder.resume() } catch {
            sayResumeFailed(error)
            throw Self.commandFailure(error, starting: false)
        }
    }

    @discardableResult
    func addBookmark() async throws -> TimeInterval {
        guard let mark = recorder.addBookmark() else { throw RecordingCommandError.notRecording }
        sharing.bookmarkAdded(mark)
        return mark.time
    }

    func editNotes(_ text: String) {
        sharing.editNotes(text)
    }

    /// A photo from the camera opened during recording `id`. While that recording runs, the photo
    /// goes with it. If it ended while the camera was open (a Mac's Stop, a failure), the photo joins
    /// the conversation it's filed as, once filing (which holds the library's lock) is done.
    func addPhoto(_ photo: CameraPhoto, recording id: UUID?) async {
        do {
            if recorder.captureID == id, try await recorder.addPhoto(photo) != nil { return }
            guard let id else { return }
            // Still being filed: the photo waits for it.
            if let filing = filings[id] { await filing.value }
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
        case .microphoneDenied?: say(Self.allowMicrophone, fix: .openSettings)
        case let known?: say(known.localizedDescription, details: known.details)
        case nil: say("Couldn’t start recording. Try again.", details: error.localizedDescription)
        }
    }

    /// A paused recording that couldn't continue (Resume, or iOS asking to continue after a call): it stays
    /// paused with Resume, and the notice says so, with the system's words behind Details.
    func sayResumeFailed(_ error: Error) {
        switch error as? PhoneRecorderError {
        case .microphoneDenied?: say(Self.allowMicrophone, fix: .openSettings)
        case .notRecording?: break
        case let known?: say(known.localizedDescription, details: known.details)
        case nil: say(Self.couldNotResume, details: error.localizedDescription)
        }
        publish()
    }

    static let allowMicrophone = "Allow Daybook to use the microphone in Settings."
    static let couldNotResume = "Couldn’t resume recording. Try again."

    /// What a Shortcut, the control, or a Live Activity button says when recording couldn't start or resume: Daybook's
    /// own sentence, never the system's words (those are in the app's notice).
    static func commandFailure(_ error: Error, starting: Bool) -> RecordingCommandError {
        switch error as? PhoneRecorderError {
        case .microphoneDenied?: return .failed(allowMicrophone)
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

    // MARK: Multipoint, as the interface and tests ask it (`MultipointCoordinator`)

    /// Where the stops this iPhone owes Macs are kept, in the library's folder.
    static let owedStopsFile = MultipointCoordinator.owedStopsFile

    /// While a Mac records this conversation too, or asked this iPhone to. Kept in the recording's
    /// journal, so a recording recovered after Daybook was killed still joins and stops its Macs.
    var multipoint: MultipointSession? {
        get { multipoints.session }
        set { multipoints.session = newValue }
    }
    /// A shared recording this iPhone takes part in only through its recorder.
    var recorderOnly: RecorderOnlyRecording? {
        get { multipoints.recorderOnly }
        set { multipoints.recorderOnly = newValue }
    }
    /// Recording here asks the connected Macs on its own (a cascading start). Tests of the person's own
    /// "Record on Studio Mac too" turn it off.
    var cascadesToMacs: Bool {
        get { multipoints.cascadesToMacs }
        set { multipoints.cascadesToMacs = newValue }
    }
    /// Stops this iPhone owes Macs it started, by Mac: the conversation to stop.
    var pendingStops: [UUID: UUID] { multipoints.pendingStops }
    /// Macs connected now that could record this conversation too.
    var macsToRecordWith: [PhoneLink.Mac] { multipoints.macsToRecordWith }
    /// The multipoint line for the recording screen.
    var multipointLine: String? { multipoints.line }

    /// "Record on Studio Mac too".
    func recordOnMac(_ macID: UUID, cascade: LinkCascade? = nil) async {
        await multipoints.recordOnMac(macID, cascade: cascade)
    }

    /// While recording for a Mac, one unreachable for too long won't stop it, so this iPhone does.
    func checkLead(now: Date = Date()) { multipoints.checkLead(now: now) }

    /// Daybook came forward while only the recorder records: this iPhone records the same conversation now.
    func recordAlongWithRecorder() async { await multipoints.recordAlongWithRecorder() }

    /// The connected Macs recording this conversation too that show other devices' captions.
    func macsShowingCaptions(_ id: UUID) -> [UUID] { sharing.macsShowingCaptions(id) }

    /// The connected Macs recording this conversation too that draw this iPhone's level.
    func macsShowingLevels(_ id: UUID) -> [UUID] { sharing.macsShowingLevels(id) }

    /// This iPhone's level to the Macs recording along that draw it.
    func shareLevel(_ level: AudioLevel, at now: Date = Date()) { sharing.shareLevel(level, at: now) }

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
            say(failures.count == 1 ? "Couldn’t import “\(failures[0].name)”." : Self.importFailures(failures.count),
                details: failures.map { "\($0.name): \($0.reason)" }.joined(separator: "\n"))
        }
        sync.synchronizeFinishing(.filed)
        processor.pickUp()
        publish()
    }

    /// "Couldn’t import 3 files.", in the language's own plural.
    static func importFailures(_ count: Int) -> String {
        String(AttributedString(localized: "Couldn’t import ^[\(count) file](inflect: true).").characters)
    }

    /// A recorder's recording was filed: upload it now and tell a connected Mac.
    private func filedElsewhere(_ filed: PhoneLibrary.Filed) {
        if let request = filed.request { link.nudge(request) }
        sync.synchronizeFinishing(.filed)
        processor.pickUp()
        publish()
    }

    // MARK: Live Activity, widgets, and the link's recording state

    private func recorderChanged() {
        if !recorder.isCapturing { levels.reset() }
        // Processing never runs beside a recording.
        processor.conditions.isRecording = recorder.isActive
        updateActivity()
        sharing.sendRecordingState(force: true)
        publish()
    }

    private func levelChanged(_ level: AudioLevel) {
        levels.append(recorder.state == .recording ? level.meterValue : 0)
        sharing.shareLevel(level)
        updateActivity()
        sharing.sendRecordingState(force: false)
        // The widgets' confirmation that it's still recording, once a minute.
        if sharedState.isDue() { publish() }
        multipoints.checkLead()
    }

    /// What the Live Activity shows now.
    func activityState() -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            phase: recorder.isPaused ? .paused : .recording,
            timerStart: recorder.startedAt ?? Date(),
            frozenElapsed: recorder.isPaused ? recorder.pausedAt : nil,
            // Whether the microphone hears anything: it changes rarely, never with the voice.
            level: RecordingActivityAttributes.ContentState.level(hearing: !recorder.isPaused && !recorder.isMicrophoneSilent),
            bookmarkCount: recorder.bookmarkCount,
            multipoint: multipoints.session?.shortLine,
            caption: Self.activityCaption(captionsOn: settings.liveCaptions, showing: captions.isShowing,
                                          forThisRecording: recorder.captureID != nil && captions.activeMeetingID == recorder.captureID,
                                          paused: recorder.isPaused, newest: captions.segments.last?.text),
            canResume: recorder.isPaused ? recorder.canResume : nil)
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
            state.multipoint = multipoints.session?.shortLine
            state.pausedElapsed = recorder.isPaused ? recorder.pausedAt : nil
            state.canResume = recorder.isPaused ? recorder.canResume : nil
        }
        if let latest = library.conversations.first {
            state.lastRecordingTitle = latest.title
            state.lastRecordingDate = latest.date
            state.lastRecordingDuration = latest.tracks.compactMap(\.duration).max()
        }
        sharedState.writes = !options.isRunningTests
        sharedState.publish(state)
    }
}

/// A stop this iPhone owes a Mac it started (`MultipointCoordinator.pendingStops`), as kept across relaunches.
struct OwedMacStop: OwedStop {
    var macID: UUID
    /// The conversation the Mac is to stop recording.
    var conversationID: UUID
    var owedAt: Date
}
