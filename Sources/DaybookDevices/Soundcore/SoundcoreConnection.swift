import AVFoundation
import Combine
import DaybookCaptions
import DaybookCore
import Foundation
import os

/// Soundcore Work's direct method: a connection state machine over a `SoundcoreTransport`.
///
/// - It never scans, connects, or asks for Bluetooth permission on its own until the person sets up
///   a recorder. After that it remembers the recorder and reconnects through the system's record of
///   it (`retrievePeripherals`), falling back to a scan.
/// - An unexpected disconnect retries on a backoff schedule. A connection made for automatic import
///   is let go soon after its imports finish, and one the person made is let go after a few idle
///   minutes, so the phone app can reach the recorder.
/// - It only reads from the recorder. It never deletes, resets, rebinds, or updates it, and starts or
///   pauses a recording only when the person asks.
@MainActor
public final class SoundcoreConnection: ObservableObject, DiscoveringConnection, RecordControlConnection,
                                 LiveListeningConnection, DetailedConnection, ManagedConnection {
    /// Where the connection is. Each phase owns at most one timer.
    public enum Phase: Equatable {
        case idle
        case waitingForRadio(Intent)
        /// Looking for recorders (setup) or for the remembered one (`target`).
        case searching(target: UUID?)
        case connecting(UUID)
        /// The link is up; Daybook is confirming the recorder speaks the expected protocol.
        case opening(UUID)
        case connected(UUID)
        /// A connection for automatic import with no deadline: it completes when the recorder is in range.
        case waitingInRange(UUID)
        case backingOff(attempt: Int)
        case unavailable(RadioState)
    }

    public enum Intent: Equatable { case discover, reconnect, automatic }
    /// Who asked for the connection, which sets how soon it's let go.
    public enum Origin { case person, automatic }

    /// What the last listing on this connection found, or why it found nothing.
    public struct ListingOutcome: Equatable {
        public enum Result: Equatable {
            case listed(count: Int, pages: Int, endedOnRefusal: Bool)
            /// The protocol error, in words (Device Details only).
            case failed(String)
        }

        public let at: Date
        public let result: Result
        public var failed: Bool { if case .failed = result { return true } else { return false } }
    }

    private static let log = Logger(subsystem: "local.daybook.devices", category: "Soundcore")

    public let method = ConnectionMethodKind.direct
    public let capabilities: DeviceCapabilities = [.battery, .caseBattery, .storage, .liveListening, .recordControl, .details, .wirelessTransfer]

    @Published public private(set) var phase: Phase = .idle
    @Published public private(set) var remembered: SoundcoreSnapshot?
    /// The recorder's status while connected.
    @Published public private(set) var info: SoundcoreDeviceInfo?
    @Published public private(set) var statusUpdatedAt: Date?
    @Published public private(set) var recordings: [DeviceRecording] = []
    @Published public private(set) var inventoryUpdatedAt: Date?
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var problem: DeviceProblem?
    @Published public private(set) var discovered: [DiscoveredRecorder] = []
    @Published public private(set) var searchFoundNothing = false
    @Published public private(set) var connectingTo: String?
    @Published public private(set) var recordCommandPending = false
    @Published public private(set) var lastTechnicalProblem: String?
    @Published public private(set) var keyExchangeComplete = false
    @Published public private(set) var reconnectAttempt = 0
    /// A transfer, Listen Live, or a Start or Pause is waiting for another app's transfer to finish (the
    /// Soundcore app, over the link iOS shares between apps): Daybook never starts one over it.
    @Published public private(set) var isWaitingForOtherApp = false
    /// Wi‑Fi Fast Transfer's stage while it runs (iPhone).
    @Published public private(set) var fastTransferStage: FastTransferStage?
    public let live = LiveCapture()

    public var onChange: (() -> Void)?
    /// A Listen Live portion to save: the staged file (the handler removes it once it's saved), the
    /// recording's ID, its length, and the conversation it was captured for (a shared recording), if any.
    public var onLiveSaved: ((URL, String, TimeInterval, UUID?) -> Void)?
    /// The recorder's own button started (true) or stopped (false) a recording: a pushed state that
    /// changes what this device knew, while no Start or Pause of its own is waiting for an answer.
    public var onButton: ((Bool) -> Void)?
    /// Holds the link while the recorder is in range, so its button is heard (a shared recording
    /// starts from it): never let go when idle, and after a drop or a failed attempt a pending
    /// connection with no deadline, rather than the cooldown automatic import waits. The iPhone sets
    /// it for a recorder it manages that records along with it; iOS shares the one link to the
    /// recorder between apps, so holding it doesn't keep the Soundcore app away.
    public var staysConnected = false {
        didSet {
            guard staysConnected != oldValue else { return }
            if staysConnected {
                switch phase {
                case .idle: if automaticDueAt != nil { cancelTimer() }; armAutomatic(after: nil)
                case .connected: idleTimer?.cancel()
                default: break
                }
            } else {
                scheduleIdleRelease()
            }
        }
    }
    /// Set from the device's preference. Turning it on arms a quiet connection to the remembered recorder.
    public var importsAutomatically: Bool {
        didSet {
            guard importsAutomatically != oldValue else { return }
            if importsAutomatically {
                if case .idle = phase { armAutomatic(after: nil) }
            } else if !staysConnected {
                switch phase {
                case .idle, .waitingInRange, .waitingForRadio(.automatic): stopAutomatic()
                default: break
                }
            }
        }
    }
    /// Another device manages this recorder (a synced `RecorderOwnership` whose owner isn't this
    /// device). While set, this device never connects on its own (automatic import, reconnecting,
    /// multipoint) and `connect()` does nothing; a link that's up is let go once it's idle, never in
    /// the middle of a transfer. Clearing it re-arms automatic import as usual.
    @Published public var managedElsewhere: RecorderOwnership? {
        didSet {
            guard managedElsewhere != oldValue else { return }
            if managedElsewhere != nil, oldValue == nil {
                switch phase {
                case .connected, .opening:
                    // Let go once nothing is running; a transfer in progress finishes first.
                    scheduleIdleRelease()
                case .unavailable:
                    deferredIntent = nil
                case .idle:
                    cancelTimer()
                default:
                    disconnect(rearm: false)
                }
            } else if managedElsewhere == nil, case .idle = phase {
                armAutomatic(after: nil)
            }
            publish()
        }
    }

    /// The recorder's serial number, from its status or the remembered recorder.
    public var recorderSerial: String? {
        let serial = info?.serial.isEmpty == false ? info?.serial : remembered?.serial
        return serial?.isEmpty == false ? serial : nil
    }

    /// The device's "Fast Transfer for Long Recordings". Turning it on again tries Fast Transfer afresh,
    /// even where a join failed before.
    public var usesFastTransfer = true {
        didSet {
            guard usesFastTransfer, !oldValue else { return }
            storage.set(nil, "fastTransferUnavailableIn")
            fastTransferPausedUntil = nil
        }
    }
    /// The import queue has another recording from this recorder waiting (the device's session sets it):
    /// Fast Transfer keeps the recorder's Wi‑Fi open for it.
    public var hasMoreQueued: (() -> Bool)?

    /// Settings › Devices › Connect over Bluetooth.
    public var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { if importsAutomatically || staysConnected { armAutomatic(after: nil) } } else { disconnect(rearm: false) }
        }
    }

    private let storage: DeviceStorage
    private let timing: SoundcoreTiming
    private let stagingDirectory: URL
    private let makeTransport: () -> any SoundcoreTransport
    private let captionHooks: LiveCaptionHooks
    private var transport: (any SoundcoreTransport)?
    private var session: SoundcoreSession?
    private var listeningTask: Task<Void, Never>?
    private var peripheral: UUID?
    private var timer: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var origin: Origin = .person
    /// An intent waiting for Bluetooth to come back on.
    private var deferredIntent: Intent?
    private var activity = 0
    private var listing: [SoundcoreRecording] = []
    private var activeRecordingID: UInt32?
    /// The recorder has been listed since this connection was confirmed. Until then `recordings` is
    /// the remembered list, which can name a recording that has since started, grown, or finished.
    private var listedThisConnection = false
    /// Listings under way (a refresh, or one after the recorder's button), for `isRefreshing`.
    private var listingsInFlight = 0
    /// The last listing on this connection: what it found, or why it found nothing (Device Details).
    @Published public private(set) var lastListing: ListingOutcome?
    /// Quiet tries again after a listing that failed, while the link stays up.
    private var relistAttempt = 0
    private var relistTimer: Task<Void, Never>?
    /// The recording this device asked the recorder to start.
    private var startedHereID: UInt32?
    /// Redraws a remembered recording as unknown once it's too old to show.
    private var expiry: Task<Void, Never>?
    /// When the automatic-import wait ends, on the wall clock: a suspended iPhone app runs no timers,
    /// so a background wake checks this instead (`resumeAutomaticImportIfDue`).
    public private(set) var automaticDueAt: Date?
    private var names: [UUID: String] = [:]
    /// Listen Live's captioner, its listeners, and where the live audio has reached (16 kHz frames).
    private var captioner: (any LiveCaptioning)?
    private var captionListeners: [Task<Void, Never>] = []
    private var captionSession = UUID()
    private var liveFrames: AVAudioFramePosition = 0
    private var lastLiveProgress = Date.distantPast
    private let liveSleep = SleepAssertion(reason: "Listening live to Soundcore Work")
    private var isDemo = false
    private let wifiHooks: SoundcoreWiFiHooks
    private lazy var fastTransfer = SoundcoreFastTransfer(host: self, hooks: wifiHooks, timing: timing)
    /// Recordings the person chose to bring over Wi‑Fi, whatever their length.
    private var fastTransferRequested: Set<String> = []
    /// After Fast Transfer failed, transfers stay on Bluetooth until then.
    private var fastTransferPausedUntil: Date?
    /// The Bluetooth link is down on purpose: the recorder is on its own Wi‑Fi (Fast Transfer).
    private var wifiHoldsLink = false

    public init(device: ConfiguredDevice, environment: DeviceEnvironment) {
        storage = environment.storage(for: device, method: .direct)
        timing = environment.soundcoreTiming
        stagingDirectory = environment.stagingDirectory
        makeTransport = environment.soundcoreTransport
        captionHooks = environment.liveCaptions
        importsAutomatically = device.importsAutomatically
        isEnabled = device.isEnabled(.direct)
        usesFastTransfer = device.usesFastTransfer
        wifiHooks = environment.soundcoreWiFi
    }

    // MARK: DeviceConnection

    public var state: ConnectionState {
        if managedElsewhere != nil, remembered != nil {
            switch phase {
            case .connected: return .connected
            case .unavailable: return .unavailable
            default: return .notConnected
            }
        }
        switch phase {
        case .idle: return remembered == nil ? .notSetUp : .notConnected
        case .waitingForRadio(.discover), .searching(target: nil): return .searching
        case .waitingForRadio(.automatic), .waitingInRange: return .notConnected
        case .waitingForRadio(.reconnect), .searching, .connecting, .opening:
            return reconnectAttempt > 0 ? .reconnecting : .connecting
        case .backingOff: return .reconnecting
        case .connected: return .connected
        case .unavailable: return .unavailable
        }
    }

    public var isSetUp: Bool { remembered != nil }
    public var lastConnectedAt: Date? { remembered?.lastConnectedAt }

    /// Live while connected. Otherwise the last confirmed values with their time; recording only while
    /// a recording seen then is recent enough to show as "Recording · as of 10:07", else unknown.
    public var status: DeviceStatus? {
        if case .connected = phase, let info {
            return info.status(at: statusUpdatedAt ?? Date(), activeRecordingStart: startDate(of: activeRecordingID))
        }
        guard let snapshot = remembered, let info = snapshot.info, let date = snapshot.statusUpdatedAt else { return nil }
        var status = info.status(at: date, activeRecordingStart: nil)
        if let known = recordingState, known.isRecording {
            status.isRecording = true
            status.recordingStartedAt = known.startedAt
        } else {
            status.isRecording = nil
        }
        return status
    }

    /// What the recorder is recording: live while connected; otherwise as last confirmed, for at most
    /// `SoundcoreTiming.lastKnownRecording` (nobody can see it stop meanwhile), then unknown (nil).
    /// Nil too when it wasn't recording when last seen.
    public var recordingState: SoundcoreRecordingState? { recordingState(at: Date()) }

    public func recordingState(at now: Date) -> SoundcoreRecordingState? {
        if case .connected = phase, let info {
            let active = listedThisConnection ? activeRecordingID : remembered?.activeRecordingID
            return SoundcoreRecordingState(isRecording: info.isRecording, activeRecordingID: active, startedAt: startDate(of: active),
                                           asOf: statusUpdatedAt ?? now, isLive: true, startedHere: active != nil && active == startedHereID)
        }
        guard let snapshot = remembered, let info = snapshot.info, let asOf = snapshot.statusUpdatedAt,
              info.isRecording || snapshot.activeRecordingID != nil,
              now.timeIntervalSince(asOf) < Self.seconds(timing.lastKnownRecording) else { return nil }
        let active = snapshot.activeRecordingID
        return SoundcoreRecordingState(isRecording: info.isRecording, activeRecordingID: active, startedAt: startDate(of: active),
                                       asOf: asOf, isLive: false, startedHere: active != nil && active == startedHereID)
    }

    private func startDate(of id: UInt32?) -> Date? {
        id.flatMap { SoundcoreRecording(id: $0, size: 0).start(correction: clockCorrection) }
    }

    /// The recorder's clock as last measured, when it was this recorder.
    public var clock: SoundcoreClock? {
        guard let clock = remembered?.clock, clock.serial == recorderSerial else { return nil }
        return clock
    }

    private var clockCorrection: TimeInterval { clock?.correction ?? 0 }

    /// A Start the recorder confirmed: its new recording's ID is when it started by its own clock.
    private func measureClock(recordingID: UInt32, sentAt: Date) {
        guard let serial = recorderSerial, var snapshot = remembered else { return }
        let measured = SoundcoreClock(serial: serial, recordingID: recordingID, sentAt: sentAt)
        snapshot.clock = measured
        remembered = snapshot
        persist()
        SoundcoreClocks.record(measured)
        rebuildRecordings()
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    public var summary: String {
        let automatic = importsAutomatically
        if let owner = managedElsewhere, state == .notConnected {
            return "Managed by \(owner.ownerName)"
        }
        switch state {
        case .connected: return "Connected"
        case .searching: return "Looking for Soundcore Work…"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .unavailable: return problem?.title ?? "Bluetooth isn’t available."
        case .notSetUp: return "Not set up"
        case .notConnected:
            if !isEnabled { return "Off in Settings › Devices." }
            return automatic ? "Connects when it’s nearby." : "Take it out of its case to connect."
        }
    }

    public func activate() {
        guard !isDemo else { return }
        remembered = storage.decode(SoundcoreSnapshot.self, "recorder")
        if let clock { SoundcoreClocks.record(clock) }
        if let remembered {
            listing = remembered.recordings
            inventoryUpdatedAt = remembered.recordingsUpdatedAt
            rebuildRecordings()
        }
        scheduleRecordingExpiry()
        // A run that ended during Fast Transfer may have left the recorder's access point open: the next
        // connection closes it.
        if let ssid = remembered?.accessPointSSID {
            wifiHooks.hotspot?.leave(ssid: ssid)
            problem = SoundcoreIssue.fastTransferInterrupted.problem
        }
        // Publishing first lets the session apply ownership now that the serial is known, so a
        // recorder another device manages is never reached for.
        publish()
        if remembered != nil, isEnabled, importsAutomatically || staysConnected { armAutomatic(after: nil) }
    }

    /// Connect or Reconnect: the remembered recorder directly, then a scan for it.
    public func connect() {
        guard isEnabled, remembered != nil, managedElsewhere == nil else { return }
        personLetGo = false
        if case .connected = phase { return }
        cancelTimer()
        problem = nil
        origin = .person
        reconnectAttempt = 0
        begin(.reconnect)
    }

    public func disconnect() {
        // The person let it go: holding it for the button waits like automatic import does.
        personLetGo = true
        disconnect(rearm: true)
    }

    /// The person disconnected; holding the link for the recorder's button waits until they connect
    /// again (or the next launch).
    private var personLetGo = false

    /// After a handoff: waits for the recorder with no deadline (like automatic import, whatever its
    /// preference), because the device that had it may still be finishing before it lets go.
    public func connectWhenAvailable() {
        guard isEnabled, remembered != nil, managedElsewhere == nil else { return }
        switch phase {
        case .idle, .backingOff, .waitingForRadio(.automatic): break
        default: return
        }
        cancelTimer()
        problem = nil
        origin = .person
        reconnectAttempt = 0
        begin(.automatic)
    }

    public func refresh() {
        guard case .connected = phase, let session, !isRefreshing, !live.isListening else { return }
        beginListing()
        Task {
            // A status that doesn't arrive doesn't keep the list from being read.
            await perform { self.applyStatus(try await session.readStatus()) }
            await self.list(session)
            self.endListing()
        }
    }

    /// The recorder started or stopped on its own (its button): list it again, so a new recording
    /// shows as in progress and a finished one appears with its final size. Imports wait meanwhile.
    private func relist() {
        guard let session else { return }
        beginListing()
        Task {
            await list(session)
            self.endListing()
        }
    }

    /// Reads the recorder's list. When it doesn't come (no answer, or refused), that's said rather
    /// than leaving the remembered list to read as current, and it's tried again quietly.
    private func list(_ session: SoundcoreSession) async {
        await perform {
            do {
                self.applyListing(try await session.listRecordings())
            } catch {
                if self.session === session { self.listingFailed(error) }
                throw error
            }
        }
    }

    private func listingFailed(_ error: Error) {
        guard case .connected = phase, (error as? SoundcoreError) != .disconnected, !(error is CancellationError) else { return }
        lastListing = ListingOutcome(at: Date(), result: .failed(error.localizedDescription))
        Self.log.notice("Recording list failed: \(error.localizedDescription, privacy: .public)")
        if problem == nil { problem = SoundcoreIssue.listFailed.problem }
        scheduleRelist()
        publish()
    }

    private func scheduleRelist() {
        relistTimer?.cancel()
        guard relistAttempt < timing.relist.count else { return }
        let wait = timing.relist[relistAttempt]
        relistAttempt += 1
        relistTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let self, self.lastListing?.failed == true else { return }
            self.refresh()
        }
    }

    private func clearListingFailure() {
        relistTimer?.cancel()
        relistTimer = nil
        relistAttempt = 0
        if problem?.id == SoundcoreIssue.listFailed.rawValue { problem = nil }
    }

    private func beginListing() {
        listingsInFlight += 1
        if !isRefreshing { isRefreshing = true }
        publish()
    }

    private func endListing() {
        listingsInFlight = max(0, listingsInFlight - 1)
        if listingsInFlight == 0 { isRefreshing = false }
        publish()
    }

    public func refreshIfStale() {
        // The device page appeared: the person is here, so the connection isn't let go as quickly.
        if case .connected = phase { origin = .person; scheduleIdleRelease() }
        guard case .connected = phase, !isRefreshing else { return }
        let stale = { (date: Date?) in date.map { Date().timeIntervalSince($0) > 60 } ?? true }
        if stale(statusUpdatedAt) || stale(inventoryUpdatedAt) { refresh() }
    }

    public func dismissProblem() { problem = nil; publish() }

    public func forget() {
        disconnect(rearm: false)
        cancelTimer()
        remembered = nil
        listing = []
        activeRecordingID = nil
        startedHereID = nil
        expiry?.cancel()
        recordings = []
        inventoryUpdatedAt = nil
        statusUpdatedAt = nil
        problem = nil
        origin = .person
        storage.removeAll()
        publish()
    }

    public func shutDown() {
        endFastTransferHere()
        disconnect(rearm: false)
        transport?.stopScan()
        transport = nil
    }

    public func transfer(_ recording: DeviceRecording,
                  progress: @escaping @MainActor (TransferPhase, UInt64) -> Void) async throws -> TransferredAudio {
        guard case .connected = phase, session != nil || wifiHoldsLink else { throw DeviceTransferError.notConnected }
        guard let id = UInt32(recording.id) else { throw DeviceTransferError.rejected("Not a Soundcore recording.") }
        let native = listing.first { $0.id == id } ?? SoundcoreRecording(id: id, size: UInt32(clamping: recording.byteCount ?? 0))
        beginActivity()
        defer { endActivity() }
        let url = stagingDirectory.appendingPathComponent("Soundcore-\(id)-\(UUID().uuidString.prefix(8)).wav")
        do {
            await fastTransfer.settled()
            // Just after Fast Transfer ended, the link is on its way back to Bluetooth: wait for it first.
            if !fastTransfer.isLinked, bluetoothSession == nil, try await bluetoothSessionAfterWiFi() == nil {
                throw SoundcoreError.disconnected
            }
            if fastTransfer.isLinked || fastTransferFits(native, id: recording.id) {
                fastTransferRequested.remove(recording.id)
                if try await fastTransfer.transfer(native, to: url, progress: { phase, bytes in progress(phase, bytes) }) {
                    return TransferredAudio(url: url, isStaged: true, serial: recorderSerial)
                }
                // It fell back: the rest is over Bluetooth, once the link is back.
                progress(.preparing, 0)
            }
            guard let session = try await bluetoothSessionAfterWiFi() else { throw SoundcoreError.disconnected }
            while true {
                do {
                    _ = try await session.download(native, to: url) { phase, bytes in progress(phase, bytes) }
                    break
                } catch SoundcoreError.yielded {
                    // Another app took the recorder for a transfer of its own: this one starts again once it's done.
                    progress(.preparing, 0)
                }
            }
            keyExchangeComplete = session.keyExchangeComplete
            let serial = info?.serial ?? remembered?.serial
            return TransferredAudio(url: url, isStaged: true, serial: serial?.isEmpty == false ? serial : nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastTechnicalProblem = error.localizedDescription
            throw DeviceTransferError(soundcore: error)
        }
    }

    /// Listed since this connection was confirmed, and not being listed again.
    public var isInventoryCurrent: Bool {
        guard case .connected = phase else { return false }
        return listedThisConnection && !isRefreshing
    }

    public func automaticImports(links: DeviceLibraryLinks, since: Date, excluding: Set<String>) -> [DeviceRecording] {
        // The device that manages the recorder imports; its recordings arrive here through sync.
        // Only from a listing made on this connection: the remembered one may still show a recording
        // in progress as finished, and importing it early under its final ID would block the rest.
        guard case .connected = phase, importsAutomatically, managedElsewhere == nil, isInventoryCurrent else { return [] }
        return recordings.filter { recording in
            !recording.isInProgress && links.imported[recording.id] == nil && !excluding.contains(recording.id)
                && (recording.startedAt ?? .distantPast) >= since
        }
    }

    // MARK: Discovery (setup)

    public func search() {
        cancelTimer()
        problem = nil
        origin = .person
        reconnectAttempt = 0
        connectingTo = nil
        begin(.discover)
    }

    public func stopSearching() {
        switch phase {
        case .searching(target: nil), .waitingForRadio(.discover):
            cancelTimer()
            transport?.stopScan()
            phase = .idle
        case .connecting(let id) where connectingTo != nil:
            cancelTimer()
            transport?.disconnect(id)
            peripheral = nil
            connectingTo = nil
            phase = .idle
        default: return
        }
        publish()
    }

    public func connect(to recorder: DiscoveredRecorder) {
        guard let id = UUID(uuidString: recorder.id) else { return }
        transport?.stopScan()
        cancelTimer()
        origin = .person
        reconnectAttempt = 0
        problem = nil
        connectingTo = recorder.id
        open(id, deadline: timing.connect, fallbackToScan: false)
        publish()
    }

    // MARK: Record control

    public func startRecording() { sendRecording(true) }
    public func pauseRecording() { sendRecording(false) }

    private func sendRecording(_ on: Bool) {
        guard case .connected = phase, let session, !recordCommandPending else { return }
        origin = .person
        recordCommandPending = true
        publish()
        let before = activeRecordingID
        Task {
            var confirmed = false
            await perform {
                let sentAt = Date()
                _ = try await session.setRecording(on)
                let deadline = ContinuousClock.now.advanced(by: self.timing.recordConfirm)
                while !confirmed, ContinuousClock.now < deadline {
                    let status = try await session.readStatus()
                    self.applyStatus(status)
                    if status.isRecording == on { confirmed = true } else { try await Task.sleep(for: .milliseconds(500)) }
                }
                if confirmed {
                    self.applyListing(try await session.listRecordings())
                    if on, let started = self.activeRecordingID {
                        self.startedHereID = started
                        // A new recording (not one resumed on firmware that keeps it open) dates the clock.
                        if started != before { self.measureClock(recordingID: started, sentAt: sentAt) }
                    }
                }
            }
            if !confirmed, self.session === session { self.problem = SoundcoreIssue.didNotConfirm.problem }
            self.recordCommandPending = false
            self.publish()
        }
    }

    // MARK: Listen Live

    public func startListening() { startListening(into: nil, captions: true) }

    /// The conversation the live audio being received is saved into, when it's a shared recording's.
    public private(set) var liveConversation: UUID?

    /// Listen Live: receives the recording in progress and saves it as it arrives. With `conversation`,
    /// for a shared recording: the audio is saved into that conversation when listening ends, and
    /// captioning is up to `captions` (the device's own recording captions the room already).
    @discardableResult
    public func startListening(into conversation: UUID?, captions: Bool) -> Bool {
        guard case .connected = phase, let session, !live.isListening else { return false }
        guard info?.isRecording == true else {
            if conversation == nil { problem = SoundcoreIssue.notRecording.problem; publish() }
            return false
        }
        if conversation == nil { origin = .person }
        problem = nil
        live.isListening = true
        live.saved = nil
        live.receivedSeconds = 0
        liveConversation = conversation
        liveSleep.hold(true)
        beginActivity()
        if captions { startCaptions() }
        publish()
        let staging = stagingDirectory
        listeningTask = Task {
            do {
                let result = try await session.listen(
                    destination: { staging.appendingPathComponent("Soundcore-Live-\($0)-\(UUID().uuidString.prefix(8)).wav") },
                    onPCM: { self.receiveLivePCM($0) },
                    progress: { _, bytes in self.liveProgress(bytes) })
                let id = String(result.recordingID)
                self.live.saved = .init(seconds: result.download.seconds, recordingID: id)
                // Whoever saves it removes the staged audio; with nobody to, it goes now.
                if let onLiveSaved = self.onLiveSaved { onLiveSaved(result.download.url, id, result.download.seconds, self.liveConversation) }
                else { try? FileManager.default.removeItem(at: result.download.url) }
            } catch {
                if (error as? SoundcoreError) == .liveFileUnavailable {
                    // A shared recording's capture says nothing on the device page: its recording carries on.
                    if self.liveConversation == nil { self.problem = SoundcoreIssue.notRecording.problem }
                } else if !(error is CancellationError), (error as? SoundcoreError) != .disconnected { self.lastTechnicalProblem = error.localizedDescription }
            }
            self.live.isListening = false
            self.liveConversation = nil
            self.listeningTask = nil
            self.endCaptions()
            self.liveSleep.hold(false)
            self.endActivity()
            self.publish()
        }
        return true
    }

    /// Saves what arrived as a conversation. The recorder keeps recording.
    public func stopListening() {
        // Finish an active transfer first so its received audio survives; cancellation also
        // stops setup or removes a listener waiting behind a different transfer.
        session?.stopListening()
        listeningTask?.cancel()
    }

    private func endLiveSoon() {
        let task = listeningTask
        Task { [weak self] in
            guard let wait = self?.timing.liveTail else { return }
            try? await Task.sleep(for: wait)
            guard let self, self.listeningTask == task, task != nil, self.live.isListening else { return }
            self.session?.stopListening()
        }
    }

    private func liveProgress(_ bytes: UInt64) {
        let now = Date()
        guard now.timeIntervalSince(lastLiveProgress) >= 1 else { return }
        lastLiveProgress = now
        live.receivedSeconds = Double(bytes) / SoundcoreRecording.bytesPerSecond
    }

    /// Live captions of what's arriving, on the shared DaybookCaptions engine: tentative, shown while
    /// listening, never saved or used as the transcript. A captioner that can't run or fails changes
    /// only `live.captionState`; the audio is saved regardless.
    private func startCaptions() {
        endCaptions()
        liveFrames = 0
        guard let captioner = captionHooks.makeCaptioner() else { return }
        self.captioner = captioner
        let token = UUID()
        captionSession = token
        live.captionState = .preparing
        captionListeners = [
            Task { [weak self] in
                for await segments in captioner.updates {
                    guard let self, self.captionSession == token else { return }
                    self.live.captions = segments
                }
            },
            Task { [weak self] in
                for await state in captioner.states {
                    guard let self, self.captionSession == token else { return }
                    self.live.captionState = state
                }
            }
        ]
        let locale = captionHooks.locale()
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        Task { await captioner.start(locale: locale, sourceFormat: format) }
    }

    /// Hands each decoded packet to the captioner as it arrives, at the recorder's own rate and in its
    /// own bursts, stamped with its place in the live audio so a burst or a gap keeps its time.
    private func receiveLivePCM(_ buffer: AVAudioPCMBuffer) {
        guard live.isListening, buffer.frameLength > 0 else { return }
        let time = AVAudioTime(sampleTime: liveFrames, atRate: buffer.format.sampleRate)
        liveFrames += AVAudioFramePosition(buffer.frameLength)
        captioner?.append(buffer, at: time)
    }

    /// Listening ended: the captions go with it, and the captioner finishes on its own time.
    private func endCaptions() {
        captionSession = UUID()
        captionListeners.forEach { $0.cancel() }
        captionListeners = []
        if let captioner {
            self.captioner = nil
            Task { await captioner.finish() }
        }
        if !live.captions.isEmpty { live.captions = [] }
        if live.captionState != .off { live.captionState = .off }
    }

    // MARK: Details

    public var details: [DeviceDetail] {
        let status = status
        let connected = state.isConnected
        let asOf = connected ? "" : status.map { ", as of " + $0.updatedAt.formatted(date: .omitted, time: .shortened) } ?? ""
        var rows = [
            DeviceDetail(label: "Recorder battery", value: BatteryFormat.label(status?.battery) + (status?.battery?.level == nil ? "" : asOf)),
            DeviceDetail(label: "Case battery", value: BatteryFormat.label(status?.caseBattery) + (status?.caseBattery?.level == nil ? "" : asOf)),
            DeviceDetail(label: "Storage", value: status?.storage.map(StorageFormat.detail) ?? "Unknown"),
            DeviceDetail(label: "Recording", value: connected ? (info?.isRecording == true ? "Recording" : "Not recording")
                         : status?.isRecording == true ? "Recording, as of " + (status?.updatedAt.formatted(date: .omitted, time: .shortened) ?? "")
                         : "Unknown while not connected"),
            DeviceDetail(label: "Recorder firmware", value: status?.firmware ?? "Unknown"),
            DeviceDetail(label: "Case firmware", value: status?.caseFirmware ?? "Unknown")
        ]
        if let serial = status?.serial ?? (remembered?.serial.isEmpty == false ? remembered?.serial : nil) {
            rows.append(DeviceDetail(label: "Serial number", value: maskedSerial(serial), copyValue: serial))
        } else {
            rows.append(DeviceDetail(label: "Serial number", value: "Unknown"))
        }
        return rows
    }

    public var technicalDetails: [DeviceDetail] {
        var rows = [
            DeviceDetail(label: "Connection", value: "Bluetooth LE, community-documented protocol"),
            DeviceDetail(label: "Audio key exchange", value: keyExchangeComplete ? "Complete" : "Not yet in this connection")
        ]
        rows.append(DeviceDetail(label: "Recording list", value: listingSummary))
        let named = listedThisConnection ? activeRecordingID : remembered?.activeRecordingID
        if let named {
            let start = startDate(of: named).map { DeviceDateFormat.title($0) } ?? String(named)
            let recording = state.isConnected ? (info?.isRecording == true ? "recording" : "not recording") : "as last listed"
            rows.append(DeviceDetail(label: "Named in progress", value: "\(start) (\(recording))"))
        }
        if let session, session.rejectedFrames > 0 {
            rows.append(DeviceDetail(label: "Malformed frames ignored", value: "\(session.rejectedFrames)"))
        }
        if let session, session.unrequestedAudio > 0 {
            rows.append(DeviceDetail(label: "Audio packets not requested here", value: session.unrequestedAudio.formatted()))
        }
        if let session, session.unrequestedReplies > 0 {
            rows.append(DeviceDetail(label: "Replies not requested here", value: session.unrequestedReplies.formatted()))
        }
        if let session, session.otherAppIsTransferring {
            rows.append(DeviceDetail(label: "Another app", value: isWaitingForOtherApp ? "Transferring; Daybook waits" : "Transferring"))
        }
        if let clock {
            rows.append(DeviceDetail(label: "Recorder clock", value: clock.summary))
        }
        if let fastTransfer = fastTransferSummary {
            rows.append(DeviceDetail(label: "Fast Transfer", value: fastTransfer))
        }
        return rows
    }

    /// "6, in 2 pages, Today, 11:14 AM", "Not listed: The recorder didn’t answer in time.", or the
    /// remembered list's time while not connected.
    private var listingSummary: String {
        guard state.isConnected else {
            return inventoryUpdatedAt.map { "\(listing.count), remembered from \(DeviceDateFormat.title($0))" } ?? "Never listed"
        }
        if isRefreshing && !listedThisConnection { return "Listing…" }
        switch lastListing?.result {
        case .listed(let count, let pages, let refused)?:
            let time = lastListing.map { DeviceDateFormat.title($0.at) } ?? ""
            return "\(count), in \(pages) \(pages == 1 ? "page" : "pages")\(refused ? " (the last refused)" : ""), \(time)"
        case .failed(let reason)?:
            return listedThisConnection ? "Listed earlier; the last try failed: \(reason)" : "Not listed: \(reason)"
        case nil:
            return "Not listed on this connection"
        }
    }

    // MARK: The state machine

    private func begin(_ intent: Intent) {
        // Setup's search is the person's own action; reconnecting and automatic import aren't.
        if intent != .discover, managedElsewhere != nil {
            phase = .idle
            publish()
            return
        }
        phase = .waitingForRadio(intent)
        if transport == nil {
            let made = makeTransport()
            made.events = self
            transport = made
        }
        transport?.activate()
        if transport?.radio == .poweredOn { proceed(intent) } else if let radio = transport?.radio { applyRadio(radio) }
        publish()
    }

    private func proceed(_ intent: Intent) {
        switch intent {
        case .discover: startScan(target: nil)
        case .reconnect: connectRemembered(timed: true)
        case .automatic: connectRemembered(timed: false)
        }
    }

    private func connectRemembered(timed: Bool) {
        guard let transport, let id = remembered?.deviceID else { phase = .idle; return }
        if transport.canReconnect(to: id) {
            if timed { open(id, deadline: timing.reconnect, fallbackToScan: true) }
            else { phase = .waitingInRange(id); peripheral = id; transport.connect(id) }
        } else if !timed, staysConnected {
            // Holding the link never scans (iOS restricts scanning in the background, and it costs
            // battery): the system's record of the recorder is tried again shortly.
            phase = .idle
            armAutomatic(after: timing.holdRetry)
        } else {
            startScan(target: id)
        }
    }

    private func open(_ id: UUID, deadline: Duration, fallbackToScan: Bool) {
        phase = .connecting(id)
        peripheral = id
        // The deadline starts first: a transport may report failure before `connect` returns.
        startTimer(deadline) { [weak self] in self?.connectTimedOut(id, fallbackToScan: fallbackToScan) }
        transport?.connect(id)
    }

    private func startScan(target: UUID?) {
        phase = .searching(target: target)
        if target == nil { discovered = []; searchFoundNothing = false }
        transport?.startScan()
        startTimer(timing.scan) { [weak self] in self?.scanTimedOut(target) }
    }

    private func scanTimedOut(_ target: UUID?) {
        transport?.stopScan()
        if target != nil {
            failedToReach(.notFound)
        } else {
            searchFoundNothing = discovered.isEmpty
            phase = .idle
        }
        publish()
    }

    private func connectTimedOut(_ id: UUID, fallbackToScan: Bool) {
        transport?.disconnect(id)
        peripheral = nil
        if fallbackToScan { startScan(target: id) } else { failedToReach(.connectTimeout) }
        publish()
    }

    /// An attempt didn't reach the recorder: keep to the backoff schedule if reconnecting, tell the
    /// person if they asked, and otherwise wait quietly for the next automatic attempt.
    private func failedToReach(_ issue: SoundcoreIssue) {
        connectingTo = nil
        if reconnectAttempt > 0 { scheduleReconnect(); return }
        phase = .idle
        // The recorder's access point may still be open: that's said whoever asked.
        if remembered?.accessPointSSID != nil { problem = SoundcoreIssue.fastTransferInterrupted.problem }
        else if origin == .person { problem = issue.problem }
        if origin != .person { armAutomatic(after: timing.automaticCooldown) }
    }

    private func scheduleReconnect() {
        reconnectAttempt += 1
        guard reconnectAttempt <= timing.backoff.count, remembered != nil, isEnabled, managedElsewhere == nil else {
            reconnectAttempt = 0
            phase = .idle
            if (importsAutomatically || staysConnected) && isEnabled && remembered != nil { armAutomatic(after: nil) }
            publish()
            return
        }
        phase = .backingOff(attempt: reconnectAttempt)
        startTimer(timing.backoff[reconnectAttempt - 1]) { [weak self] in self?.begin(.reconnect) }
        publish()
    }

    private func armAutomatic(after delay: Duration?) {
        guard importsAutomatically || staysConnected, isEnabled, remembered != nil, managedElsewhere == nil else { return }
        origin = .automatic
        // Holding the link for the recorder's button: no cooldown, a pending connection now, or after a
        // short wait when the last attempt failed at once (never a busy loop).
        let holding = staysConnected && !personLetGo
        let delay = holding ? delay.map { min($0, timing.holdRetry) } : delay
        if let delay, delay > .zero {
            phase = .idle
            automaticDueAt = Date().addingTimeInterval(Self.seconds(delay))
            startTimer(delay) { [weak self] in self?.armAutomatic(after: nil) }
        } else {
            automaticDueAt = nil
            begin(.automatic)
        }
    }

    /// The app was woken in the background (iOS app refresh). A timer doesn't run while the app is
    /// suspended, so a wait for the next automatic import that has run out starts its quiet
    /// connection now; the system keeps that pending, and wakes the app when the recorder answers.
    public func resumeAutomaticImportIfDue(now: Date = Date()) {
        guard case .idle = phase, importsAutomatically || staysConnected, isEnabled, remembered != nil, managedElsewhere == nil else { return }
        if let due = automaticDueAt, due > now { return }
        cancelTimer()
        armAutomatic(after: nil)
    }

    private func stopAutomatic() {
        cancelTimer()
        automaticDueAt = nil
        if case .waitingInRange(let id) = phase { transport?.disconnect(id); peripheral = nil }
        phase = .idle
        origin = .person
        publish()
    }

    private func disconnect(rearm: Bool) {
        endFastTransferHere()
        cancelTimer()
        reconnectAttempt = 0
        connectingTo = nil
        transport?.stopScan()
        if let peripheral { dropLink(peripheral) }
        phase = .idle
        if rearm, importsAutomatically || staysConnected, isEnabled, remembered != nil { armAutomatic(after: timing.automaticCooldown) }
        publish()
    }

    /// Ends the link and everything that belonged to it. Transfers in flight fail as disconnected
    /// (the queue keeps the recording for the reconnect), and Listen Live keeps what arrived.
    private func dropLink(_ id: UUID) {
        idleTimer?.cancel()
        if case .connected = phase, var snapshot = remembered {
            snapshot.lastConnectedAt = Date()
            remembered = snapshot
            persist()
        }
        let closing = session
        session = nil
        closing?.close()
        transport?.disconnect(id)
        peripheral = nil
        info = nil
        activeRecordingID = nil
        listedThisConnection = false
        lastListing = nil
        clearListingFailure()
        recordCommandPending = false
        keyExchangeComplete = false
        isWaitingForOtherApp = false
        // Bluetooth went for real (turned off, say) while the recorder was on its Wi‑Fi: the next link
        // is an ordinary one, and closes the access point.
        wifiHoldsLink = false
        rebuildRecordings()
        scheduleRecordingExpiry()
    }

    /// A recording seen before the link went is shown with its time until it's too old to show;
    /// then the page redraws it as unknown.
    private func scheduleRecordingExpiry() {
        expiry?.cancel()
        guard let known = recordingState, !known.isLive else { return }
        let remaining = known.asOf.addingTimeInterval(Self.seconds(timing.lastKnownRecording)).timeIntervalSinceNow
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, remaining) + 0.01))
            guard !Task.isCancelled, let self else { return }
            self.objectWillChange.send()
            self.rebuildRecordings()
            self.publish()
        }
    }

    private func applyRadio(_ radio: RadioState) {
        switch radio {
        case .poweredOn:
            if case .waitingForRadio(let intent) = phase { proceed(intent) }
            else if case .unavailable = phase {
                problem = nil
                phase = .idle
                if let intent = deferredIntent { deferredIntent = nil; begin(intent) }
                else if importsAutomatically || staysConnected { armAutomatic(after: nil) }
            }
        case .poweredOff, .unauthorized, .unsupported:
            if case .waitingForRadio(let intent) = phase, intent != .automatic { deferredIntent = intent }
            cancelTimer()
            transport?.stopScan()
            if let peripheral {
                // Linked when the radio went away: reconnect when it's back, so waiting imports resume.
                if case .connected = phase { deferredIntent = .reconnect }
                dropLink(peripheral)
            }
            reconnectAttempt = 0
            connectingTo = nil
            phase = .unavailable(radio)
            let issue: SoundcoreIssue = radio == .poweredOff ? .bluetoothOff : radio == .unauthorized ? .bluetoothDenied : .bluetoothUnsupported
            problem = issue.problem
        case .unknown, .resetting:
            let intent: Intent?
            if case .waitingForRadio(let waiting) = phase { intent = waiting }
            else if case .searching = phase { intent = remembered == nil ? .discover : .reconnect }
            else { intent = peripheral != nil ? .reconnect : deferredIntent }
            cancelTimer()
            transport?.stopScan()
            if let peripheral { dropLink(peripheral) }
            connectingTo = nil
            deferredIntent = nil
            if let intent { phase = .waitingForRadio(intent) }
            else { phase = .unavailable(radio) }
        }
    }

    private func linkIsUp(_ id: UUID) {
        cancelTimer()
        wifiHoldsLink = false
        phase = .opening(id)
        peripheral = id
        let transport = transport
        let session = SoundcoreSession(timing: timing) { data in
            guard let transport else { throw SoundcoreError.disconnected }
            try transport.send(data)
        }
        session.onPush = { [weak self] in self?.receivePush($0) }
        session.onWaitingForOtherApp = { [weak self, weak session] waiting in
            guard let self, let session, self.session === session else { return }
            self.isWaitingForOtherApp = waiting
            self.publish()
        }
        self.session = session
        // What it was doing as last seen, so a press missed while the link came back is still heard.
        recordingBeforeLink = remembered?.info?.isRecording ?? false
        publish()
        Task { await confirm(id, session) }
    }

    /// Whether the recorder was recording when last seen, before this connection: nil once its first
    /// list on this connection has been read.
    private var recordingBeforeLink: Bool?

    /// The recorder's button pressed just before the link came back (iOS relaunching Daybook in the
    /// background for it, the push arriving before the link was ready): when the link is held for the
    /// button, a recording it started within `buttonCatchUp` that this device didn't know of counts as
    /// the press. One running longer was started by the person some time ago and isn't a press now.
    private func catchUpMissedButton() {
        guard let before = recordingBeforeLink else { return }
        recordingBeforeLink = nil
        guard staysConnected, !before, info?.isRecording == true, !recordCommandPending,
              let start = startDate(of: activeRecordingID), abs(Date().timeIntervalSince(start)) <= Self.seconds(timing.buttonCatchUp) else { return }
        onButton?(true)
    }

    /// The recorder answers a status request before it counts as connected.
    private func confirm(_ id: UUID, _ session: SoundcoreSession) async {
        do {
            let status = try await session.readStatus()
            guard self.session === session else { return }
            listedThisConnection = false
            personLetGo = false
            phase = .connected(id)
            reconnectAttempt = 0
            connectingTo = nil
            problem = nil
            remember(id, status)
            applyStatus(status)
            scheduleIdleRelease()
            publish()
            if remembered?.accessPointSSID != nil {
                await closeAccessPoint(session)
                guard self.session === session else { return }
            }
            refresh()
        } catch {
            guard self.session === session else { return }
            lastTechnicalProblem = error.localizedDescription
            let reconnecting = reconnectAttempt > 0
            dropLink(id)
            if reconnecting { scheduleReconnect() } else { phase = .idle; problem = SoundcoreIssue.rejected.problem }
            publish()
        }
    }

    private func remember(_ id: UUID, _ status: SoundcoreDeviceInfo) {
        var snapshot = remembered?.deviceID == id ? remembered! : SoundcoreSnapshot(deviceID: id, name: names[id] ?? remembered?.name ?? "Soundcore Work")
        if let name = names[id] { snapshot.name = name }
        snapshot.lastConnectedAt = Date()
        if remembered?.deviceID != id { listing = []; snapshot.recordings = [] }
        remembered = snapshot
        persist()
    }

    private func applyStatus(_ status: SoundcoreDeviceInfo) {
        info = status
        statusUpdatedAt = Date()
        if var snapshot = remembered {
            snapshot.apply(status, at: statusUpdatedAt!)
            remembered = snapshot
            persist()
        }
        rebuildRecordings()
    }

    private func applyListing(_ result: SoundcoreSession.Listing) {
        listing = result.recordings.sorted { $0.id > $1.id }
        activeRecordingID = result.activeRecordingID
        let firstListing = !listedThisConnection
        listedThisConnection = true
        defer { if firstListing { catchUpMissedButton() } }
        let now = Date()
        inventoryUpdatedAt = now
        lastListing = ListingOutcome(at: now, result: .listed(count: listing.count, pages: result.pages, endedOnRefusal: result.endedOnRefusal))
        clearListingFailure()
        Self.log.notice("Recording list: \(result.recordings.count, privacy: .public) in \(result.pages, privacy: .public) pages\(result.endedOnRefusal ? ", the last refused" : "", privacy: .public); in progress: \(result.activeRecordingID.map(String.init) ?? "none", privacy: .public); recording: \(self.info?.isRecording == true, privacy: .public)")
        if var snapshot = remembered {
            snapshot.recordings = Array(listing.prefix(1_000))
            snapshot.recordingsUpdatedAt = inventoryUpdatedAt
            snapshot.activeRecordingID = activeRecordingID
            remembered = snapshot
            persist()
        }
        rebuildRecordings()
        publish()
    }

    private func receivePush(_ push: SoundcoreSession.Push) {
        guard var current = info else { return }
        switch push {
        case .battery(let recorder, let caseLevel):
            current.microphoneBattery = recorder ?? current.microphoneBattery
            current.caseBattery = caseLevel ?? current.caseBattery
        case .charging(let recorder, let caseCharging):
            current.microphoneCharging = recorder
            current.caseCharging = caseCharging
        case .recording(let on):
            let changed = current.isRecording != on
            current.isRecording = on
            // Live audio of a recording that ended has all there is: the stream ends on its own (the
            // last frames may still be on their way), else it's kept after a moment rather than waiting
            // for the stream to go quiet.
            if !on, live.isListening { endLiveSoon() }
            // Either way the list changes: a recording appears in progress, or one is finished.
            relist()
            applyStatus(current)
            publish()
            // The person pressed the recorder's button; a state its own command asked for isn't news.
            if changed, !recordCommandPending { onButton?(on) }
            return
        }
        applyStatus(current)
        publish()
    }

    /// The recording in progress is shown as "Recording now" and never offered for import. It's the
    /// one the recorder names as active, whether or not it says it's recording: firmware may list the
    /// file while it grows, or keep it open while paused. Until this connection has listed it, it's
    /// the one named at the last listing (while that's recent enough to show, when not connected).
    private func rebuildRecordings() {
        let recordingNow: UInt32?
        if case .connected = phase {
            recordingNow = listedThisConnection ? activeRecordingID : remembered?.activeRecordingID
        } else {
            recordingNow = recordingState?.activeRecordingID
        }
        let correction = clockCorrection
        var result = listing.map { $0.deviceRecording(inProgress: $0.id == recordingNow, clockCorrection: correction) }
        if let recordingNow, !listing.contains(where: { $0.id == recordingNow }) {
            result.insert(SoundcoreRecording(id: recordingNow, size: 0).deviceRecording(inProgress: true, clockCorrection: correction), at: 0)
        }
        if result != recordings { recordings = result }
    }

    private func persist() { storage.encode(remembered, "recorder") }

    // MARK: Activity and letting go

    private func perform(_ operation: () async throws -> Void) async {
        beginActivity()
        defer { endActivity() }
        do { try await operation() } catch {
            if (error as? SoundcoreError) != .disconnected, !(error is CancellationError) { lastTechnicalProblem = error.localizedDescription }
        }
    }

    private func beginActivity() {
        activity += 1
        idleTimer?.cancel()
    }

    private func endActivity() {
        activity = max(0, activity - 1)
        scheduleIdleRelease()
    }

    private func scheduleIdleRelease() {
        idleTimer?.cancel()
        guard case .connected = phase, activity == 0, !live.isListening, !(staysConnected && managedElsewhere == nil),
              !fastTransfer.isActive, !wifiHoldsLink else { return }
        let wait = managedElsewhere != nil ? .zero : origin == .automatic ? timing.automaticIdleRelease : timing.idleRelease
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self?.releaseIdle()
        }
    }

    /// Nothing has happened for a while: let the recorder go so the phone app can reach it.
    private func releaseIdle() {
        guard case .connected = phase, activity == 0, !live.isListening, !(staysConnected && managedElsewhere == nil),
              !fastTransfer.isActive, !wifiHoldsLink else { return }
        disconnect(rearm: true)
    }

    private func startTimer(_ delay: Duration, _ action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }

    private func publish() { onChange?() }

    #if DEBUG
    /// Puts the connection into a representative state for screenshots. Never touches Bluetooth.
    public func applyDemo(phase: Phase, remembered: SoundcoreSnapshot?, info: SoundcoreDeviceInfo?, listing: [SoundcoreRecording],
                   activeRecordingID: UInt32?, discovered: [DiscoveredRecorder] = [], searchFoundNothing: Bool = false,
                   problem: DeviceProblem? = nil, reconnectAttempt: Int = 0, connectingTo: String? = nil) {
        isDemo = true
        self.phase = phase
        self.remembered = remembered
        self.info = info
        self.statusUpdatedAt = info == nil ? nil : Date().addingTimeInterval(-20)
        self.listing = listing.sorted { $0.id > $1.id }
        self.activeRecordingID = activeRecordingID
        self.inventoryUpdatedAt = listing.isEmpty ? nil : (info == nil ? remembered?.statusUpdatedAt : Date())
        self.discovered = discovered
        self.searchFoundNothing = searchFoundNothing
        self.problem = problem
        self.reconnectAttempt = reconnectAttempt
        self.connectingTo = connectingTo
        self.keyExchangeComplete = info != nil
        if problem != nil { lastTechnicalProblem = "The peripheral disconnected unexpectedly." }
        rebuildRecordings()
    }
    #endif
}

extension SoundcoreConnection: SoundcoreTransportEvents {
    public func transportRadioChanged(_ radio: RadioState) {
        applyRadio(radio)
        publish()
    }

    public func transportDiscovered(_ id: UUID, name: String, rssi: Int) {
        names[id] = name
        guard case .searching(let target) = phase else { return }
        if let target {
            guard target == id else { return }
            transport?.stopScan()
            open(id, deadline: timing.connect, fallbackToScan: false)
        } else {
            let strength = SignalStrength(rssi: rssi)
            if let index = discovered.firstIndex(where: { $0.id == id.uuidString }) {
                discovered[index].signal = strength
            } else {
                let sameName = discovered.filter { $0.name == name || $0.name.hasPrefix(name + " · ") }.count
                discovered.append(DiscoveredRecorder(id: id.uuidString, name: sameName == 0 ? name : "\(name) · \(sameName + 1)", signal: strength))
            }
        }
        publish()
    }

    public func transportReady(_ id: UUID) {
        switch phase {
        case .connecting(id), .waitingInRange(id): linkIsUp(id)
        default: transport?.disconnect(id)
        }
    }

    public func transportFailed(_ id: UUID, _ failure: TransportFailure) {
        guard peripheral == id, !wifiHoldsLink else { return }
        cancelTimer()
        peripheral = nil
        switch failure {
        case .unsupported(let detail):
            lastTechnicalProblem = detail
            if session != nil { dropLink(id) }
            reconnectAttempt = 0
            connectingTo = nil
            phase = .idle
            problem = SoundcoreIssue.rejected.problem
        case .connectFailed(let detail):
            lastTechnicalProblem = detail ?? lastTechnicalProblem
            if case .waitingInRange = phase { armAutomatic(after: timing.automaticCooldown) } else { failedToReach(.connectTimeout) }
        }
        publish()
    }

    public func transportDisconnected(_ id: UUID, error: String?) {
        // The recorder dropping Bluetooth for its access point is expected.
        guard peripheral == id, !wifiHoldsLink else { return }
        if let error { lastTechnicalProblem = error }
        let wasLinked: Bool
        switch phase {
        case .connected, .opening: wasLinked = true
        default: wasLinked = false
        }
        cancelTimer()
        dropLink(id)
        if wasLinked {
            // Unexpected: try again on the backoff schedule. The import queue waits for the reconnect.
            reconnectAttempt = 0
            scheduleReconnect()
        } else {
            failedToReach(.connectTimeout)
        }
        publish()
    }

    public func transportReceived(_ data: Data) {
        session?.receive(data)
    }
}

// MARK: - Wi‑Fi Fast Transfer (iPhone; docs/direct-soundcore.md, "Wi‑Fi Fast Transfer")

extension SoundcoreConnection: SoundcoreFastTransferHost {
    /// This device can bring recordings over the recorder's Wi‑Fi: it can join networks (the iPhone), and
    /// this build hasn't found it can't.
    public var offersFastTransfer: Bool { wifiHooks.hotspot != nil && !fastTransferUnavailableHere }

    /// The person chose these recordings to come over Wi‑Fi, whatever their length.
    public func requestFastTransfer(_ ids: [String]) {
        fastTransferRequested.formUnion(ids)
    }

    /// A join failed because this build can't join networks: not tried again until the build changes.
    private var fastTransferUnavailableHere: Bool {
        guard let build = storage.string("fastTransferUnavailableIn") else { return false }
        return build == wifiHooks.build
    }

    /// Over Wi‑Fi: on iPhone, in the foreground, when the person chose it or the recording is long enough
    /// and the preference is on; never during Listen Live or another app's transfer, nor for a while
    /// after Fast Transfer failed.
    private func fastTransferFits(_ recording: SoundcoreRecording, id: String) -> Bool {
        guard offersFastTransfer, wifiHooks.isForeground, !live.isListening, session?.otherAppIsTransferring != true,
              (fastTransferPausedUntil ?? .distantPast) <= Date() else { return false }
        if fastTransferRequested.contains(id) { return true }
        return usesFastTransfer && recording.length.seconds >= Self.seconds(timing.fastTransferMinimum)
    }

    /// The Bluetooth session, waiting while the link comes back after Fast Transfer. Nil when it isn't
    /// coming back (the reconnect gave up, Bluetooth went off).
    private func bluetoothSessionAfterWiFi() async throws -> SoundcoreSession? {
        while true {
            if case .connected = phase, !wifiHoldsLink, let session { return session }
            switch phase {
            case .connected where wifiHoldsLink, .waitingForRadio(.reconnect), .searching(target: .some), .connecting, .opening, .backingOff:
                try await Task.sleep(for: .milliseconds(50))
            default:
                return nil
            }
        }
    }

    /// The recorder's access point may still be open (Fast Transfer ended, or a run ended during it).
    private func closeAccessPoint(_ session: SoundcoreSession) async {
        do {
            try await session.closeAccessPoint()
            accessPointMayBeOpen(nil)
            if problem?.id == SoundcoreIssue.fastTransferInterrupted.rawValue { problem = nil }
            Self.log.notice("Closed the recorder's access point")
            publish()
        } catch {
            lastTechnicalProblem = "Closing the recorder’s Wi‑Fi: \(error.localizedDescription)"
        }
    }

    /// The connection is going away during Fast Transfer: its Wi‑Fi side ends where it is, and the
    /// access point, still marked, is closed on the next connection.
    private func endFastTransferHere() {
        guard fastTransfer.isActive || wifiHoldsLink else { return }
        fastTransfer.abandon()
        wifiHoldsLink = false
        if remembered?.accessPointSSID != nil { problem = SoundcoreIssue.fastTransferInterrupted.problem }
    }

    /// "Over Wi‑Fi, Today, 10:02 AM", "Back to Bluetooth, …: why", or how it's set; nil where it can't run.
    private var fastTransferSummary: String? {
        guard wifiHooks.hotspot != nil else { return nil }
        if fastTransferUnavailableHere { return "Unavailable in this build" }
        switch fastTransfer.outcome {
        case .transferred(let at)?: return "Over Wi‑Fi, \(DeviceDateFormat.title(at))"
        case .fellBack(let at, let why)?: return "Back to Bluetooth, \(DeviceDateFormat.title(at)): \(why)"
        case nil: return usesFastTransfer ? "On for long recordings" : "Off"
        }
    }

    // MARK: SoundcoreFastTransferHost

    var bluetoothSession: SoundcoreSession? {
        guard case .connected = phase, !wifiHoldsLink else { return nil }
        return session
    }

    var moreQueued: Bool { hasMoreQueued?() == true }

    func leaveBluetoothForWiFi() {
        guard case .connected(let id) = phase else { return }
        wifiHoldsLink = true
        idleTimer?.cancel()
        relistTimer?.cancel()
        let closing = session
        session = nil
        closing?.close()
        transport?.disconnect(id)
        Self.log.notice("Let Bluetooth go for the recorder's access point")
        publish()
    }

    func returnToBluetooth() {
        guard wifiHoldsLink else { return }
        wifiHoldsLink = false
        guard case .connected = phase, remembered != nil else { return }
        // As a reconnect: the remembered recorder, then a scan, then the backoff schedule.
        phase = .idle
        peripheral = nil
        reconnectAttempt = 0
        begin(.reconnect)
        publish()
    }

    func accessPointMayBeOpen(_ ssid: String?) {
        guard var snapshot = remembered else { return }
        snapshot.accessPointSSID = ssid
        snapshot.accessPointSince = ssid == nil ? nil : Date()
        remembered = snapshot
        persist()
    }

    func fastTransferChanged() {
        fastTransferStage = fastTransfer.stage
        publish()
    }

    func fastTransferFailed(_ error: Error) {
        lastTechnicalProblem = "Fast Transfer: \(error.localizedDescription)"
        Self.log.notice("Fast Transfer fell back to Bluetooth: \(error.localizedDescription, privacy: .public)")
        if (error as? SoundcoreHotspotError) == .unavailable {
            storage.set(wifiHooks.build, "fastTransferUnavailableIn")
        } else if (error as? SoundcoreFastTransferError) != .background {
            fastTransferPausedUntil = Date().addingTimeInterval(Self.seconds(timing.fastTransferPause))
        }
    }
}
