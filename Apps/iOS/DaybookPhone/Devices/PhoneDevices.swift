import Combine
import DaybookKit
import Foundation
import Observation

/// Recorders on iPhone (DaybookDevices): Soundcore Work over Bluetooth, usually the device in your
/// pocket, and other recorders through Files. Its recordings import into the library as recorder
/// tracks, with a Transcribe request, and sync to a Mac for processing.
///
/// - **Background Bluetooth**: the `bluetooth-central` background mode with state restoration. The
///   transport is made with `restoreIdentifier`, so iOS can relaunch Daybook in the background when
///   the recorder comes into range and hand back its pending connection (`willRestoreState` →
///   `onRestore`). The hub starts in `App.init`, before the first scene, as CoreBluetooth requires.
/// - **One owner per recorder**: a synced `RecorderOwnership` in the library's metadata. Setting up
///   a recorder here claims it; a recorder another device manages isn't connected here, and the
///   device page says "Managed by Studio Mac".
/// - **Handoff** (`handoff`, DaybookKit's `RecorderHandoff`): "Use on This iPhone" asks the Mac to
///   let go (over Wi‑Fi in seconds, else through iCloud), and "Use on Studio Mac" offers it back.
@MainActor
@Observable
final class PhoneDevices {
    enum Mode: Equatable {
        /// Real Bluetooth.
        case live
        /// `--device-simulator`: the real connection against DaybookDevices' simulated recorder.
        case simulator
        /// Tests: a transport that never touches Bluetooth.
        case inert
    }

    let hub: DeviceHub
    /// Moving a recorder between this iPhone and a Mac. The app model plugs in the link.
    let handoff: RecorderHandoff
    /// The recorders recording along with this iPhone's shared recording (docs/multipoint.md): started
    /// with it, their audio saved into it as they record, stopped with it.
    let cascade: RecorderCascade
    let mode: Mode
    /// Bumps when the hub or a session publishes, for Observation-based views.
    private(set) var revision = 0
    /// Recorders iOS handed back after relaunching Daybook in the background, and when.
    private(set) var restored: [UUID] = []
    private(set) var restoredAt: Date?
    /// The last conversation a recorder's recording went into.
    private(set) var lastImported: PhoneLibrary.Filed?

    /// A recording was filed (the app model syncs at once and nudges a connected Mac).
    @ObservationIgnored var onImported: ((PhoneLibrary.Filed) -> Void)?
    @ObservationIgnored private let library: PhoneLibrary
    @ObservationIgnored private let settings: PhoneSettings
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var sessionSubscriptions: [String: AnyCancellable] = [:]
    @ObservationIgnored private var started = false
    /// The recorder's Live Activity: Listen Live, or a recording this iPhone started on it. None in tests.
    @ObservationIgnored private var recorderActivity: RecorderActivityController?

    static let restoreIdentifier = "local.daybook.phone.soundcore"

    #if DEBUG
    /// `--device-simulator`'s recorder, for demos.
    @ObservationIgnored private(set) var simulatedRecorder: SimulatedSoundcore?
    #endif

    /// How long the Soundcore connection and the handoff wait for things. The app uses the
    /// production values; tests shorten them.
    struct Timing {
        var soundcore = SoundcoreTiming()
        var handoff = RecorderHandoff.Timing()
        var cascade = RecorderCascade.Timing()
    }

    /// `transport`, when given, replaces the mode's link to the recorder (tests: a simulated one).
    init(library: PhoneLibrary, settings: PhoneSettings, mode: Mode, defaults: UserDefaults = .standard,
         timing: Timing = Timing(), transport: (() -> any SoundcoreTransport)? = nil) {
        self.library = library
        self.settings = settings
        self.mode = mode
        let staging = library.importsURL.appendingPathComponent("Devices", isDirectory: true)
        try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var environment = DeviceEnvironment(defaults: defaults, stagingDirectory: staging, soundcoreTiming: timing.soundcore)
        weak var weakSelf: PhoneDevices?
        #if DEBUG
        var simulator: SimulatedSoundcore?
        #endif
        switch mode {
        case .live:
            environment.soundcoreTransport = {
                let transport = CoreBluetoothSoundcoreTransport(restoreIdentifier: Self.restoreIdentifier)
                transport.onRestore = { ids in weakSelf?.didRestore(ids) }
                return transport
            }
            // Wi‑Fi Fast Transfer joins the recorder's own network (docs/direct-soundcore.md).
            environment.soundcoreWiFi.hotspot = SystemSoundcoreHotspot()
        case .inert:
            environment.soundcoreTransport = { InertSoundcoreTransport() }
        case .simulator:
            #if DEBUG
            let recorder = SimulatedSoundcore.demo()
            DeviceHub.demo = DeviceHubDemo(transport: { SimulatedSoundcoreTransport(device: recorder) },
                                           simulatorSuite: "local.daybook.phone.device-simulator")
            // Fast Transfer against the simulated recorder's access point, on loopback.
            let wifi = environment.soundcoreWiFi
            wifi.hotspot = SimulatedSoundcoreHotspot(recorder: recorder)
            wifi.requiresWiFi = false
            wifi.keepAlivePort = { [weak recorder] _ in recorder?.accessPoint?.keepAlivePort ?? SoundcoreWiFi.keepAlivePort }
            simulator = recorder
            #endif
        }
        if let transport { environment.soundcoreTransport = transport }
        hub = DeviceHub(environment: environment)
        #if DEBUG
        simulatedRecorder = simulator
        #endif
        handoff = RecorderHandoff(library: library.controller, devices: hub, deviceClass: .phone, defaults: defaults, timing: timing.handoff)
        let hub = self.hub
        cascade = RecorderCascade(sessions: { hub.sessions })
        cascade.timing = timing.cascade
        weakSelf = self
        hub.importer = { [weak self] url, identity, attachTo, source in
            guard let self else { throw DaybookError.libraryUnavailable }
            // A recording a Mac asked the recorder to make (multipoint) joins that conversation, also
            // when the recorder moved to this iPhone before it finished.
            let linked = attachTo ?? self.library.controller.meetings.first { meeting in
                meeting.companions?.contains { $0.deviceKind == identity.kind && $0.recordingID == identity.recordingID } == true
            }?.id
            // A shared recording's conversation that isn't in this library yet (a Mac's, not synced here):
            // made as the device leading it has it, so the copies agree when they meet.
            if let linked, self.library.controller.meeting(linked) == nil, let pending = self.cascade.pendingConversation(linked) {
                try await self.library.reload()
                if self.library.controller.meeting(linked) == nil {
                    self.library.controller.add(Meeting(id: linked, title: pending.title ?? PhoneLibrary.deviceTitle(identity, fallback: url),
                                                        date: pending.date ?? PhoneLibrary.deviceStart(identity) ?? Date(),
                                                        status: pending.ledHere ? .imported : .draft))
                }
            }
            let filed = try await self.library.importDeviceRecording(url, identity: identity, attachTo: linked, source: source,
                                                                     requestTranscription: self.settings.requestsTranscription)
            self.lastImported = filed
            self.onImported?(filed)
            return filed.meeting.id
        }
        hub.objectWillChange.sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
        handoff.objectWillChange.sink { [weak self] _ in self?.changed() }.store(in: &subscriptions)
        if !LaunchOptions.isTestHost {
            let activity = RecorderActivityController { [weak self] in self?.hub.sessions ?? [] }
            recorderActivity = activity
            // Its Stop Listening runs in this process, launching the app in the background if needed.
            RecorderCommands.handler = activity
        }
    }

    /// Restores remembered recorders and, where allowed, reconnects. Call once, at launch.
    func start() {
        guard !started else { return }
        started = true
        let controller = library.controller
        hub.observeLibrary(controller.$meetings.combineLatest(controller.$isLoaded).eraseToAnyPublisher())
        controller.$metadata.sink { [weak self] _ in
            DispatchQueue.main.async { self?.applyOwnership() }
        }.store(in: &subscriptions)
        hub.start()
        followSessions()
        applyOwnership()
    }

    func shutDown() { hub.shutDown() }

    /// Wi‑Fi Fast Transfer runs only in the foreground: leaving it ends Fast Transfer, and the transfer
    /// carries on over Bluetooth.
    func foregroundChanged(_ isForeground: Bool) {
        hub.environment.soundcoreWiFi.isForeground = isForeground
    }

    /// Background app refresh: a recorder whose wait before the next automatic import ran out while
    /// the app was suspended reaches for the recorder now (`SoundcoreConnection.automaticDueAt`).
    func backgroundRefresh() {
        guard started else { return }
        hub.resumeAutomaticImportsIfDue()
    }

    var sessions: [DeviceSession] { _ = revision; return hub.sessions }

    // MARK: Ownership

    /// The library's ownership records changed, or a recorder's serial became known.
    func applyOwnership() {
        hub.recorderOwnersChanged(library.controller.recorderOwners, thisDevice: library.controller.thisDevice.id)
        holdRecorders()
        revision &+= 1
    }

    /// A recorder this iPhone manages that records along with it keeps its link while in range, so its
    /// button is heard, even with Daybook in the background (`SoundcoreConnection.staysConnected`).
    /// Never in tests' inert mode, which has no recorder to reach.
    func holdRecorders() {
        guard mode != .inert || holdsInTests else { return }
        for session in hub.sessions {
            guard let soundcore = session.direct as? SoundcoreConnection else { continue }
            let hold = session.managedElsewhere == nil && session.device.recordsAlongsideMac && session.device.isEnabled(.direct)
            if soundcore.staysConnected != hold { soundcore.staysConnected = hold }
        }
    }

    /// Tests with a simulated recorder hold it like the app does.
    @ObservationIgnored var holdsInTests = false

    /// Manage this recorder on this iPhone: other devices stop connecting to it (setting a recorder
    /// up here claims it outright; the device that had it lets go and hands over what was waiting).
    func claim(_ session: DeviceSession) {
        guard let serial = session.recorderSerial else { return }
        library.controller.claimRecorder(kind: session.kind.id, serial: serial, deviceClass: .phone)
        handoff.noteChosenHere(session)
        applyOwnership()
    }

    // MARK: Handoff

    /// "Use on This iPhone": asks the device that manages it to let go, then connects.
    func useHere(_ session: DeviceSession) { handoff.useHere(session) }
    /// After the person confirmed what it risks.
    func takeOverAnyway(_ session: DeviceSession) { handoff.takeOverAnyway(session) }
    /// "Use on Studio Mac": offers it to a Mac connected over Wi‑Fi.
    func give(_ session: DeviceSession, to mac: RecorderHandoff.Peer) { handoff.give(session, to: mac) }
    func handoffState(_ session: DeviceSession) -> RecorderHandoff.State { _ = revision; return handoff.state(of: session) }
    /// Macs on Wi‑Fi this iPhone could hand the recorder to.
    func handoffTargets(_ session: DeviceSession) -> [RecorderHandoff.Peer] { _ = revision; return handoff.peersToGive(session) }
    /// Stops waiting, or clears an answer that was shown.
    func endHandoff(_ session: DeviceSession) {
        if handoff.state(of: session).isPending { handoff.cancel(session) } else { handoff.dismiss(session) }
    }

    /// Removing a recorder here lets another device manage it again.
    func remove(_ session: DeviceSession) {
        if let serial = session.recorderSerial {
            library.controller.releaseRecorder(kind: session.kind.id, serial: serial, onlyIfOwnedBy: library.controller.thisDevice.id)
        }
        hub.remove(session.id)
        followSessions()
    }

    /// Who manages the recorder when it isn't this iPhone.
    func owner(of session: DeviceSession) -> RecorderOwnership? { session.managedElsewhere }

    // MARK: Setup

    /// Add Device: begins setting up a kind; its setup screen drives the session.
    func beginSetup(_ kind: DeviceKind) -> DeviceSession? {
        let session = hub.beginSetup(kind)
        revision &+= 1
        return session
    }

    /// The recorder connected (or a folder was chosen): it joins the device list, and this iPhone
    /// becomes its manager.
    func commitSetup() {
        guard let session = hub.pendingSetup else { return }
        // Its button can start a recording while Daybook is in the background, which a notification
        // tells the person about: asked now, while they're setting it up. Not for the simulated
        // recorder (a debug demo), whose prompt would cover its screenshots.
        if mode == .live, !LaunchOptions.isTestHost { DeviceNotifications.requestAuthorizationIfNeeded() }
        hub.commitSetup()
        followSessions()
        claim(session)
    }

    func cancelSetup() {
        hub.cancelSetup()
        revision &+= 1
    }

    // MARK: Background Bluetooth

    /// iOS relaunched Daybook for a recorder and handed back its connections. The connection's own
    /// state machine reconnects from the system's record of it once the radio reports.
    private func didRestore(_ ids: [UUID]) {
        restored = ids
        restoredAt = Date()
    }

    // MARK: Plumbing

    private func followSessions() {
        let ids = Set(hub.sessions.map(\.id))
        sessionSubscriptions = sessionSubscriptions.filter { ids.contains($0.key) }
        holdRecorders()
        for session in hub.sessions where sessionSubscriptions[session.id] == nil {
            // Listen Live is observed apart from the session (its text changes often): follow both.
            var changes = session.objectWillChange.eraseToAnyPublisher()
            if let live = (session.direct as? any LiveListeningConnection)?.live {
                changes = changes.merge(with: live.objectWillChange).eraseToAnyPublisher()
            }
            sessionSubscriptions[session.id] = changes.sink { [weak self] _ in self?.changed() }
        }
        changed()
    }

    @ObservationIgnored private var pendingChange = false

    /// Coalesced: a transfer publishes often, and views need one redraw per turn.
    private func changed() {
        guard !pendingChange else { return }
        pendingChange = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingChange = false
            self.revision &+= 1
            self.recorderActivity?.follow()
        }
    }
}
